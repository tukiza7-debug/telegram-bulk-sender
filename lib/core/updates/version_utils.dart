/// Semantic version comparison for "vX.Y.Z" tags.
class VersionUtils {
  VersionUtils._();

  /// Strips an optional leading "v"/"V".
  static String normalize(String version) {
    var v = version.trim();
    if (v.startsWith('v') || v.startsWith('V')) v = v.substring(1);
    // Drop build metadata like "1.2.3+5".
    final plus = v.indexOf('+');
    if (plus > 0) v = v.substring(0, plus);
    // Drop pre-release suffix like "1.2.3-beta".
    final dash = v.indexOf('-');
    if (dash > 0) v = v.substring(0, dash);
    return v;
  }

  /// Returns -1, 0 or 1 comparing [a] against [b] numerically per segment.
  static int compare(String a, String b) {
    final pa = normalize(a).split('.');
    final pb = normalize(b).split('.');
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final na = i < pa.length ? int.tryParse(pa[i]) ?? 0 : 0;
      final nb = i < pb.length ? int.tryParse(pb[i]) ?? 0 : 0;
      if (na != nb) return na.compareTo(nb);
    }
    return 0;
  }

  /// True when [candidate] is strictly newer than [installed].
  static bool isNewer(String candidate, String installed) =>
      compare(candidate, installed) > 0;
}
