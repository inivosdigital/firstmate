#!/usr/bin/env bash
# Escalation-trigger guard for the trivial (Haiku/low) dispatch tier: mechanically
# checks whether a task's actual diff size or elapsed time has outgrown the
# resource envelope its assigned model/effort tier implies, so under-resourcing
# is never caught by the crewmate's own self-report alone (guardrail #1,
# data/research-resource-tiering-synthesis.md). Read-only: never edits meta,
# the worktree, or the branch.
#
# Usage: fm-tier-guard.sh <task-id>
#
# Reads state/<task-id>.meta for model=/effort=, and that file's own mtime as a
# best-effort spawn-time proxy for the age check - NOT authoritative. A later
# append to meta (bin/fm-pr-check.sh recording pr=/pr_head=, or fm-x-link
# recording X-mode fields) resets the mtime, so a long-running task can read as
# younger than it is and slip the age ceiling; the diff size/file ceilings are
# the primary signal and are unaffected by that reset. Reuses
# bin/fm-review-diff.sh --stat for the actual diff size instead of re-deriving
# the authoritative base/PR-head resolution here.
#
# Prints one "ESCALATE: <reason>" line per triggered condition. Exit codes:
#   0  within the tier's envelope (silent)
#   1  at least one escalation fired
#   2  usage or setup error (bad args, missing meta, or fm-review-diff failed)
# Distinct codes let a caller branching on $? tell a real escalation from a
# malformed invocation, matching the sibling guardrail bin/fm-risk-tripwire.sh.
# Only the trivial (Haiku/low) tier has a size/age ceiling checked here; every
# other tier is covered only by the general, tier-independent ceiling below.
# On an escalation, bump the task's model/effort in place per AGENTS.md
# section 7's Validate step; never silently de-escalate afterward.
#
# Env overrides (starting points from
# data/scout-nomistakes-tiering-t8/report.md section 3, not yet calibrated
# against this fleet's own diff-size history):
#   FM_TIER_TRIVIAL_MAX_LINES        default 30
#   FM_TIER_TRIVIAL_MAX_FILES        default 2
#   FM_TIER_TRIVIAL_MAX_AGE_SECONDS  default 1800 (30 minutes)
#   FM_TIER_HEAVY_MIN_LINES          default 400
#   FM_TIER_HEAVY_MIN_FILES          default 8
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

TRIVIAL_MAX_LINES=${FM_TIER_TRIVIAL_MAX_LINES:-30}
TRIVIAL_MAX_FILES=${FM_TIER_TRIVIAL_MAX_FILES:-2}
TRIVIAL_MAX_AGE=${FM_TIER_TRIVIAL_MAX_AGE_SECONDS:-1800}
HEAVY_MIN_LINES=${FM_TIER_HEAVY_MIN_LINES:-400}
HEAVY_MIN_FILES=${FM_TIER_HEAVY_MIN_FILES:-8}

usage() {
  echo "usage: fm-tier-guard.sh <task-id>" >&2
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

ID=${1:-}
[ -n "$ID" ] || { usage; exit 2; }
[ $# -le 1 ] || { usage; exit 2; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 2; }

MODEL=$(grep '^model=' "$META" | tail -1 | cut -d= -f2- || true)
EFFORT=$(grep '^effort=' "$META" | tail -1 | cut -d= -f2- || true)

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c (mirrors
# bin/fm-supervision-lib.sh's fm_sup_stat_mtime; not sourced from there to keep
# this script's only dependency on that library's actual contract-bearing
# function, fm_supervision_status, out of scope here).
tier_guard_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

is_trivial_tier() {
  case "$MODEL" in
    *haiku*) [ "$EFFORT" = low ] && return 0 ;;
  esac
  return 1
}

STAT_ERR=$(mktemp)
STAT_OUT=$("$SCRIPT_DIR/fm-review-diff.sh" "$ID" --stat 2>"$STAT_ERR") || {
  echo "error: fm-review-diff.sh failed for $ID" >&2
  rm -f "$STAT_ERR"
  exit 2
}
# fm-review-diff.sh still exits 0 but warns when it cannot resolve an open PR's
# head and falls back to the possibly-stale local branch, so the size measured
# below may under-count the real PR diff. Blanket-discarding that warning (the
# 2>/dev/null this replaces) made a degraded read indistinguishable from an
# authoritative one - the dangerous under-report direction for this guardrail.
# Detect only that specific marker (not all of fm-review-diff.sh's stderr, which
# also carries fm-guard.sh's supervision banner) and surface it below.
DIFF_MAY_LAG_PR=0
if grep -q 'PR head unavailable' "$STAT_ERR"; then
  DIFF_MAY_LAG_PR=1
fi
rm -f "$STAT_ERR"

FILES=0
LINES=0
if ! printf '%s\n' "$STAT_OUT" | grep -q '^no changes vs'; then
  FILES=$(printf '%s\n' "$STAT_OUT" | grep -oE '[0-9]+ files? changed' | grep -oE '^[0-9]+' || true)
  INS=$(printf '%s\n' "$STAT_OUT" | grep -oE '[0-9]+ insertions?\(\+\)' | grep -oE '^[0-9]+' || true)
  DEL=$(printf '%s\n' "$STAT_OUT" | grep -oE '[0-9]+ deletions?\(-\)' | grep -oE '^[0-9]+' || true)
  FILES=${FILES:-0}
  INS=${INS:-0}
  DEL=${DEL:-0}
  LINES=$((INS + DEL))
fi

FOUND=0

if is_trivial_tier; then
  if [ "$FILES" -gt "$TRIVIAL_MAX_FILES" ] || [ "$LINES" -gt "$TRIVIAL_MAX_LINES" ]; then
    echo "ESCALATE: trivial (haiku/low) task $ID has grown to $FILES files / $LINES changed lines, past the trivial envelope ($TRIVIAL_MAX_FILES files / $TRIVIAL_MAX_LINES lines) - bump to at least sonnet/high"
    FOUND=1
  fi
  AGE_SRC=$(tier_guard_stat_mtime "$META" || true)
  if [ -n "$AGE_SRC" ]; then
    NOW=$(date +%s)
    AGE=$((NOW - AGE_SRC))
    if [ "$AGE" -gt "$TRIVIAL_MAX_AGE" ]; then
      echo "ESCALATE: trivial (haiku/low) task $ID has run ${AGE}s, past the trivial tier's ${TRIVIAL_MAX_AGE}s ceiling - bump to at least sonnet/high"
      FOUND=1
    fi
  fi
fi

if [ "$FILES" -gt "$HEAVY_MIN_FILES" ] || [ "$LINES" -gt "$HEAVY_MIN_LINES" ]; then
  echo "ESCALATE: task $ID's diff ($FILES files / $LINES changed lines) exceeds the heavy-scale ceiling ($HEAVY_MIN_FILES files / $HEAVY_MIN_LINES lines) regardless of its assigned tier - re-check whether it still matches its dispatched rule"
  FOUND=1
fi

if [ "$DIFF_MAY_LAG_PR" -eq 1 ]; then
  echo "warning: the diff for $ID was sized against a possibly-stale local branch because the open PR head could not be resolved; the ceilings above may under-count the real PR diff - re-check against the current PR before trusting a within-envelope result" >&2
fi

exit "$FOUND"
