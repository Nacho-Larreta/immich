package app.alextran.immich.images

import android.content.Context
import android.os.CancellationSignal
import android.os.OperationCanceledException
import app.alextran.immich.INITIAL_BUFFER_SIZE
import app.alextran.immich.NativeBuffer
import app.alextran.immich.NativeByteBuffer
import app.alextran.immich.core.HttpClientManager
import app.alextran.immich.core.NetworkContextBoundWork
import app.alextran.immich.core.NetworkContextBoundWorkRegistry
import app.alextran.immich.core.NetworkContextWorkPhase
import app.alextran.immich.core.RemoteImageAuthorization
import app.alextran.immich.core.RemoteImageCacheClaim
import okhttp3.Cache
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.chromium.net.CronetException
import org.chromium.net.UrlRequest
import org.chromium.net.UrlResponseInfo
import java.io.EOFException
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

private class RemoteRequest(
  val cancellationSignal: CancellationSignal,
)

private const val MAX_REDIRECTS = 5

class RemoteImagesImpl(
  context: Context,
) : RemoteImageApi {
  private val requestMap = ConcurrentHashMap<Long, RemoteRequest>()

  init {
    ImageFetcherManager.initialize(context)
  }

  companion object {
    val CANCELLED = Result.success(RemoteImageResult(error = RemoteImageErrorCode.CANCELLED))
  }

  override fun requestImage(
    request: RemoteImageRequest,
    callback: (Result<RemoteImageResult>) -> Unit,
  ) {
    if (request.policy == RemoteImagePolicy.CACHE_ONLY) {
      requestCachedImage(request, callback)
      return
    }
    val expectedGeneration = request.expectedContextGeneration
    val authorization =
      expectedGeneration?.let {
        HttpClientManager.captureRemoteImageAuthorization(request.url, request.origin, it)
      }
    if (expectedGeneration == null || authorization == null) {
      callback(Result.success(RemoteImageResult(error = RemoteImageErrorCode.WRONG_SERVER)))
      return
    }
    val signal = CancellationSignal()
    val admitted =
      HttpClientManager.admitRemoteImageRequest(authorization) {
        requestMap[request.requestId] = RemoteRequest(signal)
        ImageFetcherManager.fetch(
          authorization,
          signal,
          onSuccess = { buffer -> completeRequest(request, authorization, signal, buffer, callback) },
          onFailure = {
            requestMap.remove(request.requestId)
            callback(
              if (signal.isCanceled) {
                CANCELLED
              } else {
                Result.success(RemoteImageResult(error = RemoteImageErrorCode.SERVER_UNAVAILABLE))
              },
            )
          },
        )
      }
    if (!admitted) callback(Result.success(RemoteImageResult(error = RemoteImageErrorCode.WRONG_SERVER)))
  }

  private fun requestCachedImage(
    request: RemoteImageRequest,
    callback: (Result<RemoteImageResult>) -> Unit,
  ) {
    val generation = request.expectedContextGeneration
    val claim = generation?.let { HttpClientManager.claimRemoteImageCacheRead(request.url, request.origin, it) }
    if (claim == null) {
      callback(Result.success(RemoteImageResult(error = RemoteImageErrorCode.CACHE_MISS)))
      return
    }
    val signal = CancellationSignal()
    requestMap[request.requestId] = RemoteRequest(signal)
    ImageFetcherManager.readCache(claim, signal) { cached ->
      requestMap.remove(request.requestId)
      if (signal.isCanceled) {
        cached?.free()
        callback(CANCELLED)
      } else {
        val delivered =
          cached != null &&
            HttpClientManager.deliverRemoteImageCache(claim) {
              callback(Result.success(cached.toRemoteImageResult()))
            }
        if (!delivered) {
          cached?.free()
          callback(Result.success(RemoteImageResult(error = RemoteImageErrorCode.CACHE_MISS)))
        }
      }
    }
  }

  private fun completeRequest(
    request: RemoteImageRequest,
    authorization: RemoteImageAuthorization,
    signal: CancellationSignal,
    buffer: NativeByteBuffer,
    callback: (Result<RemoteImageResult>) -> Unit,
  ) {
    requestMap.remove(request.requestId)
    if (signal.isCanceled) {
      buffer.free()
      callback(CANCELLED)
      return
    }
    val completion = HttpClientManager.claimRemoteImageCompletion(authorization)
    if (completion == null) {
      buffer.free()
      callback(Result.success(RemoteImageResult(error = RemoteImageErrorCode.WRONG_SERVER)))
      return
    }
    val preparedWrite = ImageFetcherManager.prepareCacheWrite(completion, buffer)
    val delivered =
      HttpClientManager.deliverRemoteImageCache(completion) {
        preparedWrite?.enqueue()
        callback(Result.success(buffer.toRemoteImageResult()))
      }
    if (!delivered) {
      preparedWrite?.close()
      buffer.free()
      callback(Result.success(RemoteImageResult(error = RemoteImageErrorCode.WRONG_SERVER)))
    }
  }

  override fun cancelRequest(requestId: Long) {
    requestMap.remove(requestId)?.cancellationSignal?.cancel()
  }

  override fun cancelAll() {
    requestMap.keys.toList().forEach(::cancelRequest)
  }

  override fun dispose() = cancelAll()

  override fun clearCache(
    request: RemoteImageCacheClearRequest,
    callback: (Result<RemoteImageCacheClearResult>) -> Unit,
  ) {
    ImageFetcherManager.clearCache { result ->
      callback(
        Result.success(
          result.fold(
            onSuccess = { RemoteImageCacheClearResult(clearedBytes = it) },
            onFailure = { RemoteImageCacheClearResult(error = RemoteImageErrorCode.SERVER_UNAVAILABLE) },
          ),
        ),
      )
    }
  }
}

private fun NativeByteBuffer.toRemoteImageResult() =
  RemoteImageResult(
    payload = RemoteImagePayload(pointer = pointer, length = offset.toLong()),
  )

private object ImageFetcherManager : NetworkContextBoundWork {
  private lateinit var cacheDir: File
  private lateinit var diskCache: RemoteImageDiskCache
  private val cacheExecutor = RemoteImageCacheExecutor()
  @Volatile
  private var cacheUsable = true
  private lateinit var fetcher: ImageFetcher
  private var initialized = false
  private var fenced = false
  private var phaseRevision = 0L
  private val activeSignals = mutableSetOf<CancellationSignal>()
  private val pendingDrains = mutableMapOf<Long, PendingDrain<CancellationSignal>>()

  fun initialize(context: Context) {
    NetworkContextBoundWorkRegistry.register(this)
    if (initialized) return
    synchronized(this) {
      if (initialized) return
      cacheDir = context.cacheDir
      diskCache = RemoteImageDiskCache(File(cacheDir, "remote-images"))
      fetcher = build()
      HttpClientManager.addClientChangedListener(::invalidate)
      initialized = true
    }
  }

  fun fetch(
    authorization: RemoteImageAuthorization,
    signal: CancellationSignal,
    onSuccess: (NativeByteBuffer) -> Unit,
    onFailure: (Exception) -> Unit,
  ) {
    val activeFetcher =
      synchronized(this) {
        if (fenced) null else fetcher.also { activeSignals.add(signal) }
      }
    if (activeFetcher == null) {
      onFailure(OperationCanceledException("Network request context is fenced"))
      return
    }
    try {
      activeFetcher.fetch(
        authorization,
        signal,
        onSuccess = { buffer ->
          try {
            onSuccess(buffer)
          } finally {
            complete(signal)
          }
        },
        onFailure = { error ->
          try {
            onFailure(error)
          } finally {
            complete(signal)
          }
        },
      )
    } catch (error: Exception) {
      try {
        onFailure(error)
      } finally {
        complete(signal)
      }
    }
  }

  fun readCache(
    claim: RemoteImageCacheClaim,
    signal: CancellationSignal,
    onRead: (NativeByteBuffer?) -> Unit,
  ) {
    if (!cacheUsable) return onRead(null)
    val accepted =
      cacheExecutor.execute {
        if (signal.isCanceled) return@execute onRead(null)
        val bytes = diskCache.read(claim.cacheScope, claim.url) ?: return@execute onRead(null)
        val buffer = NativeByteBuffer(bytes.size)
        try {
          NativeBuffer.wrap(buffer.pointer, bytes.size).put(bytes)
          buffer.advance(bytes.size)
          onRead(buffer)
        } catch (_: Exception) {
          buffer.free()
          onRead(null)
        }
      }
    if (!accepted) onRead(null)
  }

  fun prepareCacheWrite(
    claim: RemoteImageCacheClaim,
    buffer: NativeByteBuffer,
  ): PreparedRemoteImageCacheWrite? {
    if (!cacheUsable) return null
    val reservation = cacheExecutor.reserve(buffer.offset.toLong()) ?: return null
    return try {
      val bytes = ByteArray(buffer.offset)
      NativeBuffer.wrap(buffer.pointer, buffer.offset).get(bytes)
      PreparedRemoteImageCacheWrite(reservation, diskCache, claim, bytes)
    } catch (error: Exception) {
      reservation.close()
      null
    }
  }

  fun clearCache(onCleared: (Result<Long>) -> Unit) {
    cacheUsable = false
    cacheExecutor.submitBarrier { diskCache.clear() }.whenComplete { diskBytes, diskError ->
      if (diskError != null || diskBytes == null) {
        onCleared(Result.failure(diskError ?: IllegalStateException("Remote image cache clear returned no result")))
      } else {
        val clearedDiskBytes = diskBytes
        cacheUsable = true
        fetcher.clearCache { fetcherResult ->
          onCleared(
            fetcherResult.map { fetcherBytes -> clearedDiskBytes + fetcherBytes },
          )
        }
      }
    }
  }

  private fun invalidate() {
    val oldFetcher =
      synchronized(this) {
        val oldFetcher = fetcher
        fetcher = build()
        oldFetcher
      }
    oldFetcher.drain()
    val scope = HttpClientManager.currentRemoteImageCacheScope()
    cacheUsable = false
    cacheExecutor.submitBarrier { diskCache.retainOnly(scope) }.whenComplete { _, error ->
      cacheUsable = error == null
    }
  }

  override fun fenceAndCancel(phase: NetworkContextWorkPhase): CompletableFuture<Unit> {
    val (signals, drained, activeFetcher) =
      synchronized(this) {
        if (phase.revision < phaseRevision) return CompletableFuture.completedFuture(Unit)
        phaseRevision = phase.revision
        fenced = true
        val signals = activeSignals.toList()
        val drained =
          if (signals.isEmpty()) {
            CompletableFuture.completedFuture(Unit)
          } else {
            pendingDrains
              .getOrPut(phase.transitionEpoch) {
                PendingDrain(signals.toMutableSet(), CompletableFuture())
              }.future
          }
        Triple(signals, drained, if (initialized) fetcher else null)
      }
    var drainFailure: Exception? = null
    try {
      activeFetcher?.drain()
    } catch (error: Exception) {
      drainFailure = error
    } finally {
      signals.forEach(CancellationSignal::cancel)
    }
    val failure = drainFailure ?: return drained
    return drained.thenCompose {
      CompletableFuture<Unit>().also { it.completeExceptionally(failure) }
    }
  }

  override fun reopen(phase: NetworkContextWorkPhase) {
    synchronized(this) {
      if (phase.revision < phaseRevision) return
      phaseRevision = phase.revision
      fenced = false
    }
  }

  private fun complete(signal: CancellationSignal) {
    val drained =
      synchronized(this) {
        if (!activeSignals.remove(signal)) return
        pendingDrains.values.forEach { it.remaining.remove(signal) }
        val completed = pendingDrains.filterValues { it.remaining.isEmpty() }
        completed.keys.forEach(pendingDrains::remove)
        completed.values.map { it.future }
      }
    drained.forEach { it.complete(Unit) }
  }

  private fun build(): ImageFetcher =
    if (HttpClientManager.isMtls) {
      OkHttpImageFetcher.create(cacheDir)
    } else {
      CronetImageFetcher()
    }
}

private class PreparedRemoteImageCacheWrite(
  private val reservation: RemoteImageCacheExecutor.Reservation,
  private val diskCache: RemoteImageDiskCache,
  private val claim: RemoteImageCacheClaim,
  private val bytes: ByteArray,
) : java.io.Closeable {
  fun enqueue(): Boolean =
    reservation.execute {
      runCatching { diskCache.write(claim.cacheScope, claim.url, bytes) }
    }

  override fun close() = reservation.close()
}

private data class PendingDrain<T>(
  val remaining: MutableSet<T>,
  val future: CompletableFuture<Unit>,
)

private sealed interface ImageFetcher {
  fun fetch(
    authorization: RemoteImageAuthorization,
    signal: CancellationSignal,
    onSuccess: (NativeByteBuffer) -> Unit,
    onFailure: (Exception) -> Unit,
  )

  fun drain()

  fun clearCache(onCleared: (Result<Long>) -> Unit)
}

private class CronetImageFetcher : ImageFetcher {
  private val stateLock = Any()
  private var activeCount = 0
  private var draining = false
  private var onCacheCleared: ((Result<Long>) -> Unit)? = null

  override fun fetch(
    authorization: RemoteImageAuthorization,
    signal: CancellationSignal,
    onSuccess: (NativeByteBuffer) -> Unit,
    onFailure: (Exception) -> Unit,
  ) {
    val rejected =
      synchronized(stateLock) {
        if (draining) {
          true
        } else {
          activeCount++
          false
        }
      }
    if (rejected) return onFailure(IllegalStateException("Engine is draining"))

    val callback =
      FetchCallback(
        authorization,
        onSuccess,
        onFailure,
        ::onComplete,
      )
    val requestBuilder =
      HttpClientManager.cronetEngine!!
        .newUrlRequestBuilder(authorization.url, callback, HttpClientManager.cronetExecutor)
    authorization.headers.forEach { (key, value) ->
      requestBuilder.addHeader(key, value)
    }
    val request = requestBuilder.build()
    signal.setOnCancelListener(request::cancel)
    request.start()
  }

  private fun onComplete() {
    val didDrain =
      synchronized(stateLock) {
        activeCount--
        draining && activeCount == 0
      }
    if (didDrain) {
      onDrained()
    }
  }

  override fun drain() {
    val didDrain =
      synchronized(stateLock) {
        if (draining) return
        draining = true
        activeCount == 0
      }
    if (didDrain) {
      onDrained()
    }
  }

  private fun onDrained() {
    val onCacheCleared =
      synchronized(stateLock) {
        val onCacheCleared = this.onCacheCleared
        this.onCacheCleared = null
        onCacheCleared
      } ?: return

    CoroutineScope(Dispatchers.IO).launch {
      val result = HttpClientManager.rebuildCronetEngine()
      synchronized(stateLock) { draining = false }
      onCacheCleared(result)
    }
  }

  override fun clearCache(onCleared: (Result<Long>) -> Unit) {
    val alreadyClearing =
      synchronized(stateLock) {
        if (onCacheCleared != null) {
          true
        } else {
          onCacheCleared = onCleared
          false
        }
      }
    if (alreadyClearing) return onCleared(Result.success(-1))
    drain()
  }

  private class FetchCallback(
    private val authorization: RemoteImageAuthorization,
    private val onSuccess: (NativeByteBuffer) -> Unit,
    private val onFailure: (Exception) -> Unit,
    private val onComplete: () -> Unit,
  ) : UrlRequest.Callback() {
    private var buffer: NativeByteBuffer? = null
    private var wrapped: ByteBuffer? = null
    private var error: Exception? = null
    private var redirectCount = 0

    override fun onRedirectReceived(
      request: UrlRequest,
      info: UrlResponseInfo,
      newUrl: String,
    ) {
      val redirected = authorization.redirectedTo(newUrl)
      val admitted =
        redirectCount < MAX_REDIRECTS &&
          HttpClientManager.admitRemoteImageRequest(redirected) {
            redirectCount++
            request.followRedirect()
          }
      if (!admitted) {
        error = IOException("Redirect left the authorized request context")
        request.cancel()
      }
    }

    override fun onResponseStarted(
      request: UrlRequest,
      info: UrlResponseInfo,
    ) {
      if (info.httpStatusCode !in 200..299) {
        error = IOException("HTTP ${info.httpStatusCode}: ${info.httpStatusText}")
        return request.cancel()
      }

      try {
        val contentLength = info.allHeaders["content-length"]?.firstOrNull()?.toIntOrNull() ?: 0
        if (contentLength > 0) {
          buffer = NativeByteBuffer(contentLength + 1)
          wrapped = NativeBuffer.wrap(buffer!!.pointer, contentLength + 1)
          request.read(wrapped)
        } else {
          buffer = NativeByteBuffer(INITIAL_BUFFER_SIZE)
          request.read(buffer!!.wrapRemaining())
        }
      } catch (e: Exception) {
        error = e
        return request.cancel()
      }
    }

    override fun onReadCompleted(
      request: UrlRequest,
      info: UrlResponseInfo,
      byteBuffer: ByteBuffer,
    ) {
      try {
        val buf =
          if (wrapped == null) {
            buffer!!.run {
              advance(byteBuffer.position())
              ensureHeadroom()
              wrapRemaining()
            }
          } else {
            wrapped
          }
        request.read(buf)
      } catch (e: Exception) {
        error = e
        return request.cancel()
      }
    }

    override fun onSucceeded(
      request: UrlRequest,
      info: UrlResponseInfo,
    ) {
      wrapped?.let { buffer!!.advance(it.position()) }
      onComplete()
      onSuccess(buffer!!)
    }

    override fun onFailed(
      request: UrlRequest,
      info: UrlResponseInfo?,
      error: CronetException,
    ) {
      buffer?.free()
      onComplete()
      onFailure(error)
    }

    override fun onCanceled(
      request: UrlRequest,
      info: UrlResponseInfo?,
    ) {
      buffer?.free()
      onComplete()
      onFailure(error ?: OperationCanceledException())
    }
  }
}

private class OkHttpImageFetcher private constructor(
  private val client: OkHttpClient,
) : ImageFetcher {
  private val stateLock = Any()
  private var activeCount = 0
  private var draining = false

  companion object {
    fun create(cacheDir: File): OkHttpImageFetcher {
      val dir = File(cacheDir, "okhttp")

      val client =
        HttpClientManager
          .getClient()
          .newBuilder()
          .cache(Cache(File(dir, "thumbnails"), HttpClientManager.MEDIA_CACHE_SIZE_BYTES))
          .followRedirects(false)
          .followSslRedirects(false)
          .build()

      return OkHttpImageFetcher(client)
    }
  }

  private fun onComplete(): Exception? {
    val shouldClose =
      synchronized(stateLock) {
        activeCount--
        draining && activeCount == 0
      }
    if (!shouldClose) return null
    return try {
      client.cache?.close()
      null
    } catch (error: Exception) {
      error
    }
  }

  override fun fetch(
    authorization: RemoteImageAuthorization,
    signal: CancellationSignal,
    onSuccess: (NativeByteBuffer) -> Unit,
    onFailure: (Exception) -> Unit,
  ) {
    val rejected =
      synchronized(stateLock) {
        if (draining) {
          true
        } else {
          activeCount++
          false
        }
      }
    if (rejected) return onFailure(IllegalStateException("Client is draining"))

    RedirectingRequest(authorization, signal, onSuccess, onFailure).startInitial()
  }

  private inner class RedirectingRequest(
    private val initialAuthorization: RemoteImageAuthorization,
    private val signal: CancellationSignal,
    private val onSuccess: (NativeByteBuffer) -> Unit,
    private val onFailure: (Exception) -> Unit,
  ) {
    private val terminal = AtomicBoolean(false)
    private var activeCall: Call? = null
    private var redirectCount = 0

    init {
      signal.setOnCancelListener { synchronized(this) { activeCall }?.cancel() }
    }

    fun startInitial() = startCall(initialAuthorization)

    private fun startRedirect(authorization: RemoteImageAuthorization) {
      val admitted = HttpClientManager.admitRemoteImageRequest(authorization) { startCall(authorization) }
      if (!admitted) finishFailure(IOException("Redirect left the authorized request context"))
    }

    private fun startCall(authorization: RemoteImageAuthorization) {
      if (signal.isCanceled) return finishFailure(OperationCanceledException())
      val requestBuilder = Request.Builder().url(authorization.url)
      authorization.headers.forEach(requestBuilder::addHeader)
      val call = client.newCall(requestBuilder.build())
      synchronized(this) { activeCall = call }
      if (signal.isCanceled) call.cancel()
      call.enqueue(
        object : Callback {
          override fun onFailure(
            call: Call,
            error: IOException,
          ) = finishFailure(error)

          override fun onResponse(
            call: Call,
            response: Response,
          ) {
            if (response.code in 300..399) {
              followRedirect(response)
            } else {
              readTerminalResponse(call, response)
            }
          }
        },
      )
    }

    private fun followRedirect(response: Response) {
      val location = response.header("Location")
      val redirectedUrl = location?.let(response.request.url::resolve)?.toString()
      response.close()
      if (redirectCount >= MAX_REDIRECTS || redirectedUrl == null) {
        finishFailure(IOException("Invalid or excessive remote image redirect"))
        return
      }
      redirectCount++
      startRedirect(initialAuthorization.redirectedTo(redirectedUrl))
    }

    private fun readTerminalResponse(
      call: Call,
      response: Response,
    ) {
      var buffer: NativeByteBuffer? = null
      var failure: Exception? = null
      try {
        if (!HttpClientManager.isRemoteImageContextCurrent(
            response.request.url.toString(),
            initialAuthorization.declaredOrigin,
            initialAuthorization.expectedGeneration,
          )
        ) {
          throw IOException("Response left the authorized request context")
        }
        response.use { buffer = readResponse(call, response) }
      } catch (error: Exception) {
        failure = error
      }
      if (failure != null) {
        buffer?.free()
        finishFailure(failure)
      } else {
        finishSuccess(buffer!!)
      }
    }

    private fun finishSuccess(buffer: NativeByteBuffer) {
      if (!terminal.compareAndSet(false, true)) {
        buffer.free()
        return
      }
      val completionFailure = onComplete()
      if (completionFailure == null) {
        onSuccess(buffer)
      } else {
        buffer.free()
        onFailure(completionFailure)
      }
    }

    private fun finishFailure(error: Exception) {
      if (!terminal.compareAndSet(false, true)) return
      onFailure(onComplete() ?: error)
    }
  }

  private fun readResponse(
    call: Call,
    response: Response,
  ): NativeByteBuffer {
    if (!response.isSuccessful) {
      throw IOException("HTTP ${response.code}: ${response.message}")
    }
    val body = response.body ?: throw IOException("Empty response body")
    if (call.isCanceled()) throw OperationCanceledException()

    body.source().use { source ->
      val length = body.contentLength().toInt()
      val buffer = NativeByteBuffer(if (length > 0) length else INITIAL_BUFFER_SIZE)
      try {
        if (length > 0) {
          val wrapped = NativeBuffer.wrap(buffer.pointer, length)
          while (wrapped.hasRemaining()) {
            if (call.isCanceled()) throw OperationCanceledException()
            if (source.read(wrapped) == -1) throw EOFException()
          }
          buffer.advance(length)
        } else {
          while (true) {
            if (call.isCanceled()) throw OperationCanceledException()
            val bytesRead = source.read(buffer.wrapRemaining())
            if (bytesRead == -1) break
            buffer.advance(bytesRead)
            buffer.ensureHeadroom()
          }
        }
        return buffer
      } catch (error: Exception) {
        buffer.free()
        throw error
      }
    }
  }

  override fun drain() {
    val shouldClose =
      synchronized(stateLock) {
        if (draining) return
        draining = true
        activeCount == 0
      }
    if (shouldClose) {
      client.cache?.close()
    }
  }

  override fun clearCache(onCleared: (Result<Long>) -> Unit) {
    try {
      val size = client.cache!!.size()
      client.cache!!.evictAll()
      onCleared(Result.success(size))
    } catch (e: Exception) {
      onCleared(Result.failure(e))
    }
  }
}
