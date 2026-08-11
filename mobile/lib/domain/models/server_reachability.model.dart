import 'package:immich_mobile/domain/models/network_uri.model.dart';
import 'package:immich_mobile/domain/models/confirmed_server_access.model.dart';

enum ReachabilityPhase { unknown, probing, offline, online, paused, disposed }

enum TransportAvailability { unknown, unavailable, available }

const _confirmedEndpointUnchanged = Object();
const _serverAccessUnchanged = Object();

final class ReachabilityState {
  ReachabilityState({
    required this.phase,
    required this.sessionEpoch,
    required this.probeGeneration,
    this.confirmedEndpoint,
    this.serverAccess,
  }) {
    _validateGeneration(sessionEpoch, 'sessionEpoch');
    _validateGeneration(probeGeneration, 'probeGeneration');
    final endpoint = confirmedEndpoint;
    if (phase == ReachabilityPhase.online && endpoint == null) {
      throw ArgumentError('confirmedEndpoint is required while online');
    }
    if (endpoint != null) {
      validateHttpEndpoint(endpoint, 'confirmedEndpoint');
    }
  }

  final ReachabilityPhase phase;
  final int sessionEpoch;
  final Uri? confirmedEndpoint;
  final ConfirmedServerAccess? serverAccess;
  final int probeGeneration;

  ReachabilityState copyWith({
    ReachabilityPhase? phase,
    int? sessionEpoch,
    Object? confirmedEndpoint = _confirmedEndpointUnchanged,
    Object? serverAccess = _serverAccessUnchanged,
    int? probeGeneration,
  }) {
    final nextEndpoint = switch (confirmedEndpoint) {
      final Uri endpoint => endpoint,
      null => null,
      _ when identical(confirmedEndpoint, _confirmedEndpointUnchanged) => this.confirmedEndpoint,
      _ => throw ArgumentError.value(confirmedEndpoint, 'confirmedEndpoint', 'Must be a Uri or null'),
    };
    final nextServerAccess = switch (serverAccess) {
      final ConfirmedServerAccess access => access,
      null => null,
      _ when identical(serverAccess, _serverAccessUnchanged) => this.serverAccess,
      _ => throw ArgumentError.value(serverAccess, 'serverAccess', 'Must be a ConfirmedServerAccess or null'),
    };
    return ReachabilityState(
      phase: phase ?? this.phase,
      sessionEpoch: sessionEpoch ?? this.sessionEpoch,
      confirmedEndpoint: nextEndpoint,
      serverAccess: nextServerAccess,
      probeGeneration: probeGeneration ?? this.probeGeneration,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ReachabilityState &&
        other.phase == phase &&
        other.sessionEpoch == sessionEpoch &&
        other.confirmedEndpoint == confirmedEndpoint &&
        other.serverAccess == serverAccess &&
        other.probeGeneration == probeGeneration;
  }

  @override
  int get hashCode => Object.hash(phase, sessionEpoch, confirmedEndpoint, serverAccess, probeGeneration);
}

final class ReachabilityIdentity {
  ReachabilityIdentity({required this.sessionEpoch, required this.probeGeneration}) {
    _validateGeneration(sessionEpoch, 'sessionEpoch');
    _validateGeneration(probeGeneration, 'probeGeneration');
  }

  final int sessionEpoch;
  final int probeGeneration;

  @override
  bool operator ==(Object other) {
    return other is ReachabilityIdentity &&
        other.sessionEpoch == sessionEpoch &&
        other.probeGeneration == probeGeneration;
  }

  @override
  int get hashCode => Object.hash(sessionEpoch, probeGeneration);
}

final class ReconciliationRequest {
  ReconciliationRequest({required this.sessionEpoch, required this.probeGeneration, required this.confirmedEndpoint}) {
    _validateGeneration(sessionEpoch, 'sessionEpoch');
    _validateGeneration(probeGeneration, 'probeGeneration');
    validateHttpEndpoint(confirmedEndpoint, 'confirmedEndpoint');
  }

  final int sessionEpoch;
  final int probeGeneration;
  final Uri confirmedEndpoint;
}

void _validateGeneration(int value, String argumentName) {
  if (value < 0) {
    throw ArgumentError.value(value, argumentName, 'Must not be negative');
  }
}
