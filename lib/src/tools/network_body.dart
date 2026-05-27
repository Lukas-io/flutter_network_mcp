import 'dart:async';
import 'dart:typed_data';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/body_decoder.dart';
import '../util/scope.dart';
import 'result.dart';

const int _kMaxBodyChunk = 262144;
const int _kDefaultLen = 16384;

final networkBodyTool = Tool(
  name: 'network_body',
  description:
      'Fetch the rest of a body that network_get truncated. Call this '
      'whenever a network_get response carries `truncated:true` plus a '
      '`totalSize` larger than what was returned — that\'s the signal you '
      'are missing data. Byte-range paged via `offset` + `length`; returns '
      '`nextOffset` so you can iterate. Auto-decodes utf8 for text content '
      'types, base64 for binary. Works against both live and history '
      'sessions (history needs the writer\'s ~2s body backfill to have run).',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.string(description: 'Request id from network_list / network_search.'),
      'which': Schema.string(description: '"request" or "response".'),
      'sessionId': Schema.int(
        description:
            'Which session the request belongs to. Omit to auto-resolve: '
            'explicit view (session_open) → sole attached session → error '
            'if 2+ attached.',
      ),
      'appNameContains': Schema.string(
        description:
            'Alternative to sessionId — case-insensitive substring on a '
            'currently-attached app name.',
      ),
      'offset': Schema.int(
        description:
            'Byte offset to start at. Default 0. Clamped to [0, totalSize].',
      ),
      'length': Schema.int(
        description:
            'Bytes to read (default 16384, hard cap 262144). Returned size '
            'may be smaller when offset+length > totalSize.',
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
    return errorResult('Missing required arg `id`.', extra: const {
      'nextSteps': [
        'network_list — list captured requests and pick an id',
        'network_search query:"..." — find a request by content',
      ],
    });
  }
  if (whichArg != 'request' && whichArg != 'response') {
    return errorResult(
      '`which` must be "request" or "response".',
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
    return errorResult('`decode` must be one of: auto, utf8, base64.', extra: const {
      'nextSteps': ['Retry with decode:"auto" (recommended)'],
    });
  }

  Uint8List? bytes;
  String? mimeType;
  String source;
  final int sessionIdForResp = scope.sessionId;

  try {
    if (!scope.isLive) {
      final sid = scope.sessionId;
      source = 'history';
      final dao = CapturesDao();
      bytes = dao.getBody(sid, id, which);
      final row = dao.getHttpRequest(sid, id);
      if (row != null) mimeType = row['content_type'] as String?;
      if (row == null) {
        return errorResult('Request `$id` not found in session $sid.', extra: {
          'sessionId': sid,
          'nextSteps': const [
            'network_list — list valid request ids in this session',
            'session_list — confirm the session id is correct',
          ],
        });
      }
    } else {
      source = 'live';
      final attached = SessionRegistry.instance.attachedById(scope.sessionId)!;
      final r = await attached.vm.getHttpProfileRequest(id);
      if (which == 'request') {
        bytes = r.requestBody;
        mimeType = firstHeader(r.request?.headers, 'content-type');
      } else {
        bytes = r.responseBody;
        mimeType = firstHeader(r.response?.headers, 'content-type');
      }
    }

    if (bytes == null || bytes.isEmpty) {
      final warnings = <String>[];
      if (source == 'history') {
        warnings.add(
          '$which body not persisted yet — the writer may still be backfilling. Retry in 2s, or fetch in live mode.',
        );
      }
      return jsonResult({
        'source': source,
        'scope': scope.toBlock(),
        'sessionId': sessionIdForResp,
        'summary': 'No $which body for $id.',
        'id': id,
        'which': which,
        if (mimeType != null) 'mimeType': mimeType,
        'totalSize': 0,
        if (warnings.isNotEmpty) 'warnings': warnings,
        'nextSteps': const [
          'network_get id:<id> — confirm the request exists and check headers',
        ],
      });
    }

    final total = bytes.length;
    final start = offset < 0 ? 0 : (offset > total ? total : offset);
    final end = (start + length) > total ? total : (start + length);
    final slice = Uint8List.sublistView(bytes, start, end);
    final decoded = decodeBody(slice, mimeType, decode: decode, maxBytes: -1);
    final returnedSize = end - start;
    final nextOffset = end < total ? end : null;

    final summary = nextOffset == null
        ? 'Returned $returnedSize-byte $which body for $id (full, ${decoded?.encoding ?? "n/a"}${mimeType != null ? ", $mimeType" : ""}).'
        : 'Returned bytes $start–$end of $total for $which body of $id (${decoded?.encoding ?? "n/a"}); call again with offset:$nextOffset for more.';

    final warnings = <String>[];
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
    });
  } catch (e) {
    return errorResult('body fetch failed: $e', extra: {
      'id': id,
      'which': which,
      'nextSteps': const [
        'network_get id:<id> — confirm the request still exists',
        'network_status — check zombie-DTD state if reading live',
      ],
    });
  }
}
