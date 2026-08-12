import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/photo_manager_change_observer_adapter.dart';

void main() {
  test('registers before start, forwards changes, then removes before stop exactly once', () async {
    final source = _Source();
    var changes = 0;
    final observer = PhotoManagerChangeObserverAdapter(onChanged: () => changes++, source: source);

    final firstStart = observer.start();
    final secondStart = observer.start();
    expect(identical(firstStart, secondStart), isTrue);
    await firstStart;
    source.emit();

    final firstDispose = observer.dispose();
    final secondDispose = observer.dispose();
    expect(identical(firstDispose, secondDispose), isTrue);
    await firstDispose;
    source.emit();

    expect(source.operations, ['add', 'start', 'remove', 'stop']);
    expect(changes, 1);
  });

  test('start failure unregisters callback without calling stop', () async {
    final source = _Source(startFailure: StateError('unavailable'));
    final observer = PhotoManagerChangeObserverAdapter(onChanged: () {}, source: source);

    await expectLater(observer.start(), throwsStateError);
    await observer.dispose();

    expect(source.operations, ['add', 'start', 'remove']);
  });
}

final class _Source implements PhotoManagerChangeSource {
  _Source({this.startFailure});

  final Object? startFailure;
  final List<String> operations = [];
  void Function(MethodCall event)? callback;

  @override
  void add(void Function(MethodCall event) callback) {
    operations.add('add');
    this.callback = callback;
  }

  @override
  void remove(void Function(MethodCall event) callback) {
    operations.add('remove');
    if (identical(this.callback, callback)) this.callback = null;
  }

  @override
  Future<void> start() async {
    operations.add('start');
    final failure = startFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> stop() async {
    operations.add('stop');
  }

  void emit() => callback?.call(const MethodCall('changed'));
}
