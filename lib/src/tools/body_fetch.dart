import 'dart:typed_data';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/body_decoder.dart';
import '../util/body_status.dart';
import '../util/scope.dart';
import 'error_kind.dart';
import 'result.dart';

/// Result of resolving a single body's bytes. Exactly one of [error] (a
/// ready-to-return tool result) or a successful ([bytes], [mimeType], [source])
/// triple is meaningful: when [error] != null the caller should return it
/// verbatim; otherwise [bytes] may still be null/empty (a genuinely no-body
/// response), which the caller renders via [noBodyResult].
typedef BodyFetch = ({
  Uint8List? bytes,
  String? mimeType,
  String source,
  CallToolResult? error,
});

/// Resolves the raw bytes of one captured body, shared by `network_body` and
/// `network_body_outline` so both flows fetch identically (live VM with a
/// persisted-DB fallback, or history). Mirrors the order the writer uses:
/// in a live session try every HTTP-profiling isolate, then fall back to the
/// stored blob; in history read straight from the DB.
Future<BodyFetch> fetchBodyBytes(
  Scope scope,
  String id,
  String which, {
  String? isolateId,
}) async {
  Uint8List? bytes;
  String? mimeType;
  String source;

  if (!scope.isLive) {
    final sid = scope.sessionId;
    source = 'history';
    final dao = CapturesDao();
    bytes = dao.getBody(sid, id, which);
    final row = dao.getHttpRequest(sid, id);
    if (row == null) {
      return (
        bytes: null,
        mimeType: null,
        source: source,
        error: errorResult('Request `$id` not found in session $sid.',
            kind: ErrorKind.notFound,
            extra: {
              'sessionId': sid,
              'nextSteps': const [
                'network_list — list valid request ids in this session',
                'session_list — confirm the session id is correct',
              ],
            }),
      );
    }
    mimeType = row['content_type'] as String?;
    return (bytes: bytes, mimeType: mimeType, source: source, error: null);
  }

  source = 'live';
  final attached = SessionRegistry.instance.attachedById(scope.sessionId)!;
  String? resolvedIsolateId = isolateId;
  if (resolvedIsolateId == null) {
    final dbRow = CapturesDao().getHttpRequest(scope.sessionId, id);
    resolvedIsolateId = dbRow?['isolate_id'] as String?;
  }
  final candidateIsolates = resolvedIsolateId != null
      ? [resolvedIsolateId]
      : [for (final iso in attached.vm.httpProfilingIsolates) iso.id];
  if (candidateIsolates.isEmpty) {
    return (
      bytes: null,
      mimeType: null,
      source: source,
      error: errorResult(
        'No HTTP-profiling isolates known for this session.',
        kind: ErrorKind.unresponsiveVm,
        extra: const {
          'nextSteps': [
            'network_status — verify the session\'s isolates list',
            'network_attach — re-attach to refresh isolate discovery',
          ],
        },
      ),
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
      final dbRow = CapturesDao().getHttpRequest(scope.sessionId, id);
      return (
        bytes: dbBytes,
        mimeType: dbRow?['content_type'] as String?,
        source: 'live-db-fallback',
        error: null,
      );
    }
    return (
      bytes: null,
      mimeType: null,
      source: source,
      error: errorResult(
        looksLikeVmIdMiss(lastError)
            ? 'No request with id "$id" is known to the live VM or the '
                'persisted DB — the id is stale or mistyped.'
            : 'body fetch failed: ${lastError ?? "no isolate had id $id"}',
        // D3: a clean "no such id" answer from a healthy VM is not_found,
        // not unresponsive_vm.
        kind: looksLikeVmIdMiss(lastError)
            ? ErrorKind.notFound
            : ErrorKind.unresponsiveVm,
        extra: {
          'id': id,
          'triedIsolates': candidateIsolates,
          'nextSteps': looksLikeVmIdMiss(lastError)
              ? const [
                  'network_list — copy a valid request id',
                  'network_search query:"..." — find the request by content',
                ]
              : const [
                  'network_query sql:"SELECT which,size FROM http_bodies WHERE vm_id=\'<id>\'" — check whether the body is persisted',
                  'network_get id:<id> — confirm the request still exists',
                  'network_status — check whether the VM service is responsive (the app may be paused at a breakpoint)',
                ],
        },
      ),
    );
  }
  return (bytes: bytes, mimeType: mimeType, source: source, error: null);
}

/// Renders the "no bytes for this body" result, shared so `network_body` and
/// `network_body_outline` agree on the bodyStatus (#59) explanation: a body
/// that is `pending` (retry), `unavailable` (lost upstream), or `empty` (the
/// server genuinely sent nothing).
CallToolResult noBodyResult(
  Scope scope,
  String id,
  String which,
  String source,
  String? mimeType,
) {
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
    'sessionId': scope.sessionId,
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
  }, scopeSessionId: scope.sessionId, scopeNote: scope.note);
}
