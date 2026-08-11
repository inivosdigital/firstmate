#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<default> after fetching
# the default branch, and local-only projects against the local default branch.
# When state/<id>.meta records pr= (URL or number) for an open PR, the compare
# side is ALWAYS a freshly fetched refs/pull/<n>/head by default so review stays
# current after no-mistakes fix rounds push to the PR. A recorded pr_head= is
# only a fallback when fetch fails (stale recorded SHAs must never win over a
# reachable remote PR head). If neither PR head can be resolved, fall back to
# the local branch with a warning. Without pr=, compare the local branch.
# Usage: fm-review-diff.sh <task-id> [--stat|--identity]
#   --stat prints only the stat summary; default prints stat summary plus full diff.
#   --identity prints, NUL-delimited, the CANONICAL content identity of that same comparison for
#     a caller that needs to tell "the code changed" from "the rendering
#     changed": one `git diff-tree -r` raw line per changed path, naming the
#     before/after blob object ids. It shares this script's base and compare
#     resolution - so a gate and a human are always talking about the same two
#     commits - but not its rendering, because the rendered diff is a display
#     artifact. `.gitattributes` can bind a path to a textconv or external diff
#     driver, which is ordinary in projects holding notebooks, generated files
#     or binary formats, and that makes changed content render identically. Raw
#     object ids move whenever the committed bytes move, whatever the driver
#     shows a reader.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-review-diff.sh <task-id> [--stat|--identity]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ID=${1:-}
[ -n "$ID" ] || { usage; exit 1; }
MODE=full
case "${2:-}" in
  '') ;;
  --stat) MODE=stat ;;
  --identity) MODE=identity ;;
  *) usage; exit 1 ;;
esac
[ $# -le 2 ] || { usage; exit 1; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
[ -n "$WT" ] || { echo "error: meta for task $ID is missing worktree=" >&2; exit 1; }
[ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree for task $ID is missing: $WT" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

BRANCH="fm/$ID"
if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || { echo "error: branch fm/$ID does not exist and worktree $WT is detached" >&2; exit 1; }
  git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $WT" >&2; exit 1; }
fi

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fetch_pull_head() {
  local n=$1 resolved
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  # Fetch into a private ref so a later base-branch fetch cannot clobber the
  # compare tip via FETCH_HEAD, and so we never review a stale local object.
  git -C "$WT" fetch --quiet origin \
    "+refs/pull/$n/head:refs/fm-review/pull/$n/head" >/dev/null 2>&1 || return 1
  resolved=$(git -C "$WT" rev-parse --verify "refs/fm-review/pull/$n/head^{commit}" 2>/dev/null) || return 1
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
}

resolve_pr_head() {
  local pr_url=$1 recorded_head=$2 n resolved
  n=$(pr_number_from_target "$pr_url") || true
  if [ -n "$n" ]; then
    if resolved=$(fetch_pull_head "$n"); then
      printf '%s' "$resolved"
      return 0
    fi
  fi
  # Offline / unreachable remote: recorded pr_head is better than the local
  # branch, but never preferred over a successful pull-head fetch above. It is
  # still only the head recorded when the PR was first seen, so it can lag every
  # fix round pushed since. Say so on stderr rather than returning it as though
  # it were a resolved head: a caller that gates on the diff being current
  # cannot otherwise tell this fallback apart from a fresh fetch, and reading it
  # as fresh is how unreviewed PR commits slip past such a gate.
  if [ -n "$recorded_head" ] \
    && git -C "$WT" cat-file -e "$recorded_head^{commit}" 2>/dev/null; then
    echo "warning: PR head not freshly resolved; using the recorded pr_head $recorded_head, which may lag the open PR" >&2
    printf '%s' "$recorded_head"
    return 0
  fi
  return 1
}

PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
COMPARE_REF=$BRANCH
if [ -n "$PR_URL" ]; then
  if PR_HEAD=$(resolve_pr_head "$PR_URL" "$PR_HEAD_RECORDED"); then
    COMPARE_REF=$PR_HEAD
  else
    echo "warning: PR head unavailable; diff may lag the open PR (using local branch $BRANCH)" >&2
  fi
fi

if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  # Update the remote-tracking ref itself; a bare single-branch fetch can leave
  # origin/<default> stale on some Git versions and only refresh FETCH_HEAD.
  git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet
  BASE="origin/$DEFAULT"
else
  BASE="$DEFAULT"
fi

BASE_COMMIT=$(git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}") || { echo "error: base $BASE does not exist in $WT" >&2; exit 1; }
COMPARE_COMMIT=$(git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}") || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }

if [ "$MODE" = identity ]; then
  # Both sides are pinned to the commits resolved above rather than re-resolved,
  # so the identity cannot describe a different comparison from the one the
  # warnings on stderr were about. The merge base makes this the two-dot
  # equivalent of the three-dot form rendered below, so an unrelated commit
  # landing on the base branch does not move the identity.
  MERGE_BASE=$(git -C "$WT" merge-base "$BASE_COMMIT" "$COMPARE_COMMIT") \
    || { echo "error: no merge base between $BASE and $COMPARE_REF in $WT" >&2; exit 1; }
  # Rename detection off: it is a heuristic whose answer can change with
  # unrelated content, and the raw pairs already carry every changed path.
  # -z is load-bearing, not a style choice: without it raw output renders paths
  # through core.quotePath, so flipping one local config setting changes this
  # output for a non-ASCII path while the commit tree is byte-for-byte
  # identical - a caller gating on it would refuse work nobody touched. -z
  # emits paths verbatim between NULs, identical under either setting, and
  # sidesteps the quoting of control characters too. Output is therefore
  # NUL-delimited binary: read it as bytes, never through a shell variable,
  # which silently drops NULs and would let a path run into the next record.
  git -C "$WT" diff-tree -r --no-renames --no-ext-diff -z "$MERGE_BASE" "$COMPARE_COMMIT" --
  exit 0
fi

echo "diff base: $BASE"
if git -C "$WT" diff --quiet "$BASE...$COMPARE_REF" --; then
  echo "no changes vs $BASE"
  exit 0
fi

git -C "$WT" diff --stat "$BASE...$COMPARE_REF" --
if [ "$MODE" != stat ]; then
  echo
  git -C "$WT" diff "$BASE...$COMPARE_REF" --
fi
