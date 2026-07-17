#!/usr/bin/env bash
# Best-effort, non-fatal deploy sync for a single project whose live deployment
# runs from a NAS git checkout managed by systemd + Docker Compose, rather than
# by pm2. It is the second deployment topology alongside bin/fm-nas-deploy-sync.sh:
# same "a merged PR does not, by itself, reach the live site" gap (see the
# 2026-07-04 entry in data/learnings.md), different runtime shape. A project uses
# exactly one of the two - never both.
#
# Unlike the pm2 script, this one is NOT wired into bin/fm-teardown.sh's automatic
# post-merge call chain: firstmate invokes it deliberately. Keep it that way
# unless wiring is a separate, explicit decision.
#
# --- mapping: data/compose-deployments.md ------------------------------------
# A hand-maintained pipe-table, one row per compose-deployed project, kept in a
# SEPARATE file from the pm2 table so a project can never be matched by both
# scripts against different assumptions (each script reads only its own file):
#
#   | project | nas_repo_path | compose_file | systemd_service | required_mount | migrate_cmd | health_check |
#   | --- | --- | --- | --- | --- | --- | --- |
#   | wealthsync | /mnt/nas/experiments/wealthsync | - | wealthsync | /var/lib/wealthsync | npx prisma migrate deploy | http://localhost:3000/health |
#
#   project          match key (column 2).
#   nas_repo_path    absolute path to the live NAS checkout (REQUIRED; the leading
#                    "/" is also how header/separator rows are excluded).
#   compose_file     compose file path relative to the checkout root, or absolute;
#                    "-" / empty uses compose's default (docker-compose.yml at root).
#   systemd_service  the unit that wraps the compose stack, or "-" / empty for a
#                    bare compose stack this script brings up itself (see redeploy).
#   required_mount   a mountpoint that must be mounted before deploying (e.g. an
#                    encrypted LUKS data volume), or "-" / empty for no mount gate.
#   migrate_cmd      the project's migration step, run in the checkout before the
#                    redeploy (e.g. "npx prisma migrate deploy"), or "-" / empty.
#   health_check     an http(s):// URL curl'd, or any other value run as a shell
#                    command in the checkout; must pass before success is reported.
#                    "-" / empty falls back to a lower-confidence "containers
#                    report running" check (said plainly in the result line).
#
# No cell may contain a literal "|" (the column separator). A migrate_cmd or
# health_check that needs one (or a pipeline) must live in a script the cell
# invokes by path. A migrate_cmd / shell health_check may contain spaces; it is
# run via `bash -c` with the checkout as the working directory.
#
# A project absent from the table - or a fresh home with no
# data/compose-deployments.md at all - has no known compose deployment, which is
# not an error: prints one skip line and exits 0.
#
# --- what it does ------------------------------------------------------------
# 1. Mount gate. Before touching the checkout, verify required_mount is actually
#    mounted. If not, that is an EXPECTED state right after a reboot before the
#    data volume has been unlocked - a quiet skip, not a failure.
# 2. Fetch origin and fast-forward-only merge to origin/<default>, mirroring
#    bin/fm-nas-deploy-sync.sh's dirty/diverged safety exactly - never force,
#    never discard local changes, never touch a checkout that is off its default
#    branch, dirty, or diverged (reported as STUCK, left completely untouched).
# 3. Only when the merge actually advanced HEAD: run migrate_cmd, then rebuild
#    and bring the stack up, then verify health before declaring success.
#
# --- redeploy: build, then bring up ------------------------------------------
# When a systemd unit wraps the stack, the unit owns start/stop, so the redeploy
# rebuilds images with `docker compose build` and hands the bring-up to
# `systemctl restart <service>` - avoiding a redundant compose up/down on top of
# the unit's own. This assumes the unit brings the stack up from THIS checkout
# under the SAME compose project name, so the images this build produces are the
# ones the unit then runs; if the unit sets its own COMPOSE_PROJECT_NAME the
# fresh images would not be consumed and a health check could pass a stale
# deploy. A bare compose stack (no unit) does the full `docker compose up -d
# --build` itself. This script never injects a `-p` project name: the single
# live deployment owns its own compose namespace (unlike an isolated worktree).
#
# Always prints exactly one clear result line and exits 0 - best-effort, it must
# never fail or block its caller. A line containing "needs attention" is the
# signal for firstmate to look; everything else is benign.
#
# Usage: fm-compose-deploy-sync.sh <project-name>
#
# Overrides (test injection): FM_DATA_OVERRIDE points at an alternate data/ dir;
# FM_COMPOSE_DEPLOYMENTS_OVERRIDE points at an alternate mapping file directly;
# FM_COMPOSE_PROC_MOUNTS points the mount gate at an alternate mounts table
# (default /proc/mounts) and, when set, is used in place of the mountpoint(1)
# tool. docker, systemctl, mountpoint, and curl are invoked via PATH, so fakebin
# shims ahead of them intercept during tests - real tests must never reach a real
# /mnt/nas checkout, docker, systemd, or NAS.
#
# Timeouts. Every filesystem/git touch of the NAS checkout is bounded by
# FM_COMPOSE_SYNC_TIMEOUT (default 15s): an unreachable NAS is a hang risk, not a
# fast failure. The redeploy steps get their own, generous bound
# FM_COMPOSE_DEPLOY_TIMEOUT (default 1200s) because a migration or image build is
# legitimately slow, and each health-check attempt is bounded by
# FM_COMPOSE_HEALTH_TIMEOUT (default 15s).
#
# Concurrency. The NAS checkout is a single shared live deployment, so two
# invocations moments apart can race the fetch on an orphaned
# .git/packed-refs.lock exactly like bin/fm-nas-deploy-sync.sh; the same
# retry-then-provably-stale guard is shared here via bin/fm-lock-lib.sh, bounded
# by FM_COMPOSE_SYNC_PACKED_REFS_LOCK_RETRIES / _RETRY_WAIT_SECS / _AGE_SECS.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
MAP="${FM_COMPOSE_DEPLOYMENTS_OVERRIDE:-$DATA/compose-deployments.md}"
SYNC_TIMEOUT="${FM_COMPOSE_SYNC_TIMEOUT:-15}"
DEPLOY_TIMEOUT="${FM_COMPOSE_DEPLOY_TIMEOUT:-1200}"
HEALTH_TIMEOUT="${FM_COMPOSE_HEALTH_TIMEOUT:-15}"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
FM_LOCK_LOG_PREFIX=compose-deploy-sync

HEALTH_RETRIES=${FM_COMPOSE_HEALTH_RETRIES:-5}
HEALTH_RETRY_WAIT_SECS=${FM_COMPOSE_HEALTH_RETRY_WAIT_SECS:-3}
case "$HEALTH_RETRIES" in ''|*[!0-9]*) HEALTH_RETRIES=5 ;; esac
[ "$HEALTH_RETRIES" -ge 1 ] || HEALTH_RETRIES=1
if ! [[ "$HEALTH_RETRY_WAIT_SECS" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
  echo "compose-deploy-sync: invalid health retry wait '$HEALTH_RETRY_WAIT_SECS'; using 3s" >&2
  HEALTH_RETRY_WAIT_SECS=3
fi

PACKED_REFS_LOCK_RETRIES=${FM_COMPOSE_SYNC_PACKED_REFS_LOCK_RETRIES:-3}
PACKED_REFS_LOCK_RETRY_WAIT_SECS=${FM_COMPOSE_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS:-1}
PACKED_REFS_LOCK_AGE_SECS=${FM_COMPOSE_SYNC_PACKED_REFS_LOCK_AGE_SECS:-30}
case "$PACKED_REFS_LOCK_RETRIES" in ''|*[!0-9]*) PACKED_REFS_LOCK_RETRIES=3 ;; esac
case "$PACKED_REFS_LOCK_AGE_SECS" in ''|*[!0-9]*) PACKED_REFS_LOCK_AGE_SECS=30 ;; esac
if ! [[ "$PACKED_REFS_LOCK_RETRY_WAIT_SECS" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
  echo "compose-deploy-sync: invalid packed-refs lock retry wait '$PACKED_REFS_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  PACKED_REFS_LOCK_RETRY_WAIT_SECS=1
fi

HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then
  HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  HAVE_TIMEOUT=gtimeout
fi

# _bounded <secs> <args...>: run <args...>, killed after <secs> when a
# `timeout`/`gtimeout` binary is available, run directly otherwise.
_bounded() {
  local t=$1
  shift
  case "$HAVE_TIMEOUT" in
    timeout) timeout "$t" "$@" ;;
    gtimeout) gtimeout "$t" "$@" ;;
    *) "$@" ;;
  esac
}
# bounded: NAS filesystem/git touches (short bound). bounded_deploy: migrate and
# image build/up (generous bound). bounded_health: one health-check attempt.
bounded() { _bounded "$SYNC_TIMEOUT" "$@"; }
bounded_deploy() { _bounded "$DEPLOY_TIMEOUT" "$@"; }
bounded_health() { _bounded "$HEALTH_TIMEOUT" "$@"; }

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
  echo "usage: fm-compose-deploy-sync.sh <project-name>" >&2
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
# bin/fm-nas-deploy-sync.sh's is_packed_refs_lock_error.
is_packed_refs_lock_error() {
  printf '%s\n' "$1" | grep -Eq "Unable to create ['\"].*packed-refs\\.lock['\"]: File exists"
}

# Absolute path to $NAS_PATH's packed-refs.lock, or empty when unresolvable.
packed_refs_lock_path() {
  local lock abs
  lock=$(git_nas rev-parse --git-path packed-refs.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      # cd is a shell builtin, so timeout/gtimeout cannot bound it directly; run
      # the cd+pwd in a bounded child so a hung NAS mount cannot wedge here either.
      # shellcheck disable=SC2016 # single-quoted so the child bash expands $1 from its own arg.
      abs=$(bounded bash -c 'cd "$1" && pwd -P' bash "$NAS_PATH") || return 1
      printf '%s/%s\n' "$abs" "$lock"
      ;;
  esac
}

# Run `git_nas fetch origin --quiet`, tolerating an orphaned packed-refs.lock
# left by a second invocation racing this exact NAS checkout. Sets FETCH_OUTPUT
# and returns the fetch's exit status; mirrors bin/fm-nas-deploy-sync.sh's
# fetch_with_packed_refs_lock_guard, sharing the staleness proof from
# bin/fm-lock-lib.sh.
fetch_with_packed_refs_lock_guard() {
  local rc attempt=0 lock lock_desc
  FETCH_OUTPUT=$(git_nas fetch origin --quiet 2>&1); rc=$?
  [ "$rc" -eq 0 ] && return 0
  is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"

  lock=$(packed_refs_lock_path) || lock=""
  lock_desc=${lock:-packed-refs.lock}
  while [ "$attempt" -lt "$PACKED_REFS_LOCK_RETRIES" ]; do
    attempt=$(( attempt + 1 ))
    echo "$NAME: fetch blocked by packed-refs lock ($lock_desc) at $NAS_PATH; waiting ${PACKED_REFS_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${PACKED_REFS_LOCK_RETRIES}) (owning process may be exiting)" >&2
    sleep "$PACKED_REFS_LOCK_RETRY_WAIT_SECS"
    FETCH_OUTPUT=$(git_nas fetch origin --quiet 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "$NAME: fetch succeeded on retry; packed-refs lock cleared on its own" >&2
      return 0
    fi
    is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"
  done

  # Retries exhausted and still the lock signature. Clear ONLY if provably stale.
  # Every probe below touches $NAS_PATH, so bound each one - the existence test,
  # the staleness proof, and the removal - or a degraded mount reintroduces the
  # unbounded hang this guard is meant to survive.
  lock=$(packed_refs_lock_path) || lock=""
  if [ -n "$lock" ] && bounded test -e "$lock"; then
    if bounded_is_provably_stale "$lock" "$NAS_PATH" "$PACKED_REFS_LOCK_AGE_SECS"; then
      if ! bounded rm -f "$lock"; then
        echo "$NAME: failed to remove provably-stale packed-refs lock $lock; leaving it in place" >&2
        return "$rc"
      fi
      echo "$NAME: removed provably-stale packed-refs lock $lock (age >= ${PACKED_REFS_LOCK_AGE_SECS}s, no live holder) and retrying fetch" >&2
      FETCH_OUTPUT=$(git_nas fetch origin --quiet 2>&1); rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "$NAME: fetch succeeded after stale packed-refs lock cleanup" >&2
        return 0
      fi
      return "$rc"
    fi
    echo "$NAME: fetch blocked by packed-refs lock $lock that persisted across ${PACKED_REFS_LOCK_RETRIES} retries and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$rc"
  fi
  echo "$NAME: fetch packed-refs lock signature persisted across ${PACKED_REFS_LOCK_RETRIES} retries even after the lock file disappeared" >&2
  return "$rc"
}

# lookup_row: print "<nas_repo_path>|<compose_file>|<systemd_service>|
# <required_mount>|<migrate_cmd>|<health_check>" for $NAME's row in $MAP, or
# nothing when the file is absent or has no matching row. Fields are joined by
# "|" - safe because no cell may contain that character.
lookup_row() {
  [ -f "$MAP" ] || return 0
  # $3 ~ /^\// excludes the header ("nas_repo_path") and separator ("---") rows -
  # a real NAS path is always absolute - so a project literally named
  # "nas_repo_path" cannot collide with the header's own column label.
  awk -F'|' -v n="$NAME" '
    { for (i = 1; i <= NF; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) } }
    NF >= 8 && $2 == n && $3 ~ /^\// { print $3 "|" $4 "|" $5 "|" $6 "|" $7 "|" $8; exit }
  ' "$MAP"
}

# unset_dash <value>: echo the value, or empty when it is "-" (the table's
# explicit "not set" marker).
unset_dash() {
  [ "$1" = "-" ] && return 0
  printf '%s' "$1"
}

# is_mountpoint <path>: true when <path> is a mounted filesystem. Uses the
# mountpoint(1) tool when available; falls back to (and, when
# FM_COMPOSE_PROC_MOUNTS is set, uses directly) a mounts table whose second
# whitespace field is the mount target. The table is a kernel virtual file
# (/proc/mounts) or a small test fixture, so the read never blocks.
is_mountpoint() {
  local path=$1 mounts target
  if [ -z "${FM_COMPOSE_PROC_MOUNTS:-}" ] && command -v mountpoint >/dev/null 2>&1; then
    bounded mountpoint -q "$path"
    return
  fi
  mounts=${FM_COMPOSE_PROC_MOUNTS:-/proc/mounts}
  [ -r "$mounts" ] || return 1
  while read -r _ target _; do
    [ "$target" = "$path" ] && return 0
  done < "$mounts"
  return 1
}

row=$(lookup_row)
if [ -z "$row" ]; then
  echo "$NAME: skipped: no recorded compose deployment"
  exit 0
fi
IFS='|' read -r NAS_PATH COMPOSE_FILE SYSTEMD_SERVICE REQUIRED_MOUNT MIGRATE_CMD HEALTH_CHECK <<< "$row"
COMPOSE_FILE=$(unset_dash "$COMPOSE_FILE")
SYSTEMD_SERVICE=$(unset_dash "$SYSTEMD_SERVICE")
REQUIRED_MOUNT=$(unset_dash "$REQUIRED_MOUNT")
MIGRATE_CMD=$(unset_dash "$MIGRATE_CMD")
HEALTH_CHECK=$(unset_dash "$HEALTH_CHECK")

# Mount gate: before touching the checkout, require the data volume to be
# mounted. An unmounted volume right after a reboot (before LUKS unlock) is an
# expected, self-clearing state - skip quietly, do not fast-forward or deploy.
if [ -n "$REQUIRED_MOUNT" ]; then
  if ! is_mountpoint "$REQUIRED_MOUNT"; then
    echo "$NAME: skipped: required data volume $REQUIRED_MOUNT is not mounted yet (waiting on volume unlock) - leaving deployment untouched"
    exit 0
  fi
fi

if ! bounded test -d "$NAS_PATH"; then
  echo "$NAME: skipped: compose checkout $NAS_PATH not a directory"
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
  echo "$NAME: STUCK: compose checkout at $NAS_PATH is not on $DEFAULT - needs attention"
  exit 0
fi
if [ "$dirty" = yes ]; then
  echo "$NAME: STUCK: compose checkout at $NAS_PATH has uncommitted changes - needs attention"
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
  echo "$NAME: STUCK: compose checkout at $NAS_PATH diverged from $BASE, $behind commits behind - needs attention"
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

# Deploy only when the fast-forward actually advanced HEAD.
if [ "$before" = "$after" ]; then
  echo "$NAME: already current"
  exit 0
fi

# compose <args...>: docker compose in the checkout with the mapped compose file,
# generous (deploy) timeout. No `-p`: the live deployment owns its own namespace.
# compose_args is empty when no compose_file is mapped (the "-" default), so both
# expansions use the ${arr[@]+"${arr[@]}"} guard - referencing an empty array via
# "${arr[@]}" under `set -u` is an unbound-variable error on bash < 4.4 (macOS's
# stock /bin/bash 3.2), the same guard bin/fm-pr-merge.sh and bin/fm-spawn.sh use.
compose_args=()
[ -n "$COMPOSE_FILE" ] && compose_args=(-f "$COMPOSE_FILE")
compose() {
  ( cd "$NAS_PATH" && bounded_deploy docker compose ${compose_args[@]+"${compose_args[@]}"} "$@" )
}

# Migrate first, in the checkout, before anything is brought up against a
# half-migrated schema.
if [ -n "$MIGRATE_CMD" ]; then
  migrate_out=""
  if ! migrate_out=$( ( cd "$NAS_PATH" && bounded_deploy bash -c "$MIGRATE_CMD" ) 2>&1 ); then
    reason="migration failed"
    [ -z "$migrate_out" ] || reason="$reason: $(first_line "$migrate_out")"
    echo "$NAME: synced $before..$after but $reason - needs attention"
    exit 0
  fi
fi

# Rebuild, then bring up (via the wrapping systemd unit when present, else via
# compose itself). A failed build aborts before the bring-up.
if [ -n "$SYSTEMD_SERVICE" ]; then
  build_out=""
  if ! build_out=$(compose build 2>&1); then
    reason="compose build failed"
    [ -z "$build_out" ] || reason="$reason: $(first_line "$build_out")"
    echo "$NAME: synced $before..$after but $reason - needs attention"
    exit 0
  fi
  restart_out=""
  if ! restart_out=$(bounded_deploy systemctl restart "$SYSTEMD_SERVICE" 2>&1); then
    reason="systemd restart of $SYSTEMD_SERVICE failed"
    [ -z "$restart_out" ] || reason="$reason: $(first_line "$restart_out")"
    echo "$NAME: synced $before..$after but $reason - needs attention"
    exit 0
  fi
else
  up_out=""
  if ! up_out=$(compose up -d --build 2>&1); then
    reason="compose up failed"
    [ -z "$up_out" ] || reason="$reason: $(first_line "$up_out")"
    echo "$NAME: synced $before..$after but $reason - needs attention"
    exit 0
  fi
fi

# containers_running: true when `docker compose ps` reports every container in a
# "running" state. Tolerates compose's JSON-array and JSON-lines ps output.
containers_running() {
  local json out
  json=$( ( cd "$NAS_PATH" && bounded_health docker compose ${compose_args[@]+"${compose_args[@]}"} ps --format json ) 2>/dev/null ) || return 1
  out=$(printf '%s' "$json" | jq -rs '
    flatten
    | if length == 0 then "none"
      elif all(.[]; .State == "running") then "running"
      else "not-running" end' 2>/dev/null) || return 1
  [ "$out" = "running" ]
}

# health_ok: one health attempt - the configured check (http(s) URL curl'd, else
# a shell command in the checkout), or the container-running fallback. Called
# directly by run_health_check.
health_ok() {
  if [ -n "$HEALTH_CHECK" ]; then
    case "$HEALTH_CHECK" in
      http://*|https://*) bounded_health curl -fsS "$HEALTH_CHECK" >/dev/null 2>&1 ;;
      *) ( cd "$NAS_PATH" && bounded_health bash -c "$HEALTH_CHECK" ) >/dev/null 2>&1 ;;
    esac
  else
    containers_running
  fi
}

# run_health_check: true when health_ok succeeds within HEALTH_RETRIES tries,
# sleeping HEALTH_RETRY_WAIT_SECS between - a container or app needs a moment to
# become healthy after a restart.
run_health_check() {
  local i=0
  while :; do
    if health_ok; then return 0; fi
    i=$(( i + 1 ))
    [ "$i" -ge "$HEALTH_RETRIES" ] && return 1
    sleep "$HEALTH_RETRY_WAIT_SECS"
  done
}

if run_health_check; then
  if [ -n "$HEALTH_CHECK" ]; then
    echo "$NAME: synced $before..$after, redeployed and health check passed ($HEALTH_CHECK)"
  else
    echo "$NAME: synced $before..$after, redeployed; containers report running (no health check configured, lower confidence)"
  fi
else
  if [ -n "$HEALTH_CHECK" ]; then
    echo "$NAME: synced $before..$after, redeployed but health check failed: $HEALTH_CHECK - needs attention"
  else
    echo "$NAME: synced $before..$after, redeployed but containers are not all running - needs attention"
  fi
fi
exit 0
