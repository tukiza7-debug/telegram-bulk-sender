/// Robust bot-token handling: users paste tokens copied out of @BotFather
/// messages, URLs, notes or password managers. Real-world pastes often carry
/// extra junk — surrounding labels ("Token:"), Markdown backticks, quotes,
/// zero-width characters, internal whitespace, or a full URL like
/// `https://api.telegram.org/bot<token>`. All of these previously reached the
/// Telegram API verbatim and produced "Invalid bot token" even when the user
/// held a perfectly valid token.
///
/// [BotTokenSanitizer.normalize] extracts the actual token from any of these
/// forms before it is ever sent to the network, so validation runs against a
/// real token.
library;

abstract final class BotTokenSanitizer {
  /// Telegram bot tokens are `<bot_id>:<secret>`. The secret is 35 chars of
  /// [A-Za-z0-9_-] today; we stay permissive (20+) so future formats and
  /// shorter test tokens still pass. The id part is 6-15 digits today.
  static final RegExp _embedded = RegExp(r'(\d{4,15})\s*[::]\s*([A-Za-z0-9_-]{20,})');

  /// A token that is already clean and structurally plausible.
  static final RegExp _standalone = RegExp(r'^\d{4,15}:[A-Za-z0-9_-]{20,}$');

  /// Characters that smuggle themselves into clipboard copies.
  static final RegExp _invisible = RegExp('[\u200b\u200c\u200d\u2060\ufeff\u00ad]');

  /// Returns the normalized token, or `null` when nothing plausible remains.
  ///
  /// Handles:
  ///  - exact tokens                       `123456789:AAH3x…`
  ///  - tokens with invisible characters   `123456789:​AAH3x…` (zero-width)
  ///  - tokens inside text                 "Token: `123456789:AAH3x…`"
  ///  - tokens inside URLs                 `https://api.telegram.org/bot123456789:AAH3x…`
  ///  - fullwidth colons                   `123456789：AAH3x…`
  static String? normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;

    // Normalize fullwidth colon (common on mobile keyboards) and drop
    // invisible/zero-width characters that break validation invisibly.
    s = s.replaceAll('：', ':');
    s = s.replaceAll(_invisible, '');

    // Fast path: already a clean token.
    if (_standalone.hasMatch(s)) return s;

    // Otherwise try to extract the token from whatever surrounds it.
    final match = _embedded.firstMatch(s);
    if (match != null) {
      final id = match.group(1)!;
      final secret = match.group(2)!;
      // Avoid re-capturing partial matches inside longer digit runs.
      return '$id:$secret';
    }

    // Last resort: strip common wrappers and all whitespace, then a leading
    // "bot" prefix (from URL-style pastes the regex above already handled).
    s = s
        .replaceAll('`', '')
        .replaceAll('"', '')
        .replaceAll("'", '')
        .replaceAll(RegExp(r'\s+'), '');
    while (s.toLowerCase().startsWith('bot') && s.length > 3 && !s.contains(':')) {
      s = s.substring(3);
    }
    if (s.isEmpty) return null;
    return s;
  }

  /// Cheap structural pre-check used only for friendly UX. We deliberately
  /// accept anything with a colon — the Telegram API (`getMe`) is the single
  /// source of truth and a network check is always performed afterwards.
  static bool mightBeToken(String token) => token.contains(':');

  /// Masked form for settings UI: `1234567:AAH3…wk9`. Never shows the
  /// full secret on screen.
  static String mask(String token) {
    final normalized = normalize(token) ?? token;
    final colon = normalized.indexOf(':');
    if (colon < 0) return '•••••';
    final id = normalized.substring(0, colon);
    final secret = normalized.substring(colon + 1);
    final head = secret.length > 4 ? secret.substring(0, 4) : secret;
    final tail = secret.length > 8 ? secret.substring(secret.length - 3) : '';
    return '$id:$head…$tail';
  }
}
