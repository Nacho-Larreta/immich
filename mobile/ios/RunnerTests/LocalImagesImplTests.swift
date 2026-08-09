import CoreGraphics
import Foundation
import XCTest

@testable import Runner

final class LocalImagesImplTests: XCTestCase {
  private let deadlinePolicy = LocalImageDeadlinePolicy(
    localThumbnail: 2,
    localOriginal: 3,
    iCloudThumbnail: 4,
    iCloudOriginal: 5
  )
  private var provider: ControllableLocalImageProvider!
  private var scheduler: ManualLocalImageTimeoutScheduler!
  private var allocator: RecordingLocalImagePayloadAllocator!
  private var progress: ProgressRecorder!
  private var performance: RecordingPerformanceRecorder!
  private var api: LocalImageApiImpl!

  override func setUp() {
    super.setUp()
    provider = ControllableLocalImageProvider()
    scheduler = ManualLocalImageTimeoutScheduler()
    allocator = RecordingLocalImagePayloadAllocator()
    progress = ProgressRecorder()
    performance = RecordingPerformanceRecorder()
    api = makeAPI()
  }

  override func tearDown() {
    api.dispose()
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)
    XCTAssertEqual(api.activeRequestCount(for: .original), 0)
    api = nil
    progress = nil
    allocator = nil
    performance = nil
    scheduler = nil
    provider = nil
    super.tearDown()
  }

  func testDegradedResultIsIgnoredUntilFinalResultArrives() {
    let recorder = request(id: 1)
    let nativeID = provider.onlyStartedRequestID

    provider.emit(.degraded(.encoded(Data("preview".utf8))), for: nativeID)

    XCTAssertEqual(recorder.count, 0)
    XCTAssertEqual(allocator.allocationCount, 0)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 1)

    provider.emit(.final(.encoded(Data("final".utf8))), for: nativeID)

    XCTAssertEqual(recorder.count, 1)
    XCTAssertNotNil(try? recorder.result?.get().payload)
    XCTAssertEqual(allocator.allocationCount, 1)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)
    XCTAssertEqual(performance.finishedCount(.request(.localThumbnail)), 1)
    XCTAssertEqual(performance.finishedCount(.permit(.localThumbnail)), 1)
  }

  func testMultipleDegradedCallbacksDoNotAllocateOrComplete() {
    let recorder = request(id: 2)
    let nativeID = provider.onlyStartedRequestID

    provider.emit(.degraded(.encoded(Data("one".utf8))), for: nativeID)
    provider.emit(.degraded(.encoded(Data("two".utf8))), for: nativeID)

    XCTAssertEqual(recorder.count, 0)
    XCTAssertEqual(allocator.allocationCount, 0)

    provider.emit(.final(.encoded(Data("final".utf8))), for: nativeID)
    XCTAssertEqual(recorder.count, 1)
  }

  func testCancellationWinningBeforeFinalCompletesOnceAndIgnoresLatePayload() {
    let recorder = request(id: 3)
    let nativeID = provider.onlyStartedRequestID

    api.cancelRequest(requestId: 3)
    provider.emit(.final(.encoded(Data("late".utf8))), for: nativeID)

    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get().error, .cancelled)
    XCTAssertEqual(allocator.allocationCount, 0)
    XCTAssertEqual(provider.cancelledRequestIDs, [nativeID])
  }

  func testFinalWinningBeforeCancellationCompletesOnce() {
    let recorder = request(id: 4)
    let nativeID = provider.onlyStartedRequestID

    provider.emit(.final(.encoded(Data("final".utf8))), for: nativeID)
    api.cancelRequest(requestId: 4)

    XCTAssertEqual(recorder.count, 1)
    XCTAssertNotNil(try? recorder.result?.get().payload)
    XCTAssertTrue(provider.cancelledRequestIDs.isEmpty)
  }

  func testConcurrentCancellationAndFinalCallbackHaveOneWinner() {
    for iteration in 0..<50 {
      let requestID = Int64(1_000 + iteration)
      let recorder = request(id: requestID)
      guard let nativeID = provider.startedRequestIDs.last else {
        return XCTFail("Expected the native request to start")
      }

      DispatchQueue.concurrentPerform(iterations: 2) { contender in
        if contender == 0 {
          api.cancelRequest(requestId: requestID)
        } else {
          provider.emit(.final(.encoded(Data("final".utf8))), for: nativeID)
        }
      }

      XCTAssertEqual(recorder.count, 1)
      XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)
    }
  }

  func testNativeCancellationMapsToCancelled() {
    assertNativeTerminal(.cancelled, mapsTo: .cancelled, requestId: 5)
  }

  func testNativeErrorMapsToMediaNotLocal() {
    assertNativeTerminal(.failed, mapsTo: .mediaNotLocal, requestId: 6)
    XCTAssertEqual(performance.finishedCount(.request(.localThumbnail)), 1)
    XCTAssertEqual(performance.finishedCount(.permit(.localThumbnail)), 1)
  }

  func testFinalNilInCloudMapsToICloudUnavailable() {
    assertNativeTerminal(.inCloud, mapsTo: .iCloudUnavailable, requestId: 7)
  }

  func testFinalNilWithoutCloudMapsToMediaNotLocal() {
    assertNativeTerminal(.missing, mapsTo: .mediaNotLocal, requestId: 8)
  }

  func testTimeoutCancelsNativeRequestAndCompletesOnce() {
    let recorder = request(id: 9)
    let nativeID = provider.onlyStartedRequestID

    scheduler.advance(by: 2)
    provider.emit(.final(.encoded(Data("late".utf8))), for: nativeID)

    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get().error, .timeout)
    XCTAssertEqual(provider.cancelledRequestIDs, [nativeID])
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)
    XCTAssertEqual(performance.finishedCount(.request(.localThumbnail)), 1)
    XCTAssertEqual(performance.finishedCount(.permit(.localThumbnail)), 1)
  }

  func testInvalidNativeRequestIDFailsWithoutWaitingForTimeout() {
    provider.nextRequestID = localImageInvalidNativeRequestID

    let recorder = request(id: 10)

    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get().error, .mediaNotLocal)
    XCTAssertTrue(provider.cancelledRequestIDs.isEmpty)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)
  }

  func testProviderStartIsDeferredToInjectedExecutor() {
    let executor = ManualLocalImageExecutor()
    replaceAPI(nativeExecutor: executor)

    let recorder = request(id: 101)

    XCTAssertTrue(provider.startedRequestIDs.isEmpty)
    XCTAssertEqual(recorder.count, 0)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 1)

    executor.runNext()
    XCTAssertEqual(provider.startedRequestIDs.count, 1)

    provider.emit(.missing, for: provider.onlyStartedRequestID)
    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)
  }

  func testCancellationBeforeExecutorRunsSkipsProviderAndReleasesPermit() {
    let executor = ManualLocalImageExecutor()
    replaceAPI(nativeExecutor: executor)
    let recorder = request(id: 102)

    api.cancelRequest(requestId: 102)

    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get().error, .cancelled)
    XCTAssertTrue(provider.startedRequestIDs.isEmpty)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)

    executor.runAll()
    XCTAssertTrue(provider.startedRequestIDs.isEmpty)
    XCTAssertEqual(recorder.count, 1)
  }

  func testCancellationBeforeNativeIDAttachCancelsIDWhenAttachCompletes() {
    provider.beforeReturningRequestID = { [weak self] _ in
      self?.api.cancelRequest(requestId: 11)
    }

    let recorder = request(id: 11)
    let nativeID = provider.onlyStartedRequestID

    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get().error, .cancelled)
    XCTAssertEqual(provider.cancelledRequestIDs, [nativeID])
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)
  }

  func testFinalBeforeNativeIDAttachDoesNotCancelAlreadyFinishedNativeRequest() {
    provider.beforeReturningRequestID = { [weak provider] nativeID in
      provider?.emit(.final(.encoded(Data("sync-final".utf8))), for: nativeID)
    }

    let recorder = request(id: 12)

    XCTAssertEqual(recorder.count, 1)
    XCTAssertNotNil(try? recorder.result?.get().payload)
    XCTAssertTrue(provider.cancelledRequestIDs.isEmpty)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)
  }

  func testDuplicateRequestIDIsRejectedWithoutOverwritingOriginal() {
    let original = request(id: 13)
    let duplicate = request(id: 13)

    XCTAssertEqual(provider.startedRequestIDs.count, 1)
    XCTAssertEqual(duplicate.count, 1)
    XCTAssertEqual(try? duplicate.result?.get().error, .cancelled)

    provider.emit(.final(.encoded(Data("original".utf8))), for: provider.onlyStartedRequestID)
    XCTAssertEqual(original.count, 1)
    XCTAssertNotNil(try? original.result?.get().payload)
  }

  func testMultipleTerminalCallbacksCompleteAndReleasePermitExactlyOnce() {
    let recorder = request(id: 14)
    let nativeID = provider.onlyStartedRequestID

    provider.emit(.missing, for: nativeID)
    provider.emit(.cancelled, for: nativeID)
    scheduler.advance(by: 2)

    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get().error, .mediaNotLocal)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)
    XCTAssertEqual(performance.finishedCount(.request(.localThumbnail)), 1)
    XCTAssertEqual(performance.finishedCount(.permit(.localThumbnail)), 1)
  }

  func testThumbnailGateStartsAtMostFourRequestsAndStartsNextAfterRelease() {
    let recorders = (20...24).map { request(id: Int64($0), kind: .thumbnail) }

    XCTAssertEqual(provider.startedRequestIDs.count, 4)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 4)
    XCTAssertEqual(api.peakActiveRequestCount(for: .thumbnail), 4)

    provider.emit(.missing, for: provider.startedRequestIDs[0])

    XCTAssertEqual(provider.startedRequestIDs.count, 5)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 4)

    completeAllStartedRequests()
    XCTAssertTrue(recorders.allSatisfy { $0.count == 1 })
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)
  }

  func testOriginalGateStartsAtMostTwoRequestsAndStartsNextAfterRelease() {
    let recorders = (30...32).map { request(id: Int64($0), kind: .original) }

    XCTAssertEqual(provider.startedRequestIDs.count, 2)
    XCTAssertEqual(api.activeRequestCount(for: .original), 2)
    XCTAssertEqual(api.peakActiveRequestCount(for: .original), 2)

    provider.emit(.missing, for: provider.startedRequestIDs[0])

    XCTAssertEqual(provider.startedRequestIDs.count, 3)
    completeAllStartedRequests()
    XCTAssertTrue(recorders.allSatisfy { $0.count == 1 })
    XCTAssertEqual(api.activeRequestCount(for: .original), 0)
  }

  func testThumbnailAndOriginalLimitsAreIndependent() {
    let thumbnailRecorders = (40...44).map { request(id: Int64($0), kind: .thumbnail) }
    let originalRecorders = (50...52).map { request(id: Int64($0), kind: .original) }

    XCTAssertEqual(provider.startedCount(for: .thumbnail), 4)
    XCTAssertEqual(provider.startedCount(for: .original), 2)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 4)
    XCTAssertEqual(api.activeRequestCount(for: .original), 2)

    completeAllStartedRequests()
    XCTAssertTrue((thumbnailRecorders + originalRecorders).allSatisfy { $0.count == 1 })
    XCTAssertEqual(api.peakActiveRequestCount(for: .thumbnail), 4)
    XCTAssertEqual(api.peakActiveRequestCount(for: .original), 2)
  }

  func testCancellingQueuedRequestDoesNotStartPhotoKitOrConsumePermit() {
    let active = (60...63).map { request(id: Int64($0), kind: .thumbnail) }
    let queued = request(id: 64, kind: .thumbnail)

    api.cancelRequest(requestId: 64)

    XCTAssertEqual(queued.count, 1)
    XCTAssertEqual(try? queued.result?.get().error, .cancelled)
    XCTAssertEqual(provider.startedRequestIDs.count, 4)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 4)
    XCTAssertEqual(performance.startedCount(.request(.localThumbnail)), 5)
    XCTAssertEqual(performance.startedCount(.permit(.localThumbnail)), 4)
    XCTAssertEqual(performance.finishedCount(.request(.localThumbnail)), 1)
    XCTAssertEqual(performance.finishedCount(.permit(.localThumbnail)), 0)

    completeAllStartedRequests()
    XCTAssertTrue(active.allSatisfy { $0.count == 1 })
    XCTAssertEqual(provider.startedRequestIDs.count, 4)
    XCTAssertEqual(performance.finishedCount(.request(.localThumbnail)), 5)
    XCTAssertEqual(performance.finishedCount(.permit(.localThumbnail)), 4)
  }

  func testCancellingActiveRequestReleasesPermitAndStartsNextQueuedRequest() {
    let recorders = (65...69).map { request(id: Int64($0), kind: .thumbnail) }

    api.cancelRequest(requestId: 65)

    XCTAssertEqual(recorders[0].count, 1)
    XCTAssertEqual(try? recorders[0].result?.get().error, .cancelled)
    XCTAssertEqual(provider.startedRequestIDs.count, 5)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 4)
    XCTAssertEqual(performance.finishedCount(.request(.localThumbnail)), 1)
    XCTAssertEqual(performance.finishedCount(.permit(.localThumbnail)), 1)

    completeAllStartedRequests()
    XCTAssertTrue(recorders.allSatisfy { $0.count == 1 })
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)
    XCTAssertEqual(performance.finishedCount(.request(.localThumbnail)), 5)
    XCTAssertEqual(performance.finishedCount(.permit(.localThumbnail)), 5)
  }

  func testCancelAllAndDisposeAreIdempotentAndIgnoreLateCallbacks() {
    let recorders = (70...75).map { request(id: Int64($0), kind: .thumbnail) }
    let startedIDs = provider.startedRequestIDs

    api.cancelAll()
    api.cancelAll()
    api.dispose()
    api.dispose()

    let rejectedAfterDispose = request(id: 76, kind: .thumbnail)

    XCTAssertTrue(recorders.allSatisfy { $0.count == 1 })
    XCTAssertTrue(recorders.allSatisfy { (try? $0.result?.get().error) == .cancelled })
    XCTAssertEqual(provider.cancelledRequestIDs.sorted(), startedIDs.sorted())
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)
    XCTAssertEqual(rejectedAfterDispose.count, 1)
    XCTAssertEqual(try? rejectedAfterDispose.result?.get().error, .cancelled)
    XCTAssertEqual(provider.startedRequestIDs, startedIDs)

    for requestID in startedIDs {
      provider.emit(.final(.encoded(Data("late".utf8))), for: requestID)
    }
    XCTAssertTrue(recorders.allSatisfy { $0.count == 1 })
    XCTAssertEqual(allocator.allocationCount, 0)
    XCTAssertEqual(performance.finishedCount(.request(.localThumbnail)), 6)
    XCTAssertEqual(performance.finishedCount(.permit(.localThumbnail)), 4)
  }

  func testPayloadAllocatedDuringCancellationRaceIsReleasedWhenCancellationWins() {
    let recorder = request(id: 80)
    let nativeID = provider.onlyStartedRequestID
    allocator.onAllocate = { [weak self] in
      self?.api.cancelRequest(requestId: 80)
    }

    provider.emit(.final(.encoded(Data("racing".utf8))), for: nativeID)

    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get().error, .cancelled)
    XCTAssertEqual(allocator.allocationCount, 1)
    XCTAssertEqual(allocator.releaseCount, 1)
  }

  func testPolicyBuildsFreshAsyncOptionsAndOnlyICloudRequestsReportProgress() {
    _ = request(id: 90, policy: .localOnly)
    _ = request(id: 91, policy: .allowICloud)

    let local = provider.startedRequest(forAssetID: "asset-90")
    let cloud = provider.startedRequest(forAssetID: "asset-91")
    XCTAssertEqual(local?.options.allowsNetworkAccess, false)
    XCTAssertEqual(local?.options.isSynchronous, false)
    XCTAssertEqual(local?.hasProgressHandler, false)
    XCTAssertEqual(cloud?.options.allowsNetworkAccess, true)
    XCTAssertEqual(cloud?.options.isSynchronous, false)
    XCTAssertEqual(cloud?.hasProgressHandler, true)
  }

  func testProgressIsClampedAndIgnoredAfterTerminalState() {
    _ = request(id: 92, policy: .allowICloud)
    let nativeID = provider.onlyStartedRequestID

    provider.emitProgress(-0.25, for: nativeID)
    provider.emitProgress(0.4, for: nativeID)
    provider.emitProgress(1.5, for: nativeID)
    provider.emit(.missing, for: nativeID)
    provider.emitProgress(0.8, for: nativeID)

    XCTAssertEqual(progress.values.map(\.fraction), [0, 0.4, 1])
    XCTAssertEqual(progress.values.map(\.requestId), [92, 92, 92])
  }

  func testDeadlinePolicyIsExplicitForEveryKindAndPolicy() {
    XCTAssertEqual(deadlinePolicy.deadline(for: .thumbnail, policy: .localOnly), 2)
    XCTAssertEqual(deadlinePolicy.deadline(for: .original, policy: .localOnly), 3)
    XCTAssertEqual(deadlinePolicy.deadline(for: .thumbnail, policy: .allowICloud), 4)
    XCTAssertEqual(deadlinePolicy.deadline(for: .original, policy: .allowICloud), 5)
  }

  func testICloudOriginalCanProgressPastTwoSecondsAndFinish() {
    let recorder = request(id: 93, kind: .original, policy: .allowICloud)
    let nativeID = provider.onlyStartedRequestID

    scheduler.advance(by: 2.5)
    provider.emitProgress(0.5, for: nativeID)

    XCTAssertEqual(recorder.count, 0)
    XCTAssertEqual(progress.values.map(\.fraction), [0.5])

    provider.emit(.final(.encoded(Data("cloud-original".utf8))), for: nativeID)
    scheduler.advance(by: 10)

    XCTAssertEqual(recorder.count, 1)
    XCTAssertNotNil(try? recorder.result?.get().payload)
    XCTAssertTrue(provider.cancelledRequestIDs.isEmpty)
  }

  func testDeferredProgressIsDroppedWhenFinalWins() {
    let executor = ManualLocalImageExecutor()
    replaceAPI(progressExecutor: executor)
    let recorder = request(id: 94, policy: .allowICloud)
    let nativeID = provider.onlyStartedRequestID

    provider.emitProgress(0.5, for: nativeID)
    provider.emit(.missing, for: nativeID)
    executor.runAll()

    XCTAssertEqual(recorder.count, 1)
    XCTAssertTrue(progress.values.isEmpty)
  }

  func testDeferredProgressIsDroppedWhenCancellationWins() {
    let executor = ManualLocalImageExecutor()
    replaceAPI(progressExecutor: executor)
    let recorder = request(id: 95, policy: .allowICloud)
    let nativeID = provider.onlyStartedRequestID

    provider.emitProgress(0.5, for: nativeID)
    api.cancelRequest(requestId: 95)
    executor.runAll()

    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get().error, .cancelled)
    XCTAssertTrue(progress.values.isEmpty)
  }

  func testDeferredProgressIsDroppedWhenTimeoutWins() {
    let executor = ManualLocalImageExecutor()
    replaceAPI(progressExecutor: executor)
    let recorder = request(id: 96, policy: .allowICloud)
    let nativeID = provider.onlyStartedRequestID

    provider.emitProgress(0.5, for: nativeID)
    scheduler.advance(by: 4)
    executor.runAll()

    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get().error, .timeout)
    XCTAssertTrue(progress.values.isEmpty)
  }

  func testProgressHandlerCanCancelSynchronouslyWithoutLateProgress() {
    replaceAPI { [weak self] event in
      guard let self else { return }
      progress.record(event)
      api.cancelRequest(requestId: event.requestId)
    }
    let recorder = request(id: 97, policy: .allowICloud)
    let nativeID = provider.onlyStartedRequestID

    provider.emitProgress(0.25, for: nativeID)

    XCTAssertEqual(progress.values.map(\.fraction), [0.25])
    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get().error, .cancelled)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)
    XCTAssertEqual(provider.cancelledRequestIDs, [nativeID])

    provider.emitProgress(0.75, for: nativeID)
    provider.emit(.missing, for: nativeID)

    XCTAssertEqual(progress.values.map(\.fraction), [0.25])
    XCTAssertEqual(recorder.count, 1)
  }

  private func request(
    id: Int64,
    kind: LocalImageRequestKind = .thumbnail,
    policy: LocalImagePolicy = .localOnly
  ) -> CompletionRecorder<LocalImageResult> {
    let recorder = CompletionRecorder<LocalImageResult>()
    api.requestImage(
      request: LocalImageRequest(
        assetId: "asset-\(id)",
        requestId: id,
        width: 200,
        height: 100,
        isVideo: false,
        preferEncoded: true,
        policy: policy,
        kind: kind
      )
    ) { _ = recorder.record($0) }
    return recorder
  }

  private func makeAPI(
    nativeExecutor: any LocalImageExecuting = ImmediateLocalImageExecutor(),
    progressExecutor: any LocalImageExecuting = ImmediateLocalImageExecutor(),
    progressHandler: ((LocalImageProgress) -> Void)? = nil
  ) -> LocalImageApiImpl {
    LocalImageApiImpl(
      provider: provider,
      timeoutScheduler: scheduler,
      deadlinePolicy: deadlinePolicy,
      nativeExecutor: nativeExecutor,
      progressExecutor: progressExecutor,
      payloadAllocator: allocator,
      performanceRecorder: performance,
      progressHandler: progressHandler ?? progress.record
    )
  }

  private func replaceAPI(
    nativeExecutor: any LocalImageExecuting = ImmediateLocalImageExecutor(),
    progressExecutor: any LocalImageExecuting = ImmediateLocalImageExecutor(),
    progressHandler: ((LocalImageProgress) -> Void)? = nil
  ) {
    api.dispose()
    api = makeAPI(
      nativeExecutor: nativeExecutor,
      progressExecutor: progressExecutor,
      progressHandler: progressHandler
    )
  }

  private func assertNativeTerminal(
    _ result: LocalImageProviderResult,
    mapsTo expectedError: LocalImageErrorCode,
    requestId: Int64
  ) {
    let recorder = request(id: requestId)
    provider.emit(result, for: provider.onlyStartedRequestID)

    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get().error, expectedError)
    XCTAssertEqual(api.activeRequestCount(for: .thumbnail), 0)
  }

  private func completeAllStartedRequests() {
    var completed = Set<LocalImageNativeRequestID>()
    while true {
      let pending = provider.startedRequestIDs.filter { !completed.contains($0) }
      guard let requestID = pending.first else { return }
      completed.insert(requestID)
      provider.emit(.missing, for: requestID)
    }
  }
}

private final class ImmediateLocalImageExecutor: LocalImageExecuting {
  func execute(_ action: @escaping @Sendable () -> Void) {
    action()
  }
}

private final class ManualLocalImageExecutor: LocalImageExecuting, @unchecked Sendable {
  private let actions = Mutex<[@Sendable () -> Void]>([])

  func execute(_ action: @escaping @Sendable () -> Void) {
    actions.withLock { $0.append(action) }
  }

  func runNext() {
    let action = actions.withLock { actions -> (@Sendable () -> Void)? in
      guard !actions.isEmpty else { return nil }
      return actions.removeFirst()
    }
    action?()
  }

  func runAll() {
    while actions.withLock({ !$0.isEmpty }) {
      runNext()
    }
  }
}

private final class ManualLocalImageTimeoutScheduler: LocalImageTimeoutScheduling,
  @unchecked Sendable
{
  private let scheduler = ManualScheduler()

  func schedule(
    after delay: TimeInterval,
    action: @escaping @Sendable () -> Void
  ) -> any LocalImageScheduledTask {
    scheduler.schedule(after: delay, action)
  }

  func advance(by interval: TimeInterval) {
    scheduler.advance(by: interval)
  }
}

extension ScheduledTask: LocalImageScheduledTask, @unchecked Sendable {}

private final class ControllableLocalImageProvider: LocalImageProviding, @unchecked Sendable {
  struct StartedRequest {
    let assetID: String
    let options: LocalImageProviderOptions
    let progress: ((Double) -> Void)?
    let completion: (LocalImageProviderResult) -> Void
    let nativeID: LocalImageNativeRequestID

    var hasProgressHandler: Bool { progress != nil }
  }

  private let state = Mutex(State())

  private struct State: @unchecked Sendable {
    var nextRequestID: LocalImageNativeRequestID = 1
    var started: [StartedRequest] = []
    var cancelled: [LocalImageNativeRequestID] = []
    var beforeReturningRequestID: ((LocalImageNativeRequestID) -> Void)?
  }

  var nextRequestID: LocalImageNativeRequestID {
    get { state.withLock { $0.nextRequestID } }
    set { state.withLock { $0.nextRequestID = newValue } }
  }

  var beforeReturningRequestID: ((LocalImageNativeRequestID) -> Void)? {
    get { state.withLock { $0.beforeReturningRequestID } }
    set { state.withLock { $0.beforeReturningRequestID = newValue } }
  }

  var startedRequestIDs: [LocalImageNativeRequestID] {
    state.withLock { $0.started.map(\.nativeID) }
  }

  var onlyStartedRequestID: LocalImageNativeRequestID {
    let requestIDs = startedRequestIDs
    precondition(requestIDs.count == 1, "Expected exactly one started request")
    return requestIDs[0]
  }

  var cancelledRequestIDs: [LocalImageNativeRequestID] {
    state.withLock { $0.cancelled }
  }

  func requestImage(
    assetID: String,
    options: LocalImageProviderOptions,
    progress: ((Double) -> Void)?,
    completion: @escaping (LocalImageProviderResult) -> Void
  ) -> LocalImageNativeRequestID {
    let (requestID, beforeReturning) = state.withLock { state in
      let requestID = state.nextRequestID
      if requestID != localImageInvalidNativeRequestID {
        state.nextRequestID += 1
      }
      state.started.append(
        StartedRequest(
          assetID: assetID,
          options: options,
          progress: progress,
          completion: completion,
          nativeID: requestID
        )
      )
      return (requestID, state.beforeReturningRequestID)
    }
    beforeReturning?(requestID)
    return requestID
  }

  func cancelImageRequest(_ requestID: LocalImageNativeRequestID) {
    state.withLock { $0.cancelled.append(requestID) }
  }

  func emit(_ result: LocalImageProviderResult, for requestID: LocalImageNativeRequestID) {
    let completion = state.withLock {
      $0.started.first { $0.nativeID == requestID }?.completion
    }
    completion?(result)
  }

  func emitProgress(_ fraction: Double, for requestID: LocalImageNativeRequestID) {
    let progress = state.withLock {
      $0.started.first { $0.nativeID == requestID }?.progress
    }
    progress?(fraction)
  }

  func startedCount(for kind: LocalImageRequestKind) -> Int {
    state.withLock { $0.started.filter { $0.options.kind == kind }.count }
  }

  func startedRequest(forAssetID assetID: String) -> StartedRequest? {
    state.withLock { $0.started.first { $0.assetID == assetID } }
  }
}

private final class RecordingLocalImagePayloadAllocator: LocalImagePayloadAllocating,
  @unchecked Sendable
{
  private let state = Mutex(State())

  private struct State: @unchecked Sendable {
    var allocationCount = 0
    var releaseCount = 0
    var onAllocate: (() -> Void)?
  }

  var allocationCount: Int { state.withLock { $0.allocationCount } }
  var releaseCount: Int { state.withLock { $0.releaseCount } }

  var onAllocate: (() -> Void)? {
    get { state.withLock { $0.onAllocate } }
    set { state.withLock { $0.onAllocate = newValue } }
  }

  func allocate(_ source: LocalImageProviderPayload) -> LocalImageAllocatedPayload? {
    let onAllocate = state.withLock { state in
      state.allocationCount += 1
      return state.onAllocate
    }
    onAllocate?()
    return LocalImageAllocatedPayload(
      payload: LocalImagePayload(pointer: 0, length: 1),
      release: { [weak self] in
        self?.state.withLock { $0.releaseCount += 1 }
      }
    )
  }
}

private final class ProgressRecorder: @unchecked Sendable {
  private let state = Mutex<[LocalImageProgress]>([])

  var values: [LocalImageProgress] { state.withLock { $0 } }

  func record(_ progress: LocalImageProgress) {
    state.withLock { $0.append(progress) }
  }
}
