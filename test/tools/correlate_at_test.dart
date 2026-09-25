import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/correlate_at.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('correlate_at_test_');
    CapturesDatabase.open(dataDir: dir.path);
    sid = CapturesDao().createSession(
        appName: 'app', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
  });

  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  void log(String message, {String? error, String? stackTrace}) {
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO log_records(session_id, timestamp_ms, source, message, error, stack_trace) '
      'VALUES (?,?,?,?,?,?)',
      [sid, 5000, 'logging', message, error, stackTrace],
    );
  }

  Future<Map<String, Object?>> firstLog() async {
    final res = await correlateAt(CallToolRequest(
      name: 'correlate_at',
      arguments: {'tsMs': 5000, 'sessionId': sid},
    ));
    return (res.structuredContent!['logs'] as List).cast<Map<String, Object?>>().first;
  }

  test('a cut never splits an emoji and reports the full length', () async {
    final message = '${'a' * 511}😀 and more';
    log(message);
    final entry = await firstLog();
    expect(entry['message'], 'a' * 511);
    expect(entry['truncated'], isTrue);
    expect(entry['totalLength'], message.length);
  });

  test('error and stackTrace are returned, bounded', () async {
    log('failed', error: 'StateError: boom', stackTrace: '#0 main\n' * 1000);
    final entry = await firstLog();
    expect(entry['error'], 'StateError: boom');
    expect(entry.containsKey('errorTotalLength'), isFalse);
    expect((entry['stackTrace'] as String).length, 2048);
    expect(entry['stackTraceTotalLength'], 8000);
  });
}
