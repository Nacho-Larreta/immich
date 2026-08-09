import 'dart:io';

import 'package:immich_mobile/domain/interfaces/temporary_file_lease.interface.dart';
import 'package:path/path.dart' as path_util;

typedef NativeLeaseReleaser = Future<void> Function(String leaseToken);

final class OwnedTemporaryFileLease extends TemporaryFileLease {
  OwnedTemporaryFileLease._({
    required super.path,
    required String leaseToken,
    required NativeLeaseReleaser releaseNativeLease,
  }) : _leaseToken = leaseToken,
       _releaseNativeLease = releaseNativeLease,
       super(ownership: TemporaryFileOwnership.caller);

  final String _leaseToken;
  final NativeLeaseReleaser _releaseNativeLease;

  static Future<OwnedTemporaryFileLease> adopt({
    required String path,
    required String leaseToken,
    required String temporaryRoot,
    required NativeLeaseReleaser releaseNativeLease,
  }) async {
    if (leaseToken.trim().isEmpty) {
      throw ArgumentError.value(leaseToken, 'leaseToken', 'Must not be empty');
    }
    await _validateOwnedPath(path, temporaryRoot);
    return OwnedTemporaryFileLease._(path: path, leaseToken: leaseToken, releaseNativeLease: releaseNativeLease);
  }

  @override
  Future<void> releaseResource() => _releaseNativeLease(_leaseToken);

  static Future<void> _validateOwnedPath(String filePath, String temporaryRoot) async {
    final normalizedRoot = path_util.normalize(path_util.absolute(temporaryRoot));
    final normalizedFile = path_util.normalize(path_util.absolute(filePath));
    final ownedDirectory = path_util.dirname(normalizedFile);
    if (path_util.dirname(ownedDirectory) != normalizedRoot ||
        !path_util.basename(ownedDirectory).startsWith('immich-share-')) {
      throw const FileSystemException('Export lease is outside an immediate Immich share directory');
    }

    final directoryType = await FileSystemEntity.type(ownedDirectory, followLinks: false);
    final fileType = await FileSystemEntity.type(normalizedFile, followLinks: false);
    if (directoryType != FileSystemEntityType.directory || fileType != FileSystemEntityType.file) {
      throw const FileSystemException('Export lease must reference a regular file in a regular directory');
    }

    final resolvedRoot = path_util.normalize(await Directory(normalizedRoot).resolveSymbolicLinks());
    final resolvedDirectory = path_util.normalize(await Directory(ownedDirectory).resolveSymbolicLinks());
    final resolvedFile = path_util.normalize(await File(normalizedFile).resolveSymbolicLinks());
    if (path_util.dirname(resolvedDirectory) != resolvedRoot ||
        path_util.dirname(resolvedFile) != resolvedDirectory ||
        !path_util.isWithin(resolvedRoot, resolvedFile)) {
      throw const FileSystemException('Export lease escapes the canonical temporary root');
    }
  }
}
