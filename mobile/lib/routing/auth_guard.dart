import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';

class AuthGuard extends AutoRouteGuard {
  final ApiService _apiService;
  final AuthGuardReauthenticationCoordinator _reauthenticationCoordinator;
  final String Function() _readAccessToken;
  final bool Function() _readAuthenticatedSessionReady;
  final Future<void> Function(StackRouter) _presentAuthentication;
  final _log = Logger("AuthGuard");
  AuthGuard(
    this._apiService,
    Future<void> Function() requireReauthentication, {
    String Function()? readAccessToken,
    bool Function()? readAuthenticatedSessionReady,
    Future<void> Function(StackRouter)? presentAuthentication,
  }) : _reauthenticationCoordinator = AuthGuardReauthenticationCoordinator(requireReauthentication),
       _readAccessToken = readAccessToken ?? _readStoredAccessToken,
       _readAuthenticatedSessionReady = readAuthenticatedSessionReady ?? _readStoredSessionReadiness,
       _presentAuthentication = presentAuthentication ?? _pushLogin;

  static String _readStoredAccessToken() => Store.get(StoreKey.accessToken);

  static bool _readStoredSessionReadiness() => Store.tryGet(StoreKey.authenticatedSessionReady) == true;

  static Future<void> _pushLogin(StackRouter router) => router.push(const LoginRoute());

  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) async {
    if (!_hasCommittedCredentials()) {
      resolver.next(false);
      _log.warning('Remote route rejected because the authenticated session was not committed.');
      unawaited(_presentAuthenticationAndInvalidate(router));
      return;
    }

    try {
      final res = await _apiService.authenticationApi.validateAccessToken();
      if (res == null || res.authStatus != true) {
        resolver.next(false);
        _log.fine('User token is invalid. Requesting authentication');
        unawaited(_presentAuthenticationAndInvalidate(router));
        return;
      }
      resolver.next(true);
    } on StoreKeyNotFoundException catch (_) {
      resolver.next(false);
      _log.warning('No access token in the store.');
      unawaited(_presentAuthenticationAndInvalidate(router));
    } on ApiException catch (e) {
      if (e.code == HttpStatus.unauthorized) {
        resolver.next(false);
        _log.warning("Unauthorized access token.");
        unawaited(_presentAuthenticationAndInvalidate(router));
        return;
      }
      resolver.next(true);
    } catch (e) {
      _log.warning('Error validating access token from server: $e');
      resolver.next(true);
    }
  }

  bool _hasCommittedCredentials() {
    try {
      return _readAccessToken().isNotEmpty && _readAuthenticatedSessionReady();
    } on StoreKeyNotFoundException {
      return false;
    } catch (error) {
      _log.warning('Could not read the local authenticated-session commit: $error');
      return false;
    }
  }

  Future<void> _presentAuthenticationAndInvalidate(StackRouter router) async {
    await _reauthenticationCoordinator.present(() => _presentAuthentication(router));
  }
}

final class AuthGuardReauthenticationCoordinator {
  AuthGuardReauthenticationCoordinator(this._requireReauthentication);

  final Future<void> Function() _requireReauthentication;
  Future<void>? _inFlight;

  Future<void> present(Future<void> Function() presentAuthentication) {
    return _inFlight ??= _coordinate(presentAuthentication).whenComplete(() => _inFlight = null);
  }

  Future<void> _coordinate(Future<void> Function() presentAuthentication) async {
    await _requireReauthentication();
    await presentAuthentication();
  }
}
