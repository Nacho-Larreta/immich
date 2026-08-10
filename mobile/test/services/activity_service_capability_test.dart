import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/remote_mutation_guard.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/models/activities/activity.model.dart';
import 'package:immich_mobile/repositories/activity_api.repository.dart';
import 'package:immich_mobile/services/activity.service.dart';
import 'package:mocktail/mocktail.dart';

class _MockActivityApiRepository extends Mock implements ActivityApiRepository {}

class _MockTimelineFactory extends Mock implements TimelineFactory {}

class _MockAssetService extends Mock implements AssetService {}

class _MockActivity extends Mock implements Activity {}

void main() {
  late _MockActivityApiRepository repository;
  late ServerAccessPolicy access;
  late ActivityService service;

  setUpAll(() => registerFallbackValue(ActivityType.like));

  setUp(() {
    repository = _MockActivityApiRepository();
    access = const ServerAccessPolicy.online();
    service = ActivityService(
      repository,
      _MockTimelineFactory(),
      _MockAssetService(),
      RemoteMutationGuard(() => access),
    );
  });

  for (final entry in <String, ServerAccessPolicy>{
    'offline': const ServerAccessPolicy.offline(),
    'reauthentication': const ServerAccessPolicy.reauthenticationRequired(),
  }.entries) {
    test('blocks activity create and delete before API calls while ${entry.key}', () async {
      access = entry.value;

      await expectLater(service.addActivity('album', ActivityType.like), throwsA(isA<StateError>()));
      await expectLater(service.removeActivity('activity'), throwsA(isA<StateError>()));

      verifyNever(
        () => repository.create(
          any(),
          any(),
          assetId: any(named: 'assetId'),
          comment: any(named: 'comment'),
        ),
      );
      verifyNever(() => repository.delete(any()));
    });
  }

  test('keeps activity create and delete behavior online', () async {
    final activity = _MockActivity();
    when(
      () => repository.create('album', ActivityType.like, assetId: null, comment: null),
    ).thenAnswer((_) async => activity);
    when(() => repository.delete('activity')).thenAnswer((_) async {});

    final created = await service.addActivity('album', ActivityType.like);
    final deleted = await service.removeActivity('activity');

    expect((created as AsyncData<Activity>).value, same(activity));
    expect(deleted, isTrue);
    verify(() => repository.create('album', ActivityType.like, assetId: null, comment: null)).called(1);
    verify(() => repository.delete('activity')).called(1);
  });
}
