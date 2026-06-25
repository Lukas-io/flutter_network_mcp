-- Tier-1 telemetry datapoints: error composition, context cost, degradation.
-- Apply to the already-deployed D1 (schema.sql's CREATE IF NOT EXISTS will not
-- add columns to an existing tool_stats):
--
--   wrangler d1 execute flutter-network-telemetry --remote \
--     --file=migrations/001-tier1-datapoints.sql
--
-- Idempotent-ish: re-running the ALTERs errors if the columns already exist,
-- so run once. The CREATE/INDEX statements are guarded with IF NOT EXISTS.

ALTER TABLE tool_stats ADD COLUMN estimated_tokens INTEGER;
ALTER TABLE tool_stats ADD COLUMN degraded INTEGER;

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
