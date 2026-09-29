import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/design_system/app_dimens.dart';
import '../../core/design_system/app_theme.dart';
import '../../core/providers.dart';
import '../common/widgets.dart';

enum _PermStatus { granted, denied, unavailable, checking }

/// Per-permission status + shortcuts. Nothing here blocks app usage when
/// denied — the app degrades gracefully.
class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key});

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen>
    with WidgetsBindingObserver {
  _PermStatus _notifications = _PermStatus.checking;
  _PermStatus _install = _PermStatus.checking;
  _PermStatus _battery = _PermStatus.checking;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may grant/revoke a permission in system settings and come
    // straight back — statuses would otherwise stay stale until reopen.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final notifGranted = await Permission.notification.isGranted;
    final installGranted = await ref.read(installerProvider).canRequestInstall();
    final batteryIgnored =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;

    if (!mounted) return;
    setState(() {
      _notifications = notifGranted ? _PermStatus.granted : _PermStatus.denied;
      _install =
          installGranted ? _PermStatus.granted : _PermStatus.denied;
      _battery =
          batteryIgnored ? _PermStatus.granted : _PermStatus.denied;
    });
  }

  Future<void> _requestNotifications() async {
    final before = await Permission.notification.isGranted;
    final status = await Permission.notification.request();
    if (!mounted) return;
    if (!before && status.isGranted) {
      setState(() => _notifications = _PermStatus.granted);
    } else if (status.isPermanentlyDenied || status.isDenied) {
      setState(() => _notifications = _PermStatus.denied);
      if (status.isPermanentlyDenied) {
        await openAppSettings();
      }
    } else {
      setState(() => _notifications = _PermStatus.granted);
    }
  }

  Future<void> _openInstallSettings() async {
    await ref.read(installerProvider).openInstallPermissionSettings();
  }

  Future<void> _openBatterySettings() async {
    await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Permissions')),
      body: ListView(
        padding: const EdgeInsets.all(AppDimens.s16),
        children: [
          Text(
            'Each permission is requested in context and only when it is '
            'needed. If you deny one, the app keeps working — you just lose '
            'the related convenience.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppDimens.s16),
          _PermCard(
            icon: Symbols.notifications_rounded,
            title: 'Notifications',
            description: 'Update alerts and background sending progress. '
                'Without it you will only see updates inside the app.',
            status: _notifications,
            statusLabel: _label(_notifications),
            actionLabel: _notifications == _PermStatus.granted
                ? null
                : 'Allow notifications',
            onAction: _requestNotifications,
          ),
          const SizedBox(height: AppDimens.s8),
          _PermCard(
            icon: Symbols.install_mobile_rounded,
            title: 'Install unknown apps',
            description: 'Needed only when you tap “Update now”, so the '
                'system can install the new APK. This app never installs '
                'anything silently.',
            status: _install,
            statusLabel: _label(_install),
            actionLabel: _install == _PermStatus.granted
                ? null
                : 'Open settings',
            onAction: _openInstallSettings,
          ),
          const SizedBox(height: AppDimens.s8),
          _PermCard(
            icon: Symbols.battery_saver_rounded,
            title: 'Ignore battery optimisation',
            tag: 'Optional',
            description:
                'Only useful if your system stops long background sends. '
                'Everything works without it on most devices.',
            status: _battery,
            statusLabel: _label(_battery),
            actionLabel: _battery == _PermStatus.granted ? null : 'Open settings',
            onAction: _openBatterySettings,
          ),
        ],
      ),
    );
  }

  String _label(_PermStatus status) => switch (status) {
        _PermStatus.granted => 'Granted',
        _PermStatus.denied => 'Not granted',
        _PermStatus.unavailable => 'Not needed',
        _PermStatus.checking => '…',
      };
}

class _PermCard extends StatelessWidget {
  const _PermCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.status,
    required this.statusLabel,
    required this.actionLabel,
    required this.onAction,
    this.tag,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? tag;
  final _PermStatus status;
  final String statusLabel;
  final String? actionLabel;
  final Future<void> Function() onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppTheme.tokensOf(context);
    final granted = status == _PermStatus.granted;

    return Container(
      padding: const EdgeInsets.all(AppDimens.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppDimens.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: AppDimens.s8),
              Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
              if (tag != null) ...[
                const SizedBox(width: AppDimens.s8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppDimens.s8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius:
                        BorderRadius.circular(AppDimens.radiusFull),
                  ),
                  child: Text(
                    tag!,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              ],
              const SizedBox(width: AppDimens.s8),
              StatusBadge(
                label: statusLabel,
                color: granted
                    ? tokens.successContainer
                    : theme.colorScheme.surfaceContainerHighest,
                onColor: granted
                    ? tokens.onSuccessContainer
                    : theme.colorScheme.onSurfaceVariant,
                icon: granted
                    ? Symbols.check_rounded
                    : Symbols.close_rounded,
              ),
            ],
          ),
          const SizedBox(height: AppDimens.s8),
          Text(description, style: theme.textTheme.bodySmall),
          if (actionLabel != null) ...[
            const SizedBox(height: AppDimens.s8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ),
          ],
        ],
      ),
    );
  }
}
