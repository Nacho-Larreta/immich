import 'dart:convert';

enum BackupExecutionMode { foreground, background }

enum BackupExecutionState { accepting, closing }

final class BackupTaskClaim {
  const BackupTaskClaim({required this.group, required this.taskId});

  final BackupTaskGroup group;
  final String taskId;

  String get durableKey => '${group.name}:$taskId';

  Map<String, Object> toJsonValue() => {'group': group.name, 'taskId': taskId};

  static BackupTaskClaim fromJsonValue(Object? source) {
    final value = source as Map<String, dynamic>;
    final taskId = value['taskId'] as String;
    if (taskId.isEmpty) throw const FormatException('Empty task claim');
    return BackupTaskClaim(group: BackupTaskGroup.values.byName(value['group'] as String), taskId: taskId);
  }

  @override
  bool operator ==(Object other) => other is BackupTaskClaim && other.group == group && other.taskId == taskId;

  @override
  int get hashCode => Object.hash(group, taskId);
}

final class ForegroundTransportClaim {
  const ForegroundTransportClaim({
    required this.activityId,
    required this.bindingDigest,
    required this.nativeGeneration,
  });

  final String activityId;
  final String bindingDigest;
  final int nativeGeneration;

  Map<String, Object> toJsonValue() => {
    'activityId': activityId,
    'bindingDigest': bindingDigest,
    'nativeGeneration': nativeGeneration,
  };

  static ForegroundTransportClaim fromJsonValue(Object? source) {
    final value = source as Map<String, dynamic>;
    final activityId = value['activityId'] as String;
    final bindingDigest = value['bindingDigest'] as String;
    final nativeGeneration = value['nativeGeneration'] as int;
    if (activityId.isEmpty || bindingDigest.isEmpty || nativeGeneration < 0) {
      throw const FormatException('Invalid foreground transport claim');
    }
    return ForegroundTransportClaim(
      activityId: activityId,
      bindingDigest: bindingDigest,
      nativeGeneration: nativeGeneration,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ForegroundTransportClaim &&
      other.activityId == activityId &&
      other.bindingDigest == bindingDigest &&
      other.nativeGeneration == nativeGeneration;

  @override
  int get hashCode => Object.hash(activityId, bindingDigest, nativeGeneration);
}

final class BackupExecutionLease {
  static const schemaVersion = 7;

  BackupExecutionLease({
    required this.mode,
    required this.runToken,
    required this.bindingDigest,
    required this.expiresAt,
    required this.activityRevision,
    required this.callbacksInFlight,
    this.state = BackupExecutionState.accepting,
    Set<BackupTaskClaim> outstandingClaims = const {},
    Set<BackupTaskClaim> enqueueClaims = const {},
    Set<BackupTaskClaim> terminalTombstones = const {},
    Set<BackupTaskClaim> callbackClaims = const {},
    Set<BackupTaskClaim> reconciliationClaims = const {},
    Map<BackupTaskClaim, String> candidateKeys = const {},
    Set<ForegroundTransportClaim> foregroundActivityClaims = const {},
  }) : outstandingClaims = Set.unmodifiable(outstandingClaims),
       enqueueClaims = Set.unmodifiable(enqueueClaims),
       terminalTombstones = Set.unmodifiable(terminalTombstones),
       callbackClaims = Set.unmodifiable(callbackClaims),
       reconciliationClaims = Set.unmodifiable(reconciliationClaims),
       candidateKeys = Map.unmodifiable(candidateKeys),
       foregroundActivityClaims = Set.unmodifiable(foregroundActivityClaims) {
    if (runToken.isEmpty) throw ArgumentError.value(runToken, 'runToken', 'Must not be empty');
    if (bindingDigest.isEmpty) throw ArgumentError.value(bindingDigest, 'bindingDigest', 'Must not be empty');
    if (activityRevision < 0) {
      throw ArgumentError.value(activityRevision, 'activityRevision', 'Must not be negative');
    }
    if (callbacksInFlight < 0) {
      throw ArgumentError.value(callbacksInFlight, 'callbacksInFlight', 'Must not be negative');
    }
    if (foregroundActivityClaims.any((claim) => claim.bindingDigest != bindingDigest)) {
      throw ArgumentError.value(
        foregroundActivityClaims,
        'foregroundActivityClaims',
        'Must belong to the lease binding',
      );
    }
  }

  final BackupExecutionMode mode;
  final String runToken;
  final String bindingDigest;
  final DateTime expiresAt;
  final int activityRevision;
  final int callbacksInFlight;
  final BackupExecutionState state;
  final Set<BackupTaskClaim> outstandingClaims;
  final Set<BackupTaskClaim> enqueueClaims;
  final Set<BackupTaskClaim> terminalTombstones;
  final Set<BackupTaskClaim> callbackClaims;
  final Set<BackupTaskClaim> reconciliationClaims;
  final Map<BackupTaskClaim, String> candidateKeys;
  final Set<ForegroundTransportClaim> foregroundActivityClaims;

  bool get hasDurableActivity =>
      callbacksInFlight > 0 ||
      outstandingClaims.isNotEmpty ||
      enqueueClaims.isNotEmpty ||
      terminalTombstones.isNotEmpty ||
      callbackClaims.isNotEmpty ||
      reconciliationClaims.isNotEmpty ||
      foregroundActivityClaims.isNotEmpty;

  bool isExpiredAt(DateTime now) => !expiresAt.isAfter(now);

  BackupExecutionLease copyWith({
    BackupExecutionMode? mode,
    DateTime? expiresAt,
    int? activityRevision,
    int? callbacksInFlight,
    BackupExecutionState? state,
    Set<BackupTaskClaim>? outstandingClaims,
    Set<BackupTaskClaim>? enqueueClaims,
    Set<BackupTaskClaim>? terminalTombstones,
    Set<BackupTaskClaim>? callbackClaims,
    Set<BackupTaskClaim>? reconciliationClaims,
    Map<BackupTaskClaim, String>? candidateKeys,
    Set<ForegroundTransportClaim>? foregroundActivityClaims,
  }) => BackupExecutionLease(
    mode: mode ?? this.mode,
    runToken: runToken,
    bindingDigest: bindingDigest,
    expiresAt: expiresAt ?? this.expiresAt,
    activityRevision: activityRevision ?? this.activityRevision,
    callbacksInFlight: callbacksInFlight ?? this.callbacksInFlight,
    state: state ?? this.state,
    outstandingClaims: outstandingClaims ?? this.outstandingClaims,
    enqueueClaims: enqueueClaims ?? this.enqueueClaims,
    terminalTombstones: terminalTombstones ?? this.terminalTombstones,
    callbackClaims: callbackClaims ?? this.callbackClaims,
    reconciliationClaims: reconciliationClaims ?? this.reconciliationClaims,
    candidateKeys: candidateKeys ?? this.candidateKeys,
    foregroundActivityClaims: foregroundActivityClaims ?? this.foregroundActivityClaims,
  );

  String toJson() => jsonEncode({
    'schemaVersion': schemaVersion,
    'mode': mode.name,
    'runToken': runToken,
    'bindingDigest': bindingDigest,
    'expiryEpochMs': expiresAt.toUtc().millisecondsSinceEpoch,
    'activityRevision': activityRevision,
    'callbacksInFlight': callbacksInFlight,
    'state': state.name,
    'outstandingClaims': _orderedClaims(outstandingClaims),
    'enqueueClaims': _orderedClaims(enqueueClaims),
    'terminalTombstones': _orderedClaims(terminalTombstones),
    'callbackClaims': _orderedClaims(callbackClaims),
    'reconciliationClaims': _orderedClaims(reconciliationClaims),
    'candidateKeys': _orderedCandidateKeys(candidateKeys),
    'foregroundActivityClaims': _orderedForegroundClaims(foregroundActivityClaims),
  });

  static BackupExecutionLease? tryParse(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      final value = jsonDecode(source);
      if (value is! Map<String, dynamic> || value['schemaVersion'] != schemaVersion) return null;
      final mode = BackupExecutionMode.values.byName(value['mode'] as String);
      return BackupExecutionLease(
        mode: mode,
        runToken: value['runToken'] as String,
        bindingDigest: value['bindingDigest'] as String,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(value['expiryEpochMs'] as int, isUtc: true),
        activityRevision: value['activityRevision'] as int,
        callbacksInFlight: value['callbacksInFlight'] as int,
        state: BackupExecutionState.values.byName(value['state'] as String),
        outstandingClaims: _parseClaims(value['outstandingClaims']),
        enqueueClaims: _parseClaims(value['enqueueClaims']),
        terminalTombstones: _parseClaims(value['terminalTombstones']),
        callbackClaims: _parseClaims(value['callbackClaims']),
        reconciliationClaims: _parseClaims(value['reconciliationClaims']),
        candidateKeys: _parseCandidateKeys(value['candidateKeys']),
        foregroundActivityClaims: (value['foregroundActivityClaims'] as List<dynamic>)
            .map(ForegroundTransportClaim.fromJsonValue)
            .toSet(),
      );
    } on Object {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is BackupExecutionLease &&
      other.mode == mode &&
      other.runToken == runToken &&
      other.bindingDigest == bindingDigest &&
      other.expiresAt == expiresAt &&
      other.activityRevision == activityRevision &&
      other.callbacksInFlight == callbacksInFlight &&
      other.state == state &&
      _sameSet(other.outstandingClaims, outstandingClaims) &&
      _sameSet(other.enqueueClaims, enqueueClaims) &&
      _sameSet(other.terminalTombstones, terminalTombstones) &&
      _sameSet(other.callbackClaims, callbackClaims) &&
      _sameSet(other.reconciliationClaims, reconciliationClaims) &&
      _sameMap(other.candidateKeys, candidateKeys) &&
      _sameSet(other.foregroundActivityClaims, foregroundActivityClaims);

  @override
  int get hashCode => Object.hash(
    mode,
    runToken,
    bindingDigest,
    expiresAt,
    activityRevision,
    callbacksInFlight,
    state,
    Object.hashAll(outstandingClaims.map((claim) => claim.durableKey).toList()..sort()),
    Object.hashAll(enqueueClaims.map((claim) => claim.durableKey).toList()..sort()),
    Object.hashAll(terminalTombstones.map((claim) => claim.durableKey).toList()..sort()),
    Object.hashAll(callbackClaims.map((claim) => claim.durableKey).toList()..sort()),
    Object.hashAll(reconciliationClaims.map((claim) => claim.durableKey).toList()..sort()),
    Object.hashAll(candidateKeys.entries.map((entry) => '${entry.key.durableKey}:${entry.value}').toList()..sort()),
    Object.hashAll(foregroundActivityClaims.map((claim) => claim.activityId).toList()..sort()),
  );

  static List<Map<String, Object>> _orderedClaims(Set<BackupTaskClaim> claims) {
    final ordered = claims.toList()..sort((left, right) => left.durableKey.compareTo(right.durableKey));
    return ordered.map((claim) => claim.toJsonValue()).toList(growable: false);
  }

  static Set<BackupTaskClaim> _parseClaims(Object? source) =>
      (source as List<dynamic>).map(BackupTaskClaim.fromJsonValue).toSet();

  static List<Map<String, Object>> _orderedCandidateKeys(Map<BackupTaskClaim, String> candidateKeys) {
    final ordered = candidateKeys.entries.toList()
      ..sort((left, right) => left.key.durableKey.compareTo(right.key.durableKey));
    return ordered
        .map((entry) => {'claim': entry.key.toJsonValue(), 'candidateKey': entry.value})
        .toList(growable: false);
  }

  static Map<BackupTaskClaim, String> _parseCandidateKeys(Object? source) => {
    for (final value in source as List<dynamic>)
      BackupTaskClaim.fromJsonValue((value as Map<String, dynamic>)['claim']): value['candidateKey'] as String,
  };

  static List<Map<String, Object>> _orderedForegroundClaims(Set<ForegroundTransportClaim> claims) {
    final ordered = claims.toList()..sort((left, right) => left.activityId.compareTo(right.activityId));
    return ordered.map((claim) => claim.toJsonValue()).toList(growable: false);
  }

  static bool _sameSet<T>(Set<T> left, Set<T> right) => left.length == right.length && left.containsAll(right);

  static bool _sameMap<K, V>(Map<K, V> left, Map<K, V> right) =>
      left.length == right.length && left.entries.every((entry) => right[entry.key] == entry.value);
}

enum BackupTaskGroup { primary, livePhoto }

enum BackupTaskStatus { enqueued, running, waitingToRetry, paused, complete, failed, cancelled }

enum BackupTaskPhase { primary, livePhoto }

final class BackupTaskMetadata {
  static const schemaVersion = 1;

  const BackupTaskMetadata.current({required this.runToken, required this.bindingDigest, required this.phase})
    : version = schemaVersion;

  final int version;
  final String runToken;
  final String bindingDigest;
  final BackupTaskPhase phase;

  String toJson() =>
      jsonEncode({'schemaVersion': version, 'runToken': runToken, 'bindingDigest': bindingDigest, 'phase': phase.name});

  static BackupTaskMetadata? tryParse(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      final value = jsonDecode(source);
      if (value is! Map<String, dynamic> || value['schemaVersion'] != schemaVersion) return null;
      return BackupTaskMetadata.current(
        runToken: value['runToken'] as String,
        bindingDigest: value['bindingDigest'] as String,
        phase: BackupTaskPhase.values.byName(value['phase'] as String),
      );
    } on Object {
      return null;
    }
  }
}

final class BackupTaskSnapshot {
  const BackupTaskSnapshot({required this.taskId, required this.group, required this.status, this.metadata});

  final String taskId;
  final BackupTaskGroup group;
  final BackupTaskStatus status;
  final BackupTaskMetadata? metadata;

  bool get isActive => switch (status) {
    BackupTaskStatus.enqueued ||
    BackupTaskStatus.running ||
    BackupTaskStatus.waitingToRetry ||
    BackupTaskStatus.paused => true,
    _ => false,
  };
}

final class BackupTaskSnapshotIndex {
  final Map<(BackupTaskGroup, String), BackupTaskSnapshot> _snapshots = {};

  void add(BackupTaskSnapshot snapshot) {
    _snapshots[(snapshot.group, snapshot.taskId)] = snapshot;
  }

  List<BackupTaskSnapshot> get values => _snapshots.values.toList(growable: false);
}
