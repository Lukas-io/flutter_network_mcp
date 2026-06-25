import 'package:flutter_network_mcp/src/tools/usage_stats.dart';
import 'package:test/test.dart';

/// #79 Phase 2: per-tool aggregation + the consecutive tool->next-tool
/// transition graph computed from ordered tool_events rows.
void main() {
  Map<String, Object?> ev(
    String corr,
    String tool,
    String outcome, {
    int? dur,
    int? bytes,
  }) =>
      {
        'correlation_id': corr,
        'tool': tool,
        'outcome': outcome,
        'duration_ms': dur,
        'result_bytes': bytes,
      };

  Map<String, Object?> toolNamed(Map<String, Object?> stats, String name) =>
      (stats['tools'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((t) => t['tool'] == name);

  test('per-tool counts + outcome breakdown + rates', () {
    final rows = [
      ev('t1', 'network_list', 'ok'),
      ev('t1', 'network_list', 'empty'),
      ev('t1', 'network_get', 'error'),
      ev('t2', 'network_list', 'ok'),
    ];
    final s = summarizeUsage(rows);
    expect(s['totalEvents'], 4);
    expect(s['totalTurns'], 2);

    final list = toolNamed(s, 'network_list');
    expect(list['count'], 3);
    expect(list['ok'], 2);
    expect(list['empty'], 1);
    expect(list['emptyRate'], closeTo(0.3333, 0.001));

    final get = toolNamed(s, 'network_get');
    expect(get['error'], 1);
    expect(get['errorRate'], 1.0);
  });

  test('tools are sorted by count desc', () {
    final rows = [
      ev('t', 'a', 'ok'),
      ev('t', 'b', 'ok'),
      ev('t', 'b', 'ok'),
      ev('t', 'b', 'ok'),
    ];
    final tools =
        (summarizeUsage(rows)['tools'] as List).cast<Map<String, Object?>>();
    expect(tools.first['tool'], 'b');
  });

  test('transitions only count consecutive events WITHIN a turn', () {
    final rows = [
      ev('t1', 'network_status', 'ok'),
      ev('t1', 'alerts_drain', 'ok'),
      ev('t1', 'network_search', 'ok'),
      // new turn: the boundary must NOT create a search->status transition
      ev('t2', 'network_status', 'ok'),
      ev('t2', 'alerts_drain', 'ok'),
    ];
    final trans = (summarizeUsage(rows)['transitions'] as List)
        .cast<Map<String, Object?>>();
    Map<String, Object?>? find(String from, String to) {
      for (final t in trans) {
        if (t['from'] == from && t['to'] == to) return t;
      }
      return null;
    }

    expect(find('network_status', 'alerts_drain')!['count'], 2,
        reason: 'happens in both turns');
    expect(find('alerts_drain', 'network_search')!['count'], 1);
    expect(find('network_search', 'network_status'), isNull,
        reason: 'must not bridge across the turn boundary');
  });

  test('errorKinds breakdown + degraded count per tool (Tier-1 datapoints)', () {
    final rows = [
      {'correlation_id': 't', 'tool': 'network_get', 'outcome': 'error', 'error_kind': 'unresponsive_vm'},
      {'correlation_id': 't', 'tool': 'network_get', 'outcome': 'error', 'error_kind': 'unresponsive_vm'},
      {'correlation_id': 't', 'tool': 'network_get', 'outcome': 'error', 'error_kind': 'not_found'},
      {'correlation_id': 't', 'tool': 'network_get', 'outcome': 'ok', 'degraded': 1},
      {'correlation_id': 't', 'tool': 'network_get', 'outcome': 'ok'},
    ];
    final get = toolNamed(summarizeUsage(rows), 'network_get');
    expect(get['errorKinds'], {'unresponsive_vm': 2, 'not_found': 1});
    expect(get['degraded'], 1);
    // errorKinds is sorted busiest-first.
    expect((get['errorKinds'] as Map).keys.first, 'unresponsive_vm');
  });

  test('no error_kind / no degraded -> fields omitted (back-compat)', () {
    final rows = [
      {'correlation_id': 't', 'tool': 'x', 'outcome': 'ok'},
    ];
    final x = toolNamed(summarizeUsage(rows), 'x');
    expect(x.containsKey('errorKinds'), isFalse);
    expect(x.containsKey('degraded'), isFalse);
  });

  test('p50/p95 latency from durations', () {
    final rows = [
      for (var i = 1; i <= 100; i++) ev('t', 'x', 'ok', dur: i * 10),
    ];
    final x = toolNamed(summarizeUsage(rows), 'x');
    // floor(100*0.5)=50 -> sorted[50] = 510; floor(100*0.95)=95 -> 960
    expect(x['p50Ms'], 510);
    expect(x['p95Ms'], 960);
  });

  test('topTransitions caps the returned list', () {
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < 30; i++) {
      rows.add(ev('c', 'a$i', 'ok'));
      rows.add(ev('c', 'b$i', 'ok'));
    }
    final trans = summarizeUsage(rows, topTransitions: 5)['transitions'] as List;
    expect(trans, hasLength(5));
  });

  test('empty input yields zeroed stats', () {
    final s = summarizeUsage(const []);
    expect(s['totalEvents'], 0);
    expect(s['totalTurns'], 0);
    expect(s['tools'], isEmpty);
    expect(s['transitions'], isEmpty);
  });
}
