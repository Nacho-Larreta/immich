import Foundation
import OSLog

enum OriginalExportFailure: Error, Equatable, Sendable {
  case assetMissing
  case mediaNotLocal
  case iCloudUnavailable
  case cancelled
  case timeout
  case unauthorized
  case wrongServer
  case serverUnavailable
  case httpFailure
  case storageUnavailable
  case writeFailed
  case cleanupFailed
  case leaseNotFound
  case platformUnsupported

  var pigeonCode: OriginalExportErrorCode {
    switch self {
    case .assetMissing: .assetMissing
    case .mediaNotLocal: .mediaNotLocal
    case .iCloudUnavailable: .iCloudUnavailable
    case .cancelled: .cancelled
    case .timeout: .timeout
    case .unauthorized: .unauthorized
    case .wrongServer: .wrongServer
    case .serverUnavailable: .serverUnavailable
    case .httpFailure: .httpFailure
    case .storageUnavailable: .storageUnavailable
    case .writeFailed: .writeFailed
    case .cleanupFailed: .cleanupFailed
    case .leaseNotFound: .leaseNotFound
    case .platformUnsupported: .platformUnsupported
    }
  }
}

protocol OriginalExportIOExecuting: AnyObject {
  func execute(_ action: @escaping @Sendable () -> Void)
}

final class SerialOriginalExportIOExecutor: OriginalExportIOExecuting {
  private let queue = DispatchQueue(
    label: "app.immich.original-export-io",
    qos: .userInitiated
  )

  func execute(_ action: @escaping @Sendable () -> Void) {
    queue.async(execute: action)
  }
}

protocol OriginalExportScheduledTask: AnyObject {
  func cancel()
}

protocol OriginalExportTimeoutScheduling: AnyObject {
  func schedule(
    after delay: TimeInterval,
    action: @escaping @Sendable () -> Void
  ) -> any OriginalExportScheduledTask
}

final class DispatchOriginalExportTimeoutScheduler: OriginalExportTimeoutScheduling {
  private let queue = DispatchQueue(label: "app.immich.original-export-timeouts")

  func schedule(
    after delay: TimeInterval,
    action: @escaping @Sendable () -> Void
  ) -> any OriginalExportScheduledTask {
    let item = DispatchWorkItem(block: action)
    queue.asyncAfter(deadline: .now() + delay, execute: item)
    return DispatchOriginalExportScheduledTask(item: item)
  }
}

private final class DispatchOriginalExportScheduledTask: OriginalExportScheduledTask {
  init(item: DispatchWorkItem) {
    self.item = item
  }

  private let item: DispatchWorkItem

  func cancel() {
    item.cancel()
  }
}

struct OriginalExportDestination: Equatable, Sendable {
  let directory: URL
  let part: URL
  let committed: URL
}

protocol OriginalExportFileStoring: AnyObject {
  func createDestination(suggestedName: String) throws -> OriginalExportDestination
  func openPart(
    at destination: OriginalExportDestination
  ) throws -> any OriginalExportFileWriting
  func commit(_ destination: OriginalExportDestination) throws -> URL
  func remove(_ destination: OriginalExportDestination) throws
}

protocol OriginalExportFileWriting: AnyObject {
  func write(contentsOf data: Data) throws
  func close() throws
}

extension FileHandle: OriginalExportFileWriting {}

final class TemporaryOriginalExportFileStore: OriginalExportFileStoring {
  static let staleLeaseAge: TimeInterval = 24 * 60 * 60

  init(
    fileManager: FileManager = .default,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    performanceRecorder: any PerformanceRecording = PerformanceTelemetry.shared
  ) {
    self.fileManager = fileManager
    self.temporaryDirectory = temporaryDirectory
    self.performanceRecorder = performanceRecorder
  }

  private let fileManager: FileManager
  private let temporaryDirectory: URL
  private let performanceRecorder: any PerformanceRecording

  func cleanupExpiredOwnedDirectories(olderThan cutoff: Date) throws {
    let properties: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
    let candidates = try fileManager.contentsOfDirectory(
      at: temporaryDirectory,
      includingPropertiesForKeys: Array(properties),
      options: [.skipsHiddenFiles]
    )
    for candidate in candidates where candidate.lastPathComponent.hasPrefix("immich-share-") {
      let values = try candidate.resourceValues(forKeys: properties)
      guard
        values.isDirectory == true,
        let modificationDate = values.contentModificationDate,
        modificationDate < cutoff
      else { continue }
      let interval = performanceRecorder.beginTemporary()
      try fileManager.removeItem(at: candidate)
      interval?.finish()
    }
  }

  func createDestination(suggestedName: String) throws -> OriginalExportDestination {
    let directory = temporaryDirectory.appendingPathComponent(
      "immich-share-\(UUID().uuidString)",
      isDirectory: true
    )
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
    } catch {
      throw OriginalExportFailure.storageUnavailable
    }

    let name = Self.sanitize(suggestedName)
    return OriginalExportDestination(
      directory: directory,
      part: directory.appendingPathComponent(".\(name).part", isDirectory: false),
      committed: directory.appendingPathComponent(name, isDirectory: false)
    )
  }

  func openPart(
    at destination: OriginalExportDestination
  ) throws -> any OriginalExportFileWriting {
    guard fileManager.createFile(atPath: destination.part.path, contents: nil) else {
      throw OriginalExportFailure.storageUnavailable
    }
    do {
      return try FileHandle(forWritingTo: destination.part)
    } catch {
      throw OriginalExportFailure.storageUnavailable
    }
  }

  func commit(_ destination: OriginalExportDestination) throws -> URL {
    do {
      try fileManager.moveItem(at: destination.part, to: destination.committed)
      return destination.committed
    } catch {
      throw OriginalExportFailure.writeFailed
    }
  }

  func remove(_ destination: OriginalExportDestination) throws {
    guard fileManager.fileExists(atPath: destination.directory.path) else { return }
    do {
      try fileManager.removeItem(at: destination.directory)
    } catch {
      throw OriginalExportFailure.cleanupFailed
    }
  }

  static func sanitize(_ suggestedName: String) -> String {
    let leaf = (suggestedName as NSString).lastPathComponent
    let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
    let scalars = leaf.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }
    let sanitized = scalars.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty || sanitized == "." || sanitized == ".." ? "original" : sanitized
  }
}

enum OriginalExportLeaseJanitor {
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app.immich",
    category: "OriginalExportLeaseJanitor"
  )

  static func schedule(
    store: TemporaryOriginalExportFileStore,
    ioExecutor: any OriginalExportIOExecuting,
    now: Date = Date()
  ) {
    ioExecutor.execute {
      do {
        try store.cleanupExpiredOwnedDirectories(
          olderThan: now.addingTimeInterval(-TemporaryOriginalExportFileStore.staleLeaseAge)
        )
      } catch {
        logger.error(
          "Failed to clean expired original-export leases: \(error.localizedDescription)"
        )
      }
    }
  }
}

final class OriginalExportLeaseWriter: @unchecked Sendable {
  private enum State {
    case prepared
    case open(any OriginalExportFileWriting)
    case committed(URL)
    case cleaned
  }

  init(
    destination: OriginalExportDestination,
    store: any OriginalExportFileStoring,
    performanceRecorder: any PerformanceRecording = PerformanceTelemetry.shared
  ) {
    self.destination = destination
    self.store = store
    self.temporaryInterval = performanceRecorder.beginTemporary()
  }

  private let destination: OriginalExportDestination
  private let store: any OriginalExportFileStoring
  private let temporaryInterval: (any PerformanceInterval)?
  private let state = Mutex<State>(.prepared)

  func open() throws {
    try state.withLock { state in
      guard case .prepared = state else { throw OriginalExportFailure.writeFailed }
      state = .open(try store.openPart(at: destination))
    }
  }

  func append(_ data: Data) throws {
    try state.withLock { state in
      guard case .open(let handle) = state else { throw OriginalExportFailure.writeFailed }
      do {
        try handle.write(contentsOf: data)
      } catch {
        throw OriginalExportFailure.writeFailed
      }
    }
  }

  func commit() throws -> URL {
    try state.withLock { state in
      let handle: (any OriginalExportFileWriting)?
      switch state {
      case .open(let openHandle): handle = openHandle
      default: throw OriginalExportFailure.writeFailed
      }
      do {
        try handle?.close()
        let url = try store.commit(destination)
        state = .committed(url)
        return url
      } catch let failure as OriginalExportFailure {
        throw failure
      } catch {
        throw OriginalExportFailure.writeFailed
      }
    }
  }

  @discardableResult
  func cleanup() -> OriginalExportFailure? {
    state.withLock { state in
      switch state {
      case .committed, .cleaned:
        return nil
      case .prepared:
        break
      case .open(let handle):
        try? handle.close()
      }
      do {
        try store.remove(destination)
        state = .cleaned
        temporaryInterval?.finish()
        return nil
      } catch {
        return .cleanupFailed
      }
    }
  }

  func releaseCommitted() throws {
    try state.withLock { state in
      guard case .committed = state else { throw OriginalExportFailure.leaseNotFound }
      do {
        try store.remove(destination)
        state = .cleaned
        temporaryInterval?.finish()
      } catch {
        throw OriginalExportFailure.cleanupFailed
      }
    }
  }

  func owns(committedURL: URL) -> Bool {
    state.withLock { state in
      guard case .committed(let registeredURL) = state else { return false }
      return registeredURL.standardizedFileURL == committedURL.standardizedFileURL
    }
  }
}

final class OriginalExportLeaseRegistry: @unchecked Sendable {
  private enum Phase {
    case active
    case releasing
  }

  private struct Entry {
    let writer: OriginalExportLeaseWriter
    let path: URL
    var phase = Phase.active
    var waiters: [(OriginalExportReleaseResult) -> Void] = []
  }

  init(ioExecutor: any OriginalExportIOExecuting) {
    self.ioExecutor = ioExecutor
  }

  private let ioExecutor: any OriginalExportIOExecuting
  private let entries = Mutex<[String: Entry]>([:])

  func adopt(writer: OriginalExportLeaseWriter, committedURL: URL) throws -> String {
    guard writer.owns(committedURL: committedURL), committedURL.isFileURL else {
      throw OriginalExportFailure.writeFailed
    }
    return entries.withLock { entries in
      var token = UUID().uuidString
      while entries[token] != nil { token = UUID().uuidString }
      entries[token] = Entry(writer: writer, path: committedURL.standardizedFileURL)
      return token
    }
  }

  func release(
    token: String,
    completion: @escaping (OriginalExportReleaseResult) -> Void
  ) {
    let writer = entries.withLock { entries -> OriginalExportLeaseWriter? in
      guard var entry = entries[token] else { return nil }
      entry.waiters.append(completion)
      guard entry.phase == .active else {
        entries[token] = entry
        return nil
      }
      entry.phase = .releasing
      entries[token] = entry
      return entry.writer
    }
    guard let writer else {
      let isKnown = entries.withLock { $0[token] != nil }
      if !isKnown { completion(OriginalExportReleaseResult(error: .leaseNotFound)) }
      return
    }
    ioExecutor.execute { [self] in
      let result: OriginalExportReleaseResult
      do {
        try writer.releaseCommitted()
        result = OriginalExportReleaseResult(error: nil)
      } catch let failure as OriginalExportFailure {
        result = OriginalExportReleaseResult(error: failure.pigeonCode)
      } catch {
        result = OriginalExportReleaseResult(error: .cleanupFailed)
      }
      let waiters = entries.withLock { entries -> [(OriginalExportReleaseResult) -> Void] in
        guard var entry = entries[token] else { return [] }
        let waiters = entry.waiters
        if result.error == nil {
          entries.removeValue(forKey: token)
        } else {
          entry.phase = .active
          entry.waiters.removeAll()
          entries[token] = entry
        }
        return waiters
      }
      for waiter in waiters { waiter(result) }
    }
  }

  func registeredPath(for token: String) -> URL? {
    entries.withLock { $0[token]?.path }
  }
}

final class OriginalExportPermit: @unchecked Sendable {
  init(
    interval: (any PerformanceInterval)?,
    release: @escaping () -> Void
  ) {
    self.interval = interval
    self.releaseAction = Mutex(release)
  }

  private let interval: (any PerformanceInterval)?
  private let releaseAction: Mutex<(() -> Void)?>

  func release() {
    let action = releaseAction.withLock { action in
      defer { action = nil }
      return action
    }
    interval?.finish()
    action?()
  }
}

final class OriginalExportOperation: @unchecked Sendable {
  private enum Phase {
    case queued
    case running
    case terminalizing
    case finalized
  }

  private struct State {
    var phase = Phase.queued
    var writer: OriginalExportLeaseWriter?
    var nativeCancel: (() -> Void)?
    var timeout: (any OriginalExportScheduledTask)?
    var permit: OriginalExportPermit?
    var nativeRequestStarting = false
    var nativeCancellationIssued = false
    var cancelLateNativeRequest = false
    var pendingFailure: OriginalExportFailure?
    var barrierWaiters: [() -> Void] = []
  }

  init(
    id: Int64,
    ioExecutor: any OriginalExportIOExecuting,
    leaseRegistry: OriginalExportLeaseRegistry,
    waitsForNativeCompletionOnCancel: Bool = true,
    onFinalized: @escaping (OriginalExportOperation) -> Void,
    completion: @escaping (Result<OriginalExportResult, any Error>) -> Void
  ) {
    self.id = id
    self.ioExecutor = ioExecutor
    self.leaseRegistry = leaseRegistry
    self.waitsForNativeCompletionOnCancel = waitsForNativeCompletionOnCancel
    self.onFinalized = onFinalized
    self.completion = completion
  }

  let id: Int64
  private let ioExecutor: any OriginalExportIOExecuting
  private let leaseRegistry: OriginalExportLeaseRegistry
  private let waitsForNativeCompletionOnCancel: Bool
  private let onFinalized: (OriginalExportOperation) -> Void
  private let completion: (Result<OriginalExportResult, any Error>) -> Void
  private let state = Mutex(State())

  var isActive: Bool {
    state.withLock { $0.phase == .running && $0.pendingFailure == nil }
  }

  var isQueued: Bool {
    state.withLock { $0.phase == .queued }
  }

  func begin(with permit: OriginalExportPermit) -> Bool {
    state.withLock { state in
      guard state.phase == .queued else { return false }
      state.phase = .running
      state.permit = permit
      return true
    }
  }

  func attach(writer: OriginalExportLeaseWriter) -> Bool {
    state.withLock { state in
      guard state.phase == .running, state.pendingFailure == nil else { return false }
      state.writer = writer
      return true
    }
  }

  func beginNativeRequest() -> Bool {
    state.withLock { state in
      guard state.phase == .running, state.pendingFailure == nil else { return false }
      state.nativeRequestStarting = true
      return true
    }
  }

  func attachNativeCancel(_ nativeCancel: @escaping () -> Void) -> Bool {
    state.withLock { state in
      guard state.phase == .running else {
        guard state.cancelLateNativeRequest, !state.nativeCancellationIssued else { return false }
        state.nativeCancellationIssued = true
        return true
      }
      state.nativeRequestStarting = false
      state.nativeCancel = nativeCancel
      guard state.pendingFailure != nil, !state.nativeCancellationIssued else { return false }
      state.nativeCancellationIssued = true
      return true
    }
  }

  func attach(timeout: any OriginalExportScheduledTask) -> Bool {
    state.withLock { state in
      guard state.phase == .running, state.pendingFailure == nil else { return false }
      state.timeout = timeout
      return true
    }
  }

  @discardableResult
  func succeed() -> Bool {
    nativeCompleted(with: nil)
  }

  @discardableResult
  func fail(_ failure: OriginalExportFailure, cancelNative: Bool = false) -> Bool {
    requestFailure(failure, cancelNative: cancelNative)
  }

  func cancel(after barrier: @escaping () -> Void = {}) {
    let action = state.withLock { state -> FinishAction in
      switch state.phase {
      case .finalized:
        return .barrier(barrier)
      case .terminalizing:
        state.barrierWaiters.append(barrier)
        return .none
      case .queued, .running:
        state.barrierWaiters.append(barrier)
        return requestTerminal(
          state: &state,
          failure: .cancelled,
          cancelNative: true
        )
      }
    }
    perform(action)
  }

  @discardableResult
  func nativeCompleted(with failure: OriginalExportFailure?) -> Bool {
    let action = state.withLock { state -> FinishAction in
      guard state.phase == .running else { return .none }
      state.nativeRequestStarting = false
      state.nativeCancel = nil
      return makeTerminal(
        state: &state,
        outcome: state.pendingFailure.map(Outcome.failure)
          ?? failure.map(Outcome.failure)
          ?? .success
      )
    }
    return perform(action)
  }

  private func requestFailure(
    _ failure: OriginalExportFailure,
    cancelNative: Bool
  ) -> Bool {
    let action = state.withLock { state -> FinishAction in
      guard state.phase == .queued || state.phase == .running else { return .none }
      return requestTerminal(state: &state, failure: failure, cancelNative: cancelNative)
    }
    return perform(action)
  }

  private func requestTerminal(
    state: inout State,
    failure: OriginalExportFailure,
    cancelNative: Bool
  ) -> FinishAction {
    if cancelNative, state.nativeRequestStarting || state.nativeCancel != nil {
      if !waitsForNativeCompletionOnCancel {
        state.cancelLateNativeRequest = state.nativeCancel == nil
        let nativeCancel = state.nativeCancel
        let terminalAction = makeTerminal(state: &state, outcome: .failure(failure))
        guard case .terminal(let terminal) = terminalAction else { return terminalAction }
        if let nativeCancel { return .cancelAndTerminal(nativeCancel, terminal) }
        return terminalAction
      }
      if state.pendingFailure == nil { state.pendingFailure = failure }
      guard let nativeCancel = state.nativeCancel, !state.nativeCancellationIssued else {
        return .none
      }
      state.nativeCancellationIssued = true
      return .cancelNative(nativeCancel)
    }
    return makeTerminal(state: &state, outcome: .failure(failure))
  }

  private func makeTerminal(state: inout State, outcome: Outcome) -> FinishAction {
    guard state.phase == .queued || state.phase == .running else { return .none }
    state.phase = .terminalizing
    let terminal = Terminal(outcome: outcome, resources: TerminalResources(state: state))
    state.writer = nil
    state.nativeCancel = nil
    state.timeout = nil
    state.permit = nil
    return .terminal(terminal)
  }

  @discardableResult
  private func perform(_ action: FinishAction) -> Bool {
    switch action {
    case .none:
      return false
    case .barrier(let barrier):
      barrier()
      return false
    case .cancelNative(let cancel):
      cancel()
      return true
    case .cancelAndTerminal(let cancel, let terminal):
      cancel()
      complete(terminal)
      return true
    case .terminal(let terminal):
      complete(terminal)
      return true
    }
  }

  private func complete(_ terminal: Terminal) {
    terminal.resources.timeout?.cancel()
    ioExecutor.execute { [self] in
      let result = finalize(terminal)
      terminal.resources.permit?.release()
      onFinalized(self)
      completion(.success(result))
      let barriers = state.withLock { state -> [() -> Void] in
        state.phase = .finalized
        defer { state.barrierWaiters.removeAll() }
        return state.barrierWaiters
      }
      for barrier in barriers { barrier() }
    }
  }

  private func finalize(_ terminal: Terminal) -> OriginalExportResult {
    switch terminal.outcome {
    case .success:
      guard let writer = terminal.resources.writer else {
        return .failure(.writeFailed)
      }
      do {
        let committedURL = try writer.commit()
        let token = try leaseRegistry.adopt(writer: writer, committedURL: committedURL)
        return OriginalExportResult(path: committedURL.path, leaseToken: token, error: nil)
      } catch let failure as OriginalExportFailure {
        let cleanupFailure = writer.cleanup()
        return .failure(cleanupFailure ?? failure)
      } catch {
        let cleanupFailure = writer.cleanup()
        return .failure(cleanupFailure ?? .writeFailed)
      }
    case .failure(let failure):
      let cleanupFailure = terminal.resources.writer?.cleanup()
      return .failure(cleanupFailure ?? failure)
    }
  }

  private struct Terminal: @unchecked Sendable {
    let outcome: Outcome
    let resources: TerminalResources
  }

  private enum Outcome: Sendable {
    case success
    case failure(OriginalExportFailure)
  }

  private struct TerminalResources: @unchecked Sendable {
    let writer: OriginalExportLeaseWriter?
    let nativeCancel: (() -> Void)?
    let timeout: (any OriginalExportScheduledTask)?
    let permit: OriginalExportPermit?
    init(state: State) {
      writer = state.writer
      nativeCancel = state.nativeCancel
      timeout = state.timeout
      permit = state.permit
    }
  }

  private enum FinishAction {
    case none
    case barrier(() -> Void)
    case cancelNative(() -> Void)
    case cancelAndTerminal(() -> Void, Terminal)
    case terminal(Terminal)
  }
}

final class OriginalExportPermitPool: @unchecked Sendable {
  private struct Entry {
    let operation: OriginalExportOperation
    let start: (OriginalExportPermit) -> Void
  }

  private struct State {
    var activeCount = 0
    var peakActiveCount = 0
    var queued: [Entry] = []
  }

  init(
    limit: Int,
    performanceRecorder: any PerformanceRecording = PerformanceTelemetry.shared
  ) {
    precondition(limit > 0)
    self.limit = limit
    self.performanceRecorder = performanceRecorder
  }

  private let limit: Int
  private let performanceRecorder: any PerformanceRecording
  private let state = Mutex(State())

  var activeCount: Int { state.withLock { $0.activeCount } }
  var peakActiveCount: Int { state.withLock { $0.peakActiveCount } }

  func enqueue(
    operation: OriginalExportOperation,
    start: @escaping (OriginalExportPermit) -> Void
  ) {
    let shouldStart = state.withLock { state in
      guard state.activeCount < limit else {
        state.queued.append(Entry(operation: operation, start: start))
        return false
      }
      state.activeCount += 1
      state.peakActiveCount = max(state.peakActiveCount, state.activeCount)
      return true
    }
    if shouldStart { start(makePermit()) }
  }

  @discardableResult
  func removeQueued(_ operation: OriginalExportOperation) -> Bool {
    state.withLock { state in
      guard let index = state.queued.firstIndex(where: { $0.operation === operation }) else {
        return false
      }
      state.queued.remove(at: index)
      return true
    }
  }

  private func makePermit() -> OriginalExportPermit {
    OriginalExportPermit(
      interval: performanceRecorder.beginPermit(.originalExport)
    ) { [weak self] in
      self?.releaseAndStartNext()
    }
  }

  private func releaseAndStartNext() {
    let next = state.withLock { state -> Entry? in
      precondition(state.activeCount > 0)
      guard !state.queued.isEmpty else {
        state.activeCount -= 1
        return nil
      }
      return state.queued.removeFirst()
    }
    next?.start(makePermit())
  }
}

extension OriginalExportResult {
  static func failure(_ failure: OriginalExportFailure) -> Self {
    Self(path: nil, leaseToken: nil, error: failure.pigeonCode)
  }
}
