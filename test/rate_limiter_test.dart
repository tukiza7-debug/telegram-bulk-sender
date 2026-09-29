import 'package:flutter_test/flutter_test.dart';
import 'package:telegram_bulk_sender/core/sending/rate_limiter.dart';

void main() {
  group('RateLimiter', () {
    test('waits for the global interval between sends', () async {
      var now = DateTime(2025, 1, 1);
      final waits = <Duration>[];
      final limiter = RateLimiter(
        globalInterval: const Duration(seconds: 1),
        perChatInterval: Duration.zero,
        sleep: (d) async {
          waits.add(d);
          now = now.add(d);
        },
        now: () => now,
      );

      await limiter.acquire('chat-a');
      expect(waits, isEmpty); // First send is immediate.
      await limiter.acquire('chat-a');
      expect(waits.single, const Duration(seconds: 1));
    });

    test('per-chat interval applies independently per chat', () async {
      var now = DateTime(2025, 1, 1);
      final waits = <Duration>[];
      final limiter = RateLimiter(
        globalInterval: const Duration(milliseconds: 100),
        perChatInterval: const Duration(seconds: 3),
        sleep: (d) async {
          waits.add(d);
          now = now.add(d);
        },
        now: () => now,
      );

      await limiter.acquire('chat-a');
      await limiter.acquire('chat-b');
      // Only the global interval applied for chat-b.
      expect(waits.single, const Duration(milliseconds: 100));

      await limiter.acquire('chat-a');
      // chat-a needs its per-chat interval (3 s) minus the 0.1 s that
      // elapsed while sending to chat-b.
      expect(waits.last, const Duration(milliseconds: 2900));
    });

    test('takes the maximum of global and per-chat delays', () async {
      var now = DateTime(2025, 1, 1);
      final waits = <Duration>[];
      final limiter = RateLimiter(
        globalInterval: const Duration(seconds: 2),
        perChatInterval: const Duration(seconds: 1),
        sleep: (d) async {
          waits.add(d);
          now = now.add(d);
        },
        now: () => now,
      );

      await limiter.acquire('chat-a');
      await limiter.acquire('chat-a');
      expect(waits.single, const Duration(seconds: 2));
    });

    test('reset clears all tracked timestamps', () async {
      var now = DateTime(2025, 1, 1);
      final waits = <Duration>[];
      final limiter = RateLimiter(
        globalInterval: const Duration(hours: 1),
        sleep: (d) async {
          waits.add(d);
          now = now.add(d);
        },
        now: () => now,
      );

      await limiter.acquire('chat-a');
      expect(waits, isEmpty);
      limiter.reset();
      now = now.add(const Duration(hours: 2));
      await limiter.acquire('chat-a');
      expect(waits, isEmpty); // No wait after reset.
    });

    test('an album of N items reserves N per-chat message slots', () async {
      var now = DateTime(2025, 1, 1);
      final waits = <Duration>[];
      final limiter = RateLimiter(
        globalInterval: Duration.zero,
        perChatInterval: const Duration(seconds: 3),
        sleep: (d) async {
          waits.add(d);
          now = now.add(d);
        },
        now: () => now,
      );

      // First chunk of 10 items goes out immediately.
      await limiter.acquire('chat-a', weight: 10);
      expect(waits, isEmpty);

      // The next request to the same chat must wait for the 9 remaining
      // slots of the album (27 s) plus its own 3 s interval: 30 s total —
      // as if the album had really consumed 10 message slots.
      await limiter.acquire('chat-a');
      expect(waits.single, const Duration(seconds: 30));

      // A different chat is unaffected by chat-a's album weight
      // (global interval is zero here, so no wait happens at all).
      await limiter.acquire('chat-b');
      expect(waits, hasLength(1));
    });

    test('weight clamps to at least 1', () async {
      var now = DateTime(2025, 1, 1);
      final limiter = RateLimiter(
        globalInterval: Duration.zero,
        perChatInterval: const Duration(seconds: 3),
        sleep: (_) async {},
        now: () => now,
      );

      await limiter.acquire('chat-a', weight: 0);
      now = now.add(const Duration(seconds: 2));
      // weight 0 behaved like weight 1: only 1 s of the 3 s remain.
      await expectLater(
        limiter.acquire('chat-a'),
        completes,
      );
    });
  });
}
