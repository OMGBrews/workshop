#!/usr/bin/env python3
"""Launch native Claude with per-process exclusions for ancestor standing rules.

Install as `claude` in a separate directory before the native CLI on PATH.
No checkout or user settings are written. The native installer and updater keep
owning their original executable. Python 3.11+ and git are required.
"""

import json
import os
from pathlib import Path
import subprocess
import sys


RULES = {
    "signal-hygiene": "# Signal hygiene",
    "definition-of-done": "# Definition of done",
    "verification-terminology": "# Verification terminology",
}


def native_cli():
    """Skip every PATH spelling of this shim, including symlink aliases."""
    own = Path(__file__).resolve()
    for directory in os.get_exec_path():
        candidate = Path(directory or ".") / "claude"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            if candidate.resolve() != own:
                return str(candidate.absolute())
    raise ValueError("native claude executable missing after the launcher on PATH")


def standing_link(root, name):
    link = root / ".claude" / "rules" / (name + ".md")
    if not link.is_symlink():
        return False
    # Match the generator's one-component mount contract. Never suppress a
    # real topic file or an arbitrary user symlink sharing the same basename.
    target = os.readlink(link)
    parts = target.split("/")
    direct = parts == ["..", "..", "docs", name + ".md"]
    mounted = (
        len(parts) == 5 and parts[:2] == ["..", ".."]
        and parts[2] not in {"", ".", "..", "docs"}
        and parts[3:] == ["docs", name + ".md"]
    )
    if not (direct or mounted):
        return False
    try:
        with link.open() as stream:
            return stream.readline().rstrip("\r\n") == RULES[name]
    except (OSError, UnicodeError):
        return False


def ancestor_exclusions(cwd):
    result = subprocess.run(
        ["git", "-C", str(cwd), "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode:
        return []
    root = Path(result.stdout.strip()).resolve()
    own = [name for name in RULES if standing_link(root, name)]
    excludes = []
    for ancestor in root.parents:
        for name in own:
            if standing_link(ancestor, name):
                path = str(ancestor / ".claude" / "rules" / (name + ".md"))
                # claudeMdExcludes uses globs even for exact paths.
                # Claude normalizes backslashes in paths, so backslash escapes
                # do not protect literal glob characters. Character classes
                # survive that normalization (verified with live /context).
                literal = {"[": "[[]", "*": "[*]", "?": "[?]",
                           "{": "[{]", "}": "[}]", "(": "[(]", ")": "[)]"}
                if "\\" in path:
                    raise ValueError("ancestor rule path contains an unsupported backslash: " + path)
                excludes.append("".join(literal.get(c, c) for c in path))
    return excludes


def launch_arguments(arguments, excludes):
    if not excludes:
        return arguments
    remaining = []
    settings = None
    index = 0
    while index < len(arguments):
        arg = arguments[index]
        if arg == "--":
            remaining.extend(arguments[index:])
            break
        if arg == "--settings":
            index += 1
            if index == len(arguments):
                raise ValueError("--settings requires a file path or JSON object")
            settings = arguments[index]
        elif arg.startswith("--settings="):
            settings = arg.split("=", 1)[1]
        else:
            remaining.append(arg)
        index += 1
    # Native Claude uses the last --settings value. Preserve that object's
    # keys, including explicit exclusions; other settings layers remain native.
    merged = {}
    if settings is not None:
        if settings.lstrip().startswith("{"):
            merged = json.loads(settings)
        else:
            merged = json.loads(Path(settings).read_text())
        if not isinstance(merged, dict):
            raise ValueError("--settings must contain a JSON object")
    existing = merged.get("claudeMdExcludes", [])
    if not isinstance(existing, list) or not all(isinstance(p, str) for p in existing):
        raise ValueError("claudeMdExcludes must be an array of strings")
    merged["claudeMdExcludes"] = list(dict.fromkeys(existing + excludes))
    # Prepend so a caller's `--` continues to delimit the positional prompt.
    return ["--settings", json.dumps(merged), *remaining]


def main():
    try:
        binary = native_cli()
        args = sys.argv[1:]
        # Maintenance commands must reach the native installer unchanged.
        commands = {
            "auth", "update", "upgrade", "install", "doctor", "mcp", "plugin",
            "plugins", "setup-token", "agents", "attach", "logs", "rm", "stop",
            "kill", "respawn", "purge", "gateway", "import", "auto-mode",
            "ultrareview", "remote-control",
        }
        options = args[:args.index("--")] if "--" in args else args
        if not (args and args[0] in commands) and not any(
            arg in {
                "--version", "-v", "--help", "-h", "--bare", "--safe-mode",
                "--cloud", "--teleport", "--environment", "--desktop",
            }
            for arg in (option.split("=", 1)[0] for option in options)
        ):
            args = launch_arguments(args, ancestor_exclusions(Path.cwd()))
        os.execv(binary, [binary, *args])
    except (OSError, ValueError) as error:
        print(f"claude launcher: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
