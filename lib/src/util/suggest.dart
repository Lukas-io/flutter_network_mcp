/// What the capture can and cannot see — said wherever an empty result
/// could otherwise read as "the app made no such request" (#91).
const String kCaptureBoundary =
    'Only dart:io traffic (HttpClient, package:http, dio) is captured; native '
    'SDK traffic (analytics, crash reporting, ads, maps, payments) never '
    'touches dart:io and is not visible here — absence of a host is not '
    'evidence the SDK is idle.';

/// Closest captured paths to a query that matched nothing: substring hits
/// first, then small edit distances against the last path segment, then
/// prefix matches. Turns "deliveries" into "/driver/deliveries".
List<String> closestPaths(Iterable<String> paths, String query, {int max = 5}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final scored = <(int, String)>[];
  for (final p in paths) {
    final lp = p.toLowerCase();
    int? score;
    if (lp.contains(q)) {
      score = 0;
    } else {
      final last = lp.split('/').where((s) => s.isNotEmpty).lastOrNull ?? lp;
      final d = _levenshtein(last, q);
      if (d <= 3) {
        score = 10 + d;
      } else if (last.startsWith(q) || q.startsWith(last)) {
        score = 20;
      }
    }
    if (score != null) scored.add((score, p));
  }
  scored.sort((a, b) {
    final s = a.$1.compareTo(b.$1);
    return s != 0 ? s : a.$2.length.compareTo(b.$2.length);
  });
  final out = <String>[];
  for (final e in scored) {
    if (!out.contains(e.$2)) out.add(e.$2);
    if (out.length >= max) break;
  }
  return out;
}

/// A leading `(?i)` is not valid in Dart regexes; fold it into ignoreCase.
({String pattern, bool ignoreCase}) normalizeGrep(String pattern, bool ignoreCase) {
  if (pattern.startsWith('(?i)')) {
    return (pattern: pattern.substring(4), ignoreCase: true);
  }
  return (pattern: pattern, ignoreCase: ignoreCase);
}

int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      cur[j] = [cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost]
          .reduce((x, y) => x < y ? x : y);
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[b.length];
}
