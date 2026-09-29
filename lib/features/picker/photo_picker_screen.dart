import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/design_system/app_dimens.dart';
import '../../core/providers.dart';
import '../../core/sending/models.dart';
import '../common/widgets.dart';

/// Multi-select photos, videos and documents.
///  - Photos: system Photo Picker via image_picker (no permission needed).
///  - Videos: system file picker (SAF, no permission needed), multi-select.
///  - Documents: system file picker (SAF, no permission needed), multi-select.
/// Preview as a grid, reorder by long-press drag, remove, and continue.
class PhotoPickerScreen extends ConsumerStatefulWidget {
  const PhotoPickerScreen({super.key});

  @override
  ConsumerState<PhotoPickerScreen> createState() => _PhotoPickerScreenState();
}

class _PhotoPickerScreenState extends ConsumerState<PhotoPickerScreen> {
  bool _picking = false;

  /// Per-file sizes are computed once and reused across rebuilds.
  final _sizeCache = FileSizeCache();

  bool get _busy => _picking;

  Future<void> _pickPhotos() => _runPick(() async {
        final picker = ImagePicker();
        final images = await picker.pickMultiImage();
        ref.read(pendingFilesProvider.notifier).addAll([
          for (final image in images) PendingFile(path: image.path, kind: SendKind.photo),
        ]);
      });

  Future<void> _pickVideos() => _runPick(() async {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.video,
          allowMultiple: true,
        );
        final files = result?.files
            .where((f) => f.path != null)
            .map((f) => PendingFile(path: f.path!, kind: SendKind.video))
            .toList();
        if (files != null && files.isNotEmpty) {
          ref.read(pendingFilesProvider.notifier).addAll(files);
        }
      });

  Future<void> _pickDocuments() => _runPick(() async {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.any,
          allowMultiple: true,
        );
        final files = result?.files
            .where((f) => f.path != null)
            .map((f) => PendingFile(path: f.path!, kind: SendKind.document))
            .toList();
        if (files != null && files.isNotEmpty) {
          ref.read(pendingFilesProvider.notifier).addAll(files);
        }
      });

  Future<void> _runPick(Future<void> Function() pick) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      await pick();
    } on Exception catch (e) {
      // A user cancel returns null/empty instead of throwing, so anything
      // reaching here is a real failure — tell the user instead of
      // silently ignoring it.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not open the file picker. Please try again. (${e.runtimeType})',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = ref.watch(pendingFilesProvider);
    final photoCount = files.where((f) => f.kind == SendKind.photo).length;
    final videoCount = files.where((f) => f.kind == SendKind.video).length;
    final docCount = files.where((f) => f.kind == SendKind.document).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select files'),
        actions: [
          if (files.isNotEmpty)
            TextButton(
              onPressed: () => ref.read(pendingFilesProvider.notifier).clear(),
              child: const Text('Clear all'),
            ),
          const SizedBox(width: AppDimens.s8),
        ],
      ),
      body: files.isEmpty
          ? EmptyState(
              icon: Symbols.add_photo_alternate_rounded,
              title: 'No files selected',
              message:
                  'Pick photos, videos and documents with the system picker — '
                  'no media permission needed, and nothing leaves your device '
                  'until you send.',
              action: FilledButton.icon(
                onPressed: _busy ? null : _pickPhotos,
                icon: const Icon(Symbols.add_rounded, size: 20),
                label: const Text('Select photos'),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ReorderableFileGrid(
                    files: files,
                    onRemove: (index) =>
                        ref.read(pendingFilesProvider.notifier).removeAt(index),
                    onReorder: (oldIndex, newIndex) => ref
                        .read(pendingFilesProvider.notifier)
                        .reorder(oldIndex: oldIndex, newIndex: newIndex),
                  ),
                ),
                _BottomBar(
                  count: files.length,
                  photoCount: photoCount,
                  videoCount: videoCount,
                  docCount: docCount,
                  totalBytes: _sizeCache
                      .totalOf([for (final f in files) f.path]),
                  onAddMore: _busy ? null : _showAddSheet,
                  adding: _picking,
                  onContinue: () => context.push('/review'),
                ),
              ],
            ),
    );
  }

  void _showAddSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppDimens.s8),
            ListTile(
              leading: const Icon(Symbols.image_rounded),
              title: const Text('Photos'),
              subtitle: const Text('JPG, PNG, WebP, HEIC — Photo Picker'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickPhotos();
              },
            ),
            ListTile(
              leading: const Icon(Symbols.videocam_rounded),
              title: const Text('Videos'),
              subtitle: const Text('MP4, MOV, MKV, WebM — max 50 MB each'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickVideos();
              },
            ),
            ListTile(
              leading: const Icon(Symbols.description_rounded),
              title: const Text('Documents'),
              subtitle: const Text('PDF, ZIP, GIF, audio, any file — max 50 MB'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickDocuments();
              },
            ),
            const SizedBox(height: AppDimens.s8),
          ],
        ),
      ),
    );
  }
}

/// Grid with long-press drag reordering (built on DragTarget/Draggable).
class ReorderableFileGrid extends StatelessWidget {
  const ReorderableFileGrid({
    super.key,
    required this.files,
    required this.onRemove,
    required this.onReorder,
  });

  final List<PendingFile> files;
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
        childAspectRatio: 0.85,
      ),
      itemCount: files.length,
      itemBuilder: (context, index) {
        return _DragTile(
          key: ValueKey('file-${files[index].path}-$index'),
          index: index,
          file: files[index],
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
    required this.file,
    required this.onRemove,
    required this.onAccept,
  });

  final int index;
  final PendingFile file;
  final void Function(int index) onRemove;
  final void Function(int fromIndex) onAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LongPressDraggable<int>(
      data: index,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _TileContent(file: file, dimmed: false),
      childWhenDragging: _TileContent(file: file, dimmed: true),
      child: DragTarget<int>(
        onWillAcceptWithDetails: (details) => details.data != index,
        onAcceptWithDetails: (details) => onAccept(details.data),
        builder: (context, candidates, rejected) {
          final highlighted = candidates.isNotEmpty;
          return Stack(
            clipBehavior: Clip.none,
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
                  child: _TileContent(file: file, dimmed: false),
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
              // Kind badge.
              if (file.kind != SendKind.photo)
                Positioned(
                  left: AppDimens.s4,
                  bottom: AppDimens.s4,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.inverseSurface.withValues(alpha: 0.85),
                      borderRadius:
                          BorderRadius.circular(AppDimens.radiusSm),
                    ),
                    child: Icon(
                      file.kind == SendKind.video
                          ? Symbols.videocam_rounded
                          : Symbols.description_rounded,
                      size: 12,
                      color: theme.colorScheme.onInverseSurface,
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

class _TileContent extends StatelessWidget {
  const _TileContent({required this.file, required this.dimmed});

  final PendingFile file;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(AppDimens.radiusMd);

    final child = switch (file.kind) {
      SendKind.photo => Image.file(
          File(file.path),
          fit: BoxFit.cover,
          cacheWidth: 240,
          errorBuilder: (_, _, _) => Container(
            color: scheme.surfaceContainerHigh,
            child: Icon(
              Symbols.broken_image_rounded,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      SendKind.video => Container(
          color: scheme.surfaceContainerHigh,
          child: Center(
            child: Icon(
              Symbols.play_circle_rounded,
              size: 32,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      SendKind.document => _DocumentTileContent(path: file.path),
    };

    return ClipRRect(
      borderRadius: radius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          if (dimmed)
            ColoredBox(
              color: scheme.surfaceContainerLowest.withValues(alpha: 0.6),
            ),
        ],
      ),
    );
  }
}

class _DocumentTileContent extends StatelessWidget {
  const _DocumentTileContent({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = path.split('/').last;
    return Container(
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.all(AppDimens.s8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Symbols.description_rounded,
            size: 28,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: AppDimens.s4),
          Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.count,
    required this.photoCount,
    required this.videoCount,
    required this.docCount,
    required this.totalBytes,
    required this.onAddMore,
    required this.adding,
    required this.onContinue,
  });

  final int count;
  final int photoCount;
  final int videoCount;
  final int docCount;
  final int totalBytes;
  final VoidCallback? onAddMore;
  final bool adding;
  final VoidCallback onContinue;

  String get _breakdown {
    final parts = <String>[
      if (photoCount > 0) '$photoCount photo${photoCount == 1 ? '' : 's'}',
      if (videoCount > 0) '$videoCount video${videoCount == 1 ? '' : 's'}',
      if (docCount > 0) '$docCount document${docCount == 1 ? '' : 's'}',
    ];
    if (parts.isEmpty) return '$count file${count == 1 ? '' : 's'}';
    return parts.join(' · ');
  }

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
                    '$count file${count == 1 ? '' : 's'} · ${formatBytes(totalBytes)}',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$_breakdown. Long-press to drag.',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
