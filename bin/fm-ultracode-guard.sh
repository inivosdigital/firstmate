#!/usr/bin/env bash
# Ultracode enforcement (guardrail #3): mechanically confirms a genuinely
# independent second pass ran on an ultracode-flagged task's finished diff
# before it can go PR-ready - not a sub-task the same crewmate spawned itself
# (data/research-resource-tiering-synthesis.md). Tracks state via a plain
# marker file, state/<task-id>.ultracode, the same convention as other
# firstmate state/ markers (state/.afk, state/<id>.turn-ended); it never
# touches fm-spawn.sh or the task's own meta.
#
# Usage:
#   fm-ultracode-guard.sh flag <task-id> [<role>]
#     Records that <task-id> was dispatched under a crew-dispatch rule whose
#     resolved profile set ultracode=true. <role> defaults to
#     "independent-review" (the only role this fleet's rules use today; see
#     docs/examples/crew-dispatch.json). Firstmate runs this right after
#     spawning the task.
#   fm-ultracode-guard.sh reviewed <task-id> <reviewer-task-id>
#     Records that <reviewer-task-id> - a distinct, separately dispatched task
#     (its own state/<reviewer-task-id>.meta must exist) - independently
#     reviewed <task-id>'s finished diff and its findings were addressed.
#     Refuses if <reviewer-task-id> equals <task-id> or has no recorded meta,
#     so a sub-task the same crewmate spawned itself cannot satisfy this.
#   fm-ultracode-guard.sh check <task-id>
#     Exits 0 if <task-id> was never flagged, or was flagged and reviewed.
#     Exits 1 with an explanatory message if flagged but not yet reviewed -
#     firstmate runs this before treating an ultracode-flagged task as
#     PR-ready (AGENTS.md section 7's Validate step).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  echo "usage: fm-ultracode-guard.sh flag <task-id> [<role>]" >&2
  echo "       fm-ultracode-guard.sh reviewed <task-id> <reviewer-task-id>" >&2
  echo "       fm-ultracode-guard.sh check <task-id>" >&2
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

CMD=${1:-}
ID=${2:-}
if [ -z "$CMD" ] || [ -z "$ID" ]; then
  usage
  exit 1
fi

MARKER="$STATE/$ID.ultracode"

cmd_flag() {
  local role=${3:-independent-review}
  [ $# -le 3 ] || { usage; exit 1; }
  mkdir -p "$STATE"
  # Overwrites any existing marker: re-flagging (e.g. after an escalation)
  # deliberately clears a prior reviewed_by=, since that review was against an
  # earlier version of the diff and the requirement starts over.
  echo "role=$role" > "$MARKER"
  echo "flagged $ID ultracode role=$role"
}

cmd_reviewed() {
  local reviewer=${3:-}
  [ $# -eq 3 ] || { usage; exit 1; }
  [ -n "$reviewer" ] || { echo "error: reviewed requires a reviewer-task-id" >&2; exit 1; }
  [ -f "$MARKER" ] || { echo "error: $ID is not ultracode-flagged (no $MARKER); nothing to mark reviewed" >&2; exit 1; }
  if [ "$reviewer" = "$ID" ]; then
    echo "error: reviewer-task-id must be a task distinct from $ID - a task cannot independently review itself" >&2
    exit 1
  fi
  if [ ! -f "$STATE/$reviewer.meta" ]; then
    echo "error: $reviewer has no recorded state/$reviewer.meta - it must be a genuinely, separately dispatched task, not a made-up id or a sub-task $ID spawned itself" >&2
    exit 1
  fi
  grep -qx "reviewed_by=$reviewer" "$MARKER" 2>/dev/null || echo "reviewed_by=$reviewer" >> "$MARKER"
  echo "recorded $reviewer as the independent review of $ID"
}

cmd_check() {
  [ $# -eq 2 ] || { usage; exit 1; }
  if [ ! -f "$MARKER" ]; then
    exit 0
  fi
  if grep -q '^reviewed_by=' "$MARKER" 2>/dev/null; then
    exit 0
  fi
  role=$(grep '^role=' "$MARKER" | tail -1 | cut -d= -f2- || true)
  echo "error: $ID is ultracode-flagged (role=${role:-independent-review}) but has no recorded independent review yet - dispatch a genuinely separate task to review the finished diff, then run: fm-ultracode-guard.sh reviewed $ID <reviewer-task-id>" >&2
  exit 1
}

case "$CMD" in
  flag) cmd_flag "$@" ;;
  reviewed) cmd_reviewed "$@" ;;
  check) cmd_check "$@" ;;
  *) usage; exit 1 ;;
esac
