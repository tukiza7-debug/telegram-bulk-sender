import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/network/telegram_exceptions.dart';
import '../../core/providers.dart';
import '../../core/design_system/app_theme.dart';
import '../common/widgets.dart';

/// First screen: connect the bot by validating a Telegram Bot API token.
class TokenOnboardingScreen extends ConsumerStatefulWidget {
  const TokenOnboardingScreen({super.key});

  @override
  ConsumerState<TokenOnboardingScreen> createState() =>
      _TokenOnboardingScreenState();
}

class _TokenOnboardingScreenState extends ConsumerState<TokenOnboardingScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _obscured = true;
  bool _validating = false;
  String? _error;
  String? _errorDetails;
  String? _connectedAs;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final token = _controller.text.trim();
    if (token.isEmpty) {
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
      final bot =
          await ref.read(botSessionProvider.notifier).connect(token);
      if (!mounted) return;
      setState(() => _connectedAs = bot.mention);
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

  void _continue() {
    context.push('/onboarding/permissions');
  }

  void _showHelp() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => const _TokenHelpSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  const Center(child: AppMark()),
                  const SizedBox(height: 24),
                  Text(
                    'Bulk Sender for Telegram',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Send albums of photos, videos and documents to your '
                    'chats and channels in one go. Connect your bot to get '
                    'started.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _controller,
                    focusNode: _focus,
                    obscureText: _obscured,
                    autofocus: false,
                    autofillHints: const [AutofillHints.password],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _connect(),
                    decoration: InputDecoration(
                      labelText: 'Bot token',
                      hintText: '123456789:AA…',
                      prefixIcon: const Icon(Symbols.key_rounded, size: 20),
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
                      label: const Text('How do I get a token?'),
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
                  FilledButton(
                    onPressed: _connectedAs != null
                        ? _continue
                        : (_validating ? null : _connect),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: _validating
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _connectedAs != null ? 'Continue' : 'Connect bot',
                          ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Your token is stored encrypted on this device only and '
                    'is never sent anywhere except api.telegram.org.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
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
                      fontFeatures: const [],
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

class _TokenHelpSheet extends StatelessWidget {
  const _TokenHelpSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = <(String, String)>[
      (
        'Open @BotFather in Telegram',
        "BotFather is Telegram's official bot for creating and managing bots.",
      ),
      (
        'Send /newbot and follow the prompts',
        'Choose a display name and a username ending in "bot".',
      ),
      (
        'Copy the token',
        'BotFather replies with a token like 123456789:AAH3x… Paste it here. '
            'The app cleans up labels, spaces and stray characters '
            'automatically.',
      ),
      (
        'Add the bot to your chat',
        'For groups/channels, add the bot as an admin so it can post photos.',
      ),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Get a bot token', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            for (final (i, (title, body)) in steps.indexed) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      '${i + 1}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
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
              const SizedBox(height: 16),
            ],
            const Divider(height: 32),
            Text(
              'Seeing "Telegram rejected this token"?',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Make sure the FULL token is selected — including the part '
                  'after the colon. Every /revoke in @BotFather kills all '
                  'older tokens, so copy from the LATEST message only. Open '
                  'Details under the error and compare the "Tried token" '
                  'line with what @BotFather shows: if the two differ, the '
                  'copy was truncated — select and copy it again.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
