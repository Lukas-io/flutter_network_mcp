import 'dart:io';

import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/storage/schema.dart' show currentVersion;
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('newer_schema_test_'));
  tearDown(() => dir.deleteSync(recursive: true));

  void stampVersion(int v) {
    final db = sql.sqlite3.open('${dir.path}/captures.db');
    db.execute("UPDATE _meta SET value='$v' WHERE key='schema_version'");
    db.dispose();
  }

  String storedVersion() {
    final db = sql.sqlite3.open('${dir.path}/captures.db');
    final v = db.select("SELECT value FROM _meta WHERE key='schema_version'").first['value'] as String;
    db.dispose();
    return v;
  }

  test('a database written by a newer build is refused and left untouched', () {
    CapturesDatabase.open(dataDir: dir.path);
    CapturesDatabase.instance.close();
    stampVersion(currentVersion + 1);

    expect(
      () => CapturesDatabase.open(dataDir: dir.path),
      throwsA(isA<NewerDatabaseError>()
          .having((e) => e.toString(), 'message', contains('--data-dir'))),
    );
    expect(storedVersion(), '${currentVersion + 1}');
  });

  test('the server exits with a clear message instead of writing to it', () async {
    CapturesDatabase.open(dataDir: dir.path);
    CapturesDatabase.instance.close();
    stampVersion(currentVersion + 1);

    final r = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/flutter_network_mcp.dart', '--data-dir', dir.path, '--no-auto-discover-dtd'],
      environment: {'FLUTTER_NETWORK_MCP_NO_TELEMETRY': 'true'},
    );
    expect(r.exitCode, 78);
    expect(r.stderr, contains('newer than this build supports'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
