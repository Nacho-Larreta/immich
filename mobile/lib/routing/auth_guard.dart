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
  final AuthGuardSessionInvalidator _sessionInvalidator;
  final _log = Logger("AuthGuard");
  AuthGuard(this._apiService, Future<void> Function() invalidateSession)
    : _sessionInvalidator = AuthGuardSessionInvalidator(invalidateSession);
  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) async {
    resolver.next(true);

    try {
      // Look in the store for an access token
      Store.get(StoreKey.accessToken);

      // Validate the access token with the server
      final res = await _apiService.authenticationApi.validateAccessToken();
      if (res == null || res.authStatus != true) {
        // If the access token is invalid, take user back to login
        _log.fine('User token is invalid. Redirecting to login');
        unawaited(_redirectToLoginAndInvalidate(router));
      }
    } on StoreKeyNotFoundException catch (_) {
      // If there is no access token, take us to the login page
      _log.warning('No access token in the store.');
      unawaited(_redirectToLoginAndInvalidate(router));
      return;
    } on ApiException catch (e) {
      // On an unauthorized request, take us to the login page
      if (e.code == HttpStatus.unauthorized) {
        _log.warning("Unauthorized access token.");
        unawaited(_redirectToLoginAndInvalidate(router));
        return;
      }
    } catch (e) {
      // Otherwise, this is not fatal, but we still log the warning
      _log.warning('Error validating access token from server: $e');
    }
  }

  Future<void> _redirectToLoginAndInvalidate(StackRouter router) async {
    await _sessionInvalidator.redirect(() => router.replaceAll([const LoginRoute()]));
  }
}

final class AuthGuardSessionInvalidator {
  const AuthGuardSessionInvalidator(this._invalidateSession);

  final Future<void> Function() _invalidateSession;

  Future<void> redirect(Future<void> Function() navigateToLogin) async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await Future.wait([attempt(navigateToLogin), attempt(_invalidateSession)]);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }
}
