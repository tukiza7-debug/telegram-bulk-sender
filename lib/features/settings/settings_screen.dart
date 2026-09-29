import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/design_system/app_dimens.dart';
import '../../core/updates/version_utils.dart';
import '../../core/providers.dart';
import '../common/widgets.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final username = ref.watch(botUsernameProvider).value ?? '';
    final update = ref.watch(updateProvider);
    final controller = ref.read(updateProvider.notifier);

    final skipped = update.skippedVersion;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppDimens.s24),
        children: [
          Section(
            title: 'Account',
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Symbols.smart_toy_rounded),
                  title: Text(username.isEmpty ? 'Bot' : username),
                  subtitle: const Text('Connected bot'),
                ),
                ListTile(
                  leading: const Icon(Symbols.sync_rounded),
                  title: const Text('Reconnect token'),
                  subtitle: const Text(
                    'Token changed or invalid? Validate a new one',
                  ),
                  trailing: const Icon(Symbols.chevron_right_rounded),
                  onTap: () => context.push('/settings/reconnect'),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppDimens.s16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Disconnect bot?'),
                            content: const Text(
                              'The stored token is deleted from this device. '
                              'Recipients and history stay until you remove '
                              'them.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                child: const Text('Disconnect'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true && context.mounted) {
                          await ref
                              .read(botSessionProvider.notifier)
                              .disconnect();
                          if (context.mounted) context.go('/onboarding');
                        }
                      },
                      icon: const Icon(Symbols.link_off_rounded, size: 20),
                      label: const Text('Disconnect bot'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppDimens.s16),
          Section(
            title: 'Updates',
            subtitle: update.currentVersion.isEmpty
                ? 'Checked against GitHub Releases.'
                : 'Installed: v${update.currentVersion}. Checked against '
                    'GitHub Releases every 6 hours in the background.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (update.phase == UpdatePhase.available &&
                    update.release != null)
                  ListTile(
                    leading: Icon(
                      Symbols.system_update_rounded,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text(
                      'v${update.release!.version} available',
                      style: theme.textTheme.titleSmall,
                    ),
                    subtitle: const Text('Tap to review and install'),
                    trailing: const Icon(Symbols.chevron_right_rounded),
                    onTap: () => context.push('/update'),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppDimens.s16,
                    ),
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.tonalIcon(
                        onPressed: update.phase == UpdatePhase.checking
                            ? null
                            : () => controller.checkNow(),
                        icon: update.phase == UpdatePhase.checking
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Symbols.refresh_rounded, size: 20),
                        label: const Text('Check for updates'),
                      ),
                    ),
                  ),
                if (update.phase == UpdatePhase.upToDate)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      "You're up to date.",
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                if (skipped != null &&
                    update.currentVersion.isNotEmpty &&
                    VersionUtils.isNewer(skipped, update.currentVersion))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Version v$skipped is skipped.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        TextButton(
                          onPressed: () => controller.unskip(),
                          child: const Text('Unskip'),
                        ),
                      ],
                    ),
                  ),
                if (update.error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      update.error!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppDimens.s16),
          Section(
            title: 'Permissions',
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Symbols.lock_rounded),
                  title: const Text('Notification & install permissions'),
                  subtitle:
                      const Text('Status and shortcuts to system settings'),
                  trailing: const Icon(Symbols.chevron_right_rounded),
                  onTap: () => context.push('/settings/permissions'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppDimens.s16),
          Section(
            title: 'About',
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Symbols.info_rounded),
                  title: const Text('Version'),
                  subtitle: Text(
                    update.currentVersion.isEmpty
                        ? '…'
                        : 'v${update.currentVersion}',
                  ),
                ),
                ListTile(
                  leading: const Icon(Symbols.code_rounded),
                  title: const Text('Source code'),
                  subtitle: const Text(
                    'github.com/tukiza7-debug/telegram-bulk-sender',
                  ),
                  onTap: () {},
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: AppDimens.s16),
                  child: Text(
                    'Bulk Sender talks only to api.telegram.org (with your '
                    'bot) and api.github.com (for updates). The bot token is '
                    'stored encrypted on this device. Not affiliated with '
                    'Telegram. Please respect Telegram’s Terms of Service '
                    'and do not use this app to spam.',
                    style: TextStyle(height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
