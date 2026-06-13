import 'dart:convert';
import 'dart:typed_data';

import 'ws_frame.dart';

/// One captured WebSocket frame, already truncated for transport.
class CapturedWsFrame {
  CapturedWsFrame({
    required this.connectionId,
    required this.tsMs,
    required this.outbound,
    required this.opcode,
    required this.payloadLength,
    required this.preview,
    required this.isText,
    required this.wasCompressed,
  });

  final int connectionId;
  final int tsMs;
  final bool outbound; // true = app -> server
  final int opcode;
  final int payloadLength;
  final String preview;
  final bool isText;
  final bool wasCompressed;

  Map<String, Object?> toJson() => {
        'connectionId': connectionId,
        'tsMs': tsMs,
        'dir': outbound ? 'out' : 'in',
        'opcode': WsOpcode.name(opcode),
        'len': payloadLength,
        'isText': isText,
        if (wasCompressed) 'compressed': true,
        'preview': preview,
      };
}

/// One captured WebSocket connection (the upgraded socket).
class CapturedWsConnection {
  CapturedWsConnection({
    required this.id,
    required this.host,
    required this.port,
    required this.startedMs,
    this.path,
  });

  final int id;
  final String host;
  final int port;
  final int startedMs;
  final String? path;

  Map<String, Object?> toJson() => {
        'id': id,
        'host': host,
        'port': port,
        if (path != null) 'path': path,
        'startedMs': startedMs,
      };
}

/// Process-wide ring buffer of captured WebSocket connections + frames. The
/// hooks write here; the VM service extension drains it for the MCP. Bounded
/// so a chatty socket can't grow memory without limit.
class RealtimeCapture {
  RealtimeCapture._();
  static final RealtimeCapture instance = RealtimeCapture._();

  static const int _previewChars = 2048;
  static const int _hexPreviewBytes = 64;

  final List<CapturedWsConnection> _connections = [];
  final List<CapturedWsFrame> _frames = [];
  int _nextId = 1;

  /// Cap on retained frames (oldest dropped first).
  int maxFrames = 2000;

  /// Cap on retained connection records.
  int maxConnections = 256;

  bool installed = false;

  int openConnection(String host, int port, String? path) {
    final id = _nextId++;
    _connections.add(CapturedWsConnection(
      id: id,
      host: host,
      port: port,
      path: path,
      startedMs: _nowMs(),
    ));
    while (_connections.length > maxConnections) {
      _connections.removeAt(0);
    }
    return id;
  }

  /// Records one fully-reassembled, decompressed WebSocket MESSAGE (the hooks
  /// handle fragmentation + permessage-deflate before calling this).
  void recordMessage({
    required int connectionId,
    required bool outbound,
    required int opcode,
    required Uint8List payload,
    required bool wasCompressed,
  }) {
    final isText = opcode == WsOpcode.text;
    final preview = isText ? _truncateText(_utf8(payload)) : _hexPreview(payload);
    _frames.add(CapturedWsFrame(
      connectionId: connectionId,
      tsMs: _nowMs(),
      outbound: outbound,
      opcode: opcode,
      payloadLength: payload.length,
      preview: preview,
      isText: isText,
      wasCompressed: wasCompressed,
    ));
    while (_frames.length > maxFrames) {
      _frames.removeAt(0);
    }
  }

  /// Returns connections + frames captured since the last drain, then clears
  /// the frame buffer (connection records are kept so later drains still name
  /// the connection a frame belongs to).
  Map<String, Object?> drain() {
    final out = <String, Object?>{
      'connections': [for (final c in _connections) c.toJson()],
      'frames': [for (final f in _frames) f.toJson()],
    };
    _frames.clear();
    return out;
  }

  void clear() {
    _frames.clear();
    _connections.clear();
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  String _utf8(Uint8List b) => utf8.decode(b, allowMalformed: true);

  String _truncateText(String s) =>
      s.length <= _previewChars ? s : '${s.substring(0, _previewChars)}…(${s.length} chars)';

  String _hexPreview(Uint8List b) {
    final n = b.length < _hexPreviewBytes ? b.length : _hexPreviewBytes;
    final sb = StringBuffer();
    for (var i = 0; i < n; i++) {
      sb.write(b[i].toRadixString(16).padLeft(2, '0'));
    }
    return b.length <= _hexPreviewBytes ? sb.toString() : '$sb…(${b.length} bytes)';
  }
}
