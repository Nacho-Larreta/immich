import 'dart:async';
import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/interfaces/backup_operation_lifetime.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_staging.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_transport.model.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/background_downloader_manual_transport.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/manual_native_task_gateway.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/manual_upload_admission_receipts.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/manual_upload_task_builder.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:mocktail/mocktail.dart';

void main() {
  late _Uploads uploads;
  late _Native gateway;
  late _Lifetime lifetime;
  late BackgroundDownloaderManualTransport transport;
  late StreamController<TaskStatusUpdate> statuses;
  late StreamController<TaskProgressUpdate> progress;
  late ManualUploadAdmissionReceipts admissions;
  late _Staging staging;

  setUp(() {
    uploads = _Uploads();
    gateway = _Native();
    lifetime = _Lifetime();
    statuses = StreamController.broadcast();
    progress = StreamController.broadcast();
    admissions = ManualUploadAdmissionReceipts();
    staging = _Staging();
    when(() => uploads.ready).thenAnswer((_) async {});
    when(() => uploads.manualStatusUpdates).thenAnswer((_) => statuses.stream);
    when(() => uploads.manualProgressUpdates).thenAnswer((_) => progress.stream);
    when(() => uploads.replayUndeliveredUpdates()).thenAnswer((_) async {});
    transport = BackgroundDownloaderManualTransport(
      uploadRepository: uploads,
      lifetime: lifetime,
      staging: staging,
      gateway: gateway,
      admissionReceipts: admissions,
      builder: ManualUploadTaskBuilder(
        splitPath: (_) async => (BaseDirectory.applicationSupport, 'manual-upload-staging-v1/intent', 'primary.jpg'),
      ),
    );
  });

  tearDown(() async {
    transport.dispose();
    await statuses.close();
    await progress.close();
  });

  test('native queued or running manual task wins over terminal tracking record', () async {
    gateway.tasks = [_task()];
    gateway.record = TaskRecord(_task(), TaskStatus.complete, 1, 1);
    expect((await transport.observe(_intent())).state, ManualUploadObservationState.active);
  });

  test('dead engine with stale running record is recoverable rather than permanently active', () async {
    lifetime.state = BackupOperationState.retired;
    gateway.record = TaskRecord(_task(), TaskStatus.running, 0.3, 100);
    expect((await transport.observe(_intent())).state, ManualUploadObservationState.absent);
    expect(gateway.snapshots, 3);
  });

  test('empty native snapshot cannot retire live sibling or unknown engine', () async {
    for (final state in [BackupOperationState.alive, BackupOperationState.unknown]) {
      lifetime.state = state;
      expect((await transport.observe(_intent())).state, ManualUploadObservationState.unknown);
    }
  });

  test('native failure is conservative but retryable without caching failure forever', () async {
    gateway.failure = PlatformException(code: 'disconnected');
    expect((await transport.observe(_intent())).state, ManualUploadObservationState.unknown);
    gateway.failure = null;
    lifetime.state = BackupOperationState.retired;
    expect((await transport.observe(_intent())).state, ManualUploadObservationState.absent);
  });

  test('lost completed receipt allows verified absent retry and never claims server success', () async {
    lifetime.state = BackupOperationState.retired;
    gateway.record = TaskRecord(_task(), TaskStatus.complete, 1, 100);
    final result = await transport.observe(_intent());
    expect(result.state, ManualUploadObservationState.failed);
    expect(result.failureCode, 'terminal-receipt-missing');
    expect(result.remoteAssetId, isNull);
  });

  test('task metadata from another account is never reconciled as current intent', () async {
    gateway.tasks = [_task(user: 'other')];
    expect((await transport.observe(_intent())).state, ManualUploadObservationState.unknown);
    expect(await transport.cancelAndDrain(_intent()), isFalse);
    expect(gateway.cancelled, isEmpty);
  });

  test('cancellation affects only exact manual task and requires drain', () async {
    lifetime.current = 'writer';
    admissions.begin(_intent().currentAttempt!);
    admissions.acknowledge(_intent().currentAttempt!);
    gateway.tasks = [_task()];
    gateway.removeOnCancel = false;
    expect(await transport.cancelAndDrain(_intent()), isFalse);
    gateway.removeOnCancel = true;
    expect(await transport.cancelAndDrain(_intent()), isTrue);
    expect(gateway.cancelled, ['task', 'task']);
  });

  test('same engine cannot recover a reservation before its producer acknowledged enqueue', () async {
    lifetime.current = 'writer';
    expect((await transport.observe(_intent())).state, ManualUploadObservationState.unknown);
    admissions.begin(_intent().currentAttempt!);
    expect((await transport.observe(_intent())).state, ManualUploadObservationState.unknown);
    admissions.acknowledge(_intent().currentAttempt!);
    expect((await transport.observe(_intent())).state, ManualUploadObservationState.absent);
    transport.forgetAttempt(_intent().currentAttempt!);
    expect((await transport.observe(_intent())).state, ManualUploadObservationState.unknown);
  });

  test('manual callbacks carry exact identity and only server-confirmed id is success', () async {
    final received = <ManualUploadNativeEvent>[];
    final subscription = transport.events.listen(received.add);
    statuses.add(
      TaskStatusUpdate(_task(), TaskStatus.complete, null, '{"id":"confirmed","status":"duplicate"}', null, 200),
    );
    statuses.add(TaskStatusUpdate(_task(), TaskStatus.complete, null, '{}', null, 200));
    statuses.add(TaskStatusUpdate(_task(group: kBackupGroup), TaskStatus.complete, null, '{"id":"other"}'));
    progress.add(TaskProgressUpdate(_task(), 0.5));
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(3));
    expect(received.first.intentId, 'intent');
    expect(received.first.generation, 1);
    expect(received.first.observation.state, ManualUploadObservationState.succeeded);
    expect(received.first.observation.remoteAssetId, 'confirmed');
    expect(received.where((event) => event.observation.state == ManualUploadObservationState.failed), hasLength(1));
    expect(received.singleWhere((event) => event.progress != null).progress, 0.5);
    await subscription.cancel();
  });

  test('mailbox replay uses shared downloader owner', () async {
    await transport.replayUndeliveredUpdates();
    verify(() => uploads.replayUndeliveredUpdates()).called(1);
  });

  test('enqueue hands off only an owned source with no persisted credentials', () async {
    lifetime.current = 'writer';
    expect(await transport.enqueue(_request()), isTrue);
    expect(gateway.enqueued.single.headers, isEmpty);
    expect(gateway.enqueued.single.group, kManualUploadGroup);
    expect((await transport.observe(_request().intent)).state, ManualUploadObservationState.absent);
  });

  test('same-basename borrowed source is refused before native admission', () async {
    lifetime.current = 'writer';
    expect(await transport.enqueue(_request(absolutePath: '/borrowed/primary.jpg')), isFalse);
    expect(gateway.enqueued, isEmpty);
    expect((await transport.observe(_request().intent)).state, ManualUploadObservationState.absent);
  });

  test('new adapter cannot mistake in-flight admission for absent task', () async {
    lifetime.current = 'writer';
    gateway.enqueueResult = Completer<bool>();
    final queued = transport.enqueue(_request());
    await Future<void>.delayed(Duration.zero);
    final sibling = BackgroundDownloaderManualTransport(
      uploadRepository: uploads,
      lifetime: lifetime,
      staging: staging,
      gateway: gateway,
      admissionReceipts: admissions,
    );
    expect((await sibling.observe(_request().intent)).state, ManualUploadObservationState.unknown);
    expect(await sibling.cancelAndDrain(_request().intent), isFalse);
    gateway.enqueueResult!.complete(false);
    expect(await queued, isFalse);
    expect((await sibling.observe(_request().intent)).state, ManualUploadObservationState.absent);
    sibling.dispose();
  });

  test('unacknowledged platform dispatch cannot authorize retry until old engine retires', () async {
    lifetime.current = 'writer';
    gateway.enqueueFailure = PlatformException(code: 'reply-lost');
    await expectLater(transport.enqueue(_request()), throwsA(isA<PlatformException>()));
    expect((await transport.observe(_request().intent)).state, ManualUploadObservationState.unknown);
    expect(await transport.enqueue(_request()), isFalse);
    expect(gateway.enqueued, hasLength(1));
    lifetime.current = 'new-root';
    lifetime.state = BackupOperationState.retired;
    expect((await transport.observe(_request().intent)).state, ManualUploadObservationState.absent);
  });

  test('exact native materialization resolves a lost reply without restarting the live engine', () async {
    lifetime.current = 'writer';
    admissions.begin(_intent().currentAttempt!);
    gateway.tasks = [_task()];
    expect((await transport.observe(_intent())).state, ManualUploadObservationState.active);
    gateway.tasks = [];
    expect((await transport.observe(_intent())).state, ManualUploadObservationState.absent);
  });

  test('exact completion tracking resolves missing admission and terminal replies without restart', () async {
    lifetime.current = 'writer';
    admissions.begin(_intent().currentAttempt!);
    gateway.record = TaskRecord(_task(), TaskStatus.complete, 1, 100);
    final result = await transport.observe(_intent());
    expect(result.state, ManualUploadObservationState.failed);
    expect(result.failureCode, 'terminal-receipt-missing');
  });
}

ManualUploadIntent _intent() => ManualUploadIntent(
  id: 'intent',
  destination: const ManualUploadDestination(serverUrl: 'https://photos.test/api', userId: 'user'),
  deviceId: 'device',
  localAssetId: 'asset',
  createdAt: DateTime.utc(2026),
  status: ManualUploadIntentStatus.uploading,
  attemptGeneration: 1,
  currentAttempt: const ManualUploadAttempt(
    taskId: 'task',
    generation: 1,
    component: ManualUploadComponent.primary,
    operationIdentity: 'writer',
    nativeGeneration: 1,
  ),
);

UploadTask _task({String user = 'user', String group = kManualUploadGroup}) => UploadTask(
  taskId: 'task',
  url: 'https://photos.test/api/assets',
  filename: 'source.jpg',
  group: group,
  metaData: jsonEncode({
    'intentId': 'intent',
    'attemptGeneration': 1,
    'component': 'primary',
    'destinationUserId': user,
    'destinationServerUrl': 'https://photos.test/api',
    'operationIncarnation': 'writer',
    'expectedNativeRevision': 1,
  }),
);

class _Uploads extends Mock implements UploadRepository {}

class _Staging implements ManualUploadStagingPort {
  @override
  Future<T> withPreparationGate<T>({required String intentId, required Future<T> Function() action}) => action();
  @override
  Future<void> pruneUnreferenced(ManualUploadIntent latest) async {}
  @override
  Future<String?> resolve({required String intentId, required ManualUploadStagedComponent component}) async =>
      '/owned/manual-upload-staging-v1/intent/primary.jpg';
  @override
  Future<ManualUploadStagedComponent> stage({
    required String intentId,
    required ManualUploadComponent component,
    required String borrowedPath,
    required String originalFileName,
  }) => throw UnimplementedError();
  @override
  Future<void> removeOwnedComponents({
    required String intentId,
    required Iterable<ManualUploadStagedComponent> components,
  }) async {}
}

class _Lifetime implements BackupOperationLifetimePort {
  String current = 'root';
  BackupOperationState state = BackupOperationState.alive;
  @override
  Future<String?> currentIdentity() async => current;
  @override
  Future<BackupOperationState> stateOf(String identity) async => state;
}

class _Native implements ManualNativeTaskGateway {
  List<Task> tasks = [];
  TaskRecord? record;
  PlatformException? failure;
  int snapshots = 0;
  bool removeOnCancel = true;
  final List<String> cancelled = [];
  final List<UploadTask> enqueued = [];
  Completer<bool>? enqueueResult;
  PlatformException? enqueueFailure;
  @override
  Future<bool> enqueue(UploadTask task) async {
    enqueued.add(task);
    if (enqueueFailure case final failure?) throw failure;
    return enqueueResult?.future ?? true;
  }

  @override
  Future<List<Task>> nativeTasks() async {
    snapshots++;
    if (failure case final error?) throw error;
    return tasks;
  }

  @override
  Future<TaskRecord?> recordForId(String taskId) async => record;
  @override
  Future<bool> cancel(String taskId) async {
    cancelled.add(taskId);
    if (removeOnCancel) tasks = tasks.where((task) => task.taskId != taskId).toList();
    return true;
  }
}

ManualUploadEnqueueRequest _request({String absolutePath = '/owned/manual-upload-staging-v1/intent/primary.jpg'}) {
  const staged = ManualUploadStagedComponent(
    component: ManualUploadComponent.primary,
    relativePath: 'intent/primary.jpg',
    fileName: 'original.jpg',
  );
  final intent = _intent().copyWith(stagedComponents: {ManualUploadComponent.primary: staged});
  final endpoint = Uri.parse('https://photos.test/api');
  return ManualUploadEnqueueRequest(
    intent: intent,
    staged: staged,
    asset: LocalAsset(
      id: 'asset',
      name: 'original.jpg',
      type: AssetType.image,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
    ),
    binding: BackupRunBinding(
      userId: 'user',
      sessionEpoch: 1,
      probeGeneration: 1,
      nativeGeneration: 1,
      apiEndpoint: endpoint,
      canonicalOrigin: Uri.parse(endpoint.origin),
      schemePolicy: EndpointSchemePolicy.httpsOnly,
      transportEpoch: 1,
      transportRevision: 1,
      localLeaseRevision: 1,
    ),
    currentDestination: intent.destination,
    authorizedEndpoints: {endpoint},
    absolutePath: absolutePath,
  );
}
