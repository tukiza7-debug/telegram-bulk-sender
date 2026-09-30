# Telegram Bulk Sender

**Send photos, videos and documents to your Telegram chats, groups and channels — in bulk, with progress, retries and rate-limit handling.**

[![Latest release](https://img.shields.io/github/v/release/tukiza7-debug/telegram-bulk-sender?include_prereleases&label=release)](https://github.com/tukiza7-debug/telegram-bulk-sender/releases/latest)
[![Build](https://img.shields.io/github/actions/workflow/status/tukiza7-debug/telegram-bulk-sender/release.yml?branch=main&label=build)](https://github.com/tukiza7-debug/telegram-bulk-sender/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/licence-MIT-green.svg)](LICENSE)

Telegram Bulk Sender is a native Android app (Flutter) that drives the
**Telegram Bot API** to bulk-send media: pick many photos, videos and
documents, choose the recipients, and let the app deliver them as albums (up
to 10 photos/videos per message) or as individual files — with a live
progress screen, pause/cancel, automatic HTTP 429 handling, and sending that
continues in the background via a foreground service.

## Screenshots

Placeholders live in [`docs/screenshots/`](docs/screenshots/) and are named
after the screens they show:

| File | Screen |
| --- | --- |
| `01_onboarding.png` | Bot token onboarding |
| `02_home.png` | Home — recipients management |
| `03_picker.png` | File picker grid (photos, videos, documents — reorderable) |
| `04_review.png` | Send review (mode, caption, pacing) |
| `05_progress.png` | Live send progress |
| `06_settings.png` | Settings (reconnect token, permissions, updates, about) |

## Features

- **Bot token onboarding** — validate with `getMe` before saving; the token
  is stored encrypted (`flutter_secure_storage`) and never logged.
- **Paste-proof token handling** — tokens copied out of @BotFather messages,
  URLs, password managers or notes are cleaned automatically before
  validation: labels like "Token:", Markdown backticks, quotes, zero-width
  characters, fullwidth colons and internal whitespace are all stripped, so
  a **real token validates on the first try**.
- **Reconnect token from Settings** — if the token was regenerated with
  `/revoke` in @BotFather (or the app reports "Invalid bot token"),
  **Settings → Reconnect token** lets you validate and replace it without
  losing recipients or history.
- **Launch-time token re-validation** — the saved token is re-checked with
  `getMe` every time the app starts. If the token has since been revoked or
  regenerated in @BotFather, the app no longer pretends to be connected: the
  dead token is cleared and a clear "token no longer valid" notice asks you
  to reconnect. Offline launches keep the session and simply mark the
  connection as unverified.
- **Recipients** — save any number of chat IDs or `@channelusernames`,
  verified through `getChat` before they are saved. Add, rename, remove.
- **File picking: photos, videos, documents** — photos via the Android
  system Photo Picker, videos (MP4, MOV, MKV, WebM…) and any documents
  (PDF, ZIP, GIF, audio…) via the system file picker — all multi-select,
  all without any storage permission. Grid preview with kind badges,
  long-press drag to reorder, remove individual files.
- **Two send modes** — `sendMediaGroup` albums (max 10, photos and videos
  can be mixed) or individual `sendPhoto` / `sendVideo` / `sendDocument`
  per file, with optional caption and configurable pacing between batches.
  Documents are always sent as individual messages (Telegram does not allow
  them in media groups).
- **Rate-limit aware** — proactive per-chat pacing, HTTP 429 handled with
  `retry_after`, exponential backoff for transient errors, and automatic
  resume after network failures.
- **Live progress** — per-file status ("Photo 3", "Video 2", the document's
  name), success/fail counts, pause, resume, cancel, and one-tap **retry of
  exactly what failed**.
- **Background sending** — the whole session runs in a foreground service
  (`dataSync` type, Android 14+ compatible) with a progress notification and
  notification action buttons.
- **Oversized file handling** — photos above Telegram's 10 MB photo limit
  are re-compressed/resized automatically before sending; videos and
  documents above the 50 MB bot upload cap are flagged **before** the send
  starts, so no data is wasted on an upload that would be rejected.
- **In-app updates** — checks GitHub Releases (on open, manually, and every
  6 h in the background), notifies once per version, downloads the APK with
  progress, verifies the published SHA-256 checksum, and prompts the system
  installer. Nothing installs silently.
- **Send history** — a simple local record of past sessions with success and
  failure counts.

## Download & Install

1. Go to [Releases](https://github.com/tukiza7-debug/telegram-bulk-sender/releases/latest).
2. Download `telegram-bulk-sender-vX.Y.Z.apk` (universal; works on
   `armeabi-v7a`, `arm64-v8a`, `x86_64`).
3. Open the APK. On first install Android will ask you to allow installs
   from this source — tap **Settings** and enable **Install unknown apps**
   for your browser/file manager, then confirm the install.
4. Verify the download (optional but recommended):

   ```bash
   sha256sum -c checksums.txt   # from the same release page
   ```

## How updates work

The app ships with a built-in updater:

- On app open, on demand from **Settings → Check for updates**, and from a
  periodic background job (every 6 hours, network-constrained, using
  `ETag`/`If-None-Match` so checks are cheap), the app queries the GitHub
  Releases API.
- When a release with a **newer semver tag** exists, you get a system
  notification **once per version**, plus a dismissible banner on the home
  screen. Tapping either opens the in-app Update screen (not a browser).
- The Update screen shows the current vs. new version and the release notes,
  then **Update now** downloads the APK, verifies its SHA-256 against the
  published `checksums.txt`, and hands it to the system installer.
- **Updates install over the existing app — no uninstall, no data loss.**
  This works because every release is signed with the same key and the
  `versionCode` (`--build-number` = CI run number) always increases. A lost
  signing key or a reused `versionCode` would break the update path — that
  is why both are treated as critical in the release guide below.
- The `REQUEST_INSTALL_PACKAGES` permission is only exercised when you tap
  **Update now**; the first time, the app explains it and sends you to the
  system "Install unknown apps" screen. You confirm every install.

## Permissions

Requested in context, with an explanation before the system dialog. The app
remains functional if you deny any of them.

| Permission | When it is requested | Why |
| --- | --- | --- |
| `INTERNET` | Automatically (normal permission) | Talk to `api.telegram.org` and `api.github.com`. |
| `POST_NOTIFICATIONS` (Android 13+) | Right after onboarding, with a rationale screen | Update alerts + background send progress. Denied → in-app banners only. |
| Photo/Video/Document pickers (no permission) | When you tap "Choose files" | System pickers (Photo Picker + SAF); the app never needs `READ_MEDIA_*`. |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` | Automatically (normal permissions) | Keep bulk sending alive in the background with a visible notification. |
| `WAKE_LOCK`, `RECEIVE_BOOT_COMPLETED` | Automatically (normal permissions) | Keep the device awake during long uploads and let WorkManager restore its periodic update check after reboot. |
| `REQUEST_INSTALL_PACKAGES` | Shown/used only on the first "Update now" | Lets the system install the downloaded update APK. Never used silently. |
| Ignore battery optimisation | **Optional**, from Settings → Permissions | Only relevant if your system kills long background sends. |

## Getting started

1. **Create a bot** — in Telegram, open [@BotFather](https://t.me/BotFather),
   send `/newbot`, and follow the prompts. Copy the token
   (`123456789:AAH3x…`).
2. **Paste the token** into the app on first launch. It is validated via
   `getMe` and stored encrypted on the device.
3. **Get a chat ID** —
   - *Channel/group*: add the bot **as an admin** to the channel/group. Use
     the numeric ID (large negative values like `-1001234567890`; you can
     obtain it via @userinfobot or similar tools) or the `@channelusername`.
   - *Private chat*: send the bot any message first (bots cannot initiate),
     then use your numeric user ID.
4. **Add the recipient** in the app — it is verified through `getChat`
   before saving, so mistakes are caught early.

## Usage

1. **Home** → *Add recipient* (repeat for every target).
2. **Choose files** → *Add* → Photos / Videos / Documents, multi-select,
   drag to reorder, remove as needed.
3. **Continue** → pick a mode:
   - *Album*: photos and videos are grouped up to 10 per `sendMediaGroup`
     (they can be mixed); the caption is applied once per album. Documents
     travel as separate messages. If Telegram rejects an album, the app
     automatically retries its files individually so one bad image does not
     sink the batch.
   - *Individual*: one message per file via `sendPhoto` / `sendVideo` /
     `sendDocument`; the caption is applied to every file.
4. Set an optional caption (≤ 1024 chars) and the pacing delay, then **Send**.
5. Watch progress; pause/cancel any time. Failed pairs can be retried
   exactly (same file, same recipient) with one tap.

**Telegram limits to keep in mind** — photos must be ≤ 10 MB (the app
compresses larger ones automatically), videos and documents sent by bots
must be ≤ 50 MB (oversized files are flagged before sending), albums hold at
most 10 items, and Telegram enforces roughly 30 messages/second globally and
about 20 messages/minute per group/channel. The app paces itself proactively
and handles HTTP 429 `retry_after` automatically, but very large jobs simply
take time.

## Build from source

Requirements: Flutter SDK **3.47.5 stable** (pinned; the CI uses the same
version) and Android SDK (API 35+ build tools).

```bash
git clone https://github.com/tukiza7-debug/telegram-bulk-sender.git
cd telegram-bulk-sender
flutter pub get
flutter analyze   # must be clean
flutter test
flutter run       # debug build on a connected device
flutter build apk --release
```

Local release builds without signing configuration fall back to the debug
key; CI builds always use the real release keystore (below).

## Release guide (maintainers)

1. **Generate the keystore once** and keep it safe (loss = users must
   uninstall/reinstall):

   ```bash
   keytool -genkeypair -v \
     -keystore upload-keystore.jks \
     -alias telegram-bulk-sender \
     -keyalg RSA -keysize 2048 -validity 10950 \
     -dname "CN=Telegram Bulk Sender, OU=Mobile, O=yourname, C=MY"
   base64 -w0 upload-keystore.jks > keystore.base64
   ```

2. **Set the GitHub Actions secrets** (repo → Settings → Secrets and
   variables → Actions):

   | Secret | Value |
   | --- | --- |
   | `KEYSTORE_BASE64` | `base64` of `upload-keystore.jks` |
   | `KEYSTORE_PASSWORD` | keystore password |
   | `KEY_ALIAS` | `telegram-bulk-sender` |
   | `KEY_PASSWORD` | key password (may equal store password) |
   | `EXPECTED_CERT_SHA256` | SHA-256 of the release signing certificate (pins CI to the real key) |

3. **Cut a release** — either:
   - push a tag: `git tag v1.0.1 && git push origin v1.0.1`, or
   - run the **Release APK** workflow via *Run workflow* and choose
     `patch` / `minor` / `major` — the workflow computes the next semver,
     builds, and creates the tag + GitHub Release automatically.

4. **Versioning rules**
   - The git tag `vX.Y.Z` is the source of truth; CI passes
     `--build-name=X.Y.Z --build-number=$GITHUB_RUN_NUMBER+1000` to
     `flutter build apk`. `versionCode` therefore equals the CI run number
     **+ 1000** and always increases — it can never repeat or go down.
     The offset protects against the workflow/repo being recreated: a reset
     `run_number` would otherwise produce a lower `versionCode` and Android
     would refuse the update as a downgrade. If you ever recreate the
     workflow, keep the offset (and raise it only if `run_number + 1000`
     could collide with an existing build).
   - `pubspec.yaml` carries a default (`1.2.2+1`) for local builds only.
   - The version shown in **Settings → About** always matches the GitHub
     release tag.
   - **No `--split-per-abi`**: a single universal APK keeps one `versionCode`
     per release, one artifact, and an updater that cannot pick the wrong
     ABI slice. Size difference vs. an arm64-only APK (~10%) is the price
     for that simplicity.
5. **Signing verification** — the release workflow extracts the APK signing
   certificate SHA-256 with `apksigner` and fails the build unless it matches
   the pinned `EXPECTED_CERT_SHA256` secret. If the release key is rotated,
   update that secret with the new digest (the failure log prints it).

## Troubleshooting

- **Self-diagnosis flow for token problems (v1.2.4)** — the token field has
  a **paste & clean** button that reads the clipboard directly (bypassing
  the keyboard), extracts the token even from the whole @BotFather message
  and shows what it cleaned. Before the app ever blames the token it
  probes api.telegram.org: an offline device or a captive portal produces
  "Cannot reach api.telegram.org … This is NOT a token problem", never
  "token rejected". When validation does fail with 401, open **Details**
  under the error: it shows the masked fingerprint of the token the app
  actually received (`123456789:AAH3…wk9`), the token length against the
  expected 40-60 range, the sanitizer action log and the network probe —
  if the fingerprint differs from what @BotFather shows, the copy was
  mangled: tap the token's code span in Telegram (don't drag-select) and
  paste again. A paste containing more than one token opens a picker
  instead of guessing.
- **"Telegram rejected this token" repeated on every paste** — since
  v1.2.3/v1.2.4 the known paste-mangling causes are fixed in-app: soft
  line breaks inside a wrapped copy are re-joined, smart
  dashes/quotes/fullwidth colons are folded, labels are stripped, and
  bot links (`t.me/…`) or `@usernames` produce the actionable "that
  doesn't look like a bot token" hint instead of a doomed 401. What
  remains is a genuinely dead token: every `/revoke` in @BotFather kills
  all older tokens — copy from the **latest** message only.
- **"Invalid bot token"** — make sure the whole token (including the part
  after the colon) was copied. The app cleans up labels, spaces and stray
  characters automatically, so a real token should validate on the first
  try. If you regenerated the token with `/revoke` in @BotFather, the old
  one stops working: open **Settings → Reconnect token**, paste the new
  token, and it will be validated against `getMe` and swapped in —
  recipients and history are kept. Since v1.2.0 the app also re-validates
  the saved token on every launch: a revoked token is detected immediately,
  the fake "connected" state is cleared, and you are asked to reconnect
  instead of seeing sends fail with 401. An offline launch never wipes the
  token — it stays "unverified" until the network returns.
- **"The saved bot token is no longer valid" on Home** — exactly the case
  above: the token stored on this device was regenerated or revoked in
  @BotFather. Tap **Connect bot** and paste the current token from
  @BotFather; recipients and history are untouched.
- **"App shows connected right after installing/updating"** — the device
  still holds a bot token from an earlier session (updates intentionally
  keep it so recipients survive). Since v1.2.1 the app re-checks it on
  every launch and discards anything blank or corrupted, so a truly fresh
  install always starts at **Bot not connected**. To start over manually:
  **Settings → Disconnect bot**, then **Connect bot** with your token
  (or use **Settings → Reconnect token** to swap it in place).
- **"App not installed"** — a different signing key than the installed
  build. Uninstall the old app first; then always update via the in-app
  updater (same key).
- **"Chat not found" / bot cannot post** — the bot must be able to see the
  chat. Send it a message (private chats) or add it **as an admin**
  (channels/groups) before adding the recipient.
- **Lots of 429 waits** — you are hitting Telegram's rate limits; increase
  the pacing delay or send albums instead of individual photos. Albums are
  now weighed by their item count against Telegram's ~20 msgs/min per-chat
  limit, so pacing adapts automatically.
- **No update notification** — check Settings → Permissions → Notifications;
  also confirm you are not running the same or a newer version, and that the
  version is not in "Skip this version" (Settings → Updates → Unskip). A
  failed update check is reported as an error — it never pretends you are
  "up to date".
- **Background sending stops** — some systems kill long jobs; enable
  *Ignore battery optimisation* for this app (Settings → Permissions).

## Privacy & Security

- The bot token is stored **encrypted on the device**
  (`flutter_secure_storage` → Android Keystore). It is never logged, never
  committed, and only ever sent to `api.telegram.org` over HTTPS.
- Photos go **only** to the Telegram recipients you chose.
- The updater talks to `api.github.com` and downloads APKs from this
  repository's Releases, verifying the published SHA-256 checksum before
  install.
- The app has **no analytics, no tracking, no third-party services** beyond
  Telegram and GitHub.

## Responsible use

This app automates posting through the Telegram Bot API. You are responsible
for how you use it: respect [Telegram's Terms of Service](https://telegram.org/tos)
and bot guidelines, only send to chats where you have permission, and **do
not spam**. Bulk messaging at scale or unsolicited content can get your bot
banned.

## Licence

[MIT](LICENSE) — see [LICENSE](LICENSE).
