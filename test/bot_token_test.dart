import 'package:flutter_test/flutter_test.dart';
import 'package:telegram_bulk_sender/core/network/bot_token.dart';

void main() {
  group('BotTokenSanitizer', () {
    test('accepts a clean token unchanged', () {
      const token = '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk';
      expect(BotTokenSanitizer.normalize(token), token);
    });

    test('strips surrounding whitespace and quotes', () {
      expect(
        BotTokenSanitizer.normalize('  "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk" '),
        '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      );
    });

    test('strips backticks from markdown copies', () {
      expect(
        BotTokenSanitizer.normalize('`123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk`'),
        '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      );
    });

    test('extracts token from a labeled BotFather message', () {
      const paste = 'Use this token to access the HTTP API:\n'
          'Token: 123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk\n'
          'Keep your token secure!';
      expect(
        BotTokenSanitizer.normalize(paste),
        '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      );
    });

    test('extracts token from a full API URL', () {
      expect(
        BotTokenSanitizer.normalize(
            'https://api.telegram.org/bot123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk/getMe'),
        '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      );
    });

    test('removes zero-width and invisible characters', () {
      const dirty = '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk\u200b';
      expect(
        BotTokenSanitizer.normalize(dirty),
        '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      );
      const bom = '\ufeff123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk';
      expect(
        BotTokenSanitizer.normalize(bom),
        '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      );
    });

    test('normalizes fullwidth colons', () {
      expect(
        BotTokenSanitizer.normalize('123456789：AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk'),
        '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      );
    });

    test('collapses internal whitespace around the colon', () {
      expect(
        BotTokenSanitizer.normalize('123456789: AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk'),
        '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      );
    });

    test('returns null for empty or useless input', () {
      expect(BotTokenSanitizer.normalize(''), isNull);
      expect(BotTokenSanitizer.normalize('   '), isNull);
      expect(BotTokenSanitizer.normalize('\u200b\ufeff'), isNull);
    });

    test('mightBeToken rejects input without any colon', () {
      expect(BotTokenSanitizer.mightBeToken('123456789AAH'), isFalse);
      expect(
        BotTokenSanitizer.mightBeToken('123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk'),
        isTrue,
      );
    });

    test('mask never reveals the full secret', () {
      final masked = BotTokenSanitizer.mask(
          '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk');
      expect(masked, startsWith('123456789:'));
      expect(masked, contains('…'));
      expect(masked.length, lessThan(25));
      expect(masked, isNot(contains('DqTcv')));
    });

    test('[verify] tokens containing - and _ pass normalize unchanged',
        () {
      // Telegram's secret alphabet includes '-' and '_'; these must never be
      // stripped or rewritten.
      const token = '8943579073:AAFJbKu7gPQZz3Gm4Y-HYg9tUA5YLtpCZtk4_-x';
      expect(BotTokenSanitizer.normalize(token), token);
      expect(
        BotTokenSanitizer.normalize('Token: `$token`'),
        token,
        reason: 'labels/backticks around a -/_ secret still extract cleanly',
      );
    });

    test('[verify] a fullwidth colon is normalized to ASCII', () {
      expect(
        BotTokenSanitizer.normalize(
            '123456789\uff1aAAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk'),
        '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk',
      );
    });

    test('keeps tokens whose selection copy wrapped across two lines', () {
      // Copying across a visually wrapped @BotFather code block keeps the
      // soft line break INSIDE the secret. The old extraction truncated
      // the token at the break, so every paste of a perfectly valid token
      // was rejected with 401 ("Telegram rejected this token").
      const full = '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk';
      final wrappedNl = '${full.substring(0, 34)}\n${full.substring(34)}';
      expect(BotTokenSanitizer.normalize(wrappedNl), full,
          reason: 'break deep in the secret (old truncation window)');
      final wrappedSp = '${full.substring(0, 25)} ${full.substring(25)}';
      expect(BotTokenSanitizer.normalize(wrappedSp), full,
          reason: 'break shallow in the secret (old truncation window)');
    });

    test('wrapped copy inside a labeled message is not truncated', () {
      const full = '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk';
      final paste = 'Use this token to access the HTTP API:\n'
          '${full.substring(0, 28)}\n${full.substring(28)}\n'
          'Keep your token secure!';
      expect(BotTokenSanitizer.normalize(paste), full);
    });

    test('a bare bot link or @username is NOT a token, not a doomed 401', () {
      // These pastes can only ever produce a confusing "Telegram rejected
      // this token"; they must surface the actionable NOT_A_TOKEN hint.
      expect(BotTokenSanitizer.normalize('https://t.me/my_bulk_bot'), isNull);
      expect(BotTokenSanitizer.normalize('t.me/my_bulk_bot'), isNull);
      expect(BotTokenSanitizer.normalize('@my_bulk_bot'), isNull);
      expect(
        BotTokenSanitizer.normalize(
            'https://api.telegram.org/@my_bulk_bot'),
        isNull,
      );
    });

    test('recovers tokens reformatted by notes apps (dashes and quotes)', () {
      const full = '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDs-awk';
      expect(BotTokenSanitizer.normalize('\u201c$full\u201d'), full,
          reason: 'curly quotes around the paste');
      expect(
        BotTokenSanitizer.normalize(full.replaceAll('-', '\u2013')),
        full,
        reason: 'en dash replacing the ASCII hyphen',
      );
    });
  });
}
