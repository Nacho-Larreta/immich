import Accelerate
import Flutter
import MobileCoreServices
import Photos

class LocalImageApiImpl: LocalImageApi {
  private static let imageManager = PHImageManager.default()
  private static let fetchOptions = {
    let fetchOptions = PHFetchOptions()
    fetchOptions.fetchLimit = 1
    fetchOptions.wantsIncrementalChangeDetails = false
    return fetchOptions
  }()
  private static let requestOptions = {
    let requestOptions = PHImageRequestOptions()
    requestOptions.isNetworkAccessAllowed = true
    requestOptions.deliveryMode = .highQualityFormat
    requestOptions.resizeMode = .fast
    requestOptions.isSynchronous = true
    requestOptions.version = .current
    return requestOptions
  }()

  private static let registry = RequestRegistry<ImageRequest<LocalImageResult>>()
  private static let rgbaFormat = vImage_CGImageFormat(
    bitsPerComponent: 8,
    bitsPerPixel: 32,
    colorSpace: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    renderingIntent: .defaultIntent
  )!
  private static let assetCache = {
    let assetCache = NSCache<NSString, PHAsset>()
    assetCache.countLimit = 10000
    return assetCache
  }()

  private let flutterApi: LocalImageFlutterApi

  init(flutterApi: LocalImageFlutterApi) {
    self.flutterApi = flutterApi
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
    let request = ImageRequest<LocalImageResult>(completion: completion)
    let operation = BlockOperation {
      if request.isCancelled {
        return request.completion(.success(Self.failure(.cancelled)))
      }

      guard let asset = Self.requestAsset(assetId: input.assetId) else {
        Self.registry.remove(requestId: input.requestId)
        return request.completion(.success(Self.failure(.mediaNotLocal)))
      }

      if request.isCancelled {
        return request.completion(.success(Self.failure(.cancelled)))
      }

      if input.preferEncoded {
        return Self.requestEncodedImage(asset: asset, input: input, request: request)
      }

      Self.requestDecodedImage(asset: asset, input: input, request: request)
    }

    Self.registry.add(requestId: input.requestId, request: request)
    ImageProcessing.queue.addOperation(operation)
  }

  func cancelRequest(requestId: Int64) {
    Self.registry.remove(requestId: requestId)?.cancel()
  }

  func cancelAll() {
    Self.registry.removeAll().forEach { $0.cancel() }
  }

  func dispose() {
    cancelAll()
  }

  private static func requestEncodedImage(
    asset: PHAsset,
    input: LocalImageRequest,
    request: ImageRequest<LocalImageResult>
  ) {
    let dataOptions = PHImageRequestOptions()
    dataOptions.isNetworkAccessAllowed = true
    dataOptions.isSynchronous = true
    dataOptions.version = .current

    var imageData: Data?
    imageManager.requestImageDataAndOrientation(
      for: asset,
      options: dataOptions,
      resultHandler: { data, _, _, _ in imageData = data }
    )

    if request.isCancelled {
      return request.completion(.success(failure(.cancelled)))
    }

    guard let data = imageData else {
      registry.remove(requestId: input.requestId)
      return request.completion(.success(failure(.mediaNotLocal)))
    }

    let length = data.count
    let pointer = malloc(length)!
    data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: length)

    if request.isCancelled {
      free(pointer)
      return request.completion(.success(failure(.cancelled)))
    }

    registry.remove(requestId: input.requestId)
    request.completion(
      .success(
        success(
          LocalImagePayload(
            pointer: Int64(Int(bitPattern: pointer)),
            length: Int64(length)
          )
        )
      )
    )
  }

  private static func requestDecodedImage(
    asset: PHAsset,
    input: LocalImageRequest,
    request: ImageRequest<LocalImageResult>
  ) {
    var image: UIImage?
    imageManager.requestImage(
      for: asset,
      targetSize: input.width > 0 && input.height > 0
        ? CGSize(width: Double(input.width), height: Double(input.height))
        : PHImageManagerMaximumSize,
      contentMode: .aspectFill,
      options: requestOptions,
      resultHandler: { fetchedImage, _ in image = fetchedImage }
    )

    if request.isCancelled {
      return request.completion(.success(failure(.cancelled)))
    }

    guard let image, let cgImage = image.cgImage else {
      registry.remove(requestId: input.requestId)
      return request.completion(.success(failure(.mediaNotLocal)))
    }

    do {
      let buffer = try vImage_Buffer(cgImage: cgImage, format: rgbaFormat)
      if request.isCancelled {
        buffer.free()
        return request.completion(.success(failure(.cancelled)))
      }

      registry.remove(requestId: input.requestId)
      request.completion(
        .success(
          success(
            LocalImagePayload(
              pointer: Int64(Int(bitPattern: buffer.data)),
              width: Int64(buffer.width),
              height: Int64(buffer.height),
              rowBytes: Int64(buffer.rowBytes)
            )
          )
        )
      )
    } catch {
      registry.remove(requestId: input.requestId)
      request.completion(.success(failure(.mediaNotLocal)))
    }
  }

  private static func success(_ payload: LocalImagePayload) -> LocalImageResult {
    LocalImageResult(payload: payload, error: nil)
  }

  private static func failure(_ error: LocalImageErrorCode) -> LocalImageResult {
    LocalImageResult(payload: nil, error: error)
  }

  private static func requestAsset(assetId: String) -> PHAsset? {
    if let cached = assetCache.object(forKey: assetId as NSString) {
      return cached
    }

    guard let asset = PHAsset.fetchAssets(
      withLocalIdentifiers: [assetId],
      options: fetchOptions
    ).firstObject else {
      return nil
    }
    assetCache.setObject(asset, forKey: assetId as NSString)
    return asset
  }
}
