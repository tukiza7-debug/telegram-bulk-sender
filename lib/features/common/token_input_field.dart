import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/token_sanitizer.dart';

/// Bottom sheet shown when a paste contains more than one bot token.
/// Returns the chosen token, or null when the sheet was dismissed.
Future<String?> pickTokenCandidate(
  BuildContext context,
  List<String> candidates,
) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: Text(
              'More than one bot token was found — pick one:',
              style: Theme.of(sheetContext).textTheme.titleSmall,
            ),
          ),
          for (final candidate in candidates)
            ListTile(
              leading: const Icon(Symbols.key_rounded),
              title: Text(TokenSanitizer.mask(candidate)),
              subtitle: Text('${candidate.length} characters'),
              onTap: () => Navigator.of(sheetContext).pop(candidate),
            ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}

/// The bot-token input used by onboarding and the reconnect screen.
///
/// Hardened against every way an on-screen keyboard or a notes app can
/// mangle a pasted token:
///  - IME assists fully disabled (no autocorrect, suggestions, smart
///    dashes/quotes or capitalization) and a password-style keyboard;
///  - a "paste & clean" button that bypasses the IME entirely, runs the
///    [TokenSanitizer] on the raw clipboard payload and fills the field
///    with the extracted token;
///  - a non-blocking note listing exactly what was cleaned;
///  - a picker whenever the clipboard contains more than one token.
class TokenInputField extends StatefulWidget {
  const TokenInputField({
    super.key,
    required this.controller,
    this.focusNode,
    this.autofocus = false,
    this.labelText = 'Bot token',
    this.hintText = '123456789:AA…',
    this.onSubmitted,
    this.onSanitized,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool autofocus;
  final String labelText;
  final String hintText;
  final ValueChanged<String>? onSubmitted;

  /// Called after a paste modified the input, with the sanitizer action
  /// log (screens carry it into `connect()` for the Details block).
  final ValueChanged<List<String>>? onSanitized;

  @override
  State<TokenInputField> createState() => _TokenInputFieldState();
}

class _TokenInputFieldState extends State<TokenInputField> {
  bool _obscured = true;
  String? _note;

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final raw = data?.text ?? '';
    if (!mounted) return;
    if (raw.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Clipboard is empty — copy the token from @BotFather first.'),
        ),
      );
      return;
    }

    final s = TokenSanitizer.sanitize(raw);
    if (s.ambiguous) {
      final chosen = await pickTokenCandidate(context, s.candidates);
      if (chosen == null || !mounted) return;
      _apply(
        chosen,
        [
          ...s.actions,
          'you picked 1 of the ${s.candidates.length} tokens found',
        ],
      );
      return;
    }
    if (s.token == null) {
      setState(() {
        _note = 'No bot token found in the clipboard. Copy the full token '
            '(like 123456789:AAH3x…) from @BotFather and try again.';
      });
      return;
    }
    _apply(s.token!, s.actions);
  }

  void _apply(String token, List<String> actions) {
    widget.controller.value = TextEditingValue(
      text: token,
      selection: TextSelection.collapsed(offset: token.length),
    );
    widget.onSanitized?.call(actions);
    setState(() {
      _note = actions.isEmpty
          ? null
          : 'Cleaned automatically: ${actions.join('; ')}.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          obscureText: _obscured,
          // IME hardening: keyboards must not "help" — every assist has
          // corrupted a pasted token somewhere at least once.
          autocorrect: false,
          enableSuggestions: false,
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
          textCapitalization: TextCapitalization.none,
          keyboardType: TextInputType.visiblePassword,
          autofillHints: const [AutofillHints.password],
          textInputAction: TextInputAction.done,
          onSubmitted: widget.onSubmitted,
          decoration: InputDecoration(
            labelText: widget.labelText,
            hintText: widget.hintText,
            prefixIcon: const Icon(Symbols.key_rounded, size: 20),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Paste from clipboard and clean it',
                  icon: const Icon(Symbols.content_paste_rounded, size: 20),
                  onPressed: _pasteFromClipboard,
                ),
                IconButton(
                  icon: Icon(
                    _obscured
                        ? Symbols.visibility_rounded
                        : Symbols.visibility_off_rounded,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _obscured = !_obscured),
                ),
              ],
            ),
          ),
        ),
        if (_note != null) ...[
          const SizedBox(height: 4),
          Text(
            _note!,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
