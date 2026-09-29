import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/design_system/app_dimens.dart';
import '../../core/providers.dart';
import '../../core/sending/models.dart';
import '../common/widgets.dart';

/// Final confirmation: send mode, optional caption, inter-batch delay,
/// and the primary Send action. Handles photos, videos and documents.
class SendReviewScreen extends ConsumerStatefulWidget {
  const SendReviewScreen({super.key});

  @override
  ConsumerState<SendReviewScreen> createState() => _SendReviewScreenState();
}

class _SendReviewScreenState extends ConsumerState<SendReviewScreen> {
  SendMode _mode = SendMode.album;
  final _captionController = TextEditingController();
  double _delaySeconds = 1.5;

  /// Per-file sizes are computed once and reused across rebuilds (the
  /// slider fires a rebuild per tick, which used to re-stat every file).
  final _sizeCache = FileSizeCache();

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  int _bytesOf(PendingFile file) => _sizeCache.sizeOf(file.path);

  /// Files that exceed Telegram's per-type bot upload cap. Videos and
  /// documents cannot be compressed on-device, so they block the send
  /// instead of failing after a long upload.
  List<PendingFile> _oversized(List<PendingFile> files) => [
        for (final file in files)
          if (_bytesOf(file) > file.kind.maxBytes &&
              file.kind != SendKind.photo)
            file,
      ];

  Future<void> _send() async {
    final files = ref.read(pendingFilesProvider);
    final targets = ref.read(targetsProvider);
    if (files.isEmpty || targets.isEmpty) return;

    final config = SendSessionConfig(
      targets: [
        for (final t in targets) SendTarget(chatId: t.chatId, title: t.title),
      ],
      filePaths: [for (final f in files) f.path],
      fileKinds: [for (final f in files) f.kind],
      mode: _mode,
      caption: _captionController.text.trim().isEmpty
          ? null
          : _captionController.text.trim(),
      extraDelay: Duration(milliseconds: (_delaySeconds * 1000).round()),
    );

    final messenger = ScaffoldMessenger.of(context);
    await ref.read(sendProvider.notifier).start(config);
    ref.read(historyProvider.notifier).refresh();
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    context.push('/progress');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final files = ref.watch(pendingFilesProvider);
    final targets = ref.watch(targetsProvider);
    final send = ref.watch(sendProvider);
    final totalBytes = _sizeCache.totalOf([for (final f in files) f.path]);

    final photoCount = files.where((f) => f.kind == SendKind.photo).length;
    final videoCount = files.where((f) => f.kind == SendKind.video).length;
    final docCount = files.where((f) => f.kind == SendKind.document).length;
    final mediaCount = photoCount + videoCount;
    final oversized = _oversized(files);
    final hasMedia = mediaCount > 0;

    final captionLabel = _mode == SendMode.album
        ? 'Caption (applied once per album)'
        : 'Caption (applied to every file)';

    return Scaffold(
      appBar: AppBar(title: const Text('Review send')),
      body: files.isEmpty || targets.isEmpty
          ? EmptyState(
              icon: Symbols.warning_rounded,
              title: files.isEmpty ? 'No files selected' : 'No recipients',
              message: files.isEmpty
                  ? 'Go back and pick the photos, videos or documents you '
                      'want to send.'
                  : 'Add at least one recipient from the home screen first.',
              action: FilledButton(
                onPressed: () =>
                    context.go(files.isEmpty ? '/picker' : '/'),
                child: Text(files.isEmpty ? 'Select files' : 'Add recipients'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: AppDimens.s24),
              children: [
                Section(
                  title: 'Recipients',
                  subtitle:
                      '${targets.length} recipient${targets.length == 1 ? '' : 's'} will receive the files.',
                  child: Wrap(
                    spacing: AppDimens.s8,
                    runSpacing: AppDimens.s8,
                    children: [
                      for (final target in targets)
                        Chip(
                          avatar: Icon(
                            target.isChannel
                                ? Symbols.campaign_rounded
                                : (target.isGroup
                                    ? Symbols.group_rounded
                                    : Symbols.person_rounded),
                            size: 16,
                          ),
                          label: Text(target.title),
                          labelStyle: theme.textTheme.labelMedium,
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: AppDimens.s20),
                Section(
                  title: 'Send mode',
                  child: Column(
                    children: [
                      _ModeCard(
                        selected: _mode == SendMode.album,
                        icon: Symbols.photo_library_rounded,
                        title: 'Album',
                        description: hasMedia
                            ? 'Groups of up to 10 photos and videos per '
                                'message. Documents are sent as separate '
                                'messages. Faster and less noisy.'
                            : 'Documents are always sent as individual '
                                'messages — Telegram does not allow them in '
                                'albums.',
                        onTap: () => setState(() => _mode = SendMode.album),
                      ),
                      const SizedBox(height: AppDimens.s8),
                      _ModeCard(
                        selected: _mode == SendMode.individual,
                        icon: Symbols.photo_rounded,
                        title: 'Individual files',
                        description:
                            'One message per file. Better when you want each '
                            'item to stand alone.',
                        onTap: () =>
                            setState(() => _mode = SendMode.individual),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppDimens.s20),
                Section(
                  title: 'Caption',
                  subtitle: 'Optional. Up to 1024 characters.',
                  child: TextField(
                    controller: _captionController,
                    maxLength: 1024,
                    minLines: 2,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: captionLabel,
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(height: AppDimens.s20),
                Section(
                  title: 'Pacing',
                  subtitle:
                      'Extra wait between batches. Telegram rate limits are '
                      'handled automatically either way.',
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Slider(
                              value: _delaySeconds,
                              min: 0,
                              max: 10,
                              divisions: 20,
                              label:
                                  '${_delaySeconds.toStringAsFixed(_delaySeconds.truncateToDouble() == _delaySeconds ? 0 : 1)} s',
                              onChanged: (value) =>
                                  setState(() => _delaySeconds = value),
                            ),
                          ),
                          SizedBox(
                            width: 56,
                            child: Text(
                              '${_delaySeconds.toStringAsFixed(_delaySeconds.truncateToDouble() == _delaySeconds ? 0 : 1)} s',
                              textAlign: TextAlign.end,
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppDimens.s20),
                Section(
                  title: 'Summary',
                  child: Container(
                    padding: const EdgeInsets.all(AppDimens.s16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius:
                          BorderRadius.circular(AppDimens.radiusLg),
                    ),
                    child: Column(
                      children: [
                        _SummaryRow(
                          icon: Symbols.image_rounded,
                          label: 'Photos',
                          value: '$photoCount',
                        ),
                        const SizedBox(height: AppDimens.s8),
                        _SummaryRow(
                          icon: Symbols.videocam_rounded,
                          label: 'Videos',
                          value: '$videoCount',
                        ),
                        const SizedBox(height: AppDimens.s8),
                        _SummaryRow(
                          icon: Symbols.description_rounded,
                          label: 'Documents',
                          value: '$docCount',
                        ),
                        const SizedBox(height: AppDimens.s8),
                        _SummaryRow(
                          icon: Symbols.database_rounded,
                          label: 'Total size',
                          value: formatBytes(totalBytes),
                        ),
                        const SizedBox(height: AppDimens.s8),
                        _SummaryRow(
                          icon: Symbols.send_rounded,
                          label: 'Messages',
                          value: _messageCountLabel(mediaCount, docCount,
                              targets.length),
                        ),
                        const SizedBox(height: AppDimens.s8),
                        _SummaryRow(
                          icon: Symbols.schedule_rounded,
                          label: 'Estimated time',
                          value: _estimate(mediaCount, docCount,
                              targets.length),
                        ),
                      ],
                    ),
                  ),
                ),
                if (oversized.isNotEmpty) ...[
                  const SizedBox(height: AppDimens.s16),
                  _OversizedWarning(files: oversized, bytesOf: _bytesOf),
                ],
              ],
            ),
      bottomNavigationBar: files.isEmpty || targets.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppDimens.s16,
                  AppDimens.s8,
                  AppDimens.s16,
                  AppDimens.s16,
                ),
                child: FilledButton.icon(
                  onPressed: oversized.isNotEmpty ||
                          send.starting ||
                          send.running
                      ? null
                      : _send,
                  icon: send.starting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Symbols.send_rounded, size: 20),
                  label: Text(
                    oversized.isNotEmpty
                        ? 'Remove oversized files to continue'
                        : 'Send ${files.length} file${files.length == 1 ? '' : 's'} '
                            'to ${targets.length} recipient${targets.length == 1 ? '' : 's'}',
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),
            ),
    );
  }

  String _messageCountLabel(int mediaCount, int docCount, int targetCount) {
    if (_mode == SendMode.individual) {
      final total = (mediaCount + docCount) * targetCount;
      return '$total (one per file)';
    }
    final albums =
        (mediaCount + SendSessionConfig.albumMax - 1) ~/ SendSessionConfig.albumMax;
    return '${albums * targetCount + docCount * targetCount} '
        '(albums of up to 10 + documents)';
  }

  String _estimate(int mediaCount, int docCount, int targetCount) {
    // Rough estimate: 3 s per API batch + configured pacing. Documents and
    // videos upload slower; weight them ~2x a photo batch.
    final batches = _mode == SendMode.individual
        ? mediaCount + docCount * 2
        : ((mediaCount + SendSessionConfig.albumMax - 1) ~/
                SendSessionConfig.albumMax) +
            docCount * 2;
    final perTarget = batches * (3 + _delaySeconds);
    final seconds = (perTarget * targetCount).round();
    if (seconds < 60) return 'about $seconds s';
    return 'about ${(seconds / 60).ceil()} min';
  }
}

class _OversizedWarning extends StatelessWidget {
  const _OversizedWarning({required this.files, required this.bytesOf});

  final List<PendingFile> files;
  final int Function(PendingFile) bytesOf;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppDimens.s16),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(AppDimens.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Symbols.error_rounded, size: 20, color: scheme.onErrorContainer),
              const SizedBox(width: AppDimens.s8),
              Expanded(
                child: Text(
                  'Files too large for Telegram bots',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.s8),
          for (final file in files)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '${file.path.split('/').last} — ${formatBytes(bytesOf(file))} '
                '(max ${formatBytes(file.kind.maxBytes)})',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
          const SizedBox(height: AppDimens.s4),
          Text(
            'Remove these files on the previous screen, or compress them '
            'first. Photos are compressed automatically.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppDimens.radiusLg),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? AppDimens.borderThick : AppDimens.borderThin,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppDimens.radiusLg),
        child: Padding(
          padding: const EdgeInsets.all(AppDimens.s16),
          child: Row(
            children: [
              Icon(
                icon,
                size: 24,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppDimens.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: selected
                            ? scheme.onPrimaryContainer
                            : scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: selected
                            ? scheme.onPrimaryContainer.withValues(alpha: 0.8)
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                selected
                    ? Symbols.check_circle_rounded
                    : Symbols.radio_button_unchecked_rounded,
                size: 20,
                color: selected ? scheme.primary : scheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: AppDimens.s8),
        Text(label, style: theme.textTheme.bodyMedium),
        const Spacer(),
        Text(value, style: theme.textTheme.titleSmall),
      ],
    );
  }
}
