import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/server/server_access_boundary.widget.dart';

Future<void> main() async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/shared_preferences'),
    (call) async => call.method == 'getAll' ? <String, Object>{} : null,
  );
  await EasyLocalization.ensureInitialized();

  testWidgets('forbidden boundary never builds its remote subtree', (tester) async {
    var builds = 0;
    await tester.pumpWidget(
      _harness(
        ServerCapabilityBoundary(
          access: const ServerAccessPolicy.unconfigured(),
          capability: ServerCapability.remoteRead,
          noticeVariant: ServerAccessNoticeVariant.fullPage,
          onConnect: () {},
          onReauthenticate: () {},
          onRetry: () {},
          childBuilder: (_) {
            builds++;
            return const Text('remote subtree');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(builds, 0);
    expect(find.text('remote subtree'), findsNothing);
    expect(find.text('Connect server'), findsOneWidget);
  });

  testWidgets('notice has semantic status, 44 point CTA and survives Dynamic Type', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _harness(
        ServerAccessNotice(mode: ServerAccessMode.offline, variant: ServerAccessNoticeVariant.section, onRetry: () {}),
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pumpAndSettle();

    final statusSemantics = tester
        .widgetList<Semantics>(find.descendant(of: find.byType(ServerAccessNotice), matching: find.byType(Semantics)))
        .singleWhere((widget) => widget.properties.liveRegion == true);
    expect(statusSemantics.properties.label, 'Server offline');
    expect(statusSemantics.properties.liveRegion, isTrue);
    expect(tester.getSize(find.widgetWithText(TextButton, 'Try again')).height, greaterThanOrEqualTo(44));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('online boundary builds its subtree once', (tester) async {
    var builds = 0;
    await tester.pumpWidget(
      _harness(
        ServerCapabilityBoundary(
          access: const ServerAccessPolicy.online(),
          capability: ServerCapability.remoteMutation,
          noticeVariant: ServerAccessNoticeVariant.inline,
          childBuilder: (_) {
            builds++;
            return const Text('remote subtree');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(builds, 1);
    expect(find.text('remote subtree'), findsOneWidget);
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
        data: MediaQueryData(textScaler: textScaler),
        child: Scaffold(body: child),
      ),
    ),
  ),
);
