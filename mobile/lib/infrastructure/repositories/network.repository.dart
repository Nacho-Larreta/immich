import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/http/canonical_origin_client.dart';
import 'package:immich_mobile/infrastructure/http/network_web_socket_lifecycle.dart';
import 'package:immich_mobile/platform/network_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:ok_http/ok_http.dart';
import 'package:web_socket/web_socket.dart';

typedef NativeRequestContextReplacement =
    Future<void> Function(Map<String, String> headers, String? canonicalOrigin, String? accessToken);
typedef NativeRequestContextFailClosed = Future<void> Function();

enum NetworkContextRole { rootWriter, attachedWorker }

final class NetworkTransportDrainTimeout implements Exception {
  const NetworkTransportDrainTimeout(this.timeout);

  final Duration timeout;

  @override
  String toString() => 'Network transport did not drain within $timeout';
}

class NetworkRepository {
  static CanonicalOriginClient? _client;
  static Pointer<Void>? _clientPointer;
  static final _requestOriginGuard = RequestOriginGuard();
  static final _contextQueue = _NetworkContextQueue();
  static NetworkWebSocketLifecycle _webSockets = NetworkWebSocketLifecycle();
  static int? _confirmedBlockedClearTransition;
  static EndpointSchemePolicy? _activeSchemePolicy;
  static int? _nativeGeneration;
  static var _transportFenced = false;
  static NetworkContextRole _contextRole = NetworkContextRole.rootWriter;
  static _NativeRequestContextFingerprint? _activeFingerprint;
  static const _transportDrainTimeout = Duration(seconds: 5);

  static Future<void> init({NetworkContextRole role = NetworkContextRole.rootWriter}) {
    _contextRole = role;
    return role == NetworkContextRole.rootWriter
        ? _init(
            replaceNativeContext: networkApi.replaceRequestContext,
            bindNativeClient: _bindNativeClient,
            failClosedNativeContext: networkApi.failClosedRequestContext,
            drainTransport: _fenceAndDrainTransport,
          )
        : _attachToNativeContext();
  }

  @visibleForTesting
  static Future<void> initForTest({
    required NativeRequestContextReplacement replaceNativeContext,
    Future<void> Function()? bindNativeClient,
    NativeRequestContextFailClosed? failClosedNativeContext,
    Future<void> Function()? drainTransport,
  }) => _initForTest(
    replaceNativeContext,
    bindNativeClient ?? () async {},
    failClosedNativeContext ?? () async {},
    drainTransport ?? _fenceAndDrainTransport,
  );

  static Future<void> _initForTest(
    NativeRequestContextReplacement replaceNativeContext,
    Future<void> Function() bindNativeClient,
    NativeRequestContextFailClosed failClosedNativeContext,
    Future<void> Function() drainTransport,
  ) {
    _contextRole = NetworkContextRole.rootWriter;
    _activeFingerprint = null;
    _requestOriginGuard.invalidate();
    return _init(
      replaceNativeContext: replaceNativeContext,
      bindNativeClient: bindNativeClient,
      failClosedNativeContext: failClosedNativeContext,
      drainTransport: drainTransport,
    );
  }

  static Future<void> _init({
    required NativeRequestContextReplacement replaceNativeContext,
    required Future<void> Function() bindNativeClient,
    required NativeRequestContextFailClosed failClosedNativeContext,
    required Future<void> Function() drainTransport,
  }) async {
    final readiness = Store.tryGet(StoreKey.authenticatedSessionReady);
    if (readiness == null) {
      await Store.put(StoreKey.authenticatedSessionReady, false);
    }
    final restored = StoredNativeRequestContext.restore(
      endpoint: Store.tryGet(StoreKey.serverEndpoint),
      policyName: Store.tryGet(StoreKey.serverEndpointSchemePolicy),
      authenticatedSessionReady: readiness ?? false,
      accessToken: Store.tryGet(StoreKey.accessToken),
      customHeaders: _storedHeaders(),
    );
    final fingerprint = _NativeRequestContextFingerprint.fromStored(restored);
    if (_requestOriginGuard.context.nativeContextConfirmed && _activeFingerprint == fingerprint) {
      return;
    }
    final transition = _blockForContextTransition();
    _activeFingerprint = null;
    return _contextQueue.protect(() async {
      await drainTransport();
      var nativeContextConfirmed = false;
      try {
        await replaceNativeContext(restored.customHeaders, restored.canonicalOrigin?.origin, restored.accessToken);
        nativeContextConfirmed = true;
        await bindNativeClient();
        _publishContext(
          transition,
          restored.canonicalOrigin == null
              ? const RequestOriginContext.cleared()
              : RequestOriginContext.restricted([restored.canonicalOrigin!]),
          restored.schemePolicy,
        );
        if (_requestOriginGuard.isCurrent(transition)) {
          _activeFingerprint = fingerprint;
        }
      } on Object {
        if (nativeContextConfirmed) {
          await failClosedNativeContext();
        } else {
          await _refreshNativeBindingKeepingFence();
        }
        rethrow;
      }
    });
  }

  static Future<void> _bindNativeClient() async {
    final snapshot = await networkApi.getRequestContextSnapshot();
    _bindNativeSnapshot(snapshot);
  }

  static void _bindNativeSnapshot(NetworkRequestContextSnapshot snapshot, {bool keepFence = false}) {
    final clientPointer = Pointer<Void>.fromAddress(snapshot.clientPointer);
    final bindingUnchanged =
        clientPointer == _clientPointer &&
        _nativeGeneration == snapshot.generation &&
        _client != null &&
        !_transportFenced &&
        !keepFence;
    if (!Platform.isIOS && bindingUnchanged) {
      return;
    }
    late final http.Client nativeClient;
    if (Platform.isIOS) {
      final session = URLSession.fromRawPointer(clientPointer.cast(), retainSession: false);
      nativeClient = CupertinoClient.fromSharedSession(session);
    } else {
      nativeClient = OkHttpClient.fromJniGlobalRef(
        clientPointer,
        configuration: const OkHttpClientConfiguration(
          connectTimeout: Duration(seconds: 30),
          readTimeout: Duration(seconds: 60),
          writeTimeout: Duration(seconds: 60),
        ),
      );
    }
    _clientPointer = clientPointer;
    _nativeGeneration = snapshot.generation;
    _installNativeClient(nativeClient);
    _webSockets = NetworkWebSocketLifecycle();
    _transportFenced = keepFence;
  }

  static Future<void> _attachToNativeContext() async {
    final transition = _blockForContextTransition();
    final snapshot = await networkApi.getRequestContextSnapshot();
    _bindNativeSnapshot(snapshot);
    if (!snapshot.confirmed) {
      return;
    }
    final origin = snapshot.canonicalOrigin == null
        ? null
        : validateCanonicalOrigin(Uri.parse(snapshot.canonicalOrigin!));
    _publishContext(
      transition,
      origin == null ? const RequestOriginContext.cleared() : RequestOriginContext.restricted([origin]),
      origin == null
          ? null
          : origin.scheme == 'https'
          ? EndpointSchemePolicy.httpsOnly
          : EndpointSchemePolicy.registeredLocalHttp,
    );
  }

  @visibleForTesting
  static void bindClientForTest(http.Client client) {
    _installNativeClient(client);
    _webSockets = NetworkWebSocketLifecycle();
    _transportFenced = false;
  }

  static void _installNativeClient(http.Client nativeClient) {
    final client = _client;
    if (client == null) {
      _client = CanonicalOriginClient(nativeClient, () => _requestOriginGuard.context);
      return;
    }
    client.replaceDelegate(nativeClient);
  }

  static Future<void> setHeaders(Map<String, String> headers, List<String> serverUrls, {String? token}) {
    final endpoint = Store.tryGet(StoreKey.serverEndpoint);
    if (endpoint == null || endpoint.isEmpty) {
      return Future.error(StateError('Cannot install headers without an active server endpoint'));
    }
    final activeEndpoint = Uri.parse(endpoint);
    final activeOrigin = canonicalOriginOfEndpoint(activeEndpoint);
    final declaredOrigins = serverUrls.map((url) => canonicalOriginOfEndpoint(Uri.parse(url))).toSet();
    if (!declaredOrigins.contains(activeOrigin)) {
      return Future.error(ArgumentError('The active server endpoint must be present in the declared server URLs'));
    }
    final policy = _storedActiveEndpointPolicy(endpoint);
    if (policy == null) {
      return Future.error(StateError('The active server endpoint has no approved scheme policy'));
    }
    final authenticatedSessionReady = Store.tryGet(StoreKey.authenticatedSessionReady) == true;
    if (token != null && !authenticatedSessionReady) {
      return Future.error(StateError('Cannot install a token before the authenticated session is committed'));
    }
    return replaceRequestContext(
      headers: headers,
      canonicalOrigin: activeOrigin,
      token: token ?? (authenticatedSessionReady ? Store.tryGet(StoreKey.accessToken) : null),
      schemePolicy: policy,
    );
  }

  static Future<void> replaceRequestContext({
    required Map<String, String> headers,
    required Uri? canonicalOrigin,
    required String? token,
    required EndpointSchemePolicy? schemePolicy,
  }) async {
    _ensureRootWriter();
    if (token != null && canonicalOrigin == null) {
      throw ArgumentError('A token requires a canonical origin');
    }
    if (headers.isNotEmpty && canonicalOrigin == null) {
      throw ArgumentError('Custom headers require a canonical origin');
    }
    if (canonicalOrigin == null && schemePolicy != null) {
      throw ArgumentError('An endpoint scheme policy requires a canonical origin');
    }
    final origin = canonicalOrigin == null ? null : validateCanonicalOrigin(canonicalOrigin);
    if (origin != null) {
      final policy = schemePolicy;
      if (policy == null) {
        throw ArgumentError('A canonical origin requires an endpoint scheme policy');
      }
      validateEndpointSchemePolicy(origin, policy);
    }
    _validateHeaders(headers);
    final fingerprint = _NativeRequestContextFingerprint(headers: headers, canonicalOrigin: origin, token: token);
    if (_requestOriginGuard.context.nativeContextConfirmed && _activeFingerprint == fingerprint) {
      _activeSchemePolicy = schemePolicy;
      return;
    }
    final transition = _blockForContextTransition();
    _activeFingerprint = null;
    await _contextQueue.protect(() async {
      await _fenceAndDrainTransport();
      var nativeContextConfirmed = false;
      try {
        await networkApi.replaceRequestContext(headers, origin?.origin, token);
        nativeContextConfirmed = true;
        await _bindNativeClient();
        _publishContext(
          transition,
          origin == null ? const RequestOriginContext.cleared() : RequestOriginContext.restricted([origin]),
          schemePolicy,
        );
        if (_requestOriginGuard.isCurrent(transition)) {
          _activeFingerprint = fingerprint;
        }
      } on Object {
        if (nativeContextConfirmed) {
          await networkApi.failClosedRequestContext();
        } else {
          await _refreshNativeBindingKeepingFence();
        }
        rethrow;
      }
    });
  }

  static void blockRequests() {
    _requestOriginGuard.invalidate();
    _confirmedBlockedClearTransition = null;
    _activeFingerprint = null;
  }

  static Future<void> clearRequestContext() {
    return replaceRequestContext(headers: const {}, canonicalOrigin: null, token: null, schemePolicy: null);
  }

  static bool hasConfirmedRequestContext(Uri canonicalOrigin) {
    final origin = validateCanonicalOrigin(canonicalOrigin);
    final context = _requestOriginGuard.context;
    return context.nativeContextConfirmed &&
        context.allowedOrigins.length == 1 &&
        context.allowedOrigins.single == origin;
  }

  static EndpointSchemePolicy? get activeEndpointSchemePolicy => _activeSchemePolicy;

  static Future<void> purgeRequestContext() {
    _ensureRootWriter();
    return _purgeRequestContext(
      drainTransport: _fenceAndDrainTransport,
      replaceNativeContext: networkApi.replaceRequestContext,
      bindNativeClient: _bindNativeClient,
      failClosedNativeContext: networkApi.failClosedRequestContext,
    );
  }

  @visibleForTesting
  static Future<void> purgeRequestContextForTest({
    required Future<void> Function() drainTransport,
    required NativeRequestContextReplacement replaceNativeContext,
    required Future<void> Function() bindNativeClient,
    required NativeRequestContextFailClosed failClosedNativeContext,
  }) {
    _contextRole = NetworkContextRole.rootWriter;
    return _purgeRequestContext(
      drainTransport: drainTransport,
      replaceNativeContext: replaceNativeContext,
      bindNativeClient: bindNativeClient,
      failClosedNativeContext: failClosedNativeContext,
    );
  }

  static Future<void> _purgeRequestContext({
    required Future<void> Function() drainTransport,
    required NativeRequestContextReplacement replaceNativeContext,
    required Future<void> Function() bindNativeClient,
    required NativeRequestContextFailClosed failClosedNativeContext,
  }) {
    final transition = _blockForContextTransition();
    _activeFingerprint = null;
    return _contextQueue.protect(() async {
      try {
        await drainTransport();
      } on Object catch (error, stackTrace) {
        try {
          await failClosedNativeContext();
        } finally {
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
      var nativeContextConfirmed = false;
      try {
        await replaceNativeContext(const {}, null, null);
        nativeContextConfirmed = true;
        await bindNativeClient();
        if (_requestOriginGuard.isCurrent(transition)) {
          _confirmedBlockedClearTransition = transition;
        }
      } on Object {
        if (nativeContextConfirmed) {
          await failClosedNativeContext();
        } else {
          await _refreshNativeBindingKeepingFence();
        }
        rethrow;
      }
    });
  }

  static void publishClearedContext() {
    if (_confirmedBlockedClearTransition != null && _requestOriginGuard.isCurrent(_confirmedBlockedClearTransition!)) {
      _requestOriginGuard.publish(_confirmedBlockedClearTransition!, const RequestOriginContext.cleared());
      _activeSchemePolicy = null;
      _confirmedBlockedClearTransition = null;
    }
  }

  static Future<WebSocket> createWebSocket(Uri uri, {Map<String, String>? headers, Iterable<String>? protocols}) {
    final context = _requestOriginGuard.context;
    final origins = context.allowedOrigins;
    if (!context.nativeContextConfirmed || !origins.any((origin) => isWebSocketForCanonicalOrigin(uri, origin))) {
      return Future.error(ArgumentError.value(uri, 'uri', 'WebSocket must use the active canonical origin'));
    }
    return _webSockets.connect(() {
      if (Platform.isIOS) {
        final session = URLSession.fromRawPointer(_clientPointer!.cast());
        return CupertinoWebSocket.connectWithSession(session, uri, protocols: protocols, headers: headers);
      }
      return OkHttpWebSocket.connectFromJniGlobalRef(_clientPointer!, uri, protocols: protocols);
    });
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

  static Future<void> _fenceAndDrainTransport() async {
    final client = _client;
    if (client == null) {
      return;
    }
    try {
      await Future.wait([
        client.fenceAndDrain(timeout: _transportDrainTimeout),
        _webSockets.fenceAndDrain(timeout: _transportDrainTimeout),
      ]).timeout(_transportDrainTimeout);
      _transportFenced = true;
    } on TimeoutException {
      throw const NetworkTransportDrainTimeout(_transportDrainTimeout);
    }
  }

  static Future<void> _refreshNativeBindingKeepingFence() async {
    try {
      final snapshot = await networkApi.getRequestContextSnapshot();
      _bindNativeSnapshot(snapshot, keepFence: true);
    } on Object {
      return;
    }
  }

  static void _ensureRootWriter() {
    if (_contextRole != NetworkContextRole.rootWriter) {
      throw StateError('Attached network workers cannot replace the native request context');
    }
  }

  static void _publishContext(int transition, RequestOriginContext context, EndpointSchemePolicy? schemePolicy) {
    if (_requestOriginGuard.isCurrent(transition)) {
      _requestOriginGuard.publish(transition, context);
      _activeSchemePolicy = schemePolicy;
      _confirmedBlockedClearTransition = null;
    }
  }
}

final class StoredNativeRequestContext {
  const StoredNativeRequestContext._({
    required this.canonicalOrigin,
    required this.accessToken,
    required this.schemePolicy,
    required this.customHeaders,
  });

  const StoredNativeRequestContext.cleared()
    : this._(canonicalOrigin: null, accessToken: null, schemePolicy: null, customHeaders: const {});

  factory StoredNativeRequestContext.restore({
    required String? endpoint,
    required String? policyName,
    required bool authenticatedSessionReady,
    required String? accessToken,
    required Map<String, String> customHeaders,
  }) {
    if (!authenticatedSessionReady ||
        accessToken == null ||
        accessToken.isEmpty ||
        endpoint == null ||
        endpoint.isEmpty) {
      return const StoredNativeRequestContext.cleared();
    }
    final endpointUri = Uri.tryParse(endpoint);
    if (endpointUri == null) return const StoredNativeRequestContext.cleared();
    final policy =
        parseEndpointSchemePolicy(policyName) ??
        (endpointUri.scheme == 'https' ? EndpointSchemePolicy.httpsOnly : null);
    if (policy == null || policy == EndpointSchemePolicy.registeredLocalHttp) {
      return const StoredNativeRequestContext.cleared();
    }
    try {
      final origin = canonicalOriginOfEndpoint(endpointUri);
      validateEndpointSchemePolicy(origin, policy);
      return StoredNativeRequestContext._(
        canonicalOrigin: origin,
        accessToken: accessToken,
        schemePolicy: policy,
        customHeaders: Map.unmodifiable(customHeaders),
      );
    } on ArgumentError {
      return const StoredNativeRequestContext.cleared();
    }
  }

  final Uri? canonicalOrigin;
  final String? accessToken;
  final EndpointSchemePolicy? schemePolicy;
  final Map<String, String> customHeaders;
}

EndpointSchemePolicy? _storedActiveEndpointPolicy(String? endpoint) {
  if (endpoint == null || endpoint.isEmpty) return null;
  final uri = Uri.tryParse(endpoint);
  if (uri == null) return null;
  final stored = parseEndpointSchemePolicy(Store.tryGet(StoreKey.serverEndpointSchemePolicy));
  if (stored != null) return stored;
  return uri.scheme == 'https' ? EndpointSchemePolicy.httpsOnly : null;
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

final class _NativeRequestContextFingerprint {
  _NativeRequestContextFingerprint({
    required Map<String, String> headers,
    required this.canonicalOrigin,
    required this.token,
  }) : headers = Map.unmodifiable({for (final entry in headers.entries) entry.key.toLowerCase(): entry.value});

  factory _NativeRequestContextFingerprint.fromStored(StoredNativeRequestContext context) =>
      _NativeRequestContextFingerprint(
        headers: context.customHeaders,
        canonicalOrigin: context.canonicalOrigin,
        token: context.accessToken,
      );

  final Map<String, String> headers;
  final Uri? canonicalOrigin;
  final String? token;

  @override
  bool operator ==(Object other) =>
      other is _NativeRequestContextFingerprint &&
      canonicalOrigin == other.canonicalOrigin &&
      token == other.token &&
      mapEquals(headers, other.headers);

  @override
  int get hashCode {
    final names = headers.keys.toList(growable: false)..sort();
    return Object.hash(canonicalOrigin, token, Object.hashAll(names.map((name) => Object.hash(name, headers[name]))));
  }
}

void _validateHeaders(Map<String, String> headers) {
  final canonicalNames = <String>{};
  for (final name in headers.keys) {
    final canonicalName = name.toLowerCase();
    if (!canonicalNames.add(canonicalName)) {
      throw ArgumentError.value(name, 'headers', 'Header names must be unique ignoring case');
    }
  }
}
