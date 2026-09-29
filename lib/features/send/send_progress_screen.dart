import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/design_system/app_dimens.dart';
import '../../core/design_system/app_theme.dart';
import '../../core/providers.dart';
import '../../core/sending/models.dart';
import '../common/widgets.dart';

/// Live progress for the running (or last) bulk send: overall bar,
/// per-photo status, pause/resume/cancel, and retry of failed photos.
class SendProgressScreen extends ConsumerStatefulWidget {
  const SendProgressScreen({super.key});

  @override
  ConsumerState<SendProgressScreen> createState() =>
      _SendProgressScreenState();
}

class _SendProgressScreenState extends ConsumerState<SendProgressScreen> {
  @override
  void initState() {
    super.initState();
    // Make sure we are listening even if the user navigated here directly.
    ref.read(sendProvider.notifier).reattach();
  }

  Future<void> _retryFailed() async {
    final controller = ref.read(sendProvider.notifier);
    final config = controller.buildRetryConfig();
    if (config == null) return;
    controller.clearFinished();
    await controller.start(config);
    ref.read(historyProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppTheme.tokensOf(context);
    final send = ref.watch(sendProvider);
    final snapshot = send.snapshot;

    if (snapshot == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Sending')),
        body: const EmptyState(
          icon: Symbols.send_rounded,
          title: 'Nothing in progress',
          message: 'Start a send from the review screen to see live progress '
              'here.',
          action: Text('Start a new send from Home'),
        ),
      );
    }

    final done = snapshot.doneCount;
    final total = snapshot.total;
    final finished =
        snapshot.phase == SendPhase.finished ||
            snapshot.phase == SendPhase.canceled;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sending'),
        automaticallyImplyLeading: false,
        actions: [
          if (finished)
            IconButton(
              tooltip: 'Close',
              onPressed: () {
                ref.read(sendProvider.notifier).clearFinished();
                ref.read(pendingFilesProvider.notifier).clear();
                context.go('/');
              },
              icon: const Icon(Symbols.close_rounded),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppDimens.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        finished
                            ? (snapshot.phase == SendPhase.canceled
                                ? 'Canceled — $done of $total processed'
                                : 'Done — $done of $total processed')
                            : (snapshot.waitingMessage ?? 'Sending…'),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    Text(
                      '$done/$total',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppDimens.s12),
                ClipRRect(
                  borderRadius:
                      BorderRadius.circular(AppDimens.radiusFull),
                  child: LinearProgressIndicator(
                    value: snapshot.progress,
                    minHeight: 8,
                  ),
                ),
                const SizedBox(height: AppDimens.s12),
                Row(
                  children: [
                    _StatusChip(
                      icon: Symbols.check_circle_rounded,
                      label: '${snapshot.successCount} sent',
                      color: tokens.successContainer,
                      textColor: tokens.onSuccessContainer,
                    ),
                    const SizedBox(width: AppDimens.s8),
                    if (snapshot.failedCount > 0)
                      _StatusChip(
                        icon: Symbols.error_rounded,
                        label: '${snapshot.failedCount} failed',
                        color: theme.colorScheme.errorContainer,
                        textColor: theme.colorScheme.onErrorContainer,
                      ),
                    const SizedBox(width: AppDimens.s8),
                    _StatusChip(
                      icon: Symbols.schedule_rounded,
                      label: '${total - done} remaining',
                      color: theme.colorScheme.surfaceContainerHigh,
                      textColor: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: AppDimens.s16),
              itemCount: total,
              separatorBuilder: (_, _) => const SizedBox(height: AppDimens.s8),
              itemBuilder: (context, index) {
                final item = snapshot.items[index];
                return _ItemRow(item: item, index: index);
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppDimens.s16),
              child: _Controls(
                finished: finished,
                phase: snapshot.phase,
                onRetryFailed: snapshot.failedCount > 0 ? _retryFailed : null,
                failedCount: snapshot.failedCount,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends ConsumerWidget {
  const _Controls({
    required this.finished,
    required this.phase,
    required this.onRetryFailed,
    required this.failedCount,
  });

  final bool finished;
  final SendPhase phase;
  final VoidCallback? onRetryFailed;
  final int failedCount;

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    ref.read(sendProvider.notifier).cancel();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (finished) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (failedCount > 0)
            FilledButton.icon(
              onPressed: onRetryFailed,
              icon: const Icon(Symbols.refresh_rounded, size: 20),
              label: Text('Retry failed ($failedCount)'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          TextButton(
            onPressed: () {
              ref.read(sendProvider.notifier).clearFinished();
              ref.read(pendingFilesProvider.notifier).clear();
              context.go('/');
            },
            child: const Text('Back to home'),
          ),
        ],
      );
    }

    final paused = phase == SendPhase.paused;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () {
              final controller = ref.read(sendProvider.notifier);
              if (paused) {
                controller.resume();
              } else {
                controller.pause();
              }
            },
            icon: Icon(
              paused
                  ? Symbols.play_arrow_rounded
                  : Symbols.pause_rounded,
              size: 20,
            ),
            label: Text(paused ? 'Resume' : 'Pause'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ),
        const SizedBox(width: AppDimens.s12),
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: () => _cancel(context, ref),
            icon: const Icon(Symbols.stop_rounded, size: 20),
            label: const Text('Cancel'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor:
                  Theme.of(context).colorScheme.errorContainer,
              foregroundColor:
                  Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    required this.color,
    required this.textColor,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.s12,
        vertical: AppDimens.s4,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppDimens.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: textColor),
          const SizedBox(width: AppDimens.s4),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: textColor, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.index});

  final SendItemState item;
  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppTheme.tokensOf(context);

    final (icon, color, statusText) = switch (item.status) {
      SendItemStatus.pending => (
          Symbols.schedule_rounded,
          theme.colorScheme.onSurfaceVariant,
          'Queued',
        ),
      SendItemStatus.preparing => (
          Symbols.progress_activity,
          theme.colorScheme.primary,
          'Preparing',
        ),
      SendItemStatus.sending => (
          Symbols.progress_activity,
          theme.colorScheme.primary,
          'Sending',
      ),
      SendItemStatus.waiting => (
          Symbols.hourglass_rounded,
          tokens.warning,
          'Waiting',
        ),
      SendItemStatus.success => (
          Symbols.check_circle_rounded,
          tokens.success,
          'Sent',
        ),
      SendItemStatus.failed => (
          Symbols.error_rounded,
          theme.colorScheme.error,
          'Failed',
        ),
      SendItemStatus.canceled => (
          Symbols.cancel_rounded,
          theme.colorScheme.outline,
          'Canceled',
        ),
    };

    // Kind-aware row title: "Photo 3", "Video 2", or the document name.
    final title = item.kind == SendKind.document
        ? '${item.path.split('/').last} · ${item.targetTitle}'
        : '${item.kind.label} ${item.photoIndex} · ${item.targetTitle}';

    return Container(
      padding: const EdgeInsets.all(AppDimens.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppDimens.radiusMd),
      ),
      child: Row(
        children: [
          _KindThumbnail(path: item.path, kind: item.kind),
          const SizedBox(width: AppDimens.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                if (item.error != null)
                  Text(
                    item.error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppDimens.s8),
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppDimens.s4),
          Text(
            statusText,
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

/// Thumbnail by kind: photo preview, play badge for videos, file icon for
/// documents.
class _KindThumbnail extends StatelessWidget {
  const _KindThumbnail({required this.path, required this.kind});

  final String path;
  final SendKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget child;
    switch (kind) {
      case SendKind.photo:
        child = Image.file(
          File(path),
          fit: BoxFit.cover,
          cacheWidth: 96,
          errorBuilder: (_, _, _) => Container(
            color: scheme.surfaceContainerHigh,
            child: Icon(
              Symbols.broken_image_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ),
        );
      case SendKind.video:
        child = Container(
          color: scheme.surfaceContainerHigh,
          child: Icon(
            Symbols.play_circle_rounded,
            size: 24,
            color: scheme.onSurfaceVariant,
          ),
        );
      case SendKind.document:
        child = Container(
          color: scheme.surfaceContainerHigh,
          child: Icon(
            Symbols.description_rounded,
            size: 24,
            color: scheme.onSurfaceVariant,
          ),
        );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppDimens.radiusSm),
      child: SizedBox(width: 48, height: 48, child: child),
    );
  }
}
