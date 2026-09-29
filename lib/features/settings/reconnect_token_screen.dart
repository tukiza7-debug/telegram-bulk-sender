import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/design_system/app_theme.dart';
import '../../core/network/telegram_exceptions.dart';
import '../../core/providers.dart';

/// Reconnect the bot from Settings: enter a (new) token, it is validated
/// against the real Telegram API (getMe) and replaces the stored one.
///
/// Use this when the bot token was regenerated in @BotFather, when the app
/// reports "Invalid bot token", or when switching to a different bot.
class ReconnectTokenScreen extends ConsumerStatefulWidget {
  const ReconnectTokenScreen({super.key});

  @override
  ConsumerState<ReconnectTokenScreen> createState() =>
      _ReconnectTokenScreenState();
}

class _ReconnectTokenScreenState extends ConsumerState<ReconnectTokenScreen> {
  final _controller = TextEditingController();
  bool _obscured = true;
  bool _validating = false;
  String? _error;
  String? _errorDetails;
  String? _connectedAs;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _reconnect() async {
    if (_validating) return;
    final raw = _controller.text;
    if (raw.trim().isEmpty) {
      setState(() {
        _error = 'Enter a bot token to continue.';
        _errorDetails = null;
      });
      return;
    }
    setState(() {
      _validating = true;
      _error = null;
      _errorDetails = null;
    });
    try {
      final bot = await ref.read(botSessionProvider.notifier).connect(raw);
      if (!mounted) return;
      setState(() => _connectedAs = bot.mention);
      ref.invalidate(botUsernameProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reconnected as ${bot.mention}')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      context.go('/');
    } on TelegramApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.friendlyMessageOnboarding;
        _errorDetails = e.technicalDetails;
      });
    } finally {
      if (mounted) setState(() => _validating = false);
    }
  }

  void _showHelp() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => const _ReconnectHelpSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Reconnect token')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Enter your bot token',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'If @BotFather regenerated your token, or the app shows '
                    '"Invalid bot token", paste the current token here. It is '
                    'validated against Telegram and stored encrypted on this '
                    'device.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _controller,
                    obscureText: _obscured,
                    autofillHints: const [AutofillHints.password],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _reconnect(),
                    decoration: InputDecoration(
                      labelText: 'New bot token',
                      hintText: '123456789:AA…',
                      prefixIcon:
                          const Icon(Symbols.key_rounded, size: 20),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscured
                              ? Symbols.visibility_rounded
                              : Symbols.visibility_off_rounded,
                          size: 20,
                        ),
                        onPressed: () =>
                            setState(() => _obscured = !_obscured),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _showHelp,
                      icon: const Icon(Symbols.help_rounded, size: 18),
                      label: const Text('Token not accepted?'),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    _ErrorBox(message: _error!, details: _errorDetails),
                  ],
                  if (_connectedAs != null) ...[
                    const SizedBox(height: 8),
                    _ConnectedCard(handle: _connectedAs!),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _validating ? null : _reconnect,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: _validating
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Symbols.sync_rounded, size: 20),
                    label: Text(
                        _validating ? 'Checking token…' : 'Reconnect token'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Recipients and history are kept. The old token is '
                    'replaced as soon as the new one is verified.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBox extends StatefulWidget {
  const _ErrorBox({required this.message, this.details});

  final String message;
  final String? details;

  @override
  State<_ErrorBox> createState() => _ErrorBoxState();
}

class _ErrorBoxState extends State<_ErrorBox> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Symbols.error_rounded,
                  size: 20, color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.message,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onErrorContainer),
                ),
              ),
            ],
          ),
          if (widget.details != null && widget.details!.isNotEmpty) ...[
            const SizedBox(height: 4),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _expanded
                          ? Symbols.expand_less_rounded
                          : Symbols.expand_more_rounded,
                      size: 16,
                      color: scheme.onErrorContainer,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Details',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: scheme.onErrorContainer),
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Text(
                widget.details!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer.withValues(alpha: 0.8),
                    ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ConnectedCard extends StatelessWidget {
  const _ConnectedCard({required this.handle});

  final String handle;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tokens.successContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Symbols.check_circle_rounded,
              size: 20, color: tokens.onSuccessContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Connected as $handle',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: tokens.onSuccessContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReconnectHelpSheet extends StatelessWidget {
  const _ReconnectHelpSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tips = <(String, String)>[
      (
        'Copy the FULL token',
        'A token is one line: a number, a colon, then a long secret — '
            '123456789:AAH3xQ…  Select the whole line, including the part '
            'after the colon.',
      ),
      (
        'Paste text, not a screenshot',
        'The token must be copied as text. The app also cleans up labels '
            'like "Token:" and stray spaces automatically.',
      ),
      (
        'Token regenerated?',
        'If you used /revoke in @BotFather, the old token stops working '
            'immediately — generate a new one and reconnect here. Copy '
            'from the LATEST message only.',
      ),
      (
        'Compare the fingerprint',
        'Open Details under the error: the "Tried token" line shows what '
            'the app received (e.g. 123456789:AAH3…wk9). If it differs '
            'from what @BotFather shows, the copy was truncated or '
            'mangled — select and copy the token again.',
      ),
      (
        'Still failing?',
        'Check your internet connection. If Telegram is unreachable the app '
            'cannot verify the token.',
      ),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Token not accepted?', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            for (final (title, body) in tips) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Symbols.check_circle_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.titleSmall),
                        const SizedBox(height: 2),
                        Text(body, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
          ],
        ),
      ),
    );
  }
}
