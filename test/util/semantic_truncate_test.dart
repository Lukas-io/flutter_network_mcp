import 'dart:convert';

import 'package:flutter_network_mcp/src/util/semantic_truncate.dart';
import 'package:test/test.dart';

void main() {
  group('truncateJson', () {
    test('empty input returns empty applied result', () {
      final r = truncateJson('', maxBytes: 1000);
      expect(r.didApply, isTrue);
      expect(r.value, '');
      expect(r.truncated, isFalse);
    });

    test('unparseable input falls back to didNotApply', () {
      final r = truncateJson('not json {', maxBytes: 1000);
      expect(r.didApply, isFalse);
    });

    test('small JSON passes through without truncation', () {
      final input = jsonEncode({'a': 1, 'b': 'hello'});
      final r = truncateJson(input, maxBytes: 1000);
      expect(r.didApply, isTrue);
      expect(r.truncated, isFalse);
      expect(jsonDecode(r.value), {'a': 1, 'b': 'hello'});
    });

    test('large array collapses to sample + truncated marker', () {
      final input = jsonEncode({
        'items': [for (var i = 0; i < 47; i++) {'id': i, 'name': 'user$i'}],
      });
      final r = truncateJson(input, maxBytes: 4096);
      expect(r.didApply, isTrue);
      expect(r.truncated, isTrue);
      final decoded = jsonDecode(r.value) as Map;
      final items = decoded['items'] as List;
      // 5 sampled + 1 truncation marker
      expect(items.length, 6);
      expect((items.first as Map)['id'], 0);
      expect((items[4] as Map)['id'], 4);
      expect(items.last, containsPair('_truncated', '42 more, 5 of 47 shown'));
    });

    test('long string leaf gets clipped with char-count suffix', () {
      final longStr = 'x' * 500;
      final input = jsonEncode({'body': longStr});
      final r = truncateJson(input, maxBytes: 4096);
      expect(r.truncated, isTrue);
      final decoded = jsonDecode(r.value) as Map;
      final body = decoded['body'] as String;
      expect(body.startsWith('xxx'), isTrue);
      expect(body.endsWith('…(500 chars)'), isTrue);
    });

    test('nested structures recurse properly', () {
      final input = jsonEncode({
        'users': [
          {
            'id': 1,
            'posts': [for (var i = 0; i < 10; i++) {'title': 'post$i'}],
          },
        ],
      });
      final r = truncateJson(input, maxBytes: 4096);
      expect(r.truncated, isTrue);
      final decoded = jsonDecode(r.value) as Map;
      final user = (decoded['users'] as List).first as Map;
      final posts = user['posts'] as List;
      expect(posts.length, 6); // 5 sampled + 1 marker
    });

    test('arraySampleSize override changes the sample count', () {
      final input = jsonEncode([for (var i = 0; i < 20; i++) i]);
      final r = truncateJson(input, maxBytes: 4096, arraySampleSize: 3);
      final decoded = jsonDecode(r.value) as List;
      expect(decoded.length, 4); // 3 sampled + 1 marker
    });

    test('object keys are preserved (shape > content)', () {
      final input = jsonEncode({
        'a': 1, 'b': 2, 'c': 3, 'd': 4, 'e': 5, 'f': 6, 'g': 7,
      });
      final r = truncateJson(input, maxBytes: 4096);
      expect(r.didApply, isTrue);
      expect(r.truncated, isFalse);
      // All keys present.
      final decoded = jsonDecode(r.value) as Map;
      expect(decoded.keys.toList(), ['a', 'b', 'c', 'd', 'e', 'f', 'g']);
    });

    test('output over maxBytes hard-caps and marks truncated', () {
      final input = jsonEncode({
        for (var i = 0; i < 50; i++) 'key_$i': 'value_$i',
      });
      final r = truncateJson(input, maxBytes: 100);
      expect(r.didApply, isTrue);
      expect(r.truncated, isTrue);
      expect(r.value.length, lessThanOrEqualTo(100));
    });

    test('input larger than semantic cap falls back to didNotApply', () {
      final huge = '"${'x' * (kSemanticInputCap + 100)}"';
      final r = truncateJson(huge, maxBytes: 4096);
      expect(r.didApply, isFalse);
    });
  });

  group('truncateHtml', () {
    test('empty input', () {
      final r = truncateHtml('', maxBytes: 1000);
      expect(r.didApply, isTrue);
      expect(r.value, '');
      expect(r.truncated, isFalse);
    });

    test('strips script tag contents', () {
      const html = '<html><body><h1>Hi</h1><script>var x = 42; '
          'while(true){doStuff();}</script></body></html>';
      final r = truncateHtml(html, maxBytes: 4096);
      expect(r.value, contains('<h1>Hi</h1>'));
      expect(r.value, contains('<script>...</script>'));
      expect(r.value, isNot(contains('doStuff')));
      expect(r.truncated, isTrue);
    });

    test('strips style tag contents', () {
      const html = '<html><style>body { margin: 0; padding: 0; '
          'background: red; }</style><div>ok</div></html>';
      final r = truncateHtml(html, maxBytes: 4096);
      expect(r.value, contains('<style>...</style>'));
      expect(r.value, contains('<div>ok</div>'));
      expect(r.value, isNot(contains('margin')));
    });

    test('strips HTML comments', () {
      const html = '<div><!-- This is a comment that should go --><p>hi</p></div>';
      final r = truncateHtml(html, maxBytes: 4096);
      expect(r.value, contains('<p>hi</p>'));
      expect(r.value, isNot(contains('comment')));
    });

    test('collapses whitespace', () {
      const html = '<div>   hello    \n\n\t   world   </div>';
      final r = truncateHtml(html, maxBytes: 4096);
      expect(r.value, '<div> hello world </div>');
    });

    test('byte-caps when still too long after stripping', () {
      final html = '<div>${'x' * 5000}</div>';
      final r = truncateHtml(html, maxBytes: 100);
      expect(r.value.length, 100);
      expect(r.truncated, isTrue);
    });

    test('no noise: no truncation flag', () {
      const html = '<p>hi</p>';
      final r = truncateHtml(html, maxBytes: 4096);
      expect(r.didApply, isTrue);
      expect(r.truncated, isFalse);
      expect(r.value, '<p>hi</p>');
    });
  });
}
