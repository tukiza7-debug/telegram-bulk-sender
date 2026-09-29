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
  });
}
