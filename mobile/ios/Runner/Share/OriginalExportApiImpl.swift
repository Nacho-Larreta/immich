import Flutter
import Foundation

protocol LocalOriginalExporting: AnyObject {
  func export(
    request: LocalOriginalExportRequest,
    completion: @escaping (Result<OriginalExportResult, any Error>) -> Void
  )
  func cancel(requestId: Int64, completion: @escaping () -> Void)
  func cancelAll(completion: @escaping () -> Void)
  func dispose(completion: @escaping () -> Void)
}

protocol RemoteOriginalExporting: AnyObject {
  func export(
    request: RemoteOriginalExportRequest,
    completion: @escaping (Result<OriginalExportResult, any Error>) -> Void
  )
  func cancel(requestId: Int64, completion: @escaping () -> Void)
  func cancelAll(completion: @escaping () -> Void)
  func dispose(completion: @escaping () -> Void)
}

extension LocalOriginalExporter: LocalOriginalExporting {}
extension RemoteOriginalExporter: RemoteOriginalExporting {}

final class OriginalExportApiImpl: OriginalExportApi {
  private struct ActiveRequest {
    let interval: (any PerformanceInterval)?
  }

  private struct Lifecycle {
    var disposed = false
    var activeRequests: [Int64: ActiveRequest] = [:]
  }

  convenience init(flutterApi: OriginalExportFlutterApi) {
    let ioExecutor = SerialOriginalExportIOExecutor()
    let pool = OriginalExportPermitPool(limit: 2)
    let leaseRegistry = OriginalExportLeaseRegistry(ioExecutor: ioExecutor)
    let fileStore = TemporaryOriginalExportFileStore()
    OriginalExportLeaseJanitor.schedule(store: fileStore, ioExecutor: ioExecutor)
    let progress: (OriginalExportProgress) -> Void = { progress in
      DispatchQueue.main.async {
        flutterApi.onProgress(progress: progress) { _ in }
      }
    }
    self.init(
      localExporter: LocalOriginalExporter(
        fileStore: fileStore,
        ioExecutor: ioExecutor,
        pool: pool,
        leaseRegistry: leaseRegistry,
        progressHandler: progress
      ),
      remoteExporter: RemoteOriginalExporter(
        sessionConfiguration: URLSessionManager.shared.session.configuration,
        cookieStorage: URLSessionManager.cookieStorage,
        challengeHandler: { session, challenge, task, authorization, completion in
          URLSessionManager.shared.delegate.handleChallenge(
            session,
            challenge,
            completion,
            task: task,
            authorization: authorization
          )
        },
        fileStore: fileStore,
        ioExecutor: ioExecutor,
        pool: pool,
        leaseRegistry: leaseRegistry,
        progressHandler: progress
      ),
      leaseRegistry: leaseRegistry,
      performanceRecorder: PerformanceTelemetry.shared
    )
  }

  init(
    localExporter: any LocalOriginalExporting,
    remoteExporter: any RemoteOriginalExporting,
    leaseRegistry: OriginalExportLeaseRegistry,
    performanceRecorder: any PerformanceRecording = PerformanceTelemetry.shared
  ) {
    self.localExporter = localExporter
    self.remoteExporter = remoteExporter
    self.leaseRegistry = leaseRegistry
    self.performanceRecorder = performanceRecorder
  }

  private let localExporter: any LocalOriginalExporting
  private let remoteExporter: any RemoteOriginalExporting
  private let leaseRegistry: OriginalExportLeaseRegistry
  private let performanceRecorder: any PerformanceRecording
  private let lifecycle = Mutex(Lifecycle())

  func exportLocal(
    request: LocalOriginalExportRequest,
    completion: @escaping (Result<OriginalExportResult, any Error>) -> Void
  ) {
    guard begin(requestId: request.requestId, kind: .localOriginalExport) else {
      completion(.success(.failure(.cancelled)))
      return
    }
    localExporter.export(request: request) { [weak self] result in
      guard let self else {
        completion(result)
        return
      }
      self.complete(requestId: request.requestId, result: result, completion: completion)
    }
  }

  func exportRemote(
    request: RemoteOriginalExportRequest,
    completion: @escaping (Result<OriginalExportResult, any Error>) -> Void
  ) {
    guard begin(requestId: request.requestId, kind: .remoteOriginalExport) else {
      completion(.success(.failure(.cancelled)))
      return
    }
    remoteExporter.export(request: request) { [weak self] result in
      guard let self else {
        completion(result)
        return
      }
      self.complete(requestId: request.requestId, result: result, completion: completion)
    }
  }

  func cancelRequest(
    requestId: Int64,
    completion: @escaping (Result<Void, any Error>) -> Void
  ) {
    let group = DispatchGroup()
    group.enter()
    localExporter.cancel(requestId: requestId, completion: group.leave)
    group.enter()
    remoteExporter.cancel(requestId: requestId, completion: group.leave)
    group.notify(queue: .global(qos: .userInitiated)) { completion(.success(())) }
  }

  func cancelAll(completion: @escaping (Result<Void, any Error>) -> Void) {
    let group = DispatchGroup()
    group.enter()
    localExporter.cancelAll(completion: group.leave)
    group.enter()
    remoteExporter.cancelAll(completion: group.leave)
    group.notify(queue: .global(qos: .userInitiated)) { completion(.success(())) }
  }

  func dispose(completion: @escaping (Result<Void, any Error>) -> Void) {
    lifecycle.withLock { $0.disposed = true }
    let group = DispatchGroup()
    group.enter()
    localExporter.dispose(completion: group.leave)
    group.enter()
    remoteExporter.dispose(completion: group.leave)
    group.notify(queue: .global(qos: .userInitiated)) { completion(.success(())) }
  }

  func releaseLease(
    leaseToken: String,
    completion: @escaping (Result<OriginalExportReleaseResult, any Error>) -> Void
  ) {
    leaseRegistry.release(token: leaseToken) { result in
      completion(.success(result))
    }
  }

  private func begin(
    requestId: Int64,
    kind: PerformanceRequestKind
  ) -> Bool {
    lifecycle.withLock { lifecycle in
      guard !lifecycle.disposed, lifecycle.activeRequests[requestId] == nil else {
        return false
      }
      lifecycle.activeRequests[requestId] = ActiveRequest(
        interval: performanceRecorder.beginRequest(kind)
      )
      return true
    }
  }

  private func complete(
    requestId: Int64,
    result: Result<OriginalExportResult, any Error>,
    completion: (Result<OriginalExportResult, any Error>) -> Void
  ) {
    let request = lifecycle.withLock { lifecycle in
      lifecycle.activeRequests.removeValue(forKey: requestId)
    }
    guard let request else { return }
    request.interval?.finish()
    completion(result)
  }
}
