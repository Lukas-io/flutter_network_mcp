import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/state/log_buffer.dart';
import 'package:flutter_network_mcp/src/state/session.dart';
import 'package:flutter_network_mcp/src/storage/capture_writer.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/network_clear.dart';
import 'package:flutter_network_mcp/src/tools/socket_clear.dart';
import 'package:flutter_network_mcp/src/vm/log_stream.dart';
import 'package:flutter_network_mcp/src/vm/vm_client.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('clear_failure_test_');
    CapturesDatabase.open(dataDir: dir.path);
    sid = CapturesDao().createSession(
        appName: 'a', vmServiceUri: 'ws://gone', isolateId: null,
        projectPath: null);
    SessionRegistry.instance.register(AttachedSession(
      id: sid,
      appName: 'a',
      vmServiceUri: 'ws://gone',
      vm: VmClient(),
      captureWriter: CaptureWriter(),
      logBuffer: LogBuffer(),
      logStream: LogStreamSubscriber(),
      attachedAt: DateTime.now(),
      httpProfilingEnabled: true,
      socketProfilingEnabled: true,
    ));
  });

  tearDown(() async {
    await SessionRegistry.instance.detachAll();
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  for (final (name, call) in [
    ('network_clear', networkClear),
    ('socket_clear', socketClear),
  ]) {
    test('$name fails when no isolate was cleared', () async {
      final r = await call(CallToolRequest(
          name: name,
          arguments: {'sessionId': sid, 'isolateId': 'isolates/1'}));
      final sc = r.structuredContent!;
      expect(r.isError, isTrue);
      expect(sc['cleared'], isFalse);
      expect(sc['errorKind'], 'unresponsive_vm');
      expect((sc['failed'] as List).single, containsPair('isolateId', 'isolates/1'));
    });
  }
}
