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
  });
}
