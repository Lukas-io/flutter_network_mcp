import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;

import 'schema.dart';

/// Owns the on-disk captures database. Singleton per process.
class CapturesDatabase {
  CapturesDatabase._(this._db, this.path);

  final sql.Database _db;
  final String path;
  sql.Database get raw => _db;

  static CapturesDatabase? _instance;
  static CapturesDatabase get instance =>
      _instance ?? (throw StateError('Database not opened. Call open() first.'));
  static bool get isOpen => _instance != null;

  /// Opens the database at [dataDir]/captures.db (default: ~/.local/share/flutter_network_mcp/).
  static CapturesDatabase open({String? dataDir}) {
    if (_instance != null) return _instance!;
    final dir = _resolveDataDir(dataDir);
    Directory(dir).createSync(recursive: true);
    final dbPath = p.join(dir, 'captures.db');
    final db = sql.sqlite3.open(dbPath);
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA journal_mode = WAL');
    _migrate(db);
    return _instance = CapturesDatabase._(db, dbPath);
  }

  static void _migrate(sql.Database db) {
    db.execute('CREATE TABLE IF NOT EXISTS _meta (key TEXT PRIMARY KEY, value TEXT)');
    final row = db.select("SELECT value FROM _meta WHERE key='schema_version'");
    int version = 0;
    if (row.isNotEmpty) {
      version = int.tryParse(row.first['value'] as String? ?? '0') ?? 0;
    }
    if (version == 0) {
      db.execute('BEGIN');
      try {
        for (final stmt in initialSchema) {
          db.execute(stmt);
        }
        db.execute(
          "INSERT OR REPLACE INTO _meta(key,value) VALUES ('schema_version','$currentVersion')",
        );
        db.execute('COMMIT');
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
      return;
    }
    while (version < currentVersion) {
      db.execute('BEGIN');
      try {
        final next = version + 1;
        final stmts = _migrationFor(version, next);
        for (final stmt in stmts) {
          db.execute(stmt);
        }
        db.execute(
          "INSERT OR REPLACE INTO _meta(key,value) VALUES ('schema_version','$next')",
        );
        db.execute('COMMIT');
        version = next;
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
  }

  static List<String> _migrationFor(int from, int to) {
    if (from == 1 && to == 2) return migrationV1toV2;
    throw StateError('No migration defined for $from → $to.');
  }

  void close() {
    try {
      _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      _db.execute('PRAGMA optimize');
    } catch (_) {/* best effort */}
    // ignore: deprecated_member_use
    _db.dispose();
    _instance = null;
  }

  static String _resolveDataDir(String? override) {
    if (override != null && override.isNotEmpty) return override;
    final env = Platform.environment;
    final xdg = env['XDG_DATA_HOME'];
    final base = (xdg != null && xdg.isNotEmpty)
        ? xdg
        : p.join(env['HOME'] ?? '.', '.local', 'share');
    return p.join(base, 'flutter_network_mcp');
  }
}
