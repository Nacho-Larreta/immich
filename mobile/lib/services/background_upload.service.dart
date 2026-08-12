import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/asset_metadata.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_candidate_key.model.dart';
import 'package:immich_mobile/domain/models/backup_reconciliation_quarantine.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup_execution.provider.dart';
import 'package:immich_mobile/providers/backup/backup_run_binding.provider.dart';
import 'package:immich_mobile/providers/backup/eager_backup_signal.provider.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final Provider<BackgroundUploadService> backgroundUploadServiceProvider = Provider<BackgroundUploadService>((ref) {
  final connectivity = ref.read(nativeConnectivityMonitorProvider) as ConnectivitySnapshotMonitorPort;
  Future<bool> canContinueOwnedUpload(BackupRunBinding binding) async {
    await connectivity.initialSnapshot;
    final snapshot = await connectivity.readCurrentSnapshot();
    ref.read(backupTransportCursorProvider.notifier).state = (
      epoch: snapshot.monitorEpoch,
      revision: snapshot.revision,
    );
    return snapshot.hasWifi &&
        snapshot.monitorEpoch == binding.transportEpoch &&
        snapshot.revision == binding.transportRevision &&
        ref.read(backupRunBindingSourceProvider).isCurrent(binding);
  }

  final service = BackgroundUploadService(
    ref.watch(uploadRepositoryProvider),
    ref.watch(storageRepositoryProvider),
    ref.watch(localAssetRepository),
    ref.watch(backupRepositoryProvider),
    ref.watch(appSettingsServiceProvider),
    ref.watch(assetMediaRepositoryProvider),
    leasePort: ref.watch(backupExecutionLeaseProvider),
    arbiter: ref.watch(backupExecutionArbiterProvider),
    resolveBinding: (metadata, task) => _resolveOwnedTaskBinding(ref, metadata, task),
    canContinueOwnedUpload: canContinueOwnedUpload,
    onOwnedTerminal: (success) => ref
        .read(eagerBackupSignalProvider)
        .signal(success ? EagerBackupTrigger.uploadTerminal : EagerBackupTrigger.uploadFailed),
    onReconciliationPending: () => ref.read(eagerBackupSignalProvider).signal(EagerBackupTrigger.reconciliationPending),
    onReconciliationBlocked: () => ref.read(eagerBackupSignalProvider).signal(EagerBackupTrigger.reconciliationBlocked),
    reconcileOwnedSuccess: (binding) => ref.read(backgroundSyncProvider).syncRemoteForBinding(binding),
  );

  unawaited(
    service.resumePersistedReconciliations().catchError((Object _, StackTrace __) {
      ref.read(eagerBackupSignalProvider).signal(EagerBackupTrigger.reconciliationBlocked);
    }),
  );

  ref.onDispose(service.dispose);
  return service;
});

BackupRunBindingResolution _resolveOwnedTaskBinding(Ref ref, UploadTaskMetadata metadata, Task task) {
  final evidence = NetworkRepository.serverAccessEvidence;
  final identity = ref.read(sessionEpochControllerProvider).current;
  final userId = ref.read(currentUserProvider)?.id;
  final evidenceAfter = NetworkRepository.serverAccessEvidence;
  final identityAfter = ref.read(sessionEpochControllerProvider).current;
  return resolveOwnedTaskBinding(
    metadata: metadata,
    task: task,
    evidence: evidence,
    evidenceAfter: evidenceAfter,
    identity: identity,
    identityAfter: identityAfter,
    userId: userId,
    userIdAfter: ref.read(currentUserProvider)?.id,
    attachedWorker: NetworkRepository.isAttachedWorker,
  );
}

@visibleForTesting
BackupRunBinding? validateOwnedTaskBinding({
  required UploadTaskMetadata metadata,
  required Task task,
  required NativeServerAccessEvidence evidence,
  required NativeServerAccessEvidence evidenceAfter,
  required ReachabilityIdentity identity,
  required ReachabilityIdentity identityAfter,
  required String? userId,
  required String? userIdAfter,
  required bool attachedWorker,
}) => resolveOwnedTaskBinding(
  metadata: metadata,
  task: task,
  evidence: evidence,
  evidenceAfter: evidenceAfter,
  identity: identity,
  identityAfter: identityAfter,
  userId: userId,
  userIdAfter: userIdAfter,
  attachedWorker: attachedWorker,
).binding;

@visibleForTesting
BackupRunBindingResolution resolveOwnedTaskBinding({
  required UploadTaskMetadata metadata,
  required Task task,
  required NativeServerAccessEvidence evidence,
  required NativeServerAccessEvidence evidenceAfter,
  required ReachabilityIdentity identity,
  required ReachabilityIdentity identityAfter,
  required String? userId,
  required String? userIdAfter,
  required bool attachedWorker,
}) {
  final ownership = metadata.ownership;
  final authority = metadata.bindingAuthority;
  final endpoint = evidence.apiEndpoint ?? _apiEndpointFromTask(task);
  final origin = evidence.canonicalOrigin;
  if (ownership == null || authority == null || metadata.expectedNativeRevision == null) {
    return const BackupRunBindingResolution.temporarilyUnavailable();
  }
  if (metadata.expectedNativeRevision != authority.nativeGeneration ||
      evidence.schemePolicy != authority.schemePolicy ||
      evidence.sessionEpoch != authority.sessionEpoch ||
      evidence.generation != authority.nativeGeneration ||
      (!attachedWorker &&
          (identity.sessionEpoch != authority.sessionEpoch || identity.probeGeneration != authority.probeGeneration))) {
    return const BackupRunBindingResolution.definitivelyStale();
  }
  if (userId == null || endpoint == null || origin == null || !evidence.confirmed || evidence.fenced) {
    return const BackupRunBindingResolution.temporarilyUnavailable();
  }
  if (!_taskTargetsEndpoint(task, endpoint)) {
    return const BackupRunBindingResolution.definitivelyStale();
  }
  final candidate = BackupRunBinding(
    userId: userId,
    sessionEpoch: authority.sessionEpoch,
    probeGeneration: authority.probeGeneration,
    nativeGeneration: authority.nativeGeneration,
    apiEndpoint: endpoint,
    canonicalOrigin: origin,
    schemePolicy: authority.schemePolicy,
    transportEpoch: authority.transportEpoch,
    transportRevision: authority.transportRevision,
    localLeaseRevision: authority.localLeaseRevision,
  );
  if (evidenceAfter.apiEndpoint != evidence.apiEndpoint ||
      evidenceAfter.canonicalOrigin != evidence.canonicalOrigin ||
      evidenceAfter.schemePolicy != evidence.schemePolicy ||
      evidenceAfter.sessionEpoch != evidence.sessionEpoch ||
      evidenceAfter.generation != evidence.generation ||
      evidenceAfter.confirmed != evidence.confirmed ||
      evidenceAfter.fenced != evidence.fenced ||
      userIdAfter != userId ||
      (!attachedWorker && identityAfter != identity)) {
    return const BackupRunBindingResolution.temporarilyUnavailable();
  }
  return candidate.digest == ownership.bindingDigest
      ? BackupRunBindingResolution.current(candidate)
      : const BackupRunBindingResolution.definitivelyStale();
}

Uri? _apiEndpointFromTask(Task task) {
  final target = Uri.tryParse(task.url);
  if (target == null || target.pathSegments.isEmpty || target.pathSegments.last != 'assets') return null;
  return target.replace(pathSegments: target.pathSegments.sublist(0, target.pathSegments.length - 1));
}

bool _taskTargetsEndpoint(Task task, Uri endpoint) {
  final target = Uri.tryParse(task.url);
  if (target == null || target.origin != endpoint.origin) return false;
  final expectedPath = '${endpoint.path.replaceFirst(RegExp(r'/$'), '')}/assets';
  return target.path == expectedPath;
}

final class UploadBindingAuthority {
  const UploadBindingAuthority({
    required this.sessionEpoch,
    required this.probeGeneration,
    required this.nativeGeneration,
    required this.transportEpoch,
    required this.transportRevision,
    required this.localLeaseRevision,
    required this.schemePolicy,
  });

  factory UploadBindingAuthority.fromBinding(BackupRunBinding binding) => UploadBindingAuthority(
    sessionEpoch: binding.sessionEpoch,
    probeGeneration: binding.probeGeneration,
    nativeGeneration: binding.nativeGeneration,
    transportEpoch: binding.transportEpoch,
    transportRevision: binding.transportRevision,
    localLeaseRevision: binding.localLeaseRevision,
    schemePolicy: binding.schemePolicy,
  );

  final int sessionEpoch;
  final int probeGeneration;
  final int nativeGeneration;
  final int transportEpoch;
  final int transportRevision;
  final int localLeaseRevision;
  final EndpointSchemePolicy schemePolicy;

  Map<String, Object> toMap() => {
    'sessionEpoch': sessionEpoch,
    'probeGeneration': probeGeneration,
    'nativeGeneration': nativeGeneration,
    'transportEpoch': transportEpoch,
    'transportRevision': transportRevision,
    'localLeaseRevision': localLeaseRevision,
    'schemePolicy': schemePolicy.name,
  };

  factory UploadBindingAuthority.fromMap(Map<String, dynamic> value) => UploadBindingAuthority(
    sessionEpoch: value['sessionEpoch'] as int,
    probeGeneration: value['probeGeneration'] as int,
    nativeGeneration: value['nativeGeneration'] as int,
    transportEpoch: value['transportEpoch'] as int,
    transportRevision: value['transportRevision'] as int,
    localLeaseRevision: value['localLeaseRevision'] as int,
    schemePolicy: EndpointSchemePolicy.values.byName(value['schemePolicy'] as String),
  );

  @override
  bool operator ==(Object other) =>
      other is UploadBindingAuthority &&
      other.sessionEpoch == sessionEpoch &&
      other.probeGeneration == probeGeneration &&
      other.nativeGeneration == nativeGeneration &&
      other.transportEpoch == transportEpoch &&
      other.transportRevision == transportRevision &&
      other.localLeaseRevision == localLeaseRevision &&
      other.schemePolicy == schemePolicy;

  @override
  int get hashCode => Object.hash(
    sessionEpoch,
    probeGeneration,
    nativeGeneration,
    transportEpoch,
    transportRevision,
    localLeaseRevision,
    schemePolicy,
  );
}

/// Metadata for upload tasks to track live photo handling
class UploadTaskMetadata {
  final String localAssetId;
  final bool isLivePhotos;
  final String livePhotoVideoId;
  final BackupTaskMetadata? ownership;
  final int? expectedNativeRevision;
  final UploadBindingAuthority? bindingAuthority;
  final String? candidateKey;

  const UploadTaskMetadata({
    required this.localAssetId,
    required this.isLivePhotos,
    required this.livePhotoVideoId,
    this.ownership,
    this.expectedNativeRevision,
    this.bindingAuthority,
    this.candidateKey,
  });

  UploadTaskMetadata copyWith({
    String? localAssetId,
    bool? isLivePhotos,
    String? livePhotoVideoId,
    String? candidateKey,
  }) {
    return UploadTaskMetadata(
      localAssetId: localAssetId ?? this.localAssetId,
      isLivePhotos: isLivePhotos ?? this.isLivePhotos,
      livePhotoVideoId: livePhotoVideoId ?? this.livePhotoVideoId,
      ownership: ownership,
      expectedNativeRevision: expectedNativeRevision,
      bindingAuthority: bindingAuthority,
      candidateKey: candidateKey ?? this.candidateKey,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'localAssetId': localAssetId,
      'isLivePhotos': isLivePhotos,
      'livePhotoVideoId': livePhotoVideoId,
      if (ownership != null) ...json.decode(ownership!.toJson()) as Map<String, dynamic>,
      if (expectedNativeRevision != null) 'expectedNativeRevision': expectedNativeRevision,
      if (bindingAuthority != null) 'bindingAuthority': bindingAuthority!.toMap(),
      if (candidateKey != null) 'candidateKey': candidateKey,
    };
  }

  factory UploadTaskMetadata.fromMap(Map<String, dynamic> map) {
    final candidateKey = map['candidateKey'] as String?;
    return UploadTaskMetadata(
      localAssetId: map['localAssetId'] as String,
      isLivePhotos: map['isLivePhotos'] as bool,
      livePhotoVideoId: map['livePhotoVideoId'] as String,
      ownership: BackupTaskMetadata.tryParse(json.encode(map)),
      expectedNativeRevision: map['expectedNativeRevision'] as int?,
      bindingAuthority: map['bindingAuthority'] == null
          ? null
          : UploadBindingAuthority.fromMap(map['bindingAuthority'] as Map<String, dynamic>),
      candidateKey: candidateKey == null ? null : BackupCandidateKey.parse(candidateKey).value,
    );
  }

  String toJson() => json.encode(toMap());

  factory UploadTaskMetadata.fromJson(String source) =>
      UploadTaskMetadata.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  String toString() => 'UploadTaskMetadata(isLivePhotos: $isLivePhotos, phase: ${ownership?.phase.name ?? 'legacy'})';

  @override
  bool operator ==(covariant UploadTaskMetadata other) {
    if (identical(this, other)) return true;

    return other.localAssetId == localAssetId &&
        other.isLivePhotos == isLivePhotos &&
        other.livePhotoVideoId == livePhotoVideoId &&
        other.expectedNativeRevision == expectedNativeRevision &&
        other.bindingAuthority == bindingAuthority &&
        other.candidateKey == candidateKey &&
        other.ownership?.toJson() == ownership?.toJson();
  }

  @override
  int get hashCode => Object.hash(
    localAssetId,
    isLivePhotos,
    livePhotoVideoId,
    ownership?.toJson(),
    expectedNativeRevision,
    bindingAuthority,
    candidateKey,
  );
}

/// Service for handling background uploads using iOS URLSession (background_downloader)
///
/// This service handles asynchronous background uploads that can continue
/// even when the app is suspended. Primarily used for iOS background backup.
class BackgroundUploadService {
  BackgroundUploadService(
    this._uploadRepository,
    this._storageRepository,
    this._localAssetRepository,
    this._backupRepository,
    this._appSettingsService,
    this._assetMediaRepository, {
    BackupExecutionLeasePort? leasePort,
    BackupExecutionArbiter? arbiter,
    String Function()? taskIdFactory,
    BackupRunBinding? Function(UploadTaskMetadata metadata, Task task)? validateBinding,
    BackupRunBindingResolution Function(UploadTaskMetadata metadata, Task task)? resolveBinding,
    Future<bool> Function(BackupRunBinding binding)? canContinueOwnedUpload,
    void Function(bool success)? onOwnedTerminal,
    void Function()? onReconciliationPending,
    void Function()? onReconciliationBlocked,
    Future<bool> Function(BackupRunBinding binding)? reconcileOwnedSuccess,
    Future<void> Function(Duration delay)? reconciliationDelay,
    Future<void> Function(Duration delay)? completedTaskRecheckDelay,
  }) : _leasePort = leasePort,
       _arbiter = arbiter,
       _taskIdFactory = taskIdFactory ?? _opaqueTaskId,
       _resolveBinding =
           resolveBinding ??
           ((metadata, task) {
             final binding = validateBinding?.call(metadata, task);
             return binding == null
                 ? const BackupRunBindingResolution.temporarilyUnavailable()
                 : BackupRunBindingResolution.current(binding);
           }),
       _canContinueOwnedUpload = canContinueOwnedUpload ?? ((_) async => true),
       _requiresConnectivityGate = canContinueOwnedUpload != null,
       _onOwnedTerminal = onOwnedTerminal,
       _onReconciliationPending = onReconciliationPending,
       _onReconciliationBlocked = onReconciliationBlocked,
       _reconcileOwnedSuccess = reconcileOwnedSuccess ?? ((_) async => true) {
    _reconciliationDelay = reconciliationDelay ?? Future<void>.delayed;
    _completedTaskRecheckDelay = completedTaskRecheckDelay ?? Future<void>.delayed;
    _uploadRepository.onUploadStatus = _onUploadCallback;
    _uploadRepository.onTaskProgress = _onTaskProgressCallback;
  }

  final UploadRepository _uploadRepository;
  final StorageRepository _storageRepository;
  final DriftLocalAssetRepository _localAssetRepository;
  final DriftBackupRepository _backupRepository;
  final AppSettingsService _appSettingsService;
  final AssetMediaRepository _assetMediaRepository;
  final BackupExecutionLeasePort? _leasePort;
  final BackupExecutionArbiter? _arbiter;
  final String Function() _taskIdFactory;
  final BackupRunBindingResolution Function(UploadTaskMetadata metadata, Task task) _resolveBinding;
  final Future<bool> Function(BackupRunBinding binding) _canContinueOwnedUpload;
  final bool _requiresConnectivityGate;
  final void Function(bool success)? _onOwnedTerminal;
  final void Function()? _onReconciliationPending;
  final void Function()? _onReconciliationBlocked;
  final Future<bool> Function(BackupRunBinding binding) _reconcileOwnedSuccess;
  late final Future<void> Function(Duration delay) _reconciliationDelay;
  late final Future<void> Function(Duration delay) _completedTaskRecheckDelay;
  final Logger _logger = Logger('BackgroundUploadService');

  final StreamController<TaskStatusUpdate> _taskStatusController = StreamController<TaskStatusUpdate>.broadcast();
  final StreamController<TaskProgressUpdate> _taskProgressController = StreamController<TaskProgressUpdate>.broadcast();
  final Map<BackupTaskClaim, Future<void>> _reconciliationOperations = {};
  Future<void>? _resumeReconciliationsOperation;
  bool _resumeReconciliationsRequested = false;
  bool _disposed = false;

  Stream<TaskStatusUpdate> get taskStatusStream => _taskStatusController.stream;
  Stream<TaskProgressUpdate> get taskProgressStream => _taskProgressController.stream;

  bool shouldAbortQueuingTasks = false;

  void _onTaskProgressCallback(TaskProgressUpdate update) {
    if (_isBackupGroup(update.task.group)) {
      unawaited(_handleOwnedProgress(update));
      return;
    }
    if (!_taskProgressController.isClosed) {
      _taskProgressController.add(update);
    }
  }

  void _onUploadCallback(TaskStatusUpdate update) {
    if (_isBackupGroup(update.task.group)) {
      unawaited(_handleOwnedStatus(update));
      return;
    }
    if (!_taskStatusController.isClosed) {
      _taskStatusController.add(update);
    }
  }

  void dispose() {
    _disposed = true;
    _taskStatusController.close();
    _taskProgressController.close();
  }

  Future<void> resumePersistedReconciliations() {
    final active = _resumeReconciliationsOperation;
    if (active != null) {
      _resumeReconciliationsRequested = true;
      return active;
    }
    late final Future<void> operation;
    operation = _drainPersistedReconciliations().whenComplete(() {
      if (identical(_resumeReconciliationsOperation, operation)) _resumeReconciliationsOperation = null;
    });
    _resumeReconciliationsOperation = operation;
    return operation;
  }

  Future<void> _drainPersistedReconciliations() async {
    do {
      _resumeReconciliationsRequested = false;
      await _resumePersistedReconciliations();
    } while (_resumeReconciliationsRequested && !_disposed);
  }

  Future<void> _resumePersistedReconciliations() async {
    final lease = await _leasePort?.read();
    if (lease == null || lease.reconciliationClaims.isEmpty) return;
    for (final claim in lease.reconciliationClaims) {
      final task = await _completedTaskAfterRecheck(claim);
      if (task == null) {
        final candidateKey = lease.candidateKeys[claim];
        if (candidateKey == null) {
          _onReconciliationBlocked?.call();
          continue;
        }
        await _quarantineReconciliation(
          lease: lease,
          claim: claim,
          candidateKey: candidateKey,
          code: BackupReconciliationQuarantineCode.completedTaskMissing,
        );
        continue;
      }
      final metadata = _taskMetadata(task);
      final candidateKey = metadata?.candidateKey ?? lease.candidateKeys[claim];
      if (metadata?.ownership == null || metadata?.bindingAuthority == null || candidateKey == null) {
        if (candidateKey == null) {
          _onReconciliationBlocked?.call();
          continue;
        }
        await _quarantineReconciliation(
          lease: lease,
          claim: claim,
          candidateKey: candidateKey,
          code: BackupReconciliationQuarantineCode.immutableMetadataMissing,
        );
        continue;
      }
      final resolution = _resolveBinding(metadata!, task);
      if (resolution.kind == BackupRunBindingResolutionKind.temporarilyUnavailable) {
        _onReconciliationPending?.call();
        continue;
      }
      if (resolution.kind == BackupRunBindingResolutionKind.definitivelyStale) {
        await _quarantineReconciliation(
          lease: lease,
          claim: claim,
          candidateKey: candidateKey,
          code: BackupReconciliationQuarantineCode.definitivelyStale,
        );
        continue;
      }
      _scheduleReconciliation(claim, metadata.ownership!, resolution.binding!, task);
    }
  }

  Future<Task?> _completedTaskAfterRecheck(BackupTaskClaim claim) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final task = await _uploadRepository.completedTask(claim);
      if (task != null) return task;
      if (attempt < 2) await _completedTaskRecheckDelay(Duration(seconds: attempt + 1));
    }
    return null;
  }

  Future<void> _quarantineReconciliation({
    required BackupExecutionLease lease,
    required BackupTaskClaim claim,
    required String candidateKey,
    required BackupReconciliationQuarantineCode code,
  }) async {
    final quarantined = await _leasePort?.quarantineReconciliationForTask(
      runToken: lease.runToken,
      bindingDigest: lease.bindingDigest,
      claim: claim,
      candidateKey: candidateKey,
      code: code,
    );
    if (quarantined == null) return;
    _onReconciliationBlocked?.call();
    await _arbiter?.releaseCurrentWhenQuiescent(runToken: lease.runToken, bindingDigest: lease.bindingDigest);
  }

  /// Enqueue tasks to the background upload queue
  Future<List<bool>> enqueueTasks(List<UploadTask> tasks, {BackupTaskMetadata? ownership}) async {
    if (ownership == null) return _uploadRepository.enqueueBackgroundAll(tasks);
    final results = <bool>[];
    for (final task in tasks) {
      final taskMetadata = _ownedMetadata(task);
      if (taskMetadata?.ownership?.toJson() != ownership.toJson() ||
          taskMetadata?.expectedNativeRevision == null ||
          taskMetadata?.bindingAuthority == null ||
          taskMetadata?.candidateKey == null) {
        results.add(false);
        continue;
      }
      if (shouldAbortQueuingTasks) {
        results.add(false);
        continue;
      }
      final binding = _requiresConnectivityGate ? _resolveBinding(taskMetadata!, task).binding : null;
      if (_requiresConnectivityGate && (binding == null || !await _canContinueOwnedUpload(binding))) {
        results.add(false);
        continue;
      }
      final taskClaim = _claimForTask(task);
      final reservation = await _leasePort?.beginEnqueueUnlessQuarantined(
        runToken: ownership.runToken,
        bindingDigest: ownership.bindingDigest,
        claim: taskClaim,
        candidateKey: taskMetadata!.candidateKey!,
      );
      if (reservation == null) {
        results.add(false);
        continue;
      }
      try {
        if (binding != null && !await _canContinueOwnedUpload(binding)) {
          await _abortEnqueue(ownership, taskClaim);
          results.add(false);
          continue;
        }
        final pluginResult = await _uploadRepository.enqueueBackgroundAll([task]);
        final enqueued = pluginResult.length == 1 && pluginResult.first;
        if (!enqueued) {
          await _abortEnqueue(ownership, taskClaim);
          results.add(false);
          continue;
        }
        final confirmed = await _leasePort?.confirmEnqueueForTask(
          runToken: ownership.runToken,
          bindingDigest: ownership.bindingDigest,
          claim: taskClaim,
        );
        if (confirmed == null) {
          await _uploadRepository.cancelAndDrain(BackupExecutionArbiter.groups);
          results.add(false);
          continue;
        }
        results.add(true);
      } on Object {
        await _abortEnqueue(ownership, taskClaim);
        rethrow;
      }
    }
    return results;
  }

  Future<void> _abortEnqueue(BackupTaskMetadata ownership, BackupTaskClaim claim) async {
    await _leasePort?.abortEnqueueForTask(
      runToken: ownership.runToken,
      bindingDigest: ownership.bindingDigest,
      claim: claim,
    );
  }

  /// Get a list of tasks that are ENQUEUED or RUNNING
  Future<List<Task>> getActiveTasks(String group) {
    return _uploadRepository.getActiveTasks(group);
  }

  /// Start background upload using iOS URLSession
  ///
  /// Finds backup candidates, builds upload tasks, and enqueues them
  /// for background processing.
  Future<void> uploadBackupCandidates(
    String userId, {
    required BackupRunBinding binding,
    required BackupExecutionLease lease,
    required bool Function() isBindingCurrent,
  }) async {
    try {
      await _uploadBackupCandidates(userId, binding: binding, lease: lease, isBindingCurrent: isBindingCurrent);
    } finally {
      await _arbiter?.releaseCurrentWhenQuiescent(runToken: lease.runToken, bindingDigest: lease.bindingDigest);
    }
  }

  Future<void> _uploadBackupCandidates(
    String userId, {
    required BackupRunBinding binding,
    required BackupExecutionLease lease,
    required bool Function() isBindingCurrent,
  }) async {
    if (!isBindingCurrent()) return;
    if (!await _canContinueOwnedUpload(binding) || !isBindingCurrent()) return;
    await _storageRepository.clearCache();
    shouldAbortQueuingTasks = false;

    if (!await _canContinueOwnedUpload(binding) || !isBindingCurrent()) return;
    final candidates = await _backupRepository.getCandidates(userId);
    if (!isBindingCurrent()) return;
    if (candidates.isEmpty) {
      _logger.info('background_upload_no_candidates');
      return;
    }

    _logger.info('background_upload_candidates_found');

    const batchSize = 100;
    final batch = candidates.take(batchSize).toList();
    List<UploadTask> tasks = [];

    for (final asset in batch) {
      if (!await _canContinueOwnedUpload(binding) || !isBindingCurrent()) return;
      final task = await getUploadTask(
        asset,
        apiEndpoint: binding.apiEndpoint,
        expectedNativeRevision: binding.nativeGeneration,
        binding: binding,
        ownership: BackupTaskMetadata.current(
          runToken: lease.runToken,
          bindingDigest: lease.bindingDigest,
          phase: BackupTaskPhase.primary,
        ),
      );
      if (task != null) {
        tasks.add(task);
      }
    }

    if (tasks.isNotEmpty && !shouldAbortQueuingTasks && await _canContinueOwnedUpload(binding) && isBindingCurrent()) {
      _logger.info('background_upload_enqueue_started');
      await enqueueTasks(
        tasks,
        ownership: BackupTaskMetadata.current(
          runToken: lease.runToken,
          bindingDigest: lease.bindingDigest,
          phase: BackupTaskPhase.primary,
        ),
      );
    }
  }

  /// Cancel all ongoing background uploads and reset the upload queue
  ///
  /// Returns the number of tasks left in the queue
  Future<int> cancel() async {
    shouldAbortQueuingTasks = true;

    await _storageRepository.clearCache();
    final lease = await _leasePort?.read();
    if (lease == null) {
      return await _uploadRepository.cancelAndDrain(BackupExecutionArbiter.groups) ? 0 : 1;
    }
    final drained = await _arbiter?.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest);
    return drained == true ? 0 : 1;
  }

  /// Resume background backup processing
  Future<void> resume() {
    return _uploadRepository.start();
  }

  Future<bool> _handleTaskStatusUpdate(
    TaskStatusUpdate update,
    UploadTaskMetadata metadata,
    BackupRunBinding binding,
  ) async {
    switch (update.status) {
      case TaskStatus.complete:
        final terminalConfirmed = await _handleLivePhoto(update, metadata, binding);

        if (CurrentPlatform.isIOS) {
          try {
            final path = await update.task.filePath();
            await File(path).delete();
          } on Object {
            _logger.warning('backup_callback_cleanup_failed');
          }
        }

        return terminalConfirmed;

      default:
        return true;
    }
  }

  Future<bool> _handleLivePhoto(TaskStatusUpdate update, UploadTaskMetadata metadata, BackupRunBinding binding) async {
    try {
      if (!metadata.isLivePhotos) {
        return true;
      }

      if (update.responseBody == null || update.responseBody!.isEmpty) {
        return false;
      }
      final response = jsonDecode(update.responseBody!);

      final localAsset = await _localAssetRepository.getById(metadata.localAssetId);
      if (localAsset == null) {
        return false;
      }

      final ownership = metadata.ownership;
      if (ownership == null) return false;
      final liveOwnership = BackupTaskMetadata.current(
        runToken: ownership.runToken,
        bindingDigest: ownership.bindingDigest,
        phase: BackupTaskPhase.livePhoto,
      );
      final uploadTask = await getLivePhotoUploadTask(
        localAsset,
        response['id'] as String,
        ownership: liveOwnership,
        apiEndpoint: binding.apiEndpoint,
        expectedNativeRevision: binding.nativeGeneration,
        binding: binding,
      );

      if (uploadTask == null) {
        return false;
      }

      final result = await enqueueTasks([uploadTask], ownership: liveOwnership);
      return result.length == 1 && result.single;
    } on Object {
      dPrint(() => 'backup_live_photo_callback_failed');
      return false;
    }
  }

  Future<void> _handleOwnedStatus(TaskStatusUpdate update) async {
    final metadata = _ownedMetadata(update.task);
    if (metadata == null) return;
    final ownership = metadata.ownership!;
    final taskClaim = _claimForTask(update.task);
    final claim = await _leasePort?.beginCallbackForTask(
      runToken: ownership.runToken,
      bindingDigest: ownership.bindingDigest,
      claim: taskClaim,
    );
    if (claim == null) return;
    final binding = _resolveBinding(metadata, update.task).binding;
    if (binding == null) {
      await _leasePort?.endCallbackForTask(
        runToken: ownership.runToken,
        bindingDigest: ownership.bindingDigest,
        claim: taskClaim,
      );
      return;
    }
    var terminalSucceeded = false;
    BackupRunBinding? pendingReconciliation;
    try {
      if (!_taskStatusController.isClosed) _taskStatusController.add(update);
      final terminalConfirmed = await _handleTaskStatusUpdate(update, metadata, binding);
      var reconciled = true;
      if (update.status == TaskStatus.complete && terminalConfirmed) {
        reconciled = await _reconcileOwnedSuccess(binding);
      }
      if (update.status == TaskStatus.complete && terminalConfirmed && !reconciled) {
        final pending = await _leasePort?.markReconciliationPendingForTask(
          runToken: ownership.runToken,
          bindingDigest: ownership.bindingDigest,
          claim: taskClaim,
        );
        if (pending != null) pendingReconciliation = binding;
      } else if (_isTerminal(update.status) && terminalConfirmed && reconciled) {
        await _leasePort?.consumeTerminalForTask(
          runToken: ownership.runToken,
          bindingDigest: ownership.bindingDigest,
          claim: taskClaim,
        );
      }
      terminalSucceeded = update.status == TaskStatus.complete && terminalConfirmed && reconciled;
    } finally {
      final ended = await _leasePort?.endCallbackForTask(
        runToken: ownership.runToken,
        bindingDigest: ownership.bindingDigest,
        claim: taskClaim,
      );
      if (ended != null) {
        await _arbiter?.releaseCurrentWhenQuiescent(
          runToken: ownership.runToken,
          bindingDigest: ownership.bindingDigest,
        );
      }
      if (_isTerminal(update.status)) {
        if (pendingReconciliation != null) {
          _onReconciliationPending?.call();
          _scheduleReconciliation(taskClaim, ownership, pendingReconciliation, update.task);
        } else if (update.status == TaskStatus.complete && !terminalSucceeded) {
          _onReconciliationBlocked?.call();
        } else {
          _onOwnedTerminal?.call(terminalSucceeded);
        }
      }
    }
  }

  void _scheduleReconciliation(
    BackupTaskClaim claim,
    BackupTaskMetadata ownership,
    BackupRunBinding binding,
    Task task,
  ) {
    if (_disposed || _reconciliationOperations.containsKey(claim)) return;
    late final Future<void> operation;
    operation = _retryReconciliation(claim, ownership, binding, task).whenComplete(() {
      if (identical(_reconciliationOperations[claim], operation)) _reconciliationOperations.remove(claim);
    });
    _reconciliationOperations[claim] = operation;
  }

  Future<void> _retryReconciliation(
    BackupTaskClaim claim,
    BackupTaskMetadata ownership,
    BackupRunBinding binding,
    Task task,
  ) async {
    var attempt = 0;
    while (!_disposed) {
      final seconds = const [1, 2, 4, 8, 15, 30][min(attempt, 5)];
      attempt++;
      await _reconciliationDelay(Duration(seconds: seconds));
      if (_disposed) return;
      final metadata = _ownedMetadata(task);
      final resolution = metadata == null
          ? const BackupRunBindingResolution.temporarilyUnavailable()
          : _resolveBinding(metadata, task);
      if (resolution.kind == BackupRunBindingResolutionKind.temporarilyUnavailable) {
        _onReconciliationPending?.call();
        return;
      }
      if (resolution.kind == BackupRunBindingResolutionKind.definitivelyStale || resolution.binding != binding) {
        final lease = await _leasePort?.read();
        final candidateKey = metadata?.candidateKey ?? lease?.candidateKeys[claim];
        if (lease != null && candidateKey != null) {
          await _quarantineReconciliation(
            lease: lease,
            claim: claim,
            candidateKey: candidateKey,
            code: BackupReconciliationQuarantineCode.definitivelyStale,
          );
        }
        return;
      }
      final reconciled = await _tryReconcile(binding);
      if (!reconciled) {
        _onReconciliationPending?.call();
        continue;
      }
      final completed = await _leasePort?.completeReconciliationForTask(
        runToken: ownership.runToken,
        bindingDigest: ownership.bindingDigest,
        claim: claim,
      );
      if (completed == null) return;
      _onOwnedTerminal?.call(true);
      await _arbiter?.releaseCurrentWhenQuiescent(runToken: ownership.runToken, bindingDigest: ownership.bindingDigest);
      return;
    }
  }

  Future<bool> _tryReconcile(BackupRunBinding binding) async {
    try {
      return await _reconcileOwnedSuccess(binding);
    } on Object {
      return false;
    }
  }

  @visibleForTesting
  Future<void> handleOwnedStatusForTest(TaskStatusUpdate update) => _handleOwnedStatus(update);

  @visibleForTesting
  Future<void> handleOwnedProgressForTest(TaskProgressUpdate update) => _handleOwnedProgress(update);

  Future<void> _handleOwnedProgress(TaskProgressUpdate update) async {
    final metadata = _ownedMetadata(update.task);
    if (metadata == null) return;
    if (!_taskProgressController.isClosed) _taskProgressController.add(update);
  }

  UploadTaskMetadata? _ownedMetadata(Task task) {
    final metadata = _taskMetadata(task);
    return metadata?.ownership == null ? null : metadata;
  }

  UploadTaskMetadata? _taskMetadata(Task task) {
    if (task.metaData.isEmpty) return null;
    try {
      return UploadTaskMetadata.fromJson(task.metaData);
    } on Object {
      return null;
    }
  }

  static bool _isBackupGroup(String group) => group == kBackupGroup || group == kBackupLivePhotoGroup;

  static BackupTaskClaim _claimForTask(Task task) => BackupTaskClaim(
    group: task.group == kBackupLivePhotoGroup ? BackupTaskGroup.livePhoto : BackupTaskGroup.primary,
    taskId: task.taskId,
  );

  static bool _isTerminal(TaskStatus status) => switch (status) {
    TaskStatus.complete || TaskStatus.failed || TaskStatus.canceled || TaskStatus.notFound => true,
    _ => false,
  };

  @visibleForTesting
  Future<UploadTask?> getUploadTask(
    LocalAsset asset, {
    Uri? apiEndpoint,
    String group = kBackupGroup,
    int? priority,
    BackupTaskMetadata? ownership,
    int? expectedNativeRevision,
    BackupRunBinding? binding,
  }) async {
    final entity = await _storageRepository.getAssetEntityForAsset(asset);
    if (entity == null) {
      _logger.warning('background_upload_asset_unavailable');
      return null;
    }

    File? file;

    /// iOS LivePhoto has two files: a photo and a video.
    /// They are uploaded separately, with video file being upload first, then returned with the assetId
    /// The assetId is then used as a metadata for the photo file upload task.
    ///
    /// We implement two separate upload groups for this, the normal one for the video file
    /// and the higher priority group for the photo file because the video file is already uploaded.
    if (entity.isLivePhoto) {
      file = await _storageRepository.getMotionFileForAsset(asset);
    } else {
      file = await _storageRepository.getFileForAsset(asset.id);
    }

    if (file == null) {
      _logger.warning('background_upload_file_unavailable');
      return null;
    }

    String fileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;
    final hasExtension = p.extension(fileName).isNotEmpty;
    if (!hasExtension) {
      fileName = p.setExtension(fileName, p.extension(asset.name));
    }

    final originalFileName = entity.isLivePhoto ? p.setExtension(fileName, p.extension(file.path)) : fileName;
    final candidateKey = ownership == null
        ? null
        : BackupCandidateKey.fromLocalIdentity(deviceId: Store.get(StoreKey.deviceId), localAssetId: asset.id).value;

    String metadata = UploadTaskMetadata(
      localAssetId: asset.id,
      isLivePhotos: entity.isLivePhoto,
      livePhotoVideoId: '',
      ownership: ownership,
      expectedNativeRevision: expectedNativeRevision,
      bindingAuthority: binding == null ? null : UploadBindingAuthority.fromBinding(binding),
      candidateKey: candidateKey,
    ).toJson();

    final requiresWiFi = ownership != null || _shouldRequireWiFi(asset);

    return buildUploadTask(
      file,
      createdAt: asset.createdAt,
      modifiedAt: asset.updatedAt,
      originalFileName: originalFileName,
      deviceAssetId: asset.id,
      metadata: metadata,
      opaqueTaskId: ownership != null,
      apiEndpoint: apiEndpoint,
      group: group,
      priority: priority,
      isFavorite: asset.isFavorite,
      requiresWiFi: requiresWiFi,
      cloudId: entity.isLivePhoto ? null : asset.cloudId,
      adjustmentTime: entity.isLivePhoto ? null : asset.adjustmentTime?.toIso8601String(),
      latitude: entity.isLivePhoto ? null : asset.latitude?.toString(),
      longitude: entity.isLivePhoto ? null : asset.longitude?.toString(),
    );
  }

  @visibleForTesting
  Future<UploadTask?> getLivePhotoUploadTask(
    LocalAsset asset,
    String livePhotoVideoId, {
    BackupTaskMetadata? ownership,
    Uri? apiEndpoint,
    int? expectedNativeRevision,
    BackupRunBinding? binding,
  }) async {
    final entity = await _storageRepository.getAssetEntityForAsset(asset);
    if (entity == null) {
      return null;
    }

    final file = await _storageRepository.getFileForAsset(asset.id);
    if (file == null) {
      return null;
    }

    final fields = {'livePhotoVideoId': livePhotoVideoId};

    final requiresWiFi = ownership != null || _shouldRequireWiFi(asset);
    final originalFileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;
    final candidateKey = ownership == null
        ? null
        : BackupCandidateKey.fromLocalIdentity(deviceId: Store.get(StoreKey.deviceId), localAssetId: asset.id).value;

    return buildUploadTask(
      file,
      createdAt: asset.createdAt,
      modifiedAt: asset.updatedAt,
      originalFileName: originalFileName,
      deviceAssetId: asset.id,
      fields: fields,
      metadata: UploadTaskMetadata(
        localAssetId: asset.id,
        isLivePhotos: false,
        livePhotoVideoId: livePhotoVideoId,
        ownership: ownership,
        expectedNativeRevision: expectedNativeRevision,
        bindingAuthority: binding == null ? null : UploadBindingAuthority.fromBinding(binding),
        candidateKey: candidateKey,
      ).toJson(),
      opaqueTaskId: ownership != null,
      apiEndpoint: apiEndpoint,
      group: kBackupLivePhotoGroup,
      priority: 0, // Highest priority to get upload immediately
      isFavorite: asset.isFavorite,
      requiresWiFi: requiresWiFi,
      cloudId: asset.cloudId,
      adjustmentTime: asset.adjustmentTime?.toIso8601String(),
      latitude: asset.latitude?.toString(),
      longitude: asset.longitude?.toString(),
    );
  }

  bool _shouldRequireWiFi(LocalAsset asset) {
    bool requiresWiFi = true;

    if (asset.isVideo && _appSettingsService.getSetting(AppSettingsEnum.useCellularForUploadVideos)) {
      requiresWiFi = false;
    } else if (!asset.isVideo && _appSettingsService.getSetting(AppSettingsEnum.useCellularForUploadPhotos)) {
      requiresWiFi = false;
    }

    return requiresWiFi;
  }

  Future<UploadTask> buildUploadTask(
    File file, {
    required String group,
    required DateTime createdAt,
    required DateTime modifiedAt,
    Map<String, String>? fields,
    String? originalFileName,
    String? deviceAssetId,
    String? metadata,
    bool opaqueTaskId = false,
    Uri? apiEndpoint,
    int? priority,
    bool? isFavorite,
    bool requiresWiFi = true,
    String? cloudId,
    String? adjustmentTime,
    String? latitude,
    String? longitude,
  }) async {
    final serverEndpoint = apiEndpoint ?? Uri.parse(Store.get(StoreKey.serverEndpoint));
    final url = Uri.parse('$serverEndpoint/assets').toString();
    final headers = ApiService.getRequestHeaders();
    final deviceId = Store.get(StoreKey.deviceId);
    final (baseDirectory, directory, filename) = await Task.split(filePath: file.path);
    final fieldsMap = {
      'filename': originalFileName ?? filename,
      'deviceAssetId': deviceAssetId ?? '',
      'deviceId': deviceId,
      'fileCreatedAt': createdAt.toUtc().toIso8601String(),
      'fileModifiedAt': modifiedAt.toUtc().toIso8601String(),
      'isFavorite': isFavorite?.toString() ?? 'false',
      'duration': '0',
      if (fields != null) ...fields,
      if (CurrentPlatform.isIOS && cloudId != null)
        'metadata': jsonEncode([
          RemoteAssetMetadataItem(
            key: RemoteAssetMetadataKey.mobileApp,
            value: RemoteAssetMobileAppMetadata(
              cloudId: cloudId,
              createdAt: createdAt.toIso8601String(),
              adjustmentTime: adjustmentTime,
              latitude: latitude,
              longitude: longitude,
            ),
          ),
        ]),
    };

    return UploadTask(
      taskId: opaqueTaskId ? _taskIdFactory() : deviceAssetId,
      displayName: originalFileName ?? filename,
      httpRequestMethod: 'POST',
      url: url,
      headers: headers,
      filename: filename,
      fields: fieldsMap,
      baseDirectory: baseDirectory,
      directory: directory,
      fileField: 'assetData',
      metaData: metadata ?? '',
      group: group,
      requiresWiFi: requiresWiFi,
      priority: priority ?? 5,
      updates: Updates.statusAndProgress,
      retries: 3,
    );
  }

  static String _opaqueTaskId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
