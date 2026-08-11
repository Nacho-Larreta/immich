package app.alextran.immich.core

import android.content.Context
import android.content.SharedPreferences
import android.security.KeyChain
import androidx.annotation.OptIn
import androidx.core.content.edit
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import app.alextran.immich.BuildConfig
import app.alextran.immich.NativeBuffer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.Cache
import okhttp3.ConnectionPool
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.Dispatcher
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import org.chromium.net.CronetEngine
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.net.Authenticator
import java.net.CookieHandler
import java.net.PasswordAuthentication
import java.net.Socket
import java.net.URI
import java.nio.ByteBuffer
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Principal
import java.security.PrivateKey
import java.security.cert.X509Certificate
import java.util.Locale
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509KeyManager
import javax.net.ssl.X509TrustManager

const val USER_AGENT = "immich-android/${BuildConfig.VERSION_NAME}"
private const val CERT_ALIAS = "client_cert"
private const val PREFS_NAME = "immich.ssl"
private const val PREFS_CERT_ALIAS = "immich.client_cert"
private const val PREFS_HEADERS = "immich.request_headers"
private const val PREFS_SERVER_URLS = "immich.server_urls"
private const val PREFS_COOKIES = "immich.cookies"
private const val COOKIE_EXPIRY_DAYS = 400L

private enum class AuthCookie(
  val cookieName: String,
  val httpOnly: Boolean,
) {
  ACCESS_TOKEN("immich_access_token", httpOnly = true),
  IS_AUTHENTICATED("immich_is_authenticated", httpOnly = false),
  AUTH_TYPE("immich_auth_type", httpOnly = true),
  ;

  companion object {
    val names = entries.map { it.cookieName }.toSet()
  }
}

private data class RequestContextFingerprint(
  val origins: List<String>,
  val token: String?,
  val headers: Map<String, String>,
) {
  fun cacheIdentity(): String {
    val digest = MessageDigest.getInstance("SHA-256")

    fun add(value: String?) {
      val bytes = value.orEmpty().toByteArray(Charsets.UTF_8)
      digest.update(ByteBuffer.allocate(Int.SIZE_BYTES).putInt(bytes.size).array())
      digest.update(bytes)
    }
    origins.sorted().forEach(::add)
    add(token)
    headers.toSortedMap().forEach { (name, value) ->
      add(name)
      add(value)
    }
    return digest.digest().joinToString(separator = "") { byte ->
      (byte.toInt() and 0xff).toString(16).padStart(2, '0')
    }
  }

  companion object {
    fun create(
      origins: List<CanonicalOrigin>,
      token: String?,
      headers: Map<String, String>,
    ): RequestContextFingerprint {
      val canonicalHeaders =
        buildMap {
          headers.forEach { (key, value) ->
            val canonicalKey = key.lowercase(Locale.ROOT)
            require(put(canonicalKey, value) == null) {
              "Request header names must be unique ignoring case"
            }
          }
        }
      return RequestContextFingerprint(origins.map(CanonicalOrigin::asString), token, canonicalHeaders)
    }
  }
}

/**
 * Manages a shared OkHttpClient with SSL configuration support.
 */
object HttpClientManager {
  private const val CACHE_SIZE_BYTES = 100L * 1024 * 1024 // 100MiB
  const val MEDIA_CACHE_SIZE_BYTES = 1024L * 1024 * 1024 // 1GiB
  private const val KEEP_ALIVE_CONNECTIONS = 10
  private const val KEEP_ALIVE_DURATION_MINUTES = 5L
  private const val MAX_REQUESTS_PER_HOST = 64
  private const val REQUEST_CONTEXT_DRAIN_TIMEOUT_SECONDS = 10L

  private var initialized = false
  private val clientChangedListeners = mutableListOf<() -> Unit>()

  private lateinit var client: OkHttpClient
  private lateinit var appContext: Context
  private lateinit var prefs: SharedPreferences

  var cronetEngine: CronetEngine? = null
    private set
  private lateinit var cronetStorageDir: File
  val cronetExecutor: ExecutorService = Executors.newFixedThreadPool(4)

  private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

  var keyChainAlias: String? = null
    private set

  var headers: Headers = Headers.headersOf()
    private set

  private var activeOrigins = emptyList<CanonicalOrigin>()
  private var requestContextFingerprint: RequestContextFingerprint? = null
  private var requestContextGeneration = 0L
  private var requestContextTransitionEpoch = 0L
  private var requestContextConfirmed = false
  private var requestContextSessionEpoch = 0L
  private var requestContextReplacing = false
  private val remoteImageAdmissionGate = RemoteImageAdmissionGate()
  private val okHttpDrainLock = Any()
  private var pendingOkHttpDrain: CompletableFuture<Unit>? = null

  private val cookieJar = PersistentCookieJar()

  val isMtls: Boolean get() = keyChainAlias != null || keyStore.containsAlias(CERT_ALIAS)

  fun initialize(context: Context) {
    if (initialized) return
    synchronized(this) {
      if (initialized) return

      appContext = context.applicationContext
      prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
      keyChainAlias = prefs.getString(PREFS_CERT_ALIAS, null)

      cookieJar.init(prefs)
      System.setProperty("http.agent", USER_AGENT)
      Authenticator.setDefault(
        object : Authenticator() {
          override fun getPasswordAuthentication(): PasswordAuthentication? {
            val url = requestingURL ?: return null
            if (url.userInfo.isNullOrEmpty()) return null
            val parts = url.userInfo.split(":", limit = 2)
            return PasswordAuthentication(parts[0], parts.getOrElse(1) { "" }.toCharArray())
          }
        },
      )
      CookieHandler.setDefault(
        object : CookieHandler() {
          override fun get(
            uri: URI,
            requestHeaders: Map<String, List<String>>,
          ): Map<String, List<String>> {
            val httpUrl = uri.toString().toHttpUrlOrNull() ?: return emptyMap()
            val cookies =
              synchronized(HttpClientManager) {
                if (!requestContextConfirmed || requestContextReplacing) {
                  emptyList()
                } else {
                  cookieJar.loadForRequest(httpUrl)
                }
              }
            if (cookies.isEmpty()) return emptyMap()
            return mapOf("Cookie" to listOf(cookies.joinToString("; ") { "${it.name}=${it.value}" }))
          }

          override fun put(
            uri: URI,
            responseHeaders: Map<String, List<String>>,
          ) {}
        },
      )

      val savedHeaders = prefs.getString(PREFS_HEADERS, null)
      if (savedHeaders != null) {
        val map = Json.decodeFromString<Map<String, String>>(savedHeaders)
        val builder = Headers.Builder()
        for ((key, value) in map) {
          builder.add(key, value)
        }
        headers = builder.build()
      }

      val serverUrlsJson = prefs.getString(PREFS_SERVER_URLS, null)
      if (serverUrlsJson != null) {
        activeOrigins =
          Json
            .decodeFromString<List<String>>(serverUrlsJson)
            .mapNotNull(CanonicalOrigin::fromEndpoint)
        cookieJar.setAllowedOrigins(activeOrigins)
      }

      val cacheDir = File(File(context.cacheDir, "okhttp"), "api")
      client = build(cacheDir)

      cronetStorageDir = File(context.cacheDir, "cronet").apply { mkdirs() }
      cronetEngine = buildCronetEngine()

      initialized = true
    }
  }

  fun setKeyChainAlias(alias: String) {
    val listeners =
      synchronized(this) {
        val wasMtls = isMtls
        keyChainAlias = alias
        prefs.edit { putString(PREFS_CERT_ALIAS, alias) }

        listenersForChange(wasMtls != isMtls)
      }
    notifyClientChanged(listeners)
  }

  fun setKeyEntry(
    clientData: ByteArray,
    password: CharArray,
  ) {
    val listeners =
      synchronized(this) {
        val wasMtls = isMtls
        val tmpKeyStore =
          KeyStore.getInstance("PKCS12").apply {
            ByteArrayInputStream(clientData).use { stream -> load(stream, password) }
          }
        val tmpAlias =
          tmpKeyStore.aliases().asSequence().firstOrNull { tmpKeyStore.isKeyEntry(it) }
            ?: throw IllegalArgumentException("No private key found in PKCS12")
        val key = tmpKeyStore.getKey(tmpAlias, password)
        val chain = tmpKeyStore.getCertificateChain(tmpAlias)

        if (keyStore.containsAlias(CERT_ALIAS)) {
          keyStore.deleteEntry(CERT_ALIAS)
        }
        keyStore.setKeyEntry(CERT_ALIAS, key, null, chain)
        listenersForChange(wasMtls != isMtls)
      }
    notifyClientChanged(listeners)
  }

  fun deleteKeyEntry() {
    val listeners =
      synchronized(this) {
        val wasMtls = isMtls

        if (keyChainAlias != null) {
          keyChainAlias = null
          prefs.edit { remove(PREFS_CERT_ALIAS) }
        }

        keyStore.deleteEntry(CERT_ALIAS)

        listenersForChange(wasMtls)
      }
    notifyClientChanged(listeners)
  }

  private var clientGlobalRef: Long = 0L

  @JvmStatic
  fun getClient(): OkHttpClient = client

  fun getClientPointer(): Long {
    if (clientGlobalRef == 0L) {
      clientGlobalRef = NativeBuffer.createGlobalRef(client)
    }
    return clientGlobalRef
  }

  fun getRequestContextSnapshot(): NetworkRequestContextSnapshot =
    synchronized(this) {
      NetworkRequestContextSnapshot(
        clientPointer = getClientPointer(),
        canonicalOrigin = activeOrigins.singleOrNull()?.asString(),
        sessionEpoch = requestContextSessionEpoch,
        generation = requestContextGeneration,
        confirmed = requestContextConfirmed && !requestContextReplacing,
      )
    }

  fun createProbeClient(timeoutMilliseconds: Long): OkHttpClient {
    require(timeoutMilliseconds > 0) { "Probe timeout must be positive" }
    return client
      .newBuilder()
      .apply {
        interceptors().clear()
        networkInterceptors().clear()
      }.cookieJar(CookieJar.NO_COOKIES)
      .cache(null)
      .followRedirects(false)
      .followSslRedirects(false)
      .callTimeout(timeoutMilliseconds, TimeUnit.MILLISECONDS)
      .addInterceptor { chain ->
        val request = chain.request()
        val builder = request.newBuilder().header("User-Agent", USER_AGENT)
        chain.proceed(builder.build())
      }.build()
  }

  fun addClientChangedListener(listener: () -> Unit) {
    synchronized(this) { clientChangedListeners.add(listener) }
  }

  fun setRequestHeaders(
    headerMap: Map<String, String>,
    serverUrls: List<String>,
    token: String?,
  ) {
    val origins =
      serverUrls.map { value ->
        CanonicalOrigin.fromEndpoint(value) ?: throw IllegalArgumentException("Invalid HTTP(S) server endpoint")
      }
    transitionRequestContext(headerMap, origins, token, synchronized(this) { requestContextSessionEpoch })
  }

  fun replaceRequestContext(
    headerMap: Map<String, String>,
    canonicalOrigin: String?,
    token: String?,
    sessionEpoch: Long,
  ) {
    val origins =
      canonicalOrigin?.let { value ->
        listOf(CanonicalOrigin.fromStrictOrigin(value) ?: throw IllegalArgumentException("Invalid canonical origin"))
      } ?: emptyList()
    transitionRequestContext(headerMap, origins, token, sessionEpoch, confirmed = true)
  }

  fun failClosedRequestContext() {
    transitionRequestContext(
      emptyMap(),
      emptyList(),
      null,
      synchronized(this) { requestContextSessionEpoch },
      confirmed = false,
    )
  }

  private fun transitionRequestContext(
    headerMap: Map<String, String>,
    origins: List<CanonicalOrigin>,
    token: String?,
    sessionEpoch: Long,
    confirmed: Boolean = true,
  ) {
    require(sessionEpoch >= 0) { "Session epoch must not be negative" }
    require(origins.isNotEmpty() || token == null) { "A token requires a canonical origin" }
    require(origins.isNotEmpty() || headerMap.isEmpty()) { "Custom headers require a canonical origin" }
    val builder = Headers.Builder()
    headerMap.forEach { (key, value) -> builder[key] = value }
    val newHeaders = builder.build()
    val newFingerprint = RequestContextFingerprint.create(origins, token, headerMap)

    lateinit var remoteImageDeliveryDrain: CompletableFuture<Unit>
    val transitionEpoch =
      synchronized(this) {
        if (
          !requestContextReplacing &&
          requestContextFingerprint == newFingerprint &&
          requestContextSessionEpoch == sessionEpoch &&
          requestContextConfirmed == confirmed
        ) {
          return
        }
        requestContextTransitionEpoch++
        requestContextReplacing = true
        requestContextConfirmed = false
        remoteImageDeliveryDrain = remoteImageAdmissionGate.fence(remoteImageContextSnapshot())
        requestContextTransitionEpoch
      }

    val cancellationError =
      runCatching {
        CompletableFuture
          .allOf(
            cancelOkHttpWorkAndAwaitIdle(),
            NetworkContextBoundWorkRegistry.fenceAndCancelAll(transitionEpoch),
            remoteImageDeliveryDrain,
          ).get(REQUEST_CONTEXT_DRAIN_TIMEOUT_SECONDS, TimeUnit.SECONDS)
      }.exceptionOrNull()
    if (cancellationError != null && confirmed) throw cancellationError

    val publication =
      synchronized(this) {
        if (requestContextTransitionEpoch != transitionEpoch) return
        val headersChanged = headers != newHeaders
        val serverUrls = origins.map(CanonicalOrigin::asString)
        val encodedServerUrls = Json.encodeToString(serverUrls)
        val urlsChanged = encodedServerUrls != prefs.getString(PREFS_SERVER_URLS, null)

        cookieJar.clearAuthCookies()
        headers = newHeaders
        activeOrigins = origins
        requestContextFingerprint = newFingerprint
        cookieJar.setAllowedOrigins(origins)
        requestContextGeneration++
        requestContextSessionEpoch = sessionEpoch
        requestContextConfirmed = confirmed
        requestContextReplacing = false
        remoteImageAdmissionGate.replace(remoteImageContextSnapshot())

        if (headersChanged || urlsChanged) {
          prefs.edit {
            putString(PREFS_HEADERS, Json.encodeToString(headerMap))
            putString(PREFS_SERVER_URLS, encodedServerUrls)
          }
        }

        if (token != null) {
          val expiry = System.currentTimeMillis() + COOKIE_EXPIRY_DAYS * 24 * 60 * 60 * 1000
          val values =
            mapOf(
              AuthCookie.ACCESS_TOKEN to token,
              AuthCookie.IS_AUTHENTICATED to "true",
              AuthCookie.AUTH_TYPE to "password",
            )
          for (origin in origins) {
            val url = origin.toHttpUrl()
            cookieJar.saveFromResponse(
              url,
              values.map { (cookie, value) ->
                Cookie
                  .Builder()
                  .name(cookie.cookieName)
                  .value(value)
                  .hostOnlyDomain(url.host)
                  .path("/")
                  .expiresAt(expiry)
                  .apply {
                    if (url.isHttps) secure()
                    if (cookie.httpOnly) httpOnly()
                  }.build()
              },
            )
          }
        }
        clientChangedListeners.toList() to transitionEpoch
      }
    notifyClientChanged(publication.first)
    if (confirmed) NetworkContextBoundWorkRegistry.reopenAll(publication.second)
    cancellationError?.let { throw it }
  }

  private fun cancelOkHttpWorkAndAwaitIdle(): CompletableFuture<Unit> {
    val dispatcher = client.dispatcher
    lateinit var onIdle: Runnable
    val drained =
      synchronized(okHttpDrainLock) {
        pendingOkHttpDrain?.let { return it }
        val drained = CompletableFuture<Unit>()
        val completed = AtomicBoolean(false)
        val previousIdleCallback = dispatcher.idleCallback
        onIdle =
          Runnable {
            if (!completed.compareAndSet(false, true)) return@Runnable
            if (dispatcher.idleCallback === onIdle) dispatcher.idleCallback = previousIdleCallback
            try {
              previousIdleCallback?.run()
            } finally {
              drained.complete(Unit)
            }
          }
        dispatcher.idleCallback = onIdle
        pendingOkHttpDrain = drained
        drained.whenComplete { _, _ ->
          synchronized(okHttpDrainLock) {
            if (pendingOkHttpDrain === drained) pendingOkHttpDrain = null
          }
        }
        drained
      }
    dispatcher.cancelAll()
    if (dispatcher.queuedCallsCount() == 0 && dispatcher.runningCallsCount() == 0) {
      onIdle.run()
    }
    return drained
  }

  private fun listenersForChange(changed: Boolean): List<() -> Unit> = if (changed) clientChangedListeners.toList() else emptyList()

  private fun notifyClientChanged(listeners: List<() -> Unit>) {
    listeners.forEach { it() }
  }

  fun loadCookieHeader(url: String): String? {
    val httpUrl = url.toHttpUrlOrNull() ?: return null
    return cookieJar
      .loadForRequest(httpUrl)
      .takeIf { it.isNotEmpty() }
      ?.joinToString("; ") { "${it.name}=${it.value}" }
  }

  fun getAuthHeaders(url: String): Map<String, String> {
    val httpUrl = url.toHttpUrlOrNull() ?: return emptyMap()
    val context =
      synchronized(this) {
        Triple(activeOrigins, headers, requestContextConfirmed && !requestContextReplacing)
      }
    if (!context.third || context.first.none { it.matches(httpUrl) }) return emptyMap()
    val result = mutableMapOf<String, String>()
    context.second.forEach { (key, value) -> result[key] = value }
    loadCookieHeader(url)?.let { result["Cookie"] = it }
    return result
  }

  fun captureRemoteImageAuthorization(
    url: String,
    declaredOrigin: String,
    expectedGeneration: Long,
  ): RemoteImageAuthorization? =
    synchronized(this) {
      val requestHeaders =
        buildMap {
          headers.forEach { (key, value) -> put(key, value) }
          loadCookieHeader(url)?.let { put("Cookie", it) }
        }
      remoteImageAdmissionGate.capture(url, declaredOrigin, expectedGeneration, requestHeaders)
    }

  fun admitRemoteImageRequest(
    authorization: RemoteImageAuthorization,
    start: () -> Unit,
  ): Boolean = remoteImageAdmissionGate.admit(authorization, start)

  fun claimRemoteImageCompletion(authorization: RemoteImageAuthorization): RemoteImageCacheClaim? =
    remoteImageAdmissionGate.claimCompletion(authorization)

  fun claimRemoteImageCacheRead(
    url: String,
    declaredOrigin: String,
    expectedGeneration: Long,
  ): RemoteImageCacheClaim? = remoteImageAdmissionGate.claimCache(url, declaredOrigin, expectedGeneration)

  fun deliverRemoteImageCache(
    claim: RemoteImageCacheClaim,
    callback: () -> Unit,
  ): Boolean = remoteImageAdmissionGate.deliver(claim, callback)

  fun currentRemoteImageCacheScope(): RemoteImageCacheScope? = remoteImageAdmissionGate.currentScope()

  fun isRemoteImageContextCurrent(
    url: String,
    declaredOrigin: String,
    expectedGeneration: Long,
  ): Boolean = remoteImageAdmissionGate.matches(url, declaredOrigin, expectedGeneration)

  private fun remoteImageContextSnapshot() =
    RemoteImageContextSnapshot(
      canonicalOrigin = activeOrigins.singleOrNull()?.asString(),
      generation = requestContextGeneration,
      confirmed = requestContextConfirmed,
      replacing = requestContextReplacing,
      cacheIdentity = requestContextFingerprint?.cacheIdentity(),
    )

  suspend fun rebuildCronetEngine(): Result<Long> =
    runCatching {
      cronetEngine?.shutdown()
      val deletionResult = deleteFolderAndGetSize(cronetStoragePath.toPath())
      cronetEngine = buildCronetEngine()
      deletionResult
    }

  val cronetStoragePath: File get() = cronetStorageDir

  @OptIn(UnstableApi::class)
  fun createDataSourceFactory(headers: Map<String, String>): DataSource.Factory {
    val delegate =
      ResolvingDataSource.Factory(
        OkHttpDataSource.Factory(buildContextBoundMediaClient()),
      ) { dataSpec ->
        val newHeaders = dataSpec.httpRequestHeaders.toMutableMap()
        newHeaders.putAll(getAuthHeaders(dataSpec.uri.toString()))
        newHeaders["Cache-Control"] = "no-store"
        dataSpec.buildUpon().setHttpRequestHeaders(newHeaders).build()
      }
    return ContextBoundDataSourceFactory(delegate)
  }

  private fun buildContextBoundMediaClient(): OkHttpClient =
    client.newBuilder().cache(null).build().also { mediaClient ->
      check(mediaClient.dispatcher === client.dispatcher) {
        "Media requests must share the request-context dispatcher"
      }
    }

  fun buildCronetEngine(): CronetEngine =
    CronetEngine
      .Builder(appContext)
      .enableHttp2(true)
      .enableQuic(true)
      .enableBrotli(true)
      .setStoragePath(cronetStorageDir.absolutePath)
      .setUserAgent(USER_AGENT)
      .enableHttpCache(CronetEngine.Builder.HTTP_CACHE_DISK, MEDIA_CACHE_SIZE_BYTES)
      .build()

  private suspend fun deleteFolderAndGetSize(root: Path): Long =
    withContext(Dispatchers.IO) {
      var totalSize = 0L

      Files.walkFileTree(
        root,
        object : SimpleFileVisitor<Path>() {
          override fun visitFile(
            file: Path,
            attrs: BasicFileAttributes,
          ): FileVisitResult {
            totalSize += attrs.size()
            Files.delete(file)
            return FileVisitResult.CONTINUE
          }

          override fun postVisitDirectory(
            dir: Path,
            exc: IOException?,
          ): FileVisitResult {
            if (dir != root) {
              Files.delete(dir)
            }
            return FileVisitResult.CONTINUE
          }
        },
      )

      totalSize
    }

  private fun build(cacheDir: File): OkHttpClient {
    val connectionPool =
      ConnectionPool(
        maxIdleConnections = KEEP_ALIVE_CONNECTIONS,
        keepAliveDuration = KEEP_ALIVE_DURATION_MINUTES,
        timeUnit = TimeUnit.MINUTES,
      )

    val managerFactory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
    managerFactory.init(null as KeyStore?)
    val trustManager = managerFactory.trustManagers.filterIsInstance<X509TrustManager>().first()

    val sslContext =
      SSLContext
        .getInstance("TLS")
        .apply { init(arrayOf(DynamicKeyManager()), arrayOf(trustManager), null) }
    HttpsURLConnection.setDefaultSSLSocketFactory(sslContext.socketFactory)

    return OkHttpClient
      .Builder()
      .cookieJar(cookieJar)
      .addNetworkInterceptor {
        val request = it.request()
        val context =
          synchronized(HttpClientManager) {
            Triple(activeOrigins, headers, requestContextConfirmed && !requestContextReplacing)
          }
        if (request.url.encodedUsername.isNotEmpty() || request.url.encodedPassword.isNotEmpty()) {
          throw IOException("Request URLs must not contain user information")
        }
        if (!context.third) {
          throw IOException("Request rejected while the native request context is fenced")
        }
        if (context.first.isNotEmpty() && context.first.none { origin -> origin.matches(request.url) }) {
          throw IOException("Request rejected outside the active server origins")
        }
        val builder = request.newBuilder()
        builder.header("User-Agent", USER_AGENT)
        if (context.first.isNotEmpty()) {
          context.second.forEach { (key, value) -> builder.header(key, value) }
        }
        it.proceed(builder.build())
      }.connectionPool(connectionPool)
      .dispatcher(Dispatcher().apply { maxRequestsPerHost = MAX_REQUESTS_PER_HOST })
      .cache(Cache(cacheDir.apply { mkdirs() }, CACHE_SIZE_BYTES))
      .sslSocketFactory(sslContext.socketFactory, trustManager)
      .build()
  }

  /**
   * Resolves client certificates dynamically at TLS handshake time.
   * Checks the system KeyChain alias first, then falls back to the app's private KeyStore.
   */
  private class DynamicKeyManager : X509KeyManager {
    override fun getClientAliases(
      keyType: String,
      issuers: Array<Principal>?,
    ): Array<String>? {
      val alias = chooseClientAlias(arrayOf(keyType), issuers, null) ?: return null
      return arrayOf(alias)
    }

    override fun chooseClientAlias(
      keyTypes: Array<String>,
      issuers: Array<Principal>?,
      socket: Socket?,
    ): String? {
      keyChainAlias?.let { return it }
      if (keyStore.containsAlias(CERT_ALIAS)) return CERT_ALIAS
      return null
    }

    override fun getCertificateChain(alias: String): Array<X509Certificate>? {
      if (alias == keyChainAlias) {
        return KeyChain.getCertificateChain(appContext, alias)
      }
      return keyStore.getCertificateChain(alias)?.map { it as X509Certificate }?.toTypedArray()
    }

    override fun getPrivateKey(alias: String): PrivateKey? {
      if (alias == keyChainAlias) {
        return KeyChain.getPrivateKey(appContext, alias)
      }
      return keyStore.getKey(alias, null) as? PrivateKey
    }

    override fun getServerAliases(
      keyType: String,
      issuers: Array<Principal>?,
    ): Array<String>? = null

    override fun chooseServerAlias(
      keyType: String,
      issuers: Array<Principal>?,
      socket: Socket?,
    ): String? = null
  }

  /**
   * Persistent CookieJar that emits authentication cookies only for explicitly allowed origins.
   */
  private class PersistentCookieJar : CookieJar {
    private val store = mutableListOf<Cookie>()
    private var allowedOrigins = emptyList<CanonicalOrigin>()
    private var prefs: SharedPreferences? = null

    fun init(prefs: SharedPreferences) {
      this.prefs = prefs
      restore()
    }

    @Synchronized
    fun setAllowedOrigins(origins: List<CanonicalOrigin>) {
      allowedOrigins = origins
    }

    @Synchronized
    fun clearAuthCookies() {
      if (store.removeAll { it.name in AuthCookie.names }) persist()
    }

    @Synchronized
    override fun saveFromResponse(
      url: HttpUrl,
      cookies: List<Cookie>,
    ) {
      val accepted = cookies.filter { it.name !in AuthCookie.names || allowedOrigins.any { origin -> origin.matches(url) } }
      var changed = false
      for (newCookie in accepted) {
        val matching =
          store.filter {
            it.name == newCookie.name && it.domain == newCookie.domain && it.path == newCookie.path
          }
        if (matching.size == 1 && matching.single() == newCookie) continue
        store.removeAll { it in matching }
        store.add(newCookie)
        changed = true
      }
      if (changed) persist()
    }

    @Synchronized
    override fun loadForRequest(url: HttpUrl): List<Cookie> {
      val now = System.currentTimeMillis()
      if (store.removeAll { it.expiresAt < now }) {
        persist()
      }
      val originAllowed = allowedOrigins.any { it.matches(url) }
      return store.filter { cookie -> cookie.matches(url) && (cookie.name !in AuthCookie.names || originAllowed) }
    }

    private fun persist() {
      val p = prefs ?: return
      p.edit { putString(PREFS_COOKIES, Json.encodeToString(store.map { SerializedCookie.from(it) })) }
    }

    private fun restore() {
      val p = prefs ?: return
      val jsonStr = p.getString(PREFS_COOKIES, null) ?: return
      try {
        store.addAll(Json.decodeFromString<List<SerializedCookie>>(jsonStr).map { it.toCookie() })
      } catch (_: Exception) {
        store.clear()
      }
    }
  }

  @Serializable
  private data class SerializedCookie(
    val name: String,
    val value: String,
    val domain: String,
    val path: String,
    val expiresAt: Long,
    val secure: Boolean,
    val httpOnly: Boolean,
    val hostOnly: Boolean,
  ) {
    fun toCookie(): Cookie =
      Cookie
        .Builder()
        .name(name)
        .value(value)
        .path(path)
        .expiresAt(expiresAt)
        .apply {
          if (hostOnly) hostOnlyDomain(domain) else domain(domain)
          if (secure) secure()
          if (httpOnly) httpOnly()
        }.build()

    companion object {
      fun from(cookie: Cookie) =
        SerializedCookie(
          name = cookie.name,
          value = cookie.value,
          domain = cookie.domain,
          path = cookie.path,
          expiresAt = cookie.expiresAt,
          secure = cookie.secure,
          httpOnly = cookie.httpOnly,
          hostOnly = cookie.hostOnly,
        )
    }
  }
}
