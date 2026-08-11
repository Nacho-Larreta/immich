package app.alextran.immich.core

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.URI
import java.util.concurrent.CompletableFuture

internal data class CanonicalOrigin(
  val scheme: String,
  val host: String,
  val port: Int,
) {
  fun matches(url: HttpUrl): Boolean =
    url.encodedUsername.isEmpty() &&
      url.encodedPassword.isEmpty() &&
      url.scheme == scheme &&
      url.host == host &&
      url.port == port

  fun toHttpUrl(): HttpUrl =
    HttpUrl
      .Builder()
      .scheme(scheme)
      .host(host)
      .port(port)
      .build()

  fun asString(): String = URI(scheme, null, host, port, null, null, null).toString()

  companion object {
    fun fromStrictOrigin(value: String): CanonicalOrigin? {
      val uri = runCatching { URI(value) }.getOrNull() ?: return null
      if (uri.rawUserInfo != null || !uri.rawPath.isNullOrEmpty() || uri.rawQuery != null || uri.rawFragment != null) {
        return null
      }
      return fromHttpUrl(value.toHttpUrlOrNull())
    }

    fun fromEndpoint(value: String): CanonicalOrigin? {
      val uri = runCatching { URI(value) }.getOrNull() ?: return null
      if (uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) return null
      return fromHttpUrl(value.toHttpUrlOrNull())
    }

    private fun fromHttpUrl(url: HttpUrl?): CanonicalOrigin? {
      if (url == null || url.scheme !in setOf("http", "https") || url.encodedUsername.isNotEmpty() ||
        url.encodedPassword.isNotEmpty()
      ) {
        return null
      }
      return CanonicalOrigin(url.scheme, url.host, url.port)
    }
  }
}

internal data class RemoteImageCacheScope(
  val identity: String,
  val generation: Long,
) {
  init {
    require(identity.matches(Regex("[a-f0-9]{64}"))) { "Cache identity must be a SHA-256 digest" }
    require(generation >= 0) { "Cache generation must not be negative" }
  }

  val directoryName: String get() = "$identity-$generation"
}

internal data class RemoteImageAuthorization(
  val url: String,
  val declaredOrigin: String,
  val expectedGeneration: Long,
  val headers: Map<String, String>,
  val cacheScope: RemoteImageCacheScope,
) {
  fun redirectedTo(url: String): RemoteImageAuthorization = copy(url = url)
}

internal data class RemoteImageCacheClaim(
  val url: String,
  val declaredOrigin: String,
  val expectedGeneration: Long,
  val cacheScope: RemoteImageCacheScope,
)

internal data class RemoteImageContextSnapshot(
  val canonicalOrigin: String?,
  val generation: Long,
  val confirmed: Boolean,
  val replacing: Boolean,
  val cacheIdentity: String?,
) {
  fun capture(
    url: String,
    declaredOrigin: String,
    expectedGeneration: Long,
    headers: Map<String, String>,
  ): RemoteImageAuthorization? {
    val scope = matchingScope(url, declaredOrigin, expectedGeneration) ?: return null
    return RemoteImageAuthorization(url, declaredOrigin, expectedGeneration, headers.toMap(), scope)
  }

  fun claimCache(
    url: String,
    declaredOrigin: String,
    expectedGeneration: Long,
  ): RemoteImageCacheClaim? {
    val scope = matchingScope(url, declaredOrigin, expectedGeneration) ?: return null
    return RemoteImageCacheClaim(url, declaredOrigin, expectedGeneration, scope)
  }

  fun admit(
    authorization: RemoteImageAuthorization,
    claim: () -> Unit,
  ): Boolean {
    if (matchingScope(
        authorization.url,
        authorization.declaredOrigin,
        authorization.expectedGeneration,
      ) != authorization.cacheScope
    ) {
      return false
    }
    claim()
    return true
  }

  fun admit(claim: RemoteImageCacheClaim): Boolean =
    matchingScope(claim.url, claim.declaredOrigin, claim.expectedGeneration) == claim.cacheScope

  fun matches(
    url: String,
    declaredOrigin: String,
    expectedGeneration: Long,
  ): Boolean = matchingScope(url, declaredOrigin, expectedGeneration) != null

  private fun matchingScope(
    url: String,
    declaredOrigin: String,
    expectedGeneration: Long,
  ): RemoteImageCacheScope? {
    val resource = url.toHttpUrlOrNull() ?: return null
    val declared = CanonicalOrigin.fromStrictOrigin(declaredOrigin) ?: return null
    val active = canonicalOrigin?.let(CanonicalOrigin::fromStrictOrigin) ?: return null
    val identity = cacheIdentity ?: return null
    if (!confirmed || replacing || generation != expectedGeneration || active != declared || !declared.matches(resource)) {
      return null
    }
    return RemoteImageCacheScope(identity, generation)
  }
}

internal class RemoteImageAdmissionGate(
  initialSnapshot: RemoteImageContextSnapshot =
    RemoteImageContextSnapshot(
      canonicalOrigin = null,
      generation = 0,
      confirmed = false,
      replacing = true,
      cacheIdentity = null,
    ),
) {
  private var snapshot = initialSnapshot
  private var activeDeliveries = 0
  private var deliveryDrain: CompletableFuture<Unit>? = null

  @Synchronized
  fun replace(replacement: RemoteImageContextSnapshot) {
    check(activeDeliveries == 0) { "Cannot publish a remote image context while deliveries are active" }
    snapshot = replacement
  }

  @Synchronized
  fun fence(replacement: RemoteImageContextSnapshot): CompletableFuture<Unit> {
    snapshot = replacement
    if (activeDeliveries == 0) return CompletableFuture.completedFuture(Unit)
    return deliveryDrain ?: CompletableFuture<Unit>().also { deliveryDrain = it }
  }

  @Synchronized
  fun capture(
    url: String,
    declaredOrigin: String,
    expectedGeneration: Long,
    headers: Map<String, String>,
  ): RemoteImageAuthorization? = snapshot.capture(url, declaredOrigin, expectedGeneration, headers)

  @Synchronized
  fun admit(
    authorization: RemoteImageAuthorization,
    start: () -> Unit,
  ): Boolean = snapshot.admit(authorization, start)

  @Synchronized
  fun claimCompletion(authorization: RemoteImageAuthorization): RemoteImageCacheClaim? =
    snapshot
      .claimCache(authorization.url, authorization.declaredOrigin, authorization.expectedGeneration)
      ?.takeIf { it.cacheScope == authorization.cacheScope }

  @Synchronized
  fun claimCache(
    url: String,
    declaredOrigin: String,
    expectedGeneration: Long,
  ): RemoteImageCacheClaim? = snapshot.claimCache(url, declaredOrigin, expectedGeneration)

  fun deliver(
    claim: RemoteImageCacheClaim,
    callback: () -> Unit,
  ): Boolean {
    synchronized(this) {
      if (!snapshot.admit(claim)) return false
      activeDeliveries++
    }
    try {
      callback()
      return true
    } finally {
      val drained =
        synchronized(this) {
          activeDeliveries--
          if (activeDeliveries == 0) deliveryDrain.also { deliveryDrain = null } else null
        }
      drained?.complete(Unit)
    }
  }

  @Synchronized
  fun currentScope(): RemoteImageCacheScope? {
    val origin = snapshot.canonicalOrigin ?: return null
    return snapshot.claimCache(origin, origin, snapshot.generation)?.cacheScope
  }

  @Synchronized
  fun matches(
    url: String,
    declaredOrigin: String,
    expectedGeneration: Long,
  ): Boolean = snapshot.matches(url, declaredOrigin, expectedGeneration)
}
