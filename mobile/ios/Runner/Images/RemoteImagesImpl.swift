import Accelerate
import Flutter
import MobileCoreServices
import Photos

final class RemoteImageOperation: ImageRequest<RemoteImageResult> {
  var task: URLSessionDataTask?
  let id: Int64

  init(
    id: Int64,
    completion: @escaping @Sendable (Result<RemoteImageResult, any Error>) -> Void
  ) {
    self.id = id
    super.init(completion: completion)
  }

  override func cancel() {
    super.cancel()
    task?.cancel()
  }
}

class RemoteImageApiImpl: NSObject, RemoteImageApi {
  private static let registry = RequestRegistry<RemoteImageOperation>()
  private static let rgbaFormat = vImage_CGImageFormat(
    bitsPerComponent: 8,
    bitsPerPixel: 32,
    colorSpace: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    renderingIntent: .perceptual
  )!
  private static let decodeOptions = [
    kCGImageSourceShouldCache: false,
    kCGImageSourceShouldCacheImmediately: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceCreateThumbnailFromImageAlways: true,
  ] as CFDictionary

  func requestImage(
    request input: RemoteImageRequest,
    completion: @escaping (Result<RemoteImageResult, any Error>) -> Void
  ) {
    guard let url = URL(string: input.url) else {
      return completion(.success(Self.failure(.serverUnavailable)))
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.cachePolicy = .returnCacheDataElseLoad

    let request = RemoteImageOperation(id: input.requestId, completion: completion)
    let task = URLSessionManager.shared.session.dataTask(with: urlRequest) {
      data,
      response,
      error in
      Self.handleCompletion(
        request: request,
        encoded: input.preferEncoded,
        data: data,
        response: response,
        error: error
      )
    }

    request.task = task
    Self.registry.add(requestId: input.requestId, request: request)
    task.resume()
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

  func clearCache(
    request: RemoteImageCacheClearRequest,
    completion: @escaping (Result<RemoteImageCacheClearResult, any Error>) -> Void
  ) {
    Task {
      guard let cache = URLSessionManager.shared.session.configuration.urlCache else {
        return completion(
          .success(
            RemoteImageCacheClearResult(
              clearedBytes: nil,
              error: .cacheMiss
            )
          )
        )
      }
      let cacheSize = Int64(cache.currentDiskUsage)
      cache.removeAllCachedResponses()
      completion(
        .success(
          RemoteImageCacheClearResult(
            clearedBytes: cacheSize,
            error: nil
          )
        )
      )
    }
  }

  private static func handleCompletion(
    request: RemoteImageOperation,
    encoded: Bool,
    data: Data?,
    response: URLResponse?,
    error: Error?
  ) {
    if request.isCancelled {
      return request.completion(.success(failure(.cancelled)))
    }

    if error != nil {
      registry.remove(requestId: request.id)
      return request.completion(.success(failure(.serverUnavailable)))
    }

    guard let data else {
      registry.remove(requestId: request.id)
      return request.completion(.success(failure(.serverUnavailable)))
    }

    if encoded {
      return completeEncoded(request: request, data: data)
    }

    completeDecoded(request: request, data: data)
  }

  private static func completeEncoded(request: RemoteImageOperation, data: Data) {
    let length = data.count
    let pointer = malloc(length)!
    data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: length)

    if request.isCancelled {
      free(pointer)
      return request.completion(.success(failure(.cancelled)))
    }

    registry.remove(requestId: request.id)
    request.completion(
      .success(
        success(
          RemoteImagePayload(
            pointer: Int64(Int(bitPattern: pointer)),
            length: Int64(length)
          )
        )
      )
    )
  }

  private static func completeDecoded(request: RemoteImageOperation, data: Data) {
    ImageProcessing.queue.addOperation {
      if request.isCancelled {
        return request.completion(.success(failure(.cancelled)))
      }

      guard
        let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
        let cgImage = CGImageSourceCreateThumbnailAtIndex(
          imageSource,
          0,
          decodeOptions
        )
      else {
        registry.remove(requestId: request.id)
        return request.completion(.success(failure(.serverUnavailable)))
      }

      do {
        let buffer = try vImage_Buffer(cgImage: cgImage, format: rgbaFormat)
        if request.isCancelled {
          buffer.free()
          return request.completion(.success(failure(.cancelled)))
        }

        registry.remove(requestId: request.id)
        request.completion(
          .success(
            success(
              RemoteImagePayload(
                pointer: Int64(Int(bitPattern: buffer.data)),
                width: Int64(buffer.width),
                height: Int64(buffer.height),
                rowBytes: Int64(buffer.rowBytes)
              )
            )
          )
        )
      } catch {
        registry.remove(requestId: request.id)
        request.completion(.success(failure(.serverUnavailable)))
      }
    }
  }

  private static func success(_ payload: RemoteImagePayload) -> RemoteImageResult {
    RemoteImageResult(payload: payload, error: nil)
  }

  private static func failure(_ error: RemoteImageErrorCode) -> RemoteImageResult {
    RemoteImageResult(payload: nil, error: error)
  }
}
