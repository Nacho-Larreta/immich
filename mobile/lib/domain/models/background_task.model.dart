import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';

enum BackgroundTaskKind { localSync, hashAssets, remoteSync, cloudIds, linkedAlbums, websocketBatch, websocketEdit }

final class BackgroundTaskContextBinding {
  const BackgroundTaskContextBinding({
    required this.sessionEpoch,
    required this.nativeContextGeneration,
    this.userId,
    this.apiEndpoint,
    this.canonicalOrigin,
    this.schemePolicy,
  }) : assert(sessionEpoch >= 0),
       assert(nativeContextGeneration >= 0);

  final int sessionEpoch;
  final int nativeContextGeneration;
  final String? userId;
  final Uri? apiEndpoint;
  final Uri? canonicalOrigin;
  final EndpointSchemePolicy? schemePolicy;

  @override
  bool operator ==(Object other) =>
      other is BackgroundTaskContextBinding &&
      other.sessionEpoch == sessionEpoch &&
      other.nativeContextGeneration == nativeContextGeneration &&
      other.userId == userId &&
      other.apiEndpoint == apiEndpoint &&
      other.canonicalOrigin == canonicalOrigin &&
      other.schemePolicy == schemePolicy;

  @override
  int get hashCode =>
      Object.hash(sessionEpoch, nativeContextGeneration, userId, apiEndpoint, canonicalOrigin, schemePolicy);
}

final class BackgroundTaskDescriptor {
  const BackgroundTaskDescriptor._({required this.kind, this.full, this.payload, this.contextBinding});

  const BackgroundTaskDescriptor.localSync({required bool full})
    : this._(kind: BackgroundTaskKind.localSync, full: full);
  const BackgroundTaskDescriptor.hashAssets() : this._(kind: BackgroundTaskKind.hashAssets);
  const BackgroundTaskDescriptor.remoteSync() : this._(kind: BackgroundTaskKind.remoteSync);
  const BackgroundTaskDescriptor.cloudIds() : this._(kind: BackgroundTaskKind.cloudIds);
  const BackgroundTaskDescriptor.linkedAlbums() : this._(kind: BackgroundTaskKind.linkedAlbums);
  factory BackgroundTaskDescriptor.websocketBatch(List<dynamic> batch) => BackgroundTaskDescriptor._(
    kind: BackgroundTaskKind.websocketBatch,
    payload: List<Object?>.unmodifiable(batch.map(_copySendableJson)),
  );
  factory BackgroundTaskDescriptor.websocketEdit(dynamic data) =>
      BackgroundTaskDescriptor._(kind: BackgroundTaskKind.websocketEdit, payload: _copySendableJson(data));

  final BackgroundTaskKind kind;
  final bool? full;
  final Object? payload;
  final BackgroundTaskContextBinding? contextBinding;

  bool get requiresServerContext => switch (kind) {
    BackgroundTaskKind.localSync || BackgroundTaskKind.hashAssets => false,
    BackgroundTaskKind.remoteSync ||
    BackgroundTaskKind.cloudIds ||
    BackgroundTaskKind.linkedAlbums ||
    BackgroundTaskKind.websocketBatch ||
    BackgroundTaskKind.websocketEdit => true,
  };

  BackgroundTaskDescriptor boundTo(BackgroundTaskContextBinding binding) {
    if (!requiresServerContext) {
      throw StateError('Local-only background tasks cannot carry a server context binding');
    }
    return BackgroundTaskDescriptor._(kind: kind, full: full, payload: payload, contextBinding: binding);
  }

  @override
  bool operator ==(Object other) =>
      other is BackgroundTaskDescriptor &&
      other.kind == kind &&
      other.full == full &&
      other.contextBinding == contextBinding &&
      _sendableEquals(other.payload, payload);

  @override
  int get hashCode => Object.hash(kind, full, contextBinding, _sendableHash(payload));
}

final class BackgroundTaskCancelled implements Exception {
  const BackgroundTaskCancelled();
}

final class BackgroundTaskContextChanged implements Exception {
  const BackgroundTaskContextChanged();
}

Object? _copySendableJson(Object? value) => switch (value) {
  null || bool() || num() || String() => value,
  List() => List<Object?>.unmodifiable(value.map(_copySendableJson)),
  Map() => _copySendableMap(value),
  _ => throw ArgumentError.value(value, 'payload', 'Must contain only immutable JSON-compatible values'),
};

Map<String, Object?> _copySendableMap(Map<dynamic, dynamic> value) {
  final copy = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throw ArgumentError.value(key, 'payload', 'Map keys must be strings');
    }
    copy[key] = _copySendableJson(entry.value);
  }
  return Map.unmodifiable(copy);
}

bool _sendableEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is List && right is List) {
    return left.length == right.length &&
        List.generate(left.length, (index) => index).every((index) => _sendableEquals(left[index], right[index]));
  }
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.entries.every((entry) => right.containsKey(entry.key) && _sendableEquals(entry.value, right[entry.key]));
  }
  return left == right;
}

int _sendableHash(Object? value) => switch (value) {
  List() => Object.hashAll(value.map(_sendableHash)),
  Map() => Object.hashAll(
    (value.entries.toList()..sort((left, right) => '${left.key}'.compareTo('${right.key}'))).map(
      (entry) => Object.hash(entry.key, _sendableHash(entry.value)),
    ),
  ),
  _ => value.hashCode,
};
