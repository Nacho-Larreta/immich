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
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:ok_http/ok_http.dart';
import 'package:web_socket/web_socket.dart';

typedef NativeRequestContextReplacement =
    Future<void> Function(Map<String, String> headers, String? canonicalOrigin, String? accessToken);

class NetworkRepository {
  static CanonicalOriginClient? _client;
  static Pointer<Void>? _clientPointer;
  static final _requestOriginGuard = RequestOriginGuard();
  static final _contextQueue = _NetworkContextQueue();
  static int? _confirmedBlockedClearTransition;
  static EndpointSchemePolicy? _activeSchemePolicy;

  static Future<void> init() =>
      _init(replaceNativeContext: networkApi.replaceRequestContext, bindNativeClient: _bindNativeClient);

  @visibleForTesting
  static Future<void> initForTest({required NativeRequestContextReplacement replaceNativeContext}) =>
      _init(replaceNativeContext: replaceNativeContext, bindNativeClient: () async {});

  static Future<void> _init({
    required NativeRequestContextReplacement replaceNativeContext,
    required Future<void> Function() bindNativeClient,
  }) async {
    final transition = _blockForContextTransition();
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
    return _contextQueue.protect(() async {
      await replaceNativeContext(restored.customHeaders, restored.canonicalOrigin?.origin, restored.accessToken);
      await bindNativeClient();
      _publishContext(
        transition,
        restored.canonicalOrigin == null
            ? const RequestOriginContext.cleared()
            : RequestOriginContext.restricted([restored.canonicalOrigin!]),
        restored.schemePolicy,
      );
    });
  }

  static Future<void> _bindNativeClient() async {
    final clientPointer = Pointer<Void>.fromAddress(await networkApi.getClientPointer());
    if (clientPointer == _clientPointer && _client != null) {
      return;
    }
    late final http.Client nativeClient;
    if (Platform.isIOS) {
      final session = URLSession.fromRawPointer(clientPointer.cast());
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
    _installNativeClient(nativeClient);
  }

  @visibleForTesting
  static void bindClientForTest(http.Client client) => _installNativeClient(client);

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
  }) {
    if (token != null && canonicalOrigin == null) {
      return Future.error(ArgumentError('A token requires a canonical origin'));
    }
    if (headers.isNotEmpty && canonicalOrigin == null) {
      return Future.error(ArgumentError('Custom headers require a canonical origin'));
    }
    if (canonicalOrigin == null && schemePolicy != null) {
      return Future.error(ArgumentError('An endpoint scheme policy requires a canonical origin'));
    }
    final origin = canonicalOrigin == null ? null : validateCanonicalOrigin(canonicalOrigin);
    if (origin != null) {
      final policy = schemePolicy;
      if (policy == null) {
        return Future.error(ArgumentError('A canonical origin requires an endpoint scheme policy'));
      }
      try {
        validateEndpointSchemePolicy(origin, policy);
      } on ArgumentError catch (error) {
        return Future.error(error);
      }
    }
    final transition = _blockForContextTransition();
    return _contextQueue.protect(() async {
      await networkApi.replaceRequestContext(headers, origin?.origin, token);
      await _bindNativeClient();
      _publishContext(
        transition,
        origin == null ? const RequestOriginContext.cleared() : RequestOriginContext.restricted([origin]),
        schemePolicy,
      );
    });
  }

  static void blockRequests() {
    _requestOriginGuard.invalidate();
    _confirmedBlockedClearTransition = null;
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
      _activeSchemePolicy = null;
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
