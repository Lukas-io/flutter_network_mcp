import 'dart:io';

import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:test/test.dart';

/// Issue #27: several apps launched from the same directory share a
/// `project_path`, so filtering by it returns the wrong app. `listSessions`
/// gains an `appNameContains` filter that scopes by the real DTD identity.
void main() {
  group('listSessions appNameContains filter', () {
    late Directory dir;
    late CapturesDao dao;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('list_sessions_filter_test_');
      CapturesDatabase.open(dataDir: dir.path);
      dao = CapturesDao();
      // Three apps, ONE shared working directory (the #27 scenario).
      for (final app in ['sangaeats', 'aetrust', 'sanga_driver']) {
        dao.createSession(
          appName: app,
          vmServiceUri: 'ws://$app/ws',
          isolateId: 'isolates/1',
          projectPath: '/Users/x/StudioProjects',
        );
      }
    });

    tearDown(() {
      CapturesDatabase.instance.close();
      dir.deleteSync(recursive: true);
    });

    test('projectPath alone returns every app sharing the directory', () {
      final rows = dao.listSessions(projectPath: '/Users/x/StudioProjects');
      expect(rows.length, 3, reason: 'the misleading mode #27 reported');
    });

    test('appNameContains scopes to the matching app (case-insensitive)', () {
      final rows = dao.listSessions(appNameContains: 'AETRUST');
      expect(rows.map((r) => r['app_name']), ['aetrust']);
    });

    test('appNameContains is a substring match', () {
      final rows = dao.listSessions(appNameContains: 'sanga');
      expect(
        rows.map((r) => r['app_name']).toSet(),
        {'sangaeats', 'sanga_driver'},
      );
    });

    test('appNameContains + projectPath combine (AND)', () {
      final rows = dao.listSessions(
        appNameContains: 'aetrust',
        projectPath: '/Users/x/StudioProjects',
      );
      expect(rows.single['app_name'], 'aetrust');
    });

    test('no match returns empty', () {
      expect(dao.listSessions(appNameContains: 'nope'), isEmpty);
    });
  });
}
