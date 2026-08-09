import Foundation

@testable import Runner

enum RecordedPerformanceInterval: Hashable {
  case request(PerformanceRequestKind)
  case permit(PerformancePermitKind)
  case temporary
}

final class RecordingPerformanceRecorder: PerformanceRecording, @unchecked Sendable {
  private struct State {
    var timelineInteractiveCount = 0
    var started: [RecordedPerformanceInterval: Int] = [:]
    var finished: [RecordedPerformanceInterval: Int] = [:]
    var active: [RecordedPerformanceInterval: Int] = [:]
  }

  private let state = Mutex(State())

  var timelineInteractiveCount: Int { state.withLock { $0.timelineInteractiveCount } }

  func startedCount(_ interval: RecordedPerformanceInterval) -> Int {
    state.withLock { $0.started[interval, default: 0] }
  }

  func finishedCount(_ interval: RecordedPerformanceInterval) -> Int {
    state.withLock { $0.finished[interval, default: 0] }
  }

  func activeCount(_ interval: RecordedPerformanceInterval) -> Int {
    state.withLock { $0.active[interval, default: 0] }
  }

  func recordTimelineInteractive() {
    state.withLock { $0.timelineInteractiveCount += 1 }
  }

  func beginRequest(_ kind: PerformanceRequestKind) -> (any PerformanceInterval)? {
    begin(.request(kind))
  }

  func beginPermit(_ kind: PerformancePermitKind) -> (any PerformanceInterval)? {
    begin(.permit(kind))
  }

  func beginTemporary() -> (any PerformanceInterval)? {
    begin(.temporary)
  }

  private func begin(_ interval: RecordedPerformanceInterval) -> any PerformanceInterval {
    state.withLock { state in
      state.started[interval, default: 0] += 1
      state.active[interval, default: 0] += 1
    }
    return IdempotentPerformanceInterval { [weak self] in
      self?.state.withLock { state in
        state.finished[interval, default: 0] += 1
        state.active[interval, default: 0] -= 1
      }
    }
  }
}
