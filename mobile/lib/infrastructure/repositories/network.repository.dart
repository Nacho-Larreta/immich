import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/network_uri.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/http/canonical_origin_client.dart';
import 'package:immich_mobile/infrastructure/http/network_web_socket_lifecycle.dart';
import 'package:immich_mobile/platform/network_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:ok_http/ok_http.dart';
import 'package:web_socket/web_socket.dart';

typedef NativeRequestContextReplacement =
    Future<void> Function(
      Map<String, String> headers,
      String? apiEndpoint,
      String? canonicalOrigin,
      NetworkEndpointSchemePolicy? schemePolicy,
      String? accessToken,
      int sessionEpoch,
    );
typedef NativeRequestContextFailClosed = Future<void> Function();

enum NetworkContextRole { rootWriter, attachedWorker }

final class NativeServerAccessEvidence {
  const NativeServerAccessEvidence({
    required this.apiEndpoint,
    required this.canonicalOrigin,
    required this.schemePolicy,
    required this.sessionEpoch,
    required this.generation,
    required this.confirmed,
    required this.fenced,
  });

  final Uri? apiEndpoint;
  final Uri? canonicalOrigin;
  final EndpointSchemePolicy? schemePolicy;
  final int sessionEpoch;
  final int generation;
  final bool confirmed;
  final bool fenced;
}

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
  static NativeServerAccessEvidence _serverAccessEvidence = const NativeServerAccessEvidence(
    apiEndpoint: null,
    canonicalOrigin: null,
    schemePolicy: null,
    sessionEpoch: 0,
    generation: 0,
    confirmed: false,
    fenced: true,
  );
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
    _activeSchemePolicy = null;
    _nativeGeneration = null;
    _transportFenced = false;
    _serverAccessEvidence = const NativeServerAccessEvidence(
      apiEndpoint: null,
      canonicalOrigin: null,
      schemePolicy: null,
      sessionEpoch: 0,
      generation: 0,
      confirmed: false,
      fenced: true,
    );
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
        await replaceNativeContext(
          restored.customHeaders,
          restored.apiEndpoint?.toString(),
          restored.canonicalOrigin?.origin,
          _toNativeSchemePolicy(restored.schemePolicy),
          restored.accessToken,
          0,
        );
        nativeContextConfirmed = true;
        await bindNativeClient();
        _publishContext(
          transition,
          restored.canonicalOrigin == null
              ? const RequestOriginContext.cleared()
              : RequestOriginContext.restricted([restored.canonicalOrigin!]),
          restored.schemePolicy,
          restored.apiEndpoint,
          0,
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
    final descriptor = _validatedNativeDescriptor(snapshot);
    if (descriptor == null) return;
    _publishContext(
      transition,
      RequestOriginContext.restricted([descriptor.canonicalOrigin]),
      descriptor.schemePolicy,
      descriptor.apiEndpoint,
      snapshot.sessionEpoch,
    );
  }

  static ({Uri apiEndpoint, Uri canonicalOrigin, EndpointSchemePolicy schemePolicy})? _validatedNativeDescriptor(
    NetworkRequestContextSnapshot snapshot,
  ) {
    final endpointValue = snapshot.apiEndpoint;
    final originValue = snapshot.canonicalOrigin;
    final policyValue = snapshot.schemePolicy;
    if (!snapshot.confirmed || endpointValue == null || originValue == null || policyValue == null) return null;
    try {
      final endpoint = Uri.parse(endpointValue);
      final origin = validateCanonicalOrigin(Uri.parse(originValue));
      validateHttpEndpoint(endpoint, 'apiEndpoint');
      if (!endpoint.path.endsWith('/api') || endpoint.origin != origin.origin) return null;
      final policy = _fromNativeSchemePolicy(policyValue);
      validateEndpointSchemePolicy(origin, policy);
      final storedEndpointValue = Store.tryGet(StoreKey.serverEndpoint);
      final storedPolicyValue = Store.tryGet(StoreKey.serverEndpointSchemePolicy);
      if (storedEndpointValue == null || storedPolicyValue == null) return null;
      final storedEndpoint = Uri.tryParse(storedEndpointValue);
      final storedPolicy = parseEndpointSchemePolicy(storedPolicyValue);
      if (storedEndpoint == null || storedPolicy == null) return null;
      if (storedEndpoint != endpoint || storedPolicy != policy) return null;
      return (apiEndpoint: endpoint, canonicalOrigin: origin, schemePolicy: policy);
    } on Object {
      return null;
    }
  }

  @visibleForTesting
  static void bindClientForTest(http.Client client) {
    _installNativeClient(client);
    _webSockets = NetworkWebSocketLifecycle();
    _transportFenced = false;
  }

  @visibleForTesting
  static void setContextRoleForTest(NetworkContextRole role) {
    _contextRole = role;
  }

  @visibleForTesting
  static void attachNativeSnapshotForTest(NetworkRequestContextSnapshot snapshot) {
    _contextRole = NetworkContextRole.attachedWorker;
    _nativeGeneration = snapshot.generation;
    final transition = _blockForContextTransition();
    final descriptor = _validatedNativeDescriptor(snapshot);
    if (descriptor == null) return;
    _transportFenced = false;
    _publishContext(
      transition,
      RequestOriginContext.restricted([descriptor.canonicalOrigin]),
      descriptor.schemePolicy,
      descriptor.apiEndpoint,
      snapshot.sessionEpoch,
    );
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
      apiEndpoint: activeEndpoint,
      canonicalOrigin: activeOrigin,
      token: token ?? (authenticatedSessionReady ? Store.tryGet(StoreKey.accessToken) : null),
      schemePolicy: policy,
      sessionEpoch: _serverAccessEvidence.sessionEpoch,
    );
  }

  static Future<void> replaceRequestContext({
    required Map<String, String> headers,
    required Uri? apiEndpoint,
    required Uri? canonicalOrigin,
    required String? token,
    required EndpointSchemePolicy? schemePolicy,
    required int sessionEpoch,
  }) async {
    _ensureRootWriter();
    if (token != null && canonicalOrigin == null) {
      throw ArgumentError('A token requires a canonical origin');
    }
    if (sessionEpoch < 0) {
      throw ArgumentError.value(sessionEpoch, 'sessionEpoch', 'Session epoch must not be negative');
    }
    if (headers.isNotEmpty && canonicalOrigin == null) {
      throw ArgumentError('Custom headers require a canonical origin');
    }
    if (canonicalOrigin == null && schemePolicy != null) {
      throw ArgumentError('An endpoint scheme policy requires a canonical origin');
    }
    final origin = canonicalOrigin == null ? null : validateCanonicalOrigin(canonicalOrigin);
    if ((apiEndpoint == null) != (origin == null)) {
      throw ArgumentError('An API endpoint and canonical origin must be installed or cleared together');
    }
    if (apiEndpoint != null) {
      validateHttpEndpoint(apiEndpoint, 'apiEndpoint');
      if (apiEndpoint.origin != origin!.origin) {
        throw ArgumentError('The API endpoint must belong to the canonical origin');
      }
    }
    if (origin != null) {
      final policy = schemePolicy;
      if (policy == null) {
        throw ArgumentError('A canonical origin requires an endpoint scheme policy');
      }
      validateEndpointSchemePolicy(origin, policy);
    }
    _validateHeaders(headers);
    final fingerprint = _NativeRequestContextFingerprint(
      headers: headers,
      apiEndpoint: apiEndpoint,
      canonicalOrigin: origin,
      schemePolicy: schemePolicy,
      token: token,
      sessionEpoch: sessionEpoch,
    );
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
        await networkApi.replaceRequestContext(
          headers,
          apiEndpoint?.toString(),
          origin?.origin,
          _toNativeSchemePolicy(schemePolicy),
          token,
          sessionEpoch,
        );
        nativeContextConfirmed = true;
        await _bindNativeClient();
        _publishContext(
          transition,
          origin == null ? const RequestOriginContext.cleared() : RequestOriginContext.restricted([origin]),
          schemePolicy,
          apiEndpoint,
          sessionEpoch,
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
    _blockForContextTransition();
    _confirmedBlockedClearTransition = null;
    _activeFingerprint = null;
  }

  static Future<void> clearRequestContext() {
    return replaceRequestContext(
      headers: const {},
      apiEndpoint: null,
      canonicalOrigin: null,
      token: null,
      schemePolicy: null,
      sessionEpoch: _serverAccessEvidence.sessionEpoch,
    );
  }

  static bool hasConfirmedRequestContext(Uri canonicalOrigin) {
    final origin = validateCanonicalOrigin(canonicalOrigin);
    final context = _requestOriginGuard.context;
    return context.nativeContextConfirmed &&
        context.allowedOrigins.length == 1 &&
        context.allowedOrigins.single == origin;
  }

  static EndpointSchemePolicy? get activeEndpointSchemePolicy => _activeSchemePolicy;

  static NativeServerAccessEvidence get serverAccessEvidence => _serverAccessEvidence;
  static bool get isAttachedWorker => _contextRole == NetworkContextRole.attachedWorker;

  static Future<bool> fenceAndDrainCurrentTransport({
    required Uri canonicalOrigin,
    required int sessionEpoch,
    required int nativeGeneration,
  }) async {
    _ensureRootWriter();
    final expectedOrigin = validateCanonicalOrigin(canonicalOrigin);
    final before = _serverAccessEvidence;
    if (before.canonicalOrigin != expectedOrigin ||
        before.sessionEpoch != sessionEpoch ||
        before.generation != nativeGeneration) {
      return false;
    }
    _blockForContextTransition();
    await _fenceAndDrainTransport();
    final after = _serverAccessEvidence;
    return after.canonicalOrigin == expectedOrigin &&
        after.sessionEpoch == sessionEpoch &&
        after.generation == nativeGeneration &&
        after.fenced;
  }

  static Future<void> purgeRequestContext() {
    _ensureRootWriter();
    return _purgeRequestContext(
      drainTransport: _fenceAndDrainTransport,
      replaceNativeContext: networkApi.replaceRequestContext,
      bindNativeClient: _bindNativeClient,
      failClosedNativeContext: networkApi.failClosedRequestContext,
    );
  }

  static Future<void> drainAttachedWorker() async {
    if (_contextRole != NetworkContextRole.attachedWorker) {
      throw StateError('Only attached network workers can drain their local transport directly');
    }
    _blockForContextTransition();
    final client = _client;
    if (client == null) return;
    await Future.wait([client.fenceAndDrain(timeout: null), _webSockets.fenceAndDrain(timeout: null)]);
    _transportFenced = true;
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
        await replaceNativeContext(const {}, null, null, null, null, _serverAccessEvidence.sessionEpoch);
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
      _serverAccessEvidence = NativeServerAccessEvidence(
        apiEndpoint: null,
        canonicalOrigin: null,
        schemePolicy: null,
        sessionEpoch: _serverAccessEvidence.sessionEpoch,
        generation: _nativeGeneration ?? _serverAccessEvidence.generation,
        confirmed: true,
        fenced: _transportFenced,
      );
      _confirmedBlockedClearTransition = null;
    }
  }

  static Future<WebSocket> createWebSocket(Uri uri, {Map<String, String>? headers, Iterable<String>? protocols}) {
    if (_contextRole != NetworkContextRole.rootWriter) {
      return Future.error(StateError('Attached network workers cannot create WebSockets'));
    }
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
    _serverAccessEvidence = NativeServerAccessEvidence(
      apiEndpoint: _serverAccessEvidence.apiEndpoint,
      canonicalOrigin: _serverAccessEvidence.canonicalOrigin,
      schemePolicy: _serverAccessEvidence.schemePolicy,
      sessionEpoch: _serverAccessEvidence.sessionEpoch,
      generation: _serverAccessEvidence.generation,
      confirmed: false,
      fenced: true,
    );
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

  static void _publishContext(
    int transition,
    RequestOriginContext context,
    EndpointSchemePolicy? schemePolicy,
    Uri? apiEndpoint,
    int sessionEpoch,
  ) {
    if (_requestOriginGuard.isCurrent(transition)) {
      _requestOriginGuard.publish(transition, context);
      _activeSchemePolicy = schemePolicy;
      _confirmedBlockedClearTransition = null;
      _serverAccessEvidence = NativeServerAccessEvidence(
        apiEndpoint: apiEndpoint,
        canonicalOrigin: context.allowedOrigins.length == 1 ? context.allowedOrigins.single : null,
        schemePolicy: schemePolicy,
        sessionEpoch: sessionEpoch,
        generation: _nativeGeneration ?? 0,
        confirmed: context.nativeContextConfirmed,
        fenced: _transportFenced,
      );
    }
  }
}

final class StoredNativeRequestContext {
  const StoredNativeRequestContext._({
    required this.apiEndpoint,
    required this.canonicalOrigin,
    required this.accessToken,
    required this.schemePolicy,
    required this.customHeaders,
  });

  const StoredNativeRequestContext.cleared()
    : this._(apiEndpoint: null, canonicalOrigin: null, accessToken: null, schemePolicy: null, customHeaders: const {});

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
        apiEndpoint: endpointUri,
        canonicalOrigin: origin,
        accessToken: accessToken,
        schemePolicy: policy,
        customHeaders: Map.unmodifiable(customHeaders),
      );
    } on ArgumentError {
      return const StoredNativeRequestContext.cleared();
    }
  }

  final Uri? apiEndpoint;
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
    required this.apiEndpoint,
    required this.canonicalOrigin,
    required this.schemePolicy,
    required this.token,
    required this.sessionEpoch,
  }) : headers = Map.unmodifiable({for (final entry in headers.entries) entry.key.toLowerCase(): entry.value});

  factory _NativeRequestContextFingerprint.fromStored(StoredNativeRequestContext context) =>
      _NativeRequestContextFingerprint(
        headers: context.customHeaders,
        apiEndpoint: context.apiEndpoint,
        canonicalOrigin: context.canonicalOrigin,
        schemePolicy: context.schemePolicy,
        token: context.accessToken,
        sessionEpoch: 0,
      );

  final Map<String, String> headers;
  final Uri? apiEndpoint;
  final Uri? canonicalOrigin;
  final EndpointSchemePolicy? schemePolicy;
  final String? token;
  final int sessionEpoch;

  @override
  bool operator ==(Object other) =>
      other is _NativeRequestContextFingerprint &&
      apiEndpoint == other.apiEndpoint &&
      canonicalOrigin == other.canonicalOrigin &&
      schemePolicy == other.schemePolicy &&
      token == other.token &&
      sessionEpoch == other.sessionEpoch &&
      mapEquals(headers, other.headers);

  @override
  int get hashCode {
    final names = headers.keys.toList(growable: false)..sort();
    return Object.hash(
      apiEndpoint,
      canonicalOrigin,
      schemePolicy,
      token,
      sessionEpoch,
      Object.hashAll(names.map((name) => Object.hash(name, headers[name]))),
    );
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

NetworkEndpointSchemePolicy? _toNativeSchemePolicy(EndpointSchemePolicy? policy) => switch (policy) {
  EndpointSchemePolicy.httpsOnly => NetworkEndpointSchemePolicy.httpsOnly,
  EndpointSchemePolicy.explicitlyApprovedHttp => NetworkEndpointSchemePolicy.explicitlyApprovedHttp,
  EndpointSchemePolicy.registeredLocalHttp => NetworkEndpointSchemePolicy.registeredLocalHttp,
  null => null,
};

EndpointSchemePolicy _fromNativeSchemePolicy(NetworkEndpointSchemePolicy policy) => switch (policy) {
  NetworkEndpointSchemePolicy.httpsOnly => EndpointSchemePolicy.httpsOnly,
  NetworkEndpointSchemePolicy.explicitlyApprovedHttp => EndpointSchemePolicy.explicitlyApprovedHttp,
  NetworkEndpointSchemePolicy.registeredLocalHttp => EndpointSchemePolicy.registeredLocalHttp,
};
