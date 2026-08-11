package app.alextran.immich.core

import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

data class NetworkContextWorkPhase(
  val transitionEpoch: Long,
  val revision: Long,
)

interface NetworkContextBoundWork {
  fun fenceAndCancel(phase: NetworkContextWorkPhase): CompletableFuture<Unit>

  fun reopen(phase: NetworkContextWorkPhase)
}

object NetworkContextBoundWorkRegistry {
  private const val REGISTRATION_DRAIN_TIMEOUT_SECONDS = 10L
  private val participants = mutableSetOf<NetworkContextBoundWork>()
  private var transitionEpoch = 0L
  private var phaseRevision = 0L
  private var fenced = false

  fun register(participant: NetworkContextBoundWork) {
    val state =
      synchronized(this) {
        participants.add(participant)
        RegistryPhase(NetworkContextWorkPhase(transitionEpoch, phaseRevision), fenced)
      }
    if (state.fenced) {
      participant
        .fenceAndCancel(state.phase)
        .get(REGISTRATION_DRAIN_TIMEOUT_SECONDS, TimeUnit.SECONDS)
    } else {
      participant.reopen(state.phase)
    }
  }

  fun fenceAndCancelAll(epoch: Long): CompletableFuture<Unit> {
    val transition =
      synchronized(this) {
        if (epoch < transitionEpoch) return CompletableFuture.completedFuture(Unit)
        transitionEpoch = epoch
        phaseRevision++
        fenced = true
        NetworkContextWorkPhase(epoch, phaseRevision) to participants.toList()
      }
    val cancellations =
      transition.second
        .map { participant ->
          try {
            participant.fenceAndCancel(transition.first)
          } catch (error: Exception) {
            CompletableFuture<Unit>().also { it.completeExceptionally(error) }
          }
        }
    return CompletableFuture.allOf(*cancellations.toTypedArray()).thenApply { Unit }
  }

  fun reopenAll(epoch: Long) {
    val transition =
      synchronized(this) {
        if (epoch < transitionEpoch) return
        transitionEpoch = epoch
        phaseRevision++
        fenced = false
        NetworkContextWorkPhase(epoch, phaseRevision) to participants.toList()
      }
    transition.second.forEach { it.reopen(transition.first) }
  }
}

private data class RegistryPhase(
  val phase: NetworkContextWorkPhase,
  val fenced: Boolean,
)
