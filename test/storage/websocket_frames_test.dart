import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/storage/schema.dart';
import 'package:test/test.dart';

/// Schema v8 (0.9.0): WebSocket connection + frame persistence for the
/// flutter_network_mcp_hooks companion drain path.
void main() {
  group('websocket capture storage', () {
    late Directory dir;
    late CapturesDao dao;
    late int sid;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ws_frames_test_');
      CapturesDatabase.open(dataDir: dir.path);
      dao = CapturesDao();
      sid = dao.createSession(
        appName: 'app',
        vmServiceUri: 'ws://x',
        isolateId: null,
        projectPath: null,
      );
    });

    tearDown(() {
      CapturesDatabase.instance.close();
      dir.deleteSync(recursive: true);
    });

    test('fresh db is at currentVersion (>= 8)', () {
      final v = CapturesDatabase.instance.raw
          .select("SELECT value FROM _meta WHERE key='schema_version'")
          .first['value'];
      expect(int.parse(v as String), equals(currentVersion));
      expect(currentVersion, greaterThanOrEqualTo(8));
    });

    test('upsertWsConnection is idempotent on (session, conn)', () {
      dao.upsertWsConnection(sid,
          connId: 1, host: 'echo.example', port: 443, path: '/ws', startedMs: 100);
      dao.upsertWsConnection(sid,
          connId: 1, host: 'echo.example', port: 443, path: '/ws', startedMs: 100);
      final conns = dao.queryWsConnections(sessionId: sid);
      expect(conns, hasLength(1));
      expect(conns.single['host'], equals('echo.example'));
      expect(conns.single['path'], equals('/ws'));
    });

    test('connection aggregates frame counts + bytes + direction split', () {
      dao.upsertWsConnection(sid, connId: 7, host: 'h', port: 80, path: '/s', startedMs: 1);
      dao.insertWsFrame(sid,
          connId: 7,
          tsMs: 10,
          direction: 'out',
          opcode: 'text',
          length: 5,
          isText: true,
          compressed: false,
          preview: 'hello');
      dao.insertWsFrame(sid,
          connId: 7,
          tsMs: 20,
          direction: 'in',
          opcode: 'binary',
          length: 4,
          isText: false,
          compressed: true,
          preview: 'deadbeef');

      // queryWsConnections returns raw SQL column names; the ws_list tool maps
      // them to camelCase for the agent.
      final conn = dao.queryWsConnections(sessionId: sid).single;
      expect(conn['frame_count'], equals(2));
      expect(conn['out_count'], equals(1));
      expect(conn['in_count'], equals(1));
      expect(conn['total_bytes'], equals(9));
      expect(conn['last_ms'], equals(20));
    });

    test('queryWsFrames returns newest-first and filters by direction', () {
      dao.upsertWsConnection(sid, connId: 3, host: 'h', port: 80, path: '/', startedMs: 1);
      for (var i = 0; i < 3; i++) {
        dao.insertWsFrame(sid,
            connId: 3,
            tsMs: i,
            direction: i.isEven ? 'out' : 'in',
            opcode: 'text',
            length: 1,
            isText: true,
            compressed: false,
            preview: 'm$i');
      }
      final all = dao.queryWsFrames(sessionId: sid, connId: 3);
      expect(all.map((r) => r['preview']), equals(['m2', 'm1', 'm0']));

      final outbound = dao.queryWsFrames(sessionId: sid, connId: 3, direction: 'out');
      expect(outbound.map((r) => r['preview']), equals(['m2', 'm0']));
    });

    test('migrates a pre-ws database up, recreating the ws tables', () {
      // Simulate a pre-ws db: drop the ws tables and rewind the recorded
      // schema version to v9 (the ws tables landed in the v9 -> v10 migration),
      // then reopen so that migration runs.
      final raw = CapturesDatabase.instance.raw;
      raw.execute('DROP TABLE websocket_frames');
      raw.execute('DROP TABLE websocket_connections');
      raw.execute("UPDATE _meta SET value='9' WHERE key='schema_version'");
      CapturesDatabase.instance.close();

      CapturesDatabase.open(dataDir: dir.path);
      final reopened = CapturesDatabase.instance.raw;
      final v = reopened
          .select("SELECT value FROM _meta WHERE key='schema_version'")
          .first['value'];
      expect(int.parse(v as String), equals(currentVersion));
      final tables = reopened
          .select(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name LIKE 'websocket_%'",
          )
          .map((r) => r['name'])
          .toSet();
      expect(tables, containsAll(['websocket_connections', 'websocket_frames']));
    });

    test('deleteSession cascades to ws connections + frames', () {
      dao.upsertWsConnection(sid, connId: 1, host: 'h', port: 80, path: '/', startedMs: 1);
      dao.insertWsFrame(sid,
          connId: 1,
          tsMs: 1,
          direction: 'in',
          opcode: 'text',
          length: 1,
          isText: true,
          compressed: false,
          preview: 'x');
      dao.deleteSession(sid);
      final raw = CapturesDatabase.instance.raw;
      expect(
          raw.select('SELECT COUNT(*) AS n FROM websocket_connections').first['n'],
          equals(0));
      expect(raw.select('SELECT COUNT(*) AS n FROM websocket_frames').first['n'],
          equals(0));
    });
  });
}
