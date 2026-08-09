import Foundation
import OSLog

enum PerformanceRequestKind: Int64, Hashable, Sendable {
  case localThumbnail = 0
  case localOriginal = 1
  case remoteThumbnail = 2
  case remoteOriginal = 3
  case localOriginalExport = 4
  case remoteOriginalExport = 5
}

enum PerformancePermitKind: Int64, Hashable, Sendable {
  case localThumbnail = 0
  case localOriginal = 1
  case originalExport = 2
}

protocol PerformanceInterval: AnyObject, Sendable {
  func finish()
}

protocol PerformanceRecording: AnyObject, Sendable {
  func recordTimelineInteractive()
  func beginRequest(_ kind: PerformanceRequestKind) -> (any PerformanceInterval)?
  func beginPermit(_ kind: PerformancePermitKind) -> (any PerformanceInterval)?
  func beginTemporary() -> (any PerformanceInterval)?
}

enum PerformanceTelemetry {
  static let shared: any PerformanceRecording = SignpostPerformanceRecorder()
}

final class SignpostPerformanceRecorder: PerformanceRecording, @unchecked Sendable {
  private static let log = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "app.immich",
    category: .pointsOfInterest
  )

  func recordTimelineInteractive() {
    guard Self.log.signpostsEnabled else { return }
    os_signpost(.event, log: Self.log, name: "TimelineInteractive")
  }

  func beginRequest(_ kind: PerformanceRequestKind) -> (any PerformanceInterval)? {
    switch kind {
    case .localThumbnail:
      begin(name: "LocalThumbnailRequest", value: kind.rawValue)
    case .localOriginal:
      begin(name: "LocalOriginalRequest", value: kind.rawValue)
    case .remoteThumbnail:
      begin(name: "RemoteThumbnailRequest", value: kind.rawValue)
    case .remoteOriginal:
      begin(name: "RemoteOriginalRequest", value: kind.rawValue)
    case .localOriginalExport:
      begin(name: "LocalOriginalExportRequest", value: kind.rawValue)
    case .remoteOriginalExport:
      begin(name: "RemoteOriginalExportRequest", value: kind.rawValue)
    }
  }

  func beginPermit(_ kind: PerformancePermitKind) -> (any PerformanceInterval)? {
    switch kind {
    case .localThumbnail:
      begin(name: "LocalThumbnailPermit", value: kind.rawValue)
    case .localOriginal:
      begin(name: "LocalOriginalPermit", value: kind.rawValue)
    case .originalExport:
      begin(name: "OriginalExportPermit", value: kind.rawValue)
    }
  }

  func beginTemporary() -> (any PerformanceInterval)? {
    begin(name: "OriginalExportTemporary", value: 1)
  }

  private func begin(
    name: StaticString,
    value: Int64
  ) -> (any PerformanceInterval)? {
    guard Self.log.signpostsEnabled else { return nil }
    let signpostID = OSSignpostID(log: Self.log)
    os_signpost(
      .begin,
      log: Self.log,
      name: name,
      signpostID: signpostID,
      "kind=%{public}lld",
      value
    )
    return IdempotentPerformanceInterval {
      os_signpost(
        .end,
        log: Self.log,
        name: name,
        signpostID: signpostID,
        "kind=%{public}lld",
        value
      )
    }
  }
}

final class IdempotentPerformanceInterval: PerformanceInterval, @unchecked Sendable {
  init(finish: @escaping @Sendable () -> Void) {
    finishAction = Mutex(finish)
  }

  private let finishAction: Mutex<(@Sendable () -> Void)?>

  func finish() {
    let action = finishAction.withLock { action in
      defer { action = nil }
      return action
    }
    action?()
  }
}
