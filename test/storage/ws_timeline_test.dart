import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/storage/ws_timeline_ingestor.dart';
import 'package:flutter_network_mcp/src/tools/ws_get.dart';
import 'package:flutter_network_mcp/src/tools/ws_list.dart';
import 'package:test/test.dart';

import '../support/schema_rollback.dart';

const _iso = 'isolates/1';

Map<String, Object?> _event(
  String name,
  int ts, {
  String ph = 'n',
  String id = 't9',
  Map<String, Object?> args = const {},
}) =>
    {
      'name': name,
      'cat': 'Dart',
      'ph': ph,
      'ts': ts,
      'id': id,
      'args': {...args, 'filterKey': 'HTTP/websocket', 'isolateId': _iso},
    };

Map<String, Object?> _frame(
        String name, int ts, int conn, String dir, String opcode, int bytes) =>
    _event(name, ts, args: {
      'connectionId': conn,
      'direction': dir,
      'opcode': opcode,
      'bytes': bytes,
    });

/// The ten events a live Dart 3.13 app emitted for connect, three sends, three echoes and a close.
List<Map<String, Object?>> _echoSession() => [
      _event('WebSocket.Connect', 1000,
          ph: 'b', id: 'c1', args: {'uri': 'ws://127.0.0.1:8799'}),
      _event('WebSocket.Connect', 5000, ph: 'e', id: 'c1'),
      _frame('WebSocket.Send', 5500, 2, 'out', 'text', 5),
      _frame('WebSocket.Send', 5600, 2, 'out', 'text', 239),
      _frame('WebSocket.Send', 5700, 2, 'out', 'binary', 3),
      _frame('WebSocket.Receive', 6000, 2, 'in', 'text', 10),
      _frame('WebSocket.Receive', 6100, 2, 'in', 'text', 244),
      _frame('WebSocket.Receive', 6200, 2, 'in', 'binary', 3),
      _event('WebSocket.Close', 400000, args: {
        'connectionId': 2,
        'direction': 'out',
        'closeCode': 1000,
        'reason': 'done'
      }),
      _event('WebSocket.Close', 401000, args: {
        'connectionId': 2,
        'direction': 'in',
        'closeCode': 1000,
        'reason': 'done'
      }),
    ];

void main() {
  late Directory dir;
  late CapturesDao dao;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ws_timeline_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
    sid = dao.createSession(
        appName: 'app',
        vmServiceUri: 'ws://x',
        isolateId: null,
        projectPath: null);
  });

  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  void ingest(List<Map<String, Object?>> events, {int offset = 0}) =>
      WsTimelineIngestor(dao).ingest(sid, events, clockOffsetUs: offset);

  List<Map<String, Object?>> connections() =>
      dao.queryWsConnections(sessionId: sid);

  List<Map<String, Object?>> messages(Map<String, Object?> conn) =>
      dao.queryWsMessages(sessionId: sid, connKey: conn['conn_key'] as String);

  test('a v13 database gains the WebSocket tables on open', () {
    final raw = CapturesDatabase.instance.raw;
    rollBackV14(raw);
    raw.execute("UPDATE _meta SET value='13' WHERE key='schema_version'");
    CapturesDatabase.instance.close();

    CapturesDatabase.open(dataDir: dir.path);
    final tables = CapturesDatabase.instance.raw
        .select(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'websocket_%'")
        .map((r) => r['name'])
        .toSet();
    expect(tables, {'websocket_connections', 'websocket_messages'});
  });

  test('a full echo exchange becomes one closed connection with its totals',
      () {
    ingest(_echoSession(), offset: 1000000);
    final conn = wsConnectionJson(connections().single);
    expect(conn['url'], 'ws://127.0.0.1:8799');
    expect(conn['state'], 'closed');
    expect(conn['close'], '1000 "done" by app');
    expect(conn['sent'], 3);
    expect(conn['received'], 3);
    expect(conn['bytesSent'], 247);
    expect(conn['bytesReceived'], 257);
    expect(conn['startedMs'], 1001);
    expect(conn['connectMs'], 4);
    expect(conn.containsKey('uriInferred'), isFalse);
    expect(messages(connections().single).map((m) => m['kind']),
        ['text', 'text', 'binary', 'text', 'text', 'binary', 'close', 'close']);
  });

  test('re-reading the same events, even from a fresh process, adds nothing',
      () {
    ingest(_echoSession());
    ingest(_echoSession());
    ingest(_echoSession().sublist(4));
    expect(connections(), hasLength(1));
    expect(messages(connections().single), hasLength(8));
  });

  test('two identical messages in the same microsecond are both kept', () {
    ingest([
      ..._echoSession().take(2),
      _frame('WebSocket.Send', 5500, 2, 'out', 'text', 5),
      _frame('WebSocket.Send', 5500, 2, 'out', 'text', 5),
    ]);
    ingest([
      _frame('WebSocket.Send', 5500, 2, 'out', 'text', 5),
      _frame('WebSocket.Send', 5500, 2, 'out', 'text', 5),
    ]);
    expect(messages(connections().single), hasLength(2));
  });

  test('a refused upgrade is a failed connection with the status and reason',
      () {
    ingest([
      _event('WebSocket.Connect', 10,
          ph: 'b', id: 'c9', args: {'uri': 'ws://h/nope'}),
      _event('WebSocket.Connect', 20, ph: 'e', id: 'c9', args: {
        'error': "Connection to 'http://h/nope#' was not upgraded to websocket",
        'httpStatusCode': 404,
      }),
    ]);
    final conn = wsConnectionJson(connections().single);
    expect(conn['state'], 'failed');
    expect(conn['httpStatus'], 404);
    expect(conn['error'], contains('not upgraded'));
  });

  test('connects waiting together bind in order, flagged as inferred', () {
    ingest([
      _event('WebSocket.Connect', 10,
          ph: 'b', id: 'a', args: {'uri': 'ws://h/a'}),
      _event('WebSocket.Connect', 11,
          ph: 'b', id: 'b', args: {'uri': 'ws://h/b'}),
      _event('WebSocket.Connect', 20, ph: 'e', id: 'a'),
      _event('WebSocket.Connect', 21, ph: 'e', id: 'b'),
      _frame('WebSocket.Send', 30, 5, 'out', 'text', 1),
      _frame('WebSocket.Send', 40, 6, 'out', 'text', 1),
    ]);
    final byUrl = {for (final c in connections()) c['uri']: c};
    expect(byUrl['ws://h/a']!['connection_id'], 5);
    expect(byUrl['ws://h/a']!['uri_inferred'], 1);
    expect(byUrl['ws://h/b']!['connection_id'], 6);
    expect(byUrl['ws://h/b']!['uri_inferred'], 0);
  });

  test('a silent connection keeps its url when a later one speaks first', () {
    ingest([
      ..._echoSession().take(3),
      _event('WebSocket.Connect', 10000,
          ph: 'b', id: 'p', args: {'uri': 'ws://h/ping'}),
      _event('WebSocket.Connect', 10001,
          ph: 'b', id: 'd', args: {'uri': 'ws://h/drop'}),
      _event('WebSocket.Connect', 10010, ph: 'e', id: 'p'),
      _event('WebSocket.Connect', 10011, ph: 'e', id: 'd'),
      _frame('WebSocket.Send', 10020, 4, 'out', 'text', 4),
      _event('WebSocket.Pong', 10300,
          args: {'connectionId': 3, 'direction': 'out', 'bytes': 0}),
    ]);
    final byUrl = {for (final c in connections()) c['uri']: c};
    expect(byUrl['ws://h/drop']!['connection_id'], 4);
    expect(byUrl['ws://h/ping']!['connection_id'], 3);
    expect(byUrl['ws://h/drop']!['uri_inferred'], 0);
    expect(byUrl['ws://h/ping']!['uri_inferred'], 0);
  });

  test('a connection opened before capture shows up without a url', () {
    ingest([
      _event('WebSocket.Ping', 50,
          args: {'connectionId': 3, 'direction': 'in', 'bytes': 0}),
      _event('WebSocket.Pong', 51,
          args: {'connectionId': 3, 'direction': 'out', 'bytes': 0}),
      _event('WebSocket.Error', 60,
          args: {'connectionId': 3, 'error': 'SocketException: reset'}),
    ]);
    final conn = wsConnectionJson(connections().single);
    expect(conn['url'], isNull);
    expect(conn['state'], 'error');
    expect(conn['error'], 'SocketException: reset');
    expect(messages(connections().single).map((m) => m['kind']),
        ['ping', 'pong', 'error']);
  });

  test('deleting the session removes its WebSocket rows', () {
    ingest(_echoSession());
    dao.deleteSession(sid);
    final raw = CapturesDatabase.instance.raw;
    expect(raw.select('SELECT * FROM websocket_connections'), isEmpty);
    expect(raw.select('SELECT * FROM websocket_messages'), isEmpty);
  });

  group('tools', () {
    Future<Map<String, Object?>> call(
      FutureOr<CallToolResult> Function(CallToolRequest) tool,
      Map<String, Object?> args,
    ) async =>
        (await tool(CallToolRequest(
                name: 't', arguments: {'sessionId': sid, ...args})))
            .structuredContent!;

    test('ws_list names the connection and ws_get reads its timeline',
        () async {
      ingest(_echoSession());
      final list = await call(wsList, {});
      final id = ((list['connections'] as List).single as Map)['id'];
      expect(list['summary'], contains('1 closed'));

      final got = await call(wsGet, {'id': id, 'direction': 'out', 'limit': 2});
      expect(got['events'], ['+0.004s out text 5B', '+0.004s out text 239B']);
      expect(got['nextAfterId'], isNotNull);
      final rest = await call(
          wsGet, {'id': id, 'direction': 'out', 'afterId': got['nextAfterId']});
      expect(rest['events'],
          ['+0.004s out binary 3B', '+0.399s out close 1000 done']);
    });

    test('bad arguments and unknown ids are branchable errors', () async {
      expect((await call(wsGet, {}))['errorKind'], 'bad_argument');
      expect((await call(wsGet, {'id': 1, 'kind': 'frame'}))['errorKind'],
          'bad_argument');
      expect((await call(wsGet, {'id': 99}))['errorKind'], 'not_found');
      expect(
          (await call(wsList, {'state': 'gone'}))['errorKind'], 'bad_argument');
    });

    test('an empty capture says what is and is not visible', () async {
      final list = await call(wsList, {});
      expect(list['count'], 0);
      expect((list['warnings'] as List).join(), contains('Native clients'));
    });
  });
}
