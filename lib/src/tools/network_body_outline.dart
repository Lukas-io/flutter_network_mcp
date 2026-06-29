import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../util/json_shape.dart';
import '../util/scope.dart';
import 'body_fetch.dart';
import 'error_kind.dart';
import 'result.dart';

/// Bodies larger than this are not parsed into a skeleton (the byte-size
/// annotation re-encodes each branch, which is wasteful on a huge document).
/// They fall back to the content-type + total size + a short head.
const int _kMaxOutlineBytes = 8 * 1024 * 1024;
const int _kDefaultHeadBytes = 512;

final networkBodyOutlineTool = Tool(
  name: 'network_body_outline',
  description:
      'Structural skeleton of a (large) body: keys, value types, array '
      'lengths, and per-branch byte sizes, with NO values. Understand a '
      '1-2 MB JSON response and see WHERE the bytes are in a few hundred '
      'tokens, then network_body exactly the slice you need. Non-JSON falls '
      'back to content-type + total size + a short head.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.string(description: 'Request id from network_list / network_search.'),
      'which': Schema.string(
        description: '"response" (default) or "request".',
      ),
      'sessionId': Schema.int(
        description:
            'Session to read from. Omit to auto-resolve (the sole attached '
            'session, or the one you opened).',
      ),
      'appNameContains': Schema.string(
        description: 'Pick the session by app-name substring instead of sessionId.',
      ),
      'isolateId': Schema.string(
        description: 'Restrict to one isolate (id from network_status). Omit to auto-resolve.',
      ),
      'maxDepth': Schema.int(
        description: 'How deep to descend before collapsing a branch. Default 6.',
      ),
      'maxKeys': Schema.int(
        description: 'Max object keys to expand per node (rest reported as omittedKeys). Default 60.',
      ),
      'headBytes': Schema.int(
        description: 'For non-JSON bodies, how many leading bytes to preview. Default 512, cap 4096.',
      ),
    },
    required: ['id'],
  ),
);

FutureOr<CallToolResult> networkBodyOutline(CallToolRequest request) async {
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
  final maxDepth = (args['maxDepth'] as int?) ?? 6;
  final maxKeys = (args['maxKeys'] as int?) ?? 60;
  final headBytesArg = (args['headBytes'] as int?) ?? _kDefaultHeadBytes;
  final headBytes = headBytesArg <= 0
      ? _kDefaultHeadBytes
      : (headBytesArg > 4096 ? 4096 : headBytesArg);

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

    // Non-JSON or too-large: head preview, no skeleton.
    Object? decoded;
    String? parseError;
    if (total > _kMaxOutlineBytes) {
      parseError = 'body is ${total}B (> ${_kMaxOutlineBytes}B outline cap)';
    } else {
      try {
        decoded = json.decode(utf8.decode(bytes));
      } catch (e) {
        parseError = 'not valid JSON (${e.runtimeType})';
      }
    }

    if (parseError != null) {
      final head = utf8.decode(
        bytes.sublist(0, total < headBytes ? total : headBytes),
        allowMalformed: true,
      );
      return jsonResult({
        'source': source,
        'scope': scope.toBlock(),
        'sessionId': scope.sessionId,
        'summary':
            'No JSON outline for $which body of $id ($parseError) — showing a $headBytes-byte head.',
        'id': id,
        'which': which,
        'bodyStatus': 'stored',
        if (mimeType != null) 'mimeType': mimeType,
        'totalSize': total,
        'outlineAvailable': false,
        'reason': parseError,
        'head': head,
        'nextSteps': [
          'network_body id:"$id" which:$which — page the raw bytes',
        ],
      }, scopeSessionId: scope.sessionId);
    }

    final outline = jsonSkeleton(decoded, maxDepth: maxDepth, maxKeys: maxKeys);
    final shapeKind = outline is Map ? (outline['type'] ?? 'value') : 'value';

    return jsonResult({
      'source': source,
      'scope': scope.toBlock(),
      'sessionId': scope.sessionId,
      'summary':
          'Structural outline of $which body for $id ($total bytes, $shapeKind). '
          'No values; `bytes` per branch shows where to drill, then network_body the slice.',
      'id': id,
      'which': which,
      'bodyStatus': 'stored',
      if (mimeType != null) 'mimeType': mimeType,
      'totalSize': total,
      'outlineAvailable': true,
      'outline': outline,
      'nextSteps': [
        'network_body id:"$id" which:$which offset:0 length:16384 — fetch the actual bytes of a branch',
      ],
    }, scopeSessionId: scope.sessionId);
  } catch (e) {
    return errorResult('outline failed: $e',
        kind: ErrorKind.internal,
        extra: {
          'id': id,
          'which': which,
          'nextSteps': const [
            'network_get id:<id> — confirm the request still exists',
            'network_body id:<id> which:response — fetch raw bytes instead',
          ],
        });
  }
}
