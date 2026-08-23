#!/usr/bin/env bash
#
# migrate-kaizen-journal.sh — one-time conversion of a repo's kaizen documents
# from the single-file layout to the directory layout.
#
#   docs/work/kaizen/journal.md   ->  docs/work/kaizen/journal/YYYY-MM/YYYY-MM-DD-<slug>.md
#   docs/work/kaizen/patterns.md  ->  docs/work/kaizen/patterns/<slug>.md
#
# One entry per file. A journal grows forever, and a single file eventually
# costs every reader — human or agent — the whole history to read one lesson.
# Month directories keep any one listing browsable (~30 entries/month), and
# per-file entries end the merge contention that prepend-at-top created between
# concurrent sessions.
#
# Usage:
#   migrate-kaizen-journal.sh [REPO_ROOT]     (default: cwd)
#
# Contract:
#   1. Entries are located by heading — `## YYYY-MM-DD — <title>` (em dash) —
#      that is NOT inside an HTML comment. File order is not trusted: journals
#      acquire out-of-order tails from merges and bulk backfills, so each entry
#      is filed by the date in its own heading. Everything before the first
#      entry heading (title, intro, and the template comment that itself
#      contains a specimen heading) is preamble, and is discarded.
#   2. Each entry becomes journal/YYYY-MM/YYYY-MM-DD-<slug>.md. The heading is
#      rewritten to `# <title>` — the date lives in the filename — and body
#      bytes are preserved with trailing blank lines trimmed, except that
#      supported relative Markdown link targets are rebased to the same resolved
#      destination. A tool that relocates a document owns that rebasing.
#   3. Slug: the title after the first " — ", lowercased, every run of
#      non-[a-z0-9] bytes replaced by "-", collapsed, edge-trimmed, and
#      truncated to 60 bytes at a hyphen boundary. An empty result becomes
#      "entry". Slugging runs under LC_ALL=C so multibyte punctuation degrades
#      to hyphen runs that collapse away.
#   4. Every entry in every document is parsed and staged under a temporary
#      directory BEFORE anything is written into the repo. A `## ` line outside
#      an HTML comment that does not match the entry-heading shape aborts the
#      run: nothing is moved, the source files are left untouched, exit
#      non-zero. Silently dropping an unrecognized entry would destroy it.
#   5. A staged entry whose target already exists byte-identical is skipped, so
#      a re-run after an interrupted move converges. A target that exists with
#      DIFFERENT content gets a -2, -3, ... suffix; that is also how two
#      same-day entries with identical slugs are separated.
#   6. Asserted before any source file is deleted: entries parsed == entries
#      written + skipped-identical. The count is the check that no entry was
#      lost between staging and placement.
#   7. patterns.md is split the same way on `## <name>` headings (no date). A
#      patterns.md holding only the commented format specimen yields just the
#      empty directory.
#   8. Both directories get a minimal README.md (the filename convention and a
#      pointer to ../README.md) unless one already exists. This is also what
#      makes an empty patterns/ trackable by git, and it makes a migrated repo
#      converge with one freshly scaffolded by /kaizen-init.
#   9. Source files are deleted once their entries are placed — git keeps the
#      history, and leaving them would give the next writer two plausible homes.
#  10. Idempotent: a document whose file is gone and whose directory exists is
#      reported as already migrated (exit 0). If NEITHER document has a file or
#      a directory, this is not a kaizen repo — exit non-zero.

set -euo pipefail

REPO_ROOT="${1:-$PWD}"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REWRITER="$SCRIPT_DIR/rewrite-moved-markdown-links.sh"

err() { printf 'error: %s\n' "$1" >&2; exit 1; }

# ---- locate the kaizen root -------------------------------------------
KAIZEN_REL="docs/work/kaizen"
if [[ ! -d "$REPO_ROOT/$KAIZEN_REL" ]]; then
  err "no kaizen directory ($KAIZEN_REL) under $REPO_ROOT — not a kaizen repo"
fi
KAIZEN_DIR="$REPO_ROOT/$KAIZEN_REL"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

migrated=0 skipped_identical=0 already=0

# ---- split one document into staged per-entry bodies + a manifest ----
# Writes <stage>/NNNN.body and <stage>/manifest.tsv (NNNN \t date \t title).
# require_date=1 enforces the journal's dated-heading shape (contract 4).
split_doc() { # <src> <stage_subdir> <require_date:0|1>
  local src="$1" out="$2" require_date="$3"
  mkdir -p "$out"
  : > "$out/manifest.tsv"
  LC_ALL=C awk -v stage="$out" -v require_date="$require_date" -v src="$src" '
    function flush(   i, f) {
      if (idx == 0) return
      while (n > 0 && body[n] ~ /^[ \t]*$/) n--
      f = sprintf("%s/%04d.body", stage, idx)
      print "# " etitle > f          # the date moves to the filename
      for (i = 1; i <= n; i++) print body[i] > f
      close(f)
      printf "%04d\t%s\t%s\n", idx, edate, etitle > (stage "/manifest.tsv")
      n = 0
    }
    {
      # Comment state is tracked per line and consulted only for heading
      # detection, so a comment inside an entry body survives verbatim.
      was_in_comment = in_comment
      if (in_comment) { if ($0 ~ /-->/) in_comment = 0 }
      else if ($0 ~ /<!--/ && $0 !~ /-->/) in_comment = 1

      if (!was_in_comment && $0 ~ /^## /) {
        if (require_date && $0 !~ /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] — /) {
          printf "error: %s:%d: heading is not `## YYYY-MM-DD — title`: %s\n", \
            src, NR, $0 > "/dev/stderr"
          aborted = 1
          exit 3
        }
        flush()
        idx++
        if (require_date) {
          edate = substr($0, 4, 10)
          etitle = substr($0, 19)   # "## " + 10-byte date + " — " (5 bytes)
        } else {
          edate = ""
          etitle = substr($0, 4)
        }
        next
      }
      if (idx > 0) body[++n] = $0
    }
    END { if (!aborted) flush() }
  ' "$src"
}

# ---- slug rule (contract 3) ----
slugify() { # <title> -> prints slug
  local s cut
  s="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9' '-')"
  s="$(printf '%s' "$s" | LC_ALL=C sed -E 's/-+/-/g; s/^-//; s/-$//')"
  if (( ${#s} > 60 )); then
    if [[ "${s:60:1}" == "-" ]]; then
      s="${s:0:60}"                  # the 60-byte cut already lands on a boundary
    else
      cut="${s:0:60}"
      [[ "$cut" == *-* ]] && cut="${cut%-*}"
      s="$cut"
    fi
    s="$(printf '%s' "$s" | LC_ALL=C sed -E 's/-+$//')"
  fi
  [[ -n "$s" ]] || s="entry"
  printf '%s' "$s"
}

# ---- place a staged body, resolving collisions (contract 5) ----
place() { # <staged_body> <target_dir> <basename_without_ext> <title>
  local staged="$1" dir="$2" base="$3" title="$4" target n
  mkdir -p "$dir"
  target="$dir/$base.md"
  if [[ -e "$target" ]]; then
    if cmp -s "$staged" "$target"; then
      echo "skip    ${target#"$REPO_ROOT/"} (already present, identical)"
      skipped_identical=$((skipped_identical + 1))
      return 0
    fi
    n=2
    while [[ -e "$dir/$base-$n.md" ]]; do
      if cmp -s "$staged" "$dir/$base-$n.md"; then
        echo "skip    ${dir#"$REPO_ROOT/"}/$base-$n.md (already present, identical)"
        skipped_identical=$((skipped_identical + 1))
        return 0
      fi
      n=$((n + 1))
    done
    target="$dir/$base-$n.md"
  fi
  mv "$staged" "$target"
  echo "migrate ${target#"$REPO_ROOT/"} — $title"
  migrated=$((migrated + 1))
}

write_readme() { # <dir> <heredoc-marker-body-via-stdin>
  local dir="$1"
  mkdir -p "$dir"
  if [[ -e "$dir/README.md" ]]; then
    cat > /dev/null           # drain stdin so the caller's heredoc has a reader
    echo "skip    ${dir#"$REPO_ROOT/"}/README.md (already present)"
  else
    cat > "$dir/README.md"
    echo "create  ${dir#"$REPO_ROOT/"}/README.md"
  fi
}

# ---- decide what there is to do (contract 10) ----
journal_md="$KAIZEN_DIR/journal.md"
patterns_md="$KAIZEN_DIR/patterns.md"
journal_dir="$KAIZEN_DIR/journal"
patterns_dir="$KAIZEN_DIR/patterns"

do_journal=0 do_patterns=0
if [[ -f "$journal_md" ]]; then
  do_journal=1
elif [[ -d "$journal_dir" ]]; then
  echo "already $KAIZEN_REL/journal/ (no journal.md to convert)"
  already=$((already + 1))
fi
if [[ -f "$patterns_md" ]]; then
  do_patterns=1
elif [[ -d "$patterns_dir" ]]; then
  echo "already $KAIZEN_REL/patterns/ (no patterns.md to convert)"
  already=$((already + 1))
fi

if (( do_journal == 0 && do_patterns == 0 && already == 0 )); then
  err "$KAIZEN_REL has neither journal.md/patterns.md nor journal/patterns directories — nothing to migrate"
fi

# ---- parse everything before writing anything (contract 4) ----
journal_entries=0 pattern_entries=0
if (( do_journal )); then
  split_doc "$journal_md" "$STAGE/journal" 1 \
    || err "refused to migrate: $KAIZEN_REL/journal.md has a heading this script cannot file; nothing was moved"
  journal_entries="$(wc -l < "$STAGE/journal/manifest.tsv")"
fi
if (( do_patterns )); then
  split_doc "$patterns_md" "$STAGE/patterns" 0 \
    || err "refused to migrate: $KAIZEN_REL/patterns.md could not be split; nothing was moved"
  pattern_entries="$(wc -l < "$STAGE/patterns/manifest.tsv")"
fi

# Split a manifest line by hand rather than with `read -r a b c`: tab is IFS
# *whitespace*, so read collapses the two tabs of an empty date field and the
# date variable swallows the title.
read_manifest_line() { # <line> -> sets m_idx, m_date, m_title
  local line="$1" rest
  m_idx="${line%%$'\t'*}"; rest="${line#*$'\t'}"
  m_date="${rest%%$'\t'*}"; m_title="${rest#*$'\t'}"
}

# Link rebasing is deliberately complete before the first repository write.
# The helper is located beside this migrator, not from the consumer's CWD:
# /kaizen-init invokes this mounted tool while CWD remains the consumer root.
if (( do_journal )); then
  while IFS= read -r line; do
    read_manifest_line "$line"
    bash "$REWRITER" "$REPO_ROOT" "$KAIZEN_REL/journal.md" \
      "$KAIZEN_REL/journal/${m_date:0:7}/$m_date-$(slugify "$m_title").md" \
      "$STAGE/journal/$m_idx.body"
  done < "$STAGE/journal/manifest.tsv"
fi
if (( do_patterns )); then
  while IFS= read -r line; do
    read_manifest_line "$line"
    bash "$REWRITER" "$REPO_ROOT" "$KAIZEN_REL/patterns.md" \
      "$KAIZEN_REL/patterns/$(slugify "$m_title").md" "$STAGE/patterns/$m_idx.body"
  done < "$STAGE/patterns/manifest.tsv"
fi

# ---- write ----

if (( do_journal )); then
  while IFS= read -r line; do
    read_manifest_line "$line"
    place "$STAGE/journal/$m_idx.body" "$journal_dir/${m_date:0:7}" \
      "$m_date-$(slugify "$m_title")" "$m_title"
  done < "$STAGE/journal/manifest.tsv"

  placed=$((migrated + skipped_identical))
  (( placed == journal_entries )) \
    || err "post-condition failed: parsed $journal_entries journal entries but placed $placed — journal.md left in place"

  write_readme "$journal_dir" <<'EOF'
# Kaizen journal

One entry per file: `YYYY-MM/YYYY-MM-DD-<slug>.md`. There is no index — `ls` is the
index, and `grep -h '^# ' */*.md` lists every title.

Entry format, when to write, and the scope boundary: [`../README.md`](../README.md).
EOF

  rm -f "$journal_md"
  echo "remove  $KAIZEN_REL/journal.md ($journal_entries entries relocated)"
fi

if (( do_patterns )); then
  before=$((migrated + skipped_identical))
  while IFS= read -r line; do
    read_manifest_line "$line"      # patterns carry no date; m_date is empty
    place "$STAGE/patterns/$m_idx.body" "$patterns_dir" "$(slugify "$m_title")" "$m_title"
  done < "$STAGE/patterns/manifest.tsv"

  placed=$((migrated + skipped_identical - before))
  (( placed == pattern_entries )) \
    || err "post-condition failed: parsed $pattern_entries patterns but placed $placed — patterns.md left in place"

  write_readme "$patterns_dir" <<'EOF'
# Kaizen patterns

One pattern per file: `<slug>.md`. Write one when two or more journal entries share a
root cause; delete it when its rule graduates into a standard — git keeps the history.

Pattern format and the review cadence: [`../README.md`](../README.md).
EOF

  rm -f "$patterns_md"
  echo "remove  $KAIZEN_REL/patterns.md ($pattern_entries patterns relocated)"
fi

echo
echo "migrated $migrated, skipped $skipped_identical, already-migrated $already"
