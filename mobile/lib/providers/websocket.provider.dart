import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/utils/debounce.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';
import 'package:socket_io_client/socket_io_client.dart';

class WebsocketState {
  final Socket? socket;
  final bool isConnected;

  const WebsocketState({this.socket, required this.isConnected});

  WebsocketState copyWith({Socket? socket, bool? isConnected}) {
    return WebsocketState(socket: socket ?? this.socket, isConnected: isConnected ?? this.isConnected);
  }

  @override
  String toString() => 'WebsocketState(socket: $socket, isConnected: $isConnected)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is WebsocketState && other.socket == socket && other.isConnected == isConnected;
  }

  @override
  int get hashCode => socket.hashCode ^ isConnected.hashCode;
}

class WebsocketNotifier extends StateNotifier<WebsocketState> {
  WebsocketNotifier(this._ref) : super(const WebsocketState(socket: null, isConnected: false));

  final _log = Logger('WebsocketNotifier');
  final Ref _ref;

  final Debouncer _batchDebouncer = Debouncer(
    interval: const Duration(seconds: 5),
    maxWaitTime: const Duration(seconds: 10),
  );
  final List<dynamic> _batchedAssetUploadReady = [];
  var _acceptEvents = false;
  var _connectionGeneration = 0;

  @override
  void dispose() {
    _batchDebouncer.dispose();
    super.dispose();
  }

  /// Connects websocket to server unless already connected
  void connect() {
    if (state.isConnected) return;
    _acceptEvents = false;
    final authenticationState = _ref.read(authProvider);

    if (authenticationState.isAuthenticated) {
      try {
        final generation = ++_connectionGeneration;
        final endpoint = Uri.parse(Store.get(StoreKey.serverEndpoint));
        dPrint(() => "Attempting to connect to websocket");
        // Configure socket transports must be specified
        Socket socket = io(
          endpoint.origin,
          OptionBuilder()
              .setPath("${endpoint.path}/socket.io")
              .setTransports(['websocket'])
              .setWebSocketConnector(NetworkRepository.createWebSocket)
              .enableReconnection()
              .enableForceNew()
              .enableForceNewConnection()
              .enableAutoConnect()
              .build(),
        );

        socket.onConnect((_) {
          if (generation != _connectionGeneration) {
            socket.dispose();
            return;
          }
          _acceptEvents = true;
          dPrint(() => "Established Websocket Connection");
          state = WebsocketState(isConnected: true, socket: socket);
        });

        socket.onDisconnect((_) {
          if (generation != _connectionGeneration) {
            return;
          }
          _acceptEvents = false;
          dPrint(() => "Disconnect to Websocket Connection");
          state = const WebsocketState(isConnected: false, socket: null);
        });

        socket.on('error', (errorMessage) {
          if (generation != _connectionGeneration) {
            return;
          }
          _acceptEvents = false;
          _log.severe("Websocket Error - $errorMessage");
          state = const WebsocketState(isConnected: false, socket: null);
        });

        socket.on('AssetUploadReadyV1', (data) {
          if (generation == _connectionGeneration) {
            handleSyncAssetUploadReady(data);
          }
        });
        socket.on('AssetEditReadyV1', (data) {
          if (generation == _connectionGeneration) {
            handleSyncAssetEditReady(data);
          }
        });
        socket.on('on_config_update', (data) {
          if (generation == _connectionGeneration) {
            handleOnConfigUpdate(data);
          }
        });
        socket.on('on_new_release', (data) {
          if (generation == _connectionGeneration) {
            handleReleaseUpdates(data);
          }
        });
      } catch (e) {
        _acceptEvents = false;
        dPrint(() => "[WEBSOCKET] Catch Websocket Error - ${e.toString()}");
      }
    }
  }

  void disconnect() {
    dPrint(() => "Attempting to disconnect from websocket");

    _acceptEvents = false;
    _connectionGeneration++;
    _batchedAssetUploadReady.clear();

    state.socket?.dispose();
    state = const WebsocketState(isConnected: false, socket: null);
  }

  Future<void> waitForEvent(String event, bool Function(dynamic)? predicate, Duration timeout) {
    final completer = Completer<void>();

    void handler(dynamic data) {
      if (predicate == null || predicate(data)) {
        completer.complete();
        state.socket?.off(event, handler);
      }
    }

    state.socket?.on(event, handler);

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        state.socket?.off(event, handler);
        completer.completeError(TimeoutException("Timeout waiting for event: $event"));
      },
    );
  }

  void handleOnConfigUpdate(dynamic _) {
    if (!_acceptEvents) {
      return;
    }
    _ref.read(serverInfoProvider.notifier).getServerFeatures();
    _ref.read(serverInfoProvider.notifier).getServerConfig();
  }

  void handleReleaseUpdates(dynamic data) {
    if (!_acceptEvents) {
      return;
    }
    // Json guard
    if (data is! Map) {
      return;
    }

    final json = data.cast<String, dynamic>();
    final serverVersionJson = json.containsKey('serverVersion') ? json['serverVersion'] : null;
    final releaseVersionJson = json.containsKey('releaseVersion') ? json['releaseVersion'] : null;
    if (serverVersionJson == null || releaseVersionJson == null) {
      return;
    }

    final serverVersionDto = ServerVersionResponseDto.fromJson(serverVersionJson);
    final releaseVersionDto = ServerVersionResponseDto.fromJson(releaseVersionJson);
    if (serverVersionDto == null || releaseVersionDto == null) {
      return;
    }

    final serverVersion = ServerVersion.fromDto(serverVersionDto);
    final releaseVersion = ServerVersion.fromDto(releaseVersionDto);
    _ref.read(serverInfoProvider.notifier).handleReleaseInfo(serverVersion, releaseVersion);
  }

  void handleSyncAssetUploadReady(dynamic data) {
    if (!_acceptEvents) {
      return;
    }
    _batchedAssetUploadReady.add(data);
    _batchDebouncer.run(_processBatchedAssetUploadReady);
  }

  void handleSyncAssetEditReady(dynamic data) {
    if (!_acceptEvents) {
      return;
    }
    unawaited(_ref.read(backgroundSyncProvider).syncWebsocketEdit(data));
  }

  void _processBatchedAssetUploadReady() {
    if (!_acceptEvents || _batchedAssetUploadReady.isEmpty) {
      _batchedAssetUploadReady.clear();
      return;
    }

    final isSyncAlbumEnabled = Store.get(StoreKey.syncAlbums, false);
    try {
      unawaited(
        _ref.read(backgroundSyncProvider).syncWebsocketBatch(_batchedAssetUploadReady.toList()).then((_) {
          if (isSyncAlbumEnabled) {
            _ref.read(backgroundSyncProvider).syncLinkedAlbum();
          }
        }),
      );
    } catch (error) {
      _log.severe("Error processing batched AssetUploadReadyV1 events: $error");
    }

    _batchedAssetUploadReady.clear();
  }
}

final websocketProvider = StateNotifierProvider<WebsocketNotifier, WebsocketState>((ref) {
  return WebsocketNotifier(ref);
});
