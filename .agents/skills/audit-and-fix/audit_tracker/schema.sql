PRAGMA foreign_keys = ON;

-- Every table carries the repository a row belongs to: `self` for the
-- control repository, or a declared subject's name. Paths are relative to
-- that repository's own root, so identical spellings in two repositories are
-- distinct rows. The default keeps single-repository callers unchanged.
--
-- This cache is derived. db.SCHEMA_VERSION is bumped whenever this file
-- changes shape, and init_schema drops and recreates every table on a
-- mismatch: `CREATE TABLE IF NOT EXISTS` never alters an existing table.

CREATE TABLE IF NOT EXISTS paths (
  repository TEXT NOT NULL DEFAULT 'self',
  path TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('file', 'directory')),
  first_seen_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  PRIMARY KEY (repository, path)
);

CREATE TABLE IF NOT EXISTS path_audit_applicability (
  repository TEXT NOT NULL DEFAULT 'self',
  path TEXT NOT NULL,
  audit_type TEXT NOT NULL,
  PRIMARY KEY (repository, path, audit_type),
  FOREIGN KEY (repository, path) REFERENCES paths(repository, path) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_applicability_type
  ON path_audit_applicability(audit_type, repository);

CREATE TABLE IF NOT EXISTS audits (
  repository TEXT NOT NULL DEFAULT 'self',
  path TEXT NOT NULL,
  audit_type TEXT NOT NULL,
  last_audited_at TEXT NOT NULL,
  last_audit_commit TEXT,
  notes TEXT,
  PRIMARY KEY (repository, path, audit_type),
  FOREIGN KEY (repository, path) REFERENCES paths(repository, path) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_audits_by_type
  ON audits(audit_type, last_audited_at);

-- Compatibility cache for legacy records carrying `pick_counter`. New
-- tracker versions neither create nor advance the counter; the derived table
-- remains so an old records file can be loaded without a schema migration.
CREATE TABLE IF NOT EXISTS audit_type_state (
  repository TEXT NOT NULL DEFAULT 'self',
  audit_type TEXT NOT NULL,
  pick_counter INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (repository, audit_type)
);

-- Derived staleness results. History classification can require a sizeable
-- Git walk, so repeated status/next calls at the same HEAD reuse exact
-- (audit commit, path) counts. Each repository has its own HEAD; rows for an
-- older HEAD of the same repository are pruned on its next query.
CREATE TABLE IF NOT EXISTS staleness_cache (
  repository TEXT NOT NULL DEFAULT 'self',
  head_commit TEXT NOT NULL,
  audit_commit TEXT NOT NULL,
  path TEXT NOT NULL,
  commits_since INTEGER NOT NULL,
  PRIMARY KEY (repository, head_commit, audit_commit, path)
);
