# Smoke test checklist (run against a TEST bot and a TEST chat)

Never run this against real subscribers. Create a dedicated test bot with
@BotFather and a private test group/channel; add the bot as an administrator
of the channel/group. Allowlist only the test chat in your config.

Prerequisites:

```bash
cd cli
python -m pip install -e .
export TELEGRAM_BOT_TOKEN="<TEST bot token from @BotFather>"
mkdir -p /tmp/tbis-smoke/photos && cd /tmp/tbis-smoke
# put 3-4 jpg/png files in photos/, including one named with two digits
# (e.g. img10.jpg) to see natural ordering.
```

Replace `news` below with the `name` of the allowlist entry pointing at your
TEST chat, and `my.yaml` with your config path.

| # | Step | Command | Expected |
|---|------|---------|----------|
| 1 | Version | `tbis --version` | prints `tbis 2.x.y`, exit 0 |
| 2 | Dry run | `tbis folder --source-dir photos --dry-run --recipient news --config my.yaml` | plan listing in natural order (img2 < img10), zero messages received in Telegram, exit 0 |
| 3 | Single send | `tbis single --file photos/img1.jpg --recipient news --config my.yaml` | exactly one photo arrives with caption (if configured); summary shows `sent: 1`; exit 0 |
| 4 | Full folder run | `tbis folder --source-dir photos --recipient news --config my.yaml` | every file delivered once; natural order; exit 0 |
| 5 | Idempotent re-run | repeat step 4 | nothing re-sent; summary shows `skipped-duplicate` = file count; exit 0 |
| 6 | Limit + resume | `tbis folder --source-dir photos2 --limit 1 --recipient news --config my.yaml` then same without `--limit` | first run sends 1 and reports `not-sent-limit` (exit 2); second run sends the rest, nothing duplicated |
| 7 | Caption escaping | config with `parse_mode: markdownv2` and caption `Shot {filename}`; a file named `my_file.jpg` | caption renders as `Shot my_file.jpg` (underscore literal, no broken markup) |
| 8 | Bad token | `TELEGRAM_BOT_TOKEN=123456789:WRONG` + step 3 | run aborts before sending; exit 3; message names the token rejection |
| 9 | No token | unset the env var + step 3 | `error: no bot token found`; exit 3 |
| 10 | Unknown recipient | `tbis single --file photos/img1.jpg --recipient ghost --config my.yaml` | `not in the allowlist`; exit 4; nothing sent |
| 11 | Bad file | add `notes.txt` to the folder; step 4 | `unsupported file type .txt`; exit 4; nothing sent |
| 12 | Wrong content | rename a text file to `fake.jpg`; step 4 | `content is not a JPEG/PNG/WebP image (magic bytes check)`; exit 4 |
| 13 | Kill-switch | config with `kill_switch: {failure_rate: 0.5, min_sample: 3}` and block all sends (e.g. point `api_base_url` at a closed port) | run halts with `kill-switch` in the output; exit 3 |
| 14 | Graceful interrupt | start step 4 with a large folder, press Ctrl-C once | in-flight photo finishes; partial report written; exit 2; re-run resumes without duplicates |
| 15 | Reports | inspect `reports/run-<run_id>/` | `log.jsonl`, `report.json`, `report.csv` exist; `report.json` contains the run's events and a config echo with no token |

Pass criteria: every step behaves as listed. Any deviation is a bug -
file the exact command, output and exit code.
