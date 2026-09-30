# Migration notes — config schema

## For operators of the Android app only

Nothing changes for you: the CLI is an independent component under `cli/`.
The app keeps its own on-device settings (secure token storage, recipients,
history). No data is migrated in either direction; the CLI reads only the
config you write for it.

## CLI config schema — version 1 (this release, 2.0.0)

This is the initial published schema for the CLI. If you wrote configs
against earlier development snapshots (before the repository's 2.0.0 tag),
apply the renames below. Every key is validated on load with the offending
key named in the error, so a missed rename fails fast with a precise
message rather than silently changing behaviour.

| Old (dev snapshot) | 2.0.0 | Notes |
|--------------------|-------|-------|
| `telegram.rate_limit_per_minute` | `limits.global_per_minute` | now a global token bucket |
| `telegram.flood_wait_margin` | (removed) | 429 `retry_after` is honoured directly; add jitter internally |
| `send.retries` | `send.max_attempts` | counts all attempts, including the first |
| `send.retry_base` | `send.backoff_base_seconds` | exponential backoff base |
| `recipients` (list of chat ids) | `recipients` (list of `{name, chat_id}`) | every target now needs a stable name used by manifests and `--recipient` |
| `security.token` | (removed) | tokens are never read from config; use `security.token_env` or `security.secrets_file` |

## Stability promises from here on

- Config keys are additive: new keys appear with safe defaults; existing
  keys keep their meaning.
- Unknown keys and wrong types are rejected at load time (typo protection),
  so a deprecated key can never silently become a no-op.
- Breaking schema changes will bump the minor version of this document and
  ship a row in this table plus a `CHANGELOG.md` entry.
