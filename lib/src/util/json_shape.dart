import 'dart:convert';

/// Builds a compact structural "skeleton" of a decoded JSON [value] (issue
/// #60): keys, value types, array lengths, and per-branch byte sizes, with NO
/// values. Lets an agent understand a 1-2 MB response and see WHERE the bytes
/// are in a few hundred tokens, then `network_body` exactly the slice it needs.
///
/// Shape:
/// - scalar -> a type string: `string` | `number` | `bool` | `null`.
/// - array  -> `{type:'array', count:N, bytes:B, element:<skeleton of [0]>}`
///   (only the first element's shape, since arrays are usually homogeneous).
/// - object -> `{type:'object', keys:N, bytes:B, fields:{k:<skeleton>}}`,
///   plus `omittedKeys:M` when it has more than [maxKeys] keys.
/// Beyond [maxDepth], a container collapses to `{type, count|keys, bytes,
/// truncated:'maxDepth'}` so a deep document can never blow up the outline.
/// `bytes` is the minified-JSON byte size of that branch — the signal for
/// where to drill.
Object? jsonSkeleton(Object? value, {int maxDepth = 6, int maxKeys = 60}) {
  Object? node(Object? v, int depth) {
    if (v is Map) {
      final bytes = _byteLen(v);
      if (depth >= maxDepth) {
        return {'type': 'object', 'keys': v.length, 'bytes': bytes, 'truncated': 'maxDepth'};
      }
      final fields = <String, Object?>{};
      var i = 0;
      for (final e in v.entries) {
        if (i >= maxKeys) break;
        fields[e.key.toString()] = node(e.value, depth + 1);
        i++;
      }
      return {
        'type': 'object',
        'keys': v.length,
        'bytes': bytes,
        'fields': fields,
        if (v.length > maxKeys) 'omittedKeys': v.length - maxKeys,
      };
    }
    if (v is List) {
      final bytes = _byteLen(v);
      if (v.isEmpty) return {'type': 'array', 'count': 0, 'bytes': bytes};
      if (depth >= maxDepth) {
        return {'type': 'array', 'count': v.length, 'bytes': bytes, 'truncated': 'maxDepth'};
      }
      return {
        'type': 'array',
        'count': v.length,
        'bytes': bytes,
        'element': node(v.first, depth + 1),
      };
    }
    return _typeOf(v);
  }

  return node(value, 0);
}

int _byteLen(Object? v) {
  try {
    return utf8.encode(json.encode(v)).length;
  } catch (_) {
    return -1;
  }
}

/// Flattens a decoded JSON value into a `keyPath -> type` map, the structural
/// "shape" of a response. Arrays use `[]` for their element path; int and
/// double both map to `number` so int<->double jitter is not reported as
/// drift. Used by network_drift to detect API contract changes over time.
Map<String, String> jsonShape(Object? value) {
  final out = <String, String>{};
  void walk(String path, Object? node) {
    if (node is Map) {
      if (path.isNotEmpty) out[path] = 'object';
      for (final e in node.entries) {
        final k = e.key.toString();
        walk(path.isEmpty ? k : '$path.$k', e.value);
      }
    } else if (node is List) {
      out[path.isEmpty ? '[]' : path] = 'array';
      if (node.isNotEmpty) walk(path.isEmpty ? '[]' : '$path[]', node.first);
    } else {
      out[path.isEmpty ? '(root)' : path] = _typeOf(node);
    }
  }

  walk('', value);
  return out;
}

String _typeOf(Object? v) {
  if (v == null) return 'null';
  if (v is bool) return 'bool';
  if (v is num) return 'number';
  if (v is String) return 'string';
  return 'unknown';
}

/// Compares two shapes. Returns added (in [now] only), removed (in [before]
/// only), and changed (in both, different type, with before/now). `null` type
/// is treated as compatible with any concrete type so a single null sample
/// does not flag every field, only concrete-to-concrete type changes count.
Map<String, Object?> diffShapes(
  Map<String, String> before,
  Map<String, String> now,
) {
  final added = [
    for (final k in now.keys)
      if (!before.containsKey(k)) k,
  ]..sort();
  final removed = [
    for (final k in before.keys)
      if (!now.containsKey(k)) k,
  ]..sort();
  final changed = <Map<String, Object?>>[];
  for (final k in now.keys) {
    final b = before[k];
    final n = now[k];
    if (b == null || n == null) continue;
    if (b == n || b == 'null' || n == 'null') continue;
    changed.add({'field': k, 'before': b, 'now': n});
  }
  changed.sort((a, b) => (a['field'] as String).compareTo(b['field'] as String));
  return {'added': added, 'removed': removed, 'changed': changed};
}
