import 'dart:convert';

import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent_validation.dart';
import 'package:immich_mobile/infrastructure/repositories/manual_upload_asset_codec.dart';

abstract final class ManualUploadIntentCodec {
  static String encode(ManualUploadIntent intent) => jsonEncode({
    'id': intent.id,
    'serverUrl': intent.destination.serverUrl,
    'userId': intent.destination.userId,
    'deviceId': intent.deviceId,
    'localAssetId': intent.localAssetId,
    'createdAt': intent.createdAt.toUtc().toIso8601String(),
    'version': intent.version,
    'status': intent.status.name,
    'requiredComponents': intent.requiredComponents.map((component) => component.name).toList()..sort(),
    'stagedComponents': {
      for (final component in ManualUploadComponent.values)
        if (intent.stagedComponents[component] case final staged?)
          component.name: {'relativePath': staged.relativePath, 'fileName': staged.fileName},
    },
    'remoteIds': {
      for (final component in ManualUploadComponent.values)
        if (intent.remoteIds[component] case final remoteId?) component.name: remoteId,
    },
    'attemptGeneration': intent.attemptGeneration,
    if (intent.currentAttempt case final attempt?)
      'attempt': {
        'taskId': attempt.taskId,
        'generation': attempt.generation,
        'component': attempt.component.name,
        'operationIdentity': attempt.operationIdentity,
        'nativeGeneration': attempt.nativeGeneration,
      },
    'retryCount': intent.retryCount,
    if (intent.retryAt case final at?) 'retryAt': at.toUtc().toIso8601String(),
    if (intent.lastFailure case final failure?) 'lastFailure': failure,
    if (intent.assetSnapshot case final asset?) 'assetSnapshot': ManualUploadAssetCodec.encode(asset),
  });

  static ManualUploadIntent decode(String payload) {
    final value = jsonDecode(payload) as Map<String, dynamic>;
    final staged = value['stagedComponents'] as Map<String, dynamic>;
    final remoteIds = value['remoteIds'] as Map<String, dynamic>;
    final attempt = value['attempt'] as Map<String, dynamic>?;
    final intent = ManualUploadIntent(
      id: value['id'] as String,
      destination: ManualUploadDestination(serverUrl: value['serverUrl'] as String, userId: value['userId'] as String),
      deviceId: value['deviceId'] as String,
      localAssetId: value['localAssetId'] as String,
      createdAt: DateTime.parse(value['createdAt'] as String),
      version: value['version'] as int,
      status: ManualUploadIntentStatus.values.byName(value['status'] as String),
      requiredComponents: (value['requiredComponents'] as List<dynamic>)
          .map((component) => ManualUploadComponent.values.byName(component as String))
          .toSet(),
      stagedComponents: {
        for (final entry in staged.entries)
          ManualUploadComponent.values.byName(entry.key): ManualUploadStagedComponent(
            component: ManualUploadComponent.values.byName(entry.key),
            relativePath: (entry.value as Map<String, dynamic>)['relativePath'] as String,
            fileName: (entry.value as Map<String, dynamic>)['fileName'] as String,
          ),
      },
      remoteIds: {
        for (final entry in remoteIds.entries) ManualUploadComponent.values.byName(entry.key): entry.value as String,
      },
      attemptGeneration: value['attemptGeneration'] as int,
      currentAttempt: attempt == null
          ? null
          : ManualUploadAttempt(
              taskId: attempt['taskId'] as String,
              generation: attempt['generation'] as int,
              component: ManualUploadComponent.values.byName(attempt['component'] as String),
              operationIdentity: attempt['operationIdentity'] as String,
              nativeGeneration: attempt['nativeGeneration'] as int,
            ),
      retryCount: value['retryCount'] as int,
      retryAt: value['retryAt'] == null ? null : DateTime.parse(value['retryAt'] as String),
      lastFailure: value['lastFailure'] as String?,
      assetSnapshot: value['assetSnapshot'] == null ? null : ManualUploadAssetCodec.decode(value['assetSnapshot'] as Map<String, dynamic>),
    );
    validateManualUploadIntent(intent);
    return intent;
  }
}
