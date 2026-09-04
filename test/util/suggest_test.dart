import 'package:flutter_network_mcp/src/util/suggest.dart';
import 'package:test/test.dart';

void main() {
  test('closestPaths ranks substring hits, then near misses', () {
    const paths = ['/driver/deliveries', '/vendors/me/orders', '/auth/login', '/deliverie'];
    expect(closestPaths(paths, 'deliveries').first, '/driver/deliveries');
    expect(closestPaths(paths, 'delivery'), contains('/deliverie'));
    expect(closestPaths(paths, 'zzz'), isEmpty);
  });

  test('normalizeGrep folds a leading (?i) into ignoreCase', () {
    final n = normalizeGrep('(?i)(totp|2fa)', false);
    expect(n.pattern, '(totp|2fa)');
    expect(n.ignoreCase, isTrue);
    expect(normalizeGrep('plain', false).ignoreCase, isFalse);
    expect(RegExp(n.pattern, caseSensitive: !n.ignoreCase).hasMatch('TOTP'), isTrue);
  });
}
