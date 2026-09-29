import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:telegram_bulk_sender/core/background/update_check_service.dart';
import 'package:telegram_bulk_sender/core/constants.dart';
import 'package:telegram_bulk_sender/core/updates/github_release_service.dart';

class FakeGithubAdapter implements HttpClientAdapter {
  FakeGithubAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final List<String?> ifNoneMatch = [];
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    ifNoneMatch.add(options.headers['If-None-Match'] as String?);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

GithubRelease fakeRelease({String tag = 'v9.9.9'}) => GithubRelease(
      tag: tag,
      name: 'v$tag',
      body: "* Fixed something\n* Another fix",
      apkUrl: 'https://github.com/x/releases/download/$tag/app.apk',
      checksumUrl: 'https://github.com/x/releases/download/$tag/checksums.txt',
    );

const Map<String, List<String>> releaseHeaders = {
  'etag': ['"abc123"'],
  Headers.contentTypeHeader: ['application/json'],
};

Future<SharedPreferences> mockPrefs(
    [Map<String, Object> values = const {}]) async {
  SharedPreferences.setMockInitialValues(
      Map<String, Object>.of(values));
  return SharedPreferences.getInstance();
}

void main() {
  Future<UpdateCheckResult> check(
    FakeGithubAdapter adapter, {
    bool force = false,
    Map<String, Object> prefs = const {},
  }) async {
    final sp = await mockPrefs(prefs);
    final service = GithubReleaseService(
        dio: Dio(BaseOptions(
              baseUrl: 'https://api.github.com',
              validateStatus: (status) => status != null && status < 600,
            ))
          ..httpClientAdapter = adapter);
    return UpdateCheckService.run(
      notify: false,
      force: force,
      github: service,
      prefs: sp,
      currentVersion: '1.0.0',
    );
  }

  test('304 after a cached fetch returns the cached release, not "no update"',
      () async {
    final adapter = FakeGithubAdapter(
      (options) => ResponseBody.fromString('null', 304),
    );
    final cached = fakeRelease();
    final result = await check(
      adapter,
      prefs: {
        AppConstants.etagKey: '"abc123"',
        AppConstants.lastReleaseKey: cached.encode(),
      },
    );

    expect(result.status, UpdateCheckStatus.available);
    expect(result.release?.tag, 'v9.9.9');
    expect(adapter.calls, 1);
    expect(adapter.ifNoneMatch.single, '"abc123"');
  });

  test('a 304 for a skipped version reports skipped', () async {
    final adapter = FakeGithubAdapter(
      (options) => ResponseBody.fromString('null', 304),
    );
    final result = await check(
      adapter,
      prefs: {
        AppConstants.etagKey: '"abc123"',
        AppConstants.lastReleaseKey: fakeRelease().encode(),
        AppConstants.skippedVersionKey: 'v9.9.9',
      },
    );

    expect(result.status, UpdateCheckStatus.skipped);
    expect(result.release?.tag, 'v9.9.9');
  });

  test('a network failure reports failed (never "up to date")', () async {
    final adapter = FakeGithubAdapter((options) {
      throw DioException.connectionTimeout(
        timeout: const Duration(seconds: 5),
        requestOptions: options,
      );
    });
    final result = await check(
      adapter,
      prefs: {
        AppConstants.etagKey: '"abc123"',
        AppConstants.lastReleaseKey: fakeRelease().encode(),
      },
    );

    expect(result.status, UpdateCheckStatus.failed);
    expect(result.release, isNull);
  });

  test('an HTTP 500 reports failed', () async {
    final adapter = FakeGithubAdapter(
      (options) => ResponseBody.fromString('{"message":"boom"}', 500),
    );
    final result = await check(adapter);

    expect(result.status, UpdateCheckStatus.failed);
  });

  test('manual check (force) never sends If-None-Match', () async {
    final adapter = FakeGithubAdapter(
      (options) => ResponseBody.fromString(
        jsonEncode({
          'tag_name': 'v9.9.9',
          'name': 'v9.9.9',
          'body': '* Fixed',
          'assets': [
            {
              'name': 'app.apk',
              'browser_download_url': 'https://x/app.apk',
            },
            {
              'name': 'checksums.txt',
              'browser_download_url': 'https://x/checksums.txt',
            },
          ],
        }),
        200,
        headers: releaseHeaders,
      ),
    );
    final result = await check(
      adapter,
      force: true,
      prefs: {
        AppConstants.etagKey: '"stale-etag"',
        AppConstants.lastReleaseKey: fakeRelease(tag: 'v1.0.0').encode(),
      },
    );

    expect(result.status, UpdateCheckStatus.available);
    expect(adapter.ifNoneMatch.single, isNull,
        reason: 'a manual check must fetch the truth, not a 304');
  });

  test('an ETag without a cached release triggers a full fetch', () async {
    final adapter = FakeGithubAdapter(
      (options) => ResponseBody.fromString('null', 304),
    );
    final result = await check(
      adapter,
      prefs: {AppConstants.etagKey: '"abc123"'},
    );

    expect(adapter.ifNoneMatch.single, isNull,
        reason: 'a 304 without cache would be unresolvable');
    expect(result.status, UpdateCheckStatus.failed);
  });

  test('a 200 persists the ETag and the parsed release together', () async {
    final adapter = FakeGithubAdapter(
      (options) => ResponseBody.fromString(
        jsonEncode({
          'tag_name': 'v9.9.9',
          'name': 'v9.9.9',
          'body': '* Fixed',
          'assets': [
            {'name': 'app.apk', 'browser_download_url': 'https://x/app.apk'},
          ],
        }),
        200,
        headers: releaseHeaders,
      ),
    );
    final sp = await mockPrefs();
    final service = GithubReleaseService(
        dio: Dio(BaseOptions(
              baseUrl: 'https://api.github.com',
              validateStatus: (status) => status != null && status < 600,
            ))
          ..httpClientAdapter = adapter);
    final result = await UpdateCheckService.run(
      notify: false,
      github: service,
      prefs: sp,
      currentVersion: '1.0.0',
    );

    expect(result.status, UpdateCheckStatus.available);
    final savedEtag = sp.getString(AppConstants.etagKey);
    final savedRaw = sp.getString(AppConstants.lastReleaseKey);
    expect(savedEtag, isNotNull);
    final savedRelease = GithubRelease.decode(savedRaw!);
    expect(savedRelease, isNotNull);
    expect(savedRelease!.tag, 'v9.9.9');
  });

  test('a 200 for a version that is not newer reports upToDate', () async {
    final adapter = FakeGithubAdapter(
      (options) => ResponseBody.fromString(
        jsonEncode({
          'tag_name': 'v1.0.0',
          'name': 'v1.0.0',
          'body': '* Same',
          'assets': [
            {'name': 'app.apk', 'browser_download_url': 'https://x/app.apk'},
          ],
        }),
        200,
        headers: releaseHeaders,
      ),
    );
    final result = await check(adapter);

    expect(result.status, UpdateCheckStatus.upToDate);
  });

  test('shared in-flight future dedupes concurrent launch checks', () async {
    final adapter = FakeGithubAdapter(
      (options) => ResponseBody.fromString(
        jsonEncode({
          'tag_name': 'v9.9.9',
          'name': 'v9.9.9',
          'body': '* Fixed',
          'assets': [
            {'name': 'app.apk', 'browser_download_url': 'https://x/app.apk'},
          ],
        }),
        200,
        headers: releaseHeaders,
      ),
    );
    final sp = await mockPrefs();
    final service = GithubReleaseService(
        dio: Dio(BaseOptions(
              baseUrl: 'https://api.github.com',
              validateStatus: (status) => status != null && status < 600,
            ))
          ..httpClientAdapter = adapter);
    final results = await Future.wait([
      UpdateCheckService.run(
          notify: false, github: service, prefs: sp, currentVersion: '1.0.0'),
      UpdateCheckService.run(
          notify: false, github: service, prefs: sp, currentVersion: '1.0.0'),
    ]);

    expect(adapter.calls, 1,
        reason: 'main() and App bootstrap share one launch check');
    for (final r in results) {
      expect(r.status, UpdateCheckStatus.available);
    }
  });
}
