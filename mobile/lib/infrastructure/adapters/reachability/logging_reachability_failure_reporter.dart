import 'package:immich_mobile/domain/interfaces/reachability_failure_reporter.interface.dart';
import 'package:logging/logging.dart';

final class LoggingReachabilityFailureReporter implements ReachabilityFailureReporterPort {
  LoggingReachabilityFailureReporter(Logger logger) : _logger = logger;

  final Logger _logger;

  @override
  void report(ReachabilityFailure failure) {
    _logger.warning(
      'reachability_failure stage=${failure.stage.name} reason=${failure.reason.name} '
      'code=${failure.code.name} offline=${failure.offlineCode?.name ?? 'none'} '
      'session=${failure.identity.sessionEpoch} probe=${failure.identity.probeGeneration} '
      'cause_type=${failure.causeType ?? 'none'} cause_message=${failure.causeMessage ?? 'none'}',
      failure.causeType == null ? null : {'type': failure.causeType, 'message': failure.causeMessage},
      failure.stackTrace,
    );
  }
}
