import Foundation

final class PerformanceOnce: @unchecked Sendable {
  private let didRun = Mutex(false)

  func run(_ action: () -> Void) {
    let shouldRun = didRun.withLock { didRun in
      guard !didRun else { return false }
      didRun = true
      return true
    }
    if shouldRun { action() }
  }
}

final class PerformanceApiImpl: PerformanceApi {
  private static let processTimelineInteractive = PerformanceOnce()

  convenience init() {
    self.init(
      recorder: PerformanceTelemetry.shared,
      timelineInteractive: Self.processTimelineInteractive
    )
  }

  init(
    recorder: any PerformanceRecording,
    timelineInteractive: PerformanceOnce
  ) {
    self.recorder = recorder
    self.timelineInteractiveGate = timelineInteractive
  }

  private let recorder: any PerformanceRecording
  private let timelineInteractiveGate: PerformanceOnce

  func timelineInteractive() {
    timelineInteractiveGate.run { recorder.recordTimelineInteractive() }
  }
}
