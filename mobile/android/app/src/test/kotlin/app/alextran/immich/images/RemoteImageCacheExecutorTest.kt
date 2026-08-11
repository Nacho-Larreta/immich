package app.alextran.immich.images

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class RemoteImageCacheExecutorTest {
  @Test
  fun `cache work runs off caller thread on a bounded queue`() {
    val executor = RemoteImageCacheExecutor(queueCapacity = 1)
    val release = CountDownLatch(1)
    val firstStarted = CountDownLatch(1)
    val workerThread = AtomicReference<String>()

    assertTrue(
      executor.execute {
        workerThread.set(Thread.currentThread().name)
        firstStarted.countDown()
        release.await()
      },
    )
    assertTrue(firstStarted.await(2, TimeUnit.SECONDS))
    assertTrue(executor.execute {})
    assertFalse(executor.execute {})
    release.countDown()
    executor.close()

    assertFalse(workerThread.get().contains("main", ignoreCase = true))
  }

  @Test
  fun `pending byte reservations reject work before copying can exceed the memory budget`() {
    val executor = RemoteImageCacheExecutor(queueCapacity = 4, maxPendingBytes = 8)
    val first = executor.reserve(weightBytes = 6)

    assertNotNull(first)
    assertNull(executor.reserve(weightBytes = 3))
    val remaining = executor.reserve(weightBytes = 2)
    assertNotNull(remaining)

    first!!.close()
    remaining!!.close()
    assertNotNull(executor.reserve(weightBytes = 8)?.also { it.close() })
    executor.close()
  }

  @Test
  fun `serialized stale write followed by purge cannot recreate the previous scope`() {
    val root =
      java.nio.file.Files
        .createTempDirectory("remote-image-cache-ordering")
        .toFile()
    val cache = RemoteImageDiskCache(root, maxEntryBytes = 8, maxTotalBytes = 16, maxEntries = 2)
    val executor = RemoteImageCacheExecutor(queueCapacity = 2, maxPendingBytes = 8)
    val oldScope =
      app.alextran.immich.core
        .RemoteImageCacheScope("a".repeat(64), generation = 1)
    val newScope =
      app.alextran.immich.core
        .RemoteImageCacheScope("b".repeat(64), generation = 2)
    val writeStarted = CountDownLatch(1)
    val releaseWrite = CountDownLatch(1)
    val purgeCompleted = CountDownLatch(1)
    val url = "https://photos.test/api/assets/id/thumbnail"

    try {
      assertTrue(
        executor.execute {
          writeStarted.countDown()
          releaseWrite.await()
          cache.write(oldScope, url, byteArrayOf(1, 2, 3))
        },
      )
      assertTrue(writeStarted.await(2, TimeUnit.SECONDS))
      val purge =
        executor.submitBarrier {
          cache.retainOnly(newScope)
          purgeCompleted.countDown()
        }

      releaseWrite.countDown()
      purge.get(2, TimeUnit.SECONDS)
      assertTrue(purgeCompleted.await(2, TimeUnit.SECONDS))
      assertNull(cache.read(oldScope, url))
    } finally {
      releaseWrite.countDown()
      executor.close()
      root.deleteRecursively()
    }
  }

  @Test
  fun `saturated queue still admits a non rejectable logout barrier after every prior write`() {
    val executor = RemoteImageCacheExecutor(queueCapacity = 1, maxPendingBytes = 8)
    val release = CountDownLatch(1)
    val running = CountDownLatch(1)
    val order = mutableListOf<String>()

    try {
      assertTrue(
        executor.execute {
          running.countDown()
          release.await()
          synchronized(order) { order.add("running") }
        },
      )
      assertTrue(running.await(2, TimeUnit.SECONDS))
      assertTrue(executor.execute { synchronized(order) { order.add("queued") } })

      val barrier = executor.submitBarrier { synchronized(order) { order.add("logout") } }
      assertFalse(executor.execute { synchronized(order) { order.add("stale") } })
      release.countDown()
      barrier.get(2, TimeUnit.SECONDS)

      assertTrue(order == listOf("running", "queued", "logout"))
    } finally {
      release.countDown()
      executor.close()
    }
  }

  @Test
  fun `write followed by clear barrier cannot recreate cleared bytes`() {
    val root = java.nio.file.Files.createTempDirectory("remote-image-cache-clear-ordering").toFile()
    val cache = RemoteImageDiskCache(root, maxEntryBytes = 8, maxTotalBytes = 16, maxEntries = 2)
    val executor = RemoteImageCacheExecutor(queueCapacity = 1, maxPendingBytes = 8)
    val scope = app.alextran.immich.core.RemoteImageCacheScope("c".repeat(64), generation = 3)
    val url = "https://photos.test/api/assets/id/thumbnail"

    try {
      assertTrue(executor.execute { cache.write(scope, url, byteArrayOf(1, 2, 3)) })
      executor.submitBarrier { cache.clear() }.get(2, TimeUnit.SECONDS)
      assertNull(cache.read(scope, url))
    } finally {
      executor.close()
      root.deleteRecursively()
    }
  }
}
