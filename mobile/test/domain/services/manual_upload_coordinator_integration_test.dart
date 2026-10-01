import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/backup_operation_lifetime.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_authority.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_outbox.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_source.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_transport.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_transport.model.dart';
import 'package:immich_mobile/domain/services/manual_upload_coordinator.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/manual_upload_staging_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/manual_upload_db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/manual_upload_outbox.repository.dart';
import 'package:uuid/uuid.dart';

void main() {
  const destination = ManualUploadDestination(serverUrl: 'https://photos.example/api', userId: 'account-1');
  const identity = 'ios-engine-v1:00000000-0000-0000-0000-000000000001:1';
  late Directory directory;
  late File outboxFile;
  late File borrowed;
  late ManualUploadDatabase database;
  late DriftManualUploadOutbox outbox;
  late FakeAuthority authority;
  late FakeSource source;
  late FakeTransport transport;
  late FakeLifetime lifetime;
  late ManualUploadCoordinator coordinator;

  ManualUploadCoordinator makeCoordinator() => ManualUploadCoordinator(
    outbox: outbox,
    staging: ManualUploadStagingAdapter(
      applicationSupportDirectory: () async => directory,
      excludeFromCloudBackup: (_) async => true,
    ),
    source: source,
    authority: authority,
    transport: transport,
    lifetime: lifetime,
    newId: const Uuid().v4,
    now: DateTime.now,
    onConfirmed: (_) async {},
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('immich-manual-recovery-');
    outboxFile = File('${directory.path}/manual.sqlite');
    borrowed = File('${directory.path}/borrowed.mov');
    await borrowed.writeAsBytes(List.filled(2048, 7));
    database = ManualUploadDatabase(NativeDatabase(outboxFile));
    outbox = DriftManualUploadOutbox(database);
    authority = FakeAuthority(destination);
    source = FakeSource(borrowed.path);
    transport = FakeTransport();
    lifetime = FakeLifetime(identity);
    coordinator = makeCoordinator();
  });

  tearDown(() async {
    await coordinator.stop();
    transport.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  test('offline acceptance survives process death and startup resumes native upload without another tap', () async {
    final accepted = await coordinator.submit([
      ManualUploadSelection(
        intentId: 'intent-1',
        destination: destination,
        deviceId: 'phone',
        localAssetId: 'asset-1',
        createdAt: DateTime.utc(2026, 10, 1),
      ),
    ]);
    expect(accepted.single.id, 'intent-1');
    expect((await outbox.read('intent-1'))?.status, ManualUploadIntentStatus.pending);
    expect(transport.requests, isEmpty);
    await coordinator.stop();
    transport.dispose();
    await database.close();

    database = ManualUploadDatabase(NativeDatabase(outboxFile));
    outbox = DriftManualUploadOutbox(database);
    authority.authorized = true;
    transport = FakeTransport();
    coordinator = makeCoordinator();
    coordinator.start();

    await _waitUntil(() => transport.requests.length == 1);
    final request = transport.requests.single;
    expect(request.intent.currentAttempt?.operationIdentity, identity);
    expect(request.absolutePath, isNot(borrowed.path));
    expect(await File(request.absolutePath).exists(), isTrue);
    expect(await borrowed.exists(), isTrue);

    transport.deliver(
      ManualUploadNativeEvent(
        intentId: 'intent-1',
        taskId: request.intent.currentAttempt!.taskId,
        generation: request.intent.currentAttempt!.generation,
        component: ManualUploadComponent.primary,
        destination: destination,
        observation: const ManualUploadObservation(ManualUploadObservationState.succeeded, remoteAssetId: 'remote-1'),
      ),
    );
    await _waitUntil(() => transport.requests.length == 1 && transport.forgotten.isNotEmpty);
    expect((await outbox.read('intent-1'))?.status, ManualUploadIntentStatus.completed);
    expect(await borrowed.exists(), isTrue);
  });

  test('large selection stages only two owned files until a native completion frees space', () async {
    authority.authorized = true;
    await coordinator.submit([
      for (var index = 1; index <= 4; index++)
        ManualUploadSelection(
          intentId: 'intent-$index',
          destination: destination,
          deviceId: 'phone',
          localAssetId: 'asset-$index',
          createdAt: DateTime.utc(2026, 10, 1),
        ),
    ]);
    coordinator.start();
    await _waitUntil(() => transport.requests.length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(transport.requests.length, 2);
    expect((await outbox.read('intent-3'))?.stagedComponents, isEmpty);
    expect((await outbox.read('intent-4'))?.stagedComponents, isEmpty);

    final first = transport.requests.first.intent.currentAttempt!;
    transport.deliver(
      ManualUploadNativeEvent(
        intentId: 'intent-1',
        taskId: first.taskId,
        generation: first.generation,
        component: first.component,
        destination: destination,
        observation: const ManualUploadObservation(ManualUploadObservationState.succeeded, remoteAssetId: 'remote-1'),
      ),
    );
    await _waitUntil(() => transport.requests.length == 3);
    expect(transport.requests.last.intent.id, 'intent-3');
  });

  test('offline startup retains intent and only admits after current authority returns', () async {
    await coordinator.submit([_selection('intent-1', destination)]);
    coordinator.start();
    await _waitUntil(() => asyncCheckStaged(outbox, 'intent-1'));
    expect(transport.requests, isEmpty);

    authority.authorized = true;
    await coordinator.pump();
    await _waitUntil(() => transport.requests.length == 1);
  });

  test('account switch fences admission while staged files remain available for original account', () async {
    await coordinator.submit([_selection('intent-1', destination)]);
    coordinator.start();
    await _waitUntil(() => asyncCheckStaged(outbox, 'intent-1'));
    authority.authorized = true;
    authority.destination = const ManualUploadDestination(serverUrl: 'https://other.example/api', userId: 'account-2');
    await coordinator.pump();
    expect(transport.requests, isEmpty);

    authority.destination = destination;
    await coordinator.pump();
    await _waitUntil(() => transport.requests.length == 1);
  });

  test('late success from failed attempt cannot overwrite newer native attempt', () async {
    authority.authorized = true;
    await coordinator.submit([_selection('intent-1', destination)]);
    coordinator.start();
    await _waitUntil(() => transport.requests.length == 1);
    final first = transport.requests.single.intent.currentAttempt!;
    transport.deliver(
      ManualUploadNativeEvent(
        intentId: 'intent-1',
        taskId: first.taskId,
        generation: first.generation,
        component: first.component,
        destination: destination,
        observation: const ManualUploadObservation(ManualUploadObservationState.failed, failureCode: 'network'),
      ),
    );
    await _waitUntil(() => transport.forgotten.isNotEmpty);
    await _waitUntil(() => transport.requests.length == 2);
    final second = transport.requests.last.intent.currentAttempt!;
    expect(second.taskId, isNot(first.taskId));

    transport.deliver(
      ManualUploadNativeEvent(
        intentId: 'intent-1',
        taskId: first.taskId,
        generation: first.generation,
        component: first.component,
        destination: destination,
        observation: const ManualUploadObservation(ManualUploadObservationState.succeeded, remoteAssetId: 'stale'),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final persisted = await outbox.read('intent-1');
    expect(persisted?.currentAttempt, second);
    expect(persisted?.remoteIds, isEmpty);
  });

  test(
    'two partially staged Live Photos continue after source recovers without opening a third staging slot',
    () async {
      authority.authorized = true;
      source.isLivePhoto = true;
      source.motionPath = borrowed.path;
      final primary = File('${directory.path}/cloud-primary.heic');
      source.primaryPath = primary.path;
      await coordinator.submit([for (var index = 1; index <= 3; index++) _selection('intent-$index', destination)]);
      coordinator.start();
      await _waitUntil(() => asyncCheckPartiallyStaged(outbox, 'intent-1'));
      await _waitUntil(() => asyncCheckPartiallyStaged(outbox, 'intent-2'));
      expect((await outbox.read('intent-3'))?.stagedComponents, isEmpty);
      expect(transport.requests, isEmpty);

      await primary.writeAsBytes(List.filled(1024, 8));
      await _waitUntil(() => transport.requests.isNotEmpty);
      expect(transport.requests.first.intent.id, 'intent-1');
      expect(transport.requests.first.intent.currentAttempt?.component, ManualUploadComponent.motion);
      expect((await outbox.read('intent-3'))?.stagedComponents, isEmpty);
    },
  );

  test('reopened in-flight native task is observed before retired absence admits a fresh attempt', () async {
    authority.authorized = true;
    await coordinator.submit([_selection('intent-1', destination)]);
    coordinator.start();
    await _waitUntil(() => transport.requests.length == 1);
    final oldAttempt = transport.requests.single.intent.currentAttempt!;
    await coordinator.stop();
    transport.dispose();
    await database.close();

    database = ManualUploadDatabase(NativeDatabase(outboxFile));
    outbox = DriftManualUploadOutbox(database);
    transport = FakeTransport();
    coordinator = makeCoordinator();
    coordinator.start();
    await coordinator.pump();
    expect((await outbox.read('intent-1'))?.currentAttempt, oldAttempt);
    expect(transport.requests, isEmpty);

    transport.observation = const ManualUploadObservation(ManualUploadObservationState.absent);
    await coordinator.pump();
    await _waitUntil(() => transport.requests.length == 1);
    final freshAttempt = transport.requests.single.intent.currentAttempt!;
    expect(freshAttempt.taskId, isNot(oldAttempt.taskId));
    expect(freshAttempt.generation, oldAttempt.generation + 1);
    expect(freshAttempt.operationIdentity, identity);

    transport.deliver(
      ManualUploadNativeEvent(
        intentId: 'intent-1',
        taskId: oldAttempt.taskId,
        generation: oldAttempt.generation,
        component: oldAttempt.component,
        destination: destination,
        observation: const ManualUploadObservation(ManualUploadObservationState.succeeded, remoteAssetId: 'stale'),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect((await outbox.read('intent-1'))?.currentAttempt, freshAttempt);
    expect((await outbox.read('intent-1'))?.remoteIds, isEmpty);
  });

  test('lost owned staging file is restaged from source instead of retrying missing path forever', () async {
    authority.authorized = true;
    final initial = (await outbox.submit([_selection('intent-1', destination)])).single;
    final snapshot = (await source.load('asset-intent-1'))!.asset;
    final missing = initial.copyWith(
      version: initial.version + 1,
      status: ManualUploadIntentStatus.ready,
      assetSnapshot: snapshot,
      stagedComponents: const {
        ManualUploadComponent.primary: ManualUploadStagedComponent(
          component: ManualUploadComponent.primary,
          relativePath: 'intent-1/primary-gone.mov',
          fileName: 'video.mov',
        ),
      },
    );
    expect(await outbox.compareAndSet(initial, missing), isTrue);
    coordinator.start();

    await _waitUntil(() => transport.requests.length == 1);
    expect(transport.requests.single.staged.relativePath, isNot('intent-1/primary-gone.mov'));
    expect(await File(transport.requests.single.absolutePath).exists(), isTrue);
  });

  test('terminal callback advances queue even when native enqueue acknowledgment never returns', () async {
    authority.authorized = true;
    transport.pendingEnqueue = Completer<bool>().future;
    await coordinator.submit([
      _selection('intent-1', destination),
      _selection('intent-2', destination),
      _selection('intent-3', destination),
    ]);
    coordinator.start();
    await _waitUntil(() => transport.requests.length == 2);
    final first = transport.requests.first.intent.currentAttempt!;

    transport.deliver(
      ManualUploadNativeEvent(
        intentId: 'intent-1',
        taskId: first.taskId,
        generation: first.generation,
        component: first.component,
        destination: destination,
        observation: const ManualUploadObservation(ManualUploadObservationState.succeeded, remoteAssetId: 'remote-1'),
      ),
    );
    await _waitUntil(() => transport.requests.length == 3);
    expect(transport.requests.last.intent.id, 'intent-3');
  });

  test('temporary missing engine identity retries automatically without another tap or resume', () async {
    authority.authorized = true;
    lifetime.identity = null;
    await coordinator.submit([_selection('intent-1', destination)]);
    coordinator.start();
    await _waitUntil(() => asyncCheckStaged(outbox, 'intent-1'));
    expect(transport.requests, isEmpty);

    lifetime.identity = identity;
    await _waitUntil(() => transport.requests.length == 1);
    expect(transport.requests.single.intent.currentAttempt?.operationIdentity, identity);
  });

  test('cancellation survives a lost compare-and-set racing preparation', () async {
    final initial = (await outbox.submit([_selection('intent-1', destination)])).single;
    final racingOutbox = _CancelRacingOutbox(outbox);
    coordinator = ManualUploadCoordinator(
      outbox: racingOutbox,
      staging: ManualUploadStagingAdapter(
        applicationSupportDirectory: () async => directory,
        excludeFromCloudBackup: (_) async => true,
      ),
      source: source,
      authority: authority,
      transport: transport,
      lifetime: lifetime,
      newId: const Uuid().v4,
      now: DateTime.now,
      onConfirmed: (_) async {},
    );

    await coordinator.requestCancel(initial.id);
    expect(racingOutbox.raced, isTrue);
    expect((await outbox.read(initial.id))?.status, ManualUploadIntentStatus.cancelling);
    coordinator.start();
    await _waitUntil(() => asyncCheckStatus(outbox, initial.id, ManualUploadIntentStatus.cancelled));
    expect(transport.requests, isEmpty);
  });
}

ManualUploadSelection _selection(String id, ManualUploadDestination destination) => ManualUploadSelection(
  intentId: id,
  destination: destination,
  deviceId: 'phone',
  localAssetId: 'asset-$id',
  createdAt: DateTime.utc(2026, 10, 1),
);

Future<bool> asyncCheckStaged(DriftManualUploadOutbox outbox, String intentId) async =>
    (await outbox.read(intentId))?.isPrepared == true;

Future<bool> asyncCheckPartiallyStaged(DriftManualUploadOutbox outbox, String intentId) async {
  final intent = await outbox.read(intentId);
  return intent?.stagedComponents.containsKey(ManualUploadComponent.motion) == true && intent?.isPrepared == false;
}

Future<bool> asyncCheckStatus(DriftManualUploadOutbox outbox, String intentId, ManualUploadIntentStatus status) async =>
    (await outbox.read(intentId))?.status == status;

final class _CancelRacingOutbox implements ManualUploadOutbox {
  _CancelRacingOutbox(this.inner);

  final DriftManualUploadOutbox inner;
  bool raced = false;

  @override
  Stream<void> get changes => inner.changes;

  @override
  Future<List<ManualUploadIntent>> submit(List<ManualUploadSelection> selections) => inner.submit(selections);

  @override
  Future<ManualUploadIntent?> read(String intentId) => inner.read(intentId);

  @override
  Future<List<ManualUploadIntent>> listActive(
    ManualUploadDestination destination, {
    int limit = 100,
    String? afterId,
  }) => inner.listActive(destination, limit: limit, afterId: afterId);

  @override
  Future<bool> compareAndSet(ManualUploadIntent expected, ManualUploadIntent next) async {
    if (!raced && next.status == ManualUploadIntentStatus.cancelling) {
      raced = true;
      await inner.compareAndSet(
        expected,
        expected.copyWith(version: expected.version + 1, status: ManualUploadIntentStatus.preparing),
      );
      return false;
    }
    return inner.compareAndSet(expected, next);
  }
}

Future<void> _waitUntil(FutureOr<bool> Function() done) async {
  for (var i = 0; i < 150; i++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for manual upload recovery');
}

final class FakeAuthority implements ManualUploadAuthoritySourcePort {
  FakeAuthority(this.destination);

  ManualUploadDestination destination;
  bool authorized = false;

  @override
  ManualUploadDestination? currentDestination() => destination;

  @override
  ManualUploadAuthority? captureAuthorized() => authorized
      ? ManualUploadAuthority(
          destination: destination,
          binding: BackupRunBinding(
            userId: destination.userId,
            sessionEpoch: 1,
            probeGeneration: 1,
            nativeGeneration: 1,
            apiEndpoint: Uri.parse(destination.serverUrl),
            canonicalOrigin: Uri.parse('https://photos.example'),
            schemePolicy: EndpointSchemePolicy.httpsOnly,
            transportEpoch: 1,
            transportRevision: 1,
            localLeaseRevision: 1,
          ),
          authorizedEndpoints: {Uri.parse(destination.serverUrl)},
        )
      : null;
}

final class FakeSource implements ManualUploadSourcePort {
  FakeSource(this.borrowedPath);

  final String borrowedPath;
  bool isLivePhoto = false;
  String? primaryPath;
  String? motionPath;

  @override
  Future<ManualUploadSource?> load(String localAssetId) async => ManualUploadSource(
    asset: LocalAsset(
      id: localAssetId,
      name: isLivePhoto ? 'image.heic' : 'video.mov',
      type: isLivePhoto ? AssetType.image : AssetType.video,
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 1),
      durationMs: 25000,
      playbackStyle: isLivePhoto ? AssetPlaybackStyle.livePhoto : AssetPlaybackStyle.video,
      isEdited: false,
    ),
    isLivePhoto: isLivePhoto,
    primaryBorrowedPath: primaryPath ?? borrowedPath,
    primaryOriginalFileName: isLivePhoto ? 'image.heic' : 'video.mov',
    motionBorrowedPath: motionPath,
    motionOriginalFileName: isLivePhoto ? 'motion.mov' : null,
  );
}

final class FakeLifetime implements BackupOperationLifetimePort {
  FakeLifetime(this.identity);

  String? identity;

  @override
  Future<String?> currentIdentity() async => identity;

  @override
  Future<BackupOperationState> stateOf(String identity) async => BackupOperationState.retired;
}

final class FakeTransport implements ManualUploadTransportPort {
  final requests = <ManualUploadEnqueueRequest>[];
  final forgotten = <ManualUploadAttempt>[];
  final controller = StreamController<ManualUploadNativeEvent>.broadcast(sync: true);
  ManualUploadObservation observation = const ManualUploadObservation(ManualUploadObservationState.active);
  Future<bool>? pendingEnqueue;

  @override
  Stream<ManualUploadNativeEvent> get events => controller.stream;

  void deliver(ManualUploadNativeEvent event) => controller.add(event);

  @override
  Future<bool> enqueue(ManualUploadEnqueueRequest request) async {
    requests.add(request);
    observation = const ManualUploadObservation(ManualUploadObservationState.active);
    final pending = pendingEnqueue;
    pendingEnqueue = null;
    return pending ?? true;
  }

  @override
  Future<ManualUploadObservation> observe(ManualUploadIntent intent) async => observation;

  @override
  Future<bool> cancelAndDrain(ManualUploadIntent intent) async => true;

  @override
  Future<void> replayUndeliveredUpdates() async {}

  @override
  void forgetAttempt(ManualUploadAttempt attempt) => forgotten.add(attempt);

  @override
  void dispose() {
    if (!controller.isClosed) controller.close();
  }
}
