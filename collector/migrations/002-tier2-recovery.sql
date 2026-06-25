-- Tier-2 telemetry: outcome-tagged transitions + self-correction effectiveness.
-- Apply to an already-deployed D1, then re-deploy the worker:
--
--   wrangler d1 execute flutter-network-telemetry --remote \
--     --file=migrations/002-tier2-recovery.sql
--   wrangler deploy
--
-- Run the ALTER once (errors if the column already exists). The CREATE/INDEX
-- statements are guarded with IF NOT EXISTS.

ALTER TABLE tool_transitions ADD COLUMN from_outcome TEXT;

CREATE TABLE IF NOT EXISTS tool_self_correction (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  rollup_id    INTEGER NOT NULL,
  machine_hash TEXT,
  tool         TEXT NOT NULL,
  signal       TEXT NOT NULL,
  occurrences  INTEGER,
  recovered    INTEGER,
  FOREIGN KEY (rollup_id) REFERENCES usage_rollups(id)
);
CREATE INDEX IF NOT EXISTS idx_self_correction_tool ON tool_self_correction(tool, signal);
CREATE INDEX IF NOT EXISTS idx_self_correction_rollup ON tool_self_correction(rollup_id);
