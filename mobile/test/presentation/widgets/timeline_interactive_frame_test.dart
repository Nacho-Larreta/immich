import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';

void main() {
  testWidgets('reports first empty data frame but not loading error or later data', (tester) async {
    final gate = TimelineInteractiveGate();
    final timelineState = ValueNotifier(_TimelineTestState.loading);
    addTearDown(timelineState.dispose);
    var interactiveCount = 0;

    await tester.pumpWidget(
      _TimelineStateHarness(state: timelineState, gate: gate, onInteractive: () => interactiveCount++),
    );
    expect(interactiveCount, 0);

    timelineState.value = _TimelineTestState.error;
    await tester.pump();
    expect(interactiveCount, 0);

    timelineState.value = _TimelineTestState.emptyData;
    await tester.pump();
    expect(interactiveCount, 1);

    timelineState.value = _TimelineTestState.loading;
    await tester.pump();
    timelineState.value = _TimelineTestState.emptyData;
    await tester.pump();

    expect(interactiveCount, 1);
  });

  testWidgets('does not consume the gate when reporting is disabled', (tester) async {
    final gate = TimelineInteractiveGate();
    var interactiveCount = 0;

    await tester.pumpWidget(
      _testApp(TimelineInteractiveFrame(gate: gate, onInteractive: null, child: const SizedBox())),
    );
    await tester.pumpWidget(
      _testApp(TimelineInteractiveFrame(gate: gate, onInteractive: () => interactiveCount++, child: const SizedBox())),
    );

    expect(interactiveCount, 1);
  });

  testWidgets('does not report when unmounted before the scheduled callback', (tester) async {
    final gate = TimelineInteractiveGate();
    VoidCallback? pendingPostFrame;
    var interactiveCount = 0;

    await tester.pumpWidget(
      _testApp(
        TimelineInteractiveFrame(
          gate: gate,
          onInteractive: () => interactiveCount++,
          schedulePostFrame: (callback) => pendingPostFrame = callback,
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    pendingPostFrame?.call();

    expect(interactiveCount, 0);
  });
}

Widget _testApp(Widget child) => MaterialApp(home: child);

enum _TimelineTestState { loading, error, emptyData }

class _TimelineStateHarness extends StatelessWidget {
  const _TimelineStateHarness({required this.state, required this.gate, required this.onInteractive});

  final ValueNotifier<_TimelineTestState> state;
  final TimelineInteractiveGate gate;
  final VoidCallback onInteractive;

  @override
  Widget build(BuildContext context) {
    return _testApp(
      ValueListenableBuilder(
        valueListenable: state,
        builder: (context, value, child) {
          return switch (value) {
            _TimelineTestState.loading => const CircularProgressIndicator(),
            _TimelineTestState.error => const Text('error'),
            _TimelineTestState.emptyData => TimelineInteractiveFrame(
              gate: gate,
              onInteractive: onInteractive,
              child: const SizedBox(key: ValueKey('empty-timeline')),
            ),
          };
        },
      ),
    );
  }
}
