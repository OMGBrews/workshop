PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS paths (
  path TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('file', 'directory')),
  first_seen_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS path_audit_applicability (
  path TEXT NOT NULL REFERENCES paths(path) ON DELETE CASCADE,
  audit_type TEXT NOT NULL,
  PRIMARY KEY (path, audit_type)
);

CREATE INDEX IF NOT EXISTS idx_applicability_type
  ON path_audit_applicability(audit_type);

CREATE TABLE IF NOT EXISTS audits (
  path TEXT NOT NULL REFERENCES paths(path) ON DELETE CASCADE,
  audit_type TEXT NOT NULL,
  last_audited_at TEXT NOT NULL,
  last_audit_commit TEXT,
  notes TEXT,
  PRIMARY KEY (path, audit_type)
);

CREATE INDEX IF NOT EXISTS idx_audits_by_type
  ON audits(audit_type, last_audited_at);

-- Compatibility cache for legacy records carrying `pick_counter`. New
-- tracker versions neither create nor advance the counter; the derived table
-- remains so an old records file can be loaded without a schema migration.
CREATE TABLE IF NOT EXISTS audit_type_state (
  audit_type TEXT PRIMARY KEY,
  pick_counter INTEGER NOT NULL DEFAULT 0
);

-- Derived staleness results. History classification can require a sizeable
-- Git walk, so repeated status/next calls at the same HEAD reuse exact
-- (audit commit, path) counts. Old HEAD rows are pruned on the next query.
CREATE TABLE IF NOT EXISTS staleness_cache (
  head_commit TEXT NOT NULL,
  audit_commit TEXT NOT NULL,
  path TEXT NOT NULL,
  commits_since INTEGER NOT NULL,
  PRIMARY KEY (head_commit, audit_commit, path)
);
