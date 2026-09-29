import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/design_system/app_dimens.dart';
import '../../core/providers.dart';
import '../common/widgets.dart';

/// Multi-select photos via the system Photo Picker, preview as a grid,
/// reorder by long-press drag, remove, and continue to review.
class PhotoPickerScreen extends ConsumerStatefulWidget {
  const PhotoPickerScreen({super.key});

  @override
  ConsumerState<PhotoPickerScreen> createState() => _PhotoPickerScreenState();
}

class _PhotoPickerScreenState extends ConsumerState<PhotoPickerScreen> {
  bool _picking = false;

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final picker = ImagePicker();
      final images = await picker.pickMultiImage();
      ref.read(pendingPhotosProvider.notifier).addAll(
            [for (final image in images) image.path],
          );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final photos = ref.watch(pendingPhotosProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select photos'),
        actions: [
          if (photos.isNotEmpty)
            TextButton(
              onPressed: () =>
                  ref.read(pendingPhotosProvider.notifier).clear(),
              child: const Text('Clear all'),
            ),
          const SizedBox(width: AppDimens.s8),
        ],
      ),
      body: photos.isEmpty
          ? EmptyState(
              icon: Symbols.add_photo_alternate_rounded,
              title: 'No photos selected',
              message:
                  'Photos are picked with the Android Photo Picker — no media '
                  'permission needed, and nothing leaves your device until '
                  'you send.',
              action: FilledButton.icon(
                onPressed: _picking ? null : _pick,
                icon: const Icon(Symbols.add_rounded, size: 20),
                label: const Text('Select photos'),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ReorderablePhotoGrid(
                    paths: photos,
                    onRemove: (index) =>
                        ref.read(pendingPhotosProvider.notifier).removeAt(index),
                    onReorder: (oldIndex, newIndex) => ref
                        .read(pendingPhotosProvider.notifier)
                        .reorder(oldIndex: oldIndex, newIndex: newIndex),
                  ),
                ),
                _BottomBar(
                  count: photos.length,
                  totalBytes: directoryBytes(photos),
                  onAddMore: _picking ? null : _pick,
                  adding: _picking,
                  onContinue: () => context.push('/review'),
                ),
              ],
            ),
    );
  }
}

/// Grid with long-press drag reordering (built on DragTarget/Draggable).
class ReorderablePhotoGrid extends StatelessWidget {
  const ReorderablePhotoGrid({
    super.key,
    required this.paths,
    required this.onRemove,
    required this.onReorder,
  });

  final List<String> paths;
  final void Function(int index) onRemove;
  final void Function(int oldIndex, int newIndex) onReorder;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(AppDimens.s16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: AppDimens.s8,
        crossAxisSpacing: AppDimens.s8,
      ),
      itemCount: paths.length,
      itemBuilder: (context, index) {
        return _DragTile(
          key: ValueKey('photo-${paths[index]}-$index'),
          index: index,
          path: paths[index],
          onRemove: onRemove,
          onAccept: (from) {
            if (from != index) onReorder(from, index);
          },
        );
      },
    );
  }
}

class _DragTile extends StatelessWidget {
  const _DragTile({
    super.key,
    required this.index,
    required this.path,
    required this.onRemove,
    required this.onAccept,
  });

  final int index;
  final String path;
  final void Function(int index) onRemove;
  final void Function(int fromIndex) onAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LongPressDraggable<int>(
      data: index,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _TileImage(path: path, dimmed: false),
      childWhenDragging: _TileImage(path: path, dimmed: true),
      child: DragTarget<int>(
        onWillAcceptWithDetails: (details) => details.data != index,
        onAcceptWithDetails: (details) => onAccept(details.data),
        builder: (context, candidates, rejected) {
          final highlighted = candidates.isNotEmpty;
          return Stack(
            children: [
              Positioned.fill(
                child: Container(
                  foregroundDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppDimens.radiusMd),
                    border: highlighted
                        ? Border.all(
                            color: theme.colorScheme.primary,
                            width: AppDimens.borderThick,
                          )
                        : null,
                  ),
                  child: _TileImage(path: path, dimmed: false),
                ),
              ),
              // Order badge.
              Positioned(
                left: AppDimens.s4,
                top: AppDimens.s4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppDimens.s8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.inverseSurface.withValues(alpha: 0.85),
                    borderRadius:
                        BorderRadius.circular(AppDimens.radiusFull),
                  ),
                  child: Text(
                    '${index + 1}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onInverseSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              // Remove button.
              Positioned(
                right: 0,
                top: 0,
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    tooltip: 'Remove',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    onPressed: () => onRemove(index),
                    icon: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.inverseSurface
                            .withValues(alpha: 0.85),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Symbols.close_rounded,
                        size: 14,
                        color: theme.colorScheme.onInverseSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TileImage extends StatelessWidget {
  const _TileImage({required this.path, required this.dimmed});

  final String path;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppDimens.radiusMd),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(path),
            fit: BoxFit.cover,
            cacheWidth: 240,
            errorBuilder: (_, _, _) => Container(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              child: Icon(
                Symbols.broken_image_rounded,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (dimmed)
            ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerLowest
                  .withValues(alpha: 0.6),
            ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.count,
    required this.totalBytes,
    required this.onAddMore,
    required this.adding,
    required this.onContinue,
  });

  final int count;
  final int totalBytes;
  final VoidCallback? onAddMore;
  final bool adding;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppDimens.s16,
          AppDimens.s8,
          AppDimens.s16,
          AppDimens.s16,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$count photo${count == 1 ? '' : 's'} · ${formatBytes(totalBytes)}',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Sent in this order. Long-press to drag.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppDimens.s12),
            OutlinedButton.icon(
              onPressed: onAddMore,
              icon: adding
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Symbols.add_rounded, size: 18),
              label: const Text('Add'),
            ),
            const SizedBox(width: AppDimens.s8),
            FilledButton(
              onPressed: onContinue,
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}
