import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/share.model.dart';
import 'package:immich_mobile/infrastructure/adapters/share_sheet/share_plus_sheet_adapter.dart';
import 'package:share_plus/share_plus.dart' as plugin;

void main() {
  test('maps anchor and actual file count while retaining files until the plugin settles', () async {
    final directory = await Directory.systemTemp.createTemp('share-plus-adapter-');
    addTearDown(() => directory.delete(recursive: true));
    final first = await File('${directory.path}/one.jpg').writeAsString('one');
    final second = await File('${directory.path}/two.jpg').writeAsString('two');
    final completion = Completer<plugin.ShareResult>();
    late List<plugin.XFile> receivedFiles;
    Rect? receivedAnchor;
    final adapter = SharePlusSheetAdapter(
      invoker: (files, anchor) {
        receivedFiles = files;
        receivedAnchor = anchor;
        return completion.future;
      },
    );

    final operation = adapter.share(
      ShareSheetRequest(paths: [first.path, second.path], anchor: ShareAnchor(x: 1, y: 2, width: 3, height: 4)),
    );
    await pumpEventQueue();

    expect(receivedFiles.map((file) => file.path), [first.path, second.path]);
    expect(receivedAnchor, const Rect.fromLTWH(1, 2, 3, 4));
    expect(await first.exists(), isTrue);
    expect(await second.exists(), isTrue);

    completion.complete(const plugin.ShareResult('activity', plugin.ShareResultStatus.success));
    expect(await operation.result, ShareResult.success(actualCount: 2, disposition: ShareDisposition.completed));
  });

  test('maps dismiss, unavailable feedback and presentation exceptions', () async {
    for (final expectation in <(plugin.ShareResult, ShareDisposition)>[
      (const plugin.ShareResult('', plugin.ShareResultStatus.dismissed), ShareDisposition.dismissed),
      (plugin.ShareResult.unavailable, ShareDisposition.unknown),
    ]) {
      final adapter = SharePlusSheetAdapter(invoker: (_, _) async => expectation.$1);
      expect(
        await adapter.share(ShareSheetRequest(paths: const ['/tmp/photo.jpg'])).result,
        ShareResult.success(actualCount: 1, disposition: expectation.$2),
      );
    }

    final reported = <ShareSheetError>[];
    final failing = SharePlusSheetAdapter(
      invoker: (_, _) async => throw StateError('platform unavailable'),
      reportFailure: reported.add,
    );
    expect(
      await failing.share(ShareSheetRequest(paths: const ['/tmp/photo.jpg'])).result,
      const ShareResult.failure(ShareSheetFailure(error: ShareSheetError.presentationFailed)),
    );
    expect(reported, [ShareSheetError.presentationFailed]);
  });

  test('cancel does not falsely complete after the platform owns the files', () async {
    final completion = Completer<plugin.ShareResult>();
    final adapter = SharePlusSheetAdapter(invoker: (_, _) => completion.future);
    final operation = adapter.share(ShareSheetRequest(paths: const ['/tmp/photo.jpg']));

    await operation.cancel();
    var completed = false;
    unawaited(operation.result.then((_) => completed = true));
    await pumpEventQueue();
    expect(completed, isFalse);

    completion.complete(const plugin.ShareResult('', plugin.ShareResultStatus.dismissed));
    expect(await operation.result, ShareResult.success(actualCount: 1, disposition: ShareDisposition.dismissed));
  });
}
