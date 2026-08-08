import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';

void main() {
  test('defines every approved offline error code', () {
    expect(OfflineErrorCode.values, [
      OfflineErrorCode.cacheMiss,
      OfflineErrorCode.mediaNotLocal,
      OfflineErrorCode.iCloudUnavailable,
      OfflineErrorCode.cancelled,
      OfflineErrorCode.timeout,
      OfflineErrorCode.serverUnavailable,
      OfflineErrorCode.wrongServer,
      OfflineErrorCode.unauthorized,
    ]);
  });

  test('success contains a payload and no error code', () {
    const result = OfflineResult<String>.success('cached-media');

    expect(result, const OfflineSuccess('cached-media'));
    expect(result.valueOrNull, 'cached-media');
    expect(result.errorOrNull, isNull);
  });

  test('failure contains an error code and no payload', () {
    const result = OfflineResult<String>.failure(OfflineErrorCode.cacheMiss);

    expect(result, const OfflineFailure<String>(OfflineErrorCode.cacheMiss));
    expect(result.valueOrNull, isNull);
    expect(result.errorOrNull, OfflineErrorCode.cacheMiss);
  });
}
