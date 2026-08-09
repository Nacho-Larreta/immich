import Foundation
import Photos

final class LocalOriginalResource: @unchecked Sendable {
  init(identifier: String, originalFilename: String, nativeResource: AnyObject? = nil) {
    self.identifier = identifier
    self.originalFilename = originalFilename
    self.nativeResource = nativeResource
  }

  let identifier: String
  let originalFilename: String
  let nativeResource: AnyObject?
}

protocol LocalOriginalResourceProviding: AnyObject {
  func resolveResource(assetId: String) -> Result<LocalOriginalResource, OriginalExportFailure>

  func requestData(
    for resource: LocalOriginalResource,
    allowsNetworkAccess: Bool,
    progress: ((Double) -> Void)?,
    dataReceived: @escaping (Data) -> Void,
    completion: @escaping (Error?) -> Void
  ) -> PHAssetResourceDataRequestID

  func cancel(_ requestId: PHAssetResourceDataRequestID)
}

final class PhotoKitOriginalResourceProvider: LocalOriginalResourceProviding {
  private let manager: PHAssetResourceManager

  init(manager: PHAssetResourceManager = .default()) {
    self.manager = manager
  }

  func resolveResource(assetId: String) -> Result<LocalOriginalResource, OriginalExportFailure> {
    let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if authorization == .denied || authorization == .restricted {
      return .failure(.unauthorized)
    }
    let options = PHFetchOptions()
    options.fetchLimit = 1
    options.wantsIncrementalChangeDetails = false
    guard
      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: options)
        .firstObject
    else { return .failure(.assetMissing) }
    guard let resource = Self.primaryResource(for: asset) else {
      return .failure(.mediaNotLocal)
    }
    return .success(
      LocalOriginalResource(
        identifier: assetId,
        originalFilename: resource.originalFilename,
        nativeResource: resource
      )
    )
  }

  func requestData(
    for resource: LocalOriginalResource,
    allowsNetworkAccess: Bool,
    progress: ((Double) -> Void)?,
    dataReceived: @escaping (Data) -> Void,
    completion: @escaping (Error?) -> Void
  ) -> PHAssetResourceDataRequestID {
    guard let nativeResource = resource.nativeResource as? PHAssetResource else {
      completion(OriginalExportFailure.mediaNotLocal)
      return PHAssetResourceDataRequestID(0)
    }
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = allowsNetworkAccess
    if allowsNetworkAccess {
      options.progressHandler = { fraction in progress?(fraction) }
    }
    return manager.requestData(
      for: nativeResource,
      options: options,
      dataReceivedHandler: dataReceived,
      completionHandler: completion
    )
  }

  func cancel(_ requestId: PHAssetResourceDataRequestID) {
    manager.cancelDataRequest(requestId)
  }

  static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
    let resources = PHAssetResource.assetResources(for: asset)
    let priority: [PHAssetResourceType]
    switch asset.mediaType {
    case .image:
      // A live photo is exported as its primary still image. Paired video export is a separate product decision.
      priority = [.fullSizePhoto, .photo, .alternatePhoto]
    case .video:
      priority = [.fullSizeVideo, .video, .fullSizePairedVideo]
    default:
      return nil
    }
    for type in priority {
      if let resource = resources.first(where: { $0.type == type }) { return resource }
    }
    return nil
  }
}

final class LocalOriginalExporter: @unchecked Sendable {
  struct Deadlines: Sendable {
    // Fixed deadlines bound PhotoKit and file resources even when iCloud progress stalls.
    static let standard = Self(local: 15, iCloud: 300)

    let local: TimeInterval
    let iCloud: TimeInterval

    init(local: TimeInterval, iCloud: TimeInterval) {
      precondition(local > 0)
      precondition(iCloud > 0)
      self.local = local
      self.iCloud = iCloud
    }

    func timeout(for policy: OriginalExportPolicy) -> TimeInterval {
      policy == .allowICloud ? iCloud : local
    }
  }

  init(
    provider: any LocalOriginalResourceProviding = PhotoKitOriginalResourceProvider(),
    fileStore: any OriginalExportFileStoring = TemporaryOriginalExportFileStore(),
    ioExecutor: any OriginalExportIOExecuting = SerialOriginalExportIOExecutor(),
    scheduler: any OriginalExportTimeoutScheduling = DispatchOriginalExportTimeoutScheduler(),
    pool: OriginalExportPermitPool = OriginalExportPermitPool(limit: 2),
    leaseRegistry: OriginalExportLeaseRegistry? = nil,
    deadlines: Deadlines = .standard,
    workerQueue: DispatchQueue = DispatchQueue(
      label: "app.immich.local-original-export",
      qos: .userInitiated,
      attributes: .concurrent
    ),
    progressHandler: @escaping (OriginalExportProgress) -> Void
  ) {
    self.provider = provider
    self.fileStore = fileStore
    self.ioExecutor = ioExecutor
    self.scheduler = scheduler
    self.pool = pool
    self.leaseRegistry = leaseRegistry ?? OriginalExportLeaseRegistry(ioExecutor: ioExecutor)
    self.deadlines = deadlines
    self.workerQueue = workerQueue
    self.progressHandler = progressHandler
  }

  private let provider: any LocalOriginalResourceProviding
  private let fileStore: any OriginalExportFileStoring
  private let ioExecutor: any OriginalExportIOExecuting
  private let scheduler: any OriginalExportTimeoutScheduling
  private let pool: OriginalExportPermitPool
  private let leaseRegistry: OriginalExportLeaseRegistry
  private let deadlines: Deadlines
  private let workerQueue: DispatchQueue
  private let progressHandler: (OriginalExportProgress) -> Void
  private let registry = RequestRegistry<OriginalExportOperation>()
  private let lifecycle = Mutex(false)

  var activeCount: Int { pool.activeCount }
  var peakActiveCount: Int { pool.peakActiveCount }

  func export(
    request: LocalOriginalExportRequest,
    completion: @escaping (Result<OriginalExportResult, any Error>) -> Void
  ) {
    let operation = OriginalExportOperation(
      id: request.requestId,
      ioExecutor: ioExecutor,
      leaseRegistry: leaseRegistry,
      waitsForNativeCompletionOnCancel: false,
      onFinalized: { [weak self] operation in
        self?.registry.remove(requestId: operation.id, matching: operation)
      },
      completion: completion
    )
    let accepted = lifecycle.withLock { disposed in
      guard !disposed else { return false }
      return registry.addIfAbsent(requestId: request.requestId, request: operation)
    }
    guard accepted else {
      completion(.success(.failure(.cancelled)))
      return
    }

    pool.enqueue(operation: operation) { [weak self, weak operation] permit in
      guard let self, let operation else {
        permit.release()
        return
      }
      guard operation.begin(with: permit) else {
        permit.release()
        return
      }
      workerQueue.async { [weak self, weak operation] in
        guard let self, let operation else { return }
        self.start(request: request, operation: operation)
      }
    }
  }

  func cancel(requestId: Int64, completion: @escaping () -> Void = {}) {
    guard let operation = registry.value(requestId: requestId) else {
      completion()
      return
    }
    if operation.isQueued { pool.removeQueued(operation) }
    operation.cancel(after: completion)
  }

  func cancelAll(completion: @escaping () -> Void = {}) {
    let operations = registry.all()
    guard !operations.isEmpty else {
      completion()
      return
    }
    let group = DispatchGroup()
    for operation in operations {
      if operation.isQueued { pool.removeQueued(operation) }
      group.enter()
      operation.cancel(after: group.leave)
    }
    group.notify(queue: .global(qos: .userInitiated), execute: completion)
  }

  func dispose(completion: @escaping () -> Void = {}) {
    let shouldCancel = lifecycle.withLock { disposed in
      guard !disposed else { return false }
      disposed = true
      return true
    }
    if shouldCancel {
      cancelAll(completion: completion)
    } else {
      completion()
    }
  }

  private func start(request: LocalOriginalExportRequest, operation: OriginalExportOperation) {
    guard operation.isActive else { return }
    let resource: LocalOriginalResource
    switch provider.resolveResource(assetId: request.assetId) {
    case .success(let resolvedResource):
      resource = resolvedResource
    case .failure(let failure):
      return finish(operation, failure: failure)
    }

    ioExecutor.execute { [weak self, weak operation] in
      guard let self, let operation, operation.isActive else { return }
      self.prepare(request: request, resource: resource, operation: operation)
    }
  }

  private func prepare(
    request: LocalOriginalExportRequest,
    resource: LocalOriginalResource,
    operation: OriginalExportOperation
  ) {
    let destination: OriginalExportDestination
    do {
      destination = try fileStore.createDestination(
        suggestedName: request.suggestedName.isEmpty
          ? resource.originalFilename
          : request.suggestedName
      )
    } catch let failure as OriginalExportFailure {
      return finish(operation, failure: failure)
    } catch {
      return finish(operation, failure: .storageUnavailable)
    }

    let writer = OriginalExportLeaseWriter(destination: destination, store: fileStore)
    guard operation.attach(writer: writer) else {
      writer.cleanup()
      return
    }
    do {
      try writer.open()
    } catch let failure as OriginalExportFailure {
      return finish(operation, failure: failure)
    } catch {
      return finish(operation, failure: .storageUnavailable)
    }

    let timeout = scheduler.schedule(after: deadlines.timeout(for: request.policy)) {
      [weak self, weak operation] in
      guard let self, let operation else { return }
      self.finish(operation, failure: .timeout, cancelNative: true)
    }
    guard operation.attach(timeout: timeout) else {
      timeout.cancel()
      return
    }

    guard operation.beginNativeRequest() else { return }
    let nativeRequestId = provider.requestData(
      for: resource,
      allowsNetworkAccess: request.policy == .allowICloud,
      progress: request.policy == .allowICloud
        ? { [weak self, weak operation] fraction in
          guard let self, let operation, operation.isActive else { return }
          self.progressHandler(
            OriginalExportProgress(
              requestId: request.requestId,
              fraction: min(1, max(0, fraction))
            )
          )
        }
        : nil,
      dataReceived: { [weak self, weak operation, weak writer] data in
        guard let self, let operation, let writer, operation.isActive else { return }
        guard !Thread.isMainThread else {
          self.finish(operation, failure: .writeFailed, cancelNative: true)
          return
        }
        do {
          try writer.append(data)
        } catch {
          self.finish(operation, failure: .writeFailed, cancelNative: true)
        }
      },
      completion: { [weak self, weak operation] error in
        guard let self, let operation else { return }
        let failure = error.map { Self.map($0, policy: request.policy) }
        self.ioExecutor.execute { [weak operation] in
          guard let operation else { return }
          if let failure {
            operation.nativeCompleted(with: failure)
          } else {
            operation.nativeCompleted(with: nil)
          }
        }
      }
    )
    if operation.attachNativeCancel({ [weak provider] in provider?.cancel(nativeRequestId) }) {
      provider.cancel(nativeRequestId)
    }
  }

  private func finish(
    _ operation: OriginalExportOperation,
    failure: OriginalExportFailure,
    cancelNative: Bool = false
  ) {
    operation.fail(failure, cancelNative: cancelNative)
  }

  private static func map(
    _ error: Error,
    policy: OriginalExportPolicy
  ) -> OriginalExportFailure {
    if let failure = error as? OriginalExportFailure { return failure }
    guard let photosError = error as? PHPhotosError else { return .mediaNotLocal }
    switch photosError.code {
    case .userCancelled:
      return .cancelled
    case .networkAccessRequired:
      return .iCloudUnavailable
    default:
      if #available(iOS 15, *) {
        switch photosError.code {
        case .identifierNotFound: return .assetMissing
        case .missingResource: return .mediaNotLocal
        case .notEnoughSpace: return .storageUnavailable
        default: break
        }
      }
      if #available(iOS 16, *), photosError.code == .networkError {
        return policy == .allowICloud ? .serverUnavailable : .iCloudUnavailable
      }
      return .mediaNotLocal
    }
  }
}
