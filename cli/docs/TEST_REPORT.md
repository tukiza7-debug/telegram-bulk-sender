# Test report — v2.0.0

Environment: Python 3.12.14, pytest, Pillow 11.3, PyYAML 6.0.
Command: `python -m pytest` (unit + integration) and
`python -m pytest -m slow` (perf sanity). All runs execute with an autouse
fixture that refuses any non-loopback socket connection, so the suite cannot
touch the real network; integration tests speak to an in-process fake Bot
API server on 127.0.0.1.

## Result: 154 passed, 0 failed, 0 skipped

## Coverage

- Overall (branch coverage): **89.7%** (floor: 80%)
- 100% floor modules (enforced separately in CI):
  - `backoff.py` (retry/backoff policy) — 100%
  - `ratelimit.py` (token buckets) — 100%
  - `captions.py` (escaping) — 100%
  - `state.py` (checkpoint store) — 100%
- Notable non-100% modules and why:
  - `cli.py` (92%): the double Ctrl-C `KeyboardInterrupt` branch and the
    `main()` entry guard are only reachable interactively.
  - `discovery.py` (73%): permission-denied and stat-failure branches of the
    directory walk are not simulated; behaviour is delegated to `os` errors
    that the runner converts to validation errors.
  - `signals.py` (76%): the "cannot install handlers outside the main
    thread" path requires a second thread running `install()`.
  - `errors.py` (75%): the generic 4xx fallback and a few rarely-hit
    constructors (kept for completeness of the taxonomy).

## Coverage by spec area (§7)

| Area | Where | Evidence |
|------|-------|----------|
| Natural sort | `tests/test_ordering.py` | img2 < img10; casefold + raw tiebreak; leading-zero determinism; unicode |
| Dedupe | `tests/test_planner.py`, `test_state.py` | within-run, across-run via checkpoint, toggleable |
| Magic-byte validation | `tests/test_validation.py` | JPEG/PNG/WebP signatures; extension/content mismatch; zero-byte; truncated PNG + JPEG EOI; size limit |
| Caption templating + escaping | `tests/test_captions.py` | variables, custom columns, literal braces; HTML/Markdown/MarkdownV2 escaping with hostile inputs; substitute-then-escape order |
| Rate limiter timing | `tests/test_ratelimit.py` | burst, refill, overdraw queueing, per-recipient isolation, global cap, max-wait semantics — under a fake clock |
| Backoff schedule | `tests/test_backoff.py` | doubling, cap, jitter bounds, retry_after + jitter, classification gates |
| Error-code classification | `tests/test_backoff.py`, `test_http_client.py`, `test_executor.py` | 400/403/404 permanent; 401 fatal; 429 + retry_after; 5xx transient; non-JSON transient |
| Checkpoint resume | `tests/test_state.py`, `test_runner_integration.py` | atomic write, reload, idempotent re-run, limit+resume |
| Config validation errors | `tests/test_config.py` | unknown keys, type errors, range errors, quiet-hours schema, recipient schema, token shape |
| Full folder run (fake Bot API) | `tests/test_runner_integration.py`, `test_failure_injection.py` | end-to-end through the real HTTP client against the loopback fake server |
| Interrupted-and-resumed run | `test_runner_integration.py::test_limit_then_resume...`, SMOKE step 14 (manual) | no resend of delivered pairs |
| Mixed success/failure | `test_runner_integration.py::test_mixed_failure_is_partial_exit` | exit 2 with truthful counters |
| 429 burst | `tests/test_executor.py::test_rate_limited_waits_server_retry_after`, `test_http_client.py::test_429...` | server-requested wait honoured, then delivery succeeds |
| Determinism | `tests/test_determinism.py` | identical queue order and report (modulo run ids/timestamps/message ids/latencies) |
| Failure injection: disk full | `tests/test_state.py::test_disk_full_on_state_write`, `test_failure_injection.py::test_disk_full...` | StateError propagates; nothing continues silently |
| Failure injection: malformed image | `tests/test_failure_injection.py::test_malformed_image...` | whole run refuses with named file; no network touched |
| Failure injection: token revoked mid-run | `tests/test_failure_injection.py::test_token_revoked...` | aborts immediately, exit 3, delivered-so-far checkpointed |
| Failure injection: network drop | `tests/test_failure_injection.py::test_network_drop...`, `test_http_client.py::test_connection_drop...` | IncompleteRead classified TRANSIENT and retried |
| Perf sanity | `tests/test_perf.py` | 1,000-file dry run < 30 s; hashing proven to read in <=CHUNK_SIZE chunks |
| README ↔ parser contract | `tests/test_readme_contract.py` | flags compared both directions; exit-code table matches `ExitCode` |
| Secret scanning | `tests/test_secret_scan.py` | clean tree; planted bot token/AWS key detected; synthetic fixtures pass |
| No-network gate | `tests/conftest.py` | autouse socket guard blocks every non-loopback destination |

## Not covered (and why)

- **Real api.telegram.org end-to-end**: intentionally excluded. The suite is
  hermetic by design; the manual smoke checklist (`docs/SMOKE.md`) covers
  the real-service path against a TEST bot, and its results depend on live
  credentials that must never be committed.
- **GUI/interactive flows**: none exist (CLI only).
- **Windows path semantics**: developed and tested on Linux; `_upload_filename`
  normalises both separators, but no CI Windows runner is configured yet.
- **Multi-process state locking**: the checkpoint assumes one run per state
  file at a time (documented). Concurrent runs on the same state file are
  operator error and not defended against beyond JSON corruption detection.
