import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/models/auth/auxilary_endpoint.model.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

import '../domain/service.mock.dart';
import '../repository.mocks.dart';
import '../service.mocks.dart';

void main() {
  late AuthService sut;
  late MockAuthApiRepository authApiRepository;
  late MockAuthRepository authRepository;
  late MockApiService apiService;
  late MockNetworkService networkService;
  late MockBackgroundSyncManager backgroundSyncManager;
  late MockAppSettingService appSettingsService;
  late Drift db;

  setUp(() async {
    authApiRepository = MockAuthApiRepository();
    authRepository = MockAuthRepository();
    apiService = MockApiService();
    networkService = MockNetworkService();
    backgroundSyncManager = MockBackgroundSyncManager();
    appSettingsService = MockAppSettingService();

    sut = AuthService(
      authApiRepository,
      authRepository,
      apiService,
      networkService,
      backgroundSyncManager,
      appSettingsService,
    );

    registerFallbackValue(Uri());
  });

  setUpAll(() async {
    WidgetsFlutterBinding.ensureInitialized();
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
  });

  tearDownAll(() async {
    await db.close();
  });

  group('remote authentication cleanup', () {
    test('forgetServer purges remote cache and every endpoint identity', () async {
      await Store.put(StoreKey.serverUrl, 'https://photos.example.test');
      await Store.put(StoreKey.serverEndpoint, 'https://photos.example.test/api');
      await Store.put(StoreKey.accessToken, 'token');
      await Store.put(StoreKey.customHeaders, '{"x-server-a-key":"secret"}');
      when(() => backgroundSyncManager.cancel()).thenAnswer((_) async {});
      when(() => authRepository.clearLocalData()).thenAnswer((_) async {});
      when(() => appSettingsService.setSetting(AppSettingsEnum.enableBackup, false)).thenAnswer((_) async {});

      await sut.forgetServer();

      expect(Store.tryGet(StoreKey.serverUrl), isNull);
      expect(Store.tryGet(StoreKey.serverEndpoint), isNull);
      expect(Store.tryGet(StoreKey.accessToken), isNull);
      expect(Store.tryGet(StoreKey.customHeaders), isNull);
      expect(Store.tryGet(StoreKey.currentUser), isNull);
      verify(() => backgroundSyncManager.cancel()).called(1);
      verify(() => authRepository.clearLocalData()).called(1);
      verify(() => appSettingsService.setSetting(AppSettingsEnum.enableBackup, false)).called(1);
    });

    test('clears the local token even when remote logout fails', () async {
      const endpoint = 'https://photos.example.test/api';
      await Store.put(StoreKey.serverEndpoint, endpoint);
      await Store.put(StoreKey.accessToken, 'expired-token');
      when(() => authApiRepository.logout()).thenThrow(Exception('Server error'));
      when(() => backgroundSyncManager.cancel()).thenAnswer((_) async {});
      when(() => authRepository.clearLocalData()).thenAnswer((_) async {});
      when(() => appSettingsService.setSetting(AppSettingsEnum.enableBackup, false)).thenAnswer((_) async {});

      await sut.invalidateRemoteSession();
      await sut.clearRemoteAuthentication();

      verify(() => authApiRepository.logout()).called(1);
      expect(Store.tryGet(StoreKey.serverEndpoint), endpoint);
      expect(Store.tryGet(StoreKey.accessToken), isNull);
      verifyNever(() => authRepository.clearLocalData());
    });
  });

  group('setOpenApiServiceEndpoint', () {
    setUp(() {
      when(() => networkService.getWifiName()).thenAnswer((_) async => 'TestWifi');
    });

    test('Should return null if auto endpoint switching is disabled', () async {
      when(() => authRepository.getEndpointSwitchingFeature()).thenReturn((false));

      final result = await sut.setOpenApiServiceEndpoint();

      expect(result, isNull);
      verify(() => authRepository.getEndpointSwitchingFeature()).called(1);
      verifyNever(() => networkService.getWifiName());
    });

    test('Should set local connection if wifi name matches', () async {
      when(() => authRepository.getEndpointSwitchingFeature()).thenReturn(true);
      when(() => authRepository.getPreferredWifiName()).thenReturn('TestWifi');
      when(() => authRepository.getLocalEndpoint()).thenReturn('http://local.endpoint');
      when(
        () => apiService.resolveAndSetEndpoint('http://local.endpoint'),
      ).thenAnswer((_) async => 'http://local.endpoint');

      final result = await sut.setOpenApiServiceEndpoint();

      expect(result, 'http://local.endpoint');
      verify(() => authRepository.getEndpointSwitchingFeature()).called(1);
      verify(() => networkService.getWifiName()).called(1);
      verify(() => authRepository.getPreferredWifiName()).called(1);
      verify(() => authRepository.getLocalEndpoint()).called(1);
      verify(() => apiService.resolveAndSetEndpoint('http://local.endpoint')).called(1);
    });

    test('Should set external endpoint if wifi name not matching', () async {
      when(() => authRepository.getEndpointSwitchingFeature()).thenReturn(true);
      when(() => authRepository.getPreferredWifiName()).thenReturn('DifferentWifi');
      when(
        () => authRepository.getExternalEndpointList(),
      ).thenReturn([const AuxilaryEndpoint(url: 'https://external.endpoint', status: AuxCheckStatus.valid)]);
      when(
        () => apiService.resolveAndSetEndpoint('https://external.endpoint'),
      ).thenAnswer((_) async => 'https://external.endpoint/api');

      final result = await sut.setOpenApiServiceEndpoint();

      expect(result, 'https://external.endpoint/api');
      verify(() => authRepository.getEndpointSwitchingFeature()).called(1);
      verify(() => networkService.getWifiName()).called(1);
      verify(() => authRepository.getPreferredWifiName()).called(1);
      verify(() => authRepository.getExternalEndpointList()).called(1);
      verify(() => apiService.resolveAndSetEndpoint('https://external.endpoint')).called(1);
    });

    test('Should set second external endpoint if the first throw any error', () async {
      when(() => authRepository.getEndpointSwitchingFeature()).thenReturn(true);
      when(() => authRepository.getPreferredWifiName()).thenReturn('DifferentWifi');
      when(() => authRepository.getExternalEndpointList()).thenReturn([
        const AuxilaryEndpoint(url: 'https://external.endpoint', status: AuxCheckStatus.valid),
        const AuxilaryEndpoint(url: 'https://external.endpoint2', status: AuxCheckStatus.valid),
      ]);

      when(
        () => apiService.resolveAndSetEndpoint('https://external.endpoint'),
      ).thenThrow(Exception('Invalid endpoint'));
      when(
        () => apiService.resolveAndSetEndpoint('https://external.endpoint2'),
      ).thenAnswer((_) async => 'https://external.endpoint2/api');

      final result = await sut.setOpenApiServiceEndpoint();

      expect(result, 'https://external.endpoint2/api');
      verify(() => authRepository.getEndpointSwitchingFeature()).called(1);
      verify(() => networkService.getWifiName()).called(1);
      verify(() => authRepository.getPreferredWifiName()).called(1);
      verify(() => authRepository.getExternalEndpointList()).called(1);
      verify(() => apiService.resolveAndSetEndpoint('https://external.endpoint2')).called(1);
    });

    test('Should set second external endpoint if the first throw ApiException', () async {
      when(() => authRepository.getEndpointSwitchingFeature()).thenReturn(true);
      when(() => authRepository.getPreferredWifiName()).thenReturn('DifferentWifi');
      when(() => authRepository.getExternalEndpointList()).thenReturn([
        const AuxilaryEndpoint(url: 'https://external.endpoint', status: AuxCheckStatus.valid),
        const AuxilaryEndpoint(url: 'https://external.endpoint2', status: AuxCheckStatus.valid),
      ]);

      when(
        () => apiService.resolveAndSetEndpoint('https://external.endpoint'),
      ).thenThrow(ApiException(503, 'Invalid endpoint'));
      when(
        () => apiService.resolveAndSetEndpoint('https://external.endpoint2'),
      ).thenAnswer((_) async => 'https://external.endpoint2/api');

      final result = await sut.setOpenApiServiceEndpoint();

      expect(result, 'https://external.endpoint2/api');
      verify(() => authRepository.getEndpointSwitchingFeature()).called(1);
      verify(() => networkService.getWifiName()).called(1);
      verify(() => authRepository.getPreferredWifiName()).called(1);
      verify(() => authRepository.getExternalEndpointList()).called(1);
      verify(() => apiService.resolveAndSetEndpoint('https://external.endpoint2')).called(1);
    });

    test('Should handle error when setting local connection', () async {
      when(() => authRepository.getEndpointSwitchingFeature()).thenReturn(true);
      when(() => authRepository.getPreferredWifiName()).thenReturn('TestWifi');
      when(() => authRepository.getLocalEndpoint()).thenReturn('http://local.endpoint');
      when(
        () => apiService.resolveAndSetEndpoint('http://local.endpoint'),
      ).thenThrow(Exception('Local endpoint error'));

      final result = await sut.setOpenApiServiceEndpoint();

      expect(result, isNull);
      verify(() => authRepository.getEndpointSwitchingFeature()).called(1);
      verify(() => networkService.getWifiName()).called(1);
      verify(() => authRepository.getPreferredWifiName()).called(1);
      verify(() => authRepository.getLocalEndpoint()).called(1);
      verify(() => apiService.resolveAndSetEndpoint('http://local.endpoint')).called(1);
    });

    test('Should handle error when setting external connection', () async {
      when(() => authRepository.getEndpointSwitchingFeature()).thenReturn(true);
      when(() => authRepository.getPreferredWifiName()).thenReturn('DifferentWifi');
      when(
        () => authRepository.getExternalEndpointList(),
      ).thenReturn([const AuxilaryEndpoint(url: 'https://external.endpoint', status: AuxCheckStatus.valid)]);
      when(
        () => apiService.resolveAndSetEndpoint('https://external.endpoint'),
      ).thenThrow(Exception('External endpoint error'));

      final result = await sut.setOpenApiServiceEndpoint();

      expect(result, isNull);
      verify(() => authRepository.getEndpointSwitchingFeature()).called(1);
      verify(() => networkService.getWifiName()).called(1);
      verify(() => authRepository.getPreferredWifiName()).called(1);
      verify(() => authRepository.getExternalEndpointList()).called(1);
      verify(() => apiService.resolveAndSetEndpoint('https://external.endpoint')).called(1);
    });
  });
}
