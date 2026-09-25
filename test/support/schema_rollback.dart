import 'package:sqlite3/sqlite3.dart' as sql;

/// Removes what v13 added, so a fresh DB can stand in for an older one whose later migrations are replayed.
void rollBackV13(sql.Database raw) {
  raw.execute('DROP INDEX IF EXISTS idx_logs_dedup');
  raw.execute('ALTER TABLE log_records DROP COLUMN dedup_key');
  raw.execute('DROP TABLE IF EXISTS session_attachments');
}
