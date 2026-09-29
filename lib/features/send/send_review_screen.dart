import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/design_system/app_dimens.dart';
import '../../core/providers.dart';
import '../../core/sending/models.dart';
import '../common/widgets.dart';

/// Final confirmation: send mode, optional caption, inter-batch delay,
/// and the primary Send action.
class SendReviewScreen extends ConsumerStatefulWidget {
  const SendReviewScreen({super.key});

  @override
  ConsumerState<SendReviewScreen> createState() => _SendReviewScreenState();
}

class _SendReviewScreenState extends ConsumerState<SendReviewScreen> {
  SendMode _mode = SendMode.album;
  final _captionController = TextEditingController();
  double _delaySeconds = 1.5;

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final photos = ref.read(pendingPhotosProvider);
    final targets = ref.read(targetsProvider);
    if (photos.isEmpty || targets.isEmpty) return;

    final config = SendSessionConfig(
      targets: [
        for (final t in targets) SendTarget(chatId: t.chatId, title: t.title),
      ],
      filePaths: photos,
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
    final photos = ref.watch(pendingPhotosProvider);
    final targets = ref.watch(targetsProvider);
    final send = ref.watch(sendProvider);
    final totalBytes = directoryBytes(photos);

    final captionLabel = _mode == SendMode.album
        ? 'Caption (applied once per album)'
        : 'Caption (applied to every photo)';

    return Scaffold(
      appBar: AppBar(title: const Text('Review send')),
      body: photos.isEmpty || targets.isEmpty
          ? EmptyState(
              icon: Symbols.warning_rounded,
              title: photos.isEmpty ? 'No photos selected' : 'No recipients',
              message: photos.isEmpty
                  ? 'Go back and pick the photos you want to send.'
                  : 'Add at least one recipient from the home screen first.',
              action: FilledButton(
                onPressed: () =>
                    context.go(photos.isEmpty ? '/picker' : '/'),
                child: Text(photos.isEmpty ? 'Select photos' : 'Add recipients'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: AppDimens.s24),
              children: [
                Section(
                  title: 'Recipients',
                  subtitle:
                      '${targets.length} recipient${targets.length == 1 ? '' : 's'} will receive the photos.',
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
                        description:
                            'Groups of up to 10 photos per message. Faster '
                            'and less noisy in the chat.',
                        onTap: () => setState(() => _mode = SendMode.album),
                      ),
                      const SizedBox(height: AppDimens.s8),
                      _ModeCard(
                        selected: _mode == SendMode.individual,
                        icon: Symbols.photo_rounded,
                        title: 'Individual photos',
                        description:
                            'One message per photo. Better when you want each '
                            'photo to stand alone.',
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
                          icon: Symbols.photo_rounded,
                          label: 'Photos',
                          value:
                              '${photos.length} · ${formatBytes(totalBytes)}',
                        ),
                        const SizedBox(height: AppDimens.s8),
                        _SummaryRow(
                          icon: Symbols.send_rounded,
                          label: 'Messages',
                          value: _messageCountLabel(photos.length, targets.length),
                        ),
                        const SizedBox(height: AppDimens.s8),
                        _SummaryRow(
                          icon: Symbols.schedule_rounded,
                          label: 'Estimated time',
                          value: _estimate(photos.length, targets.length),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: photos.isEmpty || targets.isEmpty
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
                  onPressed:
                      send.starting || send.running ? null : _send,
                  icon: send.starting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Symbols.send_rounded, size: 20),
                  label: Text(
                    'Send ${photos.length} photo${photos.length == 1 ? '' : 's'} '
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

  String _messageCountLabel(int photoCount, int targetCount) {
    if (_mode == SendMode.individual) {
      return '${photoCount * targetCount} (one per photo)';
    }
    final albums =
        (photoCount + SendSessionConfig.albumMax - 1) ~/ SendSessionConfig.albumMax;
    return '${albums * targetCount} (albums of up to 10)';
  }

  String _estimate(int photoCount, int targetCount) {
    // Rough estimate: 3 s per API batch + configured pacing.
    final batches = _mode == SendMode.individual
        ? photoCount
        : (photoCount + SendSessionConfig.albumMax - 1) ~/ SendSessionConfig.albumMax;
    final perTarget = batches * (3 + _delaySeconds);
    final seconds = (perTarget * targetCount).round();
    if (seconds < 60) return 'about $seconds s';
    return 'about ${(seconds / 60).ceil()} min';
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
