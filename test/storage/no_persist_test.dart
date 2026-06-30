import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

/// #64 part 3: ephemeral / no-persist mode — the DB lives in memory only.
void main() {
  tearDown(() {
    if (CapturesDatabase.isOpen) CapturesDatabase.instance.close();
  });

  test('inMemory open is ephemeral with a :memory: path', () {
    CapturesDatabase.open(inMemory: true);
    expect(CapturesDatabase.instance.isEphemeral, isTrue);
    expect(CapturesDatabase.instance.path, ':memory:');
  });

  test('schema is fully usable in memory (create + insert + read back)', () {
    CapturesDatabase.open(inMemory: true);
    final dao = CapturesDao();
    final sid = dao.createSession(
        appName: 'eph', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
    CapturesDatabase.instance.raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, method, url, host, path) '
      'VALUES (?,?,?,?,?,?)',
      [sid, 'r1', 'GET', 'https://h/x', 'h', '/x'],
    );
    final row = dao.getHttpRequest(sid, 'r1');
    expect(row, isNotNull);
    expect(row!['method'], 'GET');
    expect(dao.dbSizeBytes(), greaterThan(0));
  });

  test('a normal file-backed open is NOT ephemeral', () {
    final dir =
        Directory.systemTemp.createTempSync('no_persist_test_').path;
    CapturesDatabase.open(dataDir: dir);
    expect(CapturesDatabase.instance.isEphemeral, isFalse);
    expect(CapturesDatabase.instance.path.endsWith('captures.db'), isTrue);
  });
}
