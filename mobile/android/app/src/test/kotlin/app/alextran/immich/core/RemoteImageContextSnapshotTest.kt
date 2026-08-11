package app.alextran.immich.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class RemoteImageContextSnapshotTest {
  @Test
  fun `generation change after credential capture rejects network admission`() {
    val generationN = confirmedSnapshot(generation = 7)
    val authorization =
      generationN.capture(
        url = "https://photos.test/api/assets/id/thumbnail",
        declaredOrigin = "https://photos.test",
        expectedGeneration = 7,
        headers = mapOf("Cookie" to "redacted"),
      )
    var networkStarts = 0

    val admitted = confirmedSnapshot(generation = 8).admit(requireNotNull(authorization)) { networkStarts++ }

    assertFalse(admitted)
    assertEquals(0, networkStarts)
  }

  @Test
  fun `confirmed exact origin and generation admit one network start`() {
    val snapshot = confirmedSnapshot(generation = 11)
    val authorization =
      snapshot.capture(
        url = "https://photos.test/api/assets/id/thumbnail",
        declaredOrigin = "https://photos.test",
        expectedGeneration = 11,
        headers = emptyMap(),
      )
    var networkStarts = 0

    val admitted = snapshot.admit(requireNotNull(authorization)) { networkStarts++ }

    assertTrue(admitted)
    assertEquals(1, networkStarts)
  }

  @Test
  fun `cross-origin resource never captures credentials`() {
    val authorization =
      confirmedSnapshot(generation = 3).capture(
        url = "https://attacker.test/asset",
        declaredOrigin = "https://photos.test",
        expectedGeneration = 3,
        headers = mapOf("Cookie" to "redacted"),
      )

    assertNull(authorization)
  }

  @Test
  fun `concurrent transition between capture and admission starts no network`() {
    assertTransitionRejects { snapshot, authorization, starts ->
      snapshot.admit(authorization) { starts.incrementAndGet() }
    }
  }

  @Test
  fun `concurrent transition before redirect hop starts no target request`() {
    assertTransitionRejects { snapshot, authorization, starts ->
      snapshot.admit(authorization.redirectedTo("https://photos.test/redirected")) { starts.incrementAndGet() }
    }
  }

  @Test
  fun `concurrent transition before completion delivers no payload`() {
    assertTransitionRejects { snapshot, authorization, deliveries ->
      val completion =
        RemoteImageCacheClaim(
          url = authorization.url,
          declaredOrigin = authorization.declaredOrigin,
          expectedGeneration = authorization.expectedGeneration,
          cacheScope = authorization.cacheScope,
        )
      snapshot.admit(completion).also { admitted ->
        if (admitted) deliveries.incrementAndGet()
      }
    }
  }

  private fun assertTransitionRejects(action: (RemoteImageContextSnapshot, RemoteImageAuthorization, AtomicInteger) -> Boolean) {
    val current = AtomicReference(confirmedSnapshot(generation = 17))
    val captured = AtomicReference<RemoteImageAuthorization>()
    val captureFinished = CountDownLatch(1)
    val transitionFinished = CountDownLatch(1)
    val effects = AtomicInteger()

    val executor = Executors.newFixedThreadPool(2)
    try {
      val requester =
        executor.submit<Boolean> {
          captured.set(
            requireNotNull(
              current.get().capture(
                url = "https://photos.test/api/assets/id/thumbnail",
                declaredOrigin = "https://photos.test",
                expectedGeneration = 17,
                headers = mapOf("Cookie" to "redacted"),
              ),
            ),
          )
          captureFinished.countDown()
          transitionFinished.await()
          action(current.get(), captured.get(), effects)
        }
      val transition =
        executor.submit {
          captureFinished.await()
          current.set(confirmedSnapshot(generation = 18))
          transitionFinished.countDown()
        }

      assertFalse(requester.get(2, TimeUnit.SECONDS))
      transition.get(2, TimeUnit.SECONDS)
      assertEquals(0, effects.get())
    } finally {
      executor.shutdownNow()
    }
  }

  private fun confirmedSnapshot(generation: Long) =
    RemoteImageContextSnapshot(
      canonicalOrigin = "https://photos.test",
      generation = generation,
      confirmed = true,
      replacing = false,
      cacheIdentity = "d".repeat(64),
    )
}
