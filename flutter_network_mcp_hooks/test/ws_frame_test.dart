import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_network_mcp_hooks/src/ws_frame.dart';
import 'package:test/test.dart';

/// Encodes a frame the way a real peer would: servers send UNMASKED frames,
/// clients send MASKED frames (RFC 6455 5.3). Used to exercise the decoder.
Uint8List encode(
  int opcode,
  List<int> payload, {
  bool fin = true,
  bool masked = false,
  List<int> mask = const [0x12, 0x34, 0x56, 0x78],
}) {
  final out = <int>[];
  out.add((fin ? 0x80 : 0) | (opcode & 0x0F));
  final len = payload.length;
  final maskBit = masked ? 0x80 : 0;
  if (len < 126) {
    out.add(maskBit | len);
  } else if (len < 65536) {
    out
      ..add(maskBit | 126)
      ..add((len >> 8) & 0xFF)
      ..add(len & 0xFF);
  } else {
    out.add(maskBit | 127);
    for (var k = 7; k >= 0; k--) {
      out.add((len >> (8 * k)) & 0xFF);
    }
  }
  if (masked) {
    out.addAll(mask);
    for (var k = 0; k < len; k++) {
      out.add(payload[k] ^ mask[k & 3]);
    }
  } else {
    out.addAll(payload);
  }
  return Uint8List.fromList(out);
}

void main() {
  test('decodes a single unmasked text frame (server -> client)', () {
    final d = WsFrameDecoder();
    final frames = d.addBytes(encode(WsOpcode.text, utf8.encode('hello')));
    expect(frames, hasLength(1));
    expect(frames.single.opcode, WsOpcode.text);
    expect(frames.single.fin, isTrue);
    expect(frames.single.textPayload(), 'hello');
    expect(frames.single.isData, isTrue);
  });

  test('decodes a masked text frame (client -> server) and unmasks payload',
      () {
    final d = WsFrameDecoder();
    final frames =
        d.addBytes(encode(WsOpcode.text, utf8.encode('42["auth"]'), masked: true));
    expect(frames.single.textPayload(), '42["auth"]');
  });

  test('decodes a binary frame', () {
    final d = WsFrameDecoder();
    final frames = d.addBytes(encode(WsOpcode.binary, [1, 2, 3, 250]));
    expect(frames.single.isBinary, isTrue);
    expect(frames.single.payload, [1, 2, 3, 250]);
  });

  test('reassembles a frame split across two addBytes calls', () {
    final d = WsFrameDecoder();
    final full = encode(WsOpcode.text, utf8.encode('split-me'));
    final cut = full.length - 3;
    expect(d.addBytes(full.sublist(0, cut)), isEmpty);
    final frames = d.addBytes(full.sublist(cut));
    expect(frames.single.textPayload(), 'split-me');
    expect(d.bufferedBytes, 0);
  });

  test('decodes multiple frames packed in one buffer', () {
    final d = WsFrameDecoder();
    final buf = <int>[
      ...encode(WsOpcode.text, utf8.encode('a')),
      ...encode(WsOpcode.text, utf8.encode('bb')),
      ...encode(WsOpcode.ping, const []),
    ];
    final frames = d.addBytes(buf);
    expect(frames.map((f) => f.opcode),
        [WsOpcode.text, WsOpcode.text, WsOpcode.ping]);
    expect(frames[1].textPayload(), 'bb');
  });

  test('handles 16-bit extended length (>= 126 bytes)', () {
    final d = WsFrameDecoder();
    final payload = List<int>.filled(300, 65);
    final frames = d.addBytes(encode(WsOpcode.binary, payload));
    expect(frames.single.payload.length, 300);
    expect(d.bufferedBytes, 0);
  });

  test('a control frame is flagged isControl, not isData', () {
    final d = WsFrameDecoder();
    final frames = d.addBytes(encode(WsOpcode.close, const []));
    expect(frames.single.isControl, isTrue);
    expect(frames.single.isData, isFalse);
  });

  test('fin=false marks a fragment', () {
    final d = WsFrameDecoder();
    final frames =
        d.addBytes(encode(WsOpcode.text, utf8.encode('frag'), fin: false));
    expect(frames.single.fin, isFalse);
  });

  test('byte-at-a-time feeding still reassembles', () {
    final d = WsFrameDecoder();
    final full = encode(WsOpcode.text, utf8.encode('drip'), masked: true);
    final got = <WsFrame>[];
    for (final byte in full) {
      got.addAll(d.addBytes([byte]));
    }
    expect(got.single.textPayload(), 'drip');
  });
}
