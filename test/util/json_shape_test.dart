import 'package:flutter_network_mcp/src/util/json_shape.dart';
import 'package:test/test.dart';

/// 0.9.3: response-shape drift primitives.
void main() {
  group('jsonShape', () {
    test('flattens nested objects + arrays to keyPath -> type', () {
      final s = jsonShape({
        'id': 1,
        'name': 'a',
        'active': true,
        'tags': ['x'],
        'meta': {'created': '2020'},
      });
      expect(s['id'], 'number');
      expect(s['name'], 'string');
      expect(s['active'], 'bool');
      expect(s['tags'], 'array');
      expect(s['tags[]'], 'string');
      expect(s['meta'], 'object');
      expect(s['meta.created'], 'string');
    });

    test('int and double both map to number (no false drift)', () {
      expect(jsonShape({'n': 1})['n'], jsonShape({'n': 1.5})['n']);
    });
  });

  group('diffShapes', () {
    test('detects added, removed, and type-changed fields', () {
      final before = {'id': 'number', 'name': 'string', 'old': 'string'};
      final now = {'id': 'string', 'name': 'string', 'new': 'bool'};
      final d = diffShapes(before, now);
      expect(d['added'], ['new']);
      expect(d['removed'], ['old']);
      final changed = (d['changed'] as List).cast<Map<String, Object?>>();
      expect(changed.single['field'], 'id');
      expect(changed.single['before'], 'number');
      expect(changed.single['now'], 'string');
    });

    test('a null sample does not flag a type change', () {
      final d = diffShapes({'x': 'null'}, {'x': 'string'});
      expect(d['changed'], isEmpty);
    });

    test('identical shapes have no drift', () {
      final d = diffShapes({'a': 'string'}, {'a': 'string'});
      expect(d['added'], isEmpty);
      expect(d['removed'], isEmpty);
      expect(d['changed'], isEmpty);
    });
  });
}
