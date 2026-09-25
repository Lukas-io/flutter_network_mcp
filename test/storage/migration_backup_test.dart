import 'dart:io';

import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/storage/schema.dart' show currentVersion;
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

import '../support/schema_rollback.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('migration_backup_test_'));
  tearDown(() {
    if (CapturesDatabase.isOpen) CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  String backup(int v) => '${dir.path}/captures.db.pre-v$v.bak';

  /// A database left at schema v13 holding one session.
  void seedV13() {
    CapturesDatabase.open(dataDir: dir.path);
    final raw = CapturesDatabase.instance.raw;
    raw.execute("INSERT INTO sessions(started_at, app_name) VALUES (1, 'kept-app')");
    rollBackV14(raw);
    raw.execute("UPDATE _meta SET value='13' WHERE key='schema_version'");
    CapturesDatabase.instance.close();
  }

  test('upgrading an existing database first writes a backup of it', () {
    seedV13();
    CapturesDatabase.open(dataDir: dir.path);

    expect(File(backup(13)).existsSync(), isTrue);
    final copy = sql.sqlite3.open(backup(13));
    addTearDown(copy.close);
    expect(copy.select("SELECT value FROM _meta WHERE key='schema_version'").first['value'], '13');
    expect(copy.select('SELECT app_name FROM sessions').single['app_name'], 'kept-app');
    expect(CapturesDatabase.instance.raw
        .select("SELECT value FROM _meta WHERE key='schema_version'").first['value'],
        '$currentVersion');
  });

  test('a new database and an up-to-date one get no backup', () {
    CapturesDatabase.open(dataDir: dir.path);
    CapturesDatabase.instance.close();
    CapturesDatabase.open(dataDir: dir.path);
    final backups = dir.listSync().where((f) => f.path.contains('.pre-v'));
    expect(backups, isEmpty);
  });

  test('the newest backup replaces older ones, and stale ones are pruned', () {
    File(backup(11)).writeAsStringSync('old');
    seedV13();
    CapturesDatabase.open(dataDir: dir.path);
    expect(File(backup(11)).existsSync(), isFalse);
    expect(File(backup(13)).existsSync(), isTrue);
    CapturesDatabase.instance.close();

    File(backup(13)).setLastModifiedSync(
        DateTime.now().subtract(CapturesDatabase.backupRetention + const Duration(days: 1)));
    CapturesDatabase.open(dataDir: dir.path);
    expect(File(backup(13)).existsSync(), isFalse);
  });

  test('a manual backup with another name is never touched', () {
    final manual = File('${dir.path}/captures.db.pre-v13-2026-09-25.bak')
      ..writeAsStringSync('mine');
    manual.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 60)));
    seedV13();
    CapturesDatabase.open(dataDir: dir.path);
    expect(manual.existsSync(), isTrue);
  });
}
