#!/usr/bin/env bash
# Periodic /tmp cleanup. Exists because nothing on this machine otherwise
# cleans /tmp, and a full tmpfs /tmp can fragment RAM under zram swap badly
# enough to make an unrelated resource (a CIFS mount needing large contiguous
# allocations) hang for 10-25s with near-zero CPU and no error - see
# docs/configuration.md "/tmp sweep and cleanup" for the full incident and the
# evidence behind every safety rule below. Read that section before changing
# the protected-name list or the classification order.
#
# Usage: fm-tmp-sweep.sh [--apply] [--install] [--uninstall] [--help]
#   (no flags)  Dry run (the default; read-only). Reports what WOULD be
#               removed or skipped, and why, but changes nothing.
#   --apply     Perform the sweep for real: remove what the dry run would
#               remove. Everything else about the run is identical.
#   --install   Install and enable a user-level systemd timer that runs this
#               script with --apply once a day (docs/configuration.md "/tmp
#               sweep and cleanup" owns the exact unit content and rationale
#               for choosing a user timer over the alternatives). Idempotent:
#               safe to re-run. Machine-scoped, not per-firstmate-home - run
#               this once from the PRIMARY checkout, never from a secondmate
#               home or a task worktree, since /tmp itself is shared by the
#               whole machine and a second install would just duplicate the
#               same sweep.
#   --uninstall Reverse --install: stop and remove the timer/service units.
#               Never removes anything already swept.
#
# Environment overrides (for testing; the shipped defaults are deliberately
# not exposed as a tracked config file - see the doc section above for why):
#   FM_TMP_SWEEP_AGE_HOURS   minimum idle age before a non-live entry is even
#                            considered (default 48).
#   FM_TMP_SWEEP_LOG         where removal/skip lines are appended (default
#                            <main-home>/state/tmp-sweep.log).
#   FM_TMP_SWEEP_LSOF_TIMEOUT  seconds to wait for one open-handle check
#                            before failing safe and skipping (default 20).
#   FM_ROOT_OVERRIDE         which firstmate home is "main" for live-session
#                            discovery (bin/fm-tmp-lib.sh); defaults to this
#                            script's own repo root, exactly like every other
#                            bin/*.sh entrypoint.
#   FM_TMP_SWEEP_ROOT        the directory swept instead of the real /tmp
#                            (default /tmp). Exists purely so tests can point a
#                            real, unmodified run of this script at a fixture
#                            tree instead of touching the machine's actual /tmp.
#
# What never gets touched, no matter how old: entries outside /tmp; anything
# a symlink under /tmp resolves to outside /tmp; the well-known live-service
# paths in PROTECTED_EXACT/PROTECTED_PREFIX below (X11/VNC/ICE/font sockets
# and locks, systemd's PrivateTmp namespaces, ssh-agent and tmux socket
# directories, editor-server sockets); any live task's /tmp/fm-<id> root
# (bin/fm-spawn.sh's TASK_TMP, across every firstmate home on this machine,
# not just this one - bin/fm-tmp-lib.sh's fm_tmp_live_tasks); the harness
# scratch directory of any live task's worktree, AND of every firstmate home's
# own top-level session (the primary checkout and each secondmate, neither of
# which is itself a spawned task - bin/fm-tmp-lib.sh's
# fm_tmp_harness_scratch_dir, same source); anything modified more recently
# than the age threshold; anything with an open file handle anywhere in its
# tree at sweep time. NOT protected by liveness: a Claude Code session this
# machine is running that firstmate did not itself spawn (a no-mistakes
# pipeline worktree, an ad-hoc session) - firstmate has no record of those at
# all, so they rely on the age threshold alone; see docs/configuration.md
# "/tmp sweep and cleanup" for that residual risk.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-tmp-lib.sh
. "$SCRIPT_DIR/fm-tmp-lib.sh"

TMP_ROOT="${FM_TMP_SWEEP_ROOT:-/tmp}"
AGE_HOURS="${FM_TMP_SWEEP_AGE_HOURS:-48}"
AGE_SECS=$(( AGE_HOURS * 3600 ))
LSOF_TIMEOUT="${FM_TMP_SWEEP_LSOF_TIMEOUT:-20}"
LOG_FILE="${FM_TMP_SWEEP_LOG:-$FM_ROOT/state/tmp-sweep.log}"
LOG_MAX_LINES=5000

usage() {
  echo "usage: fm-tmp-sweep.sh [--apply] [--install] [--uninstall] [--help]" >&2
  echo "  (no flags) dry run; --apply performs the sweep for real." >&2
  echo "  see this script's header comment for the full contract." >&2
}

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  --install) "$SCRIPT_DIR/fm-tmp-sweep-install.sh" install; exit $? ;;
  --uninstall) "$SCRIPT_DIR/fm-tmp-sweep-install.sh" uninstall; exit $? ;;
  --help|-h) usage; exit 0 ;;
  "") ;;
  *) usage; exit 2 ;;
esac

mkdir -p "$(dirname "$LOG_FILE")"
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_LINES" ]; then
  # A unique per-invocation temp name, not a fixed "$LOG_FILE.trim": two
  # overlapping invocations (a manual --apply landing mid-timer, say) both
  # rotating against the same fixed name raced here, and under set -eu the
  # loser's failed mv crashed it outright and the winner's mv had already
  # replaced the log with an empty file. mktemp's suffix makes each
  # invocation's trim file distinct, so the race is now at worst "last mv
  # wins, losing only the other invocation's newest few lines" - never a
  # crash, never a full wipe.
  log_trim=$(mktemp "${LOG_FILE}.trim.XXXXXX")
  if tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "$log_trim"; then
    mv "$log_trim" "$LOG_FILE"
  else
    rm -f "$log_trim"
  fi
fi

RUN_TS=$(date -Is)
log_and_report() {  # <action> <path> <reason>
  printf '%s\t%s\t%s\t%s\n' "$RUN_TS" "$1" "$2" "$3" >> "$LOG_FILE"
  printf '%s: %s (%s)\n' "$1" "$2" "$3"
}

# --- well-known live infra, enumerated by hand on this machine (2026-07-27;
# see docs/configuration.md "/tmp sweep and cleanup" for the evidence trail of
# what each one is and who owns it) --------------------------------------
PROTECTED_EXACT=".X11-unix .ICE-unix .font-unix .XIM-unix .Test-unix .X0-lock .X1-lock"
PROTECTED_PREFIX="systemd-private- tmux- ssh- vscode-typescript .xfsm-ICE-"

is_protected_name() {
  local name=$1 p
  for p in $PROTECTED_EXACT; do [ "$name" = "$p" ] && return 0; done
  for p in $PROTECTED_PREFIX; do case "$name" in "$p"*) return 0 ;; esac; done
  return 1
}

# True (0) when <path> resolves to somewhere outside $TMP_ROOT once every
# symlink component is followed - the top-level entry is itself a symlink out,
# or a directory component higher up resolves elsewhere. Never used to decide
# whether to descend INTO a directory's contents: find/rm below already never
# follow a symlink to reach something outside the tree they were pointed at.
escapes_tmp_root() {
  local name=$1 real
  real=$(cd "$TMP_ROOT" 2>/dev/null && readlink -f -- "$name" 2>/dev/null) || return 0
  case "$real" in
    "$TMP_ROOT"/*|"$TMP_ROOT") return 1 ;;
    *) return 0 ;;
  esac
}

# Newest mtime age, in whole seconds, of <path> or anything under it
# (symlinks excluded from the scan so a symlinked-out target is never stat'd).
# A directory's OWN mtime only changes when its immediate entries change, not
# when a file deep inside is rewritten in place, so this recurses rather than
# trusting the top-level stat.
newest_mtime_age() {
  local path=$1 newest now
  newest=$(find "$path" -xdev ! -type l -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1)
  [ -n "$newest" ] || newest=0
  now=$(date +%s)
  if [ "$newest" -gt "$now" ]; then
    printf '0\n'
  else
    printf '%s\n' "$(( now - newest ))"
  fi
}

LSOF_AVAILABLE=1
command -v lsof >/dev/null 2>&1 || LSOF_AVAILABLE=0

# True (0) when some process holds a file handle anywhere within <path>'s
# tree right now, or when that cannot be determined (fail safe: treat
# uncertainty as "in use"). Deliberately NOT bin/fm-lock-lib.sh's
# fm_lock_has_live_holder: that proof answers "does a process hold this EXACT
# path open", which is right for a single lock file but wrong here - a live
# agent scratch directory routinely has its top-level dir untouched while a
# process holds a file two levels down open (a log redirect, a background
# task's output file), so this needs `lsof +D`'s recursive tree scan instead.
path_has_open_handle() {
  local path=$1 out rc lines
  [ "$LSOF_AVAILABLE" -eq 1 ] || return 0
  out=$(timeout "$LSOF_TIMEOUT" lsof +D "$path" 2>/dev/null)
  rc=$?
  [ "$rc" -ne 124 ] || return 0
  # lsof's own exit status is unreliable here: on this host it still exits
  # nonzero on a clean match because of unrelated warnings (unstatable
  # tracefs/overlay mounts from OTHER processes) it emits while resolving the
  # match - verified empirically, see docs/configuration.md. Line count is the
  # reliable signal: a header-only or empty result means no match.
  lines=$(printf '%s\n' "$out" | grep -c . || true)
  [ "$lines" -gt 1 ]
}

classify_candidate() {  # <path> <label> <protect-reason-or-empty>
  local path=$1 label=$2 protect_reason=$3 age
  if [ -n "$protect_reason" ]; then
    log_and_report skip "$label" "$protect_reason"
    return 0
  fi
  if escapes_tmp_root "${path#"$TMP_ROOT"/}"; then
    log_and_report skip "$label" "resolves outside $TMP_ROOT (symlink-escape guard)"
    return 0
  fi
  if [ ! -L "$path" ] && mountpoint -q -- "$path" 2>/dev/null; then
    log_and_report skip "$label" "is itself a separate filesystem mount point"
    return 0
  fi
  age=$(newest_mtime_age "$path")
  if [ "$age" -lt "$AGE_SECS" ]; then
    log_and_report skip "$label" "modified ${age}s ago, within ${AGE_HOURS}h threshold"
    return 0
  fi
  if path_has_open_handle "$path"; then
    log_and_report skip "$label" "open file handle detected (or undeterminable)"
    return 0
  fi
  if [ "$APPLY" -eq 1 ]; then
    if rm -rf -- "$path" 2>/dev/null; then
      log_and_report removed "$label" "stale, idle ${age}s (>= ${AGE_HOURS}h), no open handle"
    else
      log_and_report skip "$label" "removal failed"
    fi
  else
    log_and_report would-remove "$label" "stale, idle ${age}s (>= ${AGE_HOURS}h), no open handle"
  fi
}

# --- build the live-session protection set --------------------------------
LIVE_IDS_FILE=$(mktemp)
LIVE_SANITIZED_FILE=$(mktemp)
cleanup_tmp_files() { rm -f "$LIVE_IDS_FILE" "$LIVE_SANITIZED_FILE"; }
trap cleanup_tmp_files EXIT

while IFS=$'\t' read -r id wt; do
  [ -n "$id" ] && printf '%s\n' "$id" >> "$LIVE_IDS_FILE"
  [ -n "$wt" ] && printf '%s\n' "$(fm_tmp_claude_sanitize "$wt")" >> "$LIVE_SANITIZED_FILE"
done < <(fm_tmp_live_tasks "$FM_ROOT")

is_live_task_id() {
  [ -s "$LIVE_IDS_FILE" ] && grep -qFx -- "$1" "$LIVE_IDS_FILE"
}
is_live_sanitized_worktree() {
  [ -s "$LIVE_SANITIZED_FILE" ] && grep -qFx -- "$1" "$LIVE_SANITIZED_FILE"
}

CLAUDE_SCRATCH_NAME="claude-$(id -u)"
apply_note=""
[ "$APPLY" -eq 1 ] || apply_note=" (dry run; pass --apply to remove)"
echo "fm-tmp-sweep: scanning $TMP_ROOT, age threshold ${AGE_HOURS}h${apply_note}"

# find, not a shell glob, enumerates both passes below: a glob needs a
# dotglob dance to also match hidden entries and still silently misses an
# oddity like "..foo", while `find -maxdepth 1 -mindepth 1` lists every
# direct child (dotfiles included, "." and ".." excluded) with no special case.

# --- pass 1: every top-level /tmp entry except the claude scratch container -
while IFS= read -r -d '' entry; do
  name=$(basename "$entry")
  [ "$name" = "$CLAUDE_SCRATCH_NAME" ] && continue

  reason=""
  if is_protected_name "$name"; then
    reason="protected system/service path"
  elif [ "${name#fm-}" != "$name" ] && is_live_task_id "${name#fm-}"; then
    reason="live task tmp root (state/${name#fm-}.meta)"
  fi
  classify_candidate "$entry" "$entry" "$reason"
done < <(find "$TMP_ROOT" -xdev -maxdepth 1 -mindepth 1 -print0 2>/dev/null)

# --- pass 2: the claude scratch container's own children only, never the
# container itself (many sessions, past and present, share one parent) ------
CLAUDE_ROOT="$TMP_ROOT/$CLAUDE_SCRATCH_NAME"
if [ -d "$CLAUDE_ROOT" ] && [ ! -L "$CLAUDE_ROOT" ] && ! escapes_tmp_root "$CLAUDE_SCRATCH_NAME"; then
  while IFS= read -r -d '' entry; do
    name=$(basename "$entry")
    reason=""
    if [ -d "$entry" ] && is_live_sanitized_worktree "$name"; then
      reason="live worktree's harness scratch"
    fi
    classify_candidate "$entry" "$CLAUDE_SCRATCH_NAME/$name" "$reason"
  done < <(find "$CLAUDE_ROOT" -xdev -maxdepth 1 -mindepth 1 -print0 2>/dev/null)
fi

[ "$LSOF_AVAILABLE" -eq 1 ] || echo "fm-tmp-sweep: warning: lsof not on PATH; every candidate is treated as possibly in use (nothing removed this run)"
echo "fm-tmp-sweep: done; see $LOG_FILE"
