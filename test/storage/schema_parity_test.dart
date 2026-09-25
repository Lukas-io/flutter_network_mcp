import 'dart:convert';
import 'dart:io';

import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/storage/schema.dart'
    show currentVersion;
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

/// Every table, column, index and trigger, in a form that ignores statement formatting and column order.
Map<String, Object> describeSchema(sql.Database db) {
  final objects = db.select(
      "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'");
  final virtual = {
    for (final o in objects)
      if ((o['sql'] as String? ?? '')
          .toUpperCase()
          .contains('CREATE VIRTUAL TABLE'))
        o['name'] as String,
  };
  bool isShadow(String name) => virtual.any((v) => name.startsWith('${v}_'));
  String norm(String? s) => (s ?? '')
      .toLowerCase()
      .replaceAll(' if not exists', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'\s*([(),])\s*'), r'$1')
      .trim();

  final out = <String, Object>{};
  for (final o in objects) {
    final type = o['type'] as String;
    final name = o['name'] as String;
    if (isShadow(name)) continue;
    if (type == 'table' && !virtual.contains(name)) {
      final cols = db
          .select('PRAGMA table_info("$name")')
          .map((c) =>
              '${c['name']} ${(c['type'] as String).toUpperCase()} notnull=${c['notnull']} '
              'default=${c['dflt_value']} pk=${c['pk']}')
          .toList()
        ..sort();
      out['table $name'] = cols;
    } else if (type == 'index' && o['sql'] == null) {
      continue;
    } else {
      out['$type $name'] = norm(o['sql'] as String?);
    }
  }
  return out;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('schema_parity_'));
  tearDown(() {
    if (CapturesDatabase.isOpen) CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  Map<String, Object> freshSchema() {
    final fresh = Directory('${dir.path}/fresh')..createSync();
    CapturesDatabase.open(dataDir: fresh.path);
    final schema = describeSchema(CapturesDatabase.instance.raw);
    CapturesDatabase.instance.close();
    return schema;
  }

  final fixtures = Directory('test/fixtures/schema')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('the comparison notices a missing index or column', () {
    final expected = freshSchema();
    final copy = Directory('${dir.path}/damaged')..createSync();
    CapturesDatabase.open(dataDir: copy.path);
    final raw = CapturesDatabase.instance.raw;
    const index = 'idx_logs_dedup';
    raw.execute('DROP INDEX $index');
    raw.execute('ALTER TABLE log_records DROP COLUMN dedup_key');
    final damaged = describeSchema(raw);
    expect(damaged.containsKey('index $index'), isFalse);
    expect(jsonEncode(damaged['table log_records']),
        isNot(jsonEncode(expected['table log_records'])));
    expect(expected.length, greaterThan(20));
  });

  test('there is a fixture for every past schema version', () {
    final versions = {
      for (final f in fixtures)
        (jsonDecode(f.readAsStringSync()) as Map)['version'] as int,
    };
    expect(versions, {for (var v = 2; v < currentVersion; v++) v});
  });

  for (final fixture in fixtures) {
    final data = jsonDecode(fixture.readAsStringSync()) as Map<String, Object?>;
    final version = data['version'] as int;
    test(
        'a database created at v$version upgrades to exactly the current schema',
        () {
      final expected = freshSchema();
      final old = Directory('${dir.path}/v$version')..createSync();
      final db = sql.sqlite3.open('${old.path}/captures.db');
      for (final stmt in (data['statements'] as List).cast<String>()) {
        db.execute(stmt);
      }
      db.execute(
          'CREATE TABLE IF NOT EXISTS _meta (key TEXT PRIMARY KEY, value TEXT)');
      db.execute(
          "INSERT OR REPLACE INTO _meta(key, value) VALUES ('schema_version', '$version')");
      db.close();

      CapturesDatabase.open(dataDir: old.path);
      final upgraded = describeSchema(CapturesDatabase.instance.raw);
      final missing =
          expected.keys.where((k) => !upgraded.containsKey(k)).toList();
      final extra =
          upgraded.keys.where((k) => !expected.containsKey(k)).toList();
      final differ = expected.keys
          .where((k) =>
              upgraded.containsKey(k) &&
              jsonEncode(upgraded[k]) != jsonEncode(expected[k]))
          .map((k) =>
              '$k\n  upgraded: ${jsonEncode(upgraded[k])}\n  fresh:    ${jsonEncode(expected[k])}')
          .toList();
      expect([
        ...missing.map((k) => 'missing $k'),
        ...extra.map((k) => 'extra $k'),
        ...differ
      ], isEmpty);
    });
  }
}
