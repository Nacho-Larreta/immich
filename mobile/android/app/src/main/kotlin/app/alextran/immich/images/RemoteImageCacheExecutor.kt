package app.alextran.immich.images

import java.io.Closeable
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal class RemoteImageCacheExecutor(
  queueCapacity: Int = DEFAULT_QUEUE_CAPACITY,
  private val maxPendingBytes: Long = DEFAULT_MAX_PENDING_BYTES,
) : Closeable {
  private val executor: ThreadPoolExecutor
  private val barrierAdmission = Executors.newSingleThreadExecutor { work ->
    Thread(work, "immich-remote-image-cache-barrier").apply { isDaemon = true }
  }
  private val submissionLock = Any()
  private val pendingBytesLock = Any()
  private var pendingBytes = 0L
  private var pendingBarriers = 0
  private var closed = false

  init {
    require(queueCapacity > 0) { "Cache queue capacity must be positive" }
    require(maxPendingBytes > 0) { "Pending cache byte limit must be positive" }
    executor =
      ThreadPoolExecutor(
        1,
        1,
        0,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(queueCapacity),
        { work -> Thread(work, "immich-remote-image-cache").apply { isDaemon = true } },
        ThreadPoolExecutor.AbortPolicy(),
      )
    executor.prestartCoreThread()
  }

  fun execute(work: () -> Unit): Boolean = synchronized(submissionLock) {
    if (closed || pendingBarriers > 0) return false
    return try {
      executor.execute(work)
      true
    } catch (_: RejectedExecutionException) {
      false
    }
  }

  fun <T> submitBarrier(work: () -> T): CompletableFuture<T> {
    val completion = CompletableFuture<T>()
    synchronized(submissionLock) {
      if (closed) {
        completion.completeExceptionally(RejectedExecutionException("Cache executor is closed"))
        return completion
      }
      pendingBarriers++
    }
    barrierAdmission.execute {
      try {
        executor.queue.put {
          try {
            completion.complete(work())
          } catch (error: Throwable) {
            completion.completeExceptionally(error)
          } finally {
            synchronized(submissionLock) { pendingBarriers-- }
          }
        }
      } catch (error: Throwable) {
        synchronized(submissionLock) { pendingBarriers-- }
        completion.completeExceptionally(error)
      }
    }
    return completion
  }

  fun reserve(weightBytes: Long): Reservation? {
    require(weightBytes >= 0) { "Cache work weight must not be negative" }
    synchronized(pendingBytesLock) {
      if (weightBytes > maxPendingBytes - pendingBytes) return null
      pendingBytes += weightBytes
    }
    return Reservation(weightBytes)
  }

  inner class Reservation internal constructor(
    private val weightBytes: Long,
  ) : Closeable {
    private val consumed = AtomicBoolean(false)

    fun execute(work: () -> Unit): Boolean {
      check(consumed.compareAndSet(false, true)) { "Cache reservation already consumed" }
      val accepted =
        this@RemoteImageCacheExecutor.execute {
          try {
            work()
          } finally {
            release(weightBytes)
          }
        }
      if (!accepted) release(weightBytes)
      return accepted
    }

    override fun close() {
      if (consumed.compareAndSet(false, true)) release(weightBytes)
    }
  }

  private fun release(weightBytes: Long) {
    synchronized(pendingBytesLock) {
      pendingBytes -= weightBytes
      check(pendingBytes >= 0) { "Pending cache byte accounting underflow" }
    }
  }

  override fun close() {
    synchronized(submissionLock) { closed = true }
    barrierAdmission.shutdown()
    if (!barrierAdmission.awaitTermination(5, TimeUnit.SECONDS)) barrierAdmission.shutdownNow()
    executor.shutdown()
    if (!executor.awaitTermination(5, TimeUnit.SECONDS)) executor.shutdownNow()
  }

  private companion object {
    const val DEFAULT_QUEUE_CAPACITY = 64
    const val DEFAULT_MAX_PENDING_BYTES = 128L * 1024 * 1024
  }
}
