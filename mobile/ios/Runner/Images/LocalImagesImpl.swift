import Accelerate
import CoreGraphics
import Flutter
import Foundation
import Photos
import UIKit

private final class PhotoKitLocalImageProvider: LocalImageProviding {
  private let imageManager: PHImageManager
  private let assetCache: NSCache<NSString, PHAsset>

  init(imageManager: PHImageManager = .default()) {
    self.imageManager = imageManager
    self.assetCache = NSCache()
    self.assetCache.countLimit = 10_000
  }

  func requestImage(
    assetID: String,
    options: LocalImageProviderOptions,
    progress: ((Double) -> Void)?,
    completion: @escaping (LocalImageProviderResult) -> Void
  ) -> LocalImageNativeRequestID {
    guard let asset = asset(for: assetID) else { return localImageInvalidNativeRequestID }
    let requestOptions = makeRequestOptions(options: options, progress: progress)

    if options.preferEncoded {
      return imageManager.requestImageDataAndOrientation(
        for: asset,
        options: requestOptions
      ) { data, _, _, info in
        completion(
          Self.providerResult(
            payload: data.map(LocalImageProviderPayload.encoded),
            info: info
          )
        )
      }
    }

    let targetSize =
      options.width > 0 && options.height > 0
      ? CGSize(width: Double(options.width), height: Double(options.height))
      : PHImageManagerMaximumSize
    return imageManager.requestImage(
      for: asset,
      targetSize: targetSize,
      contentMode: .aspectFill,
      options: requestOptions
    ) { image, info in
      completion(
        Self.providerResult(
          payload: image?.cgImage.map(LocalImageProviderPayload.decoded),
          info: info
        )
      )
    }
  }

  func cancelImageRequest(_ requestID: LocalImageNativeRequestID) {
    imageManager.cancelImageRequest(requestID)
  }

  private func asset(for assetID: String) -> PHAsset? {
    if let cached = assetCache.object(forKey: assetID as NSString) {
      return cached
    }

    let fetchOptions = PHFetchOptions()
    fetchOptions.fetchLimit = 1
    fetchOptions.wantsIncrementalChangeDetails = false
    guard
      let asset = PHAsset.fetchAssets(
        withLocalIdentifiers: [assetID],
        options: fetchOptions
      ).firstObject
    else { return nil }
    assetCache.setObject(asset, forKey: assetID as NSString)
    return asset
  }

  private func makeRequestOptions(
    options: LocalImageProviderOptions,
    progress: ((Double) -> Void)?
  ) -> PHImageRequestOptions {
    let requestOptions = PHImageRequestOptions()
    requestOptions.isSynchronous = options.isSynchronous
    requestOptions.isNetworkAccessAllowed = options.allowsNetworkAccess
    requestOptions.deliveryMode = .highQualityFormat
    requestOptions.resizeMode = .fast
    requestOptions.version = .current
    if options.allowsNetworkAccess {
      requestOptions.progressHandler = { fraction, _, _, _ in progress?(fraction) }
    }
    return requestOptions
  }

  private static func providerResult(
    payload: LocalImageProviderPayload?,
    info: [AnyHashable: Any]?
  ) -> LocalImageProviderResult {
    LocalImageProviderResult(
      payload: payload,
      isDegraded: info?[PHImageResultIsDegradedKey] as? Bool ?? false,
      isCancelled: info?[PHImageCancelledKey] as? Bool ?? false,
      hasError: info?[PHImageErrorKey] != nil,
      isInCloud: info?[PHImageResultIsInCloudKey] as? Bool ?? false
    )
  }
}

private final class VImageLocalImagePayloadAllocator: LocalImagePayloadAllocating {
  private let rgbaFormat = vImage_CGImageFormat(
    bitsPerComponent: 8,
    bitsPerPixel: 32,
    colorSpace: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    renderingIntent: .defaultIntent
  )

  func allocate(_ source: LocalImageProviderPayload) -> LocalImageAllocatedPayload? {
    switch source {
    case .encoded(let data):
      allocateEncoded(data)
    case .decoded(let image):
      allocateDecoded(image)
    }
  }

  private func allocateEncoded(_ data: Data) -> LocalImageAllocatedPayload? {
    guard !data.isEmpty, let pointer = malloc(data.count) else { return nil }
    data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
    return LocalImageAllocatedPayload(
      payload: LocalImagePayload(
        pointer: Int64(Int(bitPattern: pointer)),
        length: Int64(data.count)
      ),
      release: { free(pointer) }
    )
  }

  private func allocateDecoded(_ image: CGImage) -> LocalImageAllocatedPayload? {
    guard let rgbaFormat else { return nil }
    do {
      let buffer = try vImage_Buffer(cgImage: image, format: rgbaFormat)
      let pointer = buffer.data
      return LocalImageAllocatedPayload(
        payload: LocalImagePayload(
          pointer: Int64(Int(bitPattern: pointer)),
          width: Int64(buffer.width),
          height: Int64(buffer.height),
          rowBytes: Int64(buffer.rowBytes)
        ),
        release: { free(pointer) }
      )
    } catch {
      return nil
    }
  }
}

class LocalImageApiImpl: LocalImageApi {
  private static let thumbnailLimit = 4
  private static let originalLimit = 2

  private let provider: any LocalImageProviding
  private let timeoutScheduler: any LocalImageTimeoutScheduling
  private let deadlinePolicy: LocalImageDeadlinePolicy
  private let nativeExecutor: any LocalImageExecuting
  private let progressExecutor: any LocalImageExecuting
  private let payloadAllocator: any LocalImagePayloadAllocating
  private let progressHandler: (LocalImageProgress) -> Void
  private let performanceRecorder: any PerformanceRecording
  private let registry = RequestRegistry<LocalImageOperation>()
  private let thumbnailPool: LocalImagePermitPool
  private let originalPool: LocalImagePermitPool
  private let lifecycle = Mutex(false)

  convenience init(flutterApi: LocalImageFlutterApi) {
    self.init(
      provider: PhotoKitLocalImageProvider(),
      timeoutScheduler: DispatchLocalImageTimeoutScheduler(),
      deadlinePolicy: .standard,
      nativeExecutor: DispatchLocalImageExecutor(
        queue: DispatchQueue(
          label: "app.immich.local-image-requests",
          qos: .userInitiated,
          attributes: .concurrent
        )
      ),
      progressExecutor: DispatchLocalImageExecutor(queue: .main),
      payloadAllocator: VImageLocalImagePayloadAllocator(),
      performanceRecorder: PerformanceTelemetry.shared,
      progressHandler: { progress in
        flutterApi.onProgress(progress: progress) { _ in }
      }
    )
  }

  init(
    provider: any LocalImageProviding,
    timeoutScheduler: any LocalImageTimeoutScheduling,
    deadlinePolicy: LocalImageDeadlinePolicy,
    nativeExecutor: any LocalImageExecuting,
    progressExecutor: any LocalImageExecuting,
    payloadAllocator: any LocalImagePayloadAllocating,
    performanceRecorder: any PerformanceRecording = PerformanceTelemetry.shared,
    progressHandler: @escaping (LocalImageProgress) -> Void
  ) {
    self.provider = provider
    self.timeoutScheduler = timeoutScheduler
    self.deadlinePolicy = deadlinePolicy
    self.nativeExecutor = nativeExecutor
    self.progressExecutor = progressExecutor
    self.payloadAllocator = payloadAllocator
    self.performanceRecorder = performanceRecorder
    self.progressHandler = progressHandler
    self.thumbnailPool = LocalImagePermitPool(
      limit: Self.thumbnailLimit,
      kind: .localThumbnail,
      recorder: performanceRecorder
    )
    self.originalPool = LocalImagePermitPool(
      limit: Self.originalLimit,
      kind: .localOriginal,
      recorder: performanceRecorder
    )
  }

  func getThumbhash(
    request: LocalImageThumbhashRequest,
    completion: @escaping (Result<LocalImageResult, any Error>) -> Void
  ) {
    ImageProcessing.queue.addOperation {
      guard let data = Data(base64Encoded: request.thumbhash) else {
        return completion(.success(Self.failure(.mediaNotLocal)))
      }

      let (width, height, pointer) = thumbHashToRGBA(hash: data)
      completion(
        .success(
          Self.success(
            LocalImagePayload(
              pointer: Int64(Int(bitPattern: pointer.baseAddress)),
              width: Int64(width),
              height: Int64(height),
              rowBytes: Int64(width * 4)
            )
          )
        )
      )
    }
  }

  func requestImage(
    request input: LocalImageRequest,
    completion: @escaping (Result<LocalImageResult, any Error>) -> Void
  ) {
    let operation = LocalImageOperation(
      id: input.requestId,
      kind: input.kind,
      completion: completion
    )
    let accepted = lifecycle.withLock { isDisposed in
      guard !isDisposed else { return false }
      return registry.addIfAbsent(requestId: input.requestId, request: operation)
    }
    guard accepted else {
      completion(.success(Self.failure(.cancelled)))
      return
    }
    operation.markAccepted(by: performanceRecorder)

    permitPool(for: input.kind).enqueue(operation: operation) {
      [weak self, weak operation] permit in
      guard let self, let operation else {
        permit.release()
        return
      }
      guard operation.begin(with: permit) else {
        permit.release()
        return
      }
      self.nativeExecutor.execute { [weak self, weak operation] in
        guard let self, let operation, operation.acceptsCallbacks else { return }
        self.start(input: input, operation: operation)
      }
    }
  }

  func cancelRequest(requestId: Int64) {
    guard let operation = registry.remove(requestId: requestId) else { return }
    cancel(operation)
  }

  func cancelAll() {
    let operations = registry.removeAll()
    thumbnailPool.removeAllQueued()
    originalPool.removeAllQueued()
    operations.forEach(cancel)
  }

  func dispose() {
    let shouldCancel = lifecycle.withLock { isDisposed in
      guard !isDisposed else { return false }
      isDisposed = true
      return true
    }
    if shouldCancel { cancelAll() }
  }

  func activeRequestCount(for kind: LocalImageRequestKind) -> Int {
    permitPool(for: kind).activeCount
  }

  func peakActiveRequestCount(for kind: LocalImageRequestKind) -> Int {
    permitPool(for: kind).peakActiveCount
  }

  private func start(
    input: LocalImageRequest,
    operation: LocalImageOperation
  ) {
    let deadline = deadlinePolicy.deadline(for: input.kind, policy: input.policy)
    let timeout = timeoutScheduler.schedule(after: deadline) { [weak self, weak operation] in
      guard let self, let operation else { return }
      self.finish(operation, result: Self.failure(.timeout), cancelNativeRequest: true)
    }
    guard operation.attachTimeout(timeout) else { return }

    let allowsICloud = input.policy == .allowICloud
    let options = LocalImageProviderOptions(
      width: input.width,
      height: input.height,
      preferEncoded: input.preferEncoded,
      allowsNetworkAccess: allowsICloud,
      isSynchronous: false,
      kind: input.kind
    )
    let progress: ((Double) -> Void)? =
      allowsICloud
      ? { [weak self, weak operation] fraction in
        guard let self, let operation else { return }
        self.reportProgress(fraction, operation: operation)
      }
      : nil
    let nativeRequestID = provider.requestImage(
      assetID: input.assetId,
      options: options,
      progress: progress
    ) { [weak self, weak operation] result in
      guard let self, let operation else { return }
      self.handle(result, operation: operation)
    }

    guard nativeRequestID != localImageInvalidNativeRequestID else {
      if operation.acceptsCallbacks {
        finish(operation, result: Self.failure(.mediaNotLocal))
      }
      return
    }
    if operation.attachNativeRequestID(nativeRequestID) {
      provider.cancelImageRequest(nativeRequestID)
    }
  }

  private func handle(_ result: LocalImageProviderResult, operation: LocalImageOperation) {
    guard !result.isDegraded, operation.acceptsCallbacks else { return }

    if result.isCancelled {
      finish(operation, result: Self.failure(.cancelled))
      return
    }
    if result.hasError {
      finish(operation, result: Self.failure(.mediaNotLocal))
      return
    }
    guard let source = result.payload else {
      finish(
        operation,
        result: Self.failure(result.isInCloud ? .iCloudUnavailable : .mediaNotLocal)
      )
      return
    }
    guard let allocatedPayload = payloadAllocator.allocate(source) else {
      finish(operation, result: Self.failure(.mediaNotLocal))
      return
    }

    let delivered = finish(operation, result: Self.success(allocatedPayload.payload))
    if !delivered { allocatedPayload.release() }
  }

  private func reportProgress(_ fraction: Double, operation: LocalImageOperation) {
    guard fraction.isFinite, operation.acceptsCallbacks else { return }
    let progress = LocalImageProgress(
      requestId: operation.id,
      fraction: min(max(fraction, 0), 1)
    )
    let progressHandler = progressHandler
    progressExecutor.execute { [weak self, weak operation] in
      guard let self, let operation, operation.beginProgressDelivery() else { return }
      progressHandler(progress)
      if let transition = operation.endProgressDelivery() {
        self.complete(operation, transition: transition)
      }
    }
  }

  private func cancel(_ operation: LocalImageOperation) {
    if operation.isQueued {
      permitPool(for: operation.kind).removeQueued(operation: operation)
    }
    finish(operation, result: Self.failure(.cancelled), cancelNativeRequest: true)
  }

  @discardableResult
  private func finish(
    _ operation: LocalImageOperation,
    result: LocalImageResult,
    cancelNativeRequest: Bool = false
  ) -> Bool {
    switch operation.requestFinish(
      result: result,
      cancelNativeRequest: cancelNativeRequest
    ) {
    case .rejected:
      return false
    case .deferred:
      return true
    case .ready(let transition):
      complete(operation, transition: transition)
      return true
    }
  }

  private func complete(
    _ operation: LocalImageOperation,
    transition: LocalImageOperation.TerminalTransition
  ) {
    let resources = transition.resources
    registry.remove(requestId: operation.id, matching: operation)
    resources.timeout?.cancel()
    if transition.cancelNativeRequest,
      let nativeRequestID = resources.nativeRequestID,
      nativeRequestID != localImageInvalidNativeRequestID
    {
      provider.cancelImageRequest(nativeRequestID)
    }
    resources.permit?.release()
    operation.complete(transition.result)
  }

  private func permitPool(for kind: LocalImageRequestKind) -> LocalImagePermitPool {
    switch kind {
    case .thumbnail:
      thumbnailPool
    case .original:
      originalPool
    }
  }

  private static func success(_ payload: LocalImagePayload) -> LocalImageResult {
    LocalImageResult(payload: payload, error: nil)
  }

  private static func failure(_ error: LocalImageErrorCode) -> LocalImageResult {
    LocalImageResult(payload: nil, error: error)
  }
}
