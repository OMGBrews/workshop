"""Config loader for the audit tracker.

The config declares audit types and the file/directory patterns each type
applies to. It lives in the **consumer** repo at ``docs/work/audits/config.toml``
— whose presence is the tracker's opt-in signal; there is no packaged default.
Stdlib-only on purpose: ``tomllib`` (Python 3.11+) replaces the former PyYAML +
pydantic stack, so the tracker runs under a bare ``python3`` with no venv.
"""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

from .git_utils import NotARepositoryError, repo_root

PathKind = Literal["file", "directory"]
KINDS: tuple[str, ...] = ("file", "directory")

CONFIG_SUBPATH = "docs/work/audits/config.toml"


def default_config_path(repo: Path | None = None) -> Path:
    """The consumer-repo config path: ``<repo>/docs/work/audits/config.toml``."""
    base = repo if repo is not None else repo_root()
    return base / CONFIG_SUBPATH


class ConfigError(Exception):
    """Raised when the audit tracker config cannot be loaded or validated."""


@dataclass(frozen=True)
class TargetRule:
    """Targeting rule scoping an audit to files or directories via include/exclude globs."""

    kind: str
    include: list[str]
    exclude: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        if self.kind not in KINDS:
            raise ConfigError(
                f"target kind must be one of {list(KINDS)}, got {self.kind!r}"
            )
        if not self.include:
            raise ConfigError("target include must list at least one pattern")
        for name, patterns in (("include", self.include), ("exclude", self.exclude)):
            for pattern in patterns:
                if not isinstance(pattern, str) or not pattern:
                    raise ConfigError(
                        f"target {name} patterns must be non-empty strings, "
                        f"got {pattern!r}"
                    )


@dataclass(frozen=True)
class AuditType:
    """A named audit type and the rules that scope it."""

    targets: list[TargetRule]
    description: str = ""

    def __post_init__(self) -> None:
        if not self.targets:
            raise ConfigError("each audit type needs at least one target rule")


@dataclass(frozen=True)
class Config:
    """Root audit tracker configuration: all audit types keyed by name."""

    audit_types: dict[str, AuditType]

    def __post_init__(self) -> None:
        if not self.audit_types:
            raise ConfigError("config must declare at least one audit type")


def _expect(mapping: object, where: str) -> dict[str, object]:
    if not isinstance(mapping, dict):
        raise ConfigError(f"{where} must be a table, got {type(mapping).__name__}")
    return mapping


def _parse_rule(raw: object, where: str) -> TargetRule:
    table = _expect(raw, where)
    unknown = set(table) - {"kind", "include", "exclude"}
    if unknown:
        raise ConfigError(f"{where} has unknown keys: {', '.join(sorted(unknown))}")
    if "kind" not in table or "include" not in table:
        raise ConfigError(f"{where} needs both 'kind' and 'include'")
    include = table["include"]
    exclude = table.get("exclude", [])
    if not isinstance(include, list) or not isinstance(exclude, list):
        raise ConfigError(f"{where}: 'include' and 'exclude' must be arrays of strings")
    return TargetRule(
        kind=table["kind"],  # type: ignore[arg-type]  # validated in __post_init__
        include=include,
        exclude=exclude,
    )


def parse_config(raw: object, source: str) -> Config:
    """Validate an already-parsed TOML document into a :class:`Config`.

    ``source`` names the file for error messages only. Raises ``ConfigError``
    with every problem found, so a hand-edited config fails once, loudly,
    naming each fix.
    """
    errors: list[str] = []
    root = _expect(raw, source)
    unknown_top = set(root) - {"audit_types"}
    if unknown_top:
        errors.append(f"unknown top-level keys: {', '.join(sorted(unknown_top))}")
    types_table = _expect(root.get("audit_types", {}), f"{source}: audit_types")

    audit_types: dict[str, AuditType] = {}
    for type_name, type_raw in types_table.items():
        where = f"{source}: audit_types.{type_name}"
        try:
            table = _expect(type_raw, where)
            unknown = set(table) - {"description", "targets"}
            if unknown:
                raise ConfigError(
                    f"unknown keys: {', '.join(sorted(unknown))}"
                )
            targets_raw = table.get("targets")
            if not isinstance(targets_raw, list) or not targets_raw:
                raise ConfigError("needs a non-empty [[…targets]] array of tables")
            rules = [
                _parse_rule(rule_raw, f"{where}.targets[{i}]")
                for i, rule_raw in enumerate(targets_raw)
            ]
            description = table.get("description", "")
            if not isinstance(description, str):
                raise ConfigError("'description' must be a string")
            audit_types[type_name] = AuditType(targets=rules, description=description)
        except ConfigError as exc:
            errors.append(str(exc))

    if errors:
        raise ConfigError(f"Audit config failed validation: " + "; ".join(errors))
    try:
        return Config(audit_types=audit_types)
    except ConfigError as exc:
        raise ConfigError(f"Audit config failed validation: {exc}") from exc


def load_config(path: Path | None = None) -> Config:
    """Load and validate the audit tracker config from TOML.

    Raises ``ConfigError`` if the file is missing, malformed TOML, or fails
    schema validation, and ``NotARepositoryError`` when the process does not
    run inside a git repository and no explicit path was given.
    """
    resolved = path if path is not None else default_config_path()
    try:
        raw = tomllib.loads(resolved.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ConfigError(f"Audit config not found: {resolved}") from exc
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"Audit config {resolved} is not valid TOML: {exc}") from exc
    try:
        return parse_config(raw, str(resolved))
    except ConfigError as exc:
        raise ConfigError(str(exc)) from exc


def validate_types_have_prompts(config: Config, prompts_dir: Path) -> None:
    """Reject a config naming a type/kind with no shipped prompt file.

    The prompt set under ``prompts/`` defines the closed vocabulary of audit
    types: a repo's config *selects* among shipped types, it does not invent
    them — a per-consumer prompt fork is exactly the drift single-sourcing
    exists to prevent. New types are Workshop contributions (PR + pin bump).
    Raises ``ConfigError`` naming every missing combination.
    """
    missing: list[str] = []
    for type_name in sorted(config.audit_types):
        for rule in sorted(config.audit_types[type_name].targets, key=lambda r: r.kind):
            if not (prompts_dir / f"{type_name}-{rule.kind}.md").exists():
                missing.append(f"{type_name}-{rule.kind}")
    if missing:
        raise ConfigError(
            "config names audit combinations with no shipped prompt file in "
            f"{prompts_dir}: {', '.join(missing)}"
        )


__all__ = [
    "CONFIG_SUBPATH",
    "ConfigError",
    "NotARepositoryError",
    "PathKind",
    "TargetRule",
    "AuditType",
    "default_config_path",
    "load_config",
    "parse_config",
    "validate_types_have_prompts",
]
