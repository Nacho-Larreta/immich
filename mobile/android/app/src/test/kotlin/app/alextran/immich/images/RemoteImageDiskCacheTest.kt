package app.alextran.immich.images

import app.alextran.immich.core.RemoteImageCacheScope
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.nio.file.Files

class RemoteImageDiskCacheTest {
  private lateinit var root: java.io.File
  private lateinit var cache: RemoteImageDiskCache
  private val scope = RemoteImageCacheScope("f".repeat(64), generation = 1)

  @Before
  fun setUp() {
    root = Files.createTempDirectory("remote-image-cache-test").toFile()
    cache = RemoteImageDiskCache(root)
  }

  @After
  fun tearDown() {
    root.deleteRecursively()
  }

  @Test
  fun `cache miss returns no bytes without creating an entry`() {
    assertNull(cache.read(scope, "https://photos.test/api/assets/missing/thumbnail"))
    assertEquals(emptyList<String>(), root.list()?.toList())
  }

  @Test
  fun `cache hit returns the exact stored bytes and clear accounts for them`() {
    val url = "https://photos.test/api/assets/asset-id/thumbnail"
    val bytes = byteArrayOf(1, 3, 3, 7)

    cache.write(scope, url, bytes)

    assertArrayEquals(bytes, cache.read(scope, url))
    assertEquals(bytes.size.toLong(), cache.clear())
    assertNull(cache.read(scope, url))
  }

  @Test
  fun `cache isolates identities and purges every stale context generation`() {
    cache = RemoteImageDiskCache(root, maxEntryBytes = 8, maxTotalBytes = 8, maxEntries = 2)
    val first = RemoteImageCacheScope("a".repeat(64), generation = 1)
    val second = RemoteImageCacheScope("b".repeat(64), generation = 2)
    val url = "https://photos.test/api/assets/asset-id/thumbnail"

    cache.write(first, url, byteArrayOf(1, 1, 1, 1))
    cache.write(second, url, byteArrayOf(2, 2, 2, 2))

    assertArrayEquals(byteArrayOf(1, 1, 1, 1), cache.read(first, url))
    assertArrayEquals(byteArrayOf(2, 2, 2, 2), cache.read(second, url))
    cache.retainOnly(second)
    assertNull(cache.read(first, url))
    assertArrayEquals(byteArrayOf(2, 2, 2, 2), cache.read(second, url))
  }

  @Test
  fun `cache evicts least recently used entries within byte and count bounds`() {
    cache = RemoteImageDiskCache(root, maxEntryBytes = 4, maxTotalBytes = 6, maxEntries = 2)
    val scope = RemoteImageCacheScope("c".repeat(64), generation = 3)

    cache.write(scope, "https://photos.test/first", byteArrayOf(1, 1, 1))
    cache.write(scope, "https://photos.test/second", byteArrayOf(2, 2, 2))
    cache.read(scope, "https://photos.test/first")
    cache.write(scope, "https://photos.test/third", byteArrayOf(3, 3, 3))

    assertArrayEquals(byteArrayOf(1, 1, 1), cache.read(scope, "https://photos.test/first"))
    assertNull(cache.read(scope, "https://photos.test/second"))
    assertArrayEquals(byteArrayOf(3, 3, 3), cache.read(scope, "https://photos.test/third"))
    assertTrue(root.walkTopDown().filter { it.isFile }.sumOf { it.length() } <= 6)
  }
}
