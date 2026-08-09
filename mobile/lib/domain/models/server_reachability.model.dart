import 'package:immich_mobile/domain/models/network_uri.model.dart';

enum ReachabilityPhase { unknown, probing, offline, online, paused, disposed }

enum TransportAvailability { unknown, unavailable, available }

const _confirmedEndpointUnchanged = Object();

final class ReachabilityState {
  ReachabilityState({
    required this.phase,
    required this.sessionEpoch,
    required this.probeGeneration,
    this.confirmedEndpoint,
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
  final int probeGeneration;

  ReachabilityState copyWith({
    ReachabilityPhase? phase,
    int? sessionEpoch,
    Object? confirmedEndpoint = _confirmedEndpointUnchanged,
    int? probeGeneration,
  }) {
    final nextEndpoint = switch (confirmedEndpoint) {
      final Uri endpoint => endpoint,
      null => null,
      _ when identical(confirmedEndpoint, _confirmedEndpointUnchanged) => this.confirmedEndpoint,
      _ => throw ArgumentError.value(confirmedEndpoint, 'confirmedEndpoint', 'Must be a Uri or null'),
    };
    return ReachabilityState(
      phase: phase ?? this.phase,
      sessionEpoch: sessionEpoch ?? this.sessionEpoch,
      confirmedEndpoint: nextEndpoint,
      probeGeneration: probeGeneration ?? this.probeGeneration,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ReachabilityState &&
        other.phase == phase &&
        other.sessionEpoch == sessionEpoch &&
        other.confirmedEndpoint == confirmedEndpoint &&
        other.probeGeneration == probeGeneration;
  }

  @override
  int get hashCode => Object.hash(phase, sessionEpoch, confirmedEndpoint, probeGeneration);
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
