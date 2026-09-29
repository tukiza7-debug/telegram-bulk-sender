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
