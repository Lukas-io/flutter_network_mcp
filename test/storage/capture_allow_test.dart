import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

/// #64 follow-up: persistent capture allowlist (the capture_allow tool) +
/// its v9 -> v10 migration.
void main() {
  group('capture_allow DAO', () {
    late Directory dir;
    late CapturesDao dao;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('capture_allow_test_');
      CapturesDatabase.open(dataDir: dir.path);
      dao = CapturesDao();
    });

    tearDown(() {
      CapturesDatabase.instance.close();
      dir.deleteSync(recursive: true);
    });

    test('add / list / set / remove round-trip', () {
      expect(dao.addCaptureAllow('api.example.com/stock/*', reason: 'focus'), isTrue);
      final list = dao.listCaptureAllow();
      expect(list.single['pattern'], 'api.example.com/stock/*');
      expect(list.single['reason'], 'focus');
      expect(dao.captureAllowSet(), {'api.example.com/stock/*'});

      // re-add (INSERT OR REPLACE) reports not-new
      expect(dao.addCaptureAllow('api.example.com/stock/*'), isFalse, reason: 're-add');

      expect(dao.removeCaptureAllow('api.example.com/stock/*'), isTrue);
      expect(dao.removeCaptureAllow('api.example.com/stock/*'), isFalse);
      expect(dao.captureAllowSet(), isEmpty);
    });
  });

  test('v9 DB migrates to add the capture_allow table', () {
    final dir = Directory.systemTemp.createTempSync('capture_allow_mig_');
    // Open at current version, then simulate an older v9 DB.
    CapturesDatabase.open(dataDir: dir.path);
    final raw = CapturesDatabase.instance.raw;
    raw.execute('DROP TABLE capture_allow');
    // A real v9 DB predates both capture_allow (v10) and redirects_json
    // (v11), so drop the column too — else replaying 10->11 re-adds it.
    raw.execute('ALTER TABLE http_requests DROP COLUMN redirects_json');
    raw.execute("UPDATE _meta SET value='9' WHERE key='schema_version'");
    CapturesDatabase.instance.close();

    // Reopen → v9->v10 recreates capture_allow, v10->v11 re-adds redirects_json.
    CapturesDatabase.open(dataDir: dir.path);
    final dao = CapturesDao();
    expect(() => dao.addCaptureAllow('a.com/x'), returnsNormally);
    expect(dao.captureAllowSet(), {'a.com/x'});
    // v11 column is back.
    final cols = CapturesDatabase.instance.raw
        .select('PRAGMA table_info(http_requests)')
        .map((r) => r['name'])
        .toList();
    expect(cols, contains('redirects_json'));

    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });
}
