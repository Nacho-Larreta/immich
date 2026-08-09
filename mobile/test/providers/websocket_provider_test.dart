import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/websocket.provider.dart';
import 'package:mocktail/mocktail.dart';

void main() {
  test('late websocket events after pause disconnect cannot trigger remote work', () {
    final ref = _MockRef();
    final notifier = WebsocketNotifier(ref);

    notifier.disconnect();
    notifier.handleSyncAssetUploadReady({'assetId': 'late-upload'});
    notifier.handleSyncAssetEditReady({'assetId': 'late-edit'});
    notifier.handleOnConfigUpdate(null);
    notifier.handleReleaseUpdates(const <String, dynamic>{});

    verifyNever(() => ref.read(backgroundSyncProvider));
    verifyNever(() => ref.read(serverInfoProvider.notifier));
  });
}

class _MockRef extends Mock implements Ref {}
