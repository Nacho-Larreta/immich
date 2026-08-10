import 'dart:ui';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/models/timeline_source_filter.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/timeline/asset_source_selector.widget.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/shared_preferences'),
    (call) async => call.method == 'getAll' ? <String, Object>{} : null,
  );
  await EasyLocalization.ensureInitialized();

  testWidgets('selects a configured source and exposes the selected semantics', (tester) async {
    TimelineSourceFilter? selected;
    await tester.pumpWidget(
      _harness(
        AssetSourceSelector(
          selectedSource: TimelineSourceFilter.device,
          hasConfiguredServer: true,
          requiresReauthentication: false,
          reachabilityPhase: ReachabilityPhase.online,
          galleryPermission: PermissionStatus.granted,
          onSourceSelected: (source) => selected = source,
          onConnectServer: () {},
          onManageGalleryPermission: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final semantics = tester.getSemantics(find.text('Phone')).getSemanticsData();
    expect(semantics.label, 'Phone');
    expect(semantics.flagsCollection.isSelected, Tristate.isTrue);
    expect(semantics.hasAction(SemanticsAction.tap), isTrue);

    await tester.tap(find.text('Server'));
    expect(selected, TimelineSourceFilter.server);
  });

  testWidgets('offers server connection without changing source when unconfigured', (tester) async {
    var connectRequests = 0;
    TimelineSourceFilter? selected;
    await tester.pumpWidget(
      _harness(
        AssetSourceSelector(
          selectedSource: TimelineSourceFilter.device,
          hasConfiguredServer: false,
          requiresReauthentication: false,
          reachabilityPhase: ReachabilityPhase.unknown,
          galleryPermission: PermissionStatus.granted,
          onSourceSelected: (source) => selected = source,
          onConnectServer: () => connectRequests++,
          onManageGalleryPermission: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Server'));
    expect(connectRequests, 1);
    expect(selected, isNull);
    expect(find.text('Connect server'), findsOneWidget);
  });

  testWidgets('renders probing, offline, and permission states explicitly', (tester) async {
    await tester.pumpWidget(
      _harness(
        AssetSourceSelector(
          selectedSource: TimelineSourceFilter.server,
          hasConfiguredServer: true,
          requiresReauthentication: false,
          reachabilityPhase: ReachabilityPhase.offline,
          galleryPermission: PermissionStatus.granted,
          onSourceSelected: (_) {},
          onConnectServer: () {},
          onManageGalleryPermission: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Server offline · showing saved items'), findsOneWidget);

    await tester.pumpWidget(
      _harness(
        AssetSourceSelector(
          selectedSource: TimelineSourceFilter.combined,
          hasConfiguredServer: true,
          requiresReauthentication: false,
          reachabilityPhase: ReachabilityPhase.probing,
          galleryPermission: PermissionStatus.limited,
          onSourceSelected: (_) {},
          onConnectServer: () {},
          onManageGalleryPermission: () {},
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Only selected photos from this phone are visible.'), findsOneWidget);
  });

  testWidgets('keeps the source selector available and offers reauthentication', (tester) async {
    var reconnectRequests = 0;
    await tester.pumpWidget(
      _harness(
        AssetSourceSelector(
          selectedSource: TimelineSourceFilter.combined,
          hasConfiguredServer: true,
          requiresReauthentication: true,
          reachabilityPhase: ReachabilityPhase.offline,
          galleryPermission: PermissionStatus.granted,
          onSourceSelected: (_) {},
          onConnectServer: () => reconnectRequests++,
          onManageGalleryPermission: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('timeline-source-segmented-control')), findsOneWidget);
    expect(find.text('Your server session expired. Photos on this phone are still available.'), findsOneWidget);
    expect(find.text('Server offline · showing saved items'), findsNothing);

    await tester.tap(find.text('Sign in again'));
    expect(reconnectRequests, 1);
  });

  testWidgets('keeps a 48 point target and status actions survive 200 percent text scaling', (tester) async {
    var permissionRequests = 0;
    await tester.pumpWidget(
      _harness(
        AssetSourceSelector(
          selectedSource: TimelineSourceFilter.combined,
          hasConfiguredServer: true,
          requiresReauthentication: true,
          reachabilityPhase: ReachabilityPhase.offline,
          galleryPermission: PermissionStatus.limited,
          onSourceSelected: (_) {},
          onConnectServer: () {},
          onManageGalleryPermission: () => permissionRequests++,
        ),
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const ValueKey('timeline-source-segmented-control'))).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.text('Go to settings'));
    expect(permissionRequests, 1);
    expect(tester.takeException(), isNull);
  });
}

Widget _harness(Widget child, {TextScaler textScaler = TextScaler.noScaling}) => EasyLocalization(
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
          body: Align(alignment: Alignment.topCenter, child: child),
        ),
      ),
    ),
  ),
);
