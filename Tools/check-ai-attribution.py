#!/usr/bin/env python3
"""Shared attribution detector and conservative, non-executing PR predicate.

Exit 0: allowed; 1: explicit credit detected; 2: cannot inspect.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ASSISTANT = r'(?:Claude(?:\s+Code)?|Codex|(?:GitHub\s+)?Copilot|Gemini)'
COAUTHOR = re.compile(
    rf'^\s*co-authored-by\s*:\s*(?:{ASSISTANT}(?:\s*<[^>]+>)?|'
    r'[^<>]*<(?:noreply@anthropic\.com|(?:claude|codex|copilot|gemini)(?:\[bot\])?@(?:users\.noreply\.github\.com|openai\.com|anthropic\.com|google\.com))>)\s*$', re.I)
CREDIT = re.compile(
    rf'^\s*(?:[🤖✨]\s*)?(?:generated|written|authored|created|co-authored|assisted)\s+'
    rf'(?:by|with(?:\s+assistance\s+from)?)\s+(?:\[)?{ASSISTANT}'
    r'(?:\]\(https?://[^\s)]+\))?(?:\s*[.!])?\s*$', re.I)


def detected(text):
    return next((line for line in text.splitlines() if COAUTHOR.fullmatch(line) or CREDIT.fullmatch(line)), None)


def enabled(cwd):
    result = subprocess.run(['git', '-C', str(cwd), 'config', '--bool', '--get',
                             'workshop.blockAIAttribution'], capture_output=True, text=True)
    return result.stdout.strip() != 'false'


def check(text, cwd):
    if not enabled(cwd):
        return 0
    line = detected(text)
    if line is None:
        return 0
    print(f'AI attribution refused: {line}\nRemove this assistant credit line and retry; the text has not been changed.')
    return 1


def shell_segments(command):
    """Tokenize literal words while keeping quoted operators as data.

    This is a small supported shell subset, not an evaluator. Expansion and
    unsupported control syntax make the whole input indeterminate.
    """
    segments = [[]]
    word = ''
    started = False
    quote = None
    index = 0
    while index < len(command):
        char = command[index]
        if char in '$`':
            raise ValueError('expansion')
        if quote:
            if char == quote:
                quote = None
            elif char == '\\' and quote == '"':
                index += 1
                if index >= len(command):
                    raise ValueError('escape')
                escaped = command[index]
                word += escaped if escaped in '\\"$`' else '\\' + escaped
            else:
                word += char
        elif char in "\"'":
            quote = char
            started = True
        elif char == '\\':
            index += 1
            if index >= len(command):
                raise ValueError('escape')
            if command[index] != '\n':
                word += command[index]
                started = True
        elif char in ' \t\r\n;&|<>()':
            if started:
                segments[-1].append(word)
                word = ''
                started = False
            if char in ';\n':
                segments.append([])
            elif char == '&' and command[index:index + 2] == '&&':
                segments.append([])
                index += 1
            elif char in '&|<>()':
                raise ValueError('unsupported shell operator')
        elif char == '#' and not started:
            newline = command.find('\n', index)
            index = len(command) if newline < 0 else newline - 1
        else:
            word += char
            started = True
        index += 1
    if quote:
        raise ValueError('unterminated quote')
    if started:
        segments[-1].append(word)
    return segments


def check_command(command, cwd):
    try:
        segments = shell_segments(command)
    except ValueError:
        return 2
    inspected = False
    for args in segments:
        if not args:
            continue
        if args[0] == 'cd' and len(args) == 2:
            cwd = (cwd / args[1]).resolve()
            if not cwd.is_dir():
                return 2
            continue
        if args[:2] == ['gh', '-C']:
            # gh has no Git-style -C flag; do not guess its meaning.
            continue
        if args[:3] not in (['gh', 'pr', 'create'], ['gh', 'pr', 'edit']):
            continue
        texts = []
        index = 3
        while index < len(args):
            arg = args[index]
            key, equal, value = arg.partition('=')
            if len(arg) > 2 and arg[:2] in ('-t', '-b', '-F') and not arg.startswith('--'):
                key, equal, value = arg[:2], '=', arg[2:]
            if key in ('--title', '-t', '--body', '-b', '--body-file', '-F'):
                if not equal:
                    index += 1
                    if index >= len(args):
                        return 2
                    value = args[index]
                if key in ('--body-file', '-F'):
                    if value == '-':
                        return 2
                    try:
                        body_path = cwd / value
                        if not body_path.is_file():
                            return 2
                        value = body_path.read_text()
                    except (OSError, UnicodeError):
                        return 2
                texts.append(value)
            elif key == '--repo' or key.startswith('-R'):
                # Remote selection may target a different policy owner.
                return 2
            index += 1
        for text in texts:
            if check(text, cwd) == 1:
                return 1
        inspected = inspected or bool(texts)
    return 0 if inspected else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['text', 'command', 'claude-hook'])
    parser.add_argument('value', nargs='?')
    parser.add_argument('--cwd', type=Path, default=Path.cwd())
    args = parser.parse_args()
    if args.mode == 'text':
        return check(Path(args.value).read_text() if args.value else sys.stdin.read(), args.cwd)
    if args.mode == 'command':
        return check_command(args.value if args.value is not None else sys.stdin.read(), args.cwd)
    # Claude-specific envelope; malformed inputs/errors deliberately allow.
    try:
        payload = json.load(sys.stdin)
        command = payload.get('tool_input', {}).get('command', '')
        cwd = Path(payload.get('cwd') or args.cwd)
        from contextlib import redirect_stdout
        from io import StringIO
        reason = StringIO()
        with redirect_stdout(reason):
            result = check_command(command, cwd)
        if result == 1:
            print(json.dumps({'hookSpecificOutput': {
                'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                'permissionDecisionReason': reason.getvalue().strip()}}))
    except (ValueError, TypeError, AttributeError, OSError):
        pass
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, UnicodeError) as error:
        print(f'Cannot inspect attribution: {error}', file=sys.stderr)
        sys.exit(2)
