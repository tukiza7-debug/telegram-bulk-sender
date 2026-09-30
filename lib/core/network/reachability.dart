import 'package:dio/dio.dart';

import '../constants.dart';

/// Result of one lightweight reachability probe against api.telegram.org.
class ReachabilityResult {
  const ReachabilityResult({
    required this.reachable,
    required this.captivePortal,
    this.latencyMs,
    this.httpStatus,
  });

  /// True when a Telegram-shaped JSON answer came back (any `ok` value —
  /// the probe token is intentionally fake, so `ok:false` proves reach).
  final bool reachable;

  /// True when something answered but NOT with Telegram JSON — a captive
  /// portal, proxy or blocker sat in front of the API.
  final bool captivePortal;

  final int? latencyMs;
  final int? httpStatus;

  /// One-line summary for the "Details" self-diagnosis block.
  String get summary {
    if (captivePortal) {
      return 'a network answered but NOT with Telegram data — captive '
          'portal / proxy suspected (HTTP ${httpStatus ?? '?'})';
    }
    if (reachable) {
      return 'api.telegram.org reachable '
          '(${latencyMs ?? '?'} ms, HTTP ${httpStatus ?? '?'})';
    }
    return 'api.telegram.org unreachable';
  }
}

/// One lightweight probe run BEFORE the app blames the token for anything.
///
/// If api.telegram.org cannot be reached — or only answers through a
/// captive portal — the UI must show a network problem, never "Telegram
/// rejected this token".
class TelegramReachability {
  TelegramReachability({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: AppConstants.telegramApiBase,
                connectTimeout: const Duration(seconds: 6),
                receiveTimeout: const Duration(seconds: 8),
                sendTimeout: const Duration(seconds: 6),
                validateStatus: (status) => status != null && status < 600,
              ),
            );

  final Dio _dio;

  /// A syntactically valid but fake token: real Telegram always answers a
  /// well-formed getMe path with JSON (`ok:false`), so any JSON reply proves
  /// reachability without touching real credentials. It is a fixed dummy —
  /// not a user secret — and is never logged.
  static const String _probePath =
      '/bot123456789:AAReachabilityProbeToken000000000000/getMe';

  Future<ReachabilityResult> probe() async {
    final watch = Stopwatch()..start();
    try {
      final response = await _dio.get<dynamic>(_probePath);
      watch.stop();
      final body = response.data;
      final isTelegramJson = body is Map && body['ok'] is bool;
      if (isTelegramJson) {
        return ReachabilityResult(
          reachable: true,
          captivePortal: false,
          latencyMs: watch.elapsedMilliseconds,
          httpStatus: response.statusCode,
        );
      }
      // HTML / plain text in front of Telegram: captive portal, proxy or
      // blocker. A token would be blamed for this — it is a network issue.
      return ReachabilityResult(
        reachable: false,
        captivePortal: true,
        latencyMs: watch.elapsedMilliseconds,
        httpStatus: response.statusCode,
      );
    } on DioException {
      return const ReachabilityResult(
        reachable: false,
        captivePortal: false,
      );
    }
  }
}
