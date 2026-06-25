-- flutter_network_mcp telemetry collector: D1 schema.
--
-- One database holds BOTH payload kinds the binary ships:
--   * crash reports  (TelemetryReporter, 0.7.1)         -> crashes
--   * usage rollups  (UsageReporter, 0.8.6, issue #79)  -> usage_rollups
--                                                          + tool_stats
--                                                          + tool_transitions
--
-- Every payload is keyed by machine_hash = HMAC_SHA256(dataDir, public_salt)[:24],
-- a one-way per-install id. No PII, URLs, bodies, or arg values are ever sent.
--
-- Apply with:  wrangler d1 execute flutter-network-telemetry --file=schema.sql

CREATE TABLE IF NOT EXISTS crashes (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  received_at   INTEGER NOT NULL,   -- collector receipt (epoch ms)
  reported_at   TEXT,               -- payload reportedAt (ISO-8601)
  machine_hash  TEXT,
  version       TEXT,
  commit_sha    TEXT,
  is_aot        INTEGER,
  os            TEXT,
  dart          TEXT,
  error_class   TEXT,
  error_message TEXT,
  signature     TEXT,               -- dedupe key: sha256(errorClass + top-3 frames)[:12]
  stack_head    TEXT                -- JSON array of redacted frames
);
CREATE INDEX IF NOT EXISTS idx_crashes_signature ON crashes(signature);
CREATE INDEX IF NOT EXISTS idx_crashes_machine ON crashes(machine_hash);
CREATE INDEX IF NOT EXISTS idx_crashes_version ON crashes(version);

-- One row per shipped usage rollup (the rollup header).
CREATE TABLE IF NOT EXISTS usage_rollups (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  received_at     INTEGER NOT NULL,
  reported_at     TEXT,
  machine_hash    TEXT,
  version         TEXT,
  commit_sha      TEXT,
  is_aot          INTEGER,
  os              TEXT,
  dart            TEXT,
  first_event_ms  INTEGER,
  last_event_ms   INTEGER,
  to_event_id     INTEGER,
  total_events    INTEGER,
  total_turns     INTEGER
);
CREATE INDEX IF NOT EXISTS idx_rollups_machine ON usage_rollups(machine_hash);
CREATE INDEX IF NOT EXISTS idx_rollups_version ON usage_rollups(version);

-- Per-tool aggregates, fanned out from each rollup's tools[]. This is the
-- table you query to answer "how are agents using the tools?".
CREATE TABLE IF NOT EXISTS tool_stats (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  rollup_id         INTEGER NOT NULL,
  machine_hash      TEXT,
  tool              TEXT NOT NULL,
  count             INTEGER,
  ok                INTEGER,
  error             INTEGER,
  empty             INTEGER,
  error_rate        REAL,
  empty_rate        REAL,
  p50_ms            INTEGER,
  p95_ms            INTEGER,
  avg_result_bytes  INTEGER,
  estimated_tokens  INTEGER,   -- total estimated tokens this tool returned (context cost)
  degraded          INTEGER,   -- count of calls that fell back from the primary path
  FOREIGN KEY (rollup_id) REFERENCES usage_rollups(id)
);
CREATE INDEX IF NOT EXISTS idx_tool_stats_tool ON tool_stats(tool);
CREATE INDEX IF NOT EXISTS idx_tool_stats_rollup ON tool_stats(rollup_id);

-- Error composition per tool, fanned out from each rollup tool's errorKinds
-- map. Answers "WHY does this tool error" (bad_argument vs unresponsive_vm vs
-- not_found ...) instead of just how often.
CREATE TABLE IF NOT EXISTS tool_error_kinds (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  rollup_id    INTEGER NOT NULL,
  machine_hash TEXT,
  tool         TEXT NOT NULL,
  error_kind   TEXT NOT NULL,
  count        INTEGER,
  FOREIGN KEY (rollup_id) REFERENCES usage_rollups(id)
);
CREATE INDEX IF NOT EXISTS idx_tool_error_kinds_tool ON tool_error_kinds(tool, error_kind);
CREATE INDEX IF NOT EXISTS idx_tool_error_kinds_rollup ON tool_error_kinds(rollup_id);

-- tool -> next-tool transitions, fanned out from each rollup's transitions[].
-- This is the "what playbook do agents actually follow" table.
CREATE TABLE IF NOT EXISTS tool_transitions (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  rollup_id    INTEGER NOT NULL,
  machine_hash TEXT,
  from_tool    TEXT,
  to_tool      TEXT,
  count        INTEGER,
  FOREIGN KEY (rollup_id) REFERENCES usage_rollups(id)
);
CREATE INDEX IF NOT EXISTS idx_transitions_pair ON tool_transitions(from_tool, to_tool);
CREATE INDEX IF NOT EXISTS idx_transitions_rollup ON tool_transitions(rollup_id);
