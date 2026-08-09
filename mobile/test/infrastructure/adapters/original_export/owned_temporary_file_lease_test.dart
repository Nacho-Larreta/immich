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

  test('adopts a canonical immediate share file and releases its native token exactly once', () async {
    final directory = await Directory('${temporaryRoot.path}/immich-share-first').create();
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

    final directory = await Directory('${temporaryRoot.path}/immich-share-link').create();
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
  });
}
