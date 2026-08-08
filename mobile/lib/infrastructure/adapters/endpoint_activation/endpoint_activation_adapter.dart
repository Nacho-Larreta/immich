import 'dart:async';
import 'dart:convert';

import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_activation.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/services/session_mutation_mutex.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/endpoint_activation_collaborators.dart';
import 'package:logging/logging.dart';

final _log = Logger('EndpointActivationAdapter');

final class EndpointActivationAdapter implements EndpointActivationPort {
  EndpointActivationAdapter({
    required SessionMutationMutex mutex,
    required ActivationSessionPort session,
    required EndpointApiGraphPort apiGraph,
    required NativeRequestContextPort nativeContext,
    required ConfirmedEndpointStorePort endpointStore,
    required WidgetCredentialsPort widgetCredentials,
    required ReachabilityPublicationPort publication,
    EndpointActivationCheckpoint? checkpoint,
    Duration stalePurgeAttemptTimeout = const Duration(seconds: 5),
  }) : _mutex = mutex,
       _session = session,
       _apiGraph = apiGraph,
       _nativeContext = nativeContext,
       _endpointStore = endpointStore,
       _widgetCredentials = widgetCredentials,
       _publication = publication,
       _checkpoint = checkpoint ?? _noCheckpoint,
       _stalePurgeAttemptTimeout = stalePurgeAttemptTimeout;

  final SessionMutationMutex _mutex;
  final ActivationSessionPort _session;
  final EndpointApiGraphPort _apiGraph;
  final NativeRequestContextPort _nativeContext;
  final ConfirmedEndpointStorePort _endpointStore;
  final WidgetCredentialsPort _widgetCredentials;
  final ReachabilityPublicationPort _publication;
  final EndpointActivationCheckpoint _checkpoint;
  final Duration _stalePurgeAttemptTimeout;

  @override
  CancellableRequest<OfflineResult<EndpointActivationReceipt>> activate(EndpointActivationRequest request) {
    return _EndpointActivationOperation((signal) => _mutex.protect(() => _activate(request, signal)));
  }

  Future<OfflineResult<EndpointActivationReceipt>> _activate(
    EndpointActivationRequest request, [
    _CancellationSignal? cancellation,
  ]) async {
    final signal = cancellation ?? _CancellationSignal();
    late final ActivationSessionSnapshot initialSession;
    try {
      initialSession = _session.snapshot();
    } catch (error, stackTrace) {
      _log.warning('Unable to snapshot the activation session', error, stackTrace);
      return const OfflineResult.failure(OfflineErrorCode.serverUnavailable);
    }
    final freshnessError = _freshnessError(request, initialSession);
    if (freshnessError != null) {
      return OfflineResult.failure(freshnessError);
    }

    late final Uri? previousEndpoint;
    late final NativeRequestContext previousNativeContext;
    late final Uri? previousStoredEndpoint;
    late final WidgetCredentials previousWidgetCredentials;
    late final PreparedApiGraph preparedGraph;
    try {
      previousEndpoint = _apiGraph.currentEndpoint;
      previousNativeContext = _nativeContext.snapshot();
      previousStoredEndpoint = _endpointStore.read();
      previousWidgetCredentials = await _widgetCredentials.snapshot();
      preparedGraph = await _apiGraph.prepare(request.endpoint.apiEndpoint);
    } catch (error, stackTrace) {
      _log.warning('Unable to prepare endpoint activation', error, stackTrace);
      return const OfflineResult.failure(OfflineErrorCode.serverUnavailable);
    }
    final progress = _ActivationProgress();

    try {
      _ensureFresh(request, signal);
      progress.nativeContextAttempted = true;
      await _nativeContext.replace(
        NativeRequestContext(
          canonicalOrigin: request.endpoint.canonicalOrigin,
          accessToken: initialSession.accessToken,
          customHeaders: initialSession.customHeaders,
        ),
      );
      await _after(EndpointActivationStep.nativeContext, request, signal);

      progress.apiGraphAttempted = true;
      await _apiGraph.install(preparedGraph);
      await _after(EndpointActivationStep.apiGraph, request, signal);

      progress.endpointStoreAttempted = true;
      await _endpointStore.write(request.endpoint.apiEndpoint);
      await _after(EndpointActivationStep.endpointStore, request, signal);

      progress.widgetCredentialsAttempted = true;
      await _widgetCredentials.write(
        WidgetCredentials(
          apiEndpoint: request.endpoint.apiEndpoint,
          accessToken: initialSession.accessToken,
          customHeaders: _serializeHeaders(initialSession.customHeaders),
        ),
      );
      await _after(EndpointActivationStep.widgetCredentials, request, signal);

      final receipt = EndpointActivationReceipt(endpoint: request.endpoint, sessionEpoch: request.sessionEpoch);
      progress.onlinePublicationAttempted = true;
      await _publication.publishOnline(receipt);
      await _after(EndpointActivationStep.onlinePublication, request, signal);
      return OfflineResult.success(receipt);
    } on _StaleActivation catch (error) {
      final rollbackError = await _rollback(
        progress: progress,
        request: request,
        previousEndpoint: previousEndpoint,
        previousNativeContext: previousNativeContext,
        previousStoredEndpoint: previousStoredEndpoint,
        previousWidgetCredentials: previousWidgetCredentials,
      );
      return OfflineResult.failure(rollbackError ?? error.code);
    } catch (_) {
      final rollbackError = await _rollback(
        progress: progress,
        request: request,
        previousEndpoint: previousEndpoint,
        previousNativeContext: previousNativeContext,
        previousStoredEndpoint: previousStoredEndpoint,
        previousWidgetCredentials: previousWidgetCredentials,
      );
      return OfflineResult.failure(rollbackError ?? OfflineErrorCode.serverUnavailable);
    }
  }

  Future<void> _after(
    EndpointActivationStep step,
    EndpointActivationRequest request,
    _CancellationSignal signal,
  ) async {
    await _checkpoint(step);
    _ensureFresh(request, signal);
  }

  Future<OfflineErrorCode?> _rollback({
    required _ActivationProgress progress,
    required EndpointActivationRequest request,
    required Uri? previousEndpoint,
    required NativeRequestContext previousNativeContext,
    required Uri? previousStoredEndpoint,
    required WidgetCredentials previousWidgetCredentials,
  }) async {
    final sessionStillCurrent = _isSessionCurrent(request.sessionEpoch);

    if (!sessionStillCurrent) {
      return _purgeStaleSession();
    }

    if (progress.onlinePublicationAttempted) {
      await _compensate(_publication.restorePrevious);
    }
    if (progress.widgetCredentialsAttempted) {
      await _compensate(() => _widgetCredentials.write(previousWidgetCredentials));
    }
    if (progress.endpointStoreAttempted) {
      await _compensate(() => _endpointStore.write(previousStoredEndpoint));
    }
    if (progress.nativeContextAttempted) {
      await _compensate(() => _nativeContext.replace(previousNativeContext));
    }
    if (progress.apiGraphAttempted) {
      await _compensate(() async {
        final rollbackGraph = await _apiGraph.prepare(previousEndpoint ?? Uri());
        await _apiGraph.install(rollbackGraph);
      });
    }
    return null;
  }

  Future<OfflineErrorCode?> _purgeStaleSession() async {
    final fenceApplied = _applyStaleFence();
    final credentialPurgeResults = await Future.wait([
      _purgeCredential(_widgetCredentials.clear),
      _purgeCredential(_nativeContext.purge),
    ]);
    final [widgetPurged, nativePurged] = credentialPurgeResults;
    final graphReset = await _tryResetGraph();

    if (!fenceApplied || !widgetPurged || !nativePurged || !graphReset) {
      _applyStaleFence();
      return OfflineErrorCode.credentialPurgeFailed;
    }
    try {
      await _publication.publishLoggedOut();
      _nativeContext.publishCleared();
    } catch (error, stackTrace) {
      _log.warning('Unable to publish logged-out state after credential purge', error, stackTrace);
      _applyStaleFence();
      return OfflineErrorCode.credentialPurgeFailed;
    }
    return null;
  }

  bool _applyStaleFence() {
    var applied = true;
    for (final fence in [_publication.blockOffline, _nativeContext.block, _apiGraph.block]) {
      try {
        fence();
      } catch (error, stackTrace) {
        applied = false;
        _log.warning('Unable to apply stale activation fence', error, stackTrace);
      }
    }
    return applied && _publication.blocked;
  }

  Future<bool> _purgeCredential(Future<void> Function() purge) async {
    try {
      await purge().timeout(_stalePurgeAttemptTimeout);
      return true;
    } catch (error, stackTrace) {
      _log.warning('Credential purge failed', error, stackTrace);
      return false;
    }
  }

  Future<bool> _tryResetGraph() async {
    try {
      await (() async {
        final loggedOutGraph = await _apiGraph.prepare(Uri());
        await _apiGraph.install(loggedOutGraph);
      })().timeout(_stalePurgeAttemptTimeout);
      return true;
    } catch (error, stackTrace) {
      _log.warning('Unable to install logged-out API graph', error, stackTrace);
      return false;
    }
  }

  bool _isSessionCurrent(int expectedEpoch) {
    try {
      return _session.snapshot().sessionEpoch == expectedEpoch;
    } catch (error, stackTrace) {
      _log.warning('Unable to revalidate session during endpoint rollback', error, stackTrace);
      return false;
    }
  }

  void _ensureFresh(EndpointActivationRequest request, _CancellationSignal signal) {
    if (signal.cancelled) {
      throw const _StaleActivation(OfflineErrorCode.cancelled);
    }
    final error = _freshnessError(request, _session.snapshot());
    if (error != null) {
      throw _StaleActivation(error);
    }
  }

  OfflineErrorCode? _freshnessError(EndpointActivationRequest request, ActivationSessionSnapshot current) {
    if (current.userId != request.endpoint.userId) {
      return OfflineErrorCode.wrongServer;
    }
    if (current.sessionEpoch != request.sessionEpoch || current.probeGeneration != request.probeGeneration) {
      return OfflineErrorCode.cancelled;
    }
    return null;
  }
}

final class _EndpointActivationOperation implements CancellableRequest<OfflineResult<EndpointActivationReceipt>> {
  _EndpointActivationOperation(Future<OfflineResult<EndpointActivationReceipt>> Function(_CancellationSignal) start) {
    _result = Future.microtask(() => start(_signal));
  }

  late final Future<OfflineResult<EndpointActivationReceipt>> _result;
  final _CancellationSignal _signal = _CancellationSignal();

  @override
  Future<OfflineResult<EndpointActivationReceipt>> get result => _result;

  @override
  Future<void> cancel() async {
    _signal.cancelled = true;
  }
}

final class _CancellationSignal {
  bool cancelled = false;
}

final class _ActivationProgress {
  bool nativeContextAttempted = false;
  bool apiGraphAttempted = false;
  bool endpointStoreAttempted = false;
  bool widgetCredentialsAttempted = false;
  bool onlinePublicationAttempted = false;
}

final class _StaleActivation implements Exception {
  const _StaleActivation(this.code);

  final OfflineErrorCode code;
}

Future<void> _compensate(Future<void> Function() compensation) async {
  try {
    await compensation();
  } catch (error, stackTrace) {
    _log.warning('Endpoint activation compensation failed', error, stackTrace);
  }
}

Future<void> _noCheckpoint(EndpointActivationStep _) async {}

String? _serializeHeaders(Map<String, String> headers) {
  if (headers.isEmpty) {
    return null;
  }
  final entries = headers.entries.toList()..sort((left, right) => left.key.compareTo(right.key));
  return jsonEncode(Map.fromEntries(entries));
}
