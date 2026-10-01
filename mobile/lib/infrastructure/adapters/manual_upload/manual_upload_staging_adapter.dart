import 'dart:io';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_staging.interface.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/manual_upload_preparation_gate.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

final class ManualUploadStagingAdapter implements ManualUploadStagingPort {
  ManualUploadStagingAdapter({
    Future<Directory> Function()? applicationSupportDirectory,
    Future<bool> Function(String root)? excludeFromCloudBackup,
  }) : _applicationSupportDirectory = applicationSupportDirectory ?? getApplicationSupportDirectory,
       _excludeFromCloudBackup = excludeFromCloudBackup ?? _excludeStagingRootFromCloudBackup;

  static const directoryName = 'manual-upload-staging-v1';
  static const _chunkSize = 256 * 1024;
  static const _channel = MethodChannel('com.bbflight.background_downloader');
  static final _safeIntentId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static final _ownedName = RegExp(
    r'^(primary|motion)-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}(\.[^/]+)?$',
  );
  static final _preparationGate = ManualUploadPreparationGate();

  final Future<Directory> Function() _applicationSupportDirectory;
  final Future<bool> Function(String root) _excludeFromCloudBackup;
  final Uuid _uuid = const Uuid();

  @override
  Future<T> withPreparationGate<T>({required String intentId, required Future<T> Function() action}) async {
    _validateIntentId(intentId);
    final root = await _preparedRoot();
    return _preparationGate.run(p.join(root.path, intentId), action);
  }

  @override
  Future<void> pruneUnreferenced(ManualUploadIntent latest) async {
    _validateIntentId(latest.id);
    final root = await _preparedRoot();
    if (!_preparationGate.holds(p.join(root.path, latest.id))) {
      throw StateError('Manual staging recovery requires the preparation gate');
    }
    if (!latest.isActive || latest.status == ManualUploadIntentStatus.cancelling || latest.currentAttempt != null) {
      throw StateError('Manual staging recovery cannot prune an admitted or cancelled intent');
    }
    final directory = await _intentDirectory(root, latest.id);
    if (directory == null) return;
    final retained = latest.stagedComponents.values
        .map((component) => _ownedFile(root, latest.id, component).path)
        .toSet();
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File && _ownedName.hasMatch(p.basename(entry.path)) && !retained.contains(entry.path)) {
        await entry.delete();
      }
    }
  }

  @override
  Future<ManualUploadStagedComponent> stage({
    required String intentId,
    required ManualUploadComponent component,
    required String borrowedPath,
    required String originalFileName,
  }) async {
    _validateIntentId(intentId);
    if (!p.isAbsolute(borrowedPath)) throw ArgumentError.value(borrowedPath, 'borrowedPath', 'Must be absolute');
    final source = File(borrowedPath);
    if (!await source.exists()) throw FileSystemException('Manual upload source unavailable', borrowedPath);
    return withPreparationGate(
      intentId: intentId,
      action: () =>
          _stageOwned(intentId: intentId, component: component, source: source, originalFileName: originalFileName),
    );
  }

  Future<ManualUploadStagedComponent> _stageOwned({
    required String intentId,
    required ManualUploadComponent component,
    required File source,
    required String originalFileName,
  }) async {
    final root = await _preparedRoot();
    await _intentDirectory(root, intentId, create: true);
    final safeOriginalFileName = p.basename(originalFileName);
    if (safeOriginalFileName.isEmpty || safeOriginalFileName == '.') {
      throw ArgumentError.value(originalFileName, 'originalFileName', 'Must name a file');
    }
    final extension = p.extension(source.path);
    final ownedName = '${component.name}-${_uuid.v4()}$extension';
    final relativePath = p.posix.join(intentId, ownedName);
    final published = File(p.join(root.path, relativePath));
    final partial = File('${published.path}.partial');

    try {
      await _copyAndFlush(source, partial);
      await partial.rename(published.path);
    } on Object {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
    return ManualUploadStagedComponent(
      component: component,
      relativePath: relativePath,
      fileName: safeOriginalFileName,
    );
  }

  @override
  Future<String?> resolve({required String intentId, required ManualUploadStagedComponent component}) async {
    final root = await _preparedRoot();
    final file = _ownedFile(root, intentId, component);
    if (await _intentDirectory(root, intentId) == null) return null;
    return await FileSystemEntity.type(file.path, followLinks: false) == FileSystemEntityType.file ? file.path : null;
  }

  @override
  Future<void> removeOwnedComponents({
    required String intentId,
    required Iterable<ManualUploadStagedComponent> components,
  }) async {
    final root = await _preparedRoot();
    final files = [for (final component in components) _ownedFile(root, intentId, component)];
    if (await _intentDirectory(root, intentId) == null) return;
    for (final file in files) {
      if (await FileSystemEntity.type(file.path, followLinks: false) == FileSystemEntityType.file) await file.delete();
    }
  }

  Future<Directory> _preparedRoot() async {
    final support = await _applicationSupportDirectory();
    final root = Directory(p.join(support.path, directoryName));
    await _requireDirectoryOrMissing(root);
    await root.create(recursive: true);
    if (!await _excludeFromCloudBackup(root.absolute.path)) {
      throw StateError('Manual upload staging exclusion unavailable');
    }
    return Directory(await root.resolveSymbolicLinks());
  }

  Future<Directory?> _intentDirectory(Directory root, String intentId, {bool create = false}) async {
    final directory = Directory(p.join(root.path, intentId));
    await _requireDirectoryOrMissing(directory);
    if (create) await directory.create();
    return await directory.exists() ? directory : null;
  }

  Future<void> _requireDirectoryOrMissing(Directory directory) async {
    final type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type != FileSystemEntityType.directory && type != FileSystemEntityType.notFound) {
      throw FileSystemException('Manual staging path is not an owned directory', directory.path);
    }
  }

  File _ownedFile(Directory root, String intentId, ManualUploadStagedComponent component) {
    _validateIntentId(intentId);
    final parts = p.posix.split(component.relativePath);
    if (parts.length != 2 || parts.first != intentId || parts.last.isEmpty || parts.last == '.' || parts.last == '..') {
      throw ArgumentError.value(component.relativePath, 'relativePath', 'Not owned by intent');
    }
    final file = File(p.join(root.path, intentId, parts.last));
    if (!p.isWithin(root.path, file.path)) throw ArgumentError.value(component.relativePath, 'relativePath');
    return file;
  }

  void _validateIntentId(String intentId) {
    if (!_safeIntentId.hasMatch(intentId)) throw ArgumentError.value(intentId, 'intentId', 'Unsafe intent ID');
  }

  Future<void> _copyAndFlush(File source, File destination) async {
    final reader = await source.open();
    RandomAccessFile? writer;
    try {
      writer = await destination.open(mode: FileMode.write);
      while (true) {
        final bytes = await reader.read(_chunkSize);
        if (bytes.isEmpty) break;
        await writer.writeFrom(bytes);
      }
      await writer.flush();
    } finally {
      await reader.close();
      await writer?.close();
    }
  }

  static Future<bool> _excludeStagingRootFromCloudBackup(String root) async {
    if (!CurrentPlatform.isIOS) return true;
    try {
      return await _channel.invokeMethod<bool>('prepareManualUploadStaging', root) == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
