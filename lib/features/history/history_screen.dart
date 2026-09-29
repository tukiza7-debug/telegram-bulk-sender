import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/design_system/app_dimens.dart';
import '../../core/design_system/app_theme.dart';
import '../../core/sending/models.dart';
import '../../core/providers.dart';
import '../common/widgets.dart';

/// Ringkas history of past sending sessions.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(historyProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          if (entries.isNotEmpty)
            IconButton(
              tooltip: 'Clear history',
              icon: const Icon(Symbols.delete_rounded),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Clear history?'),
                    content: const Text(
                      'This removes the record of past sends. Your photos and '
                      'recipients are not affected.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await ref.read(historyProvider.notifier).clear();
                }
              },
            ),
          const SizedBox(width: AppDimens.s8),
        ],
      ),
      body: entries.isEmpty
          ? const EmptyState(
              icon: Symbols.history_rounded,
              title: 'No sends yet',
              message: 'Completed bulk sends will be listed here with their '
                  'success and failure counts.',
            )
          : ListView.separated(
              padding: const EdgeInsets.all(AppDimens.s16),
              itemCount: entries.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(height: AppDimens.s8),
              itemBuilder: (context, index) {
                final entry = entries[index];
                return _HistoryTile(entry: entry);
              },
            ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final started =
        DateTime.fromMillisecondsSinceEpoch(entry.startedAtMs);
    final dateLabel =
        DateFormat('d MMM yyyy · HH:mm').format(started);

    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(
          horizontal: AppDimens.s16,
          vertical: AppDimens.s4,
        ),
        leading: CircleAvatar(
          radius: 20,
          backgroundColor: theme.colorScheme.secondaryContainer,
          foregroundColor: theme.colorScheme.onSecondaryContainer,
          child: Icon(
            entry.mode == SendMode.album
                ? Symbols.photo_library_rounded
                : Symbols.photo_rounded,
            size: 20,
          ),
        ),
        title: Text(
          entry.targetTitles.isEmpty
              ? 'No recipients'
              : entry.targetTitles.join(', '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(dateLabel),
        trailing: _Counts(entry: entry),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            entry.errors.isEmpty
                ? 'All photos were sent successfully.'
                : 'Errors reported by Telegram:',
            style: theme.textTheme.bodySmall,
          ),
          if (entry.errors.isNotEmpty) ...[
            const SizedBox(height: AppDimens.s8),
            for (final error in entry.errors.take(10))
              Text(
                '• $error',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            if (entry.errors.length > 10)
              Text(
                '…and ${entry.errors.length - 10} more.',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ],
      ),
    );
  }
}

class _Counts extends StatelessWidget {
  const _Counts({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.tokensOf(context);
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Symbols.check_circle_rounded, size: 16, color: tokens.success),
        const SizedBox(width: AppDimens.s4),
        Text('${entry.success}', style: theme.textTheme.labelMedium),
        if (entry.failed > 0) ...[
          const SizedBox(width: AppDimens.s8),
          Icon(
            Symbols.error_rounded,
            size: 16,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: AppDimens.s4),
          Text('${entry.failed}', style: theme.textTheme.labelMedium),
        ],
      ],
    );
  }
}
