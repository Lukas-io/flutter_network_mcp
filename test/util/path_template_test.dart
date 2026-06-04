import 'package:flutter_network_mcp/src/util/path_template.dart';
import 'package:test/test.dart';

void main() {
  group('pathTemplate', () {
    test('pure integer segment becomes N', () {
      expect(pathTemplate('/api/users/42'), '/api/users/N');
    });

    test('multiple integer segments all become N', () {
      expect(
        pathTemplate('/api/users/42/posts/91'),
        '/api/users/N/posts/N',
      );
    });

    test('hex segment of 8+ chars becomes H', () {
      expect(pathTemplate('/api/req/a3f7c8d2'), '/api/req/H');
      expect(pathTemplate('/api/req/a3f7c8d219b4'), '/api/req/H');
    });

    test('UUID becomes UUID', () {
      expect(
        pathTemplate('/api/users/550e8400-e29b-41d4-a716-446655440000'),
        '/api/users/UUID',
      );
    });

    test('UUID matching is case-insensitive', () {
      expect(
        pathTemplate('/api/users/550E8400-E29B-41D4-A716-446655440000'),
        '/api/users/UUID',
      );
    });

    test('mixed-content segments stay intact', () {
      expect(pathTemplate('/api/products/abc-123'), '/api/products/abc-123');
      expect(pathTemplate('/api/products/v2-final'), '/api/products/v2-final');
    });

    test('short hex (under 8 chars) does NOT collapse', () {
      expect(pathTemplate('/api/items/abc'), '/api/items/abc');
      expect(pathTemplate('/api/items/abcdef1'), '/api/items/abcdef1');
    });

    test('exactly 8 hex chars collapses', () {
      expect(pathTemplate('/api/items/abcdef12'), '/api/items/H');
    });

    test('query string is stripped', () {
      expect(pathTemplate('/api/search?q=foo'), '/api/search');
      expect(pathTemplate('/api/users/42?expand=posts'), '/api/users/N');
    });

    test('fragment is stripped', () {
      expect(pathTemplate('/page#section'), '/page');
    });

    test('paths without dynamic segments pass through unchanged', () {
      expect(pathTemplate('/health'), '/health');
      expect(pathTemplate('/api/v1/login'), '/api/v1/login');
    });

    test('root and empty input', () {
      expect(pathTemplate('/'), '/');
      expect(pathTemplate(''), '');
    });

    test('trailing slash preserved', () {
      expect(pathTemplate('/api/users/42/'), '/api/users/N/');
    });

    test('UUID-shaped strings without dashes do NOT match UUID', () {
      // 32 hex chars without dashes is just a long hex string — H, not UUID.
      expect(
        pathTemplate('/api/users/550e8400e29b41d4a716446655440000'),
        '/api/users/H',
      );
    });

    test('common REST path with integer id collapses', () {
      expect(
        pathTemplate('/api/v1/users/42/posts/91/comments/3'),
        '/api/v1/users/N/posts/N/comments/N',
      );
    });

    test('versioned API segments stay verbatim', () {
      // `v1`, `v2` are NOT pure digits and NOT 8+ hex — they're
      // identifiers and should stay.
      expect(pathTemplate('/api/v1/users'), '/api/v1/users');
      expect(pathTemplate('/api/v2/users'), '/api/v2/users');
    });
  });
}
