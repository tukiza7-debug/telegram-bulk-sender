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

  /// Returns null when the server answered 304 (not modified).
  Future<GithubRelease?> fetchLatest({
    String? etag,
    void Function(String newEtag)? onEtag,
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/repos/${AppConstants.updateRepoSlug}/releases/latest',
      options: Options(
        headers: {
          if (etag != null && etag.isNotEmpty) 'If-None-Match': etag,
        },
      ),
    );

    final newEtag = response.headers.value('etag');
    if (newEtag != null && onEtag != null) onEtag(newEtag);

    if (response.statusCode == 304) return null;
    if (response.statusCode == 404) return null; // No releases yet.
    final body = response.data;
    if (body == null || response.statusCode != 200) {
      throw Exception('GitHub API error: HTTP ${response.statusCode}');
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
    if (apkAsset == null) return null;

    return GithubRelease(
      tag: body['tag_name'] as String? ?? '',
      name: body['name'] as String? ?? '',
      body: body['body'] as String? ?? '',
      apkUrl: apkAsset['browser_download_url'] as String,
      checksumUrl: checksumAsset?['browser_download_url'] as String?,
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
