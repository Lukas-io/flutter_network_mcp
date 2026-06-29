import 'package:flutter_network_mcp/src/util/json_path.dart';
import 'package:test/test.dart';

/// #61: small JSON path extractor for in-body extract.
void main() {
  final doc = {
    'data': [
      {'id': 0, 'symbol': 'aapl', 'meta': {'sector': 'tech'}},
      {'id': 1, 'symbol': 'tsla', 'meta': {'sector': 'auto'}},
      {'id': 2, 'symbol': 'msft', 'meta': {'sector': 'tech'}},
    ],
    'pagination': {'page': 1, 'total': 3},
  };

  group('extractJsonPath', () {
    test('dotted path to a scalar', () {
      final hits = extractJsonPath(doc, r'$.pagination.total');
      expect(hits.single.value, 3);
      expect(hits.single.path, r'$.pagination.total');
    });

    test('array index', () {
      final hits = extractJsonPath(doc, r'$.data[1].symbol');
      expect(hits.single.value, 'tsla');
      expect(hits.single.path, r'$.data[1].symbol');
    });

    test('wildcard collects a field across the array (resolved paths)', () {
      final hits = extractJsonPath(doc, r'$.data[*].symbol');
      expect(hits.map((h) => h.value).toList(), ['aapl', 'tsla', 'msft']);
      expect(hits.map((h) => h.path).toList(),
          [r'$.data[0].symbol', r'$.data[1].symbol', r'$.data[2].symbol']);
    });

    test('wildcard over a map collects values', () {
      final hits = extractJsonPath(doc, r'$.pagination[*]');
      expect(hits.map((h) => h.value).toSet(), {1, 3});
    });

    test(r'leading $ and bare path are equivalent', () {
      expect(extractJsonPath(doc, r'$.pagination.page').single.value,
          extractJsonPath(doc, 'pagination.page').single.value);
    });

    test('bracket-quoted key', () {
      expect(extractJsonPath(doc, r"$['pagination']['page']").single.value, 1);
    });

    test('nested wildcard then key', () {
      final hits = extractJsonPath(doc, r'$.data[*].meta.sector');
      expect(hits.map((h) => h.value).toList(), ['tech', 'auto', 'tech']);
    });

    test('missing key -> no matches', () {
      expect(extractJsonPath(doc, r'$.nope.here'), isEmpty);
    });

    test('out-of-range index -> no matches', () {
      expect(extractJsonPath(doc, r'$.data[99].symbol'), isEmpty);
    });

    test('malformed path throws JsonPathParseException', () {
      expect(() => extractJsonPath(doc, r'$.data[abc]'),
          throwsA(isA<JsonPathParseException>()));
      expect(() => extractJsonPath(doc, r'$.data[1'),
          throwsA(isA<JsonPathParseException>()));
      expect(() => extractJsonPath(doc, r'$'),
          throwsA(isA<JsonPathParseException>()));
    });
  });
}
