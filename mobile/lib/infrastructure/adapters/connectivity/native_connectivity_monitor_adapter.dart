import 'dart:async';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';

typedef ConnectivityFlutterApiRegistration = void Function(ConnectivityFlutterApi? api);

abstract interface class ConnectivityHostApi {
  Future<void> start();

  Future<ConnectivityTransportSnapshot> getSnapshot();

  Future<void> stop();

  Future<void> dispose();
}

final class ConnectivityHostException implements Exception {
  const ConnectivityHostException(this.message);

  final String message;
}

final class PigeonConnectivityHostApi implements ConnectivityHostApi {
  PigeonConnectivityHostApi({ConnectivityApi? api}) : _api = api ?? ConnectivityApi();

  final ConnectivityApi _api;

  @override
  Future<void> start() => _translatePlatformFailure(_api.start());

  @override
  Future<ConnectivityTransportSnapshot> getSnapshot() => _translatePlatformFailure(_api.getSnapshot());

  @override
  Future<void> stop() => _translatePlatformFailure(_api.stop());

  @override
  Future<void> dispose() => _translatePlatformFailure(_api.dispose());
}

final class NativeConnectivityMonitorAdapter implements ConnectivityMonitorPort, ConnectivityFlutterApi {
  NativeConnectivityMonitorAdapter({ConnectivityHostApi? api, ConnectivityFlutterApiRegistration? registerFlutterApi})
    : _api = api ?? PigeonConnectivityHostApi(),
      _registerFlutterApi = registerFlutterApi ?? _registerWithPigeon;

  final ConnectivityHostApi _api;
  final ConnectivityFlutterApiRegistration _registerFlutterApi;
  final StreamController<TransportAvailability> _events = StreamController.broadcast(sync: true);

  Future<TransportAvailability>? _initializationFuture;
  Future<void>? _disposeFuture;
  bool _disposed = false;

  @override
  Future<TransportAvailability> get initialAvailability {
    return _initializationFuture ??= _disposed ? Future.value(TransportAvailability.unknown) : _initialize();
  }

  @override
  Stream<TransportAvailability> get events => _events.stream;

  @override
  void onTransportChanged(ConnectivityTransportSnapshot snapshot) {
    if (_disposed) {
      return;
    }
    _events.add(_mapAvailability(snapshot.availability));
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
    try {
      _registerFlutterApi(this);
      await _api.start();
      if (_disposed) {
        return TransportAvailability.unknown;
      }
      final snapshot = await _api.getSnapshot();
      if (_disposed) {
        return TransportAvailability.unknown;
      }
      return _mapAvailability(snapshot.availability);
    } on ConnectivityHostException {
      return TransportAvailability.unknown;
    } on PlatformException {
      return TransportAvailability.unknown;
    }
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
    await release(_events.close);
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
