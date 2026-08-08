import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/http/canonical_origin_client.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:ok_http/ok_http.dart';
import 'package:web_socket/web_socket.dart';

class NetworkRepository {
  static http.Client? _client;
  static http.Client? _nativeClient;
  static Pointer<Void>? _clientPointer;
  static final _requestOriginGuard = RequestOriginGuard();
  static final _contextQueue = _NetworkContextQueue();
  static int? _confirmedBlockedClearTransition;

  static Future<void> init() {
    final endpoint = Store.tryGet(StoreKey.serverEndpoint);
    final origin = endpoint == null || endpoint.isEmpty ? null : canonicalOriginOfEndpoint(Uri.parse(endpoint));
    final token = origin == null ? null : Store.tryGet(StoreKey.accessToken);
    final headers = origin == null ? const <String, String>{} : _storedHeaders();
    final transition = _blockForContextTransition();
    return _contextQueue.protect(() async {
      await networkApi.replaceRequestContext(headers, origin?.origin, token);
      await _bindNativeClient();
      _publishContext(
        transition,
        origin == null ? const RequestOriginContext.cleared() : RequestOriginContext.restricted([origin]),
      );
    });
  }

  static Future<void> _bindNativeClient() async {
    final clientPointer = Pointer<Void>.fromAddress(await networkApi.getClientPointer());
    if (clientPointer == _clientPointer && _client != null) {
      return;
    }
    _clientPointer = clientPointer;
    _nativeClient?.close();
    if (Platform.isIOS) {
      final session = URLSession.fromRawPointer(clientPointer.cast());
      _nativeClient = CupertinoClient.fromSharedSession(session);
    } else {
      _nativeClient = OkHttpClient.fromJniGlobalRef(
        clientPointer,
        configuration: const OkHttpClientConfiguration(
          connectTimeout: Duration(seconds: 30),
          readTimeout: Duration(seconds: 60),
          writeTimeout: Duration(seconds: 60),
        ),
      );
    }
    _client = CanonicalOriginClient(_nativeClient!, () => _requestOriginGuard.context);
  }

  static Future<void> setHeaders(Map<String, String> headers, List<String> serverUrls, {String? token}) {
    final origins = serverUrls.map((url) => canonicalOriginOfEndpoint(Uri.parse(url))).toList(growable: false);
    final effectiveToken = token ?? (origins.isEmpty ? null : Store.tryGet(StoreKey.accessToken));
    if ((effectiveToken != null || headers.isNotEmpty) && origins.isEmpty) {
      return Future.error(ArgumentError('Credentials and custom headers require at least one server origin'));
    }
    final transition = _blockForContextTransition();
    return _contextQueue.protect(() async {
      await networkApi.setRequestHeaders(headers, origins.map((origin) => origin.origin).toList(), effectiveToken);
      await _bindNativeClient();
      _publishContext(
        transition,
        origins.isEmpty ? const RequestOriginContext.cleared() : RequestOriginContext.restricted(origins),
      );
    });
  }

  static Future<void> replaceRequestContext({
    required Map<String, String> headers,
    required Uri? canonicalOrigin,
    required String? token,
  }) {
    if (token != null && canonicalOrigin == null) {
      return Future.error(ArgumentError('A token requires a canonical origin'));
    }
    if (headers.isNotEmpty && canonicalOrigin == null) {
      return Future.error(ArgumentError('Custom headers require a canonical origin'));
    }
    final origin = canonicalOrigin == null ? null : validateCanonicalOrigin(canonicalOrigin);
    final transition = _blockForContextTransition();
    return _contextQueue.protect(() async {
      await networkApi.replaceRequestContext(headers, origin?.origin, token);
      await _bindNativeClient();
      _publishContext(
        transition,
        origin == null ? const RequestOriginContext.cleared() : RequestOriginContext.restricted([origin]),
      );
    });
  }

  static void blockRequests() {
    _requestOriginGuard.fence();
    _confirmedBlockedClearTransition = null;
  }

  static Future<void> clearRequestContext() {
    return replaceRequestContext(headers: const {}, canonicalOrigin: null, token: null);
  }

  static Future<void> purgeRequestContext() {
    final transition = _blockForContextTransition();
    return _contextQueue.protect(() async {
      await networkApi.replaceRequestContext(const {}, null, null);
      await _bindNativeClient();
      if (_requestOriginGuard.isCurrent(transition)) {
        _confirmedBlockedClearTransition = transition;
      }
    });
  }

  static void publishClearedContext() {
    if (_confirmedBlockedClearTransition != null && _requestOriginGuard.isCurrent(_confirmedBlockedClearTransition!)) {
      _requestOriginGuard.publish(_confirmedBlockedClearTransition!, const RequestOriginContext.cleared());
      _confirmedBlockedClearTransition = null;
    }
  }

  // ignore: avoid-unused-parameters
  static Future<WebSocket> createWebSocket(Uri uri, {Map<String, String>? headers, Iterable<String>? protocols}) {
    final context = _requestOriginGuard.context;
    final origins = context.allowedOrigins;
    if (!context.nativeContextConfirmed || !origins.any((origin) => isWebSocketForCanonicalOrigin(uri, origin))) {
      return Future.error(ArgumentError.value(uri, 'uri', 'WebSocket must use the active canonical origin'));
    }
    if (Platform.isIOS) {
      final session = URLSession.fromRawPointer(_clientPointer!.cast());
      return CupertinoWebSocket.connectWithSession(session, uri, protocols: protocols);
    } else {
      return OkHttpWebSocket.connectFromJniGlobalRef(_clientPointer!, uri, protocols: protocols);
    }
  }

  const NetworkRepository();

  /// Returns a shared HTTP client that uses native SSL configuration.
  ///
  /// On iOS: Uses SharedURLSessionManager's URLSession.
  /// On Android: Uses SharedHttpClientManager's OkHttpClient.
  ///
  /// Must call [init] before using this method.
  static http.Client get client => _client!;

  static int _blockForContextTransition() {
    _confirmedBlockedClearTransition = null;
    return _requestOriginGuard.block();
  }

  static void _publishContext(int transition, RequestOriginContext context) {
    if (_requestOriginGuard.isCurrent(transition)) {
      _requestOriginGuard.publish(transition, context);
      _confirmedBlockedClearTransition = null;
    }
  }
}

Map<String, String> _storedHeaders() {
  final value = Store.get(StoreKey.customHeaders, '');
  if (value.isEmpty) return const {};
  return (jsonDecode(value) as Map).cast<String, String>();
}

final class _NetworkContextQueue {
  Future<void> _tail = Future.value();

  Future<T> protect<T>(Future<T> Function() operation) {
    final predecessor = _tail;
    final completion = Completer<void>();
    _tail = completion.future;
    return predecessor.then((_) => operation()).whenComplete(completion.complete);
  }
}
