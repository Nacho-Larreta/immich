import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_transport.model.dart';

abstract final class ManualUploadNativeEventMapper {
  static ManualUploadNativeEvent? event(Task task, ManualUploadObservation observation, {double? progress}) {
    if (task.group != kManualUploadGroup) return null;
    try {
      final value = jsonDecode(task.metaData) as Map<String, dynamic>;
      final intentId = value['intentId'] as String;
      final generation = value['attemptGeneration'] as int;
      final userId = value['destinationUserId'] as String;
      final server = value['destinationServerUrl'] as String;
      if (intentId.isEmpty || generation <= 0 || userId.isEmpty || server.isEmpty) return null;
      return ManualUploadNativeEvent(
        intentId: intentId,
        taskId: task.taskId,
        generation: generation,
        component: ManualUploadComponent.values.byName(value['component'] as String),
        destination: ManualUploadDestination(serverUrl: server, userId: userId),
        observation: observation,
        progress: progress,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  static bool matches(Task task, ManualUploadIntent intent) {
    final parsed = event(task, const ManualUploadObservation(ManualUploadObservationState.unknown));
    final attempt = intent.currentAttempt;
    if (parsed == null || attempt == null) return false;
    final metadata = jsonDecode(task.metaData) as Map<String, dynamic>;
    return parsed.intentId == intent.id &&
        parsed.taskId == attempt.taskId &&
        parsed.generation == attempt.generation &&
        parsed.component == attempt.component &&
        parsed.destination == intent.destination &&
        metadata['operationIncarnation'] == attempt.operationIdentity &&
        metadata['expectedNativeRevision'] == attempt.nativeGeneration;
  }

  static ManualUploadObservation status(TaskStatus status, {String? responseBody, int? responseStatusCode}) =>
      switch (status) {
        TaskStatus.complete => _confirmation(responseBody, responseStatusCode),
        TaskStatus.failed || TaskStatus.notFound => const ManualUploadObservation(
          ManualUploadObservationState.failed,
          failureCode: 'native-transfer-failed',
        ),
        TaskStatus.canceled => const ManualUploadObservation(ManualUploadObservationState.cancelled),
        _ => const ManualUploadObservation(ManualUploadObservationState.active),
      };

  static ManualUploadObservation _confirmation(String? body, int? statusCode) {
    if (body == null || body.isEmpty || (statusCode != null && (statusCode < 200 || statusCode >= 300))) {
      return const ManualUploadObservation(
        ManualUploadObservationState.failed,
        failureCode: 'terminal-receipt-missing',
      );
    }
    try {
      final response = jsonDecode(body);
      if (response is Map<String, dynamic> && response['id'] is String && (response['id'] as String).isNotEmpty) {
        return ManualUploadObservation(ManualUploadObservationState.succeeded, remoteAssetId: response['id'] as String);
      }
    } on FormatException {
      return const ManualUploadObservation(
        ManualUploadObservationState.failed,
        failureCode: 'terminal-receipt-invalid',
      );
    }
    return const ManualUploadObservation(ManualUploadObservationState.failed, failureCode: 'terminal-receipt-missing');
  }
}
