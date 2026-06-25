import 'package:flutter_network_mcp/src/tools/network_diff_session.dart';
import 'package:test/test.dart';

/// 0.9.2: "what changed between two runs" — endpoint-level diff.
void main() {
  Map<String, Object?> ep(
    String endpoint, {
    double errorRate = 0.0,
    int? p95 = 100,
    int count = 10,
  }) =>
      {
        'endpoint': endpoint,
        'errorRate': errorRate,
        'p95LatencyMs': p95,
        'count': count,
      };

  test('new + gone endpoints are detected', () {
    final d = diffEndpointSummaries(
      [ep('GET api/a'), ep('GET api/new')],
      [ep('GET api/a'), ep('GET api/gone')],
    );
    expect((d['newEndpoints'] as List).single['endpoint'], 'GET api/new');
    expect((d['goneEndpoints'] as List).single['endpoint'], 'GET api/gone');
  });

  test('material error-rate jump flags a changed endpoint', () {
    final d = diffEndpointSummaries(
      [ep('GET api/a', errorRate: 0.5)],
      [ep('GET api/a', errorRate: 0.0)],
    );
    final changed = (d['changed'] as List).cast<Map<String, Object?>>();
    expect(changed.single['endpoint'], 'GET api/a');
    expect((changed.single['errorRate'] as Map)['delta'], closeTo(0.5, 0.001));
  });

  test('p95 regression of 2x flags a changed endpoint', () {
    final d = diffEndpointSummaries(
      [ep('GET api/a', p95: 900)],
      [ep('GET api/a', p95: 100)],
    );
    expect((d['changed'] as List), hasLength(1));
  });

  test('a stable endpoint is NOT flagged as changed', () {
    final d = diffEndpointSummaries(
      [ep('GET api/a', errorRate: 0.02, p95: 110)],
      [ep('GET api/a', errorRate: 0.01, p95: 100)],
    );
    expect((d['changed'] as List), isEmpty);
  });
}
