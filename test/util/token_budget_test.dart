import 'package:flutter_network_mcp/src/util/token_budget.dart';
import 'package:test/test.dart';

/// 0.9.1: token-budget trimming keeps newest-first rows until the estimated
/// cost exceeds the budget, never returns empty, reports what it dropped.
void main() {
  List<Map<String, Object?>> rows(int n) =>
      [for (var i = 0; i < n; i++) {'id': i, 'pad': 'x' * 40}];

  test('null / zero budget keeps everything', () {
    expect(trimToTokenBudget(rows(10), null).kept, hasLength(10));
    expect(trimToTokenBudget(rows(10), 0).kept, hasLength(10));
    expect(trimToTokenBudget(rows(10), null).dropped, 0);
  });

  test('trims to fit and reports dropped', () {
    final all = rows(20);
    final r = trimToTokenBudget(all, 30);
    expect(r.kept.length, lessThan(20));
    expect(r.dropped, 20 - r.kept.length);
    expect(r.keptTokens, lessThanOrEqualTo(30 + 20)); // within a row of budget
    // keeps the FRONT (newest-first) rows
    expect(r.kept.first['id'], 0);
  });

  test('always keeps at least one row even under a tiny budget', () {
    final r = trimToTokenBudget(rows(5), 1);
    expect(r.kept, hasLength(1));
    expect(r.dropped, 4);
  });

  test('empty input is a no-op', () {
    final r = trimToTokenBudget(<Map<String, Object?>>[], 100);
    expect(r.kept, isEmpty);
    expect(r.dropped, 0);
  });
}
