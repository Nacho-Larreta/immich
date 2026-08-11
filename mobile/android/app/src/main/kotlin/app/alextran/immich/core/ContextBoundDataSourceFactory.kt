package app.alextran.immich.core

import android.net.Uri
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.io.IOException
import java.util.concurrent.CompletableFuture

internal class ContextBoundDataSourceFactory(
  private val delegate: DataSource.Factory,
) : DataSource.Factory {
  init {
    ContextBoundDataSources.register()
  }

  override fun createDataSource(): DataSource = ContextBoundDataSource(delegate.createDataSource())
}

private object ContextBoundDataSources : NetworkContextBoundWork {
  private val active = mutableSetOf<ContextBoundDataSource>()
  private val pendingDrains = mutableMapOf<Long, DataSourceDrain>()
  private var fenced = false
  private var phaseRevision = 0L

  fun register() {
    NetworkContextBoundWorkRegistry.register(this)
  }

  fun admit(dataSource: ContextBoundDataSource): Boolean =
    synchronized(this) {
      if (fenced) return false
      active.add(dataSource)
      true
    }

  fun complete(dataSource: ContextBoundDataSource) {
    val drained =
      synchronized(this) {
        if (!active.remove(dataSource)) return
        pendingDrains.values.forEach { it.remaining.remove(dataSource) }
        val completed = pendingDrains.filterValues { it.remaining.isEmpty() }
        completed.keys.forEach(pendingDrains::remove)
        completed.values.map { it.future }
      }
    drained.forEach { it.complete(Unit) }
  }

  override fun fenceAndCancel(phase: NetworkContextWorkPhase): CompletableFuture<Unit> {
    val cancellation =
      synchronized(this) {
        if (phase.revision < phaseRevision) return CompletableFuture.completedFuture(Unit)
        phaseRevision = phase.revision
        fenced = true
        val dataSources = active.toList()
        val drained =
          if (dataSources.isEmpty()) {
            CompletableFuture.completedFuture(Unit)
          } else {
            pendingDrains
              .getOrPut(phase.transitionEpoch) {
                DataSourceDrain(dataSources.toMutableSet(), CompletableFuture())
              }.future
          }
        dataSources to drained
      }

    var cancellationFailure: IOException? = null
    cancellation.first.forEach { dataSource ->
      try {
        dataSource.cancel()
      } catch (error: IOException) {
        cancellationFailure = cancellationFailure ?: error
      }
    }
    val failure = cancellationFailure ?: return cancellation.second
    return cancellation.second.thenCompose {
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
}

private data class DataSourceDrain(
  val remaining: MutableSet<ContextBoundDataSource>,
  val future: CompletableFuture<Unit>,
)

private class ContextBoundDataSource(
  private val delegate: DataSource,
) : DataSource {
  private val lifecycleLock = Any()
  private var admitted = false
  private var opening = false
  private var closeRequested = false
  private var closeAcknowledged = false
  private var delegateCloseStarted = false
  private var activeReads = 0
  private var transitionCanceled = false

  override fun addTransferListener(transferListener: TransferListener) {
    delegate.addTransferListener(transferListener)
  }

  override fun open(dataSpec: DataSpec): Long {
    synchronized(lifecycleLock) {
      if (transitionCanceled || !ContextBoundDataSources.admit(this)) {
        transitionCanceled = true
        throw IOException("Native media request rejected while the request context is fenced")
      }
      admitted = true
      opening = true
      closeAcknowledged = false
      delegateCloseStarted = false
    }

    val openedLength: Long
    try {
      openedLength = delegate.open(dataSpec)
    } catch (error: Exception) {
      synchronized(lifecycleLock) {
        opening = false
      }
      try {
        closeDelegateOnce()
      } finally {
        acknowledgeClose()
      }
      throw error
    }

    val mustClose =
      synchronized(lifecycleLock) {
        opening = false
        closeRequested
      }
    if (!mustClose) return openedLength

    try {
      closeDelegateOnce()
    } finally {
      acknowledgeClose()
    }
    throw IOException("Native media request was canceled during request context transition")
  }

  override fun read(
    buffer: ByteArray,
    offset: Int,
    length: Int,
  ): Int {
    synchronized(lifecycleLock) {
      if (!admitted || closeRequested || transitionCanceled) {
        throw IOException("Native media read rejected while the request context is fenced")
      }
      activeReads++
    }
    try {
      val bytesRead = delegate.read(buffer, offset, length)
      if (synchronized(lifecycleLock) { transitionCanceled }) {
        throw IOException("Native media read canceled during request context transition")
      }
      return bytesRead
    } finally {
      val shouldFinish =
        synchronized(lifecycleLock) {
          activeReads--
          closeAcknowledged && activeReads == 0
        }
      if (shouldFinish) finishAdmission()
    }
  }

  override fun getUri(): Uri? = delegate.uri

  override fun getResponseHeaders(): Map<String, List<String>> = delegate.responseHeaders

  override fun close() {
    closeDelegate(terminal = false)
  }

  @Throws(IOException::class)
  fun cancel() {
    closeDelegate(terminal = true)
  }

  private fun closeDelegate(terminal: Boolean) {
    val closeNow =
      synchronized(lifecycleLock) {
        if (terminal) transitionCanceled = true
        if (closeRequested || !admitted) return
        closeRequested = true
        !opening
      }
    if (!closeNow) return
    try {
      closeDelegateOnce()
    } finally {
      acknowledgeClose()
    }
  }

  private fun closeDelegateOnce() {
    synchronized(lifecycleLock) {
      if (delegateCloseStarted) return
      delegateCloseStarted = true
    }
    delegate.close()
  }

  private fun acknowledgeClose() {
    val shouldFinish =
      synchronized(lifecycleLock) {
        closeAcknowledged = true
        !opening && activeReads == 0
      }
    if (shouldFinish) finishAdmission()
  }

  private fun finishAdmission() {
    val shouldComplete =
      synchronized(lifecycleLock) {
        if (!admitted) return
        admitted = false
        opening = false
        closeRequested = false
        closeAcknowledged = false
        delegateCloseStarted = false
        true
      }
    if (shouldComplete) ContextBoundDataSources.complete(this)
  }
}
