import 'package:flutter_test/flutter_test.dart';
import 'package:telegram_bulk_sender/core/updates/version_utils.dart';

void main() {
  group('VersionUtils.compare', () {
    test('handles v prefix and equality', () {
      expect(VersionUtils.compare('v1.0.0', '1.0.0'), 0);
      expect(VersionUtils.compare('v1.0.1', '1.0.0'), 1);
      expect(VersionUtils.compare('1.0.0', 'v1.0.1'), -1);
    });

    test('compares numerically, not lexicographically', () {
      expect(VersionUtils.compare('1.10.0', '1.9.0'), 1);
      expect(VersionUtils.compare('0.9.0', '0.10.0'), -1);
      expect(VersionUtils.compare('2.0.0', '1.99.99'), 1);
    });

    test('short versions are padded', () {
      expect(VersionUtils.compare('1.2', '1.2.0'), 0);
      expect(VersionUtils.compare('1.2', '1.2.1'), -1);
    });

    test('strips build metadata and pre-release tags', () {
      expect(VersionUtils.compare('1.2.3+5', '1.2.3'), 0);
      expect(VersionUtils.compare('1.2.3-beta.1', '1.2.3'), 0);
    });
  });

  group('VersionUtils.isNewer', () {
    test('returns true only for strictly newer versions', () {
      expect(VersionUtils.isNewer('v1.0.1', '1.0.0'), isTrue);
      expect(VersionUtils.isNewer('v1.0.0', '1.0.0'), isFalse);
      expect(VersionUtils.isNewer('v0.9.0', '1.0.0'), isFalse);
    });
  });
}
