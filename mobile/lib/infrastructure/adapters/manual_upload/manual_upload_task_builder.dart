import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/asset_metadata.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:path/path.dart' as p;

typedef ManualUploadPathSplitter = Future<(BaseDirectory, String, String)> Function(String path);

final class ManualUploadTaskBuilder {
  ManualUploadTaskBuilder({ManualUploadPathSplitter? splitPath})
    : _splitPath = splitPath ?? ((path) => Task.split(filePath: path));

  final ManualUploadPathSplitter _splitPath;

  Future<UploadTask> build({
    required ManualUploadIntent intent,
    required ManualUploadStagedComponent staged,
    required LocalAsset asset,
    required BackupRunBinding binding,
    required ManualUploadDestination currentDestination,
    required Set<Uri> authorizedEndpoints,
    required String absolutePath,
  }) async {
    final attempt = intent.currentAttempt;
    final published = intent.stagedComponents[staged.component];
    if (intent.status != ManualUploadIntentStatus.uploading ||
        attempt == null ||
        attempt.component != staged.component ||
        attempt.generation != intent.attemptGeneration ||
        attempt.nativeGeneration != binding.nativeGeneration ||
        attempt.operationIdentity.isEmpty ||
        intent.destination != currentDestination ||
        intent.destination.userId != binding.userId ||
        !authorizedEndpoints.map(_normalizedEndpoint).contains(_normalizedEndpoint(binding.apiEndpoint)) ||
        intent.localAssetId != asset.id ||
        !intent.isPrepared ||
        published == null ||
        published.relativePath != staged.relativePath ||
        published.fileName != staged.fileName ||
        !p.isAbsolute(absolutePath) ||
        p.basename(absolutePath) != p.basename(staged.relativePath)) {
      throw StateError('Manual upload attempt is not authorized for this source and destination');
    }
    if (attempt.component == ManualUploadComponent.primary &&
        intent.requiredComponents.contains(ManualUploadComponent.motion) &&
        !intent.remoteIds.containsKey(ManualUploadComponent.motion)) {
      throw StateError('Live Photo motion must be confirmed before still upload');
    }

    final (baseDirectory, directory, filename) = await _splitPath(absolutePath);
    final fields = <String, String>{
      'filename': staged.fileName,
      'deviceAssetId': asset.id,
      'deviceId': intent.deviceId,
      'fileCreatedAt': asset.createdAt.toUtc().toIso8601String(),
      'fileModifiedAt': asset.updatedAt.toUtc().toIso8601String(),
      'isFavorite': asset.isFavorite.toString(),
      'duration': asset.duration.toString(),
      if (attempt.component == ManualUploadComponent.primary && intent.remoteIds[ManualUploadComponent.motion] != null)
        'livePhotoVideoId': intent.remoteIds[ManualUploadComponent.motion]!,
      if (attempt.component == ManualUploadComponent.primary && CurrentPlatform.isIOS && asset.cloudId != null)
        'metadata': jsonEncode([
          RemoteAssetMetadataItem(
            key: RemoteAssetMetadataKey.mobileApp,
            value: RemoteAssetMobileAppMetadata(
              cloudId: asset.cloudId,
              createdAt: asset.createdAt.toIso8601String(),
              adjustmentTime: asset.adjustmentTime?.toIso8601String(),
              latitude: asset.latitude?.toString(),
              longitude: asset.longitude?.toString(),
            ),
          ),
        ]),
    };
    final metadata = jsonEncode({
      'intentId': intent.id,
      'attemptGeneration': attempt.generation,
      'component': attempt.component.name,
      'destinationUserId': intent.destination.userId,
      'destinationServerUrl': intent.destination.serverUrl,
      'bindingDigest': binding.digest,
      'expectedNativeRevision': attempt.nativeGeneration,
      'operationIncarnation': attempt.operationIdentity,
    });
    return UploadTask(
      taskId: attempt.taskId,
      url: '${binding.apiEndpoint}/assets',
      filename: filename,
      directory: directory,
      baseDirectory: baseDirectory,
      group: kManualUploadGroup,
      fields: fields,
      fileField: 'assetData',
      metaData: metadata,
      headers: const {},
      updates: Updates.statusAndProgress,
      requiresWiFi: false,
      retries: 0,
    );
  }

  Uri _normalizedEndpoint(Uri endpoint) =>
      endpoint.replace(path: endpoint.path.replaceFirst(RegExp(r'/$'), ''), query: '', fragment: '');
}
