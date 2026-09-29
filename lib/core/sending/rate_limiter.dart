import 'dart:async';

/// Proactive client-side rate limiting.
///
/// Telegram limits are roughly 30 messages/second globally and about
/// 20 messages/minute per group/channel. The limiter enforces a minimum
/// global interval and a minimum per-chat interval before each request.
class RateLimiter {
  RateLimiter({
    this.globalInterval = const Duration(milliseconds: 1000),
    this.perChatInterval = const Duration(milliseconds: 3000),
    Future<void> Function(Duration delay)? sleep,
    DateTime Function()? now,
  })  : _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        _now = now ?? DateTime.now;

  final Duration globalInterval;
  final Duration perChatInterval;

  final Future<void> Function(Duration delay) _sleep;
  final DateTime Function() _now;

  DateTime _lastGlobal = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, DateTime> _lastPerChat = {};

  /// Returns (and awaits) the delay required before sending to [chatId].
  ///
  /// [weight] is the number of Telegram messages the request consumes.
  /// A media-group (album) call is ONE HTTP request but Telegram counts
  /// every item inside it toward the ~20 msgs/min per-group cap, so albums
  /// must be weighed by their item count.
  Future<void> acquire(String chatId, {int weight = 1}) async {
    if (weight < 1) weight = 1;
    final current = _now();
    var earliest = _lastGlobal.add(globalInterval);
    final lastChat = _lastPerChat[chatId];
    if (lastChat != null) {
      final chatReady = lastChat.add(perChatInterval);
      if (chatReady.isAfter(earliest)) earliest = chatReady;
    }
    final wait = earliest.difference(current);
    if (wait > Duration.zero) {
      await _sleep(wait);
    }
    final stamp = _now();
    // Reserve the whole weight now: the next acquire must wait for the
    // remaining (weight - 1) messages of this request as well.
    _lastGlobal = stamp.add(globalInterval * (weight - 1));
    _lastPerChat[chatId] = stamp.add(perChatInterval * (weight - 1));
  }

  /// Clears tracked timestamps (used between independent sessions).
  void reset() {
    _lastGlobal = DateTime.fromMillisecondsSinceEpoch(0);
    _lastPerChat.clear();
  }
}
