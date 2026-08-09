import Flutter
import Foundation

final class OriginalExportApiImpl: OriginalExportApi {
  private struct Lifecycle {
    var disposed = false
    var activeRequestIds: Set<Int64> = []
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
        challengeHandler: { session, challenge, task, completion in
          URLSessionManager.shared.delegate.handleChallenge(
            session,
            challenge,
            completion,
            task: task
          )
        },
        fileStore: fileStore,
        ioExecutor: ioExecutor,
        pool: pool,
        leaseRegistry: leaseRegistry,
        progressHandler: progress
      ),
      leaseRegistry: leaseRegistry
    )
  }

  init(
    localExporter: LocalOriginalExporter,
    remoteExporter: RemoteOriginalExporter,
    leaseRegistry: OriginalExportLeaseRegistry
  ) {
    self.localExporter = localExporter
    self.remoteExporter = remoteExporter
    self.leaseRegistry = leaseRegistry
  }

  private let localExporter: LocalOriginalExporter
  private let remoteExporter: RemoteOriginalExporter
  private let leaseRegistry: OriginalExportLeaseRegistry
  private let lifecycle = Mutex(Lifecycle())

  func exportLocal(
    request: LocalOriginalExportRequest,
    completion: @escaping (Result<OriginalExportResult, any Error>) -> Void
  ) {
    guard begin(requestId: request.requestId) else {
      completion(.success(.failure(.cancelled)))
      return
    }
    localExporter.export(request: request) { [weak self] result in
      self?.finish(requestId: request.requestId)
      completion(result)
    }
  }

  func exportRemote(
    request: RemoteOriginalExportRequest,
    completion: @escaping (Result<OriginalExportResult, any Error>) -> Void
  ) {
    guard begin(requestId: request.requestId) else {
      completion(.success(.failure(.cancelled)))
      return
    }
    remoteExporter.export(request: request) { [weak self] result in
      self?.finish(requestId: request.requestId)
      completion(result)
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

  private func begin(requestId: Int64) -> Bool {
    lifecycle.withLock { lifecycle in
      guard !lifecycle.disposed, !lifecycle.activeRequestIds.contains(requestId) else {
        return false
      }
      lifecycle.activeRequestIds.insert(requestId)
      return true
    }
  }

  private func finish(requestId: Int64) {
    lifecycle.withLock { lifecycle in
      _ = lifecycle.activeRequestIds.remove(requestId)
    }
  }
}
