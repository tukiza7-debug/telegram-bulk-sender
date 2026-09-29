import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';

/// Telegram Bot API allows photos up to 10 MB via sendPhoto/sendMediaGroup.
/// Anything bigger is resized/re-compressed until it fits.
class ImagePreparer {
  static const int maxBytes = 10 * 1024 * 1024;

  /// Returns a path that is guaranteed to be <= 10 MB.
  /// If [path] already fits, it is returned unchanged.
  static Future<String> prepare(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw StateError('Selected file does not exist: $path');
    }
    var length = file.lengthSync();
    if (length <= maxBytes) return path;

    final target = await _tempCopyPath(path);
    var quality = 85;
    var longestSide = 2560;

    var result = await FlutterImageCompress.compressAndGetFile(
      path,
      target,
      quality: quality,
      minHeight: longestSide,
      minWidth: longestSide,
      format: CompressFormat.jpeg,
    );
    length = result != null ? File(result.path).lengthSync() : length;

    while (length > maxBytes && quality > 40) {
      quality -= 15;
      if (quality <= 55) longestSide = 1920;
      if (quality <= 45) longestSide = 1440;
      result = await FlutterImageCompress.compressAndGetFile(
        path,
        target,
        quality: quality,
        minHeight: longestSide,
        minWidth: longestSide,
        format: CompressFormat.jpeg,
      );
      length = result != null ? File(result.path).lengthSync() : length;
    }

    if (result == null || length > maxBytes) {
      // Last resort: hard resize.
      final fallback = await FlutterImageCompress.compressAndGetFile(
        path,
        target,
        quality: 40,
        minHeight: 1280,
        minWidth: 1280,
        format: CompressFormat.jpeg,
      );
      if (fallback == null || File(fallback.path).lengthSync() > maxBytes) {
        return path; // Let Telegram reject it with a clear error.
      }
      return fallback.path;
    }
    return result.path;
  }

  static Future<String> _tempCopyPath(String original) async {
    final dir = await getTemporaryDirectory();
    final updatesDir = Directory('${dir.path}/prepared');
    if (!updatesDir.existsSync()) updatesDir.createSync(recursive: true);
    final name = original.split('/').last.replaceAll(RegExp(r'\.[^.]+$'), '');
    return '${updatesDir.path}/$name-${DateTime.now().microsecondsSinceEpoch}.jpg';
  }
}
