import 'dart:async';

import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

typedef PhotoLibraryChangeCallback = void Function();

abstract interface class PhotoManagerChangeSource {
  void add(void Function(MethodCall event) callback);

  void remove(void Function(MethodCall event) callback);

  Future<void> start();

  Future<void> stop();
}

final class PhotoManagerChangeObserverAdapter {
  PhotoManagerChangeObserverAdapter({required PhotoLibraryChangeCallback onChanged, PhotoManagerChangeSource? source})
    : _onChanged = onChanged,
      _source = source ?? const _DefaultPhotoManagerChangeSource();

  final PhotoLibraryChangeCallback _onChanged;
  final PhotoManagerChangeSource _source;
  Future<void>? _startFuture;
  Future<void>? _disposeFuture;
  bool _registered = false;
  bool _disposed = false;

  Future<void> start() {
    if (_disposed) return Future.value();
    return _startFuture ??= _start();
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _start() async {
    _source.add(_handleChange);
    _registered = true;
    try {
      await _source.start();
    } on Object {
      _source.remove(_handleChange);
      _registered = false;
      rethrow;
    }
  }

  Future<void> _dispose() async {
    _disposed = true;
    final starting = _startFuture;
    if (starting != null) {
      try {
        await starting;
      } on Object {
        return;
      }
    }
    if (!_registered) return;
    _source.remove(_handleChange);
    _registered = false;
    await _source.stop();
  }

  void _handleChange(MethodCall event) {
    if (!_disposed) _onChanged();
  }
}

final class _DefaultPhotoManagerChangeSource implements PhotoManagerChangeSource {
  const _DefaultPhotoManagerChangeSource();

  @override
  void add(void Function(MethodCall event) callback) => PhotoManager.addChangeCallback(callback);

  @override
  void remove(void Function(MethodCall event) callback) => PhotoManager.removeChangeCallback(callback);

  @override
  Future<void> start() => PhotoManager.startChangeNotify();

  @override
  Future<void> stop() => PhotoManager.stopChangeNotify();
}
