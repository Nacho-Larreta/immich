import 'dart:async';

import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';

/// Provides access to a persistent key-value store with an in-memory cache.
/// Listens for repository changes to keep the cache updated.
class StoreService {
  final DriftStoreRepository _storeRepository;

  /// In-memory cache. Keys are [StoreKey.id]
  final Map<int, Object?> _cache = {};
  final Map<int, Object?> _committedWrites = {};
  final Set<int> _deletedKeys = {};
  StreamSubscription<List<StoreDto>>? _storeUpdateSubscription;

  StoreService._({required DriftStoreRepository isarStoreRepository}) : _storeRepository = isarStoreRepository;

  // TODO: Temporary typedef to make minimal changes. Remove this and make the presentation layer access store through a provider
  static StoreService? _instance;
  static StoreService get I {
    if (_instance == null) {
      throw UnsupportedError("StoreService not initialized. Call init() first");
    }
    return _instance!;
  }

  // TODO: Replace the implementation with the one from create after removing the typedef
  static Future<StoreService> init({required DriftStoreRepository storeRepository, bool listenUpdates = true}) async {
    _instance ??= await create(storeRepository: storeRepository, listenUpdates: listenUpdates);
    return _instance!;
  }

  static Future<StoreService> create({required DriftStoreRepository storeRepository, bool listenUpdates = true}) async {
    final instance = StoreService._(isarStoreRepository: storeRepository);
    await instance.populateCache();
    if (listenUpdates) {
      instance._storeUpdateSubscription = instance._listenForChange();
    }
    return instance;
  }

  Future<void> populateCache() async {
    final storeValues = await _storeRepository.getAll();
    for (StoreDto storeValue in storeValues) {
      _cache[storeValue.key.id] = storeValue.value;
    }
  }

  StreamSubscription<List<StoreDto>> _listenForChange() => _storeRepository.watchAll().listen((snapshot) {
    final snapshotValues = Map<int, Object?>.fromEntries(
      snapshot
          .where((entry) => !_deletedKeys.contains(entry.key.id))
          .map((entry) => MapEntry(entry.key.id, entry.value)),
    );
    for (final committedWrite in _committedWrites.entries.toList()) {
      if (snapshotValues.containsKey(committedWrite.key) &&
          snapshotValues[committedWrite.key] == committedWrite.value) {
        _committedWrites.remove(committedWrite.key);
      } else {
        snapshotValues[committedWrite.key] = committedWrite.value;
      }
    }
    _cache
      ..clear()
      ..addAll(snapshotValues);
  });

  /// Disposes the store and cancels the subscription. To reuse the store call init() again
  Future<void> dispose() async {
    await _storeUpdateSubscription?.cancel();
    _cache.clear();
    _committedWrites.clear();
    _deletedKeys.clear();
  }

  /// Returns the cached value for [key], or `null`
  T? tryGet<T>(StoreKey<T> key) => _cache[key.id] as T?;

  /// Returns the stored value for [key] or [defaultValue].
  /// Throws [StoreKeyNotFoundException] if value and [defaultValue] are null.
  T get<T>(StoreKey<T> key, [T? defaultValue]) {
    final value = tryGet(key) ?? defaultValue;
    if (value == null) {
      throw StoreKeyNotFoundException(key);
    }
    return value;
  }

  /// Stores the [value] for the [key]. Skips write if value hasn't changed.
  Future<void> put<U extends StoreKey<T>, T>(U key, T value) async {
    if (_cache[key.id] == value) return;
    await _storeRepository.upsert(key, value);
    _deletedKeys.remove(key.id);
    _committedWrites[key.id] = value;
    _cache[key.id] = value;
  }

  /// Returns a stream that emits the value for [key] on change.
  Stream<T?> watch<T>(StoreKey<T> key) => _storeRepository.watch(key);

  /// Removes the value for [key]
  Future<void> delete<T>(StoreKey<T> key) async {
    final hadCachedValue = _cache.containsKey(key.id);
    final cachedValue = _cache[key.id];
    final hadCommittedWrite = _committedWrites.containsKey(key.id);
    final committedValue = _committedWrites[key.id];
    _deletedKeys.add(key.id);
    _committedWrites.remove(key.id);
    try {
      await _storeRepository.delete(key);
      _cache.remove(key.id);
    } catch (_) {
      _deletedKeys.remove(key.id);
      if (hadCachedValue) {
        _cache[key.id] = cachedValue;
      }
      if (hadCommittedWrite) {
        _committedWrites[key.id] = committedValue;
      }
      rethrow;
    }
  }

  /// Clears all values from the store (cache and DB)
  Future<void> clear() async {
    await _storeRepository.deleteAll();
    _cache.clear();
    _committedWrites.clear();
    _deletedKeys.addAll(StoreKey.values.map((key) => key.id));
  }
}

class StoreKeyNotFoundException implements Exception {
  final StoreKey key;
  const StoreKeyNotFoundException(this.key);

  @override
  String toString() => "Key - <${key.name}> not available in Store";
}
