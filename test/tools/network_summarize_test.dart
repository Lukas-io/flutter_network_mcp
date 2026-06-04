import 'package:flutter_network_mcp/src/tools/network_summarize.dart';
import 'package:test/test.dart';

Map<String, Object?> row({
  String method = 'GET',
  String host = 'api.example.com',
  String path = '/health',
  int? status = 200,
  int durationMs = 100,
}) {
  return {
    'method': method,
    'host': host,
    'path': path,
    'status_code': status,
    'duration_us': durationMs * 1000,
  };
}

void main() {
  group('summarizeRequests', () {
    test('empty input returns empty list', () {
      expect(summarizeRequests(const []), isEmpty);
    });

    test('single endpoint with one request', () {
      final result = summarizeRequests([row()]);
      expect(result, hasLength(1));
      final e = result.first;
      expect(e['endpoint'], 'GET api.example.com/health');
      expect(e['method'], 'GET');
      expect(e['host'], 'api.example.com');
      expect(e['pathTemplate'], '/health');
      expect(e['count'], 1);
      expect(e['statusDist'], {'200': 1});
      expect(e['p50LatencyMs'], 100);
      expect(e['p95LatencyMs'], 100);
      expect(e['errorRate'], 0.0);
    });

    test('different user ids collapse via path template', () {
      final rows = [
        row(path: '/api/users/42'),
        row(path: '/api/users/91'),
        row(path: '/api/users/123'),
      ];
      final result = summarizeRequests(rows);
      expect(result, hasLength(1));
      expect(result.first['pathTemplate'], '/api/users/N');
      expect(result.first['count'], 3);
    });

    test('different methods stay distinct', () {
      final rows = [
        row(method: 'GET', path: '/api/users/42'),
        row(method: 'POST', path: '/api/users/42'),
      ];
      final result = summarizeRequests(rows);
      expect(result, hasLength(2));
    });

    test('different hosts stay distinct', () {
      final rows = [
        row(host: 'api.example.com', path: '/v1/users'),
        row(host: 'api.other.com', path: '/v1/users'),
      ];
      final result = summarizeRequests(rows);
      expect(result, hasLength(2));
    });

    test('sorted by count descending', () {
      final rows = [
        row(path: '/api/once'),
        row(path: '/api/three'),
        row(path: '/api/three'),
        row(path: '/api/three'),
        row(path: '/api/twice'),
        row(path: '/api/twice'),
      ];
      final result = summarizeRequests(rows);
      expect(
        result.map((e) => e['count']).toList(),
        [3, 2, 1],
      );
    });

    test('minCount filters out low-volume endpoints', () {
      final rows = [
        row(path: '/api/once'),
        row(path: '/api/twice'),
        row(path: '/api/twice'),
      ];
      final result = summarizeRequests(rows, minCount: 2);
      expect(result, hasLength(1));
      expect(result.first['pathTemplate'], '/api/twice');
    });

    test('status distribution buckets all status codes', () {
      final rows = [
        row(status: 200),
        row(status: 200),
        row(status: 200),
        row(status: 404),
        row(status: 500),
      ];
      final result = summarizeRequests(rows);
      expect(result.first['statusDist'], {'200': 3, '404': 1, '500': 1});
    });

    test('null status counted as synthetic "error"', () {
      final rows = [
        row(status: 200),
        row(status: null),
        row(status: null),
      ];
      final result = summarizeRequests(rows);
      expect(result.first['statusDist'], {'200': 1, 'error': 2});
    });

    test('error rate = 4xx+5xx+null/total', () {
      final rows = [
        row(status: 200),
        row(status: 200),
        row(status: 404),
        row(status: 500),
        row(status: null),
      ];
      final result = summarizeRequests(rows);
      // 3 errors (404, 500, null) of 5 total = 0.6
      expect(result.first['errorRate'], 0.6);
    });

    test('p50 + p95 latency percentiles', () {
      // 100 requests with durations 1..100 ms
      final rows = [
        for (var i = 1; i <= 100; i++) row(durationMs: i),
      ];
      final result = summarizeRequests(rows);
      // p50 floor(100 * 0.5) = index 50, value 51 (0-indexed array of 1..100)
      expect(result.first['p50LatencyMs'], 51);
      // p95 floor(100 * 0.95) = index 95, value 96
      expect(result.first['p95LatencyMs'], 96);
    });

    test('percentiles handle single duration sample', () {
      final result = summarizeRequests([row(durationMs: 250)]);
      expect(result.first['p50LatencyMs'], 250);
      expect(result.first['p95LatencyMs'], 250);
    });

    test('path template applied to query-string paths', () {
      final rows = [
        row(path: '/api/search?q=foo'),
        row(path: '/api/search?q=bar'),
      ];
      final result = summarizeRequests(rows);
      expect(result, hasLength(1));
      expect(result.first['pathTemplate'], '/api/search');
      expect(result.first['count'], 2);
    });
  });
}
