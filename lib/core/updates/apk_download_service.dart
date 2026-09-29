import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// Downloads the update APK with progress reporting and verifies its
/// SHA-256 checksum against the published checksums.txt.
class ApkDownloadService {
  ApkDownloadService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<Directory> _updateDir() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/updates');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Downloads [url] into the app cache and returns the local file path.
  Future<String> download(
    String url,
    String fileName, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await _updateDir();
    final savePath = '${dir.path}/$fileName';
    final file = File(savePath);
    if (file.existsSync()) file.deleteSync();

    await _dio.download(
      url,
      savePath,
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
      options: Options(receiveTimeout: const Duration(minutes: 15)),
    );
    return savePath;
  }

  /// Streams the file through SHA-256 (constant memory).
  Future<String> computeFileSha256(String path) async {
    final file = File(path);
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase();
  }

  /// Verifies [apkPath] against [expectedSha256]. Throws [StateError] on
  /// mismatch.
  Future<void> verify(String apkPath, String expectedSha256) async {
    final actual = await computeFileSha256(apkPath);
    if (actual != expectedSha256.toLowerCase()) {
      throw StateError(
        'Checksum mismatch. The downloaded file may be corrupted or '
        'tampered with. Please try again.',
      );
    }
  }
}
