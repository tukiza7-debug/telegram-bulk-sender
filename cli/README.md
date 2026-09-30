# Telegram Bulk Image Sender (CLI + library) — v2.0.0

Production-grade command-line tool and importable Python library that sends
images in bulk through the **Telegram Bot API** to recipients who have
explicitly opted in: your own channels, groups you administer, users who
started your bot. It is the CLI component of the Telegram Bulk Sender
product; the Android app in this repository is the mobile companion.

**Start with `--dry-run`.** It prints the complete plan (file -> recipient ->
caption -> estimated API calls) and performs zero network calls.

## Install

Requires Python 3.11+.

```bash
cd cli
python -m pip install -e .
tbis --version
```

Dependencies are intentionally minimal: PyYAML (config parsing) and Pillow
(image verification, dimension checks, EXIF normalisation, resized
derivatives). Everything else is stdlib, including the HTTP client.

## The three modes

| Mode | Command | Behaviour |
|------|---------|-----------|
| Folder | `tbis folder --source-dir DIR` | deterministic natural-order queue (img2 < img10), optional recursion and globs, fan-out to all `--recipient`s |
| Manifest (one-by-one) | `tbis manifest --manifest PATH` | strictly sequential, manifest order preserved, resumable; concurrency forced to 1 |
| Single | `tbis single --file PATH --recipient NAME` | exactly one image; use it to verify a setup |

All three modes share one sending pipeline (validation -> planning ->
rate-limited execution -> checkpoint -> report).

## Quick start

```bash
# 1. configure the allowlist (recipients must be explicit)
cp config.example.yaml my.yaml
$EDITOR my.yaml

# 2. see what WOULD happen (no token needed, no network)
tbis folder --source-dir ./photos --dry-run --config my.yaml

# 3. send, keeping the token out of the shell history
export TELEGRAM_BOT_TOKEN="123456789:AA..."
tbis folder --source-dir ./photos --config my.yaml
```

## CLI reference

`tbis --help` and `tbis <command> --help` always show the authoritative list
(the test suite compares this section to the parser in both directions).
Use `--help` after any command for per-flag details; `--version` prints the
tool version.

```text
tbis folder --source-dir DIR [--no-recursive] [--include GLOB] [--exclude GLOB]
            [--order name|mtime|manifest-row] [--reverse]
tbis manifest --manifest PATH [--order manifest-row|name|mtime] [--reverse]
tbis single --file PATH
# common flags for every command:
#   --config PATH              config file (.yaml/.yml or .toml)
#   --dry-run                  print plan, exit, no network
#   --recipient NAME           allowlist name or chat_id, repeatable
#   --caption TEXT             template: {filename} {stem} {index} {total}
#                              {date} + custom manifest columns; {{ escapes
#   --caption-mode MODE        none | per-image | per-run | manifest-column
#   --limit N                  cap sends dispatched this run
#   --state-file PATH          checkpoint file (resume/dedupe)
#   --report-dir PATH          directory for run reports
#   --concurrency N            max parallel sends (default 1)
#   --max-attempts N           retry budget for transient errors (default 4)
#   --timeout-seconds S        per-request network timeout (default 60)
#   --resize-if-over-limit     send a resized derivative when needed
#   --normalize-exif           normalise EXIF orientation via a derivative
#   --api-base-url URL         Bot API base (default https://api.telegram.org)
```

### Config file, env, flags

Precedence: **CLI flags > environment (secrets only) > config file >
defaults**. The token is never read from the config file: set the env var
named by `security.token_env` (default `TELEGRAM_BOT_TOKEN`) or point
`security.secrets_file` at a git-ignored file. Unknown config keys and wrong
types fail at load time with the exact offending key in the message.

Every option is documented in [`config.example.yaml`](config.example.yaml).

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | every planned send succeeded (or dry run completed) |
| 2 | partial failure: some sends failed, or the run was interrupted or `--limit`ed |
| 3 | fatal: bad/revoked token, kill-switch triggered, broken checkpoint, config error |
| 4 | validation error: bad files, bad manifest, unknown recipients, usage error |

## Reliability model

- **Idempotent**: the checkpoint store records `(sha256, chat_id) ->
  message_id` after every delivery. A re-run never resends a delivered pair.
- **Pacing**: global and per-recipient token buckets; HTTP 429 waits the
  server-requested `retry_after` plus jitter before retrying.
- **Error taxonomy**: TRANSIENT (network, 5xx, 429) retries with exponential
  backoff + jitter up to `--max-attempts`; PERMANENT (400/403/404) is
  recorded without retry; FATAL (401) aborts the run immediately.
- **Timeouts on every network call**; the client connects directly and
  deliberately ignores proxy environment variables. There is no proxy,
  account or session rotation of any kind - rate limits are respected, never
  circumvented.
- **Kill-switch**: if more than `kill_switch.failure_rate` of the sends in
  the last `kill_switch.window_minutes` minutes failed (at least
  `kill_switch.min_sample` sends), the run halts and exits 3.
- **Graceful stop**: SIGINT/SIGTERM finish the in-flight send, flush the
  checkpoint, write the partial report and exit non-zero.

## Reports

Each run writes `reports/run-<run_id>/`:

- `log.jsonl` - one JSON object per event: run_id, timestamp, file,
  recipient, attempt, result, telegram_message_id, error_code, latency_ms;
- `report.json` - full machine-readable report including the effective
  (secret-free) configuration;
- `report.csv` - the same events as CSV for audit.

The end-of-run summary prints real counters only - no estimated ETA, no
guessed percentages.

## Image handling

jpg/jpeg/png/webp are supported. Files are verified by **magic bytes**, not
extension; truncated, zero-byte and over-limit files are rejected before the
queue with a named reason (the whole run refuses to start on any rejection -
nothing is skipped silently). sendPhoto limits from the official Bot API
docs are encoded as defaults: 10 MB per photo, width+height at most 10000,
aspect ratio at most 20. `--resize-if-over-limit` and `--normalize-exif`
upload a derivative written to a temp dir; the original file is never
modified and the report marks derivative sends.

Captions: variables are substituted first, then the whole string is escaped
for the configured `parse_mode`, so manifest data can never inject markup.

## Troubleshooting

- `error: no bot token found` - export `TELEGRAM_BOT_TOKEN` or configure
  `security.secrets_file`; the token must look like `<bot_id>:<secret>`.
- `recipient(s) not in the allowlist` - add the recipient to
  `recipients:` in the config, or reference it by its exact name/chat_id.
- `401 ... run aborted` - the token was rejected by Telegram itself. Check
  the token against the latest @BotFather message; the CLI sends only after
  a successful `getMe`, so a 401 here is genuinely a token problem.
- `network failure calling sendPhoto` - the network path failed (timeout,
  DNS, dropped connection). This is retried automatically and is never
  reported as a token problem.
- Resume after interruption: just run the same command again; delivered
  pairs are skipped (`skipped-duplicate` in the summary).

## Compliance notice

You are responsible for complying with Telegram's Terms of Service and
applicable anti-spam/privacy law. **Only message people who opted in.**
Sending targets must be explicitly allowlisted in the config; there is no
contact discovery, scraping, or auto-join feature, and none may be added.
Per-recipient daily caps and quiet hours exist to make respectful operation
the default. Never point this tool at real subscribers while testing - use a
test bot and a test chat (see `docs/SMOKE.md`).

## Development

```bash
cd cli
python -m pip install -e .[dev]
ruff check . && ruff format --check .
mypy
python -m pytest                     # unit + integration, no real network
python -m pytest -m slow             # adds the 1000-file perf sanity test
python scripts/secret_scan.py        # credential scan (also in CI)
```

Coverage floors: 80% overall, 100% on the retry/backoff, rate-limiting,
escaping and checkpoint modules. The suite runs with all non-loopback
networking disabled by an autouse fixture; integration tests talk to an
in-process fake Bot API server on 127.0.0.1.

See `docs/ARCHITECTURE.md` (pipeline, module responsibilities),
`docs/SMOKE.md` (manual checklist against a test bot) and
`docs/MIGRATION.md` (config schema notes).
