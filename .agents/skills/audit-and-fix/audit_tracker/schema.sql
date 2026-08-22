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

-- Per-audit-type rotation state. `pick_counter` is a monotonic integer
-- advanced by done(); next_paths() uses `counter % len(dirs)` to rotate the
-- round-robin starting directory across sessions, so back-to-back audits
-- don't all land in the same parent directory.
CREATE TABLE IF NOT EXISTS audit_type_state (
  audit_type TEXT PRIMARY KEY,
  pick_counter INTEGER NOT NULL DEFAULT 0
);
