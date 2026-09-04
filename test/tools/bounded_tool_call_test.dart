import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/server.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/logs_tail.dart';
import 'package:test/test.dart';

void main() {
  test('a call past the deadline returns errorKind timeout, not a hang', () async {
    final r = await boundedToolCall(
      'logs_tail',
      () => Future.delayed(const Duration(seconds: 2),
          () => CallToolResult(content: const [], structuredContent: const {})),
      deadline: const Duration(milliseconds: 50),
    );
    expect(r.isError, isTrue);
    expect(r.structuredContent!['errorKind'], 'timeout');
  });

  test('unbounded tools are not cut off', () async {
    final r = await boundedToolCall(
      'db_vacuum',
      () => Future.delayed(const Duration(milliseconds: 80),
          () => CallToolResult(content: const [], structuredContent: const {'ok': true})),
      deadline: const Duration(milliseconds: 20),
    );
    expect(r.isError, isNot(isTrue));
  });

  test('the database opens with a busy timeout', () {
    final dir = Directory.systemTemp.createTempSync('fnm-busy-');
    CapturesDatabase.open(dataDir: dir.path);
    final v = CapturesDatabase.instance.raw.select('PRAGMA busy_timeout').first;
    expect(v.values.first, 5000);
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  test('truncateMessage flags a cut and keeps a short message whole', () {
    final t = truncateMessage('x' * 100, 40);
    expect(t.truncated, isTrue);
    expect(t.message.length, 40);
    expect(t.totalLength, 100);
    expect(truncateMessage('short', 40).truncated, isFalse);
  });
}
