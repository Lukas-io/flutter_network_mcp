/// Collapses dynamic segments of an HTTP path into placeholders so requests
/// hitting the "same endpoint" with different ids group together.
///
/// Per-segment, structural normalization (not per-character like the alert
/// signature normalizer): each `/`-separated segment is replaced by a
/// placeholder when it matches a known dynamic-id shape, otherwise it's
/// kept verbatim. Mixed-content segments stay intact (`abc-123` is NOT
/// `abc-N` — only segments that are PURELY a digit run / hex run / UUID
/// get replaced).
///
/// Query strings are stripped — `/api/users/42?expand=posts` becomes
/// `/api/users/N`. The endpoint identity is the path; query parameters
/// are caller-level, not routing-level.
///
/// Examples:
///
/// | Input                                          | Output            |
/// |---|---|
/// | `/api/users/42`                                | `/api/users/N`    |
/// | `/api/users/91/posts`                          | `/api/users/N/posts` |
/// | `/api/users/a3f7c8d219b4`                      | `/api/users/H`    |
/// | `/api/users/550e8400-e29b-41d4-a716-446655440000` | `/api/users/UUID` |
/// | `/api/products/abc-123`                        | `/api/products/abc-123` (mixed, untouched) |
/// | `/api/search?q=foo&page=2`                     | `/api/search`     |
/// | `/health`                                      | `/health`         |
///
/// Use this for endpoint-stats grouping (#2 `network_summarize`,
/// #5 baseline anomaly alerts) — anywhere two requests should be
/// considered the same endpoint despite differing ids.
String pathTemplate(String path) {
  if (path.isEmpty) return path;

  var working = path;
  final qIdx = working.indexOf('?');
  if (qIdx != -1) working = working.substring(0, qIdx);
  final hIdx = working.indexOf('#');
  if (hIdx != -1) working = working.substring(0, hIdx);

  final segments = working.split('/');
  for (var i = 0; i < segments.length; i++) {
    final seg = segments[i];
    if (seg.isEmpty) continue;
    if (_uuidRegex.hasMatch(seg)) {
      segments[i] = 'UUID';
    } else if (_digitsRegex.hasMatch(seg)) {
      segments[i] = 'N';
    } else if (_hexRegex.hasMatch(seg)) {
      segments[i] = 'H';
    }
  }
  return segments.join('/');
}

/// Pure digit run. Anchored — `abc-123` doesn't match, only `123`.
final RegExp _digitsRegex = RegExp(r'^[0-9]+$');

/// Pure hex run, 8+ characters. Catches generated request ids, short
/// hashes. Anchored — `abc-deadbeef` doesn't match.
final RegExp _hexRegex = RegExp(r'^[a-f0-9]{8,}$', caseSensitive: false);

/// Standard 8-4-4-4-12 UUID. Anchored.
final RegExp _uuidRegex = RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
  caseSensitive: false,
);
