/// Classifies why a captured body is present or absent, so an agent can tell
/// "the server sent nothing" from "we could not capture it in time" (issue
/// #59). [row] is an `http_requests` row; [which] is `request` | `response`;
/// [hasBytes] is whether a non-empty body was decoded.
///
/// Returns a map merged into the tool response:
/// - `stored`     — a body is present.
/// - `empty`      — the request genuinely had no body (size 0, or the backfill
///                  ran and stored nothing).
/// - `pending`    — the async body backfill has not run yet.
/// - `unavailable`— the body was lost (evicted by the VM profiler before
///                  backfill, or the fetch failed) after `fetchAttempts` tries.
Map<String, Object?> bodyStatusFor({
  required Map<String, Object?> row,
  required String which,
  required bool hasBytes,
}) {
  if (hasBytes) return const {'bodyStatus': 'stored'};

  final size = row[which == 'request' ? 'request_size' : 'response_size'] as int?;
  final fetched = (row['bodies_fetched'] as int? ?? 0) != 0;
  final attempts = row['body_fetch_attempts'] as int? ?? 0;

  // size 0 = genuinely empty; size -1 = unknown/chunked (a body likely existed).
  if (size == 0) return const {'bodyStatus': 'empty'};
  if (fetched) return const {'bodyStatus': 'empty'};
  if (attempts == 0) return const {'bodyStatus': 'pending'};
  return {
    'bodyStatus': 'unavailable',
    'fetchAttempts': attempts,
    'reason': 'evicted-before-backfill-or-fetch-failed',
  };
}
