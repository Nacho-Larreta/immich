import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/user_api.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

final class _MockApiService extends Mock implements ApiService {}

final class _MockUsersApi extends Mock implements UsersApi {}

void main() {
  test('preserves the causal ApiException when the fresh user request is unauthorized', () async {
    final service = _MockApiService();
    final api = _MockUsersApi();
    final unauthorized = ApiException(401, 'Unauthorized');
    when(() => service.usersApi).thenReturn(api);
    when(api.getMyUser).thenThrow(unauthorized);

    final request = UserApiRepository(service).getMyUser();

    await expectLater(request, throwsA(same(unauthorized)));
    verifyNever(api.getMyPreferences);
  });

  test('does not fetch preferences when the server has no current user', () async {
    final service = _MockApiService();
    final api = _MockUsersApi();
    when(() => service.usersApi).thenReturn(api);
    when(api.getMyUser).thenAnswer((_) async => null);

    expect(await UserApiRepository(service).getMyUser(), isNull);
    verifyNever(api.getMyPreferences);
  });
}
