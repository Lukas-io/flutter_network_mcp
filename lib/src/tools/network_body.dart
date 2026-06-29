import 'dart:async';
import 'dart:typed_data';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/body_decoder.dart';
import '../util/body_status.dart';
import '../util/scope.dart';
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
        return errorResult('Request `$id` not found in session $sid.',
            kind: ErrorKind.notFound,
            extra: {
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
      final isolateFilter = args['isolateId'] as String?;
      String? resolvedIsolateId = isolateFilter;
      if (resolvedIsolateId == null) {
        final dbRow = CapturesDao().getHttpRequest(scope.sessionId, id);
        resolvedIsolateId = dbRow?['isolate_id'] as String?;
      }
      final candidateIsolates = resolvedIsolateId != null
          ? [resolvedIsolateId]
          : [for (final iso in attached.vm.httpProfilingIsolates) iso.id];
      if (candidateIsolates.isEmpty) {
        return errorResult(
          'No HTTP-profiling isolates known for this session.',
          kind: ErrorKind.unresponsiveVm,
          extra: const {
            'nextSteps': [
              'network_status — verify the session\'s isolates list',
              'network_attach — re-attach to refresh isolate discovery',
            ],
          },
        );
      }
      Object? lastError;
      bool fetched = false;
      for (final isoId in candidateIsolates) {
        try {
          final r = await attached.vm.getHttpProfileRequestForIsolate(isoId, id);
          if (which == 'request') {
            bytes = r.requestBody;
            mimeType = firstHeader(r.request?.headers, 'content-type');
          } else {
            bytes = r.responseBody;
            mimeType = firstHeader(r.response?.headers, 'content-type');
          }
          fetched = true;
          break;
        } catch (e) {
          lastError = e;
        }
      }
      if (!fetched) {
        final dbBytes = CapturesDao().getBody(scope.sessionId, id, which);
        if (dbBytes != null && dbBytes.isNotEmpty) {
          bytes = dbBytes;
          final dbRow = CapturesDao().getHttpRequest(scope.sessionId, id);
          mimeType = dbRow?['content_type'] as String?;
          source = 'live-db-fallback';
        } else {
          return errorResult(
            'body fetch failed: ${lastError ?? "no isolate had id $id"}',
            kind: ErrorKind.unresponsiveVm,
            extra: {
              'id': id,
              'triedIsolates': candidateIsolates,
              'nextSteps': const [
                'network_query sql:"SELECT which,size FROM http_bodies WHERE vm_id=\'<id>\'" — check whether the body is persisted',
                'network_get id:<id> — confirm the request still exists',
                'network_status — check whether the VM service is responsive (the app may be paused at a breakpoint)',
              ],
            },
          );
        }
      }
    }

    if (bytes == null || bytes.isEmpty) {
      final statusRow = CapturesDao().getHttpRequest(scope.sessionId, id);
      final status = statusRow == null
          ? <String, Object?>{
              'bodyStatus': 'unavailable',
              'reason': 'request-not-in-db',
            }
          : bodyStatusFor(row: statusRow, which: which, hasBytes: false);
      final bodyStatus = status['bodyStatus'];
      final warnings = <String>[];
      if (bodyStatus == 'pending') {
        warnings.add(
          '$which body not captured yet — the writer backfills async. Retry '
          'in ~2s, or fetch in live mode.',
        );
      } else if (bodyStatus == 'unavailable') {
        warnings.add(
          'The $which body was lost before capture (the VM evicted it before '
          'the async backfill); this is NOT "the server sent nothing".',
        );
      }
      return jsonResult({
        'source': source,
        'scope': scope.toBlock(),
        'sessionId': sessionIdForResp,
        'summary': 'No $which body bytes for $id (bodyStatus: $bodyStatus).',
        'id': id,
        'which': which,
        if (mimeType != null) 'mimeType': mimeType,
        'totalSize': 0,
        ...status,
        if (warnings.isNotEmpty) 'warnings': warnings,
        'nextSteps': const [
          'network_get id:<id> — confirm the request exists and check headers',
        ],
      }, scopeSessionId: scope.sessionId);
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
    }, scopeSessionId: scope.sessionId);
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
