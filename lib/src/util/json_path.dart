/// A deliberately small JSON path extractor (issue #61): enough to reach a
/// field deep in one captured body without pulling the whole thing into
/// context. Supports `$.a.b`, `a.b` (leading `$`/`.` optional), array index
/// `a[0].b`, bracket key `a['b']` / `a["b"]`, and the wildcard `a[*].b`
/// (collect a field across every array element, or every value of a map).
///
/// NOT supported: filter predicates like `[?(@.x=='y')]`, slices, recursive
/// descent `..`. For value-matching use the tool's `grep` mode instead.
library;

/// One selector step in a parsed path.
class _Sel {
  const _Sel.key(this.key)
      : index = null,
        wildcard = false;
  const _Sel.index(this.index)
      : key = null,
        wildcard = false;
  const _Sel.wildcard()
      : key = null,
        index = null,
        wildcard = true;
  final String? key;
  final int? index;
  final bool wildcard;
}

/// A matched node and the concrete path that reached it (wildcards resolved to
/// the actual index/key, e.g. `data[3].symbol`).
typedef PathMatch = ({String path, Object? value});

/// Thrown when [parseJsonPath] cannot make sense of the path string.
class JsonPathParseException implements Exception {
  JsonPathParseException(this.message);
  final String message;
  @override
  String toString() => 'Invalid jsonPath: $message';
}

/// Evaluates [path] against [root], returning every matched node with its
/// resolved path. Throws [JsonPathParseException] on a malformed path.
List<PathMatch> extractJsonPath(Object? root, String path) {
  final selectors = _parseJsonPath(path);
  var current = <PathMatch>[(path: r'$', value: root)];
  for (final sel in selectors) {
    final next = <PathMatch>[];
    for (final m in current) {
      final node = m.value;
      if (sel.wildcard) {
        if (node is List) {
          for (var i = 0; i < node.length; i++) {
            next.add((path: '${m.path}[$i]', value: node[i]));
          }
        } else if (node is Map) {
          for (final e in node.entries) {
            next.add((path: "${m.path}['${e.key}']", value: e.value));
          }
        }
      } else if (sel.index != null) {
        if (node is List && sel.index! >= 0 && sel.index! < node.length) {
          next.add((path: '${m.path}[${sel.index}]', value: node[sel.index!]));
        }
      } else {
        if (node is Map && node.containsKey(sel.key)) {
          next.add((path: '${m.path}.${sel.key}', value: node[sel.key]));
        }
      }
    }
    current = next;
    if (current.isEmpty) break;
  }
  return current;
}

/// Parses [path] into selector steps.
List<_Sel> _parseJsonPath(String path) {
  var s = path.trim();
  if (s.startsWith(r'$')) s = s.substring(1);
  final out = <_Sel>[];
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == '.') {
      i++;
      continue;
    }
    if (c == '[') {
      final end = s.indexOf(']', i);
      if (end < 0) throw JsonPathParseException('unclosed "[" at $i');
      var inner = s.substring(i + 1, end).trim();
      if (inner == '*') {
        out.add(const _Sel.wildcard());
      } else if ((inner.startsWith("'") && inner.endsWith("'")) ||
          (inner.startsWith('"') && inner.endsWith('"'))) {
        out.add(_Sel.key(inner.substring(1, inner.length - 1)));
      } else {
        final idx = int.tryParse(inner);
        if (idx == null) {
          throw JsonPathParseException('non-integer index "$inner"');
        }
        out.add(_Sel.index(idx));
      }
      i = end + 1;
    } else {
      // bare key: read until next '.' or '['
      var j = i;
      while (j < s.length && s[j] != '.' && s[j] != '[') {
        j++;
      }
      final key = s.substring(i, j);
      if (key.isNotEmpty) out.add(_Sel.key(key));
      i = j;
    }
  }
  if (out.isEmpty) throw JsonPathParseException('empty path');
  return out;
}
