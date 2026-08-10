import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/logout_outcome.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/providers/remote_authentication.provider.dart';
import 'package:immich_mobile/widgets/common/app_bar_dialog/app_bar_logout_action.dart';
import 'package:immich_mobile/widgets/common/immich_sliver_app_bar.dart';

Future<void> main() async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/shared_preferences'),
    (call) async => call.method == 'getAll' ? <String, Object>{} : null,
  );
  await EasyLocalization.ensureInitialized();

  testWidgets('successful logout closes confirmation and profile before showing the local shell', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    var logoutCalls = 0;

    await tester.pumpWidget(
      _harness(
        navigatorKey: navigatorKey,
        logout: () async {
          logoutCalls++;
          return const LogoutSuccess();
        },
        onLoggedOut: (_) async {
          await navigatorKey.currentState!.pushReplacement(
            MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('local-shell'))),
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.logout_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();

    expect(logoutCalls, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('local-shell'), findsOneWidget);
  });

  testWidgets('failed logout leaves the profile open and allows retry', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    var failures = 0;

    await tester.pumpWidget(
      _harness(
        navigatorKey: navigatorKey,
        logout: () async => LogoutNotCleared(StateError('logout failed')),
        onLoggedOut: (_) => throw StateError('must not navigate'),
        onError: (_) => failures++,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.logout_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();

    expect(failures, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byIcon(Icons.logout_rounded), findsOneWidget);
    expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNotNull);
  });

  testWidgets('partial logout closes the profile, navigates locally, and warns in the shell', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      _harness(
        navigatorKey: navigatorKey,
        logout: () async => LogoutClearedWithWarning(StateError('background cleanup failed')),
        onLoggedOut: (_) async {
          await navigatorKey.currentState!.pushReplacement(
            MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('local-shell'))),
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.logout_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(Dialog), findsNothing);
    expect(find.text('local-shell'), findsOneWidget);
    expect(find.text('Signed out, but some background cleanup could not finish.'), findsOneWidget);
  });

  testWidgets('reauthentication phase suppresses stale authenticated app bar actions', (tester) async {
    var authenticatedBuilds = 0;
    var connectCalls = 0;

    Widget subject(RemoteAuthenticationPhase phase) => AppBarServerSessionActions(
      authenticationPhase: phase,
      onConnect: () => connectCalls++,
      authenticatedBuilder: (_) {
        authenticatedBuilds++;
        return const Text('stale-avatar-and-backup');
      },
    );

    await tester.pumpWidget(_localizedHarness(subject(RemoteAuthenticationPhase.reauthenticationRequired)));
    await tester.pumpAndSettle();

    expect(authenticatedBuilds, 0);
    expect(find.text('stale-avatar-and-backup'), findsNothing);
    expect(find.byKey(const ValueKey('connect-server-indicator')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('connect-server-indicator')));
    expect(connectCalls, 1);

    await tester.pumpWidget(_localizedHarness(subject(RemoteAuthenticationPhase.authenticated)));
    await tester.pumpAndSettle();
    expect(authenticatedBuilds, 1);
    expect(find.text('stale-avatar-and-backup'), findsOneWidget);
  });
}

Widget _harness({
  required GlobalKey<NavigatorState> navigatorKey,
  required Future<LogoutOutcome> Function() logout,
  required Future<void> Function(LogoutOutcome outcome) onLoggedOut,
  void Function(Object error)? onError,
}) {
  return EasyLocalization(
    supportedLocales: const [Locale('en')],
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    path: 'unused',
    saveLocale: false,
    assetLoader: const CodegenLoader(),
    child: Builder(
      builder: (context) => MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => Dialog(
                  child: AppBarLogoutAction(logout: logout, onLoggedOut: onLoggedOut, onError: onError),
                ),
              ),
              child: const Text('Open profile'),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _localizedHarness(Widget child) => EasyLocalization(
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
      home: Scaffold(body: child),
    ),
  ),
);
