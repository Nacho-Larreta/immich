package app.alextran.immich.core

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

private const val PROBE_MAXIMUM_BODY_BYTES = 1024 * 1024
private const val PROBE_MAXIMUM_REDIRECTS = 5
private const val PROBE_READ_BUFFER_BYTES = 8 * 1024
private val PROBE_FORBIDDEN_HEADER_NAMES = setOf(
  "connection",
  "cookie",
  "host",
  "keep-alive",
  "proxy-authorization",
  "proxy-connection",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
)

class ProbeHttpApiImpl : ProbeHttpApi {
  private val sessions = ConcurrentHashMap<Long, ProbeHttpSession>()

  override fun openSession(session: NativeProbeHttpSession) {
    require(session.sessionId > 0) { "Probe session ID must be positive" }
    require(session.timeoutMilliseconds > 0) { "Probe timeout must be positive" }
    val probeSession = ProbeHttpSession(HttpClientManager.createProbeClient(session.timeoutMilliseconds))
    check(sessions.putIfAbsent(session.sessionId, probeSession) == null) {
      probeSession.close()
      "Probe session ID is already active"
    }
  }

  override fun get(
    request: NativeProbeHttpRequest,
    callback: (Result<NativeProbeHttpResult>) -> Unit,
  ) {
    val session = sessions[request.sessionId]
    if (session == null) {
      callback(Result.success(NativeProbeHttpResult(error = NativeProbeHttpErrorCode.SESSION_NOT_FOUND)))
      return
    }
    session.get(request, callback)
  }

  override fun cancelRequest(sessionId: Long, requestId: Long) {
    sessions[sessionId]?.cancel(requestId)
  }

  override fun closeSession(sessionId: Long) {
    sessions.remove(sessionId)?.close()
  }
}

private class ProbeHttpSession(private val client: OkHttpClient) {
  private val operations = ConcurrentHashMap<Long, ProbeHttpOperation>()

  fun get(
    input: NativeProbeHttpRequest,
    callback: (Result<NativeProbeHttpResult>) -> Unit,
  ) {
    val requestUrl = input.url.toHttpUrlOrNull()
    val origin = input.canonicalOrigin.toHttpUrlOrNull()
    if (
      requestUrl == null ||
      origin == null ||
      !origin.isOriginOnly() ||
      !requestUrl.isValidProbeResource() ||
      !requestUrl.hasSameOrigin(origin)
    ) {
      callback(Result.success(NativeProbeHttpResult(error = NativeProbeHttpErrorCode.INVALID_REQUEST)))
      return
    }
    val initialRequest = try {
      Request.Builder().url(requestUrl).get().apply {
        input.headers.forEach { (name, value) ->
          if (!name.isForbiddenProbeHeader()) header(name, value)
        }
      }.build()
    } catch (_: IllegalArgumentException) {
      callback(Result.success(NativeProbeHttpResult(error = NativeProbeHttpErrorCode.INVALID_REQUEST)))
      return
    }
    val operation = ProbeHttpOperation(
      client = client,
      requestUrl = requestUrl,
      origin = origin,
      initialRequest = initialRequest,
      onComplete = { result ->
        operations.remove(input.requestId)
        callback(Result.success(result))
      },
    )
    if (operations.putIfAbsent(input.requestId, operation) != null) {
      callback(Result.success(NativeProbeHttpResult(error = NativeProbeHttpErrorCode.DUPLICATE_REQUEST)))
      return
    }
    operation.start()
  }

  fun cancel(requestId: Long) {
    operations.remove(requestId)?.cancel()
  }

  fun close() {
    val active = operations.values.toList()
    operations.clear()
    active.forEach(ProbeHttpOperation::cancel)
  }
}

private class ProbeHttpOperation(
  private val client: OkHttpClient,
  private val requestUrl: HttpUrl,
  private val origin: HttpUrl,
  private val initialRequest: Request,
  private val onComplete: (NativeProbeHttpResult) -> Unit,
) {
  private val completed = AtomicBoolean(false)
  private val redirectChain = mutableListOf<String>()
  @Volatile private var activeCall: Call? = null

  fun start() = execute(initialRequest, redirectCount = 0)

  fun cancel() {
    activeCall?.cancel()
    complete(NativeProbeHttpResult(error = NativeProbeHttpErrorCode.CANCELLED))
  }

  private fun execute(request: Request, redirectCount: Int) {
    if (completed.get()) return
    val call = client.newCall(request)
    activeCall = call
    if (completed.get()) {
      call.cancel()
      return
    }
    call.enqueue(object : Callback {
      override fun onFailure(call: Call, error: IOException) {
        val code = when {
          call.isCanceled -> NativeProbeHttpErrorCode.CANCELLED
          error is SocketTimeoutException -> NativeProbeHttpErrorCode.TIMEOUT
          else -> NativeProbeHttpErrorCode.TRANSPORT_FAILURE
        }
        complete(NativeProbeHttpResult(error = code))
      }

      override fun onResponse(call: Call, response: Response) {
        response.use {
          try {
            val redirect = response.redirectTarget()
            if (redirect != null) {
              followRedirect(response.request, redirect, redirectCount)
              return
            }
            complete(response.toProbeResult())
          } catch (error: SocketTimeoutException) {
            complete(NativeProbeHttpResult(error = NativeProbeHttpErrorCode.TIMEOUT))
          } catch (error: IOException) {
            complete(NativeProbeHttpResult(error = NativeProbeHttpErrorCode.TRANSPORT_FAILURE))
          }
        }
      }
    })
  }

  private fun followRedirect(previousRequest: Request, target: HttpUrl, redirectCount: Int) {
    if (!target.isValidProbeResource() || !target.hasSameOrigin(origin) || redirectCount >= PROBE_MAXIMUM_REDIRECTS) {
      complete(NativeProbeHttpResult(error = NativeProbeHttpErrorCode.REDIRECT_REJECTED))
      return
    }
    redirectChain.add(target.toString())
    execute(previousRequest.newBuilder().url(target).removeForbiddenProbeHeaders().build(), redirectCount + 1)
  }

  private fun Response.toProbeResult(): NativeProbeHttpResult {
    val responseBody = body ?: return NativeProbeHttpResult(error = NativeProbeHttpErrorCode.TRANSPORT_FAILURE)
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(PROBE_READ_BUFFER_BYTES)
    responseBody.byteStream().use { stream ->
      while (true) {
        val count = stream.read(buffer)
        if (count < 0) break
        if (output.size() > PROBE_MAXIMUM_BODY_BYTES - count) {
          return NativeProbeHttpResult(error = NativeProbeHttpErrorCode.BODY_TOO_LARGE)
        }
        output.write(buffer, 0, count)
      }
    }
    val bodyString = output.toByteArray().toString(Charsets.UTF_8)
    return NativeProbeHttpResult(
      response = NativeProbeHttpResponse(
        requestUrl = requestUrl.toString(),
        effectiveUrl = request.url.toString(),
        statusCode = code.toLong(),
        body = bodyString,
        redirectChain = redirectChain.toList(),
      ),
    )
  }

  private fun complete(result: NativeProbeHttpResult) {
    if (completed.compareAndSet(false, true)) {
      onComplete(result)
    }
  }
}

private fun Response.redirectTarget(): HttpUrl? {
  if (code !in 300..399) return null
  val location = header("Location") ?: return null
  return request.url.resolve(location)
}

private fun HttpUrl.isOriginOnly(): Boolean =
  encodedPath == "/" && query == null && fragment == null && username.isEmpty() && password.isEmpty()

private fun HttpUrl.hasSameOrigin(other: HttpUrl): Boolean =
  scheme == other.scheme && host == other.host && port == other.port

private fun HttpUrl.isValidProbeResource(): Boolean =
  username.isEmpty() && password.isEmpty() && fragment == null

private fun String.isForbiddenProbeHeader(): Boolean =
  lowercase(Locale.ROOT) in PROBE_FORBIDDEN_HEADER_NAMES

private fun Request.Builder.removeForbiddenProbeHeaders(): Request.Builder = apply {
  PROBE_FORBIDDEN_HEADER_NAMES.forEach { removeHeader(it) }
}
