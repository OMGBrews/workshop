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

# GitHub remote spellings, shared by the checkout identity check and the
# `.gitmodules` reader below.
GITHUB_URL_PATTERNS = (
    r"^https?://github\.com/([^/]+/[^/]+?)(?:\.git)?$",
    r"^git@github\.com:([^/]+/[^/]+?)(?:\.git)?$",
    r"^ssh://git@github\.com/([^/]+/[^/]+?)(?:\.git)?$",
)

# Both public spellings of the Workshop remote. The repository was transferred
# from OMGBrewmaster to OMGBrews; GitHub redirects the old URL, so most
# consumers still record it verbatim and are normalized only at their next
# pointer bump. Accepting the new spelling alone would exempt every one of them
# from the kit requirement below — and an exemption nobody can see is the exact
# failure this check exists to prevent.
WORKSHOP_REPOSITORIES = frozenset({"OMGBrews/workshop", "OMGBrewmaster/workshop"})

# The standard cloud-session bootstrap kit: deployed copy -> canonical template,
# relative to the repository root and the Workshop mount respectively.
BOOTSTRAP_KIT = (
    ("scripts/agent/session-start.sh", "docs/templates/cloud-sessions/agent-session-start.sh"),
    (".claude/hooks/session-start.sh", "docs/templates/cloud-sessions/session-start.sh"),
)
KIT_MARKER = "docs/templates/cloud-sessions/agent-session-start.sh"
SESSION_START_COMMAND = '"$CLAUDE_PROJECT_DIR"/.claude/hooks/session-start.sh'
SESSION_START_TIMEOUT = 120


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


def validate_setup_script(value: dict[str, Any], root: Path, primary: str) -> None:
    """Require the fleet's versioned, absolute-path setup-script stub."""
    setup = value["setupScript"]
    if not setup:
        return
    repository = primary.rsplit("/", 1)[1]
    header = f"# {repository} setup stub — v"
    if len(setup) != 5 or not setup[1].startswith(header):
        raise DeclarationError("environment.setupScript: expected the canonical five-line setup stub")
    version = setup[1][len(header) :].split(".", 1)[0]
    if not version.isdecimal() or int(version) < 1:
        raise DeclarationError("environment.setupScript: stub version must be a positive integer")
    expected = [
        "#!/bin/bash",
        f"# {repository} setup stub — v{version}. Real script: scripts/agent/cloud-setup.sh in the repo.",
        "# Bump the version above to force a cache rebuild after editing that script.",
        "set -euo pipefail",
        f"bash /home/user/{repository}/scripts/agent/cloud-setup.sh",
    ]
    if setup != expected:
        raise DeclarationError("environment.setupScript: expected the canonical five-line setup stub")
    script = root / "scripts/agent/cloud-setup.sh"
    if not script.is_file() or not script.stat().st_mode & 0o111:
        raise DeclarationError(
            "environment.setupScript: scripts/agent/cloud-setup.sh must exist and be executable"
        )


def github_repository(url: str) -> str | None:
    """`owner/repo` for a GitHub remote URL, or None when it is not one."""
    for pattern in GITHUB_URL_PATTERNS:
        match = re.fullmatch(pattern, url)
        if match:
            return match.group(1)
    return None


def declared_submodules(root: Path) -> dict[str, str]:
    """Every `.gitmodules` edge, as declared path -> declared URL.

    Read lexically, from the committed declaration alone. Nothing here touches
    the working tree, so an edge whose mount was never initialized is still
    seen — which is the whole point: the failure this check exists for looks
    from the working tree exactly like a repository that mounts nothing.
    """
    modules = root / ".gitmodules"
    if not modules.is_file():
        return {}
    try:
        listing = subprocess.run(
            [
                "git",
                "config",
                "--file",
                str(modules),
                "--get-regexp",
                r"^submodule\..*\.(path|url)$",
            ],
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise DeclarationError(f"cannot read {modules}: {error}") from error
    # 1 is "no matches"; anything above it is a real failure to read the file,
    # and reporting that as "declares no submodules" would exempt the
    # repository from the kit requirement without saying so.
    if listing.returncode > 1:
        detail = listing.stderr.strip() or f"git config exited {listing.returncode}"
        raise DeclarationError(f"cannot read {modules}: {detail}")
    paths: dict[str, str] = {}
    urls: dict[str, str] = {}
    for line in listing.stdout.splitlines():
        key, _, value = line.partition(" ")
        name, _, field = key.rpartition(".")
        name = name[len("submodule.") :]
        if field == "path":
            paths[name] = value
        elif field == "url":
            urls[name] = value
    return {paths[name]: url for name, url in urls.items() if name in paths}


def workshop_mount(root: Path) -> str | None:
    """The path `.gitmodules` declares for the Workshop submodule, if any."""
    for path, url in sorted(declared_submodules(root).items()):
        if github_repository(url) in WORKSHOP_REPOSITORIES:
            return path
    return None


def validate_session_start_registration(settings: dict[str, Any] | None, primary: str) -> None:
    """Require a complete canonical `SessionStart` hook object for the wrapper.

    Presence on disk is not adoption. The skill and hook registries are built
    once per session from what settings declare, so an executable wrapper that
    nothing registers never runs and leaves no trace that it did not.
    """
    remedy = (
        "Fix: merge the hooks key from "
        "<workshop mount>/docs/templates/cloud-sessions/settings-hooks.json into "
        ".claude/settings.json, keeping the project's other keys."
    )
    matches: list[dict[str, Any]] = []
    hooks = (settings or {}).get("hooks")
    entries = hooks.get("SessionStart") if isinstance(hooks, dict) else None
    for group in entries if isinstance(entries, list) else []:
        if not isinstance(group, dict):
            continue
        group_hooks = group.get("hooks")
        for hook in group_hooks if isinstance(group_hooks, list) else []:
            if isinstance(hook, dict) and hook.get("command") == SESSION_START_COMMAND:
                matches.append(hook)
    if not matches:
        raise DeclarationError(
            f"{primary}: .claude/settings.json registers no SessionStart hook running the "
            f"standard bootstrap wrapper ({SESSION_START_COMMAND}), so the deployed kit "
            f"never runs. {remedy}"
        )
    # Other hook objects, other events, and the rest of settings are none of
    # this check's business: standard adoption constrains the Workshop
    # bootstrap entry, not the rest of a project's session preparation.
    for hook in matches:
        if hook.get("type") == "command" and hook.get("timeout") == SESSION_START_TIMEOUT:
            return
    hook = matches[0]
    if hook.get("type") != "command":
        raise DeclarationError(
            f"{primary}: .claude/settings.json registers the standard bootstrap wrapper with "
            f"type {hook.get('type')!r}; the canonical hook object declares type \"command\". "
            f"{remedy}"
        )
    raise DeclarationError(
        f"{primary}: .claude/settings.json registers the standard bootstrap wrapper with "
        f"timeout {hook.get('timeout')!r}; the canonical hook object declares timeout "
        f"{SESSION_START_TIMEOUT}. {remedy}"
    )


def validate_bootstrap_kit(root: Path, settings: dict[str, Any] | None, primary: str) -> None:
    """Require the complete standard bootstrap kit of a Workshop consumer.

    Applies when a `configured` repository declares the public Workshop
    submodule. Three edges are checked together because each is separately
    satisfiable while the bootstrap still never runs: both deployed scripts
    matching their canonical templates byte-for-byte, both executable, and the
    wrapper registered as a complete `SessionStart` hook object. A repository
    whose agent surfaces link into Workshop while nothing bootstraps it starts
    every session with those links dangling and nothing printed to say so.
    """
    mount = workshop_mount(root)
    if mount is None:
        return
    if not (root / mount / KIT_MARKER).is_file():
        raise DeclarationError(
            f"{primary}: .gitmodules declares the Workshop submodule at {mount!r}, but that "
            f"mount is not initialized ({mount}/{KIT_MARKER} is absent), so the standard "
            "bootstrap kit cannot be checked and every agent surface linked into it dangles. "
            f"Fix: git submodule update --init {mount}"
        )
    for deployed, template in BOOTSTRAP_KIT:
        copy = root / deployed
        canonical = root / mount / template
        redeploy = f"Fix: cp {mount}/{template} {deployed} && chmod +x {deployed}"
        if not canonical.is_file():
            raise DeclarationError(
                f"{primary}: the pinned Workshop checkout at {mount!r} carries no "
                f"{template} to check {deployed} against — the pin predates the standard "
                "bootstrap kit. Fix: advance the Workshop pointer, then redeploy both kit files."
            )
        if not copy.is_file():
            raise DeclarationError(
                f"{primary}: standard bootstrap kit incomplete — {deployed} is absent while "
                f"the repository mounts Workshop at {mount!r}. {redeploy}"
            )
        if not copy.stat().st_mode & 0o111:
            raise DeclarationError(
                f"{primary}: standard bootstrap kit — {deployed} is not executable, so the "
                f"session bootstrap cannot run. Fix: chmod +x {deployed}"
            )
        if copy.read_bytes() != canonical.read_bytes():
            raise DeclarationError(
                f"{primary}: standard bootstrap kit — {deployed} differs from its canonical "
                f"template {mount}/{template}. The template is canonical: upstream a "
                f"deliberate change there first, then redeploy. {redeploy}"
            )
    validate_session_start_registration(settings, primary)


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

    settings = read_settings(root)
    settings_id = default_environment_id(settings, root)
    if availability == "configured":
        if "environment" not in config:
            raise DeclarationError("configuration: configured availability requires environment")
        if "reason" in config:
            raise DeclarationError("configuration: configured availability forbids reason")
        validate_environment(config["environment"])
        validate_setup_script(config["environment"], root, primary)
        validate_bootstrap_kit(root, settings, primary)
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
    repository = github_repository(origin)
    if repository is None:
        raise DeclarationError(f"origin is not a supported GitHub repository URL: {origin!r}")
    return repository


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
