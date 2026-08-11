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
import kotlinx.coroutines.*
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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CompletableFuture

private class RemoteRequest(val cancellationSignal: CancellationSignal)

class RemoteImagesImpl(context: Context) : RemoteImageApi {
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
    val signal = CancellationSignal()
    requestMap[request.requestId] = RemoteRequest(signal)

    ImageFetcherManager.fetch(
      request.url,
      signal,
      onSuccess = { buffer ->
        requestMap.remove(request.requestId)
        if (signal.isCanceled) {
          NativeBuffer.free(buffer.pointer)
          return@fetch callback(CANCELLED)
        }

        callback(
          Result.success(
            RemoteImageResult(
              payload = RemoteImagePayload(
                pointer = buffer.pointer,
                length = buffer.offset.toLong(),
              ),
            ),
          ),
        )
      },
      onFailure = { e ->
        requestMap.remove(request.requestId)
        val result = if (signal.isCanceled) {
          CANCELLED
        } else {
          Result.success(RemoteImageResult(error = RemoteImageErrorCode.SERVER_UNAVAILABLE))
        }
        callback(result)
      },
    )
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
    CoroutineScope(Dispatchers.IO).launch {
      try {
        ImageFetcherManager.clearCache { result ->
          callback(
            Result.success(
              result.fold(
                onSuccess = { RemoteImageCacheClearResult(clearedBytes = it) },
                onFailure = {
                  RemoteImageCacheClearResult(error = RemoteImageErrorCode.SERVER_UNAVAILABLE)
                },
              ),
            ),
          )
        }
      } catch (e: Exception) {
        callback(
          Result.success(
            RemoteImageCacheClearResult(error = RemoteImageErrorCode.SERVER_UNAVAILABLE),
          ),
        )
      }
    }
  }
}

private object ImageFetcherManager : NetworkContextBoundWork {
  private lateinit var cacheDir: File
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
      fetcher = build()
      HttpClientManager.addClientChangedListener(::invalidate)
      initialized = true
    }
  }

  fun fetch(
    url: String,
    signal: CancellationSignal,
    onSuccess: (NativeByteBuffer) -> Unit,
    onFailure: (Exception) -> Unit,
  ) {
    val activeFetcher = synchronized(this) {
      if (fenced) null else fetcher.also { activeSignals.add(signal) }
    }
    if (activeFetcher == null) {
      onFailure(OperationCanceledException("Network request context is fenced"))
      return
    }
    try {
      activeFetcher.fetch(
        url,
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

  fun clearCache(onCleared: (Result<Long>) -> Unit) {
    fetcher.clearCache(onCleared)
  }

  private fun invalidate() {
    val oldFetcher = synchronized(this) {
      val oldFetcher = fetcher
      fetcher = build()
      oldFetcher
    }
    oldFetcher.drain()
  }

  override fun fenceAndCancel(phase: NetworkContextWorkPhase): CompletableFuture<Unit> {
    val (signals, drained, activeFetcher) = synchronized(this) {
      if (phase.revision < phaseRevision) return CompletableFuture.completedFuture(Unit)
      phaseRevision = phase.revision
      fenced = true
      val signals = activeSignals.toList()
      val drained = if (signals.isEmpty()) {
        CompletableFuture.completedFuture(Unit)
      } else {
        pendingDrains.getOrPut(phase.transitionEpoch) {
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
    val drained = synchronized(this) {
      if (!activeSignals.remove(signal)) return
      pendingDrains.values.forEach { it.remaining.remove(signal) }
      val completed = pendingDrains.filterValues { it.remaining.isEmpty() }
      completed.keys.forEach(pendingDrains::remove)
      completed.values.map { it.future }
    }
    drained.forEach { it.complete(Unit) }
  }

  private fun build(): ImageFetcher {
    return if (HttpClientManager.isMtls) {
      OkHttpImageFetcher.create(cacheDir)
    } else {
      CronetImageFetcher()
    }
  }
}

private data class PendingDrain<T>(
  val remaining: MutableSet<T>,
  val future: CompletableFuture<Unit>,
)

private sealed interface ImageFetcher {
  fun fetch(
    url: String,
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
    url: String,
    signal: CancellationSignal,
    onSuccess: (NativeByteBuffer) -> Unit,
    onFailure: (Exception) -> Unit,
  ) {
    val rejected = synchronized(stateLock) {
      if (draining) {
        true
      } else {
        activeCount++
        false
      }
    }
    if (rejected) return onFailure(IllegalStateException("Engine is draining"))

    val callback = FetchCallback(onSuccess, onFailure, ::onComplete)
    val requestBuilder = HttpClientManager.cronetEngine!!
      .newUrlRequestBuilder(url, callback, HttpClientManager.cronetExecutor)
    HttpClientManager.getAuthHeaders(url).forEach { (key, value) ->
      requestBuilder.addHeader(key, value)
    }
    val request = requestBuilder.build()
    signal.setOnCancelListener(request::cancel)
    request.start()
  }

  private fun onComplete() {
    val didDrain = synchronized(stateLock) {
      activeCount--
      draining && activeCount == 0
    }
    if (didDrain) {
      onDrained()
    }
  }

  override fun drain() {
    val didDrain = synchronized(stateLock) {
      if (draining) return
      draining = true
      activeCount == 0
    }
    if (didDrain) {
      onDrained()
    }
  }

  private fun onDrained() {
    val onCacheCleared = synchronized(stateLock) {
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
    val alreadyClearing = synchronized(stateLock) {
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
    private val onSuccess: (NativeByteBuffer) -> Unit,
    private val onFailure: (Exception) -> Unit,
    private val onComplete: () -> Unit,
  ) : UrlRequest.Callback() {
    private var buffer: NativeByteBuffer? = null
    private var wrapped: ByteBuffer? = null
    private var error: Exception? = null

    override fun onRedirectReceived(request: UrlRequest, info: UrlResponseInfo, newUrl: String) {
      request.followRedirect()
    }

    override fun onResponseStarted(request: UrlRequest, info: UrlResponseInfo) {
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
      byteBuffer: ByteBuffer
    ) {
      try {
        val buf = if (wrapped == null) {
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

    override fun onSucceeded(request: UrlRequest, info: UrlResponseInfo) {
      wrapped?.let { buffer!!.advance(it.position()) }
      onComplete()
      onSuccess(buffer!!)
    }

    override fun onFailed(request: UrlRequest, info: UrlResponseInfo?, error: CronetException) {
      buffer?.free()
      onComplete()
      onFailure(error)
    }

    override fun onCanceled(request: UrlRequest, info: UrlResponseInfo?) {
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

      val client = HttpClientManager.getClient().newBuilder()
        .cache(Cache(File(dir, "thumbnails"), HttpClientManager.MEDIA_CACHE_SIZE_BYTES))
        .build()

      return OkHttpImageFetcher(client)
    }
  }

  private fun onComplete(): Exception? {
    val shouldClose = synchronized(stateLock) {
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
    url: String,
    signal: CancellationSignal,
    onSuccess: (NativeByteBuffer) -> Unit,
    onFailure: (Exception) -> Unit,
  ) {
    val rejected = synchronized(stateLock) {
      if (draining) {
        true
      } else {
        activeCount++
        false
      }
    }
    if (rejected) return onFailure(IllegalStateException("Client is draining"))

    val requestBuilder = Request.Builder().url(url)
    val call = client.newCall(requestBuilder.build())
    signal.setOnCancelListener(call::cancel)

    call.enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) {
        onFailure(onComplete() ?: e)
      }

      override fun onResponse(call: Call, response: Response) {
        var buffer: NativeByteBuffer? = null
        var failure: Exception? = null
        try {
          response.use { buffer = readResponse(call, response) }
        } catch (error: Exception) {
          failure = error
        }
        val completionFailure = onComplete()
        failure = failure ?: completionFailure
        if (failure != null) {
          try {
            buffer?.free()
          } catch (freeError: Exception) {
            failure = failure ?: freeError
          } finally {
            buffer = null
          }
        }
        failure?.let(onFailure) ?: onSuccess(buffer!!)
      }
    })
  }

  private fun readResponse(call: Call, response: Response): NativeByteBuffer {
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
    val shouldClose = synchronized(stateLock) {
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
