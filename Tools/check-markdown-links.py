#!/usr/bin/env python3
"""Check Markdown policy using one captured working-tree repository view."""

import argparse
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
from repository_view import RepositoryView, ViewError, UnavailableViewError, normalize_link_path

TOOLS = Path(__file__).resolve().parent
SKIP_FILE = '.markdown-links-skip'
# Extractor batches stay well inside every platform's argument-length limit.
BATCH_FILES = 500
BATCH_BYTES = 100_000


def percent_decode(value):
    """Decode path bytes without losing newlines or interpreting an encoded NUL."""
    encoded = os.fsencode(value)
    return os.fsdecode(re.sub(
        rb'%([0-9a-fA-F]{2})',
        lambda match: bytes([int(match[1], 16)]) if match[1] != b'00' else match[0],
        encoded,
    ))


def anchor_reader():
    # Load code from Workshop, never from the repository data being inspected.
    spec = importlib.util.spec_from_file_location('markdown_anchors', TOOLS / 'markdown-anchors.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.anchors


class Checker:
    def __init__(self, view):
        self.view = view
        self.failures = 0
        self.skipped = 0
        self.errors = 0
        self.anchor_cache = {}
        self.collect_anchors = anchor_reader()

    def skip(self, message):
        print(message)
        self.skipped += 1

    def fail(self, message):
        print(message, file=sys.stderr)
        self.failures += 1

    def error(self, message):
        print(message, file=sys.stderr)
        self.errors += 1

    def skip_entries(self):
        if not self.view.exists(SKIP_FILE):
            return []
        if self.view.is_dir(SKIP_FILE):
            raise ViewError(f'{SKIP_FILE}: expected a file')
        entries = []
        for raw in self.view.read_bytes(SKIP_FILE).split(b'\n'):
            entry = os.fsdecode(raw).strip()
            if not entry or entry.startswith('#'):
                continue
            if re.search(r'[\[\]*?]', entry) or entry.startswith('/') or '..' in entry.split('/'):
                raise ViewError(
                    f'{SKIP_FILE}: unsupported entry (no wildcards, absolute paths, or .. segments): {entry}'
                )
            entries.append(entry)
        return entries

    def check_target(self, source, original):
        if re.match(r'^[A-Za-z][A-Za-z0-9+.-]*:', original):
            self.skip(f'skipped URI Markdown link: {source} -> {original}')
            return
        target, separator, raw_fragment = original.partition('#')
        invalid_fragment = bool(re.search(r'%([01][0-9a-fA-F]|7[fF])|[\x00-\x1f\x7f]', raw_fragment))
        fragment = percent_decode(raw_fragment) if separator else ''
        target = target.split('?', 1)[0]
        if target.startswith('/'):
            return
        resolved = normalize_link_path(source, percent_decode(target))
        if resolved == '..' or resolved.startswith('../'):
            self.skip(f'skipped Markdown link escaping repository: {source} -> {original}')
            return
        if any(resolved == mount or resolved.startswith(mount + '/') for mount in self.view.unavailable):
            self.skip(f'skipped Markdown link into unavailable submodule: {source} -> {original}')
            return
        try:
            if not self.view.exists(resolved):
                self.fail(f'broken Markdown link: {source} -> {original}')
                return
            if not fragment and not invalid_fragment:
                return
            if not resolved.endswith(('.md', '.markdown', '.MD')):
                self.skip(f'skipped non-Markdown fragment: {source} -> {original}')
                return
            if invalid_fragment:
                self.fail(f'missing Markdown anchor: {source} -> {original} (control character in fragment)')
                return
            if resolved not in self.anchor_cache:
                try:
                    self.anchor_cache[resolved] = self.collect_anchors(
                        self.view.read_bytes(resolved).decode('utf-8')
                    )
                except Exception as error:
                    self.error(f'anchor parsing failed: {resolved}: {error}')
                    return
            if fragment not in self.anchor_cache[resolved]:
                self.fail(f'missing Markdown anchor: {source} -> {original} (fragment #{fragment})')
        except UnavailableViewError:
            self.skip(f'skipped Markdown link into unavailable submodule: {source} -> {original}')
        except (ViewError, OSError) as error:
            self.error(f'Markdown link evaluation failed: {source} -> {original}: {error}')

    def extract_one(self, path):
        """Scan one source; returns (records or None on error, stderr bytes)."""
        result = subprocess.run(
            ['bash', str(TOOLS / 'rewrite-moved-markdown-links.sh'), '--extract', path],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        if result.returncode:
            return None, result.stderr
        return [record.split(b'\t', 1)[1] for record in result.stdout.split(b'\n') if record], result.stderr

    def extract_all(self, paths):
        """Scan every source with as few extractor processes as possible.

        Results are per path and match extract_one: a batch stops at its first
        unparseable file, which is reported alone, and the scan resumes after it.
        A batch is trusted only when its stderr can be attributed: empty on
        success, or exactly the one diagnostic of the file it stopped at. Any
        other outcome, such as an awk warning about one file's bytes, falls back
        to one process per file so every message stays with its own source.
        """
        results = [None] * len(paths)
        start = 0
        while start < len(paths):
            end, size = start, 0
            while end < len(paths) and end - start < BATCH_FILES and (end == start or size + len(paths[end]) < BATCH_BYTES):
                size += len(paths[end]) + 1
                end += 1
            result = subprocess.run(
                ['bash', str(TOOLS / 'rewrite-moved-markdown-links.sh'), '--extract-batch', *paths[start:end]],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            records = [[] for _ in range(start, end)]
            failed = None
            malformed = False
            for line in result.stdout.split(b'\n'):
                if not line:
                    continue
                fields = line.split(b'\t', 2)
                try:
                    index = int(fields[0]) - 1
                except ValueError:
                    malformed = True
                    break
                if not 0 <= index < end - start:
                    malformed = True
                    break
                if fields[1:] == [b'error']:
                    failed = index
                elif len(fields) == 3:
                    records[index].append(fields[2])
                else:
                    malformed = True
                    break
            if not malformed and result.returncode == 0 and failed is None and not result.stderr:
                for offset, found in enumerate(records):
                    results[start + offset] = (found, b'')
                start = end
            elif (not malformed and result.returncode == 1 and failed is not None
                  and result.stderr.startswith(b'error: ') and result.stderr.count(b'\n') == 1
                  and result.stderr.endswith(b'\n')):
                for offset in range(failed):
                    results[start + offset] = (records[offset], b'')
                results[start + failed] = (None, result.stderr)
                start += failed + 1
            else:
                for offset in range(start, end):
                    results[offset] = self.extract_one(paths[offset])
                start = end
        return results

    def run(self):
        entries = self.skip_entries()
        used = set()
        plan = []
        for source, metadata in sorted(self.view.entries.items()):
            if metadata['owner'] != '' or metadata['kind'] not in ('file', 'symlink') or not source.endswith('.md'):
                continue
            entry = next((entry for entry in entries
                          if (source.startswith(entry) if entry.endswith('/') else source == entry)), None)
            if entry is not None:
                used.add(entry)
                plan.append((source, 'listed'))
            elif metadata['kind'] == 'symlink':
                plan.append((source, 'symlink'))
            else:
                plan.append((source, 'extract'))
        # The shared extractor owns Markdown grammar. Arguments and its bytes
        # remain unmodified even when source filenames contain newlines; absolute
        # paths cannot be read as awk assignments or stdin.
        scanned = [source for source, action in plan if action == 'extract']
        extracted = dict(zip(scanned, self.extract_all(
            [os.path.abspath(self.view.path(source)) for source in scanned])))
        root_prefix = os.fsencode(os.path.abspath(self.view.root) + '/')
        for source, action in plan:
            if action == 'listed':
                self.skip(f'skipped Markdown source (listed in {SKIP_FILE}): {source}')
                continue
            if action == 'symlink':
                self.skip(f'skipped symlink Markdown source: {source}')
                continue
            records, diagnostic = extracted[source]
            if diagnostic:
                # Report original repository-relative names, never temporary roots.
                sys.stderr.write(os.fsdecode(diagnostic.replace(root_prefix, b'')))
            if records is None:
                self.errors += 1
                continue
            for target in records:
                self.check_target(source, os.fsdecode(target))
        for entry in entries:
            if entry not in used:
                self.fail(f'stale {SKIP_FILE} entry matches no visible Markdown source: {entry}')
        if self.errors:
            print(f'{self.errors} Markdown source(s) could not be fully checked (link grammar, anchor parsing, or repository view)', file=sys.stderr)
            return 2
        if self.failures:
            return 1
        print(f'Markdown links valid; {self.skipped} source or target(s) skipped')
        return 0


def main(argv):
    if argv == ['--help'] or argv == ['-h']:
        print('usage: bash Tools/check-markdown-links.sh <repo-root>\n'
              'Check parent-owned Markdown in one working-tree repository view: visible\n'
              'tracked and non-ignored untracked files, excluding unstaged deletions.\n'
              'Populated submodules supply visible targets; unavailable mounts are named skips.\n'
              'Repeat --target-repository RELATIVE_PATH to include ignored independent repositories\n'
              'as targets only; missing roots are errors and their own ignored files stay excluded.\n'
              'Sources, .markdown-links-skip, targets and anchors all use the repository view;\n'
              'target repositories are listed from Git and read only where a link refers.\n'
              'The shared repository_view.py also provides exact-index views for other consumers.\n'
              'Exit 0: valid; 1: broken links, missing anchors or stale skips; 2: evaluation error.\n'
              'See docs/repository-views.md for both modes, isolation and failure semantics.')
        return 0
    parser = argparse.ArgumentParser()
    parser.add_argument('repo_root')
    parser.add_argument('--target-repository', action='append', default=[],
                        help='explicit nested independent repository, used only for link targets')
    args = parser.parse_args(argv)
    try:
        with RepositoryView(args.repo_root, mode='working-tree',
                            target_repositories=tuple(args.target_repository)) as view:
            return Checker(view).run()
    except (ViewError, OSError, UnicodeError) as error:
        print(f'Markdown repository view evaluation failed: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
