import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';

enum ReachabilityFailureStage { connectivity, probe, activation, reconciliation }

enum ReachabilityFailureReason { exception, rejected, staleProof }

enum ReachabilityFailureCode {
  connectivityException,
  transportReviewCancellationException,
  probeException,
  probeRejected,
  activationException,
  activationRejected,
  staleActivationProof,
  reconciliationException,
  reconciliationRejected,
}

final class ReachabilityFailure {
  const ReachabilityFailure({
    required this.stage,
    required this.reason,
    required this.code,
    required this.identity,
    this.offlineCode,
    this.causeType,
    this.causeMessage,
    this.stackTrace,
  });

  final ReachabilityFailureStage stage;
  final ReachabilityFailureReason reason;
  final ReachabilityFailureCode code;
  final ReachabilityIdentity identity;
  final OfflineErrorCode? offlineCode;
  final String? causeType;
  final String? causeMessage;
  final StackTrace? stackTrace;
}

String sanitizeReachabilityFailureMessage(Object cause) {
  final normalized = cause.toString().replaceAll(RegExp(r'[\r\n\t]+'), ' ');
  final withoutUrls = normalized.replaceAll(RegExp(r'https?://[^\s;,]+', caseSensitive: false), '[redacted-url]');
  final namedCredentialBoundary =
      r'(?=\s+(?:proxy-authorization|authorization|set-cookie|cookie|token|password|secret|api[_-]?key)\s*[:=]|$)';
  final withoutAuthorization = withoutUrls.replaceAllMapped(
    RegExp(r'\b(proxy-authorization|authorization)\s*[:=]\s*.*?' + namedCredentialBoundary, caseSensitive: false),
    (match) => '${match.group(1)!.toLowerCase()}=[redacted]',
  );
  final withoutCookies = withoutAuthorization.replaceAllMapped(
    RegExp(r'\b(set-cookie|cookie)\s*[:=]\s*.*?' + namedCredentialBoundary, caseSensitive: false),
    (match) => '${match.group(1)!.toLowerCase()}=[redacted]',
  );
  final withoutNamedSecrets = withoutCookies.replaceAllMapped(
    RegExp(r'\b(token|password|secret|api[_-]?key)\s*[:=]\s*[^\s,;]+', caseSensitive: false),
    (match) => '${match.group(1)!.toLowerCase()}=[redacted]',
  );
  final withoutBareSchemes = withoutNamedSecrets.replaceAll(
    RegExp(r'\b(?:bearer|basic)\s+[^\s,;]+', caseSensitive: false),
    '[redacted-auth]',
  );
  final singleLine = withoutBareSchemes
      .replaceAll(RegExp(r'\s*[;,]\s*'), ' ')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
  return singleLine.length <= 240 ? singleLine : '${singleLine.substring(0, 237)}...';
}

abstract interface class ReachabilityFailureReporterPort {
  void report(ReachabilityFailure failure);
}
