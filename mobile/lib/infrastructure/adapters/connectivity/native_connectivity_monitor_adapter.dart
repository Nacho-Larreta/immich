import 'dart:async';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';

typedef ConnectivityFlutterApiRegistration = void Function(ConnectivityFlutterApi? api);

abstract interface class ConnectivityHostApi {
  Future<void> start();

  Future<ConnectivityTransportSnapshot> readCurrentSnapshot();

  Future<void> stop();

  Future<void> dispose();
}

final class ConnectivityHostException implements Exception {
  const ConnectivityHostException(this.message);

  final String message;
}

final class ConnectivitySnapshotConflict implements Exception {
  const ConnectivitySnapshotConflict();
}

final class PigeonConnectivityHostApi implements ConnectivityHostApi {
  PigeonConnectivityHostApi({ConnectivityApi? api}) : _api = api ?? ConnectivityApi();

  final ConnectivityApi _api;

  @override
  Future<void> start() => _translatePlatformFailure(_api.start());

  @override
  Future<ConnectivityTransportSnapshot> readCurrentSnapshot() => _translatePlatformFailure(_api.readCurrentSnapshot());

  @override
  Future<void> stop() => _translatePlatformFailure(_api.stop());

  @override
  Future<void> dispose() => _translatePlatformFailure(_api.dispose());
}

final class NativeConnectivityMonitorAdapter
    implements ConnectivityMonitorPort, ConnectivitySnapshotMonitorPort, ConnectivityFlutterApi {
  NativeConnectivityMonitorAdapter({ConnectivityHostApi? api, ConnectivityFlutterApiRegistration? registerFlutterApi})
    : _api = api ?? PigeonConnectivityHostApi(),
      _registerFlutterApi = registerFlutterApi ?? _registerWithPigeon;

  final ConnectivityHostApi _api;
  final ConnectivityFlutterApiRegistration _registerFlutterApi;
  final StreamController<TransportAvailability> _events = StreamController.broadcast(sync: true);
  final StreamController<BackupTransportSnapshot> _snapshotEvents = StreamController.broadcast(sync: true);

  Future<TransportAvailability>? _initializationFuture;
  Future<BackupTransportSnapshot>? _snapshotInitializationFuture;
  Future<void>? _disposeFuture;
  bool _disposed = false;
  BackupTransportSnapshot _latestSnapshot = const BackupTransportSnapshot(available: false, capabilities: {});

  @override
  Future<TransportAvailability> get initialAvailability {
    return _initializationFuture ??= _disposed ? Future.value(TransportAvailability.unknown) : _initialize();
  }

  @override
  Stream<TransportAvailability> get events => _events.stream;

  @override
  Future<BackupTransportSnapshot> get initialSnapshot {
    return _snapshotInitializationFuture ??= _disposed
        ? Future.value(const BackupTransportSnapshot(available: false, capabilities: {}))
        : _initializeSnapshot();
  }

  @override
  Stream<BackupTransportSnapshot> get snapshotEvents => _snapshotEvents.stream;

  @override
  void onTransportChanged(ConnectivityTransportSnapshot snapshot) {
    if (_disposed) {
      return;
    }
    _acceptSnapshot(snapshot);
  }

  @override
  Future<BackupTransportSnapshot> readCurrentSnapshot() async {
    if (_disposed) return const BackupTransportSnapshot(available: false, capabilities: {});
    try {
      await _ensureStarted();
      return _acceptSnapshot(await _api.readCurrentSnapshot());
    } on ConnectivityHostException {
      return const BackupTransportSnapshot(available: false, capabilities: {});
    } on PlatformException {
      return const BackupTransportSnapshot(available: false, capabilities: {});
    }
  }

  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) {
      return existing;
    }

    _disposed = true;
    Object? registrationError;
    StackTrace? registrationStackTrace;
    try {
      _registerFlutterApi(null);
    } on Object catch (error, stackTrace) {
      registrationError = error;
      registrationStackTrace = stackTrace;
    }
    return _disposeFuture = _releaseResources(registrationError, registrationStackTrace);
  }

  Future<TransportAvailability> _initialize() async {
    final snapshot = await initialSnapshot;
    return snapshot.available ? TransportAvailability.available : _lastAvailability;
  }

  TransportAvailability _lastAvailability = TransportAvailability.unknown;

  Future<BackupTransportSnapshot> _initializeSnapshot() async {
    try {
      await _ensureStarted();
      if (_disposed) {
        return const BackupTransportSnapshot(available: false, capabilities: {});
      }
      final snapshot = await _api.readCurrentSnapshot();
      if (_disposed) {
        return const BackupTransportSnapshot(available: false, capabilities: {});
      }
      return _acceptSnapshot(snapshot);
    } on ConnectivityHostException {
      return const BackupTransportSnapshot(available: false, capabilities: {});
    } on PlatformException {
      return const BackupTransportSnapshot(available: false, capabilities: {});
    }
  }

  Future<void>? _startFuture;

  BackupTransportSnapshot _acceptSnapshot(ConnectivityTransportSnapshot snapshot) {
    final candidate = _mapSnapshot(snapshot);
    if (candidate.hasSameCursorAs(_latestSnapshot)) {
      if (!candidate.hasSamePayloadAs(_latestSnapshot)) throw const ConnectivitySnapshotConflict();
      return _latestSnapshot;
    }
    if (!candidate.isNewerThan(_latestSnapshot)) return _latestSnapshot;
    _latestSnapshot = candidate;
    _lastAvailability = _mapAvailability(snapshot.availability);
    _events.add(_lastAvailability);
    _snapshotEvents.add(candidate);
    return candidate;
  }

  Future<void> _ensureStarted() => _startFuture ??= _start();

  Future<void> _start() async {
    _registerFlutterApi(this);
    await _api.start();
  }

  Future<void> _releaseResources(Object? firstError, StackTrace? firstStackTrace) async {
    Future<void> release(Future<void> Function() operation) async {
      try {
        await operation();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    final initialization = _initializationFuture;
    if (initialization != null) {
      await release(() async => initialization);
    }
    final snapshotInitialization = _snapshotInitializationFuture;
    if (snapshotInitialization != null && initialization == null) {
      await release(() async => snapshotInitialization);
    }
    await release(_events.close);
    await release(_snapshotEvents.close);
    await release(_api.dispose);

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  static TransportAvailability _mapAvailability(ConnectivityTransportAvailability availability) {
    return switch (availability) {
      ConnectivityTransportAvailability.unknown => TransportAvailability.unknown,
      ConnectivityTransportAvailability.unavailable => TransportAvailability.unavailable,
      ConnectivityTransportAvailability.available => TransportAvailability.available,
    };
  }

  static BackupTransportSnapshot _mapSnapshot(ConnectivityTransportSnapshot snapshot) {
    return BackupTransportSnapshot(
      available: snapshot.availability == ConnectivityTransportAvailability.available,
      capabilities: snapshot.capabilities.map(_mapCapability).toSet(),
      monitorEpoch: snapshot.monitorEpoch,
      revision: snapshot.revision,
    );
  }

  static BackupNetworkCapability _mapCapability(ConnectivityNetworkCapability capability) => switch (capability) {
    ConnectivityNetworkCapability.cellular => BackupNetworkCapability.cellular,
    ConnectivityNetworkCapability.wifi => BackupNetworkCapability.wifi,
    ConnectivityNetworkCapability.vpn => BackupNetworkCapability.vpn,
    ConnectivityNetworkCapability.unmetered => BackupNetworkCapability.unmetered,
  };

  static void _registerWithPigeon(ConnectivityFlutterApi? api) {
    ConnectivityFlutterApi.setUp(api);
  }
}

Future<T> _translatePlatformFailure<T>(Future<T> operation) async {
  try {
    return await operation;
  } on ConnectivityHostException {
    rethrow;
  } on Object catch (error) {
    throw ConnectivityHostException(error.toString());
  }
}
