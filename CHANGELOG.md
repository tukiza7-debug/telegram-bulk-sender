# Changelog

## 2.0.0 — production CLI + importable library (`cli/`)

The major update of the product: a production-grade command-line tool and
importable Python library that bulk-sends images through the Telegram Bot
API to explicitly allowlisted, consent-based recipients. The Android app is
untouched and continues its own 1.x line; the CLI lives in `cli/` with its
own CI workflow (`.github/workflows/cli.yml`).

- **Three delivery modes over ONE pipeline** (no forked logic):
  `tbis folder` (deterministic natural-order queue, optional recursion and
  globs), `tbis manifest` (strictly sequential CSV/JSON manifest, order
  preserved), `tbis single` (one image, for testing a setup).
- **Dry-run first**: `--dry-run` prints the complete plan (file → recipient
  → caption → estimated API calls) and performs zero network calls; it does
  not even require a token.
- **Validation before the queue**: JPEG/PNG/WebP detection by magic bytes
  (not extension), truncation detection (including the JPEG EOI marker),
  zero-byte and oversize rejection with named reasons. The official
  sendPhoto limits are encoded as documented defaults: 10 MB,
  width+height ≤ 10000, aspect ratio ≤ 20
  (https://core.telegram.org/bots/api#sendphoto, fetched 2026-09-30).
  Optional `--resize-if-over-limit` and `--normalize-exif` upload
  derivatives written to a temp dir; originals are never modified.
- **Reliability**: idempotent checkpoint store (SHA-256 + chat_id →
  message_id, atomic writes with fsync) — interrupted runs resume without
  resending; global + per-recipient token-bucket pacing; HTTP 429 waits the
  server-requested `retry_after` plus jitter; TRANSIENT (network/5xx)
  retries with exponential backoff up to `--max-attempts`; PERMANENT
  (400/403/404) is recorded without retry; FATAL (401) aborts immediately.
  Timeouts on every network call.
- **Safety rails**: explicit recipient allowlist (no discovery feature by
  design), per-recipient daily cap, optional quiet-hours window,
  kill-switch that halts a run when the failure rate over a rolling window
  exceeds the configured limit, graceful SIGINT/SIGTERM shutdown that
  finishes the in-flight send, flushes state and exits non-zero.
- **Reporting**: JSON Lines event log plus machine-readable `report.json`
  and `report.csv` per run; end-of-run summary built from real counters
  only (no estimated ETA). Exit codes: 0 all sent, 2 partial failure,
  3 fatal, 4 validation error.
- **Truthful errors**: network failures report network failures — never
  "token rejected"; `getMe` preflight fails fast on a bad token.
- **Engineering gates enforced in CI**: ruff lint + format, mypy strict
  (zero issues), 154 hermetic tests (no real network; a fake Bot API server
  runs on loopback), coverage floors (80% overall; 100% on the
  retry/backoff, rate-limiting, escaping and checkpoint modules), secret
  scanning, and a README↔parser contract test.
- **Dependencies**: PyYAML (config file parsing) and Pillow (image
  verification, dimensions, EXIF, resizing) only; HTTP uses the stdlib
  urllib with streaming multipart uploads.

Docs: `cli/README.md`, `cli/config.example.yaml`, `cli/docs/ARCHITECTURE.md`,
`cli/docs/SMOKE.md`, `cli/docs/MIGRATION.md`, `cli/docs/TEST_REPORT.md`.

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
