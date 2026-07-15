#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
#
# After the fast-forward, the project's origin is pushed only when the project
# IS firstmate's own repo (PROJ resolves to the same real path as FM_ROOT) - that
# is the deliberate fork-sync case (AGENTS.md prime directives; section 12's
# self-update model), where origin is the captain's own fork and keeping its
# default branch in sync is intended. A local-only PROJECT's contract is "no
# remote, no PR" (AGENTS.md section 6); auto-pushing an arbitrary local-only
# project's origin would silently break that promise, so every other project
# needs the explicit --push-origin flag to opt in.
#
# Usage: fm-merge-local.sh <task-id> [--push-origin]
#   --push-origin  push the fast-forwarded default branch to origin even when
#                  PROJ is not firstmate's own repo. Only pass this on the
#                  captain's explicit request for that project; firstmate's own
#                  repo pushes automatically without it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:?usage: fm-merge-local.sh <task-id> [--push-origin]}
PUSH_ORIGIN_OPT=${2:-}
case "$PUSH_ORIGIN_OPT" in
  ''|--push-origin) ;;
  *) echo "error: unknown argument '$PUSH_ORIGIN_OPT'; usage: fm-merge-local.sh <task-id> [--push-origin]" >&2; exit 1 ;;
esac
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

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

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"

# Keep a push-backed default branch synced with the merge that just landed, so
# the remote never silently drifts behind local main - but ONLY when PROJ is
# firstmate's own repo (the deliberate fork-sync case; see header) or the caller
# passed --push-origin explicitly. Best-effort by design when it does push: the
# local fast-forward above is the operation that matters, so a push failure
# (offline, transient network, or a non-fast-forward rejection) is reported but
# never fails the merge. A pure local-only project with no origin remote has
# nowhere to push and is skipped silently - not every local-only project is
# remote-backed.
proj_abs=$(cd "$PROJ" && pwd -P)
fm_root_abs=$(cd "$FM_ROOT" && pwd -P)
is_firstmate_repo=0
[ "$proj_abs" = "$fm_root_abs" ] && is_firstmate_repo=1

if [ "$is_firstmate_repo" -eq 1 ] || [ "$PUSH_ORIGIN_OPT" = "--push-origin" ]; then
  if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
    if git -C "$PROJ" push origin "$DEFAULT" >/dev/null 2>&1; then
      echo "pushed $DEFAULT to origin in $PROJ"
    else
      echo "warning: local $DEFAULT merged, but syncing it to origin failed in $PROJ (best-effort; merge succeeded)" >&2
    fi
  fi
fi
