import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/forms/login/login_form.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

@RoutePage()
class LoginPage extends HookConsumerWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appVersion = useState('0.0.0');

    getAppInfo() async {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      appVersion.value = packageInfo.version;
    }

    useEffect(() {
      getAppInfo();
      return null;
    });

    return LoginPageLayout(
      appVersion: appVersion.value,
      loginForm: LoginForm(),
      onOpenPhotos: () => replaceLoginWithLocalLibrary(context.router),
      onOpenLogs: () => context.pushRoute(const AppLogRoute()),
    );
  }
}

Future<void> replaceLoginWithLocalLibrary(StackRouter router) => router.replaceAll([localLibraryShell()]);

final class LoginPageLayout extends StatelessWidget {
  const LoginPageLayout({
    super.key,
    required this.appVersion,
    required this.loginForm,
    required this.onOpenPhotos,
    this.onOpenLogs,
  });

  final String appVersion;
  final Widget loginForm;
  final FutureOr<void> Function() onOpenPhotos;
  final FutureOr<void> Function()? onOpenLogs;

  @override
  Widget build(BuildContext context) {
    final openPhotosLabel = 'login_form_back_to_photos'.t(context: context);
    return Scaffold(
      body: loginForm,
      bottomNavigationBar: AnimatedPadding(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300, minHeight: 44),
                  child: Semantics(
                    key: const ValueKey('login-open-local-library'),
                    button: true,
                    label: openPhotosLabel,
                    onTap: onOpenPhotos,
                    child: ExcludeSemantics(
                      child: ImmichTextButton(
                        labelText: openPhotosLabel,
                        icon: Icons.photo_library_outlined,
                        variant: ImmichVariant.ghost,
                        onPressed: onOpenPhotos,
                      ),
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'v$appVersion',
                      style: TextStyle(
                        color: context.colorScheme.onSurfaceSecondary,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'GoogleSansCode',
                      ),
                    ),
                    if (onOpenLogs != null) ...[
                      const Text(' '),
                      GestureDetector(
                        onTap: onOpenLogs,
                        child: Text(
                          'Logs',
                          style: TextStyle(
                            color: context.primaryColor,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'GoogleSansCode',
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
