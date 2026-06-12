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

  /// Opens the database at `<dataDir>/captures.db`. When [dataDir] is null,
  /// walks a prioritized candidate list (see [_candidateDataDirs]) and uses
  /// the first writable one. Throws [StateError] (caller catches in `bin/`)
  /// if every candidate fails.
  static CapturesDatabase open({String? dataDir}) {
    if (_instance != null) return _instance!;

    final candidates = _candidateDataDirs(dataDir);
    final errors = <String>[];

    for (final dir in candidates) {
      try {
        Directory(dir).createSync(recursive: true);
        final dbPath = p.join(dir, 'captures.db');
        final db = sql.sqlite3.open(dbPath);
        db.execute('PRAGMA foreign_keys = ON');
        db.execute('PRAGMA journal_mode = WAL');
        _migrate(db);

        // Visibility when a non-primary fallback was chosen for a default
        // (auto-resolved) data dir. Skipped when the user passed an explicit
        // override — that's a single-element list, so dir == first.
        if (dataDir == null && dir != candidates.first) {
          stderr.writeln(
            'flutter_network_mcp: primary data dir ${candidates.first} '
            'not writable; using $dir instead.',
          );
        }

        return _instance = CapturesDatabase._(db, dbPath);
      } on FileSystemException catch (e) {
        errors.add('  $dir → ${e.osError?.message ?? e.message}');
        continue;
      }
    }

    throw StateError(
      'could not create data dir. Tried:\n'
      '${errors.join('\n')}\n'
      'Pass --data-dir <writable path> or set FLUTTER_NETWORK_MCP_DATA_DIR.',
    );
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
    if (from == 2 && to == 3) return migrationV2toV3;
    if (from == 3 && to == 4) return migrationV3toV4;
    if (from == 4 && to == 5) return migrationV4toV5;
    if (from == 5 && to == 6) return migrationV5toV6;
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

  /// Returns the prioritized list of data-dir candidates the caller should
  /// try in order. The first writable one wins.
  ///
  /// macOS order:
  ///   1. [override] (single-element list — no fallback when user is explicit)
  ///   2. $FLUTTER_NETWORK_MCP_DATA_DIR (single-element list)
  ///   3. $XDG_DATA_HOME/flutter_network_mcp (when XDG_DATA_HOME is set)
  ///   4. ~/Library/Application Support/flutter_network_mcp  (canonical macOS)
  ///   5. ~/.local/share/flutter_network_mcp  (back-compat; only used if
  ///      the 0.5.16 auto-migration failed and the old dir still exists)
  ///   6. ~/.cache/flutter_network_mcp  (last resort)
  ///
  /// Linux/other order:
  ///   1. [override]
  ///   2. $FLUTTER_NETWORK_MCP_DATA_DIR
  ///   3. $XDG_DATA_HOME/flutter_network_mcp
  ///   4. ~/.local/share/flutter_network_mcp
  ///   5. ~/.cache/flutter_network_mcp
  ///
  /// On macOS, runs the one-time canonical-path migration before assembling
  /// the list so the renamed dir is found at its new home.
  static List<String> _candidateDataDirs(String? override) {
    if (override != null && override.isNotEmpty) return [override];

    final env = Platform.environment;
    final envOverride = env['FLUTTER_NETWORK_MCP_DATA_DIR'];
    if (envOverride != null && envOverride.isNotEmpty) return [envOverride];

    final home = env['HOME'] ?? '.';
    final out = <String>[];

    final xdg = env['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      out.add(p.join(xdg, 'flutter_network_mcp'));
    }

    if (Platform.isMacOS) {
      _maybeMigrateMacOsDataDir(home);
      out.add(p.join(home, 'Library', 'Application Support', 'flutter_network_mcp'));
      out.add(p.join(home, '.local', 'share', 'flutter_network_mcp'));
    } else {
      out.add(p.join(home, '.local', 'share', 'flutter_network_mcp'));
    }

    out.add(p.join(home, '.cache', 'flutter_network_mcp'));
    return out;
  }

  /// One-time atomic move of ~/.local/share/flutter_network_mcp to
  /// ~/Library/Application Support/flutter_network_mcp on macOS (0.5.16).
  ///
  /// Pre-conditions to migrate:
  ///   * old dir's captures.db exists
  ///   * new dir's captures.db does NOT exist
  ///
  /// Atomic rename only — both paths live under `$HOME`, same filesystem.
  /// On failure (permissions, race, etc.) leaves the old dir untouched so
  /// the candidate walker can still fall back to it (slot 5 on macOS).
  /// Never does partial copy+delete: corruption risk outweighs the cost of
  /// staying on the old path.
  static void _maybeMigrateMacOsDataDir(String home) {
    final oldDir = Directory(
      p.join(home, '.local', 'share', 'flutter_network_mcp'),
    );
    final newDirPath = p.join(
      home,
      'Library',
      'Application Support',
      'flutter_network_mcp',
    );

    final oldDbExists = File(p.join(oldDir.path, 'captures.db')).existsSync();
    final newDbExists = File(p.join(newDirPath, 'captures.db')).existsSync();

    if (!oldDbExists || newDbExists) return;

    try {
      Directory(p.dirname(newDirPath)).createSync(recursive: true);
      oldDir.renameSync(newDirPath);
      stderr.writeln(
        'flutter_network_mcp: migrated data dir from ${oldDir.path} to '
        '$newDirPath (macOS canonical path; 0.5.16). '
        'Set FLUTTER_NETWORK_MCP_DATA_DIR or --data-dir to override.',
      );
    } catch (e) {
      stderr.writeln(
        'flutter_network_mcp: tried to migrate ${oldDir.path} to macOS '
        'canonical path but failed ($e); continuing to use old location.',
      );
    }
  }
}
