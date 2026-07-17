#!/usr/bin/env bash
# Best-effort, non-fatal deploy sync for a single project's live NAS checkout: a
# merged PR lands in the project's GitHub default branch, but the live app on this
# host runs from its own separate checkout under /mnt/nas/experiments/<name>/,
# managed by pm2 - that checkout does not update itself (see the 2026-07-04 entry
# in data/learnings.md). This script closes that gap after a landed ship task.
# It is one of two deployment topologies; a project managed by Docker Compose
# (optionally systemd-wrapped) instead of pm2 uses the sibling
# bin/fm-compose-deploy-sync.sh instead - a project uses exactly one of the two,
# never both.
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
#
# Every filesystem/git touch of $NAS_PATH is wrapped in a bounded timeout
# (FM_NAS_SYNC_TIMEOUT seconds, default 15): the mount is a NAS, and an
# unreachable one is a hang risk (a stuck stat/read), not a fast failure, which
# would otherwise stall fm-teardown.sh's caller and break this script's
# non-blocking contract.
#
# $NAS_PATH is one single shared live-deployment checkout - unlike a project's
# projects/<name> dev clone, which is scoped to one firstmate home, two ship
# tasks for the same project landing moments apart can both reach the SAME
# NAS checkout from concurrent teardowns. That races the fetch on an orphaned
# .git/packed-refs.lock exactly like bin/fm-fleet-sync.sh's fetch had to guard
# against; fetch_with_packed_refs_lock_guard below mirrors that recovery,
# sharing the staleness proof from bin/fm-lock-lib.sh, bounded by
# FM_NAS_SYNC_PACKED_REFS_LOCK_RETRIES / _RETRY_WAIT_SECS / _AGE_SECS.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
MAP="${FM_NAS_DEPLOYMENTS_OVERRIDE:-$DATA/nas-deployments.md}"
NAS_SYNC_TIMEOUT="${FM_NAS_SYNC_TIMEOUT:-15}"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
FM_LOCK_LOG_PREFIX=nas-deploy-sync

NAS_SYNC_PACKED_REFS_LOCK_RETRIES=${FM_NAS_SYNC_PACKED_REFS_LOCK_RETRIES:-3}
NAS_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=${FM_NAS_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS:-1}
NAS_SYNC_PACKED_REFS_LOCK_AGE_SECS=${FM_NAS_SYNC_PACKED_REFS_LOCK_AGE_SECS:-30}
case "$NAS_SYNC_PACKED_REFS_LOCK_RETRIES" in ''|*[!0-9]*) NAS_SYNC_PACKED_REFS_LOCK_RETRIES=3 ;; esac
case "$NAS_SYNC_PACKED_REFS_LOCK_AGE_SECS" in ''|*[!0-9]*) NAS_SYNC_PACKED_REFS_LOCK_AGE_SECS=30 ;; esac
if ! [[ "$NAS_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
  echo "nas-deploy-sync: invalid packed-refs lock retry wait '$NAS_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  NAS_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1
fi

HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then
  HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  HAVE_TIMEOUT=gtimeout
fi

# bounded <args...>: run <args...>, killed after $NAS_SYNC_TIMEOUT seconds when
# a `timeout`/`gtimeout` binary is available, run directly otherwise.
bounded() {
  case "$HAVE_TIMEOUT" in
    timeout) timeout "$NAS_SYNC_TIMEOUT" "$@" ;;
    gtimeout) gtimeout "$NAS_SYNC_TIMEOUT" "$@" ;;
    *) "$@" ;;
  esac
}

# git_nas <args...>: git -C "$NAS_PATH" <args...>, bounded.
git_nas() {
  bounded git -C "$NAS_PATH" "$@"
}

# bounded_is_provably_stale <lock> <dir> <min_age_secs>: fm_lock_is_provably_stale,
# bounded like every other filesystem/git touch of $NAS_PATH - its [ -e ], lsof,
# and stat probes can hang on a degraded NAS exactly like git_nas's calls do.
# timeout/gtimeout only bound a real subprocess, not an in-process shell
# function, so this execs the check in a fresh bash -c instead.
export FM_LOCK_LOG_PREFIX
export -f fm_lock_log fm_lock_path_mtime fm_lock_lsof_holder fm_lock_has_live_holder fm_lock_age fm_lock_is_provably_stale
bounded_is_provably_stale() {
  # shellcheck disable=SC2016 # single-quoted so the timeout'd child bash
  # expands $1/$2/$3 from ITS OWN args, not this shell's.
  bounded bash -c 'fm_lock_is_provably_stale "$1" "$2" "$3"' bash "$1" "$2" "$3"
}

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

# True when git stderr shows the packed-refs.lock "File exists" race, mirroring
# bin/fm-fleet-sync.sh's is_packed_refs_lock_error.
is_packed_refs_lock_error() {
  printf '%s\n' "$1" | grep -Eq "Unable to create ['\"].*packed-refs\\.lock['\"]: File exists"
}

# Absolute path to $NAS_PATH's packed-refs.lock, or empty when it cannot be
# resolved.
packed_refs_lock_path() {
  local lock abs
  lock=$(git_nas rev-parse --git-path packed-refs.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs=$(cd "$NAS_PATH" && pwd -P) || return 1
      printf '%s/%s\n' "$abs" "$lock"
      ;;
  esac
}

# Run `git_nas fetch origin --quiet`, tolerating an orphaned packed-refs.lock
# left by a second landed-teardown racing this exact NAS checkout. Sets
# FETCH_OUTPUT and returns the fetch's exit status; mirrors bin/fm-fleet-sync.sh's
# fetch_with_packed_refs_lock_guard retry-then-provably-stale-clear contract,
# sharing the staleness proof from bin/fm-lock-lib.sh.
fetch_with_packed_refs_lock_guard() {
  local rc attempt=0 lock lock_desc
  FETCH_OUTPUT=$(git_nas fetch origin --quiet 2>&1); rc=$?
  [ "$rc" -eq 0 ] && return 0
  is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"

  lock=$(packed_refs_lock_path) || lock=""
  lock_desc=${lock:-packed-refs.lock}
  while [ "$attempt" -lt "$NAS_SYNC_PACKED_REFS_LOCK_RETRIES" ]; do
    attempt=$(( attempt + 1 ))
    echo "$NAME: fetch blocked by packed-refs lock ($lock_desc) at $NAS_PATH; waiting ${NAS_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${NAS_SYNC_PACKED_REFS_LOCK_RETRIES}) (owning process may be exiting)" >&2
    sleep "$NAS_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS"
    FETCH_OUTPUT=$(git_nas fetch origin --quiet 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "$NAME: fetch succeeded on retry; packed-refs lock cleared on its own" >&2
      return 0
    fi
    is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"
  done

  # Retries exhausted and still the lock signature. Clear ONLY if provably stale.
  lock=$(packed_refs_lock_path) || lock=""
  if [ -n "$lock" ] && bounded test -e "$lock"; then
    if bounded_is_provably_stale "$lock" "$NAS_PATH" "$NAS_SYNC_PACKED_REFS_LOCK_AGE_SECS"; then
      if ! bounded rm -f "$lock"; then
        echo "$NAME: failed to remove provably-stale packed-refs lock $lock; leaving it in place" >&2
        return "$rc"
      fi
      echo "$NAME: removed provably-stale packed-refs lock $lock (age >= ${NAS_SYNC_PACKED_REFS_LOCK_AGE_SECS}s, no live holder) and retrying fetch" >&2
      FETCH_OUTPUT=$(git_nas fetch origin --quiet 2>&1); rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "$NAME: fetch succeeded after stale packed-refs lock cleanup" >&2
        return 0
      fi
      return "$rc"
    fi
    echo "$NAME: fetch blocked by packed-refs lock $lock that persisted across ${NAS_SYNC_PACKED_REFS_LOCK_RETRIES} retries and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$rc"
  fi
  echo "$NAME: fetch packed-refs lock signature persisted across ${NAS_SYNC_PACKED_REFS_LOCK_RETRIES} retries even after the lock file disappeared" >&2
  return "$rc"
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

if ! bounded test -d "$NAS_PATH"; then
  echo "$NAME: skipped: NAS path $NAS_PATH not a directory"
  exit 0
fi
if ! git_nas rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "$NAME: skipped: $NAS_PATH not a git repo"
  exit 0
fi
if ! git_nas remote get-url origin >/dev/null 2>&1; then
  echo "$NAME: skipped: no origin remote at $NAS_PATH"
  exit 0
fi

if ! fetch_with_packed_refs_lock_guard; then
  reason="fetch failed"
  [ -z "$FETCH_OUTPUT" ] || reason="$reason: $(first_line "$FETCH_OUTPUT")"
  echo "$NAME: skipped: $reason"
  exit 0
fi

default_branch() {
  local ref branch
  ref=$(git_nas symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git_nas show-ref --verify --quiet "refs/heads/$branch"; then
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
if ! git_nas rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
  echo "$NAME: skipped: $BASE does not exist at $NAS_PATH"
  exit 0
fi

cur=$(git_nas symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
dirty=no
[ -z "$(git_nas status --porcelain 2>/dev/null | head -1)" ] || dirty=yes

if [ "$cur" != "$DEFAULT" ]; then
  echo "$NAME: STUCK: NAS checkout at $NAS_PATH is not on $DEFAULT - needs attention"
  exit 0
fi
if [ "$dirty" = yes ]; then
  echo "$NAME: STUCK: NAS checkout at $NAS_PATH has uncommitted changes - needs attention"
  exit 0
fi

local_rev=""
if ! local_rev=$(git_nas rev-parse --verify --quiet "$DEFAULT"); then
  echo "$NAME: skipped: cannot read local $DEFAULT at $NAS_PATH"
  exit 0
fi
remote_rev=""
if ! remote_rev=$(git_nas rev-parse --verify --quiet "$BASE"); then
  echo "$NAME: skipped: cannot read $BASE at $NAS_PATH"
  exit 0
fi
if [ "$local_rev" = "$remote_rev" ]; then
  echo "$NAME: already current"
  exit 0
fi
if ! git_nas merge-base --is-ancestor "$DEFAULT" "$BASE"; then
  behind=$(git_nas rev-list --count "HEAD..$BASE" 2>/dev/null) || behind="?"
  echo "$NAME: STUCK: NAS checkout at $NAS_PATH diverged from $BASE, $behind commits behind - needs attention"
  exit 0
fi

before=$(git_nas rev-parse --short "$DEFAULT")
merge_output=""
if ! merge_output=$(git_nas merge --ff-only "$BASE" 2>&1); then
  reason="fast-forward failed"
  [ -z "$merge_output" ] || reason="$reason: $(first_line "$merge_output")"
  echo "$NAME: skipped: $reason"
  exit 0
fi
after=$(git_nas rev-parse --short "$DEFAULT")

# process_online <proc>: true when pm2 currently reports EVERY instance of
# <proc> as online (a clustered app can register several jlist entries under
# the same name; one lagging instance must not be masked by the others).
process_online() {
  local proc=$1 status
  status=$(pm2 jlist 2>/dev/null | jq -r --arg n "$proc" \
    '[.[] | select(.name == $n) | .pm2_env.status] as $s
     | if ($s | length) == 0 then "missing"
       elif all($s[]; . == "online") then "online"
       else "not-online"
       end' 2>/dev/null) || status="missing"
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
