import 'package:flutter_network_mcp/src/alerts/anomaly_detector.dart';
import 'package:test/test.dart';

Map<String, Object?> row({
  String method = 'GET',
  String host = 'api.example.com',
  String path = '/api/users/42',
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
  group('AnomalyDetector.detectAnomalies', () {
    test('returns empty when both windows empty', () {
      final out = AnomalyDetector.instance.detectAnomalies(
        currentRows: const [],
        baselineRows: const [],
      );
      expect(out, isEmpty);
    });

    test('latency anomaly fires at 2x threshold', () {
      // Baseline: 10 requests at 100ms p95.
      final baseline = [for (var i = 0; i < 10; i++) row(durationMs: 100)];
      // Current: 10 requests at 300ms p95 (3x — over 2x threshold).
      final current = [for (var i = 0; i < 10; i++) row(durationMs: 300)];
      final out = AnomalyDetector.instance.detectAnomalies(
        currentRows: current,
        baselineRows: baseline,
      );
      expect(out.where((a) => a.kind == 'http_anomaly'), hasLength(1));
      final anomaly = out.firstWhere((a) => a.kind == 'http_anomaly');
      expect(anomaly.severity, 'warning');
      expect(anomaly.title, contains('p95 300ms vs baseline 100ms'));
      expect(anomaly.title, contains('3.0x'));
    });

    test('latency anomaly does NOT fire at 1.5x', () {
      final baseline = [for (var i = 0; i < 10; i++) row(durationMs: 100)];
      final current = [for (var i = 0; i < 10; i++) row(durationMs: 150)];
      final out = AnomalyDetector.instance.detectAnomalies(
        currentRows: current,
        baselineRows: baseline,
      );
      expect(out.where((a) => a.kind == 'http_anomaly'), isEmpty);
    });

    test('does NOT fire when current window has fewer than minRequests', () {
      final baseline = [for (var i = 0; i < 50; i++) row(durationMs: 100)];
      // Only 5 current requests at 1000ms — wouldn't pass minRequests.
      final current = [for (var i = 0; i < 5; i++) row(durationMs: 1000)];
      final out = AnomalyDetector.instance.detectAnomalies(
        currentRows: current,
        baselineRows: baseline,
      );
      expect(out, isEmpty);
    });

    test('does NOT fire when baseline has no traffic for endpoint', () {
      // Baseline has different endpoint.
      final baseline = [
        for (var i = 0; i < 10; i++) row(path: '/different/path'),
      ];
      final current = [for (var i = 0; i < 10; i++) row(durationMs: 5000)];
      final out = AnomalyDetector.instance.detectAnomalies(
        currentRows: current,
        baselineRows: baseline,
      );
      expect(out, isEmpty);
    });

    test('error-rate anomaly fires when 5x baseline AND above 10% floor', () {
      // Baseline: 1% error rate (1 of 100).
      final baseline = [
        for (var i = 0; i < 99; i++) row(status: 200),
        row(status: 500),
      ];
      // Current: 30% error rate (3 of 10) — 30x baseline.
      final current = [
        for (var i = 0; i < 7; i++) row(status: 200),
        for (var i = 0; i < 3; i++) row(status: 500),
      ];
      final out = AnomalyDetector.instance.detectAnomalies(
        currentRows: current,
        baselineRows: baseline,
      );
      final errAnomaly = out.where((a) => a.kind == 'http_anomaly_errors');
      expect(errAnomaly, hasLength(1));
      expect(errAnomaly.first.severity, 'error');
      expect(errAnomaly.first.title, contains('error rate 30.0%'));
      expect(errAnomaly.first.title, contains('1.0%'));
    });

    test('error-rate anomaly does NOT fire below 10% absolute floor', () {
      final baseline = [
        for (var i = 0; i < 199; i++) row(status: 200),
        row(status: 500), // 0.5%
      ];
      final current = [
        for (var i = 0; i < 9; i++) row(status: 200),
        row(status: 500), // 10% exactly — at floor, not above
      ];
      final out = AnomalyDetector.instance.detectAnomalies(
        currentRows: current,
        baselineRows: baseline,
      );
      expect(out.where((a) => a.kind == 'http_anomaly_errors'), isEmpty);
    });

    test('different endpoints produce different anomalies', () {
      final baseline = [
        for (var i = 0; i < 10; i++) row(path: '/api/users/1'),
        for (var i = 0; i < 10; i++) row(path: '/api/posts/1'),
      ];
      final current = [
        for (var i = 0; i < 10; i++) row(path: '/api/users/2', durationMs: 500),
        for (var i = 0; i < 10; i++) row(path: '/api/posts/2', durationMs: 500),
      ];
      final out = AnomalyDetector.instance.detectAnomalies(
        currentRows: current,
        baselineRows: baseline,
      );
      // Path template collapses /N suffix → same endpoint. So we expect
      // 2 anomalies (one per distinct endpoint).
      expect(out, hasLength(2));
      expect(
        out.map((a) => a.kind).toSet(),
        {'http_anomaly'},
      );
    });

    test('detail field reports comparison numbers', () {
      final baseline = [for (var i = 0; i < 10; i++) row(durationMs: 50)];
      final current = [for (var i = 0; i < 10; i++) row(durationMs: 200)];
      final out = AnomalyDetector.instance.detectAnomalies(
        currentRows: current,
        baselineRows: baseline,
      );
      expect(out.first.detail, contains('Current 30s p95 (200ms'));
      expect(out.first.detail, contains('baseline (50ms'));
      expect(out.first.detail, contains('Threshold: 2.0x'));
    });
  });
}
