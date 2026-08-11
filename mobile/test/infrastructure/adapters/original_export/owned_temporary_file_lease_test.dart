import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/owned_temporary_file_lease.dart';

void main() {
  late Directory temporaryRoot;

  setUp(() async {
    temporaryRoot = await Directory.systemTemp.createTemp('immich-lease-test-');
  });

  tearDown(() async {
    if (await temporaryRoot.exists()) {
      await temporaryRoot.delete(recursive: true);
    }
  });

  test('Dart and Swift share the same dedicated export subroot contract', () {
    final swift = File('ios/Runner/Share/OriginalExportSupport.swift').readAsStringSync();

    expect(swift, contains('static let ownedRootName = "$originalExportCacheDirectoryName"'));
  });

  test('adopts a canonical immediate share file and releases its native token exactly once', () async {
    final exportRoot = await Directory('${temporaryRoot.path}/immich-original-exports').create();
    final directory = await Directory('${exportRoot.path}/immich-share-550e8400-e29b-41d4-a716-446655440000').create();
    final file = await File('${directory.path}/same.jpg').writeAsString('first');
    final releasedTokens = <String>[];
    final lease = await OwnedTemporaryFileLease.adopt(
      path: file.path,
      leaseToken: 'lease-1',
      temporaryRoot: temporaryRoot.path,
      releaseNativeLease: (token) async {
        releasedTokens.add(token);
        await directory.delete(recursive: true);
      },
    );

    await Future.wait([lease.release(), lease.release()]);

    expect(releasedTokens, ['lease-1']);
    expect(await directory.exists(), isFalse);
    expect(lease.isReleased, isTrue);
  });

  test('rejects outside-root, nested and symlinked paths before adoption', () async {
    final outsideDirectory = await Directory('${temporaryRoot.parent.path}/immich-share-outside').create();
    final outsideFile = await File('${outsideDirectory.path}/outside.jpg').writeAsString('outside');
    addTearDown(() async {
      if (await outsideDirectory.exists()) {
        await outsideDirectory.delete(recursive: true);
      }
    });
    await expectLater(
      OwnedTemporaryFileLease.adopt(
        path: outsideFile.path,
        leaseToken: 'outside',
        temporaryRoot: temporaryRoot.path,
        releaseNativeLease: (_) async {},
      ),
      throwsA(isA<FileSystemException>()),
    );

    final exportRoot = await Directory('${temporaryRoot.path}/immich-original-exports').create();
    final directory = await Directory('${exportRoot.path}/immich-share-550e8400-e29b-41d4-a716-446655440001').create();
    final nested = await Directory('${directory.path}/nested').create();
    final nestedFile = await File('${nested.path}/photo.jpg').writeAsString('nested');
    await expectLater(
      OwnedTemporaryFileLease.adopt(
        path: nestedFile.path,
        leaseToken: 'nested',
        temporaryRoot: temporaryRoot.path,
        releaseNativeLease: (_) async {},
      ),
      throwsA(isA<FileSystemException>()),
    );

    final target = await File('${directory.path}/target.jpg').writeAsString('target');
    final link = Link('${directory.path}/photo.jpg');
    await link.create(target.path);
    await expectLater(
      OwnedTemporaryFileLease.adopt(
        path: link.path,
        leaseToken: 'link',
        temporaryRoot: temporaryRoot.path,
        releaseNativeLease: (_) async {},
      ),
      throwsA(isA<FileSystemException>()),
    );

    final legacyDirectory = await Directory('${temporaryRoot.path}/immich-share-legacy').create();
    final legacyFile = await File('${legacyDirectory.path}/photo.jpg').writeAsString('legacy');
    await expectLater(
      OwnedTemporaryFileLease.adopt(
        path: legacyFile.path,
        leaseToken: 'legacy',
        temporaryRoot: temporaryRoot.path,
        releaseNativeLease: (_) async {},
      ),
      throwsA(isA<FileSystemException>()),
    );

    final siblingDirectory = await Directory('${temporaryRoot.path}/immich-original-exports-sibling').create();
    final siblingShare = await Directory(
      '${siblingDirectory.path}/immich-share-550e8400-e29b-41d4-a716-446655440002',
    ).create();
    final siblingFile = await File('${siblingShare.path}/photo.jpg').writeAsString('sibling');
    await expectLater(
      OwnedTemporaryFileLease.adopt(
        path: siblingFile.path,
        leaseToken: 'sibling',
        temporaryRoot: temporaryRoot.path,
        releaseNativeLease: (_) async {},
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('rejects symlinked export root and share directory without traversing them', () async {
    final outside = await Directory.systemTemp.createTemp('immich-lease-outside-');
    addTearDown(() async {
      if (await outside.exists()) await outside.delete(recursive: true);
    });
    final outsideFile = await File('${outside.path}/photo.jpg').writeAsString('outside');
    final rootLink = Link('${temporaryRoot.path}/immich-original-exports');
    await rootLink.create(outside.path);
    await expectLater(
      OwnedTemporaryFileLease.adopt(
        path: '${rootLink.path}/immich-share-550e8400-e29b-41d4-a716-446655440003/photo.jpg',
        leaseToken: 'root-link',
        temporaryRoot: temporaryRoot.path,
        releaseNativeLease: (_) async {},
      ),
      throwsA(isA<FileSystemException>()),
    );
    await rootLink.delete();

    final exportRoot = await Directory('${temporaryRoot.path}/immich-original-exports').create();
    final shareLink = Link('${exportRoot.path}/immich-share-550e8400-e29b-41d4-a716-446655440004');
    await shareLink.create(outside.path);
    await expectLater(
      OwnedTemporaryFileLease.adopt(
        path: '${shareLink.path}/${outsideFile.uri.pathSegments.last}',
        leaseToken: 'share-link',
        temporaryRoot: temporaryRoot.path,
        releaseNativeLease: (_) async {},
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
