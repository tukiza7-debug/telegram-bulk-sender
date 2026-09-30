import 'package:flutter_test/flutter_test.dart';
import 'package:telegram_bulk_sender/core/network/bot_token.dart';
import 'package:telegram_bulk_sender/core/token_sanitizer.dart';

const clean = '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk';
const second = '987654321:AABbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQq';
const mixedCase = '123456789:AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQq';
const hyphenToken = '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDs-awk';

void main() {
  group('TEST MATRIX (every row must pass)', () {
    test('1. clean token string passes untouched', () {
      final s = TokenSanitizer.sanitize(clean);
      expect(s.token, clean);
      expect(s.ambiguous, isFalse);
      expect(s.actions, isEmpty, reason: 'a clean paste must not be "cleaned"');
      expect(s.modified, isFalse);
      expect(s.warnings, isEmpty);
    });

    test('2. newline injected in the middle (soft-wrap copy)', () {
      final wrapped = '${clean.substring(0, 34)}\n${clean.substring(34)}';
      final s = TokenSanitizer.sanitize(wrapped);
      expect(s.token, clean, reason: 'fragments must be re-joined');
      expect(s.actions.join(' | '), contains('wrapped fragments'));
    });

    test('3. trailing space and trailing newline', () {
      expect(TokenSanitizer.sanitize('$clean \n').token, clean);
      expect(TokenSanitizer.sanitize('\n$clean\n\n').token, clean);
    });

    test('4. whole @BotFather message pasted (prose included)', () {
      final message = 'Use this token to access the HTTP Bot API:\n'
          '$clean\n\n'
          'Keep your token secure!';
      final s = TokenSanitizer.sanitize(message);
      expect(s.token, clean,
          reason: 'the secret must not fuse onto surrounding prose');
      expect(s.ambiguous, isFalse);
    });

    test('5. backticks / single quotes / double quotes wrappers', () {
      expect(TokenSanitizer.sanitize('`$clean`').token, clean);
      expect(TokenSanitizer.sanitize("'$clean'").token, clean);
      expect(TokenSanitizer.sanitize('"$clean"').token, clean);
    });

    test('6. label prefixes (Token:, token bot=, API TOKEN -)', () {
      expect(TokenSanitizer.sanitize('Token: $clean').token, clean);
      expect(TokenSanitizer.sanitize('token bot= $clean').token, clean);
      expect(TokenSanitizer.sanitize('API TOKEN - $clean').token, clean);
      expect(
        TokenSanitizer.sanitize('token anda : $clean').token,
        clean,
        reason: 'multi-language notes (Malay)',
      );
    });

    test('7. fullwidth colon U+FF1A folded to ASCII colon', () {
      final s = TokenSanitizer.sanitize(clean.replaceFirst(':', '\uFF1A'));
      expect(s.token, clean);
      expect(s.actions.join(' | '), contains('fullwidth colon'));
    });

    test('8. zero-width space U+200B inside the secret', () {
      final dirty = '${clean.substring(0, 20)}\u200B${clean.substring(20)}';
      expect(TokenSanitizer.sanitize(dirty).token, clean);
    });

    test('9. BOM at the start', () {
      expect(TokenSanitizer.sanitize('\uFEFF$clean').token, clean);
    });

    test('10. NBSP between fragments', () {
      final dirty = '${clean.substring(0, 25)}\u00A0${clean.substring(25)}';
      final s = TokenSanitizer.sanitize(dirty);
      expect(s.token, clean);
      expect(s.actions.join(' | '), contains('wrapped fragments'));
    });

    test('11. smart quotes and en-dash introduced by a notes app', () {
      expect(
        TokenSanitizer.sanitize('\u201C$hyphenToken\u201D').token,
        hyphenToken,
      );
      expect(
        TokenSanitizer.sanitize(hyphenToken.replaceAll('-', '\u2013')).token,
        hyphenToken,
        reason: 'the en dash must be folded back to a hyphen',
      );
    });

    test('12. non-token input gets the friendly hint, never a 401', () {
      for (final garbage in ['t.me/mybot', '@mybot', 'random text']) {
        final s = TokenSanitizer.sanitize(garbage);
        expect(s.token, isNull, reason: garbage);
        expect(s.ambiguous, isFalse, reason: garbage);
        expect(s.friendlyError, contains("doesn't look like a bot token"));
      }
    });

    test('13. two tokens in one paste -> ambiguity, never a silent guess',
        () {
      final s = TokenSanitizer.sanitize('First $clean then $second');
      expect(s.ambiguous, isTrue);
      expect(s.candidates, hasLength(2));
      expect(s.candidates, containsAll([clean, second]));
      expect(s.token, isNull);
    });

    test('14. case preservation: mixed-case secret kept byte-exact', () {
      final s = TokenSanitizer.sanitize('Token: \u201C$mixedCase\u201D');
      expect(s.token, mixedCase);
      final units = s.token!.runes.toList();
      expect(
        String.fromCharCodes(units),
        mixedCase,
        reason: 'the secret bytes must be identical to the original',
      );
    });
  });

  group('soft length checks (warn, never block)', () {
    test('short secret and total are warned about', () {
      final s = TokenSanitizer.sanitize('123456789:AAAA_old_secret_token');
      expect(s.token, '123456789:AAAA_old_secret_token');
      expect(s.warnings.join(' | '), contains('secret is 21 chars'));
      expect(s.warnings.join(' | '), contains('total length is 31 chars'));
    });

    test('a healthy token produces no warnings', () {
      expect(TokenSanitizer.sanitize(clean).warnings, isEmpty);
    });
  });

  group('heavily wrapped fallback', () {
    test('a token split across 7+ lines is re-joined', () {
      final pieces = <String>[];
      for (var i = 0; i < clean.length; i += 6) {
        final end = i + 6 > clean.length ? clean.length : i + 6;
        pieces.add(clean.substring(i, end));
      }
      expect(pieces.length, greaterThan(6));
      final s = TokenSanitizer.sanitize(pieces.join('\n'));
      expect(s.token, clean);
      expect(s.actions.join(' | '), contains('wrapped fragments'),
          reason: 'the join layer reaches 10 visual lines, so an 8-line '
              'wrap is recovered before the squash fallback is needed');
    });

    test('a token split beyond the join window still falls back to squash',
        () {
      final pieces = <String>[];
      for (var i = 0; i < clean.length; i += 4) {
        final end = i + 4 > clean.length ? clean.length : i + 4;
        pieces.add(clean.substring(i, end));
      }
      expect(pieces.length, greaterThan(10));
      final s = TokenSanitizer.sanitize(pieces.join('\n'));
      expect(s.token, clean);
      expect(s.actions.join(' | '), contains('heavily wrapped'));
    });
  });

  group('no raw token ever leaks into diagnostics', () {
    test('the sanitizer action log never contains the secret', () {
      final shapes = <String>[
        'Use this token to access the HTTP Bot API:\n$clean\n\nKeep it!',
        '${clean.substring(0, 34)}\n${clean.substring(34)}',
        '${clean.substring(0, 20)}\u200B${clean.substring(20)}',
        'Token: \u201C$clean\u201D',
      ];
      for (final shape in shapes) {
        final log = TokenSanitizer.sanitize(shape).actions.join(' | ');
        expect(log, isNot(contains(clean)));
        expect(log, isNot(contains('AAHdqTcvCH1vGWJxfSeofSAs')));
      }
    });

    test('the masked fingerprint shows only head and tail', () {
      final mask = TokenSanitizer.mask(clean);
      expect(mask, '123456789:AAHd\u2026awk');
      expect(mask, isNot(contains('dqTcvCH1vGWJxfSeofSAs')));
      expect(TokenSanitizer.mask('no colon here'), '\u2022\u2022\u2022\u2022\u2022');
    });
  });

  group('legacy BotTokenSanitizer compatibility', () {
    test('normalize delegates to the new pipeline', () {
      expect(BotTokenSanitizer.normalize('  `$clean`  \n'), clean);
      expect(BotTokenSanitizer.normalize('t.me/mybot'), isNull);
      expect(BotTokenSanitizer.mightBeToken(clean), isTrue);
      expect(BotTokenSanitizer.mask(clean), '123456789:AAHd\u2026awk');
    });
  });
}
