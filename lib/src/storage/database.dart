import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;

import 'schema.dart';
import '../util/data_dir.dart';
import '../util/network_env.dart';

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

  /// True when the database lives in memory only (no-persist / ephemeral mode,
  /// issue #64) — nothing is written to disk and everything is lost on exit.
  bool get isEphemeral => path == _memoryPath;
  static const String _memoryPath = ':memory:';

  /// Opens the database at `<dataDir>/captures.db`. When [dataDir] is null,
  /// walks a prioritized candidate list (see [_candidateDataDirs]) and uses
  /// the first writable one. Throws [StateError] (caller catches in `bin/`)
  /// if every candidate fails.
  ///
  /// When [inMemory] (or `GLINT_NETWORK_NO_PERSIST`) is set, opens a
  /// purely in-memory database instead: captures are readable live but never
  /// touch disk and vanish on exit. For noisy or sensitive flows where on-disk
  /// retention is unwanted.
  static CapturesDatabase open({String? dataDir, bool inMemory = false}) {
    if (_instance != null) return _instance!;

    if (inMemory || _noPersistFromEnv()) {
      final db = sql.sqlite3.openInMemory();
      db.execute('PRAGMA foreign_keys = ON');
      _migrate(db);
      stderr.writeln(
        'glint_network: NO-PERSIST mode — captures live in memory only '
        'and are lost when the server exits. Nothing is written to disk.',
      );
      return _instance = CapturesDatabase._(db, _memoryPath);
    }

    final candidates = _candidateDataDirs(dataDir);
    final errors = <String>[];

    for (final dir in candidates) {
      try {
        Directory(dir).createSync(recursive: true);
        final dbPath = p.join(dir, 'captures.db');
        final db = sql.sqlite3.open(dbPath);
        // First, so the pragmas and migration below wait out another server process instead of failing on its lock.
        db.execute('PRAGMA busy_timeout = 5000');
        db.execute('PRAGMA foreign_keys = ON');
        _enableWal(db);
        _backupBeforeMigration(db, dir);
        _pruneStaleBackups(dir);
        try {
          _migrate(db);
        } on NewerDatabaseError {
          db.close();
          rethrow;
        }

        if (dataDir == null && dir != candidates.first) {
          stderr.writeln(
            'glint_network: primary data dir ${candidates.first} '
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
      'Pass --data-dir <writable path> or set GLINT_NETWORK_DATA_DIR.',
    );
  }

  /// How long the automatic pre-migration backup is kept.
  static const backupRetention = Duration(days: 14);

  static final RegExp _backupName = RegExp(r'^captures\.db\.pre-v\d+\.bak$');

  static int _storedVersion(sql.Database db) {
    try {
      final row = db.select("SELECT value FROM _meta WHERE key='schema_version'");
      return row.isEmpty ? 0 : int.tryParse(row.first['value'] as String? ?? '') ?? 0;
    } on sql.SqliteException {
      return 0;
    }
  }

  /// Before upgrading an existing database, copies it to `captures.db.pre-v<N>.bak` so a migration that completes but damages data can be undone; the newest backup replaces older ones.
  static void _backupBeforeMigration(sql.Database db, String dir) {
    final off = networkEnv['GLINT_NETWORK_NO_MIGRATION_BACKUP']
        ?.trim()
        .toLowerCase();
    if (off == 'true' || off == '1' || off == 'yes' || off == 'on') return;
    final version = _storedVersion(db);
    if (version == 0 || version >= currentVersion) return;
    final target = p.join(dir, 'captures.db.pre-v$version.bak');
    if (File(target).existsSync()) return;
    final partial = '$target.partial-$pid';
    stderr.writeln(
      'glint_network: backing up captures.db before upgrading it from '
      'schema v$version to v$currentVersion...',
    );
    final watch = Stopwatch()..start();
    try {
      db.execute("VACUUM INTO '${partial.replaceAll("'", "''")}'");
      if (File(target).existsSync()) {
        File(partial).deleteSync();
      } else {
        File(partial).renameSync(target);
      }
    } on Object catch (e) {
      try {
        File(partial).deleteSync();
      } on Object {
        // Nothing was written.
      }
      stderr.writeln(
        'glint_network: backup before the upgrade failed ($e); '
        'upgrading without one.',
      );
      return;
    }
    stderr.writeln(
      'glint_network: backup written to $target in '
      '${watch.elapsedMilliseconds} ms.',
    );
    for (final f in Directory(dir).listSync()) {
      if (f is File && f.path != target && _backupName.hasMatch(p.basename(f.path))) {
        f.deleteSync();
      }
    }
  }

  /// Deletes automatic pre-migration backups older than [backupRetention].
  static void _pruneStaleBackups(String dir) {
    try {
      final cutoff = DateTime.now().subtract(backupRetention);
      for (final f in Directory(dir).listSync()) {
        if (f is File &&
            _backupName.hasMatch(p.basename(f.path)) &&
            f.statSync().modified.isBefore(cutoff)) {
          f.deleteSync();
        }
      }
    } on Object {
      // A backup that cannot be listed or removed is left for the user.
    }
  }

  static bool _noPersistFromEnv() {
    final raw = networkEnv['GLINT_NETWORK_NO_PERSIST']?.toLowerCase();
    return raw == 'true' || raw == '1' || raw == 'yes' || raw == 'on';
  }

  /// Switching a new file to WAL needs an exclusive lock and SQLite does not wait for it, so retry while another server process is creating the schema.
  static void _enableWal(sql.Database db) {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      try {
        db.execute('PRAGMA journal_mode = WAL');
        return;
      } on sql.SqliteException catch (e) {
        if (e.extendedResultCode & 0xff != 5 || DateTime.now().isAfter(deadline)) {
          rethrow;
        }
        sleep(const Duration(milliseconds: 50));
      }
    }
  }

  /// Each step reads the version inside an IMMEDIATE transaction, so server processes starting together on one DB apply it once instead of racing.
  static void _migrate(sql.Database db) {
    db.execute('CREATE TABLE IF NOT EXISTS _meta (key TEXT PRIMARY KEY, value TEXT)');
    while (true) {
      db.execute('BEGIN IMMEDIATE');
      try {
        final row = db.select("SELECT value FROM _meta WHERE key='schema_version'");
        final version = row.isEmpty
            ? 0
            : int.tryParse(row.first['value'] as String? ?? '0') ?? 0;
        if (version > currentVersion) {
          db.execute('ROLLBACK');
          throw NewerDatabaseError(found: version, supported: currentVersion);
        }
        if (version == currentVersion) {
          db.execute('COMMIT');
          return;
        }
        final next = version == 0 ? currentVersion : version + 1;
        final stmts = version == 0 ? initialSchema : _migrationFor(version, next);
        for (final stmt in stmts) {
          db.execute(stmt);
        }
        db.execute(
          "INSERT OR REPLACE INTO _meta(key,value) VALUES ('schema_version','$next')",
        );
        db.execute('COMMIT');
      } on NewerDatabaseError {
        rethrow;
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
    if (from == 6 && to == 7) return migrationV6toV7;
    if (from == 7 && to == 8) return migrationV7toV8;
    if (from == 8 && to == 9) return migrationV8toV9;
    if (from == 9 && to == 10) return migrationV9toV10;
    if (from == 10 && to == 11) return migrationV10toV11;
    if (from == 11 && to == 12) return migrationV11toV12;
    if (from == 12 && to == 13) return migrationV12toV13;
    if (from == 13 && to == 14) return migrationV13toV14;
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
  ///   2. $GLINT_NETWORK_DATA_DIR (single-element list)
  ///   3. $XDG_DATA_HOME/flutter_network_mcp (when XDG_DATA_HOME is set)
  ///   4. ~/Library/Application Support/flutter_network_mcp  (canonical macOS)
  ///   5. ~/.local/share/flutter_network_mcp  (back-compat; only used if
  ///      the 0.5.16 auto-migration failed and the old dir still exists)
  ///   6. ~/.cache/flutter_network_mcp  (last resort)
  ///
  /// Linux/other order:
  ///   1. [override]
  ///   2. $GLINT_NETWORK_DATA_DIR
  ///   3. $XDG_DATA_HOME/flutter_network_mcp
  ///   4. ~/.local/share/flutter_network_mcp
  ///   5. ~/.cache/flutter_network_mcp
  ///
  /// On macOS, runs the one-time canonical-path migration before assembling
  /// the list so the renamed dir is found at its new home.
  static List<String> _candidateDataDirs(String? override) {
    if (override != null && override.isNotEmpty) return [override];

    final env = networkEnv;
    final envOverride = env['GLINT_NETWORK_DATA_DIR'];
    if (envOverride != null && envOverride.isNotEmpty) return [envOverride];

    final home = env['HOME'] ?? '.';
    final out = <String>[];

    final xdg = env['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      out.add(p.join(xdg, dataDirName));
    }

    if (Platform.isMacOS) {
      _maybeMigrateMacOsDataDir(home);
      out.add(p.join(home, 'Library', 'Application Support', dataDirName));
      out.add(p.join(home, '.local', 'share', dataDirName));
    } else {
      out.add(p.join(home, '.local', 'share', dataDirName));
    }

    out.add(p.join(home, '.cache', dataDirName));
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
      p.join(home, '.local', 'share', dataDirName),
    );
    final newDirPath = p.join(
      home,
      'Library',
      'Application Support',
      dataDirName,
    );

    final oldDbExists = File(p.join(oldDir.path, 'captures.db')).existsSync();
    final newDbExists = File(p.join(newDirPath, 'captures.db')).existsSync();

    if (!oldDbExists || newDbExists) return;

    try {
      Directory(p.dirname(newDirPath)).createSync(recursive: true);
      oldDir.renameSync(newDirPath);
      stderr.writeln(
        'glint_network: migrated data dir from ${oldDir.path} to '
        '$newDirPath (macOS canonical path; 0.5.16). '
        'Set GLINT_NETWORK_DATA_DIR or --data-dir to override.',
      );
    } catch (e) {
      stderr.writeln(
        'glint_network: tried to migrate ${oldDir.path} to macOS '
        'canonical path but failed ($e); continuing to use old location.',
      );
    }
  }
}

/// The capture database was written by a newer build; an older build must not write to it, or it would corrupt rows the newer code relies on.
class NewerDatabaseError implements Exception {
  NewerDatabaseError({required this.found, required this.supported});

  final int found;
  final int supported;

  @override
  String toString() =>
      'the capture database is at schema v$found, newer than this build '
      'supports (v$supported). A newer glint_network wrote it. Update '
      'this install the way you installed it, or pass --data-dir <other dir> '
      'to use a separate database.';
}
