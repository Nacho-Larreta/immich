import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_submission.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/providers/backup/asset_upload_progress.provider.dart';
import 'package:immich_mobile/providers/infrastructure/action.provider.dart';
import 'package:immich_mobile/providers/manual_upload.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/upload_action_button.widget.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:mocktail/mocktail.dart';

class _Submission extends Mock implements ManualUploadSubmissionPort {}

class _Asset extends Mock implements LocalAsset {}

final class _ActionNotifier extends ActionNotifier {
  _ActionNotifier(this.result);

  final Future<ActionResult> result;

  @override
  void build() {}

  @override
  Future<ActionResult> upload(ActionSource source, {List<LocalAsset>? assets}) => result;
}

void main() {
  testWidgets('closing queued viewer dialog hides it without cancelling its durable intent', (tester) async {
    final submission = _Submission();
    final container = ProviderContainer(overrides: [manualUploadSubmissionProvider.overrideWithValue(submission)]);
    addTearDown(container.dispose);
    container.read(assetUploadProgressProvider.notifier).setProgress('asset-1', 0);
    await tester.pumpWidget(_Harness(container: container));

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(ImmichTextButton).first);
    await tester.pumpAndSettle();

    expect(find.byType(QueuedUploadDialog), findsNothing);
    verifyNever(() => submission.requestCancel(any()));
    expect(container.read(assetUploadProgressProvider), {'asset-1': 0});
  });

  testWidgets('explicit cancel targets only the accepted viewer intent', (tester) async {
    final submission = _Submission();
    when(() => submission.requestCancel('intent-1')).thenAnswer((_) async {});
    final container = ProviderContainer(overrides: [manualUploadSubmissionProvider.overrideWithValue(submission)]);
    addTearDown(container.dispose);
    container.read(assetUploadProgressProvider.notifier).setProgress('asset-1', 0);
    await tester.pumpWidget(_Harness(container: container));

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(ImmichTextButton).last);
    await tester.pumpAndSettle();

    verify(() => submission.requestCancel('intent-1')).called(1);
    expect(find.byType(QueuedUploadDialog), findsNothing);
  });

  testWidgets('failed durable submit keeps timeline selection intact', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final selected = _Asset();
    final pending = Completer<ActionResult>();
    final container = _timelineContainer({selected}, pending.future);
    addTearDown(container.dispose);
    await tester.pumpWidget(_TimelineHarness(container: container));

    await tester.tap(find.byType(UploadActionButton));
    await tester.pump();
    expect(container.read(multiSelectProvider).selectedAssets, {selected});
    pending.complete(const ActionResult(count: 0, success: false, pendingCount: 1));
    await tester.pump();
    expect(container.read(multiSelectProvider).selectedAssets, {selected});
    await tester.pump(const Duration(seconds: 4));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('accepted submit clears only tapped selection, preserving new selection made while committing', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final selected = _Asset();
    final selectedLater = _Asset();
    final pending = Completer<ActionResult>();
    final container = _timelineContainer({selected}, pending.future);
    addTearDown(container.dispose);
    await tester.pumpWidget(_TimelineHarness(container: container));

    await tester.tap(find.byType(UploadActionButton));
    await tester.pump();
    container.read(multiSelectProvider.notifier).selectAsset(selectedLater);
    pending.complete(const ActionResult(count: 0, success: true, acceptedCount: 1, pendingCount: 1));
    await tester.pump();
    expect(container.read(multiSelectProvider).selectedAssets, {selectedLater});
    debugDefaultTargetPlatformOverride = null;
  });
}

ProviderContainer _timelineContainer(Set<BaseAsset> selected, Future<ActionResult> result) => ProviderContainer(
  overrides: [
    multiSelectProvider.overrideWith(
      () => MultiSelectNotifier(MultiSelectState(selectedAssets: selected, lockedSelectionAssets: const {})),
    ),
    actionProvider.overrideWith(() => _ActionNotifier(result)),
  ],
);

final class _TimelineHarness extends StatelessWidget {
  const _TimelineHarness({required this.container});

  final ProviderContainer container;

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: Scaffold(body: UploadActionButton(source: ActionSource.timeline)),
    ),
  );
}

final class _Harness extends StatelessWidget {
  const _Harness({required this.container});

  final ProviderContainer container;

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            barrierDismissible: true,
            builder: (_) => const QueuedUploadDialog(intentIds: ['intent-1'], localAssetIds: ['asset-1']),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
}
