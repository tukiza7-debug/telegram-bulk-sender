# Architecture

## Pipeline

Every mode (folder / manifest / single) flows through the same pipeline. No
mode has its own sending logic.

```
                CLI flags (win)      env / secrets file
                      |                      |
                      v                      v
                +-----------+        +-----------+
 config file -->|  Config   |        Bot token (never in config)
                |  Loader   |                |
                +-----------+                v
                      |               +-------------+
                      v               | TelegramCli |<----------------+
   +------------------ Source ------------------>|              |
   |   folder: DirectorySource   manifest: Rows   |              |
   |   single: one candidate                      |              |
   v                                              |              |
+-----------+      +---------+      +----------+   |              |
| Validator |----->| Planner |----->|  Queue   |---+              |
| (magic    |      | (dedupe,|      | (plan    |                  |
|  bytes,   |      | captions|      |  items)  |                  |
|  size,    |      |  order) |      +----------+                  |
|  dims)    |      +---------+           |                        |
+-----------+            |               v                        |
      |            dry-run print  +---------------------+        |
      |            (no network)   | RateLimitedExecutor |        |
      |                           |  token buckets      |        |
      |                           |  retry policy       |        |
      |                           |  kill-switch        |        |
      |                           +---------------------+        |
      |                                  |                       |
      v                                  v                       |
+---------------+   sends   +------------------+   records   |
| CheckpointStore|<---------|  TelegramClient  |-------------+
| (atomic JSON)  |  results | (HTTP | fake)    |
+---------------+          +------------------+
        ^  ^                       |
        |  +---------+             v
        |            |      +-----------+
        +------------+------| Reporter  |
     resume on next run     | JSONL/JSON/CSV
                            +-----------+
```

## Module responsibilities and public API

| Module | Responsibility | Key public API |
|--------|----------------|----------------|
| `config.py` | Typed config schema; YAML/TOML loading; strict validation naming the offending key; secret resolution (env var / git-ignored file only) | `Config`, `load_config`, `parse_config`, `resolve_token` |
| `model.py` | Data vocabulary: recipients, candidates, validated images, plan items, outcomes, run summary | `Recipient`, `ImageCandidate`, `ValidatedImage`, `PlannedSend`, `SendOutcome`, `RunSummary`, enums |
| `errors.py` | The single error taxonomy and exit codes | `TbisError` hierarchy, `ErrorKind`, `classify_http_status`, `ExitCode` |
| `discovery.py` | Directory scan, glob include/exclude, ordering by name/mtime | `scan_directory`, `order_candidates`, `IMAGE_EXTENSIONS` |
| `formats.py` | Magic-byte format detection (single source of truth) | `sniff_format` |
| `validation.py` | Real-image verification, size/dimension/ratio limits, truncation detection, EXIF normalisation, resized derivatives | `validate_image`, `build_derivative`, `ImageRejected` |
| `hashing.py` | Streaming SHA-256 (bounded memory) | `sha256_of_file`, `CHUNK_SIZE` |
| `ordering.py` | Deterministic natural sort key | `natural_key` |
| `captions.py` | Variable substitution then parse-mode escaping | `render_caption`, `escape_caption`, `build_and_escape`, `check_template` |
| `ratelimit.py` | Global + per-recipient token buckets; `reserve()` returns the wait (no hidden sleeps) | `RateLimiter`, `TokenBucket` |
| `backoff.py` | Retry policy: exponential backoff + jitter; honours 429 `retry_after` | `RetryPolicy` |
| `state.py` | Checkpoint store; atomic writes; cross-run dedupe; daily-cap counting | `CheckpointStore` |
| `sources.py` | Manifest (CSV/JSON) reading with row-accurate validation | `read_manifest`, `ManifestRow` |
| `planner.py` | Builds the ordered plan for all three modes; cross-run dedupe; caption assembly | `Planner`, `PlanBuild` |
| `executor.py` | Bounded-concurrency dispatch, pacing, retries, kill-switch, graceful stop | `RateLimitedExecutor`, `RunResult` |
| `reporter.py` | JSONL event log, JSON+CSV reports, human summary | `Reporter`, `format_summary` |
| `runner.py` | Pipeline wiring, client construction, temp-dir ownership, exit-code mapping | `run`, `RunRequest`, `RunResult`, `ClientFactory` |
| `signals.py` | SIGINT/SIGTERM -> stop event (all real work stays in the pipeline) | `GracefulStop` |
| `cli.py` | Argument parsing for `folder`/`manifest`/`single`; exit codes | `main`, `build_parser` |
| `telegram/base.py` | The client interface (the only network boundary) | `TelegramClient`, `BotUser`, `SentMessage` |
| `telegram/http_client.py` | Real client: stdlib urllib, streaming multipart, timeouts, direct connection | `TelegramHttpClient`, `MultipartBody` |
| `telegram/fake.py` | In-memory client with a scriptable outcome queue | `FakeTelegramClient` |

## Invariants

1. **One pipeline.** Modes differ only in the source that produces
   (image, recipient) pairs. Any new mode must reuse `Planner` +
   `RateLimitedExecutor`.
2. **Interface isolation.** Only `runner.py` imports the real HTTP client.
   Business logic depends on `telegram.base.TelegramClient`; tests inject
   `FakeTelegramClient` or a loopback fake HTTP server.
3. **Shared behaviour in one place.** Retry/backoff in `backoff.py`,
   pacing in `ratelimit.py`, escaping in `captions.py`, state in
   `state.py`, format detection in `formats.py`. Nothing re-implements
   these.
4. **Pure policy, injected time.** Pacing and backoff compute delays;
   the executor sleeps through injected `sleeper`/`clock` functions, so
   the timing tests never wait in real time.
5. **Failure is data.** Every planned send ends in exactly one
   `ResultStatus`, recorded to the JSONL log and both report files.
   Unexpected internal exceptions are recorded and then re-raised - never
   swallowed.
6. **Secrets never cross into config or reports.** The token lives in env
   or a git-ignored file; `Reporter._redact` echoes the config without any
   secret material.
