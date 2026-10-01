import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/interfaces/backup_operation_lifetime.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_staging.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_transport.interface.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_transport.model.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/manual_native_task_gateway.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/manual_upload_admission_receipts.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/manual_upload_native_event_mapper.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/manual_upload_task_builder.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:logging/logging.dart';

final class BackgroundDownloaderManualTransport implements ManualUploadTransportPort {
  BackgroundDownloaderManualTransport({
    required UploadRepository uploadRepository,
    required BackupOperationLifetimePort lifetime,
    required ManualUploadStagingPort staging,
    ManualNativeTaskGateway? gateway,
    ManualUploadTaskBuilder? builder,
    ManualUploadAdmissionReceipts? admissionReceipts,
  }) : _uploads = uploadRepository,
       _lifetime = lifetime,
       _staging = staging,
       _gateway = gateway ?? DownloaderManualNativeTaskGateway(),
       _admissions = admissionReceipts ?? ManualUploadAdmissionReceipts.shared,
       _builder = builder ?? ManualUploadTaskBuilder() {
    _statusSubscription = _uploads.manualStatusUpdates.listen(_onStatus);
    _progressSubscription = _uploads.manualProgressUpdates.listen(_onProgress);
  }

  final UploadRepository _uploads;
  final BackupOperationLifetimePort _lifetime;
  final ManualUploadStagingPort _staging;
  final ManualNativeTaskGateway _gateway;
  final ManualUploadTaskBuilder _builder;
  final ManualUploadAdmissionReceipts _admissions;
  final _log = Logger('ManualUploadTransport');
  final _events = StreamController<ManualUploadNativeEvent>.broadcast();
  late final StreamSubscription<TaskStatusUpdate> _statusSubscription;
  late final StreamSubscription<TaskProgressUpdate> _progressSubscription;

  @override
  Stream<ManualUploadNativeEvent> get events => _events.stream;

  @override
  Future<bool> enqueue(ManualUploadEnqueueRequest request) async {
    final attempt = request.intent.currentAttempt;
    if (attempt == null || !_admissions.begin(attempt)) return false;
    var dispatched = false;
    try {
      await _uploads.ready;
      final path = await _staging.resolve(intentId: request.intent.id, component: request.staged);
      if (path == null ||
          path != request.absolutePath ||
          await _lifetime.currentIdentity() != attempt.operationIdentity) {
        return false;
      }
      final task = await _builder.build(
        intent: request.intent,
        staged: request.staged,
        asset: request.asset,
        binding: request.binding,
        currentDestination: request.currentDestination,
        authorizedEndpoints: request.authorizedEndpoints,
        absolutePath: path,
      );
      if (task.retries != 0) throw StateError('The manual outbox must be the only retry owner');
      dispatched = true;
      final accepted = await _gateway.enqueue(task);
      _admissions.acknowledge(attempt);
      return accepted;
    } finally {
      if (!dispatched) _admissions.acknowledge(attempt);
    }
  }

  @override
  Future<ManualUploadObservation> observe(ManualUploadIntent intent) async {
    try {
      return await _observe(intent);
    } on PlatformException {
      return _unavailable('native-bridge-unavailable');
    } on MissingPluginException {
      return _unavailable('native-bridge-unavailable');
    } on FileSystemException {
      return _unavailable('native-tracking-unavailable');
    }
  }

  Future<ManualUploadObservation> _observe(ManualUploadIntent intent) async {
    final attempt = intent.currentAttempt;
    if (attempt == null) return const ManualUploadObservation(ManualUploadObservationState.absent);
    await _uploads.ready;
    var revision = _admissions.revision;
    for (var pass = 0; pass < 3; pass++) {
      final tasks = await _gateway.nativeTasks();
      for (final task in tasks.where((task) => task.taskId == attempt.taskId)) {
        if (!ManualUploadNativeEventMapper.matches(task, intent)) return _unavailable('native-attempt-mismatch');
        if (task.retries == 0) _admissions.acknowledgeMaterialized(attempt);
        return const ManualUploadObservation(ManualUploadObservationState.active);
      }
    }
    final record = await _gateway.recordForId(attempt.taskId);
    if (_admissions.revision != revision) return _unavailable('native-admission-changed');
    if (record != null && !ManualUploadNativeEventMapper.matches(record.task, intent)) return _unavailable('native-attempt-mismatch');
    if (record?.status == TaskStatus.complete && record?.task.retries == 0) {
      _admissions.acknowledgeMaterialized(attempt);
      revision = _admissions.revision;
    }
    if (!await _canProveAdmissionDrained(attempt)) return _unavailable('native-owner-not-retired');
    if (_admissions.revision != revision) return _unavailable('native-admission-changed');
    if (record != null && record.status.isFinalState) return ManualUploadNativeEventMapper.status(record.status);
    return const ManualUploadObservation(ManualUploadObservationState.absent);
  }

  Future<bool> _canProveAdmissionDrained(ManualUploadAttempt attempt) async {
    if (await _lifetime.currentIdentity() == attempt.operationIdentity) return _admissions.isSettled(attempt);
    return await _lifetime.stateOf(attempt.operationIdentity) == BackupOperationState.retired;
  }

  @override
  Future<bool> cancelAndDrain(ManualUploadIntent intent) async {
    final attempt = intent.currentAttempt;
    if (attempt == null) return true;
    final before = await observe(intent);
    if (before.state == ManualUploadObservationState.unknown) return false;
    if (before.state == ManualUploadObservationState.active && !await _gateway.cancel(attempt.taskId)) return false;
    final after = await observe(intent);
    return after.state != ManualUploadObservationState.active && after.state != ManualUploadObservationState.unknown;
  }

  @override
  Future<void> replayUndeliveredUpdates() => _uploads.replayUndeliveredUpdates();

  @override
  void forgetAttempt(ManualUploadAttempt attempt) => _admissions.forget(attempt);

  ManualUploadObservation _unavailable(String code) {
    _log.fine('Manual native observation unavailable: $code');
    return ManualUploadObservation(ManualUploadObservationState.unknown, failureCode: code);
  }

  void _onStatus(TaskStatusUpdate update) {
    final observation = ManualUploadNativeEventMapper.status(
      update.status,
      responseBody: update.responseBody,
      responseStatusCode: update.responseStatusCode,
    );
    final event = ManualUploadNativeEventMapper.event(update.task, observation);
    if (event != null && !_events.isClosed) _events.add(event);
  }

  void _onProgress(TaskProgressUpdate update) {
    if (update.progress < 0 || update.progress > 1) return;
    final event = ManualUploadNativeEventMapper.event(
      update.task,
      const ManualUploadObservation(ManualUploadObservationState.active),
      progress: update.progress,
    );
    if (event != null && !_events.isClosed) _events.add(event);
  }

  @override
  void dispose() {
    _statusSubscription.cancel();
    _progressSubscription.cancel();
    _events.close();
  }
}
