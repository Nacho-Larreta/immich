import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/network_uri.model.dart';

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
    required this.canonicalOrigin,
    required this.accessToken,
    required Map<String, String> customHeaders,
  }) : customHeaders = Map.unmodifiable(customHeaders) {
    final Uri? origin = canonicalOrigin;
    final String? token = accessToken;
    if (origin != null) {
      validateHttpOrigin(origin, 'canonicalOrigin');
    }
    if (token != null && (token.isEmpty || origin == null)) {
      throw ArgumentError('An access token requires a non-empty canonical origin');
    }
  }

  final Uri? canonicalOrigin;
  final String? accessToken;
  final Map<String, String> customHeaders;
}

abstract interface class NativeRequestContextPort {
  NativeRequestContext snapshot();

  void block();

  Future<void> replace(NativeRequestContext context);

  Future<void> purge();

  void publishCleared();
}

abstract interface class ConfirmedEndpointStorePort {
  Uri? read();

  Future<void> write(Uri? endpoint);
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

abstract interface class ReachabilityPublicationPort {
  bool get blocked;

  void blockOffline();

  Future<void> publishOnline(EndpointActivationReceipt receipt);

  Future<void> restorePrevious();

  Future<void> publishLoggedOut();
}

enum EndpointActivationStep { nativeContext, apiGraph, endpointStore, widgetCredentials, onlinePublication }

typedef EndpointActivationCheckpoint = Future<void> Function(EndpointActivationStep step);
