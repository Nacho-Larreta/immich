import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/share_operation.interface.dart';
import 'package:immich_mobile/domain/models/original_export.model.dart';
import 'package:immich_mobile/domain/models/share.model.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/share_action_button.widget.dart';

void main() {
  test('maps remote authentication and connectivity failures to distinct messages', () {
    expect(
      shareFailureMessageKey(
        ShareAssetFailure(assetId: 'remote-1', phase: SharePhase.remoteExport, error: OriginalExportError.unauthorized),
      ),
      'timeline_source_reauthentication_required',
    );
    expect(
      shareFailureMessageKey(
        ShareAssetFailure(
          assetId: 'remote-1',
          phase: SharePhase.remoteExport,
          error: OriginalExportError.serverUnavailable,
        ),
      ),
      'timeline_source_server_offline',
    );
  });

  testWidgets('dialog cancel invokes operation cancellation once and late completion is context-safe', (tester) async {
    final operation = _ShareOperation();
    await tester.pumpWidget(_Harness(operation: operation));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.descendant(of: find.byType(SharePreparingDialog), matching: find.byType(TextButton)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(operation.cancelCount, 1);

    operation.complete(
      ShareResult.failure(
        ShareAssetFailure(assetId: 'asset-1', phase: SharePhase.localExport, error: OriginalExportError.cancelled),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('presentation phase dismisses preparation without claiming cancellation', (tester) async {
    final operation = _ShareOperation();
    await tester.pumpWidget(_Harness(operation: operation));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    operation.publish(ShareProgress(phase: SharePhase.presentation, completedCount: 1, totalCount: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(SharePreparingDialog), findsNothing);
    expect(operation.cancelCount, 0);
    operation.complete(ShareResult.success(actualCount: 1, disposition: ShareDisposition.dismissed));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-turn presentation and result exit the dialog only once', (tester) async {
    final operation = _ShareOperation();
    await tester.pumpWidget(_Harness(operation: operation));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    operation.publish(ShareProgress(phase: SharePhase.presentation, completedCount: 1, totalCount: 1));
    operation.complete(ShareResult.success(actualCount: 1, disposition: ShareDisposition.dismissed));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('open'), findsOneWidget);
    expect(find.byType(SharePreparingDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

final class _Harness extends StatelessWidget {
  const _Harness({required this.operation});

  final ShareOperation operation;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => SharePreparingDialog(operation: operation),
          ),
          child: const Text('open'),
        ),
      ),
    );
  }
}

final class _ShareOperation implements ShareOperation {
  final Completer<ShareResult> _result = Completer();
  final StreamController<ShareProgress> _progress = StreamController.broadcast(sync: true);
  int cancelCount = 0;

  @override
  Future<ShareResult> get result => _result.future;

  @override
  Stream<ShareProgress> get progress => _progress.stream;

  void publish(ShareProgress progress) => _progress.add(progress);

  void complete(ShareResult result) => _result.complete(result);

  @override
  Future<void> cancel() async => cancelCount++;
}
