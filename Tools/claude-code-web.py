#!/usr/bin/env python3
"""Inspect and validate a repository's Claude Code Web declaration."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


DOCUMENT = Path("docs/work/claude-code-web.md")
BEGIN = "<!-- WORKSHOP-CLOUD-SESSION:BEGIN -->"
END = "<!-- WORKSHOP-CLOUD-SESSION:END -->"
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
ENVIRONMENT_ID = re.compile(r"^env_[A-Za-z0-9]+$")
VARIABLE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
DOMAIN = re.compile(
    r"^(?:\*\.)?(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"
)
SECRET_NAME_COMPONENTS = {"KEY", "TOKEN", "PASSWORD", "PASSWD", "SECRET", "CREDENTIAL", "CREDENTIALS"}


class DeclarationError(ValueError):
    """A user-actionable declaration error."""


def object_without_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DeclarationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def require_exact_keys(
    value: dict[str, Any], required: set[str], context: str, optional: set[str] | None = None
) -> None:
    optional = optional or set()
    missing = sorted(required - value.keys())
    unexpected = sorted(value.keys() - required - optional)
    if missing:
        raise DeclarationError(f"{context}: missing key(s): {', '.join(missing)}")
    if unexpected:
        raise DeclarationError(f"{context}: unexpected key(s): {', '.join(unexpected)}")


def require_string(value: Any, context: str, *, nonempty: bool = True) -> str:
    if not isinstance(value, str):
        raise DeclarationError(f"{context}: expected a string")
    if nonempty and not value.strip():
        raise DeclarationError(f"{context}: expected a non-empty string")
    return value


def require_sorted_unique(values: Any, context: str) -> list[str]:
    if not isinstance(values, list) or any(not isinstance(item, str) for item in values):
        raise DeclarationError(f"{context}: expected an array of strings")
    if values != sorted(values):
        raise DeclarationError(f"{context}: entries must be sorted")
    if len(values) != len(set(values)):
        raise DeclarationError(f"{context}: entries must be unique")
    return values


def extract(document: Path) -> dict[str, Any]:
    try:
        text = document.read_text(encoding="utf-8")
    except FileNotFoundError as error:
        raise DeclarationError(f"missing declaration: {document}") from error
    except (OSError, UnicodeError) as error:
        raise DeclarationError(f"cannot read declaration {document}: {error}") from error

    if text.count(BEGIN) != 1 or text.count(END) != 1:
        raise DeclarationError(
            f"{document}: expected exactly one {BEGIN!r} and one {END!r} sentinel"
        )
    before, remainder = text.split(BEGIN, 1)
    block, after = remainder.split(END, 1)
    if END in before or BEGIN in block or BEGIN in after or END in after:
        raise DeclarationError(f"{document}: declaration sentinels are duplicated or out of order")

    lines = block.strip().splitlines()
    if len(lines) < 3 or lines[0].strip() != "```json" or lines[-1].strip() != "```":
        raise DeclarationError(
            f"{document}: sentinels must contain exactly one fenced ```json block"
        )
    if any(line.strip().startswith("```") for line in lines[1:-1]):
        raise DeclarationError(f"{document}: declaration contains an unexpected code fence")
    payload = "\n".join(lines[1:-1])
    try:
        parsed = json.loads(payload, object_pairs_hook=object_without_duplicates)
    except DeclarationError:
        raise
    except json.JSONDecodeError as error:
        raise DeclarationError(
            f"{document}: invalid JSON at line {error.lineno}, column {error.colno}: {error.msg}"
        ) from error
    if not isinstance(parsed, dict):
        raise DeclarationError(f"{document}: configuration must be a JSON object")
    return parsed


def validate_repository_list(value: Any, context: str) -> list[str]:
    repositories = require_sorted_unique(value, context)
    for repository in repositories:
        if not REPOSITORY.fullmatch(repository):
            raise DeclarationError(f"{context}: invalid owner/repo value: {repository!r}")
    return repositories


def validate_network(value: Any) -> None:
    if not isinstance(value, dict):
        raise DeclarationError("environment.network: expected an object")
    require_exact_keys(
        value,
        {"access", "includeCommonPackageManagers", "allowedDomains"},
        "environment.network",
    )
    if value["access"] not in {"none", "trusted", "full", "custom"}:
        raise DeclarationError(
            "environment.network.access: expected none, trusted, full, or custom"
        )
    if not isinstance(value["includeCommonPackageManagers"], bool):
        raise DeclarationError("environment.network.includeCommonPackageManagers: expected a boolean")
    domains = require_sorted_unique(value["allowedDomains"], "environment.network.allowedDomains")
    for domain in domains:
        if not DOMAIN.fullmatch(domain):
            raise DeclarationError(
                "environment.network.allowedDomains: expected bare DNS names, got " + repr(domain)
            )
    if value["access"] != "custom" and domains:
        raise DeclarationError(
            "environment.network.allowedDomains: entries are only valid when access is custom"
        )


def validate_variables(value: Any) -> None:
    if not isinstance(value, list):
        raise DeclarationError("environment.environmentVariables: expected an array")
    names: list[str] = []
    for index, variable in enumerate(value):
        context = f"environment.environmentVariables[{index}]"
        if not isinstance(variable, dict):
            raise DeclarationError(f"{context}: expected an object")
        source = variable.get("source")
        if source == "literal":
            require_exact_keys(
                variable,
                {"name", "source", "value"},
                context,
                {"nonSecretJustification"},
            )
            require_string(variable["value"], f"{context}.value", nonempty=False)
        elif source == "secret":
            require_exact_keys(variable, {"name", "source", "required"}, context)
            if not isinstance(variable["required"], bool):
                raise DeclarationError(f"{context}.required: expected a boolean")
        else:
            raise DeclarationError(f"{context}.source: expected literal or secret")
        name = require_string(variable["name"], f"{context}.name")
        if not VARIABLE.fullmatch(name):
            raise DeclarationError(f"{context}.name: invalid environment-variable name: {name!r}")
        components = set(name.upper().split("_"))
        suspicious = bool(components & SECRET_NAME_COMPONENTS) or name.upper().endswith(
            ("_B64", "_BASE64")
        )
        justification = variable.get("nonSecretJustification")
        if suspicious and source == "literal":
            if justification is None:
                raise DeclarationError(
                    f"{context}: secret-bearing name {name!r} cannot use source literal without "
                    "nonSecretJustification"
                )
            require_string(justification, f"{context}.nonSecretJustification")
        elif justification is not None:
            raise DeclarationError(
                f"{context}.nonSecretJustification: allowed only for a literal with a "
                "secret-bearing name"
            )
        names.append(name)
    if names != sorted(names):
        raise DeclarationError("environment.environmentVariables: entries must be sorted by name")
    if len(names) != len(set(names)):
        raise DeclarationError("environment.environmentVariables: names must be unique")


def validate_environment(value: Any) -> None:
    if not isinstance(value, dict):
        raise DeclarationError("environment: expected an object")
    require_exact_keys(
        value,
        {"name", "id", "network", "environmentVariables", "setupScript"},
        "environment",
    )
    require_string(value["name"], "environment.name")
    environment_id = require_string(value["id"], "environment.id")
    if not ENVIRONMENT_ID.fullmatch(environment_id):
        raise DeclarationError("environment.id: expected an ID beginning with env_")
    validate_network(value["network"])
    validate_variables(value["environmentVariables"])
    setup = value["setupScript"]
    if not isinstance(setup, list) or any(not isinstance(line, str) for line in setup):
        raise DeclarationError("environment.setupScript: expected an array of strings")
    if any("\n" in line or "\r" in line for line in setup):
        raise DeclarationError("environment.setupScript: each array item must be exactly one line")


def read_settings(root: Path) -> dict[str, Any] | None:
    path = root / ".claude/settings.json"
    if not path.exists():
        return None
    try:
        parsed = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=object_without_duplicates)
    except DeclarationError as error:
        raise DeclarationError(f"{path}: {error}") from error
    except json.JSONDecodeError as error:
        raise DeclarationError(f"{path}: invalid JSON: {error.msg}") from error
    except (OSError, UnicodeError) as error:
        raise DeclarationError(f"cannot read {path}: {error}") from error
    if not isinstance(parsed, dict):
        raise DeclarationError(f"{path}: expected a JSON object")
    return parsed


def default_environment_id(settings: dict[str, Any] | None, root: Path) -> str | None:
    if settings is None:
        return None
    remote = settings.get("remote")
    if remote is None:
        return None
    if not isinstance(remote, dict):
        raise DeclarationError(f"{root / '.claude/settings.json'}: remote must be an object")
    value = remote.get("defaultEnvironmentId")
    if value is not None and not isinstance(value, str):
        raise DeclarationError(
            f"{root / '.claude/settings.json'}: remote.defaultEnvironmentId must be a string"
        )
    return value


def validate(root: Path) -> dict[str, Any]:
    config = extract(root / DOCUMENT)
    require_exact_keys(
        config,
        {"version", "availability", "primaryRepository", "additionalRepositories"},
        "configuration",
        {"environment", "reason"},
    )
    if config["version"] != 1 or isinstance(config["version"], bool):
        raise DeclarationError("configuration.version: only version 1 is supported")
    availability = config["availability"]
    if availability not in {"configured", "not-configured", "unsupported"}:
        raise DeclarationError(
            "configuration.availability: expected configured, not-configured, or unsupported"
        )
    primary = require_string(config["primaryRepository"], "configuration.primaryRepository")
    if not REPOSITORY.fullmatch(primary):
        raise DeclarationError("configuration.primaryRepository: expected owner/repo")
    additional = validate_repository_list(
        config["additionalRepositories"], "configuration.additionalRepositories"
    )
    if primary in additional:
        raise DeclarationError(
            "configuration.additionalRepositories: must not repeat primaryRepository"
        )

    settings_id = default_environment_id(read_settings(root), root)
    if availability == "configured":
        if "environment" not in config:
            raise DeclarationError("configuration: configured availability requires environment")
        if "reason" in config:
            raise DeclarationError("configuration: configured availability forbids reason")
        validate_environment(config["environment"])
        declared_id = config["environment"]["id"]
        if settings_id is None:
            raise DeclarationError(
                ".claude/settings.json must declare remote.defaultEnvironmentId for a configured environment"
            )
        if settings_id != declared_id:
            raise DeclarationError(
                ".claude/settings.json remote.defaultEnvironmentId does not match environment.id "
                f"({settings_id!r} != {declared_id!r})"
            )
    else:
        if "reason" not in config:
            raise DeclarationError(f"configuration: {availability} availability requires reason")
        require_string(config["reason"], "configuration.reason")
        if "environment" in config:
            raise DeclarationError(f"configuration: {availability} availability forbids environment")
        if settings_id is not None:
            raise DeclarationError(
                ".claude/settings.json remote.defaultEnvironmentId contradicts "
                f"availability {availability}"
            )
    return config


def show(config: dict[str, Any]) -> None:
    print(f"Availability: {config['availability']}")
    print(f"Primary repository: {config['primaryRepository']}")
    additional = config["additionalRepositories"]
    print("Additional repositories: " + (", ".join(additional) if additional else "none"))
    if config["availability"] != "configured":
        print(f"Reason: {config['reason']}")
        return
    environment = config["environment"]
    network = environment["network"]
    print(f"Environment: {environment['name']}")
    print(f"Environment ID: {environment['id']}")
    print(f"Network access: {network['access']}")
    print(
        "Common package-manager domains: "
        + ("included" if network["includeCommonPackageManagers"] else "not included")
    )
    print(
        "Allowed domains: "
        + (", ".join(network["allowedDomains"]) if network["allowedDomains"] else "none")
    )
    variables = environment["environmentVariables"]
    print("Environment variables: " + (", ".join(item["name"] for item in variables) if variables else "none"))
    print(f"Setup script lines: {len(environment['setupScript'])}")


def repository_root(value: str) -> Path:
    root = Path(value).expanduser().resolve()
    if not root.is_dir():
        raise DeclarationError(f"repository root is not a directory: {root}")
    return root


def checkout_repository(root: Path) -> str:
    try:
        top = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        origin = subprocess.run(
            ["git", "-C", str(root), "remote", "get-url", "origin"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise DeclarationError(f"cannot resolve Git origin for repository root {root}") from error
    if Path(top).resolve() != root:
        raise DeclarationError(f"not the Git worktree root: {root}")
    patterns = (
        r"^https?://github\.com/([^/]+/[^/]+?)(?:\.git)?$",
        r"^git@github\.com:([^/]+/[^/]+?)(?:\.git)?$",
        r"^ssh://git@github\.com/([^/]+/[^/]+?)(?:\.git)?$",
    )
    for pattern in patterns:
        match = re.fullmatch(pattern, origin)
        if match:
            return match.group(1)
    raise DeclarationError(f"origin is not a supported GitHub repository URL: {origin!r}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate and inspect docs/work/claude-code-web.md"
    )
    parser.add_argument("command", choices=("validate", "show", "render-setup"))
    parser.add_argument("repository", help="repository root containing docs/work/claude-code-web.md")
    parser.add_argument(
        "--json",
        action="store_true",
        help="with show, emit the validated declaration as normalized JSON",
    )
    args = parser.parse_args(argv)
    if args.json and args.command != "show":
        parser.error("--json is valid only with show")
    try:
        root = repository_root(args.repository)
        config = validate(root)
        actual_repository = checkout_repository(root)
        if config["primaryRepository"] != actual_repository:
            raise DeclarationError(
                "configuration.primaryRepository does not match the checkout origin "
                f"({config['primaryRepository']!r} != {actual_repository!r})"
            )
        if args.command == "validate":
            print(f"ok: {root / DOCUMENT}")
        elif args.command == "show":
            if args.json:
                print(json.dumps(config, indent=2, sort_keys=True))
            else:
                show(config)
        elif config["availability"] != "configured":
            raise DeclarationError(
                f"cannot render a setup script when availability is {config['availability']}"
            )
        else:
            lines = config["environment"]["setupScript"]
            if lines:
                sys.stdout.write("\n".join(lines) + "\n")
        return 0
    except DeclarationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
