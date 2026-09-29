import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/network/telegram_api_client.dart';
import '../../core/network/telegram_exceptions.dart';
import '../../core/network/telegram_models.dart';
import '../../core/providers.dart';

/// Bottom sheet for adding (or renaming) a recipient. Verifies through
/// getChat before saving so bad IDs are caught early.
Future<void> showTargetEditor(
  BuildContext context, {
  TgChat? existing,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: _TargetEditorSheet(existing: existing),
    ),
  );
}

class _TargetEditorSheet extends ConsumerStatefulWidget {
  const _TargetEditorSheet({this.existing});

  final TgChat? existing;

  @override
  ConsumerState<_TargetEditorSheet> createState() => _TargetEditorSheetState();
}

class _TargetEditorSheetState extends ConsumerState<_TargetEditorSheet> {
  final _controller = TextEditingController();
  bool _verifying = false;
  bool _saving = false;
  String? _error;
  TgChat? _verified;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      _verified = widget.existing;
      _controller.text = widget.existing!.title;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final input = _controller.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Enter a chat ID or @username.');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
      _verified = null;
    });
    final token = ref.read(botSessionProvider)?.token;
    if (token == null) {
      setState(() {
        _verifying = false;
        _error = 'Bot is not connected.';
      });
      return;
    }
    try {
      final api = TelegramApiClient(token);
      TgChat chat;
      try {
        chat = await api.getChat(input);
      } finally {
        // Closed on both paths — an error during verify used to leak the
        // Dio client (and its sockets).
        api.dispose();
      }
      if (!mounted) return;
      setState(() => _verified = chat);
    } on TelegramApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.friendlyMessage);
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      if (widget.existing != null) {
        await ref
            .read(targetsProvider.notifier)
            .rename(widget.existing!, _controller.text);
      } else {
        final chat = _verified;
        if (chat == null) return;
        // The chat was already verified via getChat above — no second
        // network call, no extra client.
        await ref.read(targetsProvider.notifier).addVerified(chat);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } on TelegramApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.friendlyMessage);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _canSave {
    if (widget.existing != null) return _controller.text.trim().isNotEmpty;
    return _verified != null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRename = widget.existing != null;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isRename ? 'Rename recipient' : 'Add recipient',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              isRename
                  ? 'Give this recipient a name you will recognise.'
                  : 'A numeric chat ID (e.g. -1001234567890) or an '
                      '@channelusername.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => isRename ? null : _verify(),
              decoration: InputDecoration(
                labelText: isRename ? 'Display name' : 'Chat ID or @username',
                prefixIcon: const Icon(Symbols.tag_rounded, size: 20),
                suffixIcon: isRename
                    ? null
                    : (_verifying
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            tooltip: 'Verify',
                            icon: const Icon(Symbols.check_rounded, size: 20),
                            onPressed: _verify,
                          )),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            if (!isRename && _verified != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Symbols.check_circle_rounded,
                      size: 20,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${_verified!.title} (${_verified!.chatId})',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving || !_canSave ? null : _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: Text(isRename ? 'Save name' : 'Save recipient'),
            ),
          ],
        ),
      ),
    );
  }
}
