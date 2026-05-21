import 'dart:async';
import 'dart:typed_data';

import 'package:dart_mcp/server.dart';

import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/body_decoder.dart';
import 'result.dart';

const int _kMaxBodyChunk = 262144;

final networkBodyTool = Tool(
  name: 'network_body',
  description:
      'Returns a byte range of a single HTTP request body. Works in live or '
      'history mode (history requires the body to have been persisted by the '
      'capture writer; check session_list counts before relying on this).',
  inputSchema: Schema.object(
    properties: {
      'id': Schema.string(description: 'Request id from network_list.'),
      'which': Schema.string(description: '"request" or "response".'),
      'offset': Schema.int(description: 'Byte offset (default 0).'),
      'length': Schema.int(description: 'Bytes to read (default 16384, hard cap 262144).'),
      'decode': Schema.string(description: '"auto" | "utf8" | "base64".'),
    },
    required: ['id', 'which'],
  ),
);

FutureOr<CallToolResult> networkBody(CallToolRequest request) async {
  final session = Session.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final id = args['id'] as String?;
  final whichArg = args['which'] as String?;
  if (id == null || id.isEmpty) return errorResult('Missing required arg `id`.');
  if (whichArg != 'request' && whichArg != 'response') {
    return errorResult('`which` must be "request" or "response".');
  }
  final which = whichArg!;
  final offset = (args['offset'] as int?) ?? 0;
  final lengthArg = (args['length'] as int?) ?? 16384;
  final length = lengthArg <= 0
      ? 16384
      : (lengthArg > _kMaxBodyChunk ? _kMaxBodyChunk : lengthArg);
  final decode = (args['decode'] as String?) ?? 'auto';
  if (decode != 'auto' && decode != 'utf8' && decode != 'base64') {
    return errorResult('`decode` must be one of: auto, utf8, base64.');
  }

  Uint8List? bytes;
  String? mimeType;
  String source;
  int? sessionIdForResp;

  try {
    if (session.isViewingHistory) {
      final sid = session.viewedSessionId!;
      source = 'history';
      sessionIdForResp = sid;
      final dao = CapturesDao();
      bytes = dao.getBody(sid, id, which);
      final row = dao.getHttpRequest(sid, id);
      if (row != null) mimeType = row['content_type'] as String?;
    } else {
      if (!session.isAttached) {
        return errorResult('Not attached. Call network_attach first.');
      }
      source = 'live';
      sessionIdForResp = session.liveSessionId;
      final r = await session.vm.getHttpProfileRequest(id);
      if (which == 'request') {
        bytes = r.requestBody;
        mimeType = firstHeader(r.request?.headers, 'content-type');
      } else {
        bytes = r.responseBody;
        mimeType = firstHeader(r.response?.headers, 'content-type');
      }
    }

    if (bytes == null || bytes.isEmpty) {
      return jsonResult({
        'source': source,
        'sessionId': sessionIdForResp,
        'id': id,
        'which': which,
        'mimeType': mimeType,
        'totalSize': 0,
        'body': null,
      });
    }

    final total = bytes.length;
    final start = offset < 0 ? 0 : (offset > total ? total : offset);
    final end = (start + length) > total ? total : (start + length);
    final slice = Uint8List.sublistView(bytes, start, end);

    final decoded = decodeBody(slice, mimeType, decode: decode, maxBytes: -1);

    return jsonResult({
      'source': source,
      'sessionId': sessionIdForResp,
      'id': id,
      'which': which,
      'mimeType': mimeType,
      'totalSize': total,
      'offset': start,
      'returnedSize': end - start,
      'nextOffset': end < total ? end : null,
      if (decoded != null) ...{
        'encoding': decoded.encoding,
        'value': decoded.value,
      },
    });
  } catch (e) {
    return errorResult('body fetch failed: $e');
  }
}
