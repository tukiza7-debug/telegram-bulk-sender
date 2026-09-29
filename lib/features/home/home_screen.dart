import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/design_system/app_dimens.dart';
import '../../core/network/telegram_models.dart';
import '../../core/providers.dart';
import '../common/widgets.dart';
import 'target_editor_sheet.dart';

/// Hub screen: manage recipients, see the pending-update banner, and start
/// a new bulk send by choosing photos.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final targets = ref.watch(targetsProvider);
    final files = ref.watch(pendingFilesProvider);
    final botUsername = ref.watch(botUsernameProvider);
    final update = ref.watch(updateProvider);

    final session = ref.watch(botSessionProvider);
    final hasToken = session != null;
    final resetNotice = ref.watch(botResetNoticeProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: 'Bulk '),
              TextSpan(
                text: 'Sender',
                style: TextStyle(color: theme.colorScheme.primary),
              ),
            ],
          ),
          style: theme.textTheme.titleLarge,
        ),
        actions: [
          IconButton(
            tooltip: 'History',
            onPressed: () => context.push('/history'),
            icon: const Icon(Symbols.history_rounded),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
            icon: const Icon(Symbols.settings_rounded),
          ),
          const SizedBox(width: AppDimens.s8),
        ],
      ),
      body: hasToken
          ? _HomeBody(
              targets: targets,
              fileCount: files.length,
              botUsername: botUsername.value ?? '',
              update: update,
              session: session,
            )
          : _NoBotState(resetNotice: resetNotice),
      bottomNavigationBar: hasToken ? _SendFooter(fileCount: files.length, targetCount: targets.length) : null,
    );
  }
}

class _HomeBody extends ConsumerWidget {
  const _HomeBody({
    required this.targets,
    required this.fileCount,
    required this.botUsername,
    required this.update,
    required this.session,
  });

  final List<TgChat> targets;
  final int fileCount;
  final String botUsername;
  final UpdateState update;
  final BotSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: AppDimens.s24),
      children: [
        if (update.phase == UpdatePhase.available && update.release != null)
          _UpdateBanner(
            version: update.release!.version,
            skipped: update.skippedVersion == update.release!.tag,
          ),
        Section(
          title: 'Recipients',
          subtitle: _connectionSubtitle(session, botUsername),
          trailing: IconButton(
            tooltip: 'Add recipient',
            onPressed: () => showTargetEditor(context),
            icon: const Icon(Symbols.add_rounded),
          ),
          child: targets.isEmpty
              ? const _EmptyTargets()
              : Column(
                  children: [
                    for (final target in targets)
                      _TargetRow(
                        key: ValueKey('target-${target.chatId}'),
                        target: target,
                      ),
                  ],
                ),
        ),
        if (targets.isNotEmpty) ...[
          const SizedBox(height: AppDimens.s8),
          Center(
            child: TextButton.icon(
              onPressed: () => showTargetEditor(context),
              icon: const Icon(Symbols.add_rounded, size: 18),
              label: const Text('Add recipient'),
            ),
          ),
        ],
        const SizedBox(height: AppDimens.s8),
        Section(
          title: 'Files',
          subtitle: fileCount == 0
              ? 'Nothing selected yet.'
              : '$fileCount file${fileCount == 1 ? '' : 's'} ready to send.',
          child: fileCount == 0
              ? Container(
                  padding: const EdgeInsets.all(AppDimens.s16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius:
                        BorderRadius.circular(AppDimens.radiusLg),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Symbols.image_rounded,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: AppDimens.s12),
                      Expanded(
                        child: Text(
                          'Photos, videos and documents you select will '
                          'appear here. Use “Choose files” below to pick '
                          'from your device.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// Accurate connection line: the app only claims "Sending as @bot" once
  /// the saved token has actually been re-verified with the live API.
  String? _connectionSubtitle(BotSession session, String botUsername) {
    switch (session.status) {
      case BotLinkStatus.checking:
        return 'Restoring bot connection…';
      case BotLinkStatus.offline:
        return botUsername.isEmpty
            ? 'Connection could not be verified (offline). Sends will '
                'retry once you are back online.'
            : 'Sending as $botUsername (connection not verified — '
                'check your internet). The bot must be a member (or admin) '
                'of each chat to post photos.';
      case BotLinkStatus.verified:
        return botUsername.isEmpty
            ? null
            : 'Sending as $botUsername. The bot must be a member (or admin) '
                'of each chat to post photos.';
    }
  }
}

class _UpdateBanner extends ConsumerWidget {
  const _UpdateBanner({required this.version, required this.skipped});

  final String version;
  final bool skipped;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.s16,
        AppDimens.s16,
        AppDimens.s16,
        0,
      ),
      child: Container(
        padding: const EdgeInsets.all(AppDimens.s16),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(AppDimens.radiusLg),
        ),
        child: Row(
          children: [
            Icon(
              Symbols.system_update_rounded,
              color: scheme.onPrimaryContainer,
            ),
            const SizedBox(width: AppDimens.s12),
            Expanded(
              child: Text(
                'Update available: v$version',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: () => context.push('/update'),
              style: TextButton.styleFrom(
                foregroundColor: scheme.onPrimaryContainer,
                minimumSize: const Size(64, 40),
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('View'),
            ),
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              onPressed: () => ref.read(updateProvider.notifier).skipThisVersion(),
              icon: const Icon(Symbols.close_rounded, size: 18),
              color: scheme.onPrimaryContainer,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyTargets extends StatelessWidget {
  const _EmptyTargets();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppDimens.s24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppDimens.radiusLg),
      ),
      child: Column(
        children: [
          Icon(
            Symbols.forum_rounded,
            size: 32,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: AppDimens.s12),
          Text('No recipients yet', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppDimens.s4),
          Text(
            'Add a chat ID or @channelusername. The bot must be able to '
            'post there — send it a message first or add it as admin.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _TargetRow extends ConsumerWidget {
  const _TargetRow({super.key, required this.target});

  final TgChat target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icon = switch (target.type) {
      'channel' => Symbols.campaign_rounded,
      'group' || 'supergroup' => Symbols.group_rounded,
      _ => Symbols.person_rounded,
    };
    final typeLabel = switch (target.type) {
      'channel' => 'Channel',
      'group' => 'Group',
      'supergroup' => 'Supergroup',
      _ => 'Private chat',
    };

    return ListTile(
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: scheme.secondaryContainer,
        foregroundColor: scheme.onSecondaryContainer,
        child: Icon(icon, size: 20),
      ),
      title: Text(target.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$typeLabel · ${target.chatId}'),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Symbols.more_vert_rounded),
        onSelected: (value) {
          if (value == 'remove') {
            _confirmRemove(context, ref);
          } else if (value == 'edit') {
            showTargetEditor(context, existing: target);
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'edit',
            child: Text('Rename'),
          ),
          const PopupMenuItem(
            value: 'remove',
            child: Text('Remove'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove recipient?'),
        content: Text(
          '${target.title} will no longer receive photos. You can add it '
          'back at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(targetsProvider.notifier).remove(target);
    }
  }
}

class _SendFooter extends ConsumerWidget {
  const _SendFooter({required this.fileCount, required this.targetCount});

  final int fileCount;
  final int targetCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final ready = targetCount > 0;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppDimens.s16,
          AppDimens.s8,
          AppDimens.s16,
          AppDimens.s16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: ready ? () => context.push('/picker') : null,
              icon: const Icon(Symbols.photo_library_rounded, size: 20),
              label: Text(
                fileCount == 0 ? 'Choose files' : 'Review files ($fileCount)',
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            if (!ready) ...[
              const SizedBox(height: AppDimens.s8),
              Text(
                'Add at least one recipient to start sending.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NoBotState extends StatelessWidget {
  const _NoBotState({required this.resetNotice});

  final bool resetNotice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (resetNotice) ...[
              Container(
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Symbols.warning_rounded,
                        size: 22, color: scheme.onErrorContainer),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        'The saved bot token is no longer valid — it was '
                        'regenerated or revoked in @BotFather. Connect again '
                        'with the current token.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            EmptyState(
              icon: Symbols.key_rounded,
              title: 'Bot not connected',
              message: 'Connect your Telegram bot to start sending photos, '
                  'videos and documents.',
              action: FilledButton(
                onPressed: () => context.push('/onboarding'),
                child: const Text('Connect bot'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
