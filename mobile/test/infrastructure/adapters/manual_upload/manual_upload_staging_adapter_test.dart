import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/manual_upload_staging_adapter.dart';

void main() {
  late Directory fixture;
  late Directory support;
  late Directory borrowed;
  late List<String> excludedRoots;

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('manual-stage-test-');
    support = Directory('${fixture.path}/support')..createSync();
    borrowed = Directory('${fixture.path}/photomanager')..createSync();
    excludedRoots = [];
  });

  tearDown(() async {
    await fixture.delete(recursive: true);
  });

  ManualUploadStagingAdapter staging({Future<bool> Function(String)? exclude}) => ManualUploadStagingAdapter(
    applicationSupportDirectory: () async => support,
    excludeFromCloudBackup:
        exclude ??
        (root) async {
          excludedRoots.add(root);
          return true;
        },
  );

  ManualUploadIntent intent({String id = 'intent-1'}) => ManualUploadIntent(
    id: id,
    destination: const ManualUploadDestination(serverUrl: 'https://example.test', userId: 'user'),
    deviceId: 'device',
    localAssetId: 'asset',
    createdAt: DateTime.utc(2026),
  );

  test('recovery removes only unreferenced owned files of the locked intent', () async {
    final source = File('${borrowed.path}/source.heic')..writeAsStringSync('photo');
    final adapter = staging();
    final retained = await adapter.stage(
      intentId: 'intent-1',
      component: ManualUploadComponent.primary,
      borrowedPath: source.path,
      originalFileName: 'source.heic',
    );
    final root = '${support.path}/${ManualUploadStagingAdapter.directoryName}';
    final directory = Directory('$root/intent-1');
    final orphan = File('${directory.path}/motion-00000000-0000-4000-8000-000000000001.mov')
      ..writeAsStringSync('orphan');
    final partial = File('${directory.path}/primary-00000000-0000-4000-8000-000000000002.heic.partial')
      ..writeAsStringSync('partial');
    final unknown = File('${directory.path}/keep.txt')..writeAsStringSync('unknown');
    final other = Directory('$root/intent-2')..createSync();
    final sibling = File('${other.path}/primary-00000000-0000-4000-8000-000000000003.heic')
      ..writeAsStringSync('sibling');
    final latest = intent().copyWith(stagedComponents: {ManualUploadComponent.primary: retained});

    await adapter.withPreparationGate(intentId: latest.id, action: () => adapter.pruneUnreferenced(latest));

    expect(await orphan.exists(), isFalse);
    expect(await partial.exists(), isFalse);
    expect(await adapter.resolve(intentId: latest.id, component: retained), isNotNull);
    expect(await source.exists(), isTrue);
    expect(await unknown.exists(), isTrue);
    expect(await sibling.exists(), isTrue);
  });

  test('preparation gate spans publication and persistence across adapter instances', () async {
    final source = File('${borrowed.path}/source.heic')..writeAsStringSync('photo');
    final first = staging();
    final second = staging();
    final published = Completer<void>();
    final persist = Completer<void>();
    var latest = intent();
    ManualUploadStagedComponent? retained;
    var secondEntered = false;
    final firstPrepare = first.withPreparationGate(
      intentId: latest.id,
      action: () async {
        retained = await first.stage(
          intentId: latest.id,
          component: ManualUploadComponent.primary,
          borrowedPath: source.path,
          originalFileName: 'source.heic',
        );
        published.complete();
        await persist.future;
        latest = latest.copyWith(stagedComponents: {ManualUploadComponent.primary: retained!});
      },
    );
    await published.future;
    final recovery = second.withPreparationGate(
      intentId: latest.id,
      action: () async {
        secondEntered = true;
        await second.pruneUnreferenced(latest);
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(secondEntered, isFalse);
    persist.complete();
    await Future.wait([firstPrepare, recovery]);
    expect(secondEntered, isTrue);
    expect(await second.resolve(intentId: latest.id, component: retained!), isNotNull);
  });

  test('pruning requires active gate and refuses cancellation or native ownership', () async {
    final adapter = staging();
    await expectLater(adapter.pruneUnreferenced(intent()), throwsStateError);
    for (final blocked in [
      intent().copyWith(status: ManualUploadIntentStatus.cancelling),
      intent().copyWith(status: ManualUploadIntentStatus.cancelled),
      intent().copyWith(status: ManualUploadIntentStatus.completed),
      intent().copyWith(
        currentAttempt: const ManualUploadAttempt(
          taskId: 'task',
          generation: 1,
          component: ManualUploadComponent.primary,
          operationIdentity: 'engine',
          nativeGeneration: 1,
        ),
      ),
    ]) {
      await expectLater(
        adapter.withPreparationGate(intentId: blocked.id, action: () => adapter.pruneUnreferenced(blocked)),
        throwsStateError,
      );
    }
    await adapter.withPreparationGate(intentId: 'intent-1', action: () => adapter.pruneUnreferenced(intent()));
  });

  test('symlink intent directory cannot redirect staging or recovery to borrowed files', () async {
    final source = File('${borrowed.path}/source.heic')..writeAsStringSync('photo');
    final root = Directory('${support.path}/${ManualUploadStagingAdapter.directoryName}')..createSync();
    await Link('${root.path}/intent-1').create(borrowed.path);
    final adapter = staging();
    await expectLater(
      adapter.stage(
        intentId: 'intent-1',
        component: ManualUploadComponent.primary,
        borrowedPath: source.path,
        originalFileName: 'source.heic',
      ),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      adapter.withPreparationGate(intentId: 'intent-1', action: () => adapter.pruneUnreferenced(intent())),
      throwsA(isA<FileSystemException>()),
    );
    expect(await source.readAsString(), 'photo');
    expect(await borrowed.list().length, 1);
  });

  test('stages an atomic owned copy and never consumes the borrowed PhotoManager source', () async {
    final source = File('${borrowed.path}/image.heic')..writeAsStringSync('image bytes');
    final sentinel = File('${borrowed.path}/other.mov')..writeAsStringSync('other bytes');
    final adapter = staging();

    final component = await adapter.stage(
      intentId: 'intent-1',
      component: ManualUploadComponent.primary,
      borrowedPath: source.path,
      originalFileName: 'original.heic',
    );

    expect(component.component, ManualUploadComponent.primary);
    expect(component.fileName, 'original.heic');
    expect(component.relativePath, startsWith('intent-1/'));
    final stagedPath = await staging().resolve(intentId: 'intent-1', component: component);
    expect(stagedPath, isNotNull);
    expect(await File(stagedPath!).readAsString(), 'image bytes');
    expect(await source.exists(), isTrue);
    expect(await sentinel.exists(), isTrue);
    expect(excludedRoots, isNotEmpty);
    expect(excludedRoots.toSet(), hasLength(1));
    expect(Directory(excludedRoots.first).existsSync(), isTrue);
    expect(await Directory(stagedPath.substring(0, stagedPath.lastIndexOf('/'))).list().length, 1);
  });

  test('failed exclusion and missing source do not publish staged files or delete borrowed files', () async {
    final source = File('${borrowed.path}/image.heic')..writeAsStringSync('image bytes');
    final denied = staging(exclude: (_) async => false);

    await expectLater(
      denied.stage(
        intentId: 'intent-denied',
        component: ManualUploadComponent.primary,
        borrowedPath: source.path,
        originalFileName: 'image.heic',
      ),
      throwsStateError,
    );
    expect(await source.exists(), isTrue);
    expect(await Directory('${support.path}/manual-upload-staging-v1/intent-denied').exists(), isFalse);

    final adapter = staging();
    await expectLater(
      adapter.stage(
        intentId: 'intent-missing',
        component: ManualUploadComponent.motion,
        borrowedPath: '${borrowed.path}/missing.mov',
        originalFileName: 'missing.mov',
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await Directory('${support.path}/manual-upload-staging-v1/intent-missing').exists(), isFalse);
  });

  test('cleanup is limited to exact owned component and rejects path traversal', () async {
    final source = File('${borrowed.path}/image.heic')..writeAsStringSync('image bytes');
    final sentinel = File('${borrowed.path}/keep.mov')..writeAsStringSync('other bytes');
    final adapter = staging();
    final first = await adapter.stage(
      intentId: 'intent-1',
      component: ManualUploadComponent.primary,
      borrowedPath: source.path,
      originalFileName: 'image.heic',
    );
    final second = await adapter.stage(
      intentId: 'intent-2',
      component: ManualUploadComponent.primary,
      borrowedPath: source.path,
      originalFileName: 'image.heic',
    );

    await expectLater(
      adapter.removeOwnedComponents(
        intentId: 'intent-1',
        components: [
          const ManualUploadStagedComponent(
            component: ManualUploadComponent.primary,
            relativePath: '../photomanager/image.heic',
            fileName: 'image.heic',
          ),
        ],
      ),
      throwsArgumentError,
    );
    await adapter.removeOwnedComponents(intentId: 'intent-1', components: [first]);

    expect(await adapter.resolve(intentId: 'intent-1', component: first), isNull);
    expect(await adapter.resolve(intentId: 'intent-2', component: second), isNotNull);
    expect(await source.exists(), isTrue);
    expect(await sentinel.exists(), isTrue);
  });
}
