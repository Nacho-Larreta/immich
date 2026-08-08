import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/repositories/widget.repository.dart';

final widgetServiceProvider = Provider((ref) {
  return WidgetService(ref.watch(widgetRepositoryProvider));
});

class WidgetService {
  final WidgetRepository _repository;
  final _credentialQueue = _WidgetCredentialQueue();

  WidgetService(this._repository);

  Future<void> _writeCredentials(String serverURL, String sessionKey, String? customHeaders) async {
    await _repository.setAppGroupId(appShareGroupId);
    await _repository.saveData(kWidgetServerEndpoint, serverURL);
    await _repository.saveData(kWidgetAuthToken, sessionKey);
    await _repository.saveData(kWidgetCustomHeaders, customHeaders ?? "");
  }

  Future<void> writeCredentialsAndRefresh(String serverURL, String sessionKey, String? customHeaders) async {
    await _credentialQueue.protect(() async {
      await _writeCredentials(serverURL, sessionKey, customHeaders);
      await _refreshWidgets();
    });
  }

  Future<({String? serverURL, String? sessionKey, String? customHeaders})> readCredentials() =>
      _credentialQueue.protect(_readCredentials);

  Future<({String? serverURL, String? sessionKey, String? customHeaders})> _readCredentials() async {
    await _repository.setAppGroupId(appShareGroupId);
    return (
      serverURL: await _repository.readData(kWidgetServerEndpoint),
      sessionKey: await _repository.readData(kWidgetAuthToken),
      customHeaders: await _repository.readData(kWidgetCustomHeaders),
    );
  }

  Future<void> _clearCredentials() async {
    await _repository.setAppGroupId(appShareGroupId);
    await _repository.saveData(kWidgetServerEndpoint, "");
    await _repository.saveData(kWidgetAuthToken, "");
    await _repository.saveData(kWidgetCustomHeaders, "");
  }

  Future<void> clearCredentialsAndRefresh() async {
    await _credentialQueue.protect(() async {
      await _clearCredentials();
      await _refreshWidgets();
    });
  }

  Future<void> _refreshWidgets() async {
    for (final (iOSName, androidName) in kWidgetNames) {
      await _repository.refresh(iOSName, androidName);
    }
  }
}

final class _WidgetCredentialQueue {
  Future<void> _tail = Future.value();

  Future<T> protect<T>(Future<T> Function() operation) {
    final predecessor = _tail;
    final completion = Completer<void>();
    _tail = completion.future;
    return predecessor.then((_) => operation()).whenComplete(completion.complete);
  }
}
