// Schema for the captures database.
//
// Bump [currentVersion] when changing this file and add a migration block in
// the migration switch in database.dart.

const int currentVersion = 6;

const List<String> initialSchema = [
  '''
  CREATE TABLE sessions (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at    INTEGER NOT NULL,
    ended_at      INTEGER,
    app_name      TEXT,
    vm_service_uri TEXT,
    isolate_id    TEXT,
    project_path  TEXT,
    note          TEXT
  )
  ''',
  '''
  CREATE TABLE http_requests (
    session_id            INTEGER NOT NULL,
    vm_id                 TEXT NOT NULL,
    isolate_id            TEXT,
    method                TEXT,
    url                   TEXT,
    host                  TEXT,
    path                  TEXT,
    status_code           INTEGER,
    reason_phrase         TEXT,
    start_us              INTEGER,
    end_us                INTEGER,
    duration_us           INTEGER,
    request_size          INTEGER,
    response_size         INTEGER,
    content_type          TEXT,
    request_headers_json  TEXT,
    response_headers_json TEXT,
    has_error             INTEGER NOT NULL DEFAULT 0,
    bodies_fetched        INTEGER NOT NULL DEFAULT 0,
    body_fetch_attempts   INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (session_id, vm_id),
    FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
  )
  ''',
  '''
  CREATE TABLE http_bodies (
    session_id INTEGER NOT NULL,
    vm_id      TEXT NOT NULL,
    which      TEXT NOT NULL,
    bytes      BLOB,
    size       INTEGER,
    PRIMARY KEY (session_id, vm_id, which),
    FOREIGN KEY (session_id, vm_id)
      REFERENCES http_requests(session_id, vm_id) ON DELETE CASCADE
  )
  ''',
  '''
  CREATE TABLE socket_events (
    session_id     INTEGER NOT NULL,
    vm_id          TEXT NOT NULL,
    isolate_id     TEXT,
    socket_type    TEXT,
    address        TEXT,
    port           INTEGER,
    start_us       INTEGER,
    end_us         INTEGER,
    last_read_us   INTEGER,
    last_write_us  INTEGER,
    read_bytes     INTEGER,
    write_bytes    INTEGER,
    PRIMARY KEY (session_id, vm_id),
    FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
  )
  ''',
  '''
  CREATE TABLE log_records (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id   INTEGER NOT NULL,
    isolate_id   TEXT,
    timestamp_ms INTEGER,
    source       TEXT,
    level        INTEGER,
    logger       TEXT,
    message      TEXT,
    error        TEXT,
    stack_trace  TEXT,
    FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
  )
  ''',
  '''
  CREATE TABLE alerts (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id        INTEGER NOT NULL,
    ts_ms             INTEGER NOT NULL,
    severity          TEXT NOT NULL,
    kind              TEXT NOT NULL,
    title             TEXT NOT NULL,
    detail            TEXT,
    source_kind       TEXT,
    source_id         TEXT,
    signature         TEXT,
    occurrence_count  INTEGER NOT NULL DEFAULT 1,
    last_seen_ms      INTEGER,
    last_source_id    TEXT,
    drained           INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
    UNIQUE(session_id, kind, source_id)
  )
  ''',
  '''
  CREATE UNIQUE INDEX idx_alerts_pending_signature
    ON alerts(session_id, signature)
    WHERE drained = 0 AND signature IS NOT NULL
  ''',
  '''
  CREATE TABLE ignored_hosts (
    host      TEXT PRIMARY KEY,
    added_at  INTEGER NOT NULL,
    reason    TEXT
  )
  ''',
  '''
  CREATE VIRTUAL TABLE http_search USING fts5(
    url, content_request, content_response,
    tokenize='unicode61'
  )
  ''',
  '''
  CREATE TABLE http_search_map (
    rowid       INTEGER PRIMARY KEY,
    session_id  INTEGER NOT NULL,
    vm_id       TEXT NOT NULL,
    isolate_id  TEXT,
    UNIQUE(session_id, vm_id)
  )
  ''',
  'CREATE INDEX idx_http_session_start ON http_requests(session_id, start_us)',
  'CREATE INDEX idx_http_host ON http_requests(host)',
  'CREATE INDEX idx_http_status ON http_requests(status_code)',
  'CREATE INDEX idx_http_isolate ON http_requests(session_id, isolate_id)',
  'CREATE INDEX idx_socket_session_start ON socket_events(session_id, start_us)',
  'CREATE INDEX idx_logs_session_time ON log_records(session_id, timestamp_ms)',
  'CREATE INDEX idx_logs_level ON log_records(level)',
  'CREATE INDEX idx_logs_isolate ON log_records(session_id, isolate_id)',
  'CREATE INDEX idx_alerts_drained ON alerts(drained, severity, ts_ms)',
  '''
  CREATE TABLE redacted_headers (
    name      TEXT PRIMARY KEY,
    added_at  INTEGER NOT NULL,
    reason    TEXT
  )
  ''',
  '''
  CREATE TABLE alert_patterns (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    kind      TEXT NOT NULL,
    regex     TEXT NOT NULL,
    severity  TEXT NOT NULL,
    label     TEXT,
    added_at  INTEGER NOT NULL
  )
  ''',
];

/// SQL statements to apply when upgrading from v1 → v2.
const List<String> migrationV1toV2 = [
  '''
  CREATE TABLE IF NOT EXISTS alerts (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id   INTEGER NOT NULL,
    ts_ms        INTEGER NOT NULL,
    severity     TEXT NOT NULL,
    kind         TEXT NOT NULL,
    title        TEXT NOT NULL,
    detail       TEXT,
    source_kind  TEXT,
    source_id    TEXT,
    drained      INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE,
    UNIQUE(session_id, kind, source_id)
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS ignored_hosts (
    host      TEXT PRIMARY KEY,
    added_at  INTEGER NOT NULL,
    reason    TEXT
  )
  ''',
  '''
  CREATE VIRTUAL TABLE IF NOT EXISTS http_search USING fts5(
    url, content_request, content_response,
    tokenize='unicode61'
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS http_search_map (
    rowid       INTEGER PRIMARY KEY,
    session_id  INTEGER NOT NULL,
    vm_id       TEXT NOT NULL,
    UNIQUE(session_id, vm_id)
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_alerts_drained ON alerts(drained, severity, ts_ms)',
];

/// v2 → v3: configurability tables (redacted_headers, alert_patterns).
const List<String> migrationV2toV3 = [
  '''
  CREATE TABLE IF NOT EXISTS redacted_headers (
    name      TEXT PRIMARY KEY,
    added_at  INTEGER NOT NULL,
    reason    TEXT
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS alert_patterns (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    kind      TEXT NOT NULL,
    regex     TEXT NOT NULL,
    severity  TEXT NOT NULL,
    label     TEXT,
    added_at  INTEGER NOT NULL
  )
  ''',
];

/// v3 → v4: per-row `isolate_id` so multi-isolate captures can be filtered.
/// Nullable column on each table that records VM activity — pre-v4 rows keep
/// NULL (treated as "VM-level" / "pre-multi-isolate"). Adds covering indexes
/// for the per-session-per-isolate query pattern.
const List<String> migrationV3toV4 = [
  'ALTER TABLE http_requests ADD COLUMN isolate_id TEXT',
  'ALTER TABLE socket_events ADD COLUMN isolate_id TEXT',
  'ALTER TABLE log_records ADD COLUMN isolate_id TEXT',
  'ALTER TABLE http_search_map ADD COLUMN isolate_id TEXT',
  'CREATE INDEX IF NOT EXISTS idx_http_isolate ON http_requests(session_id, isolate_id)',
  'CREATE INDEX IF NOT EXISTS idx_logs_isolate ON log_records(session_id, isolate_id)',
];

/// v4 → v5: alert deduplication by signature. Collapses N events with the
/// same underlying issue into one row with `occurrence_count`, advancing
/// `last_seen_ms` + `last_source_id` instead of inserting a new row.
///
/// Backfill: existing rows get `signature = NULL` (we don't try to
/// recompute for old data — they drain through the same path as fresh
/// rows, just without a dedup key). `last_seen_ms` defaults to `ts_ms`
/// for legacy rows so the new field is always populated. The partial
/// unique index applies only to `signature IS NOT NULL`, so legacy NULLs
/// don't trip on the constraint.
const List<String> migrationV4toV5 = [
  'ALTER TABLE alerts ADD COLUMN signature TEXT',
  'ALTER TABLE alerts ADD COLUMN occurrence_count INTEGER NOT NULL DEFAULT 1',
  'ALTER TABLE alerts ADD COLUMN last_seen_ms INTEGER',
  'ALTER TABLE alerts ADD COLUMN last_source_id TEXT',
  'UPDATE alerts SET last_seen_ms = ts_ms WHERE last_seen_ms IS NULL',
  '''
  CREATE UNIQUE INDEX idx_alerts_pending_signature
    ON alerts(session_id, signature)
    WHERE drained = 0 AND signature IS NOT NULL
  ''',
];

/// v5 → v6: body-backfill retry counter. The capture writer used to skip
/// body/search backfill for any request whose `end_us` was NULL; the
/// response was never marked complete by the dart:io profiler, which is
/// common for chunked / gzip streamed responses. That stranded their bodies
/// forever, so `network_get` returned `response: null` and `network_search`
/// could not see the payload.
///
/// v6 lets the writer also attempt backfill for response-incomplete-but-stale
/// requests, capped by `body_fetch_attempts` so genuinely body-less or
/// transport-invisible requests stop being re-polled. Existing rows default
/// to 0 attempts and re-enter the backfill path on the next tick.
const List<String> migrationV5toV6 = [
  'ALTER TABLE http_requests ADD COLUMN body_fetch_attempts INTEGER NOT NULL DEFAULT 0',
];
