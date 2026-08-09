import CoreGraphics
import Foundation
import Photos

typealias LocalImageNativeRequestID = PHImageRequestID

let localImageInvalidNativeRequestID = PHInvalidImageRequestID

struct LocalImageProviderOptions: Equatable, Sendable {
  let width: Int64
  let height: Int64
  let preferEncoded: Bool
  let allowsNetworkAccess: Bool
  let isSynchronous: Bool
  let kind: LocalImageRequestKind
}

struct LocalImageDeadlinePolicy: Sendable {
  // Fixed deadlines bound native resources even if PhotoKit progress callbacks stall or repeat.
  static let standard = Self(
    localThumbnail: 2,
    localOriginal: 15,
    iCloudThumbnail: 60,
    iCloudOriginal: 300
  )

  let localThumbnail: TimeInterval
  let localOriginal: TimeInterval
  let iCloudThumbnail: TimeInterval
  let iCloudOriginal: TimeInterval

  init(
    localThumbnail: TimeInterval,
    localOriginal: TimeInterval,
    iCloudThumbnail: TimeInterval,
    iCloudOriginal: TimeInterval
  ) {
    precondition(localThumbnail > 0)
    precondition(localOriginal > 0)
    precondition(iCloudThumbnail > 0)
    precondition(iCloudOriginal > 0)
    self.localThumbnail = localThumbnail
    self.localOriginal = localOriginal
    self.iCloudThumbnail = iCloudThumbnail
    self.iCloudOriginal = iCloudOriginal
  }

  func deadline(
    for kind: LocalImageRequestKind,
    policy: LocalImagePolicy
  ) -> TimeInterval {
    switch (kind, policy) {
    case (.thumbnail, .localOnly):
      localThumbnail
    case (.original, .localOnly):
      localOriginal
    case (.thumbnail, .allowICloud):
      iCloudThumbnail
    case (.original, .allowICloud):
      iCloudOriginal
    }
  }
}

enum LocalImageProviderPayload: @unchecked Sendable {
  case encoded(Data)
  case decoded(CGImage)
}

struct LocalImageProviderResult: @unchecked Sendable {
  let payload: LocalImageProviderPayload?
  let isDegraded: Bool
  let isCancelled: Bool
  let hasError: Bool
  let isInCloud: Bool

  static func degraded(_ payload: LocalImageProviderPayload? = nil) -> Self {
    Self(
      payload: payload,
      isDegraded: true,
      isCancelled: false,
      hasError: false,
      isInCloud: false
    )
  }

  static func final(_ payload: LocalImageProviderPayload) -> Self {
    Self(
      payload: payload,
      isDegraded: false,
      isCancelled: false,
      hasError: false,
      isInCloud: false
    )
  }

  static let cancelled = Self(
    payload: nil,
    isDegraded: false,
    isCancelled: true,
    hasError: false,
    isInCloud: false
  )

  static let failed = Self(
    payload: nil,
    isDegraded: false,
    isCancelled: false,
    hasError: true,
    isInCloud: false
  )

  static let inCloud = Self(
    payload: nil,
    isDegraded: false,
    isCancelled: false,
    hasError: false,
    isInCloud: true
  )

  static let missing = Self(
    payload: nil,
    isDegraded: false,
    isCancelled: false,
    hasError: false,
    isInCloud: false
  )
}

protocol LocalImageProviding: AnyObject {
  @discardableResult
  func requestImage(
    assetID: String,
    options: LocalImageProviderOptions,
    progress: ((Double) -> Void)?,
    completion: @escaping (LocalImageProviderResult) -> Void
  ) -> LocalImageNativeRequestID

  func cancelImageRequest(_ requestID: LocalImageNativeRequestID)
}

protocol LocalImageScheduledTask: AnyObject {
  func cancel()
}

protocol LocalImageTimeoutScheduling: AnyObject {
  func schedule(
    after delay: TimeInterval,
    action: @escaping @Sendable () -> Void
  ) -> any LocalImageScheduledTask
}

protocol LocalImagePayloadAllocating: AnyObject {
  func allocate(_ source: LocalImageProviderPayload) -> LocalImageAllocatedPayload?
}

protocol LocalImageExecuting: AnyObject {
  func execute(_ action: @escaping @Sendable () -> Void)
}

final class LocalImageAllocatedPayload: @unchecked Sendable {
  let payload: LocalImagePayload

  init(payload: LocalImagePayload, release: @escaping () -> Void) {
    self.payload = payload
    self.releaseAction = Mutex(release)
  }

  private let releaseAction: Mutex<(() -> Void)?>

  func release() {
    let action = releaseAction.withLock { action in
      defer { action = nil }
      return action
    }
    action?()
  }
}

final class DispatchLocalImageTimeoutScheduler: LocalImageTimeoutScheduling {
  private let queue = DispatchQueue(
    label: "app.immich.local-image-timeouts",
    qos: .userInitiated
  )

  func schedule(
    after delay: TimeInterval,
    action: @escaping @Sendable () -> Void
  ) -> any LocalImageScheduledTask {
    let workItem = DispatchWorkItem(block: action)
    queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    return DispatchLocalImageScheduledTask(workItem: workItem)
  }
}

final class DispatchLocalImageExecutor: LocalImageExecuting {
  init(queue: DispatchQueue) {
    self.queue = queue
  }

  private let queue: DispatchQueue

  func execute(_ action: @escaping @Sendable () -> Void) {
    queue.async(execute: action)
  }
}

final class LocalImagePermit: @unchecked Sendable {
  init(release: @escaping () -> Void) {
    self.releaseAction = Mutex(release)
  }

  private let releaseAction: Mutex<(() -> Void)?>

  func release() {
    let action = releaseAction.withLock { action in
      defer { action = nil }
      return action
    }
    action?()
  }
}

final class LocalImagePermitPool: @unchecked Sendable {
  private struct Entry: @unchecked Sendable {
    let operation: LocalImageOperation
    let start: (LocalImagePermit) -> Void
  }

  private struct State: @unchecked Sendable {
    var activeCount = 0
    var peakActiveCount = 0
    var queued: [Entry] = []
  }

  init(limit: Int) {
    precondition(limit > 0)
    self.limit = limit
  }

  private let limit: Int
  private let state = Mutex(State())

  var activeCount: Int { state.withLock { $0.activeCount } }
  var peakActiveCount: Int { state.withLock { $0.peakActiveCount } }

  func enqueue(
    operation: LocalImageOperation,
    start: @escaping (LocalImagePermit) -> Void
  ) {
    let entry = Entry(operation: operation, start: start)
    let shouldStart = state.withLock { state in
      guard state.activeCount < limit else {
        state.queued.append(entry)
        return false
      }
      state.activeCount += 1
      state.peakActiveCount = max(state.peakActiveCount, state.activeCount)
      return true
    }
    if shouldStart {
      start(makePermit())
    }
  }

  @discardableResult
  func removeQueued(operation: LocalImageOperation) -> Bool {
    state.withLock { state in
      guard let index = state.queued.firstIndex(where: { $0.operation === operation }) else {
        return false
      }
      state.queued.remove(at: index)
      return true
    }
  }

  func removeAllQueued() {
    state.withLock { $0.queued.removeAll() }
  }

  private func makePermit() -> LocalImagePermit {
    LocalImagePermit { [weak self] in self?.releaseAndStartNext() }
  }

  private func releaseAndStartNext() {
    let next = state.withLock { state -> Entry? in
      precondition(state.activeCount > 0, "Local image permit released more than once")
      guard !state.queued.isEmpty else {
        state.activeCount -= 1
        return nil
      }
      return state.queued.removeFirst()
    }
    next?.start(makePermit())
  }
}

final class LocalImageOperation: @unchecked Sendable {
  private enum Phase: @unchecked Sendable {
    case queued
    case running(nativeRequestID: LocalImageNativeRequestID?, permit: LocalImagePermit)
    case finished(cancelLateNativeRequest: Bool)
  }

  struct TerminalResources {
    let nativeRequestID: LocalImageNativeRequestID?
    let permit: LocalImagePermit?
    let timeout: (any LocalImageScheduledTask)?
  }

  struct TerminalTransition {
    let resources: TerminalResources
    let result: LocalImageResult
    let cancelNativeRequest: Bool
  }

  enum FinishDecision {
    case rejected
    case deferred
    case ready(TerminalTransition)
  }

  let id: Int64
  let kind: LocalImageRequestKind

  init(
    id: Int64,
    kind: LocalImageRequestKind,
    completion: @escaping (Result<LocalImageResult, any Error>) -> Void
  ) {
    self.id = id
    self.kind = kind
    self.completion = completion
  }

  private struct State: @unchecked Sendable {
    var phase: Phase = .queued
    var timeout: (any LocalImageScheduledTask)?
    var activeProgressDeliveries = 0
    var pendingTerminal: PendingTerminal?
  }

  private struct PendingTerminal: @unchecked Sendable {
    let result: LocalImageResult
    let cancelNativeRequest: Bool
  }

  private let completion: (Result<LocalImageResult, any Error>) -> Void
  private let state = Mutex(State())

  var isQueued: Bool {
    state.withLock {
      if case .queued = $0.phase { return true }
      return false
    }
  }

  var acceptsCallbacks: Bool {
    state.withLock {
      if case .running = $0.phase, $0.pendingTerminal == nil { return true }
      return false
    }
  }

  func beginProgressDelivery() -> Bool {
    state.withLock { state in
      guard case .running = state.phase, state.pendingTerminal == nil else { return false }
      state.activeProgressDeliveries += 1
      return true
    }
  }

  func endProgressDelivery() -> TerminalTransition? {
    state.withLock { state in
      precondition(state.activeProgressDeliveries > 0)
      state.activeProgressDeliveries -= 1
      guard state.activeProgressDeliveries == 0, let pending = state.pendingTerminal else {
        return nil
      }
      state.pendingTerminal = nil
      return Self.makeTerminalTransition(state: &state, pending: pending)
    }
  }

  func begin(with permit: LocalImagePermit) -> Bool {
    state.withLock { state in
      guard case .queued = state.phase else { return false }
      state.phase = .running(nativeRequestID: nil, permit: permit)
      return true
    }
  }

  func attachTimeout(_ timeout: any LocalImageScheduledTask) -> Bool {
    let attached = state.withLock { state in
      guard case .running = state.phase else { return false }
      state.timeout = timeout
      return true
    }
    if !attached { timeout.cancel() }
    return attached
  }

  func attachNativeRequestID(_ requestID: LocalImageNativeRequestID) -> Bool {
    state.withLock { state in
      switch state.phase {
      case .running(_, let permit):
        if state.pendingTerminal?.cancelNativeRequest == true {
          return true
        }
        state.phase = .running(nativeRequestID: requestID, permit: permit)
        return false
      case .finished(let cancelLateNativeRequest):
        return cancelLateNativeRequest
      case .queued:
        return true
      }
    }
  }

  func requestFinish(
    result: LocalImageResult,
    cancelNativeRequest: Bool
  ) -> FinishDecision {
    state.withLock { state in
      if case .finished = state.phase { return .rejected }
      guard state.pendingTerminal == nil else { return .rejected }
      let pending = PendingTerminal(
        result: result,
        cancelNativeRequest: cancelNativeRequest
      )
      guard state.activeProgressDeliveries == 0 else {
        state.pendingTerminal = pending
        return .deferred
      }
      guard let transition = Self.makeTerminalTransition(state: &state, pending: pending)
      else { return .rejected }
      return .ready(transition)
    }
  }

  func complete(_ result: LocalImageResult) {
    completion(.success(result))
  }

  private static func makeTerminalTransition(
    state: inout State,
    pending: PendingTerminal
  ) -> TerminalTransition? {
    let resources: TerminalResources
    switch state.phase {
    case .queued:
      resources = TerminalResources(
        nativeRequestID: nil,
        permit: nil,
        timeout: state.timeout
      )
    case .running(let nativeRequestID, let permit):
      resources = TerminalResources(
        nativeRequestID: nativeRequestID,
        permit: permit,
        timeout: state.timeout
      )
    case .finished:
      return nil
    }
    state.phase = .finished(cancelLateNativeRequest: pending.cancelNativeRequest)
    state.timeout = nil
    return TerminalTransition(
      resources: resources,
      result: pending.result,
      cancelNativeRequest: pending.cancelNativeRequest
    )
  }
}

private final class DispatchLocalImageScheduledTask: LocalImageScheduledTask {
  init(workItem: DispatchWorkItem) {
    self.workItem = workItem
  }

  private let workItem: DispatchWorkItem

  func cancel() {
    workItem.cancel()
  }
}
