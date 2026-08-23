"""CLI for the audit tracker: ``python3 .agents/skills/audit-and-fix/tracker.py <cmd>``."""

import argparse
import hashlib
import json
import sqlite3
import sys
from pathlib import Path

from . import git_utils, queries, records
from .config import (
    Config,
    ConfigError,
    KINDS,
    PathKind,
    default_config_path,
    load_config,
    validate_types_have_prompts,
)
from .db import connect, init_schema
from .refresh import refresh

# A repo without the opt-in config gets this dedicated code — never
# conflatable with "no candidates" (0) or a broken tracker (1). The selector
# translates it into its ``not-configured`` outcome; the skill degrades to
# ``--path``-only mode with disclosure.
EXIT_NOT_CONFIGURED = 4


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python3 .agents/skills/audit-and-fix/tracker.py",
        description="Track which files and directories have been audited, when, and against which commit.",
    )
    parser.add_argument(
        "--db",
        type=Path,
        default=None,
        help="SQLite cache path (default: <git-dir>/audit-tracker/cache.sqlite3)",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=None,
        help="Audit config TOML path (default: docs/work/audits/config.toml)",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("refresh", help="Reconcile paths + applicability with git state")
    sub.add_parser("list-types", help="Show configured audit types with counts")

    under_help = (
        "Restrict to the given path and its descendants. Must be repo-relative; "
        "leading './' and trailing '/' are stripped, and absolute paths or '..' "
        "segments are rejected."
    )

    p_next = sub.add_parser("next", help="Print the next path(s) to audit for a type")
    p_next.add_argument("audit_type")
    p_next.add_argument(
        "-n",
        "--limit",
        type=_positive_int,
        default=1,
        help="How many candidates to return (default: 1, must be >= 1)",
    )
    bucket = p_next.add_mutually_exclusive_group()
    bucket.add_argument("--never", action="store_true", help="Only never-audited paths")
    bucket.add_argument(
        "--stale",
        action="store_true",
        help="Only paths changed since their last audit (mutually exclusive with --never)",
    )
    p_next.add_argument(
        "--kind",
        choices=["file", "directory"],
        help="Restrict to files or directories only",
    )
    p_next.add_argument("--under", metavar="PATH", help=under_help)
    p_next.add_argument(
        "--format",
        dest="output_format",
        choices=["text", "json"],
        default="text",
        help="Output format (default: text)",
    )

    p_status = sub.add_parser("status", help="Summary counts for an audit type")
    p_status.add_argument("audit_type")
    p_status.add_argument(
        "--kind",
        choices=["file", "directory"],
        help="Restrict to files or directories only",
    )
    p_status.add_argument("--under", metavar="PATH", help=under_help)

    p_done = sub.add_parser(
        "done",
        help="Record that a path was audited at HEAD (replaces any prior record)",
    )
    p_done.add_argument("path")
    p_done.add_argument("audit_type")
    p_done.add_argument("--commit", help="Override the commit SHA (default: current HEAD)")
    p_done.add_argument("--note", help="Optional free-form note for the audit record")

    p_validate = sub.add_parser(
        "validate-path",
        help="Canonicalize and validate a user-supplied explicit audit path",
    )
    p_validate.add_argument("path")
    p_validate.add_argument("audit_type")
    p_validate.add_argument("--kind", choices=["file", "directory"])
    p_validate.add_argument(
        "--format",
        dest="output_format",
        choices=["text", "json"],
        default="text",
        help="Output format (default: text)",
    )

    return parser


def _positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"expected an integer, got {value!r}") from exc
    if parsed < 1:
        raise argparse.ArgumentTypeError(f"must be >= 1, got {parsed}")
    return parsed


def _cmd_refresh(conn: sqlite3.Connection, cfg: Config) -> int:
    summary = refresh(conn, cfg)
    state = records.read_refresh_state()
    when = state["last_refreshed_at"] if state else "unknown"
    print(
        f"Refreshed at {when}: {summary.total_paths} paths "
        f"(+{summary.added_paths} new, -{summary.removed_paths} removed), "
        f"{summary.applicability_rows} applicability rows across "
        f"{len(cfg.audit_types)} audit types"
    )
    return 0


def _cmd_list_types(conn: sqlite3.Connection, cfg: Config) -> int:
    state = records.read_refresh_state()
    if state is not None:
        commit = state["last_refresh_commit"] or "?"
        print(f"Last refresh: {state['last_refreshed_at']} (commit {commit})")
    else:
        print("Last refresh: never recorded")
    print()
    configured = set(cfg.audit_types)
    known = set(queries.list_types(conn))
    for type_name in sorted(configured | known):
        present = "configured" if type_name in configured else "orphaned"
        stats = queries.status(conn, type_name)
        print(
            f"{type_name:<20}  {present:<11}  "
            f"total={stats.total} audited={stats.audited} never={stats.never} stale={stats.stale}"
        )
    return 0


def _resolve_prefix(raw: str | None) -> str | None:
    if raw is None:
        return None
    return queries.normalize_path_prefix(raw)


def _cmd_next(
    conn: sqlite3.Connection,
    audit_type: str,
    limit: int,
    only_never: bool,
    only_stale: bool,
    kind: PathKind | None,
    under: str | None,
    output_format: str,
) -> int:
    try:
        prefix = _resolve_prefix(under)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 2
    candidates = queries.next_paths(
        conn,
        audit_type,
        limit=limit,
        only_never=only_never,
        only_stale=only_stale,
        kind=kind,
        path_prefix=prefix,
    )
    if not candidates:
        if output_format == "json":
            print(json.dumps({"outcome": "empty", "candidates": []}))
            return 0
        scope = f" under {prefix!r}" if prefix else ""
        print(f"No candidates for {audit_type!r}{scope}.")
        return 0
    if output_format == "json":
        print(
            json.dumps(
                {
                    "outcome": "selected",
                    "candidates": [
                        {
                            "path": c.path,
                            "kind": c.kind,
                            "reason": c.reason,
                            "last_audited_at": c.last_audited_at,
                            "commits_since_audit": c.commits_since_audit,
                        }
                        for c in candidates
                    ],
                }
            )
        )
        return 0
    for c in candidates:
        if c.reason == "never-audited":
            detail = "never audited"
        elif c.reason == "stale":
            detail = f"{c.commits_since_audit} commit(s) since audit at {c.last_audited_at}"
        else:
            detail = f"last audited {c.last_audited_at}"
        print(f"{c.path}\t[{c.kind}]\t{detail}")
    return 0


def _cmd_status(
    conn: sqlite3.Connection,
    audit_type: str,
    kind: PathKind | None,
    under: str | None,
) -> int:
    try:
        prefix = _resolve_prefix(under)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 2
    s = queries.status(conn, audit_type, kind=kind, path_prefix=prefix)
    scope_bits: list[str] = []
    if kind:
        scope_bits.append(f"{'directories' if kind == 'directory' else 'files'} only")
    if prefix:
        scope_bits.append(f"under {prefix}")
    scope = f" ({', '.join(scope_bits)})" if scope_bits else ""
    print(
        f"{s.audit_type}{scope}: total={s.total} audited={s.audited} "
        f"never={s.never} stale={s.stale}"
    )
    return 0


def _cmd_done(
    conn: sqlite3.Connection,
    path: str,
    audit_type: str,
    commit: str | None,
    note: str | None,
) -> int:
    try:
        validated = queries.validate_explicit_path(
            path, conn=conn, audit_type=audit_type
        )
        queries.done(conn, validated.path, audit_type, commit=commit, note=note)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1
    print(f"Marked {validated.path} as audited for {audit_type}.")
    return 0


def _cmd_validate_path(
    path: str,
    audit_type: str,
    kind: PathKind | None,
    output_format: str,
    *,
    conn: sqlite3.Connection | None,
    configured: bool,
) -> int:
    try:
        validated = queries.validate_explicit_path(
            path,
            conn=conn,
            audit_type=audit_type if configured else None,
            expected_kind=kind,
        )
    except ValueError as exc:
        print(f"audit_tracker: {exc}", file=sys.stderr)
        return 2
    prompts_dir = Path(__file__).resolve().parent.parent / "prompts"
    if not (prompts_dir / f"{audit_type}-{validated.kind}.md").is_file():
        print(
            f"audit_tracker: no shipped prompt for {audit_type!r} on {validated.kind}s",
            file=sys.stderr,
        )
        return 2
    if output_format == "json":
        print(
            json.dumps(
                {
                    "outcome": "valid",
                    "path": validated.path,
                    "kind": validated.kind,
                    "audit_type": audit_type,
                    "configured": configured,
                }
            )
        )
    else:
        print(validated.path)
    return 0


def _auto_refresh_reason(
    conn: sqlite3.Connection,
    head: str,
    config_digest: str,
    index_fingerprint: str,
) -> str | None:
    """Return a short reason string when the tracker should auto-refresh
    before serving a command, or ``None`` when the cache is fresh.

    Reasons (cheapest checks first):
    - ``"empty"`` — SQLite cache holds no paths yet (fresh clone / deleted DB)
    - ``"first-run"`` — no refresh state recorded yet (first run in this
      clone, or upgrading from a version that kept it beside the records)
    - ``"head-changed"`` — HEAD moved since the last recorded refresh,
      so the path set may have shifted (adds, deletes, renames)
    """
    if conn.execute("SELECT 1 FROM paths LIMIT 1").fetchone() is None:
        return "empty"
    state = records.read_refresh_state()
    if state is None:
        return "first-run"
    if state["last_refresh_commit"] != head:
        return "head-changed"
    if state.get("config_digest") != config_digest:
        return "config-changed"
    if state.get("index_fingerprint") != index_fingerprint:
        return "index-changed"
    return None


def _config_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _has_shipped_type(audit_type: str) -> bool:
    prompts = Path(__file__).resolve().parent.parent / "prompts"
    return any((prompts / f"{audit_type}-{kind}.md").is_file() for kind in KINDS)


def _record_refresh_inputs(config_digest: str, index_fingerprint: str) -> None:
    state = records.read_refresh_state()
    if state is None:
        return
    records.write_refresh_state(
        last_refreshed_at=state["last_refreshed_at"],
        last_refresh_commit=state["last_refresh_commit"],
        config_digest=config_digest,
        index_fingerprint=index_fingerprint,
    )


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        config_path = args.config or default_config_path()
    except git_utils.NotARepositoryError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    if args.config is None and not config_path.exists():
        notice = f"audit_tracker: not opted in — missing config: {config_path}"
        audit_type = getattr(args, "audit_type", None)
        if audit_type is not None and not _has_shipped_type(audit_type):
            print(
                f"audit_tracker: unknown shipped audit type {audit_type!r}",
                file=sys.stderr,
            )
            return 2
        if args.command == "validate-path":
            return _cmd_validate_path(
                args.path,
                args.audit_type,
                args.kind,
                args.output_format,
                conn=None,
                configured=False,
            )
        print(notice, file=sys.stderr)
        if args.command == "next" and args.output_format == "json":
            print(json.dumps({"outcome": "not-configured"}))
            return 0
        return EXIT_NOT_CONFIGURED
    try:
        cfg = load_config(config_path)
    except ConfigError as exc:
        print(f"audit_tracker: {exc}", file=sys.stderr)
        return 2


    command_audit_type = getattr(args, "audit_type", None)
    if command_audit_type is not None and command_audit_type not in cfg.audit_types:
        print(
            f"audit_tracker: unknown audit type {command_audit_type!r}; configured types: "
            + ", ".join(sorted(cfg.audit_types)),
            file=sys.stderr,
        )
        return 2

    config_digest = _config_digest(config_path)

    # The shipped prompt set is the closed vocabulary of audit types; a
    # config naming a combination with no prompt file is rejected here.
    try:
        validate_types_have_prompts(
            cfg, Path(__file__).resolve().parent.parent / "prompts"
        )
    except ConfigError as exc:
        print(f"audit_tracker: {exc}", file=sys.stderr)
        return 2

    try:
        conn = connect(args.db)
    except git_utils.NotARepositoryError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    try:
        init_schema(conn)
        # The explicit ``refresh`` subcommand will refresh below — no
        # need to do it twice in the same invocation.
        if args.command != "refresh":
            head = git_utils.head_sha()
            index = git_utils.index_fingerprint()
            reason = _auto_refresh_reason(conn, head, config_digest, index)
            if reason is not None:
                print(f"audit_tracker: auto-refresh ({reason})", file=sys.stderr)
                refresh(conn, cfg)
                _record_refresh_inputs(config_digest, git_utils.index_fingerprint())
        # Always reload audit records from the JSON source of truth so
        # manual edits (or text-merge resolutions) are picked up without
        # a separate sync step.
        records.load_into_db(conn)

        if args.command == "refresh":
            result = _cmd_refresh(conn, cfg)
            _record_refresh_inputs(config_digest, git_utils.index_fingerprint())
            return result
        if args.command == "list-types":
            return _cmd_list_types(conn, cfg)
        if args.command == "next":
            return _cmd_next(
                conn,
                args.audit_type,
                args.limit,
                args.never,
                args.stale,
                args.kind,
                args.under,
                args.output_format,
            )
        if args.command == "status":
            return _cmd_status(conn, args.audit_type, args.kind, args.under)
        if args.command == "done":
            return _cmd_done(conn, args.path, args.audit_type, args.commit, args.note)
        if args.command == "validate-path":
            return _cmd_validate_path(
                args.path,
                args.audit_type,
                args.kind,
                args.output_format,
                conn=conn,
                configured=True,
            )
        print(f"Unknown command: {args.command}", file=sys.stderr)
        return 2
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
