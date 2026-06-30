import 'package:flutter_network_mcp/src/config/capture_filter.dart';
import 'package:test/test.dart';

/// #64: host/path-glob denylist + opt-in allowlist for capture filtering.
void main() {
  Uri u(String s) => Uri.parse(s);

  group('denylist', () {
    test('bare host matches the whole host (back-compat), any path', () {
      final f = CaptureFilter.build({'analytics.example.com'});
      expect(f.shouldCapture(u('https://analytics.example.com/anything')), isFalse);
      expect(f.shouldCapture(u('https://api.example.com/users')), isTrue);
    });

    test('host/path glob silences one path, keeps the rest of the host', () {
      // The motivating case: drop socket.io polling, keep the REST API.
      final f = CaptureFilter.build({'dev.example.com/socket.io/*'});
      expect(f.shouldCapture(u('https://dev.example.com/socket.io/?EIO=4')), isFalse);
      expect(f.shouldCapture(u('https://dev.example.com/socket.io/poll/123')), isFalse);
      expect(f.shouldCapture(u('https://dev.example.com/api/users')), isTrue);
      expect(f.shouldCapture(u('https://dev.example.com/stock/commodities')), isTrue);
    });

    test('matching is case-insensitive', () {
      final f = CaptureFilter.build({'Analytics.Example.COM'});
      expect(f.shouldCapture(u('https://analytics.example.com/x')), isFalse);
    });

    test('? matches a single char', () {
      final f = CaptureFilter.build({'h.com/v?/ping'});
      expect(f.shouldCapture(u('https://h.com/v1/ping')), isFalse);
      expect(f.shouldCapture(u('https://h.com/v12/ping')), isTrue);
    });
  });

  group('allowlist (opt-in, capture-only)', () {
    test('only matching requests are captured; everything else dropped', () {
      final f = CaptureFilter.build(const {}, allowOverride: ['api.example.com/stock/*']);
      expect(f.hasAllowlist, isTrue);
      expect(f.shouldCapture(u('https://api.example.com/stock/commodities')), isTrue);
      expect(f.shouldCapture(u('https://api.example.com/users')), isFalse);
      expect(f.shouldCapture(u('https://other.example.com/stock/x')), isFalse);
    });

    test('allow then deny — deny still wins inside the allowed set', () {
      final f = CaptureFilter.build(
        {'api.example.com/stock/secret/*'},
        allowOverride: ['api.example.com/stock/*'],
      );
      expect(f.shouldCapture(u('https://api.example.com/stock/list')), isTrue);
      expect(f.shouldCapture(u('https://api.example.com/stock/secret/x')), isFalse);
    });

    test('empty allowlist captures everything not denied', () {
      final f = CaptureFilter.build(const {});
      expect(f.hasAllowlist, isFalse);
      expect(f.shouldCapture(u('https://anything.com/path')), isTrue);
    });

    test('allowPatterns surfaces the raw patterns', () {
      final f = CaptureFilter.build(const {}, allowOverride: ['a.com/x', 'b.com']);
      expect(f.allowPatterns, ['a.com/x', 'b.com']);
    });

    test('allowEntries (the capture_allow table) drives the allowlist', () {
      final f = CaptureFilter.build(const {}, allowEntries: {'a.com/x'});
      expect(f.hasAllowlist, isTrue);
      expect(f.allowPatterns, contains('a.com/x'));
      expect(f.shouldCapture(u('https://a.com/x')), isTrue);
      expect(f.shouldCapture(u('https://a.com/y')), isFalse);
    });
  });

  test('empty() is inert', () {
    expect(CaptureFilter.empty().isActive, isFalse);
    expect(CaptureFilter.empty().shouldCapture(u('https://x.com/y')), isTrue);
  });
}
