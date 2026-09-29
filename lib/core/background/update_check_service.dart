import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../notifications/notification_service.dart';
import '../updates/github_release_service.dart';
import '../updates/version_utils.dart';

/// Outcome of one update check. A network failure is [status] `failed` —
/// it must NEVER be reported to the user as "You're up to date".
enum UpdateCheckStatus { available, upToDate, skipped, failed }

class UpdateCheckResult {
  const UpdateCheckResult(this.status, {this.release});

  final UpdateCheckStatus status;

  /// Set for [UpdateCheckStatus.available] and [UpdateCheckStatus.skipped].
  final GithubRelease? release;
}

/// Shared logic for the three update-check entry points:
///  1. workmanager periodic task (every 6 h, network constraint)
///  2. app open
///  3. "Check for updates" button in Settings
///
/// A system notification is shown AT MOST ONCE per new version.
///
/// ETag handling: the last parsed release is cached together with the ETag.
/// A 304 answer therefore means "use the cached release", not "no update" —
/// previously a 304 made [fetchLatest]-style callers read null as
/// "up to date" and the update banner never appeared.
class UpdateCheckService {
  UpdateCheckService._();

  static final GithubReleaseService _github = GithubReleaseService();

  /// In-flight launch check shared between main() and App._bootstrap so
  /// both entry points trigger at most one network round-trip.
  static Future<UpdateCheckResult>? _sharedCheck;

  /// Runs a full check.
  ///
  ///  - [force]: manual checks (Settings button) — never sends If-None-Match
  ///    and never shares the in-flight future.
  ///  - [github]/[prefs]/[currentVersion]: injectable for tests.
  static Future<UpdateCheckResult> run({
    bool notify = true,
    bool force = false,
    GithubReleaseService? github,
    SharedPreferences? prefs,
    String? currentVersion,
  }) {
    if (force) {
      return _evaluate(
        force: true,
        github: github ?? _github,
        prefs: prefs,
        currentVersion: currentVersion,
      ).then((result) => _maybeNotify(result, notify: notify, prefsOverride: prefs));
    }

    // Launch / background checks share one in-flight future.
    final existing = _sharedCheck;
    if (existing != null) {
      return existing.then(
        (result) => _maybeNotify(result, notify: notify, prefsOverride: prefs),
      );
    }
    final future = _evaluate(
      force: false,
      github: github ?? _github,
      prefs: prefs,
      currentVersion: currentVersion,
    );
    _sharedCheck = future;
    void release() {
      if (identical(_sharedCheck, future)) _sharedCheck = null;
    }

    future.whenComplete(release);
    return future.then(
      (result) => _maybeNotify(result, notify: notify, prefsOverride: prefs),
    );
  }

  static Future<UpdateCheckResult> _evaluate({
    required bool force,
    required GithubReleaseService github,
    SharedPreferences? prefs,
    String? currentVersion,
  }) async {
    final prefs_ = prefs ?? await SharedPreferences.getInstance();
    final version = currentVersion ?? (await PackageInfo.fromPlatform()).version;

    final savedEtag = prefs_.getString(AppConstants.etagKey);
    final cachedRaw = prefs_.getString(AppConstants.lastReleaseKey);
    final cached = cachedRaw == null ? null : GithubRelease.decode(cachedRaw);

    // Manual (forced) checks never send If-None-Match: a stale ETag would
    // return 304 and hide a release published between checks.
    // An ETag without a cached release (legacy install) cannot be resolved
    // on a 304 either — force a full fetch in that case too.
    final sendEtag = (!force &&
            savedEtag != null &&
            savedEtag.isNotEmpty &&
            cached != null)
        ? savedEtag
        : null;

    GithubFetchResult response;
    try {
      response = await github.fetchLatest(etag: sendEtag);
    } on Exception {
      // Network/API failure: update checks must never crash the caller,
      // and the UI must show an error — never "You're up to date".
      return const UpdateCheckResult(UpdateCheckStatus.failed);
    }

    if (response.notModified) {
      final release = cached;
      if (release == null) {
        // Should not happen (sendEtag implies cache), but stay safe.
        return const UpdateCheckResult(UpdateCheckStatus.failed);
      }
      return _classify(release: release, currentVersion: version, prefs: prefs_);
    }

    if (response.noReleaseYet) {
      await _clearCache(prefs_);
      return const UpdateCheckResult(UpdateCheckStatus.upToDate);
    }

    if (!response.ok) {
      return const UpdateCheckResult(UpdateCheckStatus.failed);
    }

    final release = response.release!;
    // Persist ETag + parsed release together, ONLY after a fresh 200.
    await prefs_.setString(AppConstants.lastReleaseKey, release.encode());
    if (response.etag != null && response.etag!.isNotEmpty) {
      await prefs_.setString(AppConstants.etagKey, response.etag!);
    }
    return _classify(release: release, currentVersion: version, prefs: prefs_);
  }

  static Future<UpdateCheckResult> _classify({
    required GithubRelease release,
    required String currentVersion,
    required SharedPreferences prefs,
  }) async {
    if (!VersionUtils.isNewer(release.version, currentVersion)) {
      return const UpdateCheckResult(UpdateCheckStatus.upToDate);
    }
    final skipped = prefs.getString(AppConstants.skippedVersionKey);
    if (skipped == release.tag) {
      return UpdateCheckResult(UpdateCheckStatus.skipped, release: release);
    }
    return UpdateCheckResult(UpdateCheckStatus.available, release: release);
  }

  static Future<UpdateCheckResult> _maybeNotify(
    UpdateCheckResult result, {
    required bool notify,
    SharedPreferences? prefsOverride,
  }) async {
    if (!notify ||
        result.status != UpdateCheckStatus.available ||
        result.release == null) {
      return result;
    }
    final prefs = prefsOverride ?? await SharedPreferences.getInstance();
    final lastNotified = prefs.getString(AppConstants.lastNotifiedVersionKey);
    if (lastNotified != result.release!.tag) {
      await NotificationService.instance.showUpdateNotification(
        version: result.release!.version,
        body: _firstLine(result.release!.body) ?? "Tap to see what's new.",
      );
      await prefs.setString(
        AppConstants.lastNotifiedVersionKey,
        result.release!.tag,
      );
    }
    return result;
  }

  static Future<void> _clearCache(SharedPreferences prefs) async {
    await prefs.remove(AppConstants.etagKey);
    await prefs.remove(AppConstants.lastReleaseKey);
  }

  /// Notification body: skip GitHub's "What's Changed" / "Full Changelog"
  /// headings and use the first actual bullet line.
  static String? _firstLine(String body) {
    const headings = ["what's changed", 'full changelog'];
    for (final rawLine in body.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final stripped = line.replaceFirst(RegExp(r'^[#*\-\s]+'), '').trim();
      if (stripped.isEmpty) continue;
      if (headings.any((h) => stripped.toLowerCase().startsWith(h))) {
        continue; // heading — skip
      }
      return stripped;
    }
    return null;
  }
}
