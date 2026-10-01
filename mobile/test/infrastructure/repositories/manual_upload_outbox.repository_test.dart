import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/manual_upload_db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/manual_upload_outbox.repository.dart';

const destination = ManualUploadDestination(serverUrl: 'https://photos.example/api', userId: 'account-1');

ManualUploadSelection selection(String id, {String? asset, ManualUploadDestination account = destination}) =>
    ManualUploadSelection(
      intentId: id,
      destination: account,
      deviceId: 'phone',
      localAssetId: asset ?? 'asset-$id',
      createdAt: DateTime.utc(2026, 10, 1),
    );

ManualUploadIntent prepared(ManualUploadIntent intent, {bool livePhoto = false}) => intent.copyWith(
  version: intent.version + 1,
  status: ManualUploadIntentStatus.ready,
  requiredComponents: {ManualUploadComponent.primary, if (livePhoto) ManualUploadComponent.motion},
  stagedComponents: {
    ManualUploadComponent.primary: ManualUploadStagedComponent(
      component: ManualUploadComponent.primary,
      relativePath: '${intent.id}/primary.jpg',
      fileName: 'image.jpg',
    ),
    if (livePhoto)
      ManualUploadComponent.motion: ManualUploadStagedComponent(
        component: ManualUploadComponent.motion,
        relativePath: '${intent.id}/motion.mov',
        fileName: 'motion.mov',
      ),
  },
);

ManualUploadIntent reserved(ManualUploadIntent intent, String task, {ManualUploadComponent? component}) =>
    intent.copyWith(
      version: intent.version + 1,
      status: ManualUploadIntentStatus.uploading,
      attemptGeneration: intent.attemptGeneration + 1,
      currentAttempt: ManualUploadAttempt(
        taskId: task,
        generation: intent.attemptGeneration + 1,
        component: component ?? ManualUploadComponent.primary,
        operationIdentity: 'ios-engine-v1:00000000-0000-0000-0000-000000000001:1',
        nativeGeneration: 2,
      ),
    );

void main() {
  late Directory directory;
  late File file;
  late ManualUploadDatabase database;
  late DriftManualUploadOutbox outbox;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('immich-manual-outbox-');
    file = File('${directory.path}/manual.sqlite');
    database = ManualUploadDatabase(NativeDatabase(file));
    outbox = DriftManualUploadOutbox(database);
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test('complete batch survives reopen before any export and leaves schema 24 main database untouched', () async {
    final mainFile = File('${directory.path}/main.sqlite');
    final main = Drift(NativeDatabase(mainFile));
    await main.customStatement('CREATE TABLE manual_test_sentinel (value TEXT NOT NULL)');
    await main.customStatement("INSERT INTO manual_test_sentinel VALUES ('preserve-me')");
    await main.close();

    final accepted = await outbox.submit([selection('one'), selection('two')]);
    expect(accepted.map((intent) => intent.status), everyElement(ManualUploadIntentStatus.pending));
    await database.close();
    database = ManualUploadDatabase(NativeDatabase(file));
    outbox = DriftManualUploadOutbox(database);

    expect((await outbox.listActive(destination)).map((intent) => intent.id), ['one', 'two']);
    expect((await database.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 1);
    final oldMain = Drift(NativeDatabase(mainFile));
    expect((await oldMain.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 24);
    expect(
      (await oldMain.customSelect('SELECT value FROM manual_test_sentinel').getSingle()).read<String>('value'),
      'preserve-me',
    );
    await oldMain.close();
  });

  test('repeat selection resolves existing active intent but does not conflate accounts', () async {
    final first = (await outbox.submit([selection('one', asset: 'same')])).single;
    final duplicate = (await outbox.submit([selection('two', asset: 'same')])).single;
    expect(duplicate.id, first.id);
    const other = ManualUploadDestination(serverUrl: 'https://photos.example/api', userId: 'account-2');
    await outbox.submit([selection('three', asset: 'same', account: other)]);
    expect((await outbox.listActive(destination)).map((intent) => intent.id), ['one']);
    expect((await outbox.listActive(other)).map((intent) => intent.id), ['three']);
  });

  test('invalid selection rejects whole batch before first insert', () async {
    await expectLater(outbox.submit([selection('valid'), selection('')]), throwsArgumentError);
    expect(await outbox.listActive(destination), isEmpty);
  });

  test('two reopened coordinators cannot reserve two attempts from one version', () async {
    final initial = (await outbox.submit([selection('one')])).single;
    final ready = prepared(initial);
    expect(await outbox.compareAndSet(initial, ready), isTrue);
    final siblingDb = ManualUploadDatabase(NativeDatabase(file));
    final sibling = DriftManualUploadOutbox(siblingDb);
    final outcomes = await Future.wait([
      outbox.compareAndSet(ready, reserved(ready, 'first')),
      sibling.compareAndSet(ready, reserved(ready, 'second')),
    ]);
    expect(outcomes.where((won) => won).length, 1);
    expect((await outbox.read('one'))?.attemptGeneration, 1);
    await siblingDb.close();
  });

  test('old callback cannot complete or clear ownership of newer attempt', () async {
    final initial = (await outbox.submit([selection('one')])).single;
    final ready = prepared(initial);
    await outbox.compareAndSet(initial, ready);
    final first = reserved(ready, 'first');
    await outbox.compareAndSet(ready, first);
    final retry = first.copyWith(
      version: first.version + 1,
      status: ManualUploadIntentStatus.retryWaiting,
      clearAttempt: true,
      retryCount: 1,
    );
    await outbox.compareAndSet(first, retry);
    final second = reserved(retry, 'second');
    await outbox.compareAndSet(retry, second);

    expect(
      await outbox.compareAndSet(
        first,
        first.copyWith(
          version: first.version + 1,
          status: ManualUploadIntentStatus.completed,
          clearAttempt: true,
          remoteIds: {ManualUploadComponent.primary: 'old-server-id'},
        ),
      ),
      isFalse,
    );
    final current = await outbox.read('one');
    expect(current?.currentAttempt?.taskId, 'second');
    expect(current?.remoteIds, isEmpty);
  });

  test('account cannot be changed by a guessed intent/version update', () async {
    final initial = (await outbox.submit([selection('one')])).single;
    final wrongAccount = ManualUploadIntent(
      id: initial.id,
      destination: const ManualUploadDestination(serverUrl: 'https://other.example/api', userId: 'other'),
      deviceId: initial.deviceId,
      localAssetId: initial.localAssetId,
      createdAt: initial.createdAt,
      version: initial.version + 1,
    );
    await expectLater(outbox.compareAndSet(initial, wrongAccount), throwsArgumentError);
    expect((await outbox.read('one'))?.destination, destination);
  });

  test('motion confirmation survives crash and still failure without falsely completing Live Photo', () async {
    final initial = (await outbox.submit([selection('live')])).single;
    final ready = prepared(initial, livePhoto: true);
    await outbox.compareAndSet(initial, ready);
    final motion = reserved(ready, 'motion', component: ManualUploadComponent.motion);
    await outbox.compareAndSet(ready, motion);
    final motionDone = motion.copyWith(
      version: motion.version + 1,
      status: ManualUploadIntentStatus.ready,
      clearAttempt: true,
      remoteIds: {ManualUploadComponent.motion: 'remote-motion'},
    );
    await outbox.compareAndSet(motion, motionDone);
    await database.close();
    database = ManualUploadDatabase(NativeDatabase(file));
    outbox = DriftManualUploadOutbox(database);
    final restored = (await outbox.read('live'))!;
    expect(restored.remoteIds[ManualUploadComponent.motion], 'remote-motion');
    expect(restored.isConfirmed, isFalse);
    await expectLater(
      outbox.compareAndSet(
        restored,
        restored.copyWith(version: restored.version + 1, status: ManualUploadIntentStatus.completed),
      ),
      throwsArgumentError,
    );
    await expectLater(
      outbox.compareAndSet(restored, restored.copyWith(version: restored.version + 1, remoteIds: {})),
      throwsArgumentError,
    );
  });

  test('server confirmation survives reopen before asset projection with no new active demand', () async {
    final initial = (await outbox.submit([selection('one')])).single;
    final ready = prepared(initial);
    await outbox.compareAndSet(initial, ready);
    final uploading = reserved(ready, 'upload');
    await outbox.compareAndSet(ready, uploading);
    final done = uploading.copyWith(
      version: uploading.version + 1,
      status: ManualUploadIntentStatus.completed,
      clearAttempt: true,
      remoteIds: {ManualUploadComponent.primary: 'remote-id'},
    );
    expect(await outbox.compareAndSet(uploading, done), isTrue);
    await database.close();
    database = ManualUploadDatabase(NativeDatabase(file));
    outbox = DriftManualUploadOutbox(database);
    expect((await outbox.read('one'))?.remoteIds[ManualUploadComponent.primary], 'remote-id');
    expect(await outbox.listActive(destination), isEmpty);
  });

  test('cancellation stays active until native drain and rejects late success afterwards', () async {
    final initial = (await outbox.submit([selection('one')])).single;
    final ready = prepared(initial);
    await outbox.compareAndSet(initial, ready);
    final uploading = reserved(ready, 'upload');
    await outbox.compareAndSet(ready, uploading);
    final cancelling = uploading.copyWith(version: uploading.version + 1, status: ManualUploadIntentStatus.cancelling);
    await outbox.compareAndSet(uploading, cancelling);
    expect((await outbox.listActive(destination)).single.currentAttempt?.taskId, 'upload');
    await expectLater(
      outbox.compareAndSet(
        cancelling,
        cancelling.copyWith(version: cancelling.version + 1, status: ManualUploadIntentStatus.cancelled),
      ),
      throwsArgumentError,
    );
    final cancelled = cancelling.copyWith(
      version: cancelling.version + 1,
      status: ManualUploadIntentStatus.cancelled,
      clearAttempt: true,
    );
    expect(await outbox.compareAndSet(cancelling, cancelled), isTrue);
    expect(
      await outbox.compareAndSet(
        uploading,
        uploading.copyWith(
          version: uploading.version + 1,
          status: ManualUploadIntentStatus.completed,
          clearAttempt: true,
          remoteIds: {ManualUploadComponent.primary: 'late-id'},
        ),
      ),
      isFalse,
    );
  });

  test('bounded paging and retry metadata survive reopen', () async {
    await outbox.submit([selection('a'), selection('b'), selection('c')]);
    final first = (await outbox.listActive(destination, limit: 1)).single;
    expect(first.id, 'a');
    expect((await outbox.listActive(destination, limit: 1, afterId: first.id)).single.id, 'b');
    await expectLater(outbox.listActive(destination, limit: 0), throwsArgumentError);
    await expectLater(outbox.listActive(destination, limit: 1001), throwsArgumentError);
    final retryAt = DateTime.utc(2026, 10, 1, 18);
    await outbox.compareAndSet(
      first,
      first.copyWith(
        version: 1,
        status: ManualUploadIntentStatus.retryWaiting,
        retryCount: 1,
        retryAt: retryAt,
        lastFailure: 'source-unavailable',
      ),
    );
    await database.close();
    database = ManualUploadDatabase(NativeDatabase(file));
    outbox = DriftManualUploadOutbox(database);
    expect((await outbox.read('a'))?.retryAt, retryAt);
    expect((await outbox.read('a'))?.lastFailure, 'source-unavailable');
  });

  test('staging paths cannot escape an intents owned directory', () async {
    final initial = (await outbox.submit([selection('one')])).single;
    final escaped = initial.copyWith(
      version: 1,
      stagedComponents: {
        ManualUploadComponent.primary: const ManualUploadStagedComponent(
          component: ManualUploadComponent.primary,
          relativePath: '../borrowed.jpg',
          fileName: 'photo.jpg',
        ),
      },
    );
    await expectLater(outbox.compareAndSet(initial, escaped), throwsArgumentError);
    expect((await outbox.read('one'))?.stagedComponents, isEmpty);
  });

  test('cancellation never admits a fresh attempt even after a prior drain', () async {
    final initial = (await outbox.submit([selection('one')])).single;
    final ready = prepared(initial);
    await outbox.compareAndSet(initial, ready);
    final cancelling = ready.copyWith(version: ready.version + 1, status: ManualUploadIntentStatus.cancelling);
    await outbox.compareAndSet(ready, cancelling);
    final fresh = reserved(cancelling, 'late-task').copyWith(status: ManualUploadIntentStatus.cancelling);
    await expectLater(outbox.compareAndSet(cancelling, fresh), throwsArgumentError);
    expect((await outbox.read('one'))?.currentAttempt, isNull);
  });

  test('unknown future schema is rejected without rewriting its version or data', () async {
    await outbox.submit([selection('future')]);
    await database.customStatement('PRAGMA user_version = 2');
    await database.close();
    database = ManualUploadDatabase(NativeDatabase(file));
    outbox = DriftManualUploadOutbox(database);
    await expectLater(outbox.read('future'), throwsUnsupportedError);
    final probe = _FutureSchemaProbe(NativeDatabase(file));
    expect((await probe.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 2);
    expect((await probe.customSelect('SELECT id FROM manual_upload_intents').getSingle()).read<String>('id'), 'future');
    await probe.close();
  });

  test('staged source metadata survives reopen without relying on the photo library', () async {
    final initial = (await outbox.submit([selection('video')])).single;
    final asset = LocalAsset(id: initial.localAssetId, name: 'original.mov', type: AssetType.video,
      createdAt: DateTime.utc(2025, 8, 1), updatedAt: DateTime.utc(2025, 8, 2), durationMs: 12345,
      isFavorite: true, cloudId: 'cloud-fixture', latitude: -34.6, longitude: -58.4,
      playbackStyle: AssetPlaybackStyle.video, isEdited: false);
    final captured = initial.copyWith(version: 1, assetSnapshot: asset);
    expect(await outbox.compareAndSet(initial, captured), isTrue);
    await database.close();
    database = ManualUploadDatabase(NativeDatabase(file));
    outbox = DriftManualUploadOutbox(database);
    final restored = (await outbox.read('video'))!;
    expect(restored.assetSnapshot, asset);
    expect(restored.assetSnapshot?.durationMs, 12345);
    await expectLater(outbox.compareAndSet(restored, restored.copyWith(version: 2, assetSnapshot: asset.copyWith(durationMs: 1))), throwsArgumentError);
  });
}

final class _FutureSchemaProbe extends GeneratedDatabase {
  _FutureSchemaProbe(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
}
