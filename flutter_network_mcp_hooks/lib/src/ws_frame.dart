import 'dart:convert';
import 'dart:typed_data';

/// WebSocket frame opcodes (RFC 6455 section 5.2).
class WsOpcode {
  static const int continuation = 0x0;
  static const int text = 0x1;
  static const int binary = 0x2;
  static const int close = 0x8;
  static const int ping = 0x9;
  static const int pong = 0xA;

  static String name(int op) {
    switch (op) {
      case continuation:
        return 'continuation';
      case text:
        return 'text';
      case binary:
        return 'binary';
      case close:
        return 'close';
      case ping:
        return 'ping';
      case pong:
        return 'pong';
      default:
        return 'reserved-0x${op.toRadixString(16)}';
    }
  }
}

/// One decoded WebSocket frame: header flags + the UNMASKED payload bytes.
class WsFrame {
  WsFrame({required this.fin, required this.opcode, required this.payload});

  final bool fin;
  final int opcode;
  final Uint8List payload;

  bool get isText => opcode == WsOpcode.text;
  bool get isBinary => opcode == WsOpcode.binary;

  /// Control frames (close/ping/pong) have the high opcode bit set.
  bool get isControl => (opcode & 0x8) != 0;

  /// Data frames carry application payload (text/binary/continuation).
  bool get isData => !isControl;

  /// Lossy UTF-8 view of the payload, for text frames + logging.
  String textPayload() => utf8.decode(payload, allowMalformed: true);
}

/// Streaming RFC 6455 frame decoder for ONE direction of an already-upgraded
/// WebSocket connection. Feed it raw bytes as they arrive ([addBytes]); it
/// buffers partial frames across calls and returns complete frames as they
/// fully parse.
///
/// Handles FIN, opcodes, client masking (frames the client sends are masked;
/// server frames are not, per RFC 6455 5.3), and 7 / 16 / 64-bit payload
/// lengths. The mask bit is read per-frame, so the same decoder works for
/// either direction. Continuation frames (opcode 0x0) are returned as-is; the
/// capture layer stores each frame as a row and need not reassemble messages.
class WsFrameDecoder {
  Uint8List _buffer = Uint8List(0);

  /// Bytes buffered but not yet part of a complete frame. Useful for tests +
  /// bounding memory if a peer sends a giant partial frame.
  int get bufferedBytes => _buffer.length;

  List<WsFrame> addBytes(List<int> bytes) {
    if (bytes.isEmpty) return const [];
    final combined = Uint8List(_buffer.length + bytes.length)
      ..setRange(0, _buffer.length, _buffer)
      ..setRange(_buffer.length, _buffer.length + bytes.length, bytes);
    _buffer = combined;

    final out = <WsFrame>[];
    var offset = 0;
    while (true) {
      final parsed = _parseFrame(_buffer, offset);
      if (parsed == null) break;
      out.add(parsed.frame);
      offset = parsed.next;
    }
    if (offset > 0) {
      _buffer = offset >= _buffer.length
          ? Uint8List(0)
          : Uint8List.fromList(Uint8List.sublistView(_buffer, offset));
    }
    return out;
  }

  /// Parses one frame starting at [start]. Returns null when there are not
  /// yet enough bytes for a complete frame (header or payload incomplete).
  _Parsed? _parseFrame(Uint8List b, int start) {
    var i = start;
    if (b.length - i < 2) return null;
    final b0 = b[i];
    final b1 = b[i + 1];
    final fin = (b0 & 0x80) != 0;
    final opcode = b0 & 0x0F;
    final masked = (b1 & 0x80) != 0;
    var len = b1 & 0x7F;
    i += 2;

    if (len == 126) {
      if (b.length - i < 2) return null;
      len = (b[i] << 8) | b[i + 1];
      i += 2;
    } else if (len == 127) {
      if (b.length - i < 8) return null;
      len = 0;
      for (var k = 0; k < 8; k++) {
        len = (len << 8) | b[i + k];
      }
      i += 8;
    }

    Uint8List? mask;
    if (masked) {
      if (b.length - i < 4) return null;
      mask = Uint8List.sublistView(b, i, i + 4);
      i += 4;
    }

    if (b.length - i < len) return null; // payload not fully arrived yet

    final payload = Uint8List(len);
    if (masked) {
      for (var k = 0; k < len; k++) {
        payload[k] = b[i + k] ^ mask![k & 3];
      }
    } else {
      payload.setRange(0, len, b, i);
    }
    i += len;

    return _Parsed(
      WsFrame(fin: fin, opcode: opcode, payload: payload),
      i,
    );
  }
}

class _Parsed {
  _Parsed(this.frame, this.next);
  final WsFrame frame;
  final int next;
}
