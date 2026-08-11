import 'package:immich_mobile/domain/models/network_uri.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';

final class ActivationSessionSnapshot {
  ActivationSessionSnapshot({
    required this.sessionEpoch,
    required this.probeGeneration,
    required this.userId,
    required this.accessToken,
    required Map<String, String> customHeaders,
  }) : customHeaders = Map.unmodifiable(customHeaders) {
    if (sessionEpoch < 0 || probeGeneration < 0) {
      throw ArgumentError('Activation generations must not be negative');
    }
    if (userId.isEmpty || accessToken.isEmpty) {
      throw ArgumentError('Activation identity must not be empty');
    }
  }

  final int sessionEpoch;
  final int probeGeneration;
  final String userId;
  final String accessToken;
  final Map<String, String> customHeaders;
}

abstract interface class ActivationSessionPort {
  ActivationSessionSnapshot snapshot();
}

abstract interface class PreparedApiGraph {}

abstract interface class EndpointApiGraphPort {
  Uri? get currentEndpoint;

  void block();

  Future<PreparedApiGraph> prepare(Uri apiEndpoint);

  Future<void> install(PreparedApiGraph graph);
}

final class NativeRequestContext {
  NativeRequestContext({
    required this.apiEndpoint,
    required this.canonicalOrigin,
    required this.accessToken,
    required this.schemePolicy,
    this.sessionEpoch = 0,
    required Map<String, String> customHeaders,
  }) : customHeaders = Map.unmodifiable(customHeaders) {
    final Uri? origin = canonicalOrigin;
    final Uri? endpoint = apiEndpoint;
    final String? token = accessToken;
    if (origin != null) {
      validateHttpOrigin(origin, 'canonicalOrigin');
      final policy = schemePolicy;
      if (policy == null) {
        throw ArgumentError('A canonical origin requires an endpoint scheme policy');
      }
      validateEndpointSchemePolicy(origin, policy);
      if (endpoint == null) {
        throw ArgumentError('A canonical origin requires an API endpoint');
      }
      validateHttpEndpoint(endpoint, 'apiEndpoint');
      if (endpoint.origin != origin.origin) {
        throw ArgumentError('The API endpoint must belong to the canonical origin');
      }
    }
    if (origin == null && endpoint != null) {
      throw ArgumentError('An API endpoint requires a canonical origin');
    }
    if (origin == null && schemePolicy != null) {
      throw ArgumentError('An endpoint scheme policy requires a canonical origin');
    }
    if (token != null && (token.isEmpty || origin == null)) {
      throw ArgumentError('An access token requires a non-empty canonical origin');
    }
    if (sessionEpoch < 0) {
      throw ArgumentError.value(sessionEpoch, 'sessionEpoch', 'Session epoch must not be negative');
    }
  }

  final Uri? apiEndpoint;
  final Uri? canonicalOrigin;
  final String? accessToken;
  final EndpointSchemePolicy? schemePolicy;
  final int sessionEpoch;
  final Map<String, String> customHeaders;
}

abstract interface class NativeRequestContextPort {
  NativeRequestContext snapshot();

  void block();

  Future<void> replace(NativeRequestContext context);

  Future<void> purge();

  void publishCleared();
}

final class ConfirmedServerEndpoint {
  ConfirmedServerEndpoint({
    required this.apiEndpoint,
    required this.schemePolicy,
    this.authenticatedSessionReady = true,
  }) {
    validateHttpEndpoint(apiEndpoint, 'apiEndpoint');
    validateEndpointSchemePolicy(Uri.parse(apiEndpoint.origin), schemePolicy);
  }

  final Uri apiEndpoint;
  final EndpointSchemePolicy schemePolicy;
  final bool authenticatedSessionReady;
}

abstract interface class ConfirmedEndpointStorePort {
  ConfirmedServerEndpoint? read();

  Future<void> write(ConfirmedServerEndpoint? endpoint);
}

final class WidgetCredentials {
  const WidgetCredentials({required this.apiEndpoint, required this.accessToken, required this.customHeaders});

  final Uri? apiEndpoint;
  final String? accessToken;
  final String? customHeaders;
}

abstract interface class WidgetCredentialsPort {
  Future<WidgetCredentials> snapshot();

  Future<void> write(WidgetCredentials credentials);

  Future<void> clear();
}

enum EndpointActivationStep { nativeContext, apiGraph, endpointStore, widgetCredentials }

typedef EndpointActivationCheckpoint = Future<void> Function(EndpointActivationStep step);
