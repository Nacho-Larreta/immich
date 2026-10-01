import 'dart:async';

import 'package:immich_mobile/domain/interfaces/backup_operation_lifetime.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_authority.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_outbox.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_source.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_staging.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_submission.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_transport.interface.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_transport.model.dart';
import 'package:logging/logging.dart';

final class ManualUploadCoordinator implements ManualUploadSubmissionPort {
  ManualUploadCoordinator({
    required ManualUploadOutbox outbox,
    required ManualUploadStagingPort staging,
    required ManualUploadSourcePort source,
    required ManualUploadAuthoritySourcePort authority,
    required ManualUploadTransportPort transport,
    required BackupOperationLifetimePort lifetime,
    required String Function() newId,
    required DateTime Function() now,
    required Future<void> Function(ManualUploadIntent) onConfirmed,
    void Function(ManualUploadIntent, double)? onProgress,
    void Function(ManualUploadIntent)? onTerminal,
  }) : _outbox = outbox,
       _staging = staging,
       _source = source,
       _authority = authority,
       _transport = transport,
       _lifetime = lifetime,
       _newId = newId,
       _now = now,
       _onConfirmed = onConfirmed,
       _onProgress = onProgress,
       _onTerminal = onTerminal;

  final ManualUploadOutbox _outbox;
  final ManualUploadStagingPort _staging;
  final ManualUploadSourcePort _source;
  final ManualUploadAuthoritySourcePort _authority;
  final ManualUploadTransportPort _transport;
  final BackupOperationLifetimePort _lifetime;
  final String Function() _newId;
  final DateTime Function() _now;
  final Future<void> Function(ManualUploadIntent) _onConfirmed;
  final void Function(ManualUploadIntent, double)? _onProgress;
  final void Function(ManualUploadIntent)? _onTerminal;
  final Logger _logger = Logger('ManualUploadCoordinator');
  static const _maxOwnedIntents = 2;

  StreamSubscription<void>? _outboxSubscription;
  StreamSubscription<ManualUploadNativeEvent>? _transportSubscription;
  Timer? _retryTimer;
  DateTime? _retryDeadline;
  Future<void>? _pumping;
  Future<void>? _starting;
  Future<void>? _closing;
  final Set<Future<void>> _eventHandlers = {};
  bool _pumpRequested = false;
  bool _disposed = false;
  bool _needsHydration = true;

  @override
  Future<List<ManualUploadIntent>> submit(List<ManualUploadSelection> selections) async {
    if (selections.isEmpty) return const [];
    final destination = _authority.currentDestination();
    if (destination == null || selections.any((selection) => selection.destination != destination)) {
      throw StateError('Manual upload destination unavailable');
    }
    final accepted = await _outbox.submit(selections);
    for (final intent in accepted) {
      _onProgress?.call(intent, 0);
    }
    if (_outboxSubscription != null) unawaited(pump());
    return accepted;
  }

  void start() {
    if (_disposed || _outboxSubscription != null) return;
    _outboxSubscription = _outbox.changes.listen((_) => unawaited(pump()));
    _transportSubscription = _transport.events.listen((event) {
      final handler = _handleEvent(event).catchError((Object error, StackTrace stack) {
        _logger.warning('manual_upload_event_retry intent=${event.intentId}');
        _scheduleRetry(_now().add(const Duration(seconds: 5)));
      });
      _eventHandlers.add(handler);
      unawaited(
        handler.whenComplete(() {
          _eventHandlers.remove(handler);
        }),
      );
    });
    _starting = _replayThenPump();
    unawaited(_starting);
  }

  Future<void> _replayThenPump() async {
    try {
      await _transport.replayUndeliveredUpdates();
    } on Object {
      _logger.warning('manual_upload_replay_unavailable');
    }
    await pump();
  }

  Future<void> pump() {
    if (_disposed) return Future.value();
    _pumpRequested = true;
    if (_pumping != null) return _pumping!;
    _pumping = _drain()
        .catchError((Object error, StackTrace stack) {
          _logger.warning('manual_upload_pump_retry');
          _scheduleRetry(_now().add(const Duration(seconds: 5)));
        })
        .whenComplete(() {
          _pumping = null;
          if (_pumpRequested && !_disposed) unawaited(pump());
        });
    return _pumping!;
  }

  Future<void> _drain() async {
    while (_pumpRequested && !_disposed) {
      _pumpRequested = false;
      final destination = _authority.currentDestination();
      if (destination == null) continue;
      ManualUploadIntent? preparedCandidate;
      ManualUploadIntent? partiallyStagedCandidate;
      ManualUploadIntent? unstagedCandidate;
      var ownedIntents = 0;
      String? afterId;
      while (!_disposed) {
        final intents = await _outbox.listActive(destination, limit: 100, afterId: afterId);
        if (intents.isEmpty) break;
        for (final intent in intents) {
          if (_disposed || _authority.currentDestination() != destination) break;
          if (_needsHydration) _onProgress?.call(intent, 0);
          if (intent.currentAttempt != null || intent.stagedComponents.isNotEmpty) ownedIntents++;
          if (intent.status == ManualUploadIntentStatus.cancelling) {
            await _drainCancellation(intent);
          } else if (intent.currentAttempt != null) {
            await _reconcileAttempt(intent);
          } else if (intent.retryAt case final retryAt? when retryAt.isAfter(_now())) {
            _scheduleRetry(retryAt);
          } else if (intent.isConfirmed) {
            await _complete(intent);
          } else if (intent.isPrepared && intent.assetSnapshot != null) {
            preparedCandidate ??= intent;
          } else if (intent.stagedComponents.isNotEmpty) {
            partiallyStagedCandidate ??= intent;
          } else {
            unstagedCandidate ??= intent;
          }
        }
        if (intents.length < 100) break;
        afterId = intents.last.id;
      }
      _needsHydration = false;
      if (_disposed || _authority.currentDestination() != destination) continue;
      if (preparedCandidate != null) {
        await _admit(preparedCandidate);
      } else if (partiallyStagedCandidate != null) {
        await _prepare(partiallyStagedCandidate);
      } else if (ownedIntents < _maxOwnedIntents && unstagedCandidate != null) {
        await _prepare(unstagedCandidate);
      }
    }
  }

  Future<void> _prepare(ManualUploadIntent intent) async {
    await _staging.withPreparationGate(
      intentId: intent.id,
      action: () async {
        final latest = await _outbox.read(intent.id);
        if (_disposed ||
            latest == null ||
            !latest.isActive ||
            latest.status == ManualUploadIntentStatus.cancelling ||
            latest.currentAttempt != null ||
            latest.isPrepared) {
          return;
        }
        await _staging.pruneUnreferenced(latest);
        final current = await _outbox.read(intent.id);
        if (_disposed ||
            current == null ||
            current.version != latest.version ||
            current.currentAttempt != null ||
            current.status == ManualUploadIntentStatus.cancelling ||
            !current.isActive) {
          return;
        }
        await _prepareLocked(current);
      },
    );
  }

  Future<void> _prepareLocked(ManualUploadIntent intent) async {
    ManualUploadSource? source;
    if (!intent.isPrepared || intent.assetSnapshot == null) {
      try {
        source = await _source.load(intent.localAssetId);
      } on Object {
        _logger.warning('manual_upload_source_retry intent=${intent.id}');
        await _retry(intent, 'source-unavailable');
        return;
      }
      if (_disposed) return;
      if (source == null || source.asset.id != intent.localAssetId) {
        await _retry(intent, 'source-unavailable');
        return;
      }
    }
    var current = intent;
    final required = source?.isLivePhoto == true
        ? const {ManualUploadComponent.primary, ManualUploadComponent.motion}
        : current.requiredComponents;
    if (current.assetSnapshot == null || required.length != current.requiredComponents.length) {
      final next = current.copyWith(
        version: current.version + 1,
        status: ManualUploadIntentStatus.preparing,
        assetSnapshot: source?.asset,
        requiredComponents: required,
      );
      if (!await _outbox.compareAndSet(current, next)) return;
      current = next;
    }
    for (final component in [ManualUploadComponent.motion, ManualUploadComponent.primary]) {
      if (!current.requiredComponents.contains(component) || current.stagedComponents.containsKey(component)) continue;
      if (source == null) {
        await _retry(current, 'source-unavailable');
        return;
      }
      final borrowedPath = component == ManualUploadComponent.motion
          ? source.motionBorrowedPath
          : source.primaryBorrowedPath;
      final fileName = component == ManualUploadComponent.motion
          ? source.motionOriginalFileName
          : source.primaryOriginalFileName;
      if (borrowedPath == null || fileName == null) {
        await _retry(current, 'source-unavailable');
        return;
      }
      ManualUploadStagedComponent staged;
      try {
        staged = await _staging.stage(
          intentId: current.id,
          component: component,
          borrowedPath: borrowedPath,
          originalFileName: fileName,
        );
      } on Object {
        _logger.warning('manual_upload_stage_retry intent=${current.id}');
        await _retry(current, 'stage-unavailable');
        return;
      }
      if (_disposed) {
        await _staging.removeOwnedComponents(intentId: current.id, components: [staged]);
        return;
      }
      final latest = await _outbox.read(current.id);
      if (latest == null || latest.version != current.version || latest.status == ManualUploadIntentStatus.cancelling) {
        await _staging.removeOwnedComponents(intentId: current.id, components: [staged]);
        return;
      }
      final next = current.copyWith(
        version: current.version + 1,
        status: ManualUploadIntentStatus.preparing,
        stagedComponents: {...current.stagedComponents, component: staged},
      );
      if (!await _outbox.compareAndSet(current, next)) {
        await _staging.removeOwnedComponents(intentId: current.id, components: [staged]);
        return;
      }
      current = next;
    }
    if (current.isPrepared) {
      await _outbox.compareAndSet(
        current,
        current.copyWith(
          version: current.version + 1,
          status: ManualUploadIntentStatus.ready,
          clearRetryAt: true,
          clearLastFailure: true,
        ),
      );
    }
  }

  Future<void> _admit(ManualUploadIntent intent) async {
    final captured = _authority.captureAuthorized();
    if (captured == null || captured.destination != intent.destination) return;
    final component =
        intent.requiredComponents.contains(ManualUploadComponent.motion) &&
            !intent.remoteIds.containsKey(ManualUploadComponent.motion)
        ? ManualUploadComponent.motion
        : ManualUploadComponent.primary;
    final staged = intent.stagedComponents[component];
    if (staged == null) return;
    final path = await _staging.resolve(intentId: intent.id, component: staged);
    if (_disposed) return;
    if (path == null) {
      await _restageMissing(intent, component);
      return;
    }
    final identity = await _lifetime.currentIdentity();
    if (_disposed) return;
    if (identity == null || identity.isEmpty) {
      _logger.warning('manual_upload_identity_retry intent=${intent.id}');
      _scheduleRetry(_now().add(const Duration(seconds: 2)));
      return;
    }
    final latestAuthority = _authority.captureAuthorized();
    if (latestAuthority == null || !captured.sameSessionAs(latestAuthority)) return;
    final attempt = ManualUploadAttempt(
      taskId: _newId(),
      generation: intent.attemptGeneration + 1,
      component: component,
      operationIdentity: identity,
      nativeGeneration: captured.binding.nativeGeneration,
    );
    final reserved = intent.copyWith(
      version: intent.version + 1,
      status: ManualUploadIntentStatus.uploading,
      attemptGeneration: attempt.generation,
      currentAttempt: attempt,
      clearRetryAt: true,
    );
    if (!await _outbox.compareAndSet(intent, reserved)) return;
    unawaited(
      _transport
          .enqueue(
            ManualUploadEnqueueRequest(
              intent: reserved,
              staged: staged,
              asset: reserved.assetSnapshot!,
              binding: captured.binding,
              currentDestination: captured.destination,
              authorizedEndpoints: captured.authorizedEndpoints,
              absolutePath: path,
            ),
          )
          .then((accepted) {
            _logger.info('manual_upload_admission intent=${intent.id} accepted=$accepted');
            if (!accepted && !_disposed) unawaited(pump());
          })
          .catchError((Object error, StackTrace stack) {
            _logger.warning('manual_upload_admission_uncertain intent=${intent.id}');
            _scheduleRetry(_now().add(const Duration(seconds: 5)));
          }),
    );
  }

  Future<void> _reconcileAttempt(ManualUploadIntent intent) async {
    final observation = await _transport.observe(intent);
    if (_disposed) return;
    await _applyObservation(intent, observation);
  }

  Future<void> _handleEvent(ManualUploadNativeEvent event) async {
    if (_disposed) return;
    final intent = await _outbox.read(event.intentId);
    if (_disposed) return;
    final attempt = intent?.currentAttempt;
    if (intent == null ||
        attempt == null ||
        intent.status == ManualUploadIntentStatus.cancelling ||
        intent.destination != event.destination ||
        attempt.taskId != event.taskId ||
        attempt.generation != event.generation ||
        attempt.component != event.component) {
      return;
    }
    if (event.progress case final progress? when progress >= 0 && progress <= 1) {
      _onProgress?.call(intent, progress);
    }
    await _applyObservation(intent, event.observation);
  }

  Future<void> _applyObservation(ManualUploadIntent intent, ManualUploadObservation observation) async {
    final attempt = intent.currentAttempt;
    if (attempt == null) return;
    switch (observation.state) {
      case ManualUploadObservationState.active:
        return;
      case ManualUploadObservationState.unknown:
        _scheduleRetry(_now().add(const Duration(seconds: 5)));
        return;
      case ManualUploadObservationState.succeeded:
        final remoteId = observation.remoteAssetId;
        if (remoteId == null || remoteId.isEmpty) {
          await _retryAttempt(intent, 'terminal-receipt-missing');
          return;
        }
        final next = intent.copyWith(
          version: intent.version + 1,
          status: ManualUploadIntentStatus.ready,
          clearAttempt: true,
          remoteIds: {...intent.remoteIds, attempt.component: remoteId},
        );
        if (await _outbox.compareAndSet(intent, next)) {
          _transport.forgetAttempt(attempt);
          _logger.info('manual_upload_confirmed intent=${intent.id} component=${attempt.component.name}');
          unawaited(pump());
        }
        return;
      case ManualUploadObservationState.failed:
      case ManualUploadObservationState.cancelled:
      case ManualUploadObservationState.absent:
        await _retryAttempt(intent, observation.failureCode ?? observation.state.name);
    }
  }

  Future<void> _retryAttempt(ManualUploadIntent intent, String reason) async {
    final attempt = intent.currentAttempt;
    if (attempt == null) return;
    final next = _retryState(intent, reason, clearAttempt: true);
    if (await _outbox.compareAndSet(intent, next)) {
      _transport.forgetAttempt(attempt);
      _onProgress?.call(next, 0);
      _scheduleRetry(next.retryAt!);
    }
  }

  Future<void> _retry(ManualUploadIntent intent, String reason) async {
    final next = _retryState(intent, reason);
    if (await _outbox.compareAndSet(intent, next)) {
      _onProgress?.call(next, 0);
      _scheduleRetry(next.retryAt!);
    }
  }

  Future<void> _restageMissing(ManualUploadIntent intent, ManualUploadComponent component) async {
    final staged = {...intent.stagedComponents}..remove(component);
    final next = _retryState(intent, 'staged-source-missing').copyWith(stagedComponents: staged);
    if (await _outbox.compareAndSet(intent, next)) {
      _scheduleRetry(next.retryAt!);
    }
  }

  ManualUploadIntent _retryState(ManualUploadIntent intent, String reason, {bool clearAttempt = false}) {
    final count = intent.retryCount + 1;
    final seconds = count < 5 ? 1 << count : 30;
    return intent.copyWith(
      version: intent.version + 1,
      status: ManualUploadIntentStatus.retryWaiting,
      clearAttempt: clearAttempt,
      retryCount: count,
      retryAt: _now().add(Duration(seconds: seconds)),
      lastFailure: reason,
    );
  }

  void _scheduleRetry(DateTime at) {
    if (_disposed) return;
    if (_retryDeadline != null && !at.isBefore(_retryDeadline!) && _retryTimer?.isActive == true) return;
    _retryTimer?.cancel();
    _retryDeadline = at;
    final delay = at.difference(_now());
    _retryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _retryDeadline = null;
      unawaited(pump());
    });
  }

  Future<void> _complete(ManualUploadIntent intent) async {
    try {
      await _onConfirmed(intent);
      if (_disposed) return;
      await _staging.removeOwnedComponents(intentId: intent.id, components: intent.stagedComponents.values);
      if (_disposed) return;
    } on Object {
      _logger.warning('manual_upload_projection_retry intent=${intent.id}');
      await _retry(intent, 'projection-unavailable');
      return;
    }
    final settled = intent.copyWith(
      version: intent.version + 1,
      status: ManualUploadIntentStatus.completed,
      clearRetryAt: true,
      clearLastFailure: true,
    );
    if (!await _outbox.compareAndSet(intent, settled)) return;
    _logger.info('manual_upload_completed intent=${intent.id}');
    _onTerminal?.call(settled);
  }

  @override
  Future<void> requestCancel(String intentId) async {
    for (var revision = 0; revision < 16; revision++) {
      final intent = await _outbox.read(intentId);
      if (intent == null || !intent.isActive) return;
      if (intent.status == ManualUploadIntentStatus.cancelling ||
          await _outbox.compareAndSet(
            intent,
            intent.copyWith(version: intent.version + 1, status: ManualUploadIntentStatus.cancelling),
          )) {
        unawaited(pump());
        return;
      }
    }
    throw StateError('Manual upload cancellation did not acquire its intent');
  }

  Future<void> _drainCancellation(ManualUploadIntent intent) async {
    if (intent.currentAttempt != null && !await _transport.cancelAndDrain(intent)) {
      _scheduleRetry(_now().add(const Duration(seconds: 5)));
      return;
    }
    final next = intent.copyWith(
      version: intent.version + 1,
      status: ManualUploadIntentStatus.cancelled,
      clearAttempt: true,
    );
    if (!await _outbox.compareAndSet(intent, next)) return;
    if (intent.currentAttempt case final attempt?) _transport.forgetAttempt(attempt);
    await _staging.removeOwnedComponents(intentId: intent.id, components: intent.stagedComponents.values);
    _onTerminal?.call(next);
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _closing ??= Future.wait([
      if (_outboxSubscription case final subscription?) subscription.cancel(),
      if (_transportSubscription case final subscription?) subscription.cancel(),
    ]);
  }

  Future<void> stop() async {
    dispose();
    await _closing;
    await _starting;
    await Future.wait(_eventHandlers.toList());
    await _pumping;
  }
}
