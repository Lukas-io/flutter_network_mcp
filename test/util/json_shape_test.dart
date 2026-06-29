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

  group('jsonSkeleton (#60: structure, no values)', () {
    test('object -> type/keys/bytes/fields, scalars become type strings', () {
      final s = jsonSkeleton({'id': 1, 'name': 'a', 'active': true}) as Map;
      expect(s['type'], 'object');
      expect(s['keys'], 3);
      expect(s['bytes'], greaterThan(0));
      final fields = s['fields'] as Map;
      expect(fields['id'], 'number');
      expect(fields['name'], 'string');
      expect(fields['active'], 'bool');
    });

    test('array collapses to count + first-element shape (not every element)', () {
      final s = jsonSkeleton({
        'data': [
          {'x': 1},
          {'x': 2},
          {'x': 3},
        ],
      }) as Map;
      final data = (s['fields'] as Map)['data'] as Map;
      expect(data['type'], 'array');
      expect(data['count'], 3);
      expect((data['element'] as Map)['type'], 'object');
      expect(((data['element'] as Map)['fields'] as Map)['x'], 'number');
    });

    test('no values leak — only types, counts, sizes', () {
      final s = jsonSkeleton({'secret': 'hunter2', 'token': 'abc123'});
      expect(s.toString().contains('hunter2'), isFalse);
      expect(s.toString().contains('abc123'), isFalse);
      final fields = (s as Map)['fields'] as Map;
      expect(fields['secret'], 'string');
      expect(fields['token'], 'string');
    });

    test('maxDepth collapses deep branches', () {
      final deep = {
        'a': {'b': {'c': {'d': {'e': {'f': {'g': 1}}}}}},
      };
      final s = jsonSkeleton(deep, maxDepth: 2);
      // somewhere down the chain a node is collapsed with truncated:maxDepth
      var node = ((s as Map)['fields'] as Map)['a'] as Map;
      node = (node['fields'] as Map)['b'] as Map;
      expect(node['truncated'], 'maxDepth');
    });

    test('maxKeys caps expanded fields and reports omittedKeys', () {
      final big = {for (var i = 0; i < 10; i++) 'k$i': i};
      final s = jsonSkeleton(big, maxKeys: 3) as Map;
      expect((s['fields'] as Map).length, 3);
      expect(s['omittedKeys'], 7);
    });

    test('empty array -> count 0, no element', () {
      final s = jsonSkeleton({'items': <Object?>[]}) as Map;
      final items = (s['fields'] as Map)['items'] as Map;
      expect(items['count'], 0);
      expect(items.containsKey('element'), isFalse);
    });
  });
}
