import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../notifications/notification_service.dart';
import '../updates/github_release_service.dart';
import '../updates/version_utils.dart';

/// Shared logic for the three update-check entry points:
///  1. workmanager periodic task (every 6 h, network constraint)
///  2. app open
///  3. "Check for updates" button in Settings
///
/// A system notification is shown AT MOST ONCE per new version.
class UpdateCheckService {
  UpdateCheckService._();

  static final GithubReleaseService _github = GithubReleaseService();

  /// Runs a full check. Returns the release when a (non-skipped) newer
  /// version exists, null otherwise.
  static Future<GithubRelease?> run({bool notify = true}) async {
    final prefs = await SharedPreferences.getInstance();
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = packageInfo.version;

    String? etag = prefs.getString(AppConstants.etagKey);
    GithubRelease? release;
    try {
      release = await _github.fetchLatest(
        etag: etag,
        onEtag: (newEtag) {
          etag = newEtag;
          prefs.setString(AppConstants.etagKey, newEtag);
        },
      );
    } on Exception {
      // Network/API failure: update checks must never crash the caller.
      return null;
    }
    if (release == null) return null;
    if (!VersionUtils.isNewer(release.version, currentVersion)) return null;

    final skipped = prefs.getString(AppConstants.skippedVersionKey);
    if (skipped == release.tag) return null;

    if (notify) {
      final lastNotified =
          prefs.getString(AppConstants.lastNotifiedVersionKey);
      if (lastNotified != release.tag) {
        await NotificationService.instance.showUpdateNotification(
          version: release.version,
          body: _firstLine(release.body) ?? "Tap to see what's new.",
        );
        await prefs.setString(
          AppConstants.lastNotifiedVersionKey,
          release.tag,
        );
      }
    }
    return release;
  }

  static String? _firstLine(String body) {
    for (final rawLine in body.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      // Strip markdown heading/bullet markers for notification text.
      return line.replaceFirst(RegExp(r'^[#*\-\s]+'), '').trim();
    }
    return null;
  }
}
