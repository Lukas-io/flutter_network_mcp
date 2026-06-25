import 'dart:convert';

/// Outcome of a semantic-truncation attempt.
///
/// `value` is the truncated text. `truncated` is true when any content was
/// dropped (an array collapsed, a string capped, the output itself
/// byte-capped). When [didApply] is false, the input wasn't parseable /
/// applicable and the caller should fall back to byte-truncation.
class SemanticTruncation {
  const SemanticTruncation({
    required this.value,
    required this.truncated,
    required this.didApply,
  });

  final String value;
  final bool truncated;
  final bool didApply;

  static const SemanticTruncation didNotApply = SemanticTruncation(
    value: '',
    truncated: false,
    didApply: false,
  );
}

/// Default thresholds — chosen to keep typical API responses recognizable
/// while bounding the output to a few KB. Caller can override via
/// [truncateJson]'s named params.
const int _kArraySampleSize = 5;
const int _kStringLeafBytes = 200;

/// Hard memory cap on the input we'll attempt to parse. Bodies larger than
/// this skip semantic truncation entirely (caller should byte-cap).
const int kSemanticInputCap = 262144;

/// Lossy structural truncation of a JSON string.
///
/// - Arrays longer than [arraySampleSize] keep the first N elements + a
///   trailing marker `{"_truncated": "<dropped> more, <shown> of <total>"}`
///   so the agent sees the shape but not the bulk.
/// - String values longer than [stringLeafBytes] are clipped with a
///   "...(<n> chars)" suffix.
/// - Objects are preserved key-for-key (the SHAPE of the response is what
///   the agent needs); recursion descends into values.
///
/// If the input doesn't parse as JSON, returns [SemanticTruncation.didNotApply]
/// so the caller can fall back to byte-truncation.
///
/// If the truncated output is still larger than [maxBytes], the output is
/// hard byte-capped at [maxBytes] and `truncated: true` stays set.
SemanticTruncation truncateJson(
  String input, {
  required int maxBytes,
  int arraySampleSize = _kArraySampleSize,
  int stringLeafBytes = _kStringLeafBytes,
}) {
  if (input.isEmpty) {
    return const SemanticTruncation(value: '', truncated: false, didApply: true);
  }
  if (input.length > kSemanticInputCap) {
    return SemanticTruncation.didNotApply;
  }

  final dynamic parsed;
  try {
    parsed = jsonDecode(input);
  } catch (_) {
    return SemanticTruncation.didNotApply;
  }

  final state = _TruncState(
    arraySampleSize: arraySampleSize,
    stringLeafBytes: stringLeafBytes,
  );
  final out = _walk(parsed, state);
  final encoded = const JsonEncoder.withIndent('  ').convert(out);
  if (encoded.length <= maxBytes) {
    return SemanticTruncation(
      value: encoded,
      truncated: state.truncated,
      didApply: true,
    );
  }
  return SemanticTruncation(
    value: encoded.substring(0, maxBytes),
    truncated: true,
    didApply: true,
  );
}

class _TruncState {
  _TruncState({
    required this.arraySampleSize,
    required this.stringLeafBytes,
  });

  final int arraySampleSize;
  final int stringLeafBytes;
  bool truncated = false;
}

Object? _walk(Object? node, _TruncState state) {
  if (node is List) {
    if (node.length > state.arraySampleSize) {
      state.truncated = true;
      final shown = node.sublist(0, state.arraySampleSize).map((e) => _walk(e, state)).toList();
      shown.add({
        '_truncated':
            '${node.length - state.arraySampleSize} more, ${state.arraySampleSize} of ${node.length} shown',
      });
      return shown;
    }
    return [for (final e in node) _walk(e, state)];
  }
  if (node is Map) {
    final out = <String, Object?>{};
    node.forEach((key, value) {
      out[key.toString()] = _walk(value, state);
    });
    return out;
  }
  if (node is String && node.length > state.stringLeafBytes) {
    state.truncated = true;
    return '${node.substring(0, state.stringLeafBytes)}…(${node.length} chars)';
  }
  return node;
}

/// Strips noise from HTML so the agent sees structure without scripts /
/// styles / comments / whitespace runs. Always "applies" — if the input
/// isn't really HTML, the regexes just don't match and the cleaning is
/// idempotent. Output is byte-capped at [maxBytes].
SemanticTruncation truncateHtml(String input, {required int maxBytes}) {
  if (input.isEmpty) {
    return const SemanticTruncation(value: '', truncated: false, didApply: true);
  }

  final original = input.length;

  var s = input
      .replaceAll(_htmlScriptRegex, '<script>...</script>')
      .replaceAll(_htmlStyleRegex, '<style>...</style>')
      .replaceAll(_htmlCommentRegex, '')
      .replaceAll(_htmlWhitespaceRegex, ' ')
      .trim();

  final truncatedSomeNoise = s.length != original;
  final overCap = s.length > maxBytes;
  if (overCap) s = s.substring(0, maxBytes);

  return SemanticTruncation(
    value: s,
    truncated: truncatedSomeNoise || overCap,
    didApply: true,
  );
}

final RegExp _htmlScriptRegex =
    RegExp(r'<script\b[^>]*>[\s\S]*?</script>', caseSensitive: false);
final RegExp _htmlStyleRegex =
    RegExp(r'<style\b[^>]*>[\s\S]*?</style>', caseSensitive: false);
final RegExp _htmlCommentRegex = RegExp(r'<!--[\s\S]*?-->');
final RegExp _htmlWhitespaceRegex = RegExp(r'\s+');
