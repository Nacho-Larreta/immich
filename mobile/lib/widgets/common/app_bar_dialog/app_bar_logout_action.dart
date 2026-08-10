import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/logout_outcome.model.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';

class AppBarLogoutAction extends StatefulWidget {
  const AppBarLogoutAction({super.key, required this.logout, required this.onLoggedOut, this.onError});

  final Future<LogoutOutcome> Function() logout;
  final FutureOr<void> Function(LogoutOutcome outcome) onLoggedOut;
  final void Function(Object error)? onError;

  @override
  State<AppBarLogoutAction> createState() => _AppBarLogoutActionState();
}

class _AppBarLogoutActionState extends State<AppBarLogoutAction> {
  bool _isLoggingOut = false;

  Future<void> _confirmLogout() async {
    if (_isLoggingOut) return;

    final profileNavigator = Navigator.of(context);
    final profileRoute = ModalRoute.of(context);
    unawaited(
      showDialog<bool>(
        context: context,
        builder: (_) => ConfirmDialog(
          title: 'app_bar_signout_dialog_title',
          content: 'app_bar_signout_dialog_content',
          ok: 'yes',
          onOk: () => _logout(profileNavigator, profileRoute),
        ),
      ),
    );
  }

  Future<void> _logout(NavigatorState profileNavigator, ModalRoute<dynamic>? profileRoute) async {
    setState(() => _isLoggingOut = true);
    try {
      final outcome = await widget.logout();
      if (outcome case LogoutNotCleared(:final error)) {
        _showFailure(error);
        return;
      }
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (profileNavigator.mounted && profileRoute?.isCurrent == true) {
        profileNavigator.pop();
      }
      final navigation = widget.onLoggedOut(outcome);
      if (outcome is LogoutClearedWithWarning) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          messenger?.showSnackBar(SnackBar(content: Text('logout_completed_with_warning'.tr())));
        });
      }
      await navigation;
    } catch (error) {
      _showFailure(error);
    }
  }

  void _showFailure(Object error) {
    if (!mounted) return;
    setState(() => _isLoggingOut = false);
    widget.onError?.call(error);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('scaffold_body_error_occurred'.tr())));
  }

  @override
  Widget build(BuildContext context) {
    final textColor = Theme.of(context).textTheme.labelLarge?.color?.withAlpha(250);
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.standard,
      contentPadding: const EdgeInsets.only(left: 30, right: 30),
      minLeadingWidth: 40,
      minTileHeight: 48,
      leading: Icon(Icons.logout_rounded, color: textColor, size: 20),
      title: Text('sign_out', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: textColor)).tr(),
      onTap: _isLoggingOut ? null : _confirmLogout,
      trailing: _isLoggingOut
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : null,
    );
  }
}
