import XCTest

@testable import Runner

final class PerformanceRecorderTests: XCTestCase {
  func testIntervalFinishIsIdempotent() {
    let recorder = RecordingPerformanceRecorder()
    let interval = recorder.beginRequest(.localThumbnail)

    interval?.finish()
    interval?.finish()

    XCTAssertEqual(recorder.startedCount(.request(.localThumbnail)), 1)
    XCTAssertEqual(recorder.finishedCount(.request(.localThumbnail)), 1)
    XCTAssertEqual(recorder.activeCount(.request(.localThumbnail)), 0)
  }

  func testTimelineInteractiveIsProcessWideAcrossApiInstances() {
    let recorder = RecordingPerformanceRecorder()
    let processGate = PerformanceOnce()
    let first = PerformanceApiImpl(recorder: recorder, timelineInteractive: processGate)
    let second = PerformanceApiImpl(recorder: recorder, timelineInteractive: processGate)

    DispatchQueue.concurrentPerform(iterations: 100) { iteration in
      if iteration.isMultiple(of: 2) {
        first.timelineInteractive()
      } else {
        second.timelineInteractive()
      }
    }

    XCTAssertEqual(recorder.timelineInteractiveCount, 1)
  }

  func testOriginalPermitStartsOnlyWhenGrantedAndFinishesOnIdempotentRelease() {
    let recorder = RecordingPerformanceRecorder()
    let pool = OriginalExportPermitPool(limit: 1, performanceRecorder: recorder)
    let executor = ImmediatePerformanceTestIOExecutor()
    let registry = OriginalExportLeaseRegistry(ioExecutor: executor)
    let first = makeOperation(id: 1, executor: executor, registry: registry)
    let second = makeOperation(id: 2, executor: executor, registry: registry)
    var firstPermit: OriginalExportPermit?
    var secondPermit: OriginalExportPermit?

    pool.enqueue(operation: first) { firstPermit = $0 }
    pool.enqueue(operation: second) { secondPermit = $0 }

    XCTAssertNotNil(firstPermit)
    XCTAssertNil(secondPermit)
    XCTAssertEqual(recorder.startedCount(.permit(.originalExport)), 1)

    firstPermit?.release()
    firstPermit?.release()
    XCTAssertNotNil(secondPermit)
    XCTAssertEqual(recorder.startedCount(.permit(.originalExport)), 2)
    XCTAssertEqual(recorder.finishedCount(.permit(.originalExport)), 1)

    secondPermit?.release()
    secondPermit?.release()
    XCTAssertEqual(recorder.finishedCount(.permit(.originalExport)), 2)
  }

  private func makeOperation(
    id: Int64,
    executor: any OriginalExportIOExecuting,
    registry: OriginalExportLeaseRegistry
  ) -> OriginalExportOperation {
    OriginalExportOperation(
      id: id,
      ioExecutor: executor,
      leaseRegistry: registry,
      onFinalized: { _ in },
      completion: { _ in }
    )
  }
}

private final class ImmediatePerformanceTestIOExecutor: OriginalExportIOExecuting {
  func execute(_ action: @escaping @Sendable () -> Void) {
    action()
  }
}
