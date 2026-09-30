/// Robust bot-token handling: users paste tokens copied out of @BotFather
/// messages, URLs, notes or password managers. Real-world pastes often carry
/// extra junk — surrounding labels ("Token:"), Markdown backticks, quotes,
/// zero-width characters, internal whitespace, or a full URL like
/// `https://api.telegram.org/bot<token>`. All of these previously reached the
/// Telegram API verbatim and produced "Invalid bot token" even when the user
/// held a perfectly valid token.
///
/// The full pipeline now lives in [TokenSanitizer] (paste-proof ingestion
/// with an action log and multi-token detection); this library keeps the
/// small API surface other call sites rely on and delegates to it.
library;

import '../token_sanitizer.dart';

abstract final class BotTokenSanitizer {
  /// Returns the normalized token, or `null` when nothing plausible
  /// remains. Delegates to [TokenSanitizer.sanitize].
  static String? normalize(String raw) => TokenSanitizer.sanitize(raw).token;

  /// Cheap structural pre-check used only for friendly UX. We deliberately
  /// accept anything with a colon — the Telegram API (`getMe`) is the single
  /// source of truth and a network check is always performed afterwards.
  static bool mightBeToken(String token) => token.contains(':');

  /// Masked form for settings UI: `1234567:AAH3…wk9`. Never shows the
  /// full secret on screen.
  static String mask(String token) => TokenSanitizer.mask(token);
}
