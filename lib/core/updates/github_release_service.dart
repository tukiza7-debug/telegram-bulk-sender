import 'dart:convert';

import 'package:dio/dio.dart';

import '../constants.dart';

/// A parsed GitHub release with the APK asset and its published checksum.
class GithubRelease {
  const GithubRelease({
    required this.tag,
    required this.name,
    required this.body,
    required this.apkUrl,
    this.checksumUrl,
  });

  final String tag;
  final String name;
  final String body;
  final String apkUrl;
  final String? checksumUrl;

  String get version => tag.startsWith('v') ? tag.substring(1) : tag;

  Map<String, dynamic> toJson() => {
        'tag': tag,
        'name': name,
        'body': body,
        'apkUrl': apkUrl,
        'checksumUrl': checksumUrl,
      };

  factory GithubRelease.fromJson(Map<String, dynamic> json) => GithubRelease(
        tag: json['tag'] as String? ?? '',
        name: json['name'] as String? ?? '',
        body: json['body'] as String? ?? '',
        apkUrl: json['apkUrl'] as String? ?? '',
        checksumUrl: json['checksumUrl'] as String?,
      );

  static GithubRelease? decode(String raw) {
    try {
      return GithubRelease.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return null;
    }
  }

  String encode() => jsonEncode(toJson());
}

/// What one HTTP round-trip against the GitHub API produced. The caller
/// decides persistence and interpretation (304 is NOT "no update").
class GithubFetchResult {
  const GithubFetchResult({
    required this.statusCode,
    this.etag,
    this.release,
  });

  final int statusCode;
  final String? etag;

  /// Parsed release — only set on a 200 with a usable APK asset.
  final GithubRelease? release;

  bool get notModified => statusCode == 304;
  bool get ok => statusCode == 200 && release != null;
  bool get noReleaseYet => statusCode == 404;
}

/// Fetches the latest release from GitHub Releases API with ETag support so
/// periodic background checks stay cheap (304 -> no payload).
class GithubReleaseService {
  GithubReleaseService({Dio? dio}) : _dio = dio ?? _buildDio();

  final Dio _dio;

  static Dio _buildDio() {
    return Dio(
      BaseOptions(
        baseUrl: 'https://api.github.com',
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
        validateStatus: (status) => status != null && status < 600,
      ),
    );
  }

  /// Fetches the latest release. [etag] may be null to skip If-None-Match
  /// (manual checks must never send it — a stale ETag would return 304 and
  /// hide a release published between checks).
  ///
  /// Uses `get<dynamic>` deliberately: GitHub answers 304 with an empty
  /// body, and a `get<Map<String, dynamic>>` type cast would turn that into
  /// a DioException instead of a clean "not modified" result.
  Future<GithubFetchResult> fetchLatest({String? etag}) async {
    final response = await _dio.get<dynamic>(
      '/repos/${AppConstants.updateRepoSlug}/releases/latest',
      options: Options(
        headers: {
          if (etag != null && etag.isNotEmpty) 'If-None-Match': etag,
        },
      ),
    );

    final result = GithubFetchResult(
      statusCode: response.statusCode ?? 0,
      etag: response.headers.value('etag'),
    );

    if (result.notModified || result.noReleaseYet) return result;
    if (response.statusCode != 200) {
      throw Exception('GitHub API error: HTTP ${response.statusCode}');
    }

    final body = response.data;
    if (body is! Map<String, dynamic>) {
      throw Exception('GitHub API error: unexpected response body');
    }

    final assets = (body['assets'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    Map<String, dynamic>? apkAsset;
    Map<String, dynamic>? checksumAsset;
    for (final asset in assets) {
      final name = asset['name'] as String? ?? '';
      if (name.endsWith('.apk')) apkAsset ??= asset;
      if (name.toLowerCase() == 'checksums.txt') checksumAsset ??= asset;
    }
    if (apkAsset == null) {
      // A release without an APK asset is not installable.
      return GithubFetchResult(statusCode: 200, etag: result.etag);
    }

    return GithubFetchResult(
      statusCode: 200,
      etag: result.etag,
      release: GithubRelease(
        tag: body['tag_name'] as String? ?? '',
        name: body['name'] as String? ?? '',
        body: body['body'] as String? ?? '',
        apkUrl: apkAsset['browser_download_url'] as String,
        checksumUrl: checksumAsset?['browser_download_url'] as String?,
      ),
    );
  }

  /// Downloads checksums.txt and returns the expected hash for [apkName],
  /// or null when unavailable/malformed.
  Future<String?> fetchExpectedChecksum(
    String checksumUrl,
    String apkName,
  ) async {
    try {
      final response = await _dio.get<String>(checksumUrl);
      final content = response.data;
      if (content == null) return null;
      for (final line in content.split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length >= 2 && parts[1] == apkName) {
          final hash = parts[0].toLowerCase();
          if (RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) return hash;
        }
      }
      return null;
    } on DioException {
      return null;
    }
  }

  void dispose() => _dio.close();
}
