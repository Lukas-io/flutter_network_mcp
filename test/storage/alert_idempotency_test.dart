import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

/// Alert dedup contract (user request): repeated evaluation of the SAME
/// source must not create duplicate rows OR inflate occurrence_count; a
/// genuinely new source sharing a signature bumps the count once.
void main() {
  late Directory dir;
  late CapturesDao dao;
  late int sid;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('alert_idem_test_');
    CapturesDatabase.open(dataDir: dir.path);
    dao = CapturesDao();
    sid = dao.createSession(
        appName: 'a', vmServiceUri: 'ws://x', isolateId: null, projectPath: null);
  });

  tearDown(() {
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  bool fire({required String sourceId, String sig = 'sig-1'}) => dao.insertAlert(
        sessionId: sid,
        severity: 'error',
        kind: 'http_5xx',
        title: '500 on GET api/x',
        signature: sig,
        sourceKind: 'http',
        sourceId: sourceId,
      );

  int occ() => CapturesDatabase.instance.raw
      .select('SELECT occurrence_count FROM alerts WHERE session_id=?', [sid])
      .first['occurrence_count'] as int;

  int rowCount() => CapturesDatabase.instance.raw
      .select('SELECT COUNT(*) c FROM alerts WHERE session_id=?', [sid])
      .first['c'] as int;

  test('first fire inserts one row, occurrence 1', () {
    expect(fire(sourceId: 'req-1'), isTrue);
    expect(rowCount(), 1);
    expect(occ(), 1);
  });

  test('re-evaluating the SAME source does not inflate occurrence_count', () {
    fire(sourceId: 'req-1');
    fire(sourceId: 'req-1');
    fire(sourceId: 'req-1');
    expect(rowCount(), 1, reason: 'still one alert row');
    expect(occ(), 1, reason: 'same source re-evaluated must not bump the count');
  });

  test('a NEW source sharing the signature bumps occurrence once', () {
    fire(sourceId: 'req-1');
    fire(sourceId: 'req-2');
    fire(sourceId: 'req-3');
    expect(rowCount(), 1, reason: 'one row per signature while pending');
    expect(occ(), 3, reason: 'three distinct sources -> count 3');
  });

  test('interleaved repeat of the immediate-prior source is not counted', () {
    fire(sourceId: 'req-1'); // occ 1
    fire(sourceId: 'req-2'); // occ 2 (new)
    fire(sourceId: 'req-2'); // repeat of last -> occ stays 2
    expect(occ(), 2);
  });

  test('after drain, a new occurrence starts a fresh pending row', () {
    fire(sourceId: 'req-1');
    CapturesDatabase.instance.raw
        .execute('UPDATE alerts SET drained=1 WHERE session_id=?', [sid]);
    expect(fire(sourceId: 'req-2'), isTrue,
        reason: 'a fresh pending alert after the old one was handled');
    expect(rowCount(), 2, reason: 'one drained + one new pending');
  });
}
