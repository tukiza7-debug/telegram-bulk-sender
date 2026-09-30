# Changelog

## 1.2.4 — paste-proof token ingestion & truthful error taxonomy

The "Telegram rejected this token" loop (valid tokens rejected on every
paste) is fixed at the ingestion layer. A valid token now validates on the
FIRST try no matter how it was pasted.

- **TokenSanitizer** (`lib/core/token_sanitizer.dart`) — pure, deterministic
  pipeline: outer trim → Markdown/quote wrapper stripping → character
  folding (fullwidth colon, NBSP variants, smart dashes/quotes, invisible
  characters; case preserved byte-exact) → label-prefix stripping
  ("Token:", "token bot=", "API TOKEN -", "token anda:"…) → extraction of
  `[0-9]{5,}:[A-Za-z0-9_-]{20,}` from the whitespace-preserving text with
  adjacent-word re-joining for soft-wrapped copies (up to 10 visual lines)
  and a squash fallback for heavily shredded pastes.
- **Soft-wrapped copies** no longer truncate the token (the v1.2.3 root
  cause of guaranteed 401s) — fragments are re-joined before validation.
- **Multi-token pastes are never guessed silently**: when a paste contains
  more than one token the app shows a picker (masked fingerprints), and
  `connect()` refuses ambiguous input programmatically.
- **Clipboard-first input**: a "paste & clean" button on the token field
  bypasses the keyboard entirely, runs the sanitizer on the whole clipboard
  payload and shows a non-blocking note listing exactly what was cleaned.
- **IME hardening**: autocorrect, suggestions, smart dashes/quotes and
  capitalization disabled; password-style keyboard; visibility toggle.
- **Truthful error taxonomy**: network/server failures say "Cannot reach
  api.telegram.org … This is NOT a token problem." — never "token
  rejected". Timeouts are retried once with a tight 10-second timeout
  (E_TIMEOUT) before being reported as a network problem.
- **Connectivity pre-check**: before any token-invalid UI, the app probes
  api.telegram.org (a fixed dummy token, JSON answer = reachable) and
  detects captive portals/proxies explicitly; the probe outcome (reachable
  / captive / unreachable, latency, HTTP status) is shown in Details.
- **Self-diagnosis Details** under any token error: masked fingerprint of
  the token actually sent (`123456789:AAH3…wk9`), token length vs the
  expected 40-60 range, the sanitizer action log and the network probe.
- **No raw token leaks**: masks only, in exceptions, diagnostics and logs —
  covered by dedicated leak tests.
- Launch-time re-validation unchanged: an offline launch keeps the saved
  token as "unverified" and never wipes it; only a real Telegram 401 does.
- Tests: 130 (was 95) — the full 14-row hostile-paste matrix, reachability
  probe, widget tests for the field, timeout taxonomy, no-leak scans.

## 1.2.3 — token-paste hardening round

- Wrapped-copy truncation fix (word-join extraction), smart
  punctuation folding, t.me/@username pastes surface NOT_A_TOKEN instead
  of a doomed 401.
- 401 Details show the masked tried-token fingerprint; clearer
  rejected-token guidance on both token screens.

## 1.2.2 — 28-item bug-fix round

- ETag/304 update caching with shared in-flight checks; FormData rebuilt
  per retry attempt; album rate-limit weighting; foreground-task image
  pipeline (HEIC/BMP re-encode, isolate-verified compression);
  send-task crash safety (onStart try/finally, interrupted marking);
  history refresh via prefs.reload(); accurate token-error classification
  (JSON vs HTML, 0 retries on getMe/getChat); Android backup exclusion
  (allowBackup=false + dataExtractionRules); startup guards; pause/resume
  swap; retry config; progress throttling; cancellable 429 waits; balanced
  album tails; update skipped-state; fail-closed APK checksums;
  notification cold-start; permissions resume refresh; review-screen math;
  picker error snackbars; cert-pinned release CI (EXPECTED_CERT_SHA256);
  versionCode offset.

## 1.2.1 — fresh-install state fix

- Hardened restore(): blank/corrupted secure-storage values are discarded,
  garbage tokens wiped; fresh installs always start at "Bot not
  connected"; 401 wipe path made exception-safe.

## 1.2.0 — launch-time token re-validation

- The saved token is re-checked with getMe on every launch; dead tokens no
  longer show a fake "connected" state.
