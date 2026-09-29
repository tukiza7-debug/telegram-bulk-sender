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

    // Normalize fullwidth colon (common on mobile keyboards), smart dashes
    // and curly quotes (notes apps reformat copied text), and drop
    // invisible/zero-width characters that break validation invisibly.
    s = s.replaceAll('：', ':');
    s = s.replaceAll(RegExp('[\u2010-\u2015\u2212]'), '-');
    s = s.replaceAll(RegExp('[\u2018\u2019\u02bc]'), '\'');
    s = s.replaceAll(RegExp('[\u201c\u201d]'), '"');
    s = s.replaceAll(_invisible, '');

    // Fast path: already a clean token.
    if (_standalone.hasMatch(s)) return s;

    // Complete tokens embedded in surrounding text. The secret character
    // class stops at whitespace and punctuation, so this stays exact even
    // for multi-line BotFather replies (the newline bounds the secret).
    // The near-today length window (34..36; real secrets are 35 chars
    // today) keeps line-wrapped fragments from matching here — they are
    // re-joined below instead.
    final embedded = _embedded.firstMatch(s);
    if (embedded != null) {
      final secretLen = embedded.group(2)!.length;
      if (secretLen >= 34 && secretLen <= 36) {
        return '${embedded.group(1)!}:${embedded.group(2)!}';
      }
    }

    // Word-join recovery for wrapped copies. Selection copies across a
    // visually wrapped token keep soft line breaks INSIDE the secret —
    // matching that verbatim truncated the token and Telegram then
    // rejected every paste of a perfectly valid token with 401 ("Telegram
    // rejected this token"). Whitespace is the natural junk boundary, so
    // candidates are built from short runs of ADJACENT words; the best
    // complete-looking one wins: an exact today-length secret (35) first,
    // otherwise the longest candidate within a sane envelope (20..36).
    // Labels like "Keep your token secure" can never fuse onto the secret
    // because they stay separate words.
    final words = s
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList(growable: false);
    String? best;
    var bestLen = -1;
    for (var window = 1; window <= 4 && window <= words.length; window++) {
      for (var i = 0; i + window <= words.length; i++) {
        final joined = words.sublist(i, i + window).join();
        if (!_standalone.hasMatch(joined)) continue;
        final secretLen = joined.length - joined.indexOf(':') - 1;
        if (secretLen == 35) return joined;
        if (secretLen > bestLen && secretLen <= 36) {
          best = joined;
          bestLen = secretLen;
        }
      }
    }
    if (best != null) return best;

    // Permissive extraction for tokens with shorter-than-today secrets
    // still sitting inside labeled text (legacy behavior).
    final loose = embedded ?? _embedded.firstMatch(s);
    if (loose != null) {
      return '${loose.group(1)!}:${loose.group(2)!}';
    }

    // Last resort: strip common wrappers and a leading "bot" prefix
    // (URL-style pastes were already handled by the regexes above).
    var t = s
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('`', '')
        .replaceAll('"', '')
        .replaceAll("'", '');
    while (t.toLowerCase().startsWith('bot') && t.length > 3 && !t.contains(':')) {
      t = t.substring(3);
    }
    if (t.isEmpty) return null;

    // Residues that are clearly NOT tokens — bare @usernames, t.me or
    // api.telegram.org links, anything without a colon — become null so
    // the caller shows the actionable "that doesn't look like a bot
    // token" hint instead of a doomed request that Telegram can only
    // answer with a confusing 401 "rejected".
    final linkLike = t.contains('t.me/') || t.contains('telegram.org/');
    if (!t.contains(':') || t.startsWith('@') || linkLike) return null;
    return t;
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
