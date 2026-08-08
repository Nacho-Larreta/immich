import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/repositories/widget.repository.dart';
import 'package:immich_mobile/services/widget.service.dart';

void main() {
  test('credential replacement clears stale custom headers before refreshing widgets', () async {
    final repository = _RecordingWidgetRepository()..values[kWidgetCustomHeaders] = '{"Stale":"header"}';
    final service = WidgetService(repository);

    await service.writeCredentialsAndRefresh('https://photos.test/family/api', 'token', null);

    expect(repository.values[kWidgetServerEndpoint], 'https://photos.test/family/api');
    expect(repository.values[kWidgetAuthToken], 'token');
    expect(repository.values[kWidgetCustomHeaders], '');
    expect(repository.refreshes, kWidgetNames);
  });

  test('explicit credential workflow persists before refreshing every widget', () async {
    final repository = _RecordingWidgetRepository();
    final service = WidgetService(repository);

    await service.writeCredentialsAndRefresh('https://photos.test/api', 'token', '{}');

    expect(repository.refreshes, kWidgetNames);
    expect(repository.events.indexOf('save:$kWidgetCustomHeaders'), lessThan(repository.events.indexOf('refresh')));
  });

  test('explicit clear workflow clears credentials before refreshing every widget', () async {
    final repository = _RecordingWidgetRepository();
    final service = WidgetService(repository);

    await service.clearCredentialsAndRefresh();

    expect(repository.values[kWidgetServerEndpoint], '');
    expect(repository.values[kWidgetAuthToken], '');
    expect(repository.values[kWidgetCustomHeaders], '');
    expect(repository.refreshes, kWidgetNames);
    expect(repository.events.indexOf('save:$kWidgetCustomHeaders'), lessThan(repository.events.indexOf('refresh')));
  });

  test('timed-out clear remains queued before a newer credential write', () async {
    final clearGate = Completer<void>();
    final repository = _RecordingWidgetRepository()..clearGate = clearGate;
    final service = WidgetService(repository);

    final clear = service.clearCredentialsAndRefresh();
    await repository.clearStarted.future;
    await expectLater(clear.timeout(const Duration(milliseconds: 5)), throwsA(isA<TimeoutException>()));

    var writeCompleted = false;
    final write = service
        .writeCredentialsAndRefresh('https://new.test/api', 'new-token', '{"X-New":"value"}')
        .whenComplete(() => writeCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(writeCompleted, isFalse);

    clearGate.complete();
    await write;

    expect(repository.values[kWidgetServerEndpoint], 'https://new.test/api');
    expect(repository.values[kWidgetAuthToken], 'new-token');
    expect(repository.values[kWidgetCustomHeaders], '{"X-New":"value"}');
    expect(writeCompleted, isTrue);
  });

  test('read waits for an in-flight write and returns one complete credential snapshot', () async {
    final writeGate = Completer<void>();
    final repository = _RecordingWidgetRepository()
      ..values[kWidgetServerEndpoint] = 'https://old.test/api'
      ..values[kWidgetAuthToken] = 'old-token'
      ..values[kWidgetCustomHeaders] = '{"Old":"header"}'
      ..gatedSaveKey = kWidgetAuthToken
      ..gatedSaveGate = writeGate;
    final service = WidgetService(repository);

    final write = service.writeCredentialsAndRefresh('https://new.test/api', 'new-token', '{"New":"header"}');
    await repository.gatedSaveStarted.future;

    var readCompleted = false;
    final read = service.readCredentials().whenComplete(() => readCompleted = true);
    await Future<void>.delayed(Duration.zero);

    expect(readCompleted, isFalse);
    writeGate.complete();
    await write;

    expect(await read, (serverURL: 'https://new.test/api', sessionKey: 'new-token', customHeaders: '{"New":"header"}'));
  });
}

final class _RecordingWidgetRepository implements WidgetRepository {
  final values = <String, String>{};
  final refreshes = <(String, String)>[];
  final events = <String>[];
  Completer<void>? clearGate;
  final clearStarted = Completer<void>();
  String? gatedSaveKey;
  Completer<void>? gatedSaveGate;
  final gatedSaveStarted = Completer<void>();

  @override
  Future<String?> readData(String key) async => values[key];

  @override
  Future<void> refresh(String iosName, String androidName) async {
    refreshes.add((iosName, androidName));
    events.add('refresh');
  }

  @override
  Future<void> saveData(String key, String value) async {
    if (key == gatedSaveKey && gatedSaveGate != null) {
      if (!gatedSaveStarted.isCompleted) gatedSaveStarted.complete();
      await gatedSaveGate!.future;
    }
    if (key == kWidgetServerEndpoint && value.isEmpty && clearGate != null) {
      if (!clearStarted.isCompleted) clearStarted.complete();
      await clearGate!.future;
    }
    values[key] = value;
    events.add('save:$key');
  }

  @override
  Future<void> setAppGroupId(String appGroupId) async {}
}
