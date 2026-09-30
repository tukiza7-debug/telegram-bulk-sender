/// Paste-proof bot-token ingestion.
///
/// Users paste tokens copied out of @BotFather messages, notes apps,
/// password managers and browser bars. Real-world pastes carry labels,
/// Markdown wrappers, smart punctuation, zero-width characters and — most
/// damaging of all — soft line breaks INSIDE the secret, injected when the
/// selection crosses a visually wrapped code block. Every one of those used
/// to reach the Telegram API verbatim (or truncated the token) and produced
/// a spurious 401 "Telegram rejected this token" for a perfectly valid
/// token.
///
/// [TokenSanitizer] is pure, deterministic and unit-testable. It folds
/// hostile characters (case is NEVER touched), strips label prefixes and
/// extracts the actual token, and it reports WHAT it changed so the UI can
/// show a non-blocking note and a self-diagnosis block. When a paste
/// contains more than one token the sanitizer refuses to guess and reports
/// every candidate so the user can pick. The definitive validation remains
/// `getMe` — this class only decides WHAT is sent there.
library;

/// The outcome of one [TokenSanitizer.sanitize] run.
class TokenSanitization {
  const TokenSanitization({
    required this.token,
    required this.candidates,
    required this.ambiguous,
    required this.actions,
    required this.warnings,
  });

  /// The single extracted token, or `null` when nothing plausible was
  /// found ([ambiguous] distinguishes the two failure shapes).
  final String? token;

  /// Every distinct plausible token found in the paste. More than one
  /// means the caller must let the user pick — never guess silently.
  final List<String> candidates;

  /// True when the paste contained several distinct tokens.
  final bool ambiguous;

  /// Human-readable log of every modification, e.g.
  /// "removed 1 line break". Empty when the paste was already clean.
  final List<String> actions;

  /// Soft length warnings (never blocking — `getMe` decides).
  final List<String> warnings;

  bool get modified => actions.isNotEmpty;

  String get friendlyError =>
      "That doesn't look like a bot token. Copy the full token from "
      '@BotFather — it looks like 123456789:AAH3x…';

  /// One-line summary for the non-blocking note under the field.
  String get changeNote =>
      actions.isEmpty ? '' : 'Cleaned automatically: ${actions.join('; ')}.';
}

class _Candidate {
  const _Candidate(this.token, this.joinWindow, this.start, this.end);

  final String token;

  /// 1 = extracted inside a single word; >1 = that many adjacent
  /// whitespace-separated fragments were re-joined.
  final int joinWindow;

  /// Word range covered by this candidate (start inclusive, end
  /// exclusive). Candidates covering overlapping ranges are fragments of
  /// the SAME physical token; candidates in separate ranges are genuinely
  /// different tokens.
  final int start;
  final int end;

  int get secretLen => token.length - token.indexOf(':') - 1;

  bool overlaps(_Candidate other) => start < other.end && other.start < end;
}

abstract final class TokenSanitizer {
  /// `<bot id>:<secret>` — the id is 5+ digits today, the secret 35 chars
  /// of [A-Za-z0-9_-]. We stay permissive at 20+ and WARN outside the
  /// expected envelope instead of blocking; `getMe` remains the authority.
  static final RegExp _embedded = RegExp(r'([0-9]{5,}):([A-Za-z0-9_-]{20,})');
  static final RegExp _standalone =
      RegExp(r'^[0-9]{5,}:[A-Za-z0-9_-]{20,}$');

  static const int _maxPlausibleSecretLen = 36;

  /// Label prefixes notes/messengers put in front of the token, followed
  /// by ':', '=', '-' or a fullwidth colon. Case-insensitive, with a word
  /// boundary so "mytoken=" is not eaten as "my".
  static final RegExp _labelPrefix = RegExp(
    r'\b(?:api\s+token|bot\s+token|token\s+bot|token\s+anda|token)'
    r'[ \t]*[:=\-][ \t]*',
    caseSensitive: false,
  );

  /// Wrapper pairs that clipboard copies and Markdown renderers add.
  static const List<String> _wrappers = [
    '`', '**', '__', '"', "'", '\u201C', '\u201D', '\u2018', '\u2019',
  ];

  // ---- Pipeline --------------------------------------------------------

  static TokenSanitization sanitize(String raw) {
    final actions = <String>[];
    final warnings = <String>[];

    // 1. Outer whitespace.
    var s = raw.trim();
    if (raw != s && s.isNotEmpty) {
      actions.add('trimmed outer whitespace');
    }
    if (s.isEmpty) {
      return TokenSanitization(
        token: null,
        candidates: const [],
        ambiguous: false,
        actions: actions,
        warnings: warnings,
      );
    }

    // 2. Markdown / quote wrapper pairs (`tok`, **tok**, "tok", "tok"…).
    s = _stripWrappers(s, actions);

    // 3. Character folding — case MUST be preserved exactly.
    s = _foldCharacters(s, actions);

    // 4. Label prefixes anywhere in the blob ("Token:", "API TOKEN -",
    //    "token bot=", "token anda:"…). Wrappers are stripped again
    //    afterwards because label removal can expose a new wrapper pair
    //    ("Token: `tok`" -> "`tok`").
    s = _stripLabels(s, actions);
    s = _stripWrappers(s, actions);

    // 5. Candidate extraction on the whitespace-PRESERVING text: line
    //    breaks and spaces bound the token against surrounding prose, so
    //    these candidates can never fuse the secret onto label words.
    final candidates = _collectCandidates(s);

    String? token;
    var ambiguous = false;

    if (candidates.isEmpty) {
      // 6. Heavily-wrapped fallback: matching found nothing at all (the
      //    token is shredded beyond the join window and no partial run
      //    reaches the minimum secret length). Joining everything can fuse
      //    trailing prose onto the secret, so the result is loudly warned
      //    about in the diagnostics.
      final squashed = s.replaceAll(RegExp(r'\s+'), '');
      final m = _embedded.firstMatch(squashed);
      if (m != null) {
        token = m.group(0);
        actions.add('joined heavily wrapped fragments');
        final secretLen = m.group(2)!.length;
        if (secretLen > 40) {
          warnings.add(
              'extracted secret is $secretLen chars — longer than expected; '
              'the paste may include extra text');
        }
      }
    } else {
      // 7. Selection. Candidates covering overlapping word ranges are
      //    fragments/partial joins of the SAME physical token (a shifted
      //    re-join over wrapped lines); each cluster resolves to ONE
      //    winner: today's exact secret length (35) first, then the
      //    longest plausible secret. Survivors in SEPARATE ranges are
      //    genuinely different tokens — the caller must let the user
      //    pick, never guess.
      final winners = <_Candidate>[];
      for (final cluster in _clusterOverlapping(candidates)) {
        var best = cluster.first;
        for (final c in cluster.skip(1)) {
          final bestExact = best.secretLen == 35;
          final cExact = c.secretLen == 35;
          if (cExact && !bestExact) {
            best = c;
          } else if (cExact == bestExact && c.secretLen > best.secretLen) {
            best = c;
          }
        }
        winners.add(best);
      }
      if (winners.length == 1) {
        final winner = winners.single;
        token = winner.token;
        _logProvenance(winner, token == s, actions);
        // Safety net: a winner with a shorter-than-today secret can be a
        // shifted partial join of a token shredded into more pieces than
        // the join window covers — a clean squash of the whole paste is
        // preferred when it yields today's secret length (34..36).
        if (winner.secretLen < 35) {
          final squashed = s.replaceAll(RegExp(r'\s+'), '');
          final m = _embedded.firstMatch(squashed);
          if (m != null) {
            final t = m.group(0)!;
            final secretLen = t.length - t.indexOf(':') - 1;
            if (secretLen >= 34 && secretLen <= 36 && t != token) {
              token = t;
              actions.add('joined heavily wrapped fragments');
            }
          }
        }
      } else if (winners.length > 1) {
        ambiguous = true;
      }
    }

    final chosen = ambiguous ? null : token;
    if (chosen != null) warnings.addAll(_lengthWarnings(chosen));

    return TokenSanitization(
      token: chosen,
      candidates: ambiguous
          ? _distinct(candidates).map((c) => c.token).toList()
          : const [],
      ambiguous: ambiguous,
      actions: actions,
      warnings: warnings,
    );
  }

  // ---- Steps -----------------------------------------------------------

  static String _stripWrappers(String s, List<String> actions) {
    var stripped = false;
    var changed = true;
    while (changed) {
      changed = false;
      for (final w in _wrappers) {
        if (s.length > w.length * 2 && s.startsWith(w) && s.endsWith(w)) {
          s = s.substring(w.length, s.length - w.length);
          stripped = true;
          changed = true;
        }
      }
    }
    if (stripped) actions.add('stripped Markdown/quote wrappers');
    return s;
  }

  static String _foldCharacters(String s, List<String> actions) {
    void fold(Pattern pattern, String target, String label) {
      final matches = pattern.allMatches(s).length;
      if (matches == 0) return;
      s = s.replaceAll(pattern, target);
      actions.add('$label ($matches)');
    }

    fold('\uFF1A', ':', 'folded fullwidth colon(s)');
    fold(RegExp('[\u00A0\u2007\u202F]'), ' ',
        'converted non-breaking space(s)');
    fold(RegExp('[\u2010-\u2014\u2212]'), '-',
        'converted smart dash(es) to hyphen');
    fold(RegExp('[\u2018\u2019\u201B]'), "'",
        'converted curly single quote(s)');
    fold(RegExp('[\u201C\u201D\u201E]'), '"',
        'converted curly double quote(s)');
    fold(RegExp('[\uFEFF\u200B-\u200D\u2060\u00AD]'), '',
        'removed invisible character(s)');
    return s;
  }

  static String _stripLabels(String s, List<String> actions) {
    final matches = _labelPrefix.allMatches(s).toList();
    if (matches.isEmpty) return s;
    final stripped = s.replaceAll(_labelPrefix, '');
    actions.add(
        'stripped ${matches.length} label prefix${matches.length == 1 ? '' : 'es'}');
    return stripped;
  }

  static List<_Candidate> _collectCandidates(String s) {
    final words = s
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList(growable: false);
    final found = <String, _Candidate>{};

    // A token inside a single word (surrounded by punctuation/backticks or
    // alone) — bounded by non-token characters, so it is exact.
    for (var i = 0; i < words.length; i++) {
      final m = _embedded.firstMatch(words[i]);
      if (m != null) {
        final tok = m.group(0)!;
        found.putIfAbsent(tok, () => _Candidate(tok, 1, i, i + 1));
      }
    }

    // Wrapped copies: selection across a visually wrapped token keeps soft
    // line breaks INSIDE the secret. Consecutive words are re-joined (up to
    // 10 visual lines — very narrow screens) and accepted only when the
    // join is a clean standalone token whose secret stayed within a
    // plausible envelope (<= 36, today's real length is 35) — prose words
    // like "Keep" push the secret past the envelope and are rejected, so
    // labels can never fuse onto the secret.
    for (var window = 2; window <= 10 && window <= words.length; window++) {
      for (var i = 0; i + window <= words.length; i++) {
        final joined = words.sublist(i, i + window).join();
        if (!_standalone.hasMatch(joined)) continue;
        final secretLen = joined.length - joined.indexOf(':') - 1;
        if (secretLen > _maxPlausibleSecretLen) continue;
        found.putIfAbsent(
            joined, () => _Candidate(joined, window, i, i + window));
      }
    }
    return found.values.toList(growable: false);
  }

  /// Groups candidates into clusters of overlapping word ranges.
  static List<List<_Candidate>> _clusterOverlapping(
      List<_Candidate> candidates) {
    final sorted = [...candidates]..sort((a, b) => a.start - b.start);
    final clusters = <List<_Candidate>>[];
    var currentEnd = -1;
    for (final c in sorted) {
      if (clusters.isEmpty || c.start >= currentEnd) {
        clusters.add([c]);
      } else {
        clusters.last.add(c);
      }
      if (c.end > currentEnd) currentEnd = c.end;
    }
    return clusters;
  }

  static List<_Candidate> _distinct(List<_Candidate> candidates) {
    final seen = <String>{};
    final out = <_Candidate>[];
    for (final c in candidates) {
      if (seen.add(c.token)) out.add(c);
    }
    return out;
  }

  static void _logProvenance(
      _Candidate c, bool equalsCleanedInput, List<String> actions) {
    if (c.joinWindow > 1) {
      actions.add('joined ${c.joinWindow} wrapped fragments');
    } else if (!equalsCleanedInput) {
      actions.add('extracted the token from surrounding text');
    }
  }

  static List<String> _lengthWarnings(String token) {
    final colon = token.indexOf(':');
    final idLen = colon;
    final secretLen = token.length - colon - 1;
    return [
      if (idLen < 5 || idLen > 10) 'bot id is $idLen digits (expected 5-10)',
      if (secretLen < 30) 'secret is $secretLen chars (expected 30-40)',
      if (secretLen > 40) 'secret is $secretLen chars (expected 30-40)',
      if (token.length < 40 || token.length > 60)
        'total length is ${token.length} chars (expected 40-60)',
    ];
  }

  /// Masked fingerprint for diagnostics and the candidate picker:
  /// `123456789:AAH3…wk9` (bot id + first 4 + last 3 of the secret).
  /// Never shows enough of the secret to be usable.
  static String mask(String token) {
    final normalized = sanitize(token).token ?? token;
    final colon = normalized.indexOf(':');
    if (colon < 0) return '\u2022\u2022\u2022\u2022\u2022';
    final id = normalized.substring(0, colon);
    final secret = normalized.substring(colon + 1);
    final head = secret.length > 4 ? secret.substring(0, 4) : secret;
    final tail = secret.length > 8 ? secret.substring(secret.length - 3) : '';
    return '$id:$head\u2026$tail';
  }
}
