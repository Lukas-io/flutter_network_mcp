import 'dart:async';
import 'dart:typed_data';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../util/body_decoder.dart';
import '../util/scope.dart';
import 'body_fetch.dart';
import 'error_kind.dart';
import 'result.dart';

const int _kMaxBodyChunk = 262144;
const int _kDefaultLen = 16384;

final networkBodyTool = Tool(
  name: 'network_body',
  description:
      'Fetch more of a body that network_get truncated (its response had '
      'truncated:true with a larger totalSize). Byte-range paged via '
      'offset+length; returns nextOffset to iterate. Auto-decodes text/binary.',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.string(description: 'Request id from network_list / network_search.'),
      'which': Schema.string(description: '"request" or "response".'),
      'sessionId': Schema.int(
        description:
            'Session to read from. Omit to auto-resolve (the sole attached '
            'session, or the one you opened).',
      ),
      'appNameContains': Schema.string(
        description: 'Pick the session by app-name substring instead of sessionId.',
      ),
      'isolateId': Schema.string(
        description:
            'Restrict to one isolate (id from network_status). Omit to '
            'auto-resolve.',
      ),
      'offset': Schema.int(
        description: 'Byte offset to start at. Default 0.',
      ),
      'length': Schema.int(
        description: 'Bytes to read (default 16384, cap 262144).',
      ),
      'decode': Schema.string(
        description:
            '"auto" (default — utf8 for text/json/xml content types, base64 '
            'for binary), "utf8" (force, accepts malformed), or "base64".',
      ),
    },
    required: ['id', 'which'],
  ),
);

FutureOr<CallToolResult> networkBody(CallToolRequest request) async {
  final caps = CapabilityConfig.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final id = args['id'] as String?;
  final whichArg = args['which'] as String?;
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
  if (whichArg != 'request' && whichArg != 'response') {
    return errorResult(
      '`which` must be "request" or "response".',
      kind: ErrorKind.badArgument,
      extra: const {
        'nextSteps': [
          'Retry with which:"response" (most common)',
          'Retry with which:"request" for the body you sent',
        ],
      },
    );
  }
  final which = whichArg!;
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;

  final offset = (args['offset'] as int?) ?? 0;
  final lengthArg = (args['length'] as int?) ?? _kDefaultLen;
  final length = lengthArg <= 0
      ? _kDefaultLen
      : (lengthArg > _kMaxBodyChunk ? _kMaxBodyChunk : lengthArg);
  final decode = (args['decode'] as String?) ?? 'auto';
  if (decode != 'auto' && decode != 'utf8' && decode != 'base64') {
    return errorResult('`decode` must be one of: auto, utf8, base64.',
        kind: ErrorKind.badArgument,
        extra: const {
          'nextSteps': ['Retry with decode:"auto" (recommended)'],
        });
  }

  final int sessionIdForResp = scope.sessionId;

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
    final start = offset < 0 ? 0 : (offset > total ? total : offset);
    final end = (start + length) > total ? total : (start + length);
    final slice = Uint8List.sublistView(bytes, start, end);
    final decoded = decodeBody(slice, mimeType, decode: decode, maxBytes: -1, semantic: false);
    final returnedSize = end - start;
    final nextOffset = end < total ? end : null;

    final summary = nextOffset == null
        ? 'Returned $returnedSize-byte $which body for $id (full, ${decoded?.encoding ?? "n/a"}${mimeType != null ? ", $mimeType" : ""}).'
        : 'Returned bytes $start–$end of $total for $which body of $id (${decoded?.encoding ?? "n/a"}); call again with offset:$nextOffset for more.';

    final warnings = <String>[];
    if (source == 'live-db-fallback') {
      warnings.add(
        'Live body fetch failed (VM unresponsive or request gone); returned '
        'the persisted DB copy instead.',
      );
    }
    if (decode == 'utf8' && decoded?.encoding == 'base64') {
      warnings.add('Requested utf8 decode but content appears non-text — returned base64 instead.');
    }
    if (offset > total) {
      warnings.add('Requested offset ($offset) exceeds totalSize ($total) — clamped to end.');
    }

    final nextSteps = <String>[];
    if (nextOffset != null) {
      nextSteps.add('network_body id:"$id" which:$which offset:$nextOffset length:$length — page next chunk');
    } else if (caps.isEnabled(Category.http)) {
      nextSteps.add('network_replay id:"$id" — emit curl reproduction');
      nextSteps.add('network_diff idA:"$id" idB:"<other id>" — compare with another request');
    }

    return jsonResult({
      'source': source,
      'scope': scope.toBlock(),
      'sessionId': sessionIdForResp,
      'summary': summary,
      'id': id,
      'which': which,
      'bodyStatus': 'stored',
      if (mimeType != null) 'mimeType': mimeType,
      'totalSize': total,
      'offset': start,
      'returnedSize': returnedSize,
      if (nextOffset != null) 'nextOffset': nextOffset,
      if (decoded != null) ...{
        'encoding': decoded.encoding,
        'value': decoded.value,
      },
      if (warnings.isNotEmpty) 'warnings': warnings,
      'nextSteps': nextSteps,
    }, scopeSessionId: scope.sessionId, scopeNote: scope.note);
  } catch (e) {
    return errorResult('body fetch failed: $e',
        kind: ErrorKind.internal,
        extra: {
          'id': id,
          'which': which,
          'nextSteps': const [
            'network_get id:<id> — confirm the request still exists',
            'network_status — check zombie-DTD state if reading live',
          ],
        });
  }
}
