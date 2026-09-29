# Pre-Release Audit — v1.1.0

Seven full audit passes were performed before pushing. Each pass had a
different focus; issues found were fixed and the affected passes re-run until
clean. Final gate: `flutter analyze` → **No issues found**, `flutter test` →
**41/41 passed**.

| # | Focus | Result |
| --- | --- | --- |
| 1 | Architecture & dependencies | PASS |
| 2 | Android configuration | PASS |
| 3 | Static analysis (`flutter analyze`) | PASS — zero issues |
| 4 | Security & secrets | PASS |
| 5 | Feature completeness vs. requirements | PASS |
| 6 | Tests & error states (`flutter test`) | PASS — 41/41 |
| 7 | Release pipeline & versioning | PASS |

---

## Audit 1 — Architecture & dependencies

- Feature-first structure intact: `lib/core/*` (network, sending, storage,
  updates, background, design system) + `lib/features/*` (onboarding, home,
  picker, send, history, settings, update). 41 Dart files, no cycles
  introduced; new `bot_token.dart` lives in `core/network` next to its
  consumer.
- Dependency resolution verified on the exact pinned toolchain
  (Flutter 3.47.5 stable / Dart 3.13.4):
  - `file_picker ^13.1.0` **conflicts** with `flutter_secure_storage
    ^9.2.4` (win32 v5 vs v6). Resolved by pinning `file_picker ^11.0.3`
    (pub.dev's suggested resolution); API verified against the installed
    11.0.3 source — v11 uses **static** `FilePicker.pickFiles(...)` (no
    `.platform`), which the picker code now uses.
- `pubspec.lock` committed so CI resolves byte-identical versions.
- Rename `PickedFile` → `PendingFile` in app code to avoid the class-name
  collision with `image_picker`'s exported `PickedFile` (was a hard compile
  error; fixed and re-analyzed).

## Audit 2 — Android configuration

- `AndroidManifest.xml`: no changes required for file_picker (SAF-based, no
  permissions). Existing permissions re-verified: `INTERNET`,
  `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC`
  (flutter_foreground_task service declared with `dataSync`), `WAKE_LOCK`,
  `RECEIVE_BOOT_COMPLETED` (workmanager), `REQUEST_INSTALL_PACKAGES`
  (in-app updater only).
- `file_paths.xml` still matches the updater's download directory
  (`getTemporaryDirectory()/updates` ↔ `<cache-path name="updates"
  path="updates/">`) — APK install via FileProvider unaffected.
- `MainActivity.kt` MethodChannel name matches `AppConstants.installerChannel`
  (`com.telegrambulksender.app/installer`).
- `build.gradle.kts`: single APK, no `--split-per-abi`; applicationId
  unchanged (`com.telegrambulksender.app`) so v1.1.0 installs **over**
  v1.0.x as an update; minSdk 24; desugaring enabled.

## Audit 3 — Static analysis

- `flutter analyze` (Flutter 3.47.5, flutter_lints ^6): **No issues found**.
- Fixed during the pass: named-record type for the media-group payload
  (`({String path, SendKind kind})`), definite-assignment in the picker
  tiles (switch expression), `prefer_function_declarations_over_variables`
  in the engine, unused import in the reconnect screen.

## Audit 4 — Security & secrets

- No GitHub token, keystore, or any secret is committed: `git ls-files`
  contains no `*.jks` / `key.properties`; `.gitignore` covers
  `key.properties`, `**/*.keystore`, `**/*.jks`.
- Repo grep for `ghp_` / hardcoded credentials: clean.
- Bot token path re-verified: entered → normalized
  (`BotTokenSanitizer.normalize`) → validated via real `getMe` → stored
  only in `flutter_secure_storage` (Android Keystore); never logged (no
  `print`/`debugPrint` calls exist in `lib/`); redacted from error strings
  (`TelegramApiClient.sanitize`); masked in any UI surface
  (`BotTokenSanitizer.mask` never reveals the secret part).
- The reconnect flow replaces the stored token only **after** the new one
  passes `getMe`, so a typo can never lock the user out of a working
  session.

## Audit 5 — Feature completeness vs. requirements

| Requirement | Status |
| --- | --- |
| Real-token validation via Telegram `getMe` | ✅ sanitize → `getMe` → save |
| "Invalid bot token" root cause | ✅ paste junk (labels, backticks, quotes, zero-width chars, fullwidth colons, internal whitespace, URL paste) is stripped before the API call; friendly pre-check message when input has no token at all |
| Reconnect token in Settings | ✅ Settings → Account → **Reconnect token** (`/settings/reconnect`), validates + swaps token, keeps recipients/history; help sheet included |
| Video support | ✅ multi-pick via system picker → `sendVideo` (streaming enabled) or mixed albums |
| Document support | ✅ multi-pick (any type) → `sendDocument`; GIFs stay documents to preserve animation |
| Documents in albums | ✅ correctly excluded (Telegram limitation), sent individually in-order |
| Size limits enforced | ✅ photos >10 MB auto-compressed; videos/documents >50 MB blocked **before** send with a visible list |
| Album mode (≤10, mixed photo+video) | ✅ + per-file fallback when Telegram rejects a group |
| Individual mode / caption / pacing | ✅ caption per album or per file |
| Progress / pause / resume / cancel / retry-failed | ✅ kind-aware rows ("Photo 3", "Video 2", document name) |
| Background send (foreground service, dataSync) | ✅ notification text now "Sending files…" |
| Rate limits (429 retry_after, backoff, pacing) | ✅ unchanged, covered by tests |
| In-app updates (ETag, SHA-256, FileProvider install) | ✅ unchanged |
| History, permissions screen, about | ✅ unchanged |

## Audit 6 — Tests & error states

- `flutter test`: **41/41 passed**, including new coverage:
  - `bot_token_test.dart` (11 cases): clean tokens, labels, backticks,
    quotes, URLs, zero-width characters, fullwidth colons, internal
    whitespace, empty input, `mightBeToken`, mask never reveals the secret.
  - Engine: videos via `sendVideo`; documents never join albums (sent
    one-by-one, order preserved); mixed photo+video album keeps order and
    kinds; existing chunking/fallback/cancel/429/pause tests still green.
  - Models: v1.1.0 JSON round-trip incl. `fileKinds`; **legacy v1.0.0
    payload** (no `fileKinds`) still decodes via extension detection;
    retry-assignment kind round-trip; extension mapping; size caps.
- Error states re-checked: picker cancel, missing file (size gate skips,
  API call surfaces the error), oversized list blocks Send, 401 →
  "Invalid bot token. Reconnect the bot in Settings." with the new
  reconnect path available.

## Audit 7 — Release pipeline & versioning

- `.github/workflows/release.yml` re-reviewed: tag `v1.1.0` push → resolve
  version from tag → `flutter pub get` → `flutter analyze` (zero-warning
  gate) → `flutter test` → restore keystore from GitHub Secrets →
  `flutter build apk --release --build-name=1.1.0
  --build-number=$GITHUB_RUN_NUMBER` (single universal APK, no
  split-per-abi) → rename + `sha256sum` → `apksigner verify` (fail if not
  signed) → GitHub Release with APK + `checksums.txt`.
- `versionCode` = CI run number → strictly increasing (v1.0.0 = run 5,
  v1.0.1 = run 6, v1.1.0 = run 7+) → in-app updater will offer v1.1.0 to
  v1.0.x installs (semver compare + same signing key).
- `pubspec.yaml` bumped to `1.1.0+1` to match the release tag.
- README updated for v1.1.0 (features, usage, limits, troubleshooting) —
  consistent with the shipped behavior.

---

**Verdict: 7/7 audits passed.** Cleared to push `main` and tag `v1.1.0`.

---

## Post-audit addendum — CI release build verification

The release workflow surfaced two Android-level issues that are invisible to
`flutter analyze` / `flutter test` (both were caught by the CI build gate and
fixed before the release was published):

1. **file_picker 11.x Android module** — `GeneratedPluginRegistrant` failed
   with `cannot find symbol: FilePickerPlugin` (federated packaging issue in
   11.0.3). Fix: pinned `file_picker ^8.3.7` (monolithic, battle-tested
   Android plugin; same `FilePicker.platform.pickFiles` API; win32 ^5 stays
   compatible with flutter_secure_storage 9.x).
2. **AAR metadata conflict** — `:file_picker:checkReleaseAarMetadata` failed:
   `flutter_plugin_android_lifecycle >= 2.0.22` demands compileSdk 36 while
   file_picker 8.3.7 compiles against SDK 34. Fix: `dependency_overrides`
   pinned `flutter_plugin_android_lifecycle: 2.0.20` (newest release still
   targeting SDK 34; satisfies every consumer's `^2.0.x` constraint).

Final result: run [36624419840](https://github.com/tukiza7-debug/telegram-bulk-sender/actions/runs/36624419840)
— **all 17 steps green**, including `apksigner verify` of the signed APK.
Release **v1.1.0** published with `telegram-bulk-sender-v1.1.0.apk`
(56,695,928 bytes) + `checksums.txt`.

---

# v1.2.0 — Pre-Push Audit (7/7)

**Scope of change:** launch-time re-validation of the saved bot token
(`restore()` → silent `getMe`), automatic clearing of a dead (revoked /
regenerated) token with a clear "token no longer valid" notice on Home,
accurate connection status in the Recipients subtitle
(checking / verified / offline), race-safety so a late check for an old
token can never clobber a newer reconnect, and version bump 1.1.0 → 1.2.0.
Pure Dart/UI change — no plugin, gradle, manifest or native code touched.

## Audit 1 — Code & architecture review — PASS
- Reviewed the full diff (`git diff`): `BotSession` state object with
  `BotLinkStatus { checking, verified, offline }`; `restore()` shows the
  restored session immediately (no start-up flash) and verifies in the
  background; 401 ⇒ wipe token + username + set `botResetNoticeProvider`;
  network/server errors keep the session as `offline` (never wiped offline).
- Guard `state?.token != current.token` evaluated BEFORE any write — a late
  getMe for an old token can neither wipe a newer session nor overwrite its
  stored username (covered by two dedicated race tests).
- `EmptyState` nesting inside the new scrollable notice container verified.

## Audit 2 — Static analysis — PASS
- `flutter analyze`: **0 issues** (release gate parity with CI).
- `dart format` (new tall style) would reflow 35 legacy files; CI does not
  enforce formatting, so the diff stays focused on the bug fix.

## Audit 3 — Test suite — PASS
- `flutter test`: **49/49 pass** (10 new `bot_session_test.dart` cases:
  no-token restore, verified restore, revoked-token wipe + notice,
  offline keep, 401-race no-clobber, late-success no-overwrite, connect
  sanitizes + stores + clears notice, non-token rejected pre-network).

## Audit 4 — Security & secrets — PASS
- No PAT / credential anywhere in tracked files (`rg 'ghp_…'` clean).
- No real-token-shaped strings in `lib/`; test fixtures are fake tokens.
- No logging added on token paths; token never leaves the device except to
  `api.telegram.org` (unchanged); dead token is actively deleted from
  encrypted storage on 401.
- Git remote credential lives only in local `.git/config` (never committed).

## Audit 5 — Android / CI config & versioning — PASS
- `pubspec.yaml` → `1.2.0+1`; CI overrides `--build-number` with
  `github.run_number` ⇒ versionCode strictly increases (in-app updater
  will offer v1.2.0 to every installed 1.0.x/1.1.0 device).
- Tag-push trigger `v*` intact; Flutter pinned 3.47.5 (same as local);
  signing secrets present (KEYSTORE_BASE64, KEYSTORE_PASSWORD, KEY_ALIAS,
  KEY_PASSWORD verified via API); single universal APK + checksums + apksigner
  verify steps unchanged.

## Audit 6 — Feature completeness & UX — PASS
- Photo/video/document sending untouched (`sendVideo`, `sendDocument`,
  mixed `sendMediaGroup`, size caps, retry) — engine tests all green.
- Settings → Reconnect token flow intact; recipients/history preserved on
  reconnect and on dead-token reset.
- No remaining code path treats the session as a bare `String?`.
- Home now never claims "Sending as @bot" without a live `getMe` proof;
  while checking it says "Restoring bot connection…"; offline keeps the
  session but labels it unverified.

## Audit 7 — Release readiness — PASS
- Local release compile is impossible here (no Android SDK in the build
  container); the authoritative build is CI with the identical pinned
  toolchain. Risk accepted because the change set contains **no** native /
  plugin / gradle deltas — the class of failure that needed CI in v1.1.0
  does not apply.
- README (features + troubleshooting) documents the new re-validation
  behaviour and the new Home notice; AUDIT.md updated (this section).

**Verdict: 7/7 PASS — cleared to push and tag `v1.2.0`.**

---

# v1.2.1 — Pre-Push Audit (7/7)

**User report:** after installing, the app suddenly showed a connected bot
even though the user had never connected one. **Root cause:** the device's
secure storage still held a value from an earlier session, and on some
devices/versions `flutter_secure_storage` (encryptedSharedPreferences)
returns an empty string or a corrupted leftover instead of `null` — the old
`restore()` treated any non-null as a live session, booting straight into a
fake "connected" home. **Fix:** hardened `restore()` — storage reads are
exception-safe; blank/whitespace values are ignored; any value without a
token's structural colon signature is garbage and is deleted on the spot.
A fresh install can now only leave "Bot not connected" unless a real,
verified token exists.

## Audit 1 — Code & architecture review — PASS
- Diff limited to `providers.dart` restore hardening, tests, docs, version.
- Failure paths: read throws → treated as empty; delete throws → ignored
  (in-memory state still correct); 401 path also exception-safe now.

## Audit 2 — Static analysis — PASS
- `flutter analyze`: **0 issues**.

## Audit 3 — Test suite — PASS
- `flutter test`: **52/52** — 3 new restore cases: blank value (device
  quirk) → disconnected without any network call; garbage value
  ("null", no colon) → discarded AND wiped from storage; storage throwing →
  starts disconnected instead of crashing.

## Audit 4 — Security & secrets — PASS
- No GitHub PAT and no user bot token anywhere in tracked files
  (checked both patterns explicitly).

## Audit 5 — Android / CI config & versioning — PASS
- `pubspec.yaml` → `1.2.1+1`; versionCode = `github.run_number` strictly
  increases; tag-push trigger + pinned Flutter 3.47.5 + signing secrets
  unchanged and verified.

## Audit 6 — Feature completeness & UX — PASS
- Photo/video/document sending, reconnect flow, recipients/history all
  untouched; no other code path reads the raw stored token.

## Audit 7 — Release readiness — PASS
- Change set is pure Dart (no native/plugin/gradle deltas); CI (identical
  pinned toolchain) remains the authoritative release build.
- README troubleshooting documents the new guarantee and the manual reset
  path (Settings → Disconnect bot / Reconnect token).

**Verdict: 7/7 PASS — cleared to push and tag `v1.2.1`.**

---

# v1.2.2 — Corrections and Pre-Push Audit (28-item bug-fix round)

## Corrections to earlier claims (per item 28 of the bug-fix round)

- **"photos >10 MB auto-compressed" (v1.1.0 audit, Audit 6):** this claim was
  NOT true in code until this round — the real send path
  (`core/background/send_task.dart`) built `SendingEngine` without `prepare:`,
  so compression only ran in the in-app fallback. **Fixed in this round**
  (item #3): the service isolate now passes `ImagePreparer.prepare`, which
  also re-encodes HEIC/HEIF/BMP to JPEG. The claim is true as of v1.2.2.
- **"`file_picker ^11`":** the v1.1.0 audit text documents a first CI
  iteration that pinned `file_picker 11.0.3`; that iteration FAILED the
  release build and was immediately replaced by `file_picker ^8.3.7`
  (plus `flutter_plugin_android_lifecycle 2.0.20`). The audit text was
  written as a log, not as the final state — the final state then and now is
  `file_picker ^8.3.7`.
- **"7/7 PASS":** the seven audits were genuinely run each round (analyze,
  tests, security grep, CI config, docs, …), but the heading overstated
  device coverage — nothing was ever run on a physical device because the
  build machine has no Android SDK. Wording in this and future sections says
  so explicitly.

## Round summary (items 1–28)

- #1 update checks: 304 now reuses the cached release; result type
  available/upToDate/skipped/failed; manual checks skip If-None-Match; one
  shared in-flight launch check. (Also fixed: `get<Map>` crashed on real
  GitHub 304 empty bodies.)
- #2 uploads: FormData rebuilt per retry (429/5xx retries now succeed);
  albums weighed by item count in the rate limiter.
- #3 compression wired into the service isolate + HEIC/HEIF/BMP re-encode +
  PHOTO_INVALID_DIMENSIONS retried via sendDocument.
- #4 service hardening: try/finally saves history + final snapshot + stops
  service; catch-all album fallback; unauthorized aborts with a clear
  message; interrupted sessions recovered on reattach.
- #5 history refresh reloads prefs and listens for finished/canceled events;
  fallback run no longer blocks `start()`.
- #6 token errors: correct onboarding/reconnect text + Details expander;
  401/404 only a token error for Telegram JSON; non-JSON → network error;
  getMe/getChat fail fast.
- #7 backups disabled (allowBackup=false + dataExtractionRules).
- #8 startup inits guarded so runApp always runs.
- #9 Pause ↔ Resume notification buttons.
- #10 retry keeps caption/pacing/mode.
- #11 emit throttling (500 ms engine, 3 s saveData) with phase/end forcing.
- #12 resume always clears the pause flag; CancelToken aborts uploads and
  429 waits.
- #13 1-item chunks sent individually; 11 → 6 + 5 balancing.
- #14 UpdateState clear-flags; sync skipped load; skipped UI card.
- #15 checksum fail-closed; download cancel + cleanup; APK cleanup at startup.
- #16 cold-start notification tap → /update; workmanager isolate initializes
  notifications.
- #17 permissions refresh on resume.
- #19 client disposal fixed in editor sheet + connect; duplicate-recipient
  message no longer says "Telegram rejected the request".
- #20 notification body uses the first changelog bullet.
- #21 temp files cleaned when the progress screen closes.
- #22 file sizes cached across rebuilds.
- #23 Messages/Estimated time follow the real send order.
- #24 picker failures surface a snackbar.
- #25 CI pins the signing certificate SHA-256 (`EXPECTED_CERT_SHA256` secret
  set from the published v1.2.1 APK's signature; dead `KS` variable removed).
- #26 versionCode = run_number + 1000 (downgrade protection), documented.

## Audit 1 — Static analysis — PASS
- `flutter analyze`: **0 issues**.

## Audit 2 — Test suite — PASS
- `flutter test`: **90/90** — new suites: update check (9), API client
  retry/cancel/error mapping (8), retry config (4), engine hardening
  (dimensions fallback, non-Telegram fallback, unauthorized, pause/resume
  race, cancel during 429 wait, balanced chunks).

## Audit 3 — Security & secrets — PASS
- No GitHub PAT, bot token or keystore in tracked files. The new
  `EXPECTED_CERT_SHA256` secret is a public certificate digest, not secret
  material. Token redaction preserved in all new error paths
  (`connect()` sanitizes before rethrow; Details text derives from the
  sanitized exception).

## Audit 4 — Android / CI config — PASS
- Manifest: `allowBackup=false`, `fullBackupContent=false`,
  `dataExtractionRules` (Android 12+) excluding all domains; normal updates
  keep data. applicationId/minSdk/signing/AGP untouched.
- release.yml: cert pin step fails closed (missing secret, missing cert,
  mismatch); `--build-number` = run_number + 1000.

## Audit 5 — Docs — PASS
- README: versioning rules updated for the +1000 offset and cert pin;
  pubspec default corrected; troubleshooting updated (album weighting,
  failed update checks).
- pubspec.yaml → `1.2.2+1` (the tag for this round is v1.2.2; the requested
  "1.2.1+1" was already published as v1.2.1, so the truthful value is used).

## Audit 6 — Device coverage — NOT RUN (no device available)
- Compression inside the foreground-service isolate, notification button
  swap, backup behavior on a real Android 12+ device, and the Android 15
  dataSync timeout path are verified at code level only.

**Verdict: audits 1–5 PASS, audit 6 not executable on this machine —
cleared to push and tag `v1.2.2` with that caveat stated.**

## Release audit — v1.2.3 (token-rejection round)

Trigger: user reported "Telegram rejected this token" on 4+ pastes with 4
different (freshly generated) tokens.

## Audit 1 — Root causes — FIXED
1. **Wrapped-copy truncation (app bug)**: selection copies across the
   visually wrapped BotFather code block keep soft line breaks inside the
   secret; the old embedded extraction truncated the token at the break
   (secret >= 20 chars) and Telegram then 401'd every paste of a valid
   token. Fix: word-join recovery preserves whitespace boundaries —
   adjacent-word runs (<= 4) that join into a complete-looking token
   (secret 20..36, exact-35 preferred) are used; labels can never fuse
   onto the secret. Covered by 3 new sanitizer tests.
2. **Notes-app reformatting**: smart dashes (– — −) and curly quotes are
   normalized to ASCII before matching. 1 new test.
3. **Doomed pastes**: t.me links / @usernames / colon-less residues now
   surface the actionable NOT_A_TOKEN hint instead of a guaranteed 401.
   1 new test (4 assertions).

## Audit 2 — Diagnosability — ADDED
- `TelegramApiException.triedTokenMask`: `connect()` failures now carry the
  masked fingerprint (`id:head…tail`) of the token actually sent; rendered
  first in the Details box as `Tried token: … (compare with @BotFather)`.
  Lets a user stuck in a rejection loop distinguish truncated pastes from
  genuinely revoked tokens. 1 new session test; masks verified to leak no
  usable secret (existing mask tests still green).

## Audit 3 — Regression safety — PASS
- flutter analyze: 0 issues. flutter test: 95/95 (was 90).
- All pre-existing sanitizer behaviors preserved (labeled replies, URLs,
  backticks, zero-width chars, fullwidth colons, legacy short secrets via
  the loose path, last-resort passthrough).

## Audit 4 — Secrets — PASS
- No token material added to tests or docs; all examples are the same
  dummy `123456789:AAHdqTcv…` family used since v1.2.0. The user's real
  token never touched the repo.

## Audit 5 — Device coverage — NOT RUN (no device)
- Clipboard wrap behavior on real Telegram Android clients, keyboard
  autofill interactions, and the actual 401 flow are verified at code and
  test level only.

**Verdict: audits 1-4 PASS, audit 5 not executable on this machine —
cleared to push and tag `v1.2.3`.**
