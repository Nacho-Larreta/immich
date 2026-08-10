import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_source_filter.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/pages/dev/main_timeline.page.dart';
import 'package:immich_mobile/presentation/widgets/timeline/asset_source_selector.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/scrubber.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/shared_preferences'),
    (call) async => call.method == 'getAll' ? <String, Object>{} : null,
  );
  await EasyLocalization.ensureInitialized();

  testWidgets('Phone source never builds the remote memory lane', (tester) async {
    var remoteWorkRequests = 0;
    await tester.pumpWidget(
      _harness(
        MainTimelineTopSlivers(
          source: TimelineSourceFilter.device,
          selector: const SizedBox(height: 48, child: Text('source selector')),
          memoryLaneBuilder: (_) {
            remoteWorkRequests++;
            return const Text('remote memory work');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('source selector'), findsOneWidget);
    expect(find.text('remote memory work'), findsNothing);
    expect(remoteWorkRequests, 0);
  });

  testWidgets('combined source can build the memory lane', (tester) async {
    var remoteWorkRequests = 0;
    await tester.pumpWidget(
      _harness(
        MainTimelineTopSlivers(
          source: TimelineSourceFilter.combined,
          selector: const SizedBox(height: 48, child: Text('source selector')),
          memoryLaneBuilder: (_) {
            remoteWorkRequests++;
            return const Text('remote memory work');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('remote memory work'), findsOneWidget);
    expect(remoteWorkRequests, 1);
  });

  testWidgets('pinned selector supports status rows at 200 percent text scaling', (tester) async {
    await tester.pumpWidget(
      _harness(
        MainTimelineTopSlivers(
          source: TimelineSourceFilter.combined,
          selector: AssetSourceSelector(
            selectedSource: TimelineSourceFilter.combined,
            hasConfiguredServer: true,
            requiresReauthentication: true,
            reachabilityPhase: ReachabilityPhase.offline,
            galleryPermission: PermissionStatus.limited,
            onSourceSelected: (_) {},
            onConnectServer: () {},
            onManageGalleryPermission: () {},
          ),
          memoryLaneBuilder: (_) => const SizedBox(height: 300, child: Text('memories')),
        ),
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -250));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('timeline-source-segmented-control')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('month snap uses measured selector status and memory extent', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final segments = List<Segment>.generate(12, (index) => _TestSegment(index));
    final scrubberKey = GlobalKey<ScrubberState>();

    await tester.pumpWidget(
      _scrubberHarness(
        controller: controller,
        child: MeasuredTimelineScrubber(
          layoutSegments: segments,
          timelineHeight: 852,
          topPadding: 0,
          bottomPadding: 0,
          snapToMonth: true,
          hasAppBar: false,
          scrubberKey: scrubberKey,
          scrollViewBuilder: (extentObserver) => CustomScrollView(
            primary: true,
            slivers: [
              MainTimelineTopSlivers(
                source: TimelineSourceFilter.combined,
                selector: AssetSourceSelector(
                  key: const ValueKey('dynamic-selector'),
                  selectedSource: TimelineSourceFilter.combined,
                  hasConfiguredServer: true,
                  requiresReauthentication: true,
                  reachabilityPhase: ReachabilityPhase.offline,
                  galleryPermission: PermissionStatus.limited,
                  onSourceSelected: (_) {},
                  onConnectServer: () {},
                  onManageGalleryPermission: () {},
                ),
                memoryLaneBuilder: (_) =>
                    const SizedBox(key: ValueKey('dynamic-memories'), height: 300, child: Text('memories')),
              ),
              extentObserver,
              const SliverToBoxAdapter(child: SizedBox(height: 6000)),
            ],
          ),
        ),
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pumpAndSettle();

    final measuredPreGridExtent =
        tester.getSize(find.byKey(const ValueKey('dynamic-selector'))).height +
        tester.getSize(find.byKey(const ValueKey('dynamic-memories'))).height;
    expect(measuredPreGridExtent, greaterThan(300));

    scrubberKey.currentState!.snapToLayoutSegmentForTest(8);
    await tester.pump();

    final targetSegment = segments[8];
    final expectedTarget = calculateMonthSnapTarget(
      segmentStartOffset: targetSegment.startOffset,
      viewportHeight: controller.position.viewportDimension,
      preGridScrollExtent: measuredPreGridExtent,
      maxScrollExtent: controller.position.maxScrollExtent,
    );
    final targetWithoutMeasuredExtent = calculateMonthSnapTarget(
      segmentStartOffset: targetSegment.startOffset,
      viewportHeight: controller.position.viewportDimension,
      preGridScrollExtent: 0,
      maxScrollExtent: controller.position.maxScrollExtent,
    );

    expect(controller.offset, closeTo(expectedTarget, 0.01));
    expect(controller.offset, isNot(closeTo(targetWithoutMeasuredExtent, 0.01)));
  });

  test('chooses a specific empty state for every source and connectivity state', () {
    expect(
      mainTimelineEmptyMessageKey(TimelineSourceFilter.device, ReachabilityPhase.offline),
      'timeline_empty_device',
    );
    expect(
      mainTimelineEmptyMessageKey(TimelineSourceFilter.combined, ReachabilityPhase.online),
      'timeline_empty_combined',
    );
    expect(
      mainTimelineEmptyMessageKey(TimelineSourceFilter.combined, ReachabilityPhase.offline),
      'timeline_empty_combined_offline',
    );
    expect(mainTimelineEmptyMessageKey(TimelineSourceFilter.server, ReachabilityPhase.online), 'timeline_empty_server');
    expect(
      mainTimelineEmptyMessageKey(TimelineSourceFilter.server, ReachabilityPhase.offline),
      'timeline_empty_server_offline',
    );
  });

  testWidgets('renders explicit empty and recoverable error content', (tester) async {
    var retryRequests = 0;
    await tester.pumpWidget(
      _harness(const SliverToBoxAdapter(child: MainTimelineEmptyState(messageKey: 'timeline_empty_device'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('No photos or videos from this phone are available.'), findsOneWidget);

    await tester.pumpWidget(
      _harness(SliverToBoxAdapter(child: MainTimelineErrorState(onRetry: () => retryRequests++))),
    );
    await tester.pumpAndSettle();
    expect(find.text("We couldn't load your photos. Your source selection is still available above."), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retryRequests, 1);
  });
}

Widget _harness(Widget sliver, {TextScaler textScaler = TextScaler.noScaling}) => EasyLocalization(
  supportedLocales: const [Locale('en')],
  path: 'unused',
  fallbackLocale: const Locale('en'),
  saveLocale: false,
  assetLoader: const CodegenLoader(),
  child: Builder(
    builder: (context) => MaterialApp(
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      home: MediaQuery(
        data: MediaQueryData(size: const Size(393, 852), textScaler: textScaler),
        child: Scaffold(
          body: CustomScrollView(
            slivers: [
              sliver,
              const SliverToBoxAdapter(child: SizedBox(height: 1200)),
            ],
          ),
        ),
      ),
    ),
  ),
);

Widget _scrubberHarness({
  required ScrollController controller,
  required Widget child,
  TextScaler textScaler = TextScaler.noScaling,
}) => ProviderScope(
  child: EasyLocalization(
    supportedLocales: const [Locale('en')],
    path: 'unused',
    fallbackLocale: const Locale('en'),
    saveLocale: false,
    assetLoader: const CodegenLoader(),
    child: Builder(
      builder: (context) => MaterialApp(
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        home: MediaQuery(
          data: MediaQueryData(size: const Size(393, 852), textScaler: textScaler),
          child: Scaffold(
            body: PrimaryScrollController(controller: controller, child: child),
          ),
        ),
      ),
    ),
  ),
);

final class _TestSegment extends Segment {
  _TestSegment(int index)
    : super(
        firstIndex: index,
        lastIndex: index,
        startOffset: index * 500,
        endOffset: (index + 1) * 500,
        firstAssetIndex: index,
        bucket: TimeBucket(date: DateTime(2025, index + 1), assetCount: 1),
        headerExtent: 0,
        spacing: 0,
        header: HeaderType.none,
      );

  @override
  Widget builder(BuildContext context, int index) => const SizedBox.shrink();

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) => firstIndex;

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) => firstIndex;

  @override
  double indexToLayoutOffset(int index) => startOffset;
}
