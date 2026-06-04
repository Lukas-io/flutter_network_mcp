// Seeds the captures DB with synthetic data so Phase 4 features can be tested
// without a live Flutter app. Run before pointing the MCP server at the same
// --data-dir.
//
// Usage: dart run tool/seed.dart /tmp/fnm_p4_dir

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_network_mcp/src/alerts/alert_rules.dart';
import 'package:flutter_network_mcp/src/alerts/signature.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';

void main(List<String> args) {
  final dataDir = args.isEmpty ? '/tmp/fnm_p4_dir' : args.first;
  final db = CapturesDatabase.open(dataDir: dataDir);
  final dao = CapturesDao();

  final sid = dao.createSession(
    appName: 'TestApp seed',
    vmServiceUri: 'ws://seed/test',
    isolateId: 'isolates/seed',
    projectPath: '/tmp/seed-project',
  );
  print('seeded session id: $sid');

  // Two requests — same endpoint, different responses. One 500, one 200 with
  // a long duration to trigger http_slow.
  final reqs = [
    _Req(
      id: 'req-1',
      method: 'POST',
      url: 'https://api.example.com/v1/login',
      host: 'api.example.com',
      path: '/v1/login',
      status: 500,
      reason: 'Internal Server Error',
      startUs: 1700000000000000,
      endUs: 1700000000180000,
      reqBody: '{"username":"alice","password":"hunter2"}',
      respBody: '{"error":"invalid_token","message":"auth failed"}',
      reqHeaders: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer secret-xyz',
      },
      respHeaders: {'Content-Type': 'application/json'},
    ),
    _Req(
      id: 'req-2',
      method: 'POST',
      url: 'https://api.example.com/v1/login',
      host: 'api.example.com',
      path: '/v1/login',
      status: 200,
      reason: 'OK',
      startUs: 1700000005000000,
      endUs: 1700000009500000, // 4.5s — triggers http_slow
      reqBody: '{"username":"alice","password":"correcthorse"}',
      respBody: '{"ok":true,"token":"happy-path-token"}',
      reqHeaders: {
        'Content-Type': 'application/json',
      },
      respHeaders: {'Content-Type': 'application/json'},
    ),
  ];

  for (final r in reqs) {
    db.raw.execute(
      'INSERT INTO http_requests(session_id, vm_id, method, url, host, path, status_code, reason_phrase, start_us, end_us, duration_us, request_size, response_size, content_type, request_headers_json, response_headers_json, has_error, bodies_fetched) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,1)',
      [
        sid,
        r.id,
        r.method,
        r.url,
        r.host,
        r.path,
        r.status,
        r.reason,
        r.startUs,
        r.endUs,
        r.endUs - r.startUs,
        r.reqBody.length,
        r.respBody.length,
        'application/json',
        jsonEncode(r.reqHeaders),
        jsonEncode(r.respHeaders),
      ],
    );
    db.raw.execute(
      'INSERT INTO http_bodies(session_id, vm_id, which, bytes, size) VALUES (?,?,?,?,?)',
      [sid, r.id, 'request', Uint8List.fromList(utf8.encode(r.reqBody)), r.reqBody.length],
    );
    db.raw.execute(
      'INSERT INTO http_bodies(session_id, vm_id, which, bytes, size) VALUES (?,?,?,?,?)',
      [sid, r.id, 'response', Uint8List.fromList(utf8.encode(r.respBody)), r.respBody.length],
    );
    dao.indexForSearch(
      sessionId: sid,
      vmId: r.id,
      url: r.url,
      requestText: r.reqBody,
      responseText: r.respBody,
    );

    // Manually run the alert detector logic since we're bypassing the live VM.
    if (r.status >= 500) {
      final title = '${r.status} on ${r.method} ${r.url}';
      dao.insertAlert(
        sessionId: sid,
        severity: 'error',
        kind: 'http_5xx',
        title: title,
        signature: computeAlertSignature(kind: 'http_5xx', title: title),
        detail: r.reason,
        sourceKind: 'http',
        sourceId: r.id,
      );
    } else if (r.status >= 400) {
      final title = '${r.status} on ${r.method} ${r.url}';
      dao.insertAlert(
        sessionId: sid,
        severity: 'warning',
        kind: 'http_4xx',
        title: title,
        signature: computeAlertSignature(kind: 'http_4xx', title: title),
        detail: r.reason,
        sourceKind: 'http',
        sourceId: r.id,
      );
    }
    final durMs = (r.endUs - r.startUs) ~/ 1000;
    if (durMs > AlertRules.instance.slowThresholdMs) {
      final title = '${durMs}ms on ${r.method} ${r.url}';
      dao.insertAlert(
        sessionId: sid,
        severity: 'warning',
        kind: 'http_slow',
        title: title,
        signature: computeAlertSignature(kind: 'http_slow', title: title),
        detail: 'Slow request.',
        sourceKind: 'http',
        sourceId: r.id,
      );
    }
  }

  // A log record that triggers the keyword detector + a Flutter error one.
  final logId1 = dao.insertLog(
    sessionId: sid,
    timestampMs: 1700000010000,
    source: 'logging',
    level: 1000,
    logger: 'AuthService',
    message: 'login request failed: invalid_token',
  );
  dao.insertAlert(
    sessionId: sid,
    severity: 'warning',
    kind: 'log_keyword',
    title: 'login request failed: invalid_token',
    signature: computeAlertSignature(
      kind: 'log_keyword',
      title: 'login request failed: invalid_token',
    ),
    detail: 'login request failed: invalid_token',
    sourceKind: 'log',
    sourceId: 'log:$logId1',
    tsMs: 1700000010000,
  );

  final logId2 = dao.insertLog(
    sessionId: sid,
    timestampMs: 1700000020000,
    source: 'stderr',
    level: null,
    logger: null,
    message:
        '══════ EXCEPTION CAUGHT BY WIDGETS LIBRARY ═══════\nNull check operator used on a null value\n#0      _MyHomePageState.build (package:test/main.dart:42:5)',
  );
  dao.insertAlert(
    sessionId: sid,
    severity: 'critical',
    kind: 'flutter_error',
    title: '══════ EXCEPTION CAUGHT BY WIDGETS LIBRARY ═══════',
    signature: computeAlertSignature(
      kind: 'flutter_error',
      title: '══════ EXCEPTION CAUGHT BY WIDGETS LIBRARY ═══════',
    ),
    detail:
        'Null check operator used on a null value at _MyHomePageState.build (line 42)',
    sourceKind: 'log',
    sourceId: 'log:$logId2',
    tsMs: 1700000020000,
  );

  print('Seeded $sid with 2 http requests + 2 logs + 5 alerts.');
  db.close();
}

class _Req {
  _Req({
    required this.id,
    required this.method,
    required this.url,
    required this.host,
    required this.path,
    required this.status,
    required this.reason,
    required this.startUs,
    required this.endUs,
    required this.reqBody,
    required this.respBody,
    required this.reqHeaders,
    required this.respHeaders,
  });
  final String id;
  final String method;
  final String url;
  final String host;
  final String path;
  final int status;
  final String reason;
  final int startUs;
  final int endUs;
  final String reqBody;
  final String respBody;
  final Map<String, dynamic> reqHeaders;
  final Map<String, dynamic> respHeaders;
}
