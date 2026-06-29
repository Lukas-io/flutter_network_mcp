import 'package:flutter_network_mcp/src/util/body_status.dart';
import 'package:test/test.dart';

/// #59: distinguish a lost-upstream body from a genuinely-empty one.
void main() {
  Map<String, Object?> row({int? size, int fetched = 0, int attempts = 0}) => {
        'response_size': size,
        'bodies_fetched': fetched,
        'body_fetch_attempts': attempts,
      };

  test('bytes present -> stored', () {
    expect(bodyStatusFor(row: row(), which: 'response', hasBytes: true),
        {'bodyStatus': 'stored'});
  });

  test('size 0 -> empty (server sent nothing)', () {
    expect(bodyStatusFor(row: row(size: 0), which: 'response', hasBytes: false),
        {'bodyStatus': 'empty'});
  });

  test('backfill ran, nothing stored -> empty', () {
    expect(
        bodyStatusFor(
            row: row(size: -1, fetched: 1), which: 'response', hasBytes: false),
        {'bodyStatus': 'empty'});
  });

  test('not fetched, no attempts -> pending', () {
    expect(
        bodyStatusFor(
            row: row(size: -1, attempts: 0), which: 'response', hasBytes: false),
        {'bodyStatus': 'pending'});
  });

  test('not fetched, attempts made -> unavailable (lost upstream)', () {
    final s = bodyStatusFor(
        row: row(size: -1, attempts: 3), which: 'response', hasBytes: false);
    expect(s['bodyStatus'], 'unavailable');
    expect(s['fetchAttempts'], 3);
    expect(s['reason'], contains('evicted'));
  });
}
