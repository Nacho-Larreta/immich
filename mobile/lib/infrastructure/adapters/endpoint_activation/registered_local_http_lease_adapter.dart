import 'dart:async';

import 'package:immich_mobile/domain/interfaces/request_context_lease.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:logging/logging.dart';

typedef ActiveEndpointPolicyReader = EndpointSchemePolicy? Function();

final _log = Logger('RegisteredLocalHttpLeaseAdapter');

final class RegisteredLocalHttpLeaseAdapter implements RequestContextLeasePort {
  RegisteredLocalHttpLeaseAdapter({
    required ActiveEndpointPolicyReader readActivePolicy,
    required void Function() blockRequests,
    required Future<void> Function() purgeRequestContext,
  }) : _readActivePolicy = readActivePolicy,
       _blockRequests = blockRequests,
       _purgeRequestContext = purgeRequestContext;

  final ActiveEndpointPolicyReader _readActivePolicy;
  final void Function() _blockRequests;
  final Future<void> Function() _purgeRequestContext;
  int _transportRevision = 0;
  RequestContextActivationLease? _pendingActivation;

  @override
  RequestContextActivationLease? beginActivation(EndpointSchemePolicy policy) {
    if (policy != EndpointSchemePolicy.registeredLocalHttp) {
      return null;
    }
    if (_pendingActivation != null) {
      throw StateError('A registered local HTTP activation is already pending');
    }
    return _pendingActivation = RequestContextActivationLease(_transportRevision);
  }

  @override
  bool commitActivation(RequestContextActivationLease lease) {
    if (!identical(_pendingActivation, lease)) {
      return false;
    }
    _pendingActivation = null;
    return lease.transportRevision == _transportRevision;
  }

  @override
  bool isCurrent(RequestContextActivationLease lease) => lease.transportRevision == _transportRevision;

  @override
  void abandonActivation(RequestContextActivationLease lease) {
    if (identical(_pendingActivation, lease)) {
      _pendingActivation = null;
    }
  }

  @override
  bool invalidateForTransportReview() {
    _transportRevision++;
    return _invalidateIfLocal();
  }

  @override
  void invalidateAfterValidationFailure() {
    _transportRevision++;
    _invalidateIfLocal();
  }

  bool _invalidateIfLocal() {
    if (_pendingActivation == null && _readActivePolicy() != EndpointSchemePolicy.registeredLocalHttp) {
      return false;
    }
    _blockRequests();
    unawaited(
      _purgeRequestContext().catchError((Object error, StackTrace stackTrace) {
        _log.warning('Unable to purge an invalidated registered local HTTP lease', error, stackTrace);
      }),
    );
    return true;
  }
}
