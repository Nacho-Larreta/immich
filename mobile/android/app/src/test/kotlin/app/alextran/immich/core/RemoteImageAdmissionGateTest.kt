package app.alextran.immich.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class RemoteImageAdmissionGateTest {
  @Test
  fun `context transition cannot complete between cache admission and payload callback`() {
    val gate = RemoteImageAdmissionGate(confirmedSnapshot(generation = 1))
    val claim = requireNotNull(gate.claimCache(URL, ORIGIN, expectedGeneration = 1))
    val deliveryEntered = CountDownLatch(1)
    val releaseDelivery = CountDownLatch(1)
    val transitionStarted = CountDownLatch(1)
    val transitionCompleted = CountDownLatch(1)
    val deliveries = AtomicInteger()
    val executor = Executors.newFixedThreadPool(2)

    try {
      val delivery =
        executor.submit<Boolean> {
          gate.deliver(claim) {
            deliveryEntered.countDown()
            releaseDelivery.await()
            deliveries.incrementAndGet()
          }
        }
      assertTrue(deliveryEntered.await(2, TimeUnit.SECONDS))
      val transition =
        executor.submit {
          transitionStarted.countDown()
          gate.fence(confirmedSnapshot(generation = 2)).get(2, TimeUnit.SECONDS)
          transitionCompleted.countDown()
        }
      assertTrue(transitionStarted.await(2, TimeUnit.SECONDS))
      assertFalse(transitionCompleted.await(100, TimeUnit.MILLISECONDS))

      releaseDelivery.countDown()
      assertTrue(delivery.get(2, TimeUnit.SECONDS))
      transition.get(2, TimeUnit.SECONDS)
      assertEquals(1, deliveries.get())
      assertTrue(transitionCompleted.await(0, TimeUnit.MILLISECONDS))
    } finally {
      releaseDelivery.countDown()
      executor.shutdownNow()
    }
  }

  @Test
  fun `cache callback is rejected when transition wins the admission lock`() {
    val gate = RemoteImageAdmissionGate(confirmedSnapshot(generation = 1))
    val claim = requireNotNull(gate.claimCache(URL, ORIGIN, expectedGeneration = 1))
    var deliveries = 0

    gate.fence(confirmedSnapshot(generation = 2)).get(2, TimeUnit.SECONDS)

    assertFalse(gate.deliver(claim) { deliveries++ })
    assertEquals(0, deliveries)
  }

  private fun confirmedSnapshot(generation: Long) =
    RemoteImageContextSnapshot(
      canonicalOrigin = ORIGIN,
      generation = generation,
      confirmed = true,
      replacing = false,
      cacheIdentity = "d".repeat(64),
    )

  private companion object {
    const val ORIGIN = "https://photos.test"
    const val URL = "$ORIGIN/api/assets/id/thumbnail"
  }
}
