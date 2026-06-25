import 'dart:convert';

/// Result of trimming a list of result rows to a token budget.
class BudgetTrim {
  const BudgetTrim(this.kept, this.dropped, this.keptTokens);

  final List<Map<String, Object?>> kept;
  final int dropped;
  final int keptTokens;
}

/// Keeps rows from the front (callers pass newest-first) until adding the next
/// would push the estimated cost over [maxTokens], then drops the rest. Cost
/// per row is `jsonEncode(row).length / 4` (UTF-8 proxy, the same estimate the
/// usage telemetry uses). A null or non-positive budget keeps everything.
/// At least one row is always kept, so a tiny budget never yields an empty,
/// useless response (the caller can still page for the rest).
BudgetTrim trimToTokenBudget(
  List<Map<String, Object?>> rows,
  int? maxTokens,
) {
  if (maxTokens == null || maxTokens <= 0 || rows.isEmpty) {
    return BudgetTrim(rows, 0, _tokensOf(rows));
  }
  final kept = <Map<String, Object?>>[];
  var tokens = 0;
  for (final row in rows) {
    final cost = (jsonEncode(row).length / 4).ceil();
    if (kept.isNotEmpty && tokens + cost > maxTokens) break;
    kept.add(row);
    tokens += cost;
  }
  return BudgetTrim(kept, rows.length - kept.length, tokens);
}

int _tokensOf(List<Map<String, Object?>> rows) {
  var n = 0;
  for (final r in rows) {
    n += (jsonEncode(r).length / 4).ceil();
  }
  return n;
}
