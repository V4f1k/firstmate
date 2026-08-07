#!/usr/bin/env bash
# Guard against a CLAUDE.md -> AGENTS.md symlink silently turning into (or being
# replaced by) a regular file or a dangling gap during a worker's own branch
# work, before that state ever reaches a PR.
#
# Root cause this guards against: when a project adopts "CLAUDE.md is a symlink
# to AGENTS.md" as its one-source-of-truth convention, any branch whose history
# predates that adoption still carries the old regular-file CLAUDE.md blob.
# Syncing or merging such a branch against a base that now has the symlink hits
# an ordinary git "distinct types on each side" conflict on that path, and
# resolving that conflict by hand is error-prone: it is easy to `git rm` or
# otherwise drop the file instead of keeping the symlink side. This is not a
# bug in any one tool; it is a routine hazard of merging stale branches, so the
# only reliable catch is a check that runs late enough to see the real result.
#
# Project-agnostic: skips silently (exit 0) whenever the resolved base does not
# manage CLAUDE.md as a symlink, so it is a no-op everywhere except a project
# that has actually made this choice.
#
# Usage: fm-claude-symlink-check.sh [dir] [base-ref]
#   dir       repo or worktree to check (default: .)
#   base-ref  git ref to compare CLAUDE.md against (default: auto-detect the
#             remote-tracking default branch, falling back to a local one)
set -eu

usage() {
  echo "usage: fm-claude-symlink-check.sh [dir] [base-ref]" >&2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -le 2 ] || { usage; exit 1; }

DIR=${1:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)

git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "error: not a git working tree: $DIR" >&2
  exit 1
}

EXPLICIT_BASE=${2:-}

resolve_base() {
  local name b
  if [ -n "$EXPLICIT_BASE" ]; then
    printf '%s\n' "$EXPLICIT_BASE"
    return 0
  fi
  name=$(git -C "$DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  name=${name#origin/}
  if [ -z "$name" ]; then
    for b in main master; do
      if git -C "$DIR" show-ref --verify --quiet "refs/remotes/origin/$b" ||
        git -C "$DIR" show-ref --verify --quiet "refs/heads/$b"; then
        name=$b
        break
      fi
    done
  fi
  [ -n "$name" ] || return 1
  if git -C "$DIR" show-ref --verify --quiet "refs/remotes/origin/$name"; then
    printf 'origin/%s\n' "$name"
    return 0
  fi
  if git -C "$DIR" show-ref --verify --quiet "refs/heads/$name"; then
    printf '%s\n' "$name"
    return 0
  fi
  return 1
}

BASE=$(resolve_base) || {
  echo "skip: cannot determine a base branch to compare CLAUDE.md against in $DIR"
  exit 0
}

# ls-tree output: "<mode> <type> <sha>\t<path>"; empty when the path is absent.
BASE_ENTRY=$(git -C "$DIR" ls-tree "$BASE" -- CLAUDE.md 2>/dev/null || true)
if [ -z "$BASE_ENTRY" ]; then
  echo "skip: $BASE has no CLAUDE.md in $DIR; nothing to guard"
  exit 0
fi
BASE_MODE=$(printf '%s\n' "$BASE_ENTRY" | awk '{print $1}')
BASE_BLOB=$(printf '%s\n' "$BASE_ENTRY" | awk '{print $3}')

if [ "$BASE_MODE" != 120000 ]; then
  echo "skip: CLAUDE.md in $BASE is not a symlink in $DIR (mode $BASE_MODE); nothing to guard"
  exit 0
fi

EXPECTED_TARGET=$(git -C "$DIR" cat-file -p "$BASE_BLOB")

CLAUDE="$DIR/CLAUDE.md"
if [ ! -e "$CLAUDE" ] && [ ! -L "$CLAUDE" ]; then
  echo "error: CLAUDE.md is missing in $DIR, but $BASE manages it as a symlink -> $EXPECTED_TARGET." >&2
  echo "Restore it: git -C '$DIR' checkout $BASE -- CLAUDE.md   (or: ln -sfn $EXPECTED_TARGET '$CLAUDE')" >&2
  exit 1
fi
if [ ! -L "$CLAUDE" ]; then
  echo "error: CLAUDE.md in $DIR is a regular file, but $BASE manages it as a symlink -> $EXPECTED_TARGET." >&2
  echo "This is the classic 'distinct types on each side' merge fallout: a pre-conversion branch clobbered the symlink." >&2
  echo "Restore it: git -C '$DIR' checkout $BASE -- CLAUDE.md   (or: ln -sfn $EXPECTED_TARGET '$CLAUDE')" >&2
  exit 1
fi

ACTUAL_TARGET=$(readlink "$CLAUDE")
if [ "$ACTUAL_TARGET" != "$EXPECTED_TARGET" ]; then
  echo "error: CLAUDE.md in $DIR is a symlink to '$ACTUAL_TARGET', but $BASE expects '$EXPECTED_TARGET'." >&2
  echo "Restore it: git -C '$DIR' checkout $BASE -- CLAUDE.md   (or: ln -sfn $EXPECTED_TARGET '$CLAUDE')" >&2
  exit 1
fi

echo "ok: CLAUDE.md -> $EXPECTED_TARGET matches $BASE in $DIR"
