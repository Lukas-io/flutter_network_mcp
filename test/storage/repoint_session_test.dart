import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

/// Issue #16: a hot-restart reattach repoints the SAME session row at the new
/// VM URI so captures from before and after the restart share one session id.
void main() {
  group('repointSession', () {
    late Directory dir;
    late CapturesDao dao;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('repoint_session_test_');
      CapturesDatabase.open(dataDir: dir.path);
      dao = CapturesDao();
    });

    tearDown(() {
      CapturesDatabase.instance.close();
      dir.deleteSync(recursive: true);
    });

    test('updates vm_service_uri + isolate_id while keeping the id', () {
      final sid = dao.createSession(
        appName: 'roqquapp',
        vmServiceUri: 'ws://old/ws',
        isolateId: 'isolates/1',
        projectPath: '/p',
      );
      // A capture from BEFORE the restart.
      CapturesDatabase.instance.raw.execute(
        'INSERT INTO http_requests(session_id, vm_id, start_us) VALUES (?,?,?)',
        [sid, 'req-before', 100],
      );

      dao.repointSession(sid,
          vmServiceUri: 'ws://new/ws', isolateId: 'isolates/2');

      final row = CapturesDatabase.instance.raw.select(
        'SELECT vm_service_uri, isolate_id FROM sessions WHERE id=?',
        [sid],
      );
      expect(row.single['vm_service_uri'], 'ws://new/ws');
      expect(row.single['isolate_id'], 'isolates/2');

      // A capture from AFTER the restart lands under the same session id.
      CapturesDatabase.instance.raw.execute(
        'INSERT INTO http_requests(session_id, vm_id, start_us) VALUES (?,?,?)',
        [sid, 'req-after', 200],
      );
      final count = CapturesDatabase.instance.raw.select(
        'SELECT COUNT(*) AS c FROM http_requests WHERE session_id=?',
        [sid],
      );
      expect(count.single['c'], 2,
          reason: 'before + after restart share one session id');
    });
  });
}
