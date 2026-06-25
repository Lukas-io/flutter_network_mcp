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
