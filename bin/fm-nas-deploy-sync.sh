#!/usr/bin/env bash
# Best-effort, non-fatal deploy sync for a single project's live NAS checkout: a
# merged PR lands in the project's GitHub default branch, but the live app on this
# host runs from its own separate checkout under /mnt/nas/experiments/<name>/,
# managed by pm2 - that checkout does not update itself (see the 2026-07-04 entry
# in data/learnings.md). This script closes that gap after a landed ship task.
#
# Looks the project up in data/nas-deployments.md, a pipe-table with one row per
# deployed project: "| <project> | <nas_repo_path> | <pm2_process(es)> |" (comma-
# separated when more than one process serves the app). A project absent from
# that table - or a fresh checkout with no data/nas-deployments.md at all - has no
# known live deployment, which is not an error: prints one skip line and exits 0.
#
# When present: fetches the NAS checkout's origin and fast-forward-only merges to
# origin/<default>, mirroring bin/fm-fleet-sync.sh's dirty/diverged safety exactly
# - never force, never discard local changes, never touch a checkout that is off
# its default branch, dirty, or diverged (reported as STUCK, left untouched).
# Restarts the recorded pm2 process(es) only when the merge actually advanced
# HEAD, then verifies each is back online via `pm2 jlist`. Always prints exactly
# one clear result line and exits 0 - this script is best-effort and must never
# fail or block its caller (see the post-teardown call in bin/fm-teardown.sh).
#
# Usage: fm-nas-deploy-sync.sh <project-name>
#
# Overrides (test injection): FM_DATA_OVERRIDE points at an alternate data/ dir
# (same knob bin/fm-project-mode.sh uses); FM_NAS_DEPLOYMENTS_OVERRIDE points at
# an alternate mapping file directly. pm2 is invoked via PATH, so a fakebin shim
# ahead of it on PATH intercepts restart/list during tests - real tests must never
# reach the real /mnt/nas/experiments or a real pm2 process.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
MAP="${FM_NAS_DEPLOYMENTS_OVERRIDE:-$DATA/nas-deployments.md}"

usage() {
  echo "usage: fm-nas-deploy-sync.sh <project-name>" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 1 ] || { usage; exit 1; }
NAME=$1

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

# lookup_row: print "<nas_repo_path>|<pm2_processes>" for $NAME's row in $MAP, or
# nothing when the file is absent or has no matching row.
lookup_row() {
  [ -f "$MAP" ] || return 0
  # $3 ~ /^\// excludes the header ("nas_repo_path") and separator ("---") rows -
  # a real NAS path is always absolute - so a project literally named "project"
  # cannot collide with the header's own column label.
  awk -F'|' -v n="$NAME" '
    { for (i = 1; i <= NF; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) } }
    NF >= 4 && $2 == n && $3 ~ /^\// { print $3 "|" $4; exit }
  ' "$MAP"
}

row=$(lookup_row)
if [ -z "$row" ]; then
  echo "$NAME: skipped: no recorded NAS deployment"
  exit 0
fi
NAS_PATH=${row%%|*}
PROCS=${row#*|}

if [ ! -d "$NAS_PATH" ]; then
  echo "$NAME: skipped: NAS path $NAS_PATH not a directory"
  exit 0
fi
if ! git -C "$NAS_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "$NAME: skipped: $NAS_PATH not a git repo"
  exit 0
fi
if ! git -C "$NAS_PATH" remote get-url origin >/dev/null 2>&1; then
  echo "$NAME: skipped: no origin remote at $NAS_PATH"
  exit 0
fi

fetch_output=""
if ! fetch_output=$(git -C "$NAS_PATH" fetch origin --quiet 2>&1); then
  reason="fetch failed"
  [ -z "$fetch_output" ] || reason="$reason: $(first_line "$fetch_output")"
  echo "$NAME: skipped: $reason"
  exit 0
fi

default_branch() {
  local ref branch
  ref=$(git -C "$NAS_PATH" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$NAS_PATH" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

DEFAULT=$(default_branch) || {
  echo "$NAME: skipped: cannot determine default branch at $NAS_PATH"
  exit 0
}
BASE="origin/$DEFAULT"
if ! git -C "$NAS_PATH" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
  echo "$NAME: skipped: $BASE does not exist at $NAS_PATH"
  exit 0
fi

cur=$(git -C "$NAS_PATH" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
dirty=no
[ -z "$(git -C "$NAS_PATH" status --porcelain 2>/dev/null | head -1)" ] || dirty=yes

if [ "$cur" != "$DEFAULT" ]; then
  echo "$NAME: STUCK: NAS checkout at $NAS_PATH is not on $DEFAULT - needs attention"
  exit 0
fi
if [ "$dirty" = yes ]; then
  echo "$NAME: STUCK: NAS checkout at $NAS_PATH has uncommitted changes - needs attention"
  exit 0
fi

local_rev=""
if ! local_rev=$(git -C "$NAS_PATH" rev-parse --verify --quiet "$DEFAULT"); then
  echo "$NAME: skipped: cannot read local $DEFAULT at $NAS_PATH"
  exit 0
fi
remote_rev=""
if ! remote_rev=$(git -C "$NAS_PATH" rev-parse --verify --quiet "$BASE"); then
  echo "$NAME: skipped: cannot read $BASE at $NAS_PATH"
  exit 0
fi
if [ "$local_rev" = "$remote_rev" ]; then
  echo "$NAME: already current"
  exit 0
fi
if ! git -C "$NAS_PATH" merge-base --is-ancestor "$DEFAULT" "$BASE"; then
  behind=$(git -C "$NAS_PATH" rev-list --count "HEAD..$BASE" 2>/dev/null) || behind="?"
  echo "$NAME: STUCK: NAS checkout at $NAS_PATH diverged from $BASE, $behind commits behind - needs attention"
  exit 0
fi

before=$(git -C "$NAS_PATH" rev-parse --short "$DEFAULT")
merge_output=""
if ! merge_output=$(git -C "$NAS_PATH" merge --ff-only "$BASE" 2>&1); then
  reason="fast-forward failed"
  [ -z "$merge_output" ] || reason="$reason: $(first_line "$merge_output")"
  echo "$NAME: skipped: $reason"
  exit 0
fi
after=$(git -C "$NAS_PATH" rev-parse --short "$DEFAULT")

# process_online <proc>: true when pm2 currently reports <proc> as online.
process_online() {
  local proc=$1 status
  status=$(pm2 jlist 2>/dev/null | jq -r --arg n "$proc" \
    '[.[] | select(.name == $n) | .pm2_env.status] | .[0] // "missing"' 2>/dev/null) || status="missing"
  [ "$status" = "online" ]
}

restart_problems=""
IFS=',' read -r -a procs <<< "$PROCS"
for proc in "${procs[@]}"; do
  proc="${proc#"${proc%%[![:space:]]*}"}"
  proc="${proc%"${proc##*[![:space:]]}"}"
  [ -n "$proc" ] || continue
  if ! pm2 restart "$proc" >/dev/null 2>&1; then
    restart_problems="$restart_problems $proc(restart failed)"
    continue
  fi
  if ! process_online "$proc"; then
    restart_problems="$restart_problems $proc(not online after restart)"
  fi
done

if [ -n "$restart_problems" ]; then
  echo "$NAME: synced $before..$after but restart verification failed:$restart_problems - needs attention"
  exit 0
fi
echo "$NAME: synced $before..$after, restarted $PROCS and verified online"
