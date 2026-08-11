import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/pages/login/login.page.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:mocktail/mocktail.dart';

class _MockStackRouter extends Mock implements StackRouter {}

Future<void> main() async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/shared_preferences'),
    (call) async => call.method == 'getAll' ? <String, Object>{} : null,
  );
  await EasyLocalization.ensureInitialized();
  registerFallbackValue(<PageRouteInfo>[]);

  for (final state in <(String, Widget)>[
    ('fresh server URL form', const Text('server-url-form')),
    ('credentials form with a visible error', const Column(children: [Text('credentials-form'), Text('login-error')])),
  ]) {
    testWidgets('local library action stays visible for ${state.$1}', (tester) async {
      await tester.pumpWidget(_harness(LoginPageLayout(appVersion: '2.7.5', loginForm: state.$2, onOpenPhotos: () {})));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-open-local-library')), findsOneWidget);
      expect(find.text('Back to photos'), findsOneWidget);
      expect(find.textContaining('form'), findsWidgets);
    });
  }

  testWidgets('local library action remains accessible with large Dynamic Type', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      _harness(
        LoginPageLayout(appVersion: '2.7.5', loginForm: const Text('login'), onOpenPhotos: () => calls++),
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pumpAndSettle();

    final action = find.byKey(const ValueKey('login-open-local-library'));
    final semantics = tester.getSemantics(action);
    expect(semantics.label, contains('Back to photos'));
    expect(semantics.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(tester.getSize(action).height, greaterThanOrEqualTo(44));

    await tester.tap(action);
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('credentials error keeps the local library action above the keyboard and tappable', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var calls = 0;
    const keyboardHeight = 300.0;
    await tester.pumpWidget(
      _harness(
        LoginPageLayout(
          appVersion: '2.7.5',
          loginForm: const Column(children: [Text('credentials-form'), Text('login-error')]),
          onOpenPhotos: () => calls++,
        ),
        viewInsets: const EdgeInsets.only(bottom: keyboardHeight),
      ),
    );
    await tester.pumpAndSettle();

    final action = find.byKey(const ValueKey('login-open-local-library'));
    expect(tester.getRect(action).bottom, lessThanOrEqualTo(800 - keyboardHeight));
    await tester.tap(action);
    await tester.pump();
    expect(calls, 1);
  });

  test('after a failed password login, leaving replaces the stack with only the local library', () async {
    final router = _MockStackRouter();
    when(() => router.replaceAll(any())).thenAnswer((_) async {});

    await replaceLoginWithLocalLibrary(router);

    final routes = verify(() => router.replaceAll(captureAny())).captured.single as List<PageRouteInfo>;
    expect(routes, hasLength(1));
    expect(routes.single, isA<TabShellRoute>());
    final children = (routes.single as TabShellRoute).initialChildren;
    expect(children, hasLength(1));
    expect(children!.single, isA<MainTimelineRoute>());
    verifyNoMoreInteractions(router);
  });
}

Widget _harness(
  Widget child, {
  TextScaler textScaler = TextScaler.noScaling,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) => EasyLocalization(
  supportedLocales: const [Locale('en')],
  fallbackLocale: const Locale('en'),
  startLocale: const Locale('en'),
  path: 'unused',
  saveLocale: false,
  assetLoader: const CodegenLoader(),
  child: Builder(
    builder: (context) => MaterialApp(
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      home: MediaQuery(
        data: MediaQueryData(textScaler: textScaler, viewInsets: viewInsets),
        child: child,
      ),
    ),
  ),
);
