import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../util/json_path.dart';
import '../util/json_shape.dart';
import '../util/scope.dart';
import 'body_fetch.dart';
import 'error_kind.dart';
import 'result.dart';

/// Above this decoded size, grep is refused (a pathological regex over a huge
/// string can stall the synchronous matcher). Use network_body to page instead.
const int _kMaxGrepBytes = 16 * 1024 * 1024;
const int _kDefaultMaxMatches = 20;
const int _kDefaultContext = 80;
const int _kPerValueBytes = 2048;

final networkBodyQueryTool = Tool(
  name: 'network_body_query',
  description:
      'Search or extract WITHIN one captured body, returning only the '
      'matching slice(s) instead of paging the whole thing. Two modes: '
      'grep:"<regex>" (text match with context windows + offsets) or '
      'jsonPath:"\$.data[*].symbol" (extract nodes by path). Pair with '
      'network_body_outline (find the branch) then query it.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.string(description: 'Request id from network_list / network_search.'),
      'which': Schema.string(description: '"response" (default) or "request".'),
      'grep': Schema.string(
        description: 'Regex to match against the decoded text body. Returns matches with offsets + context.',
      ),
      'jsonPath': Schema.string(
        description:
            'Path to extract from a JSON body: \$.a.b, a[0].b, a[*].b (wildcard '
            'across an array/map). No filter predicates — use grep for value matching.',
      ),
      'ignoreCase': Schema.bool(description: 'Case-insensitive grep. Default false.'),
      'maxMatches': Schema.int(description: 'Cap on returned matches. Default 20.'),
      'context': Schema.int(description: 'Chars of context around each grep match. Default 80.'),
      'sessionId': Schema.int(
        description: 'Session to read from. Omit to auto-resolve.',
      ),
      'appNameContains': Schema.string(
        description: 'Pick the session by app-name substring instead of sessionId.',
      ),
      'isolateId': Schema.string(description: 'Restrict to one isolate. Omit to auto-resolve.'),
    },
    required: ['id'],
  ),
);

FutureOr<CallToolResult> networkBodyQuery(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final id = args['id'] as String?;
  if (id == null || id.isEmpty) {
    return errorResult('Missing required arg `id`.',
        kind: ErrorKind.badArgument,
        extra: const {
          'nextSteps': [
            'network_list — list captured requests and pick an id',
            'network_search query:"..." — find a request by content',
          ],
        });
  }
  final whichArg = (args['which'] as String?) ?? 'response';
  if (whichArg != 'request' && whichArg != 'response') {
    return errorResult('`which` must be "request" or "response".',
        kind: ErrorKind.badArgument,
        extra: const {
          'nextSteps': ['Retry with which:"response" (default)'],
        });
  }
  final which = whichArg;
  final grep = args['grep'] as String?;
  final jsonPath = args['jsonPath'] as String?;
  if ((grep == null || grep.isEmpty) && (jsonPath == null || jsonPath.isEmpty)) {
    return errorResult('Provide exactly one of `grep` or `jsonPath`.',
        kind: ErrorKind.badArgument,
        extra: const {
          'nextSteps': [
            'network_body_query id:<id> grep:"<regex>" — text search the body',
            'network_body_query id:<id> jsonPath:"\$.data[*].id" — extract by path',
          ],
        });
  }
  if (grep != null && grep.isNotEmpty && jsonPath != null && jsonPath.isNotEmpty) {
    return errorResult('Provide only one of `grep` or `jsonPath`, not both.',
        kind: ErrorKind.badArgument);
  }
  final ignoreCase = (args['ignoreCase'] as bool?) ?? false;
  final maxMatches = (args['maxMatches'] as int?) ?? _kDefaultMaxMatches;
  final context = (args['context'] as int?) ?? _kDefaultContext;

  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;

  try {
    final fetch = await fetchBodyBytes(scope, id, which,
        isolateId: args['isolateId'] as String?);
    if (fetch.error != null) return fetch.error!;
    final bytes = fetch.bytes;
    final mimeType = fetch.mimeType;
    final source = fetch.source;

    if (bytes == null || bytes.isEmpty) {
      return noBodyResult(scope, id, which, source, mimeType);
    }
    final total = bytes.length;

    if (grep != null && grep.isNotEmpty) {
      return _grep(
        scope: scope,
        id: id,
        which: which,
        source: source,
        mimeType: mimeType,
        bytes: bytes,
        total: total,
        pattern: grep,
        ignoreCase: ignoreCase,
        maxMatches: maxMatches < 1 ? _kDefaultMaxMatches : maxMatches,
        context: context < 0 ? _kDefaultContext : context,
      );
    }

    return _jsonPath(
      scope: scope,
      id: id,
      which: which,
      source: source,
      mimeType: mimeType,
      bytes: bytes,
      total: total,
      path: jsonPath!,
      maxMatches: maxMatches < 1 ? _kDefaultMaxMatches : maxMatches,
    );
  } catch (e) {
    return errorResult('body query failed: $e',
        kind: ErrorKind.internal,
        extra: {
          'id': id,
          'which': which,
          'nextSteps': const [
            'network_body_outline id:<id> — inspect the structure first',
            'network_body id:<id> which:response — page raw bytes',
          ],
        });
  }
}

CallToolResult _grep({
  required Scope scope,
  required String id,
  required String which,
  required String source,
  required String? mimeType,
  required List<int> bytes,
  required int total,
  required String pattern,
  required bool ignoreCase,
  required int maxMatches,
  required int context,
}) {
  if (total > _kMaxGrepBytes) {
    return errorResult(
      'Body is ${total}B (> ${_kMaxGrepBytes}B grep cap) — page it instead.',
      kind: ErrorKind.badArgument,
      extra: {
        'id': id,
        'nextSteps': const [
          'network_body_outline id:<id> — find the branch, then page it',
          'network_body id:<id> which:response — byte-range paging',
        ],
      },
    );
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  final RegExp re;
  try {
    re = RegExp(pattern, caseSensitive: !ignoreCase, multiLine: true);
  } catch (e) {
    return errorResult('Invalid grep regex: $e',
        kind: ErrorKind.badArgument,
        extra: const {
          'nextSteps': ['Retry with a valid Dart RegExp pattern'],
        });
  }
  final matches = <Map<String, Object?>>[];
  var totalMatches = 0;
  for (final m in re.allMatches(text)) {
    totalMatches++;
    if (matches.length >= maxMatches) continue;
    final start = m.start;
    final end = m.end;
    final ctxStart = (start - context) < 0 ? 0 : start - context;
    final ctxEnd = (end + context) > text.length ? text.length : end + context;
    matches.add({
      'offset': start,
      'match': _cap(text.substring(start, end), 512),
      'context': _cap(text.substring(ctxStart, ctxEnd), context * 2 + 512),
    });
  }
  final truncated = totalMatches > matches.length;
  return jsonResult({
    'source': source,
    'scope': scope.toBlock(),
    'sessionId': scope.sessionId,
    'summary': totalMatches == 0
        ? 'No grep matches for /$pattern/ in $which body of $id.'
        : 'Matched /$pattern/ ${totalMatches}x in $which body of $id'
            '${truncated ? " (showing first ${matches.length})" : ""}.',
    'id': id,
    'which': which,
    'mode': 'grep',
    if (mimeType != null) 'mimeType': mimeType,
    'totalSize': total,
    'totalMatches': totalMatches,
    'matches': matches,
    if (truncated) 'truncated': true,
    'nextSteps': [
      if (matches.isNotEmpty)
        'network_body id:"$id" which:$which offset:${matches.first['offset']} length:16384 — read full bytes around the first match',
    ],
  }, scopeSessionId: scope.sessionId, scopeNote: scope.note);
}

CallToolResult _jsonPath({
  required Scope scope,
  required String id,
  required String which,
  required String source,
  required String? mimeType,
  required List<int> bytes,
  required int total,
  required String path,
  required int maxMatches,
}) {
  Object? decoded;
  try {
    decoded = json.decode(utf8.decode(bytes));
  } catch (e) {
    return errorResult('Body is not valid JSON (${e.runtimeType}) — use grep.',
        kind: ErrorKind.badArgument,
        extra: {
          'id': id,
          'nextSteps': const [
            'network_body_query id:<id> grep:"<regex>" — text search instead',
          ],
        });
  }
  List<PathMatch> hits;
  try {
    hits = extractJsonPath(decoded, path);
  } on JsonPathParseException catch (e) {
    return errorResult(e.message,
        kind: ErrorKind.badArgument,
        extra: const {
          'nextSteps': [
            'Use a supported path: \$.a.b, a[0].b, a[*].b (no filter predicates)',
            'network_body_query id:<id> grep:"<regex>" — for value matching',
          ],
        });
  }
  final totalHits = hits.length;
  final shown = hits.take(maxMatches).map((h) {
    final encoded = json.encode(h.value);
    if (encoded.length <= _kPerValueBytes) {
      return {'path': h.path, 'value': h.value};
    }
    // Too big to inline — give the shape + size so the agent can drill.
    return {
      'path': h.path,
      'valueBytes': encoded.length,
      'truncated': true,
      'outline': jsonSkeleton(h.value, maxDepth: 3),
    };
  }).toList();
  final truncated = totalHits > shown.length;
  return jsonResult({
    'source': source,
    'scope': scope.toBlock(),
    'sessionId': scope.sessionId,
    'summary': totalHits == 0
        ? 'jsonPath $path matched nothing in $which body of $id.'
        : 'jsonPath $path matched $totalHits node(s) in $which body of $id'
            '${truncated ? " (showing $maxMatches)" : ""}.',
    'id': id,
    'which': which,
    'mode': 'jsonPath',
    if (mimeType != null) 'mimeType': mimeType,
    'totalSize': total,
    'totalMatches': totalHits,
    'matches': shown,
    if (truncated) 'truncated': true,
    'nextSteps': const [
      'network_body_outline id:<id> — see the full structure if the path missed',
    ],
  }, scopeSessionId: scope.sessionId, scopeNote: scope.note);
}

String _cap(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…(+${s.length - max} chars)';
