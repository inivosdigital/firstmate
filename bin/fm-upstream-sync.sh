#!/usr/bin/env bash
# fm-upstream-sync.sh - the scheduled upstream-template drift sweep.
#
# firstmate's `upstream` remote (kunchenguid/firstmate) is the read-only parent
# template: it can never be pushed or merged from here, so local `main` and
# `upstream/main` drift apart until somebody deliberately reconciles them. This
# script is the scheduled DETECTION half of that routine, and nothing more. It
# notices new upstream commits and queues one actionable reconciliation request
# for firstmate; the reconciliation itself - branching, the pinned merge in an
# isolated copy, the fork-behavior inventory, review, and the captain's landing
# approval - belongs to the `upstream-reconciliation` skill and to the existing
# task, backlog, and landing tools it drives. Cron never merges and never
# spawns an agent.
#
# bin/fm-bootstrap.sh's UPSTREAM_DRIFT line is a separate, thresholded session
# FYI computed WITHOUT fetching. This script owns the scheduled fetch, the
# durable sweep outcome, and intake de-duplication; docs/configuration.md
# "Upstream drift watch" routes an operator between them.
#
# Usage:
#   fm-upstream-sync.sh sweep                  the scheduled entry point
#   fm-upstream-sync.sh status                 durable evidence only, no network
#   fm-upstream-sync.sh install-cron [--dry-run]
#
# Subcommands:
#   sweep         Bounded `git fetch upstream`, then measure local main against
#                 upstream/main. No new upstream commits is a SUCCESS recorded
#                 as result=no-change; a failed or timed-out fetch is a FAILURE
#                 recorded with a distinct reason, and never reports no-change.
#                 New upstream commits queue exactly one durable intake unless
#                 one of the de-duplication owners below already covers them.
#   status        Print the last success, the last failure, the last published
#                 intake, and anything saved but not yet announced, from durable
#                 records. No network, no wake.
#   install-cron  Idempotently install the sweep in the user crontab, migrating
#                 off this home's legacy fm-upstream-drift-check.sh job. Every
#                 entry that is not provably this installation's own is
#                 preserved byte-for-byte, including another firstmate home's
#                 scheduled sweep.
#
# EVERY SWEEP IS BOUNDED END TO END. The fetch is not the only thing that can
# wait forever: reading the backlog backend and appending a wake both take
# locks or spawn helpers that an ordinary contended or wedged host can stall.
# FM_UPSTREAM_SYNC_TOTAL_TIMEOUT caps the whole measured operation (fetch,
# measurement, backlog read) and every step is additionally capped by its own
# bound, whichever is smaller. Notification is bounded separately by
# FM_UPSTREAM_SYNC_STEP_TIMEOUT rather than out of that budget, so a sweep that
# ran out of time can still say so instead of failing silently. The sweep lock
# is released on every exit path, including a signal.
#
# De-duplication reads the EXISTING owners rather than keeping a second task
# state of its own, in this order:
#   1. this routine already published intake for this exact upstream head, so an
#      unreconciled fork is not re-reported every day (last-intake below);
#   2. the intake note this routine last ANNOUNCED is still unacknowledged in
#      the inbox, so firstmate has not even read the previous request
#      (bin/fm-inbox.sh owns that record and its acknowledgement). Announced is
#      the load-bearing word: a note bin/fm-inbox.sh saved but could not wake
#      firstmate for is an unfinished publication, not a delivered request, and
#      is re-announced (below) rather than counted here;
#   3. the reconciliation backlog item is filed and NOT held - queued for
#      dispatch, in flight, or waiting on the captain's landing approval - so an
#      actionable request already exists (tasks-axi owns the item; this script
#      only reads it).
# A HELD item deliberately does NOT suppress intake, because suppressing on one
# would leave the sweep inert for as long as the hold stands. That is a
# REPORTING decision and nothing more: this routine has no authority to release
# a hold and never asks for one to be lifted. The same id can be held as this
# home's legacy drift reminder OR as a landing or decision gate on a
# reconciliation already under review, and only the captain's recorded
# instructions say which. So the note repeats the hold's own recorded kind,
# reason and date verbatim and routes the reader to `captain-hold-lifecycle` to
# reconcile it. Rule 1 still bounds this to one note per upstream head.
#
# A scheduled sweep holds no session lock, so it never writes the backlog. It
# queues a note and firstmate files the item.
#
# Publication is at-least-once, not exactly-once. The note is published before
# the receipt is recorded, so an interruption between the two republishes at the
# next sweep rather than going permanently silent about work nobody was told
# about. The opposite order would trade a duplicate note for a lost request.
#
# Exit codes:
#   0  success (including result=no-change)
#   1  usage error, invalid configuration, or a refusal
#   2  the fetch failed or timed out (offline; NOT "no changes"), the sweep ran
#      out of its budget, or intake could not be queued or announced
#   3  another sweep holds the lock
#
# Durable records under <state>/upstream-sync/:
#   last-success    the last sweep that completed, with its result
#   last-failure    the last sweep that failed, with its distinct reason
#   last-intake     the upstream head this routine last published AND announced
#                   intake for, with the note id that carried it
#   unannounced-intake   an intake note bin/fm-inbox.sh saved but could not
#                   announce; the next sweep re-announces that same note through
#                   bin/fm-inbox.sh rather than treating it as delivered
#   unannounced-failure  the same, for a failure report
#   failure-episode the reason of the failure already announced, so a continuing
#                   failure stays durable without a note every single day
#   cron.log        raw scheduled-run output, capped; the installed cron line
#                   appends here instead of discarding it
#
# Environment:
#   FM_ROOT_OVERRIDE                  the firstmate checkout to sweep
#   FM_HOME / FM_STATE_OVERRIDE       operational home / durable records
#   FM_DATA_OVERRIDE                  durable private fleet records (backlog)
#   FM_UPSTREAM_SYNC_FETCH_TIMEOUT    seconds allowed for the fetch (default 60)
#   FM_UPSTREAM_SYNC_FETCH_KILL_GRACE seconds between a bounded command's
#                                     SIGTERM and its SIGKILL (default 10)
#   FM_UPSTREAM_SYNC_STEP_TIMEOUT     seconds allowed for one helper call: the
#                                     backlog read, a note publication, a
#                                     re-announcement (default 60)
#   FM_UPSTREAM_SYNC_TOTAL_TIMEOUT    seconds allowed for the whole measured
#                                     sweep (default 300)
#   FM_UPSTREAM_SYNC_TIMEOUT_TOOL     auto (default) | timeout | gtimeout | none;
#                                     `none` forces the built-in bounded fallback
#                                     on a host whose timeout(1) is unusable
#   FM_UPSTREAM_SYNC_SCHEDULE         cron schedule to install (default 35 4 * * *)
#   FM_UPSTREAM_SYNC_CRON_PATH        PATH the installed cron line runs under.
#                                     Default: this process's own PATH, keeping
#                                     only the directories that actually provide
#                                     a tool the sweep needs (git, coreutils,
#                                     tasks-axi, gh-axi, the configured git
#                                     credential helper), in their original
#                                     order. Whatever is used is then verified
#                                     under a cron-shaped environment before the
#                                     line is written; cron's own PATH would not
#                                     find a node-managed tasks-axi
#   FM_UPSTREAM_SYNC_TASK_ID          reconciliation backlog id (default
#                                     upstream-drift-alert, the id the legacy
#                                     job already files under)
# Every one of those selections that the script cannot re-derive from its own
# location is written into the installed cron line. cron hands a job almost no
# environment, and a dropped FM_HOME would silently sweep into a different home
# while still logging into this one.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SYNC_DIR="$STATE/upstream-sync"

# The helpers this script drives (bin/fm-inbox.sh, and bin/fm-wake-lib.sh
# through it) select their home from the environment, so export the resolved
# selection instead of re-deriving it per call site.
export FM_HOME
export FM_STATE_OVERRIDE="$STATE"
export FM_DATA_OVERRIDE="$DATA"

LAST_SUCCESS="$SYNC_DIR/last-success"
LAST_FAILURE="$SYNC_DIR/last-failure"
FAILURE_EPISODE="$SYNC_DIR/failure-episode"
LAST_INTAKE="$SYNC_DIR/last-intake"
UNANNOUNCED_INTAKE="$SYNC_DIR/unannounced-intake"
UNANNOUNCED_FAILURE="$SYNC_DIR/unannounced-failure"
CRON_LOG="$SYNC_DIR/cron.log"
SWEEP_LOCK="$SYNC_DIR/.sweep.lock"

CRON_LOG_MAX_LINES=2000
FETCH_TIMEOUT="${FM_UPSTREAM_SYNC_FETCH_TIMEOUT:-60}"
FETCH_KILL_GRACE="${FM_UPSTREAM_SYNC_FETCH_KILL_GRACE:-10}"
STEP_TIMEOUT="${FM_UPSTREAM_SYNC_STEP_TIMEOUT:-60}"
TOTAL_TIMEOUT="${FM_UPSTREAM_SYNC_TOTAL_TIMEOUT:-300}"
SCHEDULE="${FM_UPSTREAM_SYNC_SCHEDULE:-35 4 * * *}"
DEFAULT_TASK_ID=upstream-drift-alert
TASK_ID="${FM_UPSTREAM_SYNC_TASK_ID:-$DEFAULT_TASK_ID}"
SELF_SCRIPT_NAME=fm-upstream-sync.sh
SELF_PATH="$SCRIPT_DIR/$SELF_SCRIPT_NAME"
# Binaries a scheduled sweep resolves through PATH. The install refuses rather
# than writing a cron line whose environment cannot resolve all of these.
CRON_PATH_REQUIRED='git awk sed grep find date mktemp mkdir mv rm cat head tail cut tr wc dirname basename sleep'
# Resolved when present and kept in the generated PATH, but not required: the
# sweep degrades in a defined, recorded way without each of them.
CRON_PATH_PREFERRED='tasks-axi gh-axi timeout gtimeout'
LEGACY_SCRIPT_NAME=fm-upstream-drift-check.sh
# Distinct markers per note KIND. A pending intake and a pending failure report
# are different facts, and a stuck failure note must never read as "the
# reconciliation request is already waiting" and suppress real intake.
INTAKE_MARKER='[upstream-sync:intake]'
FAILURE_MARKER='[upstream-sync:failure]'
# The marker names the home it was installed for. A second firstmate home on
# this user's crontab owns its own marker and its own job, and this one must
# never adopt or delete either.
CRON_MARKER="# fm-upstream-sync home=$FM_HOME (managed by bin/fm-upstream-sync.sh install-cron)"

CRONTAB_READ_ERROR=""
CRON_ASSIGNMENTS=""
SWEEP_REASON=""
SWEEP_DEADLINE=""
SWEEP_LOCK_HELD=0
BOUND_TOOL=""
BOUND_TOOL_READY=0
PUBLISHED_NOTE_ID=""

die() { printf 'fm-upstream-sync: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
mktemp_here() { mktemp "${TMPDIR:-/tmp}/fm-upstream-sync.XXXXXX"; }

usage() {
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "${BASH_SOURCE[0]}"
}

git_repo() { git -C "$FM_ROOT" "$@"; }

# First value of <key>= in a key=value record, or nothing.
record_get() { # <file> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

# Publish a key=value record atomically so a reader never sees a half-written
# one and an interrupted write cannot leave a truncated record behind.
record_put() { # <file> <line>...
  local file=$1 dir tmp
  shift
  dir=$(dirname "$file")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.$(basename "$file").XXXXXX") || return 1
  printf '%s\n' "$@" > "$tmp"
  mv "$tmp" "$file"
}

# Trim <file> to its last <max> lines IN PLACE, keeping the inode. The installed
# cron line holds an O_APPEND fd on cron.log for the whole run, so replacing the
# file by rename would send the rest of that run's output to an unlinked inode.
trim_log() { # <file> <max>
  local file=$1 max=$2 tmp
  [ -f "$file" ] || return 0
  [ "$(wc -l < "$file" | tr -d ' ')" -gt "$max" ] || return 0
  tmp=$(mktemp_here) || return 0
  if tail -n "$max" "$file" > "$tmp"; then
    cat "$tmp" > "$file"
  fi
  rm -f "$tmp"
}

# --- configuration ----------------------------------------------------------

# Which external timeout tool to use, if any. `none` selects the built-in
# fallback, which is otherwise unreachable on a host that has timeout(1). An
# unusable value RETURNS non-zero: refusing from inside a command substitution
# would be swallowed by the surrounding conditional and the empty result would
# read as "no tool configured", turning an advertised refusal into a silent
# fallback and a falsely successful sweep.
timeout_tool() {
  case "${FM_UPSTREAM_SYNC_TIMEOUT_TOOL:-auto}" in
    none) return 0 ;;
    timeout|gtimeout) printf '%s\n' "$FM_UPSTREAM_SYNC_TIMEOUT_TOOL" ;;
    auto)
      if command -v timeout >/dev/null 2>&1; then printf 'timeout\n'
      elif command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout\n'
      fi ;;
    *)
      printf 'fm-upstream-sync: FM_UPSTREAM_SYNC_TIMEOUT_TOOL must be auto, timeout, gtimeout or none (got: %s)\n' \
        "$FM_UPSTREAM_SYNC_TIMEOUT_TOOL" >&2
      return 1 ;;
  esac
}

# Refuse a misconfigured run BEFORE it starts, where the refusal is visible and
# nothing durable has been touched yet.
validate_config() {
  local name value
  for name in FM_UPSTREAM_SYNC_FETCH_TIMEOUT FM_UPSTREAM_SYNC_FETCH_KILL_GRACE \
              FM_UPSTREAM_SYNC_STEP_TIMEOUT FM_UPSTREAM_SYNC_TOTAL_TIMEOUT; do
    value=${!name:-}
    [ -n "$value" ] || continue
    case "$value" in
      *[!0-9]*) die "$name must be a whole number of seconds (got: $value)" ;;
    esac
    [ "$value" -gt 0 ] || die "$name must be greater than zero (got: $value)"
  done
  timeout_tool >/dev/null || exit 1
  # Resolved here, in the parent shell, so the probe is paid once and every
  # later subshell inherits the answer instead of re-running it.
  resolve_bound_tool || exit 1
}

# --- bounded execution ------------------------------------------------------

# Resolve the escalating timeout tool once. A timeout(1) whose -k this host does
# not support is treated as no tool at all: its plain form sends SIGTERM and
# then waits forever, which is not a bound against a command that ignores it.
resolve_bound_tool() {
  [ "$BOUND_TOOL_READY" -eq 0 ] || return 0
  BOUND_TOOL=$(timeout_tool) || return 1
  if [ -n "$BOUND_TOOL" ] && ! "$BOUND_TOOL" -k 1 1 true >/dev/null 2>&1; then
    BOUND_TOOL=""
  fi
  BOUND_TOOL_READY=1
}

# No usable timeout(1). Run the command in its own process group and escalate
# SIGTERM -> SIGKILL, because a `kill -TERM` followed by a bare `wait` is not a
# bound at all: a child that ignores TERM leaves the scheduled run hanging
# forever, which is exactly what the deadline exists to prevent.
run_bounded_fallback() { # <seconds> <cmd>...
  local seconds=$1 pid start monitor_was_on=0
  shift
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$@" &
  pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    [ "$(( $(date +%s) - start ))" -lt "$seconds" ] || break
    sleep 1
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || return $?
    return 0
  fi

  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    [ "$(( $(date +%s) - start ))" -lt "$FETCH_KILL_GRACE" ] || break
    sleep 1
  done
  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  # Deliberately no `wait` here. A process wedged in uninterruptible I/O would
  # never be reaped and the promised bound would become a hang; the kernel
  # reparents and reaps it when this shell exits.
  return 124
}

# Run <cmd> under a hard deadline. Returns the command's status, 124 when the
# deadline fired, or 125 when the configured timeout selector is unusable.
run_bounded() { # <seconds> <cmd>...
  local seconds=$1 rc=0
  shift
  resolve_bound_tool || return 125
  if [ -n "$BOUND_TOOL" ]; then
    "$BOUND_TOOL" -k "$FETCH_KILL_GRACE" "$seconds" "$@" || rc=$?
    return "$rc"
  fi
  run_bounded_fallback "$seconds" "$@"
}

# --- the sweep's own budget -------------------------------------------------

start_budget() { SWEEP_DEADLINE=$(( $(date +%s) + TOTAL_TIMEOUT )); }

budget_left() {
  local left
  [ -n "$SWEEP_DEADLINE" ] || { printf '%s\n' "$TOTAL_TIMEOUT"; return 0; }
  left=$(( SWEEP_DEADLINE - $(date +%s) ))
  [ "$left" -gt 0 ] || left=0
  printf '%s\n' "$left"
}

budget_spent() { [ "$(budget_left)" -eq 0 ]; }

# One measured step of the sweep, bounded by the smaller of its own deadline and
# what is left of the whole sweep's budget. Notification does NOT go through
# here: a sweep that ran out of budget must still be able to report why.
run_step() { # <seconds> <cmd>...
  local seconds=$1 left
  shift
  left=$(budget_left)
  [ "$left" -gt 0 ] || return 124
  [ "$seconds" -le "$left" ] || seconds=$left
  run_bounded "$seconds" "$@"
}

# --- durable outcome records ------------------------------------------------

record_success() { # <result> <upstream_sha> <local_sha> <behind> <ahead> <backlog>
  record_put "$LAST_SUCCESS" \
    "schema=fm-upstream-sync-outcome.v1" \
    "at=$(now_iso)" \
    "epoch=$(date +%s)" \
    "result=$1" \
    "upstream_sha=$2" \
    "local_sha=$3" \
    "behind=$4" \
    "ahead=$5" \
    "backlog_item=$6"
  # A completed sweep ends whatever failure episode preceded it, so the next
  # failure is announced again instead of being swallowed as a repeat.
  rm -f "$FAILURE_EPISODE"
}

# A failure is durable AND, on the first failure of an episode, announced once.
# Announcing every day would turn a week offline into a week of noise, while
# announcing never is exactly the silent failure the legacy job's
# `>/dev/null 2>&1` produced.
record_failure() { # <reason> <detail>
  local reason=$1 detail=$2 previous=""
  record_put "$LAST_FAILURE" \
    "schema=fm-upstream-sync-outcome.v1" \
    "at=$(now_iso)" \
    "epoch=$(date +%s)" \
    "reason=$reason" \
    "detail=$detail"
  [ -f "$FAILURE_EPISODE" ] && previous=$(cat "$FAILURE_EPISODE" 2>/dev/null || true)
  [ "$previous" = "$reason" ] && return 0
  # Mark the episode announced only AFTER the note is durable AND announced.
  # Writing the marker first would let one failed publication silence this
  # reason forever, which is the same silent failure in a new place.
  if publish_note "$FAILURE_MARKER" "$FAILURE_MARKER upstream sync sweep failed ($reason): $detail. Upstream was not reached, so the last recorded drift is stale rather than clean. Evidence: $LAST_FAILURE"; then
    printf '%s\n' "$reason" > "$FAILURE_EPISODE"
    return 0
  fi
  if [ -n "$PUBLISHED_NOTE_ID" ]; then
    # Saved but not announced: remember which note, so the next sweep wakes
    # firstmate for THAT note instead of writing a second copy of it.
    record_put "$UNANNOUNCED_FAILURE" \
      "schema=fm-upstream-sync-unannounced.v1" \
      "at=$(now_iso)" \
      "note=$PUBLISHED_NOTE_ID" \
      "reason=$reason"
    say "WARNING failure note $PUBLISHED_NOTE_ID is saved but firstmate was not woken; the next sweep re-announces it"
  else
    say "WARNING could not queue the failure note; it stays unannounced and the next sweep retries"
  fi
}

# --- durable intake ---------------------------------------------------------

# One durable, separately acknowledged record plus one wake, through the inbox
# that already owns both. Returns 0 only when the note is BOTH saved and
# announced, and always leaves the note id in PUBLISHED_NOTE_ID - including when
# it could not be announced, which is the one state the next sweep has to
# recover from. The id is a global rather than stdout on purpose: capturing it
# would put this call in a subshell and lose exactly that record.
publish_note() { # <marker> <body>
  local marker=$1 body=$2 out rc=0 id mark
  PUBLISHED_NOTE_ID=""
  mark="$SYNC_DIR/.publish-mark"
  mkdir -p "$SYNC_DIR"
  : > "$mark"
  out=$(run_bounded "$STEP_TIMEOUT" "$SCRIPT_DIR/fm-inbox.sh" note - <<< "$body") || rc=$?
  id=$(printf '%s\n' "$out" | sed -n 's/^queued //p' | head -1)
  # A publication killed at its deadline loses its buffered stdout, so fall back
  # to the inbox itself: any note carrying this marker that appeared after the
  # call started is the one this call wrote.
  [ -n "$id" ] || id=$(pending_note_since "$marker" "$mark")
  rm -f "$mark"
  PUBLISHED_NOTE_ID=$id
  [ "$rc" -eq 0 ] && [ -n "$id" ]
}

# Newest pending note carrying <marker>, optionally only one newer than <ref>.
pending_note_since() { # <marker> [reffile] -> note id or nothing
  local marker=$1 ref=${2:-} f newest=""
  for f in "$STATE"/inbox/*.note; do
    [ -e "$f" ] || break
    grep -qF "$marker" "$f" || continue
    [ -z "$ref" ] || [ "$f" -nt "$ref" ] || continue
    [ -z "$newest" ] || [ "$f" -nt "$newest" ] || continue
    newest=$f
  done
  [ -n "$newest" ] || return 0
  basename "$newest" .note
}

# Wake firstmate for a note that is already saved. bin/fm-inbox.sh owns both the
# note record and the wake payload, so the retry goes through it rather than
# reproducing the payload here.
announce_note() { # <note id>
  run_bounded "$STEP_TIMEOUT" "$SCRIPT_DIR/fm-inbox.sh" wake "$1" >/dev/null 2>&1
}

# The note id an unannounced-note record refers to, or nothing when there is no
# pending note left to announce.
saved_note_id() { # <record file> <marker>
  local file=$1 marker=$2 id
  id=$(record_get "$file" note)
  [ -n "$id" ] || id=$(pending_note_since "$marker")
  [ -n "$id" ] || return 0
  [ -f "$STATE/inbox/$id.note" ] || return 0
  printf '%s\n' "$id"
}

# True when the intake note this routine last ANNOUNCED is still waiting for
# firstmate. last-intake is written only after a note is both saved and
# announced, so a saved-but-silent note can never stand in for a delivered
# request here. A pending FAILURE note is a different fact and is never counted.
announced_intake_pending() {
  local id
  id=$(record_get "$LAST_INTAKE" note)
  [ -n "$id" ] || return 1
  [ -f "$STATE/inbox/$id.note" ]
}

# Print "<bearing>|<detail>" for the reconciliation item, from tasks-axi:
#   open     filed and not held: queued for dispatch, in flight, or awaiting the
#            captain's landing approval. An actionable request already exists.
#   held     filed and held. The detail repeats the hold's own recorded kind,
#            reason and date, because this routine reports a hold and never
#            interprets or releases one.
#   absent   no such item, or it is done.
#   unknown  the backlog backend could not be read from here at all.
# `unknown` is reported rather than folded into `absent`, because a scheduled
# run whose PATH lacks tasks-axi would otherwise silently look like "nothing is
# filed" and the note would not say that it could not check.
reconciliation_state() {
  local out rc=0 state held kind reason until_
  command -v tasks-axi >/dev/null 2>&1 || { printf 'unknown|tasks-axi is not on this run PATH\n'; return 0; }
  [ -f "$DATA/backlog.md" ] || { printf 'absent|\n'; return 0; }
  out=$(run_step "$STEP_TIMEOUT" tasks-axi show "$TASK_ID" --file "$DATA/backlog.md" 2>&1) || rc=$?
  case "$rc" in
    0) ;;
    124|125|137) printf 'unknown|the backlog read did not answer within its bound\n'; return 0 ;;
    *)
      case "$out" in
        *NOT_FOUND*) printf 'absent|\n' ;;
        *) printf 'unknown|the backlog backend refused the read\n' ;;
      esac
      return 0 ;;
  esac
  state=$(printf '%s\n' "$out" | sed -n 's/^ *state: *//p' | head -1)
  held=$(printf '%s\n' "$out" | sed -n 's/^ *held: *//p' | head -1)
  case "$state" in
    ''|done|done*|closed*|archived*) printf 'absent|\n'; return 0 ;;
  esac
  [ "$held" = "yes" ] || { printf 'open|\n'; return 0; }
  kind=$(printf '%s\n' "$out" | sed -n 's/^ *hold_kind: *//p' | head -1)
  until_=$(printf '%s\n' "$out" | sed -n 's/^ *hold_until: *//p' | head -1)
  reason=$(printf '%s\n' "$out" | sed -n 's/^ *hold_reason: *//p' | head -1 | cut -c1-240)
  printf 'held|state=%s hold_kind=%s hold_until=%s hold_reason=%s\n' \
    "$state" "${kind:--}" "${until_:--}" "${reason:--}"
}

# The two halves of that record. A hold reason may itself contain '|', so the
# bearing is the first field and the detail is everything after it.
recon_bearing() { printf '%s\n' "${1%%|*}"; }
recon_detail()  { printf '%s\n' "${1#*|}"; }

intake_body() { # <upstream> <local> <base> <behind> <ahead> <bearing> <detail>
  local plural=s
  local -a tail=()
  [ "$4" != 1 ] || plural=""
  case "$6" in
    held)
      # Report the hold exactly as recorded and hand it to its own owner. This
      # routine cannot tell a legacy drift reminder from a landing or decision
      # gate on work already under review, and has no authority to release
      # either, so it must never ask for one to be lifted.
      tail=(
        "Backlog item $TASK_ID exists and is HELD ($7)."
        "That hold may be this home's legacy drift reminder, or a landing or decision gate on a reconciliation already under review. This routine only reports it and grants no authority to release it."
        "Inspect and reconcile the hold against the captain's recorded instructions with the captain-hold-lifecycle skill before filing anything new, and do not file a duplicate item."
      ) ;;
    unknown)
      tail=("The backlog backend could not be read from this run (${7:-no reason recorded}), so an already-filed request could not be checked for; confirm $TASK_ID before filing a second one.") ;;
    *)
      tail=("File or refresh backlog item $TASK_ID, then run the reconciliation with the upstream-reconciliation skill.") ;;
  esac
  printf '%s\n' \
    "$INTAKE_MARKER upstream template has $4 new commit$plural to reconcile into local main." \
    "upstream=${1:0:12} local=${2:0:12} merge_base=${3:0:12} behind=$4 ahead=$5" \
    "${tail[@]}" \
    "The merge is never automated and landing is still the captain's call."
}

# --- fetch and measurement --------------------------------------------------

# Sets SWEEP_REASON and returns 1 on failure; returns 0 on a real fetch.
fetch_upstream() {
  local rc=0
  SWEEP_REASON=""
  run_step "$FETCH_TIMEOUT" git -C "$FM_ROOT" fetch --quiet upstream 2>/dev/null || rc=$?
  case "$rc" in
    0) return 0 ;;
    125) SWEEP_REASON=config-invalid ;;
    124|137)
      if budget_spent; then SWEEP_REASON=sweep-timeout; else SWEEP_REASON=fetch-timeout; fi ;;
    *) SWEEP_REASON=fetch-failed ;;
  esac
  return 1
}

# Capture a bounded git command's stdout into <var>. Returns 124 when the bound
# or the sweep's budget stopped it, and 1 when git itself said no.
git_out() { # <var> <git args>...
  local __var=$1 __out __rc=0
  shift
  __out=$(run_step "$STEP_TIMEOUT" git -C "$FM_ROOT" "$@" 2>/dev/null) || __rc=$?
  case "$__rc" in
    0) printf -v "$__var" '%s' "$__out" ;;
    124|125|137) return 124 ;;
    *) return 1 ;;
  esac
}

# Sets UPSTREAM_SHA, LOCAL_SHA, MERGE_BASE, BEHIND, AHEAD from local refs only,
# so it must run in this shell and report through SWEEP_REASON rather than
# stdout. Returns 1 when a bounded read does not answer; a genuinely
# misconfigured checkout is still a refusal, not a recorded failure.
measure() {
  local rc=0
  SWEEP_REASON=
  git_out MEASURE_REMOTE remote get-url upstream || rc=$?
  [ "$rc" -ne 124 ] || { SWEEP_REASON=measure-timeout; return 1; }
  [ "$rc" -eq 0 ] || die "no 'upstream' remote in $FM_ROOT"

  rc=0
  git_out UPSTREAM_SHA rev-parse --verify --quiet refs/remotes/upstream/main || rc=$?
  [ "$rc" -ne 124 ] || { SWEEP_REASON=measure-timeout; return 1; }
  [ "$rc" -eq 0 ] || die "no refs/remotes/upstream/main in $FM_ROOT"

  rc=0
  git_out LOCAL_SHA rev-parse --verify --quiet refs/heads/main || rc=$?
  [ "$rc" -ne 124 ] || { SWEEP_REASON=measure-timeout; return 1; }
  [ "$rc" -eq 0 ] || die "no local main branch in $FM_ROOT"

  rc=0
  git_out MERGE_BASE merge-base "$LOCAL_SHA" "$UPSTREAM_SHA" || rc=$?
  [ "$rc" -ne 124 ] || { SWEEP_REASON=measure-timeout; return 1; }
  [ "$rc" -eq 0 ] || die "local main and upstream/main share no history"

  rc=0
  git_out BEHIND rev-list --count "$LOCAL_SHA..$UPSTREAM_SHA" || rc=$?
  [ "$rc" -eq 0 ] || { SWEEP_REASON=measure-timeout; return 1; }
  rc=0
  git_out AHEAD rev-list --count "$UPSTREAM_SHA..$LOCAL_SHA" || rc=$?
  [ "$rc" -eq 0 ] || { SWEEP_REASON=measure-timeout; return 1; }
}

# --- recovery ---------------------------------------------------------------

# A note bin/fm-inbox.sh saved but could not announce is the one state that must
# never be mistaken for a delivered request: nothing else in the fleet retries
# an unwoken captain note, and counting its mere presence as "already waiting"
# is what makes a detection routine go permanently quiet. Re-announce it here,
# through its own owner, before this sweep decides anything.
recover_unannounced_failure() {
  local id reason
  [ -f "$UNANNOUNCED_FAILURE" ] || return 0
  id=$(saved_note_id "$UNANNOUNCED_FAILURE" "$FAILURE_MARKER")
  if [ -z "$id" ]; then
    rm -f "$UNANNOUNCED_FAILURE"
    return 0
  fi
  if announce_note "$id"; then
    reason=$(record_get "$UNANNOUNCED_FAILURE" reason)
    [ -z "$reason" ] || printf '%s\n' "$reason" > "$FAILURE_EPISODE"
    rm -f "$UNANNOUNCED_FAILURE"
    say "recovered: saved failure note $id was announced on this run"
  else
    say "WARNING failure note $id is still saved and unannounced; the next sweep retries it"
  fi
}

# Returns 1 when the saved intake is still unannounced, so the caller stops
# rather than recording another successful sweep over a request nobody has been
# told about.
recover_unannounced_intake() {
  local id
  [ -f "$UNANNOUNCED_INTAKE" ] || return 0
  id=$(saved_note_id "$UNANNOUNCED_INTAKE" "$INTAKE_MARKER")
  if [ -z "$id" ]; then
    # Nothing left to announce: the note was never written, or somebody read and
    # acknowledged it out of band. Drift, if it still stands, is reported again
    # below because no receipt was ever recorded for it.
    rm -f "$UNANNOUNCED_INTAKE"
    return 0
  fi
  if ! announce_note "$id"; then
    record_failure intake-unannounced \
      "intake note $id is saved in $STATE/inbox but firstmate was never woken for it, and re-announcing it failed"
    say "FAILED intake-unannounced - saved note $id is still unannounced; upstream work has not been reported"
    return 1
  fi
  record_put "$LAST_INTAKE" \
    "schema=fm-upstream-sync-intake.v1" \
    "at=$(now_iso)" \
    "note=$id" \
    "upstream_sha=$(record_get "$UNANNOUNCED_INTAKE" upstream_sha)" \
    "local_sha=$(record_get "$UNANNOUNCED_INTAKE" local_sha)" \
    "behind=$(record_get "$UNANNOUNCED_INTAKE" behind)" \
    "ahead=$(record_get "$UNANNOUNCED_INTAKE" ahead)" \
    "backlog_item=$(record_get "$UNANNOUNCED_INTAKE" backlog_item)"
  rm -f "$UNANNOUNCED_INTAKE"
  say "recovered: saved intake note $id was announced on this run"
}

# --- sweep ------------------------------------------------------------------

release_sweep_lock() {
  [ "$SWEEP_LOCK_HELD" -eq 1 ] || return 0
  SWEEP_LOCK_HELD=0
  fm_lock_release "$SWEEP_LOCK" || true
}

# A signal must not leave the lock behind for the next scheduled run to trip
# over, and it must leave a durable reason rather than an unexplained gap.
sweep_interrupted() {
  record_put "$LAST_FAILURE" \
    "schema=fm-upstream-sync-outcome.v1" \
    "at=$(now_iso)" \
    "epoch=$(date +%s)" \
    "reason=sweep-interrupted" \
    "detail=the sweep was signalled before it finished" || true
  say "FAILED sweep-interrupted - the sweep was signalled before it finished"
  exit 2
}

cmd_sweep() {
  [ "$#" -eq 0 ] || die "sweep takes no arguments"
  validate_config
  mkdir -p "$SYNC_DIR"
  trim_log "$CRON_LOG" "$CRON_LOG_MAX_LINES"
  start_budget

  # STATE and FM_HOME are already set above and the library defers to them.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if ! fm_lock_try_acquire "$SWEEP_LOCK"; then
    say "sweep already running (lock held); this run did nothing"
    exit 3
  fi
  SWEEP_LOCK_HELD=1
  trap release_sweep_lock EXIT
  trap sweep_interrupted INT TERM HUP

  recover_unannounced_failure
  recover_unannounced_intake || exit 2

  if ! fetch_upstream; then
    record_failure "$SWEEP_REASON" "git fetch upstream in $FM_ROOT (bound ${FETCH_TIMEOUT}s, sweep budget ${TOTAL_TIMEOUT}s)"
    say "FAILED $SWEEP_REASON - upstream was not reached; the recorded drift is stale, not clean"
    exit 2
  fi

  if ! measure; then
    record_failure "$SWEEP_REASON" "reading local refs in $FM_ROOT did not finish inside the sweep budget"
    say "FAILED $SWEEP_REASON - the drift could not be measured; the recorded drift is stale, not clean"
    exit 2
  fi

  local recon_raw recon recon_why
  recon_raw=$(reconciliation_state)
  recon=$(recon_bearing "$recon_raw")
  recon_why=$(recon_detail "$recon_raw")

  if [ "$BEHIND" -eq 0 ]; then
    record_success no-change "$UPSTREAM_SHA" "$LOCAL_SHA" "$BEHIND" "$AHEAD" "$recon"
    say "no-change - no new upstream commits (local main is $AHEAD ahead)"
    return 0
  fi

  local suppressed=""
  if [ "$UPSTREAM_SHA" = "$(record_get "$LAST_INTAKE" upstream_sha)" ]; then
    suppressed="intake for this upstream head was already published"
  elif announced_intake_pending; then
    suppressed="an intake note is still waiting for firstmate"
  elif [ "$recon" = "open" ]; then
    suppressed="backlog item $TASK_ID is filed and not held"
  fi

  if [ -n "$suppressed" ]; then
    record_success intake-suppressed "$UPSTREAM_SHA" "$LOCAL_SHA" "$BEHIND" "$AHEAD" "$recon"
    say "behind=$BEHIND ahead=$AHEAD - no new intake: $suppressed"
    return 0
  fi

  # Publish first, then record. An interruption between the two leaves
  # last-intake unchanged, so the next sweep republishes rather than going
  # permanently silent about upstream work nobody was ever told about.
  local note
  if publish_note "$INTAKE_MARKER" \
      "$(intake_body "$UPSTREAM_SHA" "$LOCAL_SHA" "$MERGE_BASE" "$BEHIND" "$AHEAD" "$recon" "$recon_why")"; then
    note=$PUBLISHED_NOTE_ID
    record_put "$LAST_INTAKE" \
      "schema=fm-upstream-sync-intake.v1" \
      "at=$(now_iso)" \
      "note=$note" \
      "upstream_sha=$UPSTREAM_SHA" \
      "local_sha=$LOCAL_SHA" \
      "behind=$BEHIND" \
      "ahead=$AHEAD" \
      "backlog_item=$recon"
    record_success intake-published "$UPSTREAM_SHA" "$LOCAL_SHA" "$BEHIND" "$AHEAD" "$recon"
    say "intake-published $note - $BEHIND new upstream commits to reconcile (backlog item: $recon)"
    return 0
  fi
  if [ -n "$PUBLISHED_NOTE_ID" ]; then
    record_put "$UNANNOUNCED_INTAKE" \
      "schema=fm-upstream-sync-unannounced.v1" \
      "at=$(now_iso)" \
      "note=$PUBLISHED_NOTE_ID" \
      "upstream_sha=$UPSTREAM_SHA" \
      "local_sha=$LOCAL_SHA" \
      "behind=$BEHIND" \
      "ahead=$AHEAD" \
      "backlog_item=$recon"
  fi
  record_failure intake-failed "measured $BEHIND new upstream commits but could not queue the note"
  say "FAILED intake-failed - drift measured but the request was not queued"
  exit 2
}

# --- status -----------------------------------------------------------------

show_record() { # <label> <file> <empty-text>
  if [ -f "$2" ]; then
    say "--- $1 ---"
    cat "$2"
  else
    say "($3)"
  fi
  say ""
}

cmd_status() {
  say "=== upstream sync (durable records only, no network) ==="
  say "checkout   $FM_ROOT"
  say "home       $FM_HOME"
  say "records    $SYNC_DIR"
  say ""
  show_record "last successful sweep" "$LAST_SUCCESS" "no successful sweep recorded"
  show_record "last failed sweep" "$LAST_FAILURE" "no failed sweep recorded"
  show_record "last published intake" "$LAST_INTAKE" "no intake published yet"
  if [ -f "$UNANNOUNCED_INTAKE" ] || [ -f "$UNANNOUNCED_FAILURE" ]; then
    say "--- saved but NOT announced (the next sweep re-announces these) ---"
    [ ! -f "$UNANNOUNCED_INTAKE" ] || cat "$UNANNOUNCED_INTAKE"
    [ ! -f "$UNANNOUNCED_FAILURE" ] || cat "$UNANNOUNCED_FAILURE"
    say ""
  fi
  local recon_raw
  recon_raw=$(reconciliation_state)
  case "$(recon_bearing "$recon_raw")" in
    open) say "backlog item $TASK_ID is filed and not held; new intake stays suppressed until it is done" ;;
    held) say "backlog item $TASK_ID is HELD ($(recon_detail "$recon_raw")); a hold does not suppress intake, and this routine cannot release it" ;;
    unknown) say "backlog item $TASK_ID could not be read from here ($(recon_detail "$recon_raw")); intake is not suppressed by it" ;;
  esac
}

# --- cron install -----------------------------------------------------------

# Tool names that resolve this repo's configured git credential helper, so an
# HTTPS `git fetch upstream` still authenticates from cron. git accepts a bare
# name (`git-credential-<name>`), an absolute path, or a `!command` shell form.
credential_helper_tools() {
  local helper first
  helper=$(git_repo config --get credential.helper 2>/dev/null) || return 0
  [ -n "$helper" ] || return 0
  case "$helper" in
    '!'*)
      first=${helper#!}
      printf '%s\n' "${first%% *}" ;;
    /*) printf '%s\n' "$helper" ;;
    *) printf 'git-credential-%s\n' "$helper" ;;
  esac
}

# The PATH the installed line runs under. cron's own PATH is minimal and would
# not find a node-managed tasks-axi, so every sweep would report the backlog as
# unreadable. This does NOT substitute platform defaults for the installing
# shell's PATH: it KEEPS the captured directories, in their captured order, that
# actually provide a tool a sweep needs, and drops only the ones that provide
# none. A nested agent host accumulates the same directory many times over, and
# a crontab should carry the working path once rather than that accumulation.
cron_path() {
  local needed="" dir tool resolved out=""
  if [ -n "${FM_UPSTREAM_SYNC_CRON_PATH:-}" ]; then
    printf '%s\n' "$FM_UPSTREAM_SYNC_CRON_PATH"
    return 0
  fi
  for tool in $CRON_PATH_REQUIRED $CRON_PATH_PREFERRED $(credential_helper_tools); do
    case "$tool" in
      /*) resolved=$tool; [ -x "$resolved" ] || continue ;;
      *) resolved=$(command -v "$tool" 2>/dev/null) || continue ;;
    esac
    dir=$(dirname "$resolved")
    case ":$needed:" in *":$dir:"*) continue ;; esac
    needed="${needed:+$needed:}$dir"
  done
  # Emit in the captured PATH's own order so nothing's resolution changes.
  local IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    case ":$needed:" in *":$dir:"*) ;; *) continue ;; esac
    case ":$out:" in *":$dir:"*) continue ;; esac
    out="${out:+$out:}$dir"
  done
  printf '%s\n' "$out"
}

# Resolve a tool the way cron actually would: /bin/sh with an environment
# holding only what cron sets. Assuming the generated line works is exactly the
# mistake that leaves a scheduled job silently unable to run its own helpers.
resolves_under() { # <path> <tool>
  env -i HOME="${HOME:-/}" PATH="$1" SHELL=/bin/sh /bin/sh -c \
    "command -v -- '$2' >/dev/null 2>&1"
}

# Refuse a cron line whose environment cannot run the sweep. This runs BEFORE
# anything is written: a check that reports after the install has already
# happened is not a gate.
verify_cron_path() { # <path>
  local path=$1 tool missing=""
  for tool in $CRON_PATH_REQUIRED; do
    resolves_under "$path" "$tool" || missing="${missing:+$missing }$tool"
  done
  [ -z "$missing" ] || die "the cron environment could not resolve: $missing
  PATH would be: $path
  Set FM_UPSTREAM_SYNC_CRON_PATH to a PATH that resolves them, then re-run."
}

# Report what the optional tools resolve to, so a degraded sweep is a visible
# fact at install time rather than a surprise in the first run's records.
report_cron_environment() { # <path>
  local path=$1 tool resolved have_timeout=0
  for tool in $CRON_PATH_PREFERRED $(credential_helper_tools); do
    if resolved=$(env -i HOME="${HOME:-/}" PATH="$path" /bin/sh -c \
        "command -v -- '$tool' 2>/dev/null"); then
      case "$tool" in timeout|gtimeout) have_timeout=1 ;; esac
      say "  cron resolves $tool -> $resolved"
      continue
    fi
    # timeout and gtimeout are the same capability under two names, and the
    # sweep has its own bounded fallback besides, so only report the gap once
    # and only when neither is there.
    case "$tool" in
      gtimeout) continue ;;
      timeout)
        say "  NOTE the cron environment cannot resolve timeout; the sweep uses its built-in bound"
        continue ;;
    esac
    say "  NOTE the cron environment cannot resolve $tool"
    case "$tool" in
      tasks-axi) say "       Every sweep then records backlog_item=unknown instead of reading the item." ;;
      gh-axi) say "       Only matters for tooling the reconciliation itself runs, not for the sweep." ;;
      *) say "       A git credential helper: an HTTPS fetch may fail to authenticate from cron." ;;
    esac
  done
  [ "$have_timeout" -eq 1 ] || say "  (the built-in SIGTERM/SIGKILL fallback still bounds the fetch)"
}

# cron hands the command to /bin/sh but parses the line itself first, and a
# value it cannot represent becomes a broken job rather than an error. Refuse
# before writing one.
cron_safe_value() { # <name> <value>
  case "$2" in
    *[[:space:]]*) die "$1 for the cron line contains whitespace, which cron would split into separate arguments: $2" ;;
    *\'*) die "$1 for the cron line contains a single quote, which cron cannot carry: $2" ;;
    *%*) die "$1 for the cron line contains '%', which cron rewrites as a newline: $2" ;;
  esac
}

# Every selection this run made that the installed script cannot re-derive from
# its own location. cron gives a job almost no environment: a dropped FM_HOME
# would sweep one home's checkout while recording into another's records, and
# the log redirect would still point at the home that installed it, so the
# mismatch would be invisible.
#
# Sets CRON_ASSIGNMENTS, and must be called DIRECTLY rather than through a
# command substitution: its refusals are the whole point of the check, and a
# subshell would swallow every one of them and install the broken line anyway.
build_cron_assignments() { # <path>
  local derived_root name pair
  local -a pairs=()
  CRON_ASSIGNMENTS=""
  derived_root=$(cd "$SCRIPT_DIR/.." && pwd)
  pairs+=("PATH=$1")
  [ "$FM_ROOT" = "$derived_root" ] || pairs+=("FM_ROOT_OVERRIDE=$FM_ROOT")
  [ "$FM_HOME" = "$FM_ROOT" ] || pairs+=("FM_HOME=$FM_HOME")
  [ "$STATE" = "$FM_HOME/state" ] || pairs+=("FM_STATE_OVERRIDE=$STATE")
  [ "$DATA" = "$FM_HOME/data" ] || pairs+=("FM_DATA_OVERRIDE=$DATA")
  [ "$TASK_ID" = "$DEFAULT_TASK_ID" ] || pairs+=("FM_UPSTREAM_SYNC_TASK_ID=$TASK_ID")
  for name in FM_UPSTREAM_SYNC_FETCH_TIMEOUT FM_UPSTREAM_SYNC_FETCH_KILL_GRACE \
              FM_UPSTREAM_SYNC_STEP_TIMEOUT FM_UPSTREAM_SYNC_TOTAL_TIMEOUT \
              FM_UPSTREAM_SYNC_TIMEOUT_TOOL; do
    [ -n "${!name:-}" ] || continue
    pairs+=("$name=${!name}")
  done
  for pair in "${pairs[@]}"; do
    cron_safe_value "${pair%%=*}" "${pair#*=}"
    CRON_ASSIGNMENTS="$CRON_ASSIGNMENTS${pair%%=*}='${pair#*=}' "
  done
  cron_safe_value "the sweep script path" "$SELF_PATH"
  cron_safe_value "the cron log path" "$CRON_LOG"
}

cron_line() {
  printf '%s %s%s sweep >> %s 2>&1\n' \
    "$SCHEDULE" "$CRON_ASSIGNMENTS" "$SELF_PATH" "$CRON_LOG"
}

# --- crontab rewriting ------------------------------------------------------
#
# Ownership, not resemblance, decides what a rewrite may delete. A user crontab
# is shared by every scheduled job this user has, including a SECOND firstmate
# home's own sweep, so matching "a command whose basename is fm-upstream-sync.sh
# with the argument sweep" would delete a valid, unrelated schedule belonging to
# somebody else's installation.
#
# A line is this installation's own only when:
#   * it is a cron job at all: not blank, not a comment, not a NAME=value
#     crontab assignment, and it has the schedule fields to prove it. An echo, a
#     backup job, or an assignment that merely MENTIONS one of these filenames
#     is an unrelated entry and is preserved;
#   * its command is this very script (same path, or the same file), its first
#     argument is `sweep`, and the operational home it selects - an inline
#     FM_HOME=, else an inline FM_ROOT_OVERRIDE=, else the script's own checkout
#     - is the home this run is installing for;
#   * or it invokes a legacy fm-upstream-drift-check.sh whose own FM_ROOT is
#     this same checkout. A legacy job whose script cannot be read, or which
#     names a different checkout, is preserved and REPORTED rather than deleted,
#     because an unprovable match is not a match.
# Every dropped line is reported; every preserved-but-related line is reported
# separately, so nothing about the migration is silent in either direction.

JOB_CMD=""
JOB_ARG1=""
JOB_HOME=""

unquote() { # <word>
  local v=$1
  case "$v" in
    \'*\') v=${v#\'}; v=${v%\'} ;;
    \"*\") v=${v#\"}; v=${v%\"} ;;
  esac
  printf '%s\n' "$v"
}

# Sets JOB_CMD, JOB_ARG1 and JOB_HOME; returns 1 when the line is not a job.
parse_cron_job() { # <line>
  local line=$1 trimmed i start root=""
  local -a f=()
  JOB_CMD=""; JOB_ARG1=""; JOB_HOME=""
  trimmed=${line#"${line%%[![:space:]]*}"}
  [ -n "$trimmed" ] || return 1
  case "$trimmed" in '#'*) return 1 ;; esac
  [[ ! $trimmed =~ ^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*= ]] || return 1
  read -r -a f <<< "$trimmed"
  [ "${#f[@]}" -gt 0 ] || return 1
  case "${f[0]}" in
    @*) start=1 ;;
    *) [ "${#f[@]}" -ge 6 ] || return 1; start=5 ;;
  esac
  i=$start
  while [ "$i" -lt "${#f[@]}" ] && [[ ${f[$i]} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    case "${f[$i]}" in
      FM_HOME=*) JOB_HOME=$(unquote "${f[$i]#FM_HOME=}") ;;
      FM_ROOT_OVERRIDE=*) root=$(unquote "${f[$i]#FM_ROOT_OVERRIDE=}") ;;
    esac
    i=$((i + 1))
  done
  [ "$i" -lt "${#f[@]}" ] || return 1
  JOB_CMD=$(unquote "${f[$i]}")
  [ $((i + 1)) -ge "${#f[@]}" ] || JOB_ARG1=$(unquote "${f[$((i + 1))]}")
  # An inline FM_HOME wins; otherwise the script's own default is FM_ROOT, which
  # is the inline override when there is one and the checkout above bin/ if not.
  if [ -z "$JOB_HOME" ]; then
    if [ -n "$root" ]; then
      JOB_HOME=$root
    else
      JOB_HOME=$(dirname "$(dirname "$JOB_CMD")")
    fi
  fi
  return 0
}

same_path() { # <a> <b>
  [ "$1" = "$2" ] && return 0
  [ -e "$1" ] && [ -e "$2" ] && [ "$1" -ef "$2" ]
}

job_is_this_installation() {
  same_path "$JOB_CMD" "$SELF_PATH" || return 1
  [ "$JOB_ARG1" = sweep ] || return 1
  same_path "$JOB_HOME" "$FM_HOME"
}

# 0 this home's legacy job, 1 not a legacy job at all, 2 unprovable, 3 another
# checkout's legacy job.
legacy_job_bearing() {
  local declared
  [ "$(basename "$JOB_CMD")" = "$LEGACY_SCRIPT_NAME" ] || return 1
  [ -r "$JOB_CMD" ] || return 2
  declared=$(sed -n 's/^[[:space:]]*FM_ROOT=//p' "$JOB_CMD" | head -1 | tr -d "\"'")
  [ -n "$declared" ] || return 2
  same_path "$declared" "$FM_ROOT" || return 3
  return 0
}

FILTER_PENDING=()

filter_flush() { # <outfile>
  local l
  for l in ${FILTER_PENDING+"${FILTER_PENDING[@]}"}; do printf '%s\n' "$l" >> "$1"; done
  FILTER_PENDING=()
}

filter_crontab() { # <infile> <outfile> <dropfile> <foreignfile>
  local in=$1 out=$2 dropfile=$3 foreign=$4 line l rc
  FILTER_PENDING=()
  : > "$out"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$CRON_MARKER" ]; then
      printf '%s\n' "$line" >> "$dropfile"
      continue
    fi
    case "${line#"${line%%[![:space:]]*}"}" in
      '#'*)
        # Another installation's marker is never buffered as this one's comment.
        case "$line" in
          *'# fm-upstream-sync '*) filter_flush "$out"; printf '%s\n' "$line" >> "$out"; continue ;;
        esac
        case "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')" in
          *upstream*) FILTER_PENDING+=("$line"); continue ;;
        esac
        filter_flush "$out"
        printf '%s\n' "$line" >> "$out"
        continue ;;
    esac
    if parse_cron_job "$line"; then
      rc=0
      legacy_job_bearing || rc=$?
      if job_is_this_installation || [ "$rc" -eq 0 ]; then
        for l in ${FILTER_PENDING+"${FILTER_PENDING[@]}"}; do printf '%s\n' "$l" >> "$dropfile"; done
        FILTER_PENDING=()
        printf '%s\n' "$line" >> "$dropfile"
        continue
      fi
      case "$rc" in
        2) printf 'legacy job this install could not bind to a checkout: %s\n' "$line" >> "$foreign" ;;
        3) printf "legacy job belonging to another checkout: %s\n" "$line" >> "$foreign" ;;
      esac
      if same_path "$JOB_CMD" "$SELF_PATH" && [ "$JOB_ARG1" = sweep ]; then
        printf 'scheduled sweep for another home (%s): %s\n' "$JOB_HOME" "$line" >> "$foreign"
      fi
    fi
    filter_flush "$out"
    printf '%s\n' "$line" >> "$out"
  done < "$in"
  filter_flush "$out"
}

# `crontab -l` exits non-zero for BOTH "this user has no crontab" and a genuine
# spool read failure, and only the message separates them (verified on this
# host: Debian cron 3.0pl1 prints "no crontab for <user>"). Treating every
# failure as an empty crontab would let one unreadable read silently delete
# every entry the user has, so anything but the known no-crontab wording fails
# closed.
read_crontab() { # <outfile> -> 0 readable (possibly empty), 1 unreadable
  local out=$1 err rc=0
  err=$(mktemp_here) || return 1
  crontab -l >"$out" 2>"$err" || rc=$?
  if [ "$rc" -eq 0 ]; then rm -f "$err"; return 0; fi
  if grep -qi 'no crontab for' "$err"; then
    : > "$out"
    rm -f "$err"
    return 0
  fi
  CRONTAB_READ_ERROR="exit $rc: $(tr '\n' ' ' < "$err" | sed 's/[[:space:]]*$//')"
  rm -f "$err"
  return 1
}

cmd_install_cron() {
  local dry_run=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      *) die "unknown install-cron option: $1" ;;
    esac
  done
  validate_config
  command -v crontab >/dev/null 2>&1 || die "crontab not found on PATH"

  local path line
  path=$(cron_path)
  # Refuse anything cron cannot represent BEFORE the crontab is read or
  # replaced, and in this shell, where a refusal actually stops the install.
  build_cron_assignments "$path"
  line=$(cron_line)

  local current dropped foreign proposed had_legacy=0
  current=$(mktemp_here)
  dropped=$(mktemp_here)
  foreign=$(mktemp_here)
  proposed=$(mktemp_here)
  # shellcheck disable=SC2064
  trap "rm -f '$current' '$dropped' '$foreign' '$proposed'" EXIT

  read_crontab "$current" \
    || die "could not read the current crontab ($CRONTAB_READ_ERROR); refusing to install over a crontab this run cannot see"

  : > "$dropped"
  : > "$foreign"
  # Byte-for-byte: every surviving line, including blank lines and trailing
  # blank lines, is copied through unchanged and in order. The only difference
  # from the bytes read is that the file always ends in a newline, which cron
  # requires anyway. Nothing else is trimmed or normalized.
  filter_crontab "$current" "$proposed" "$dropped" "$foreign"
  printf '%s\n%s\n' "$CRON_MARKER" "$line" >> "$proposed"

  # Only lines the structural filter actually dropped land in $dropped, so a
  # plain name match here reports a real legacy job rather than a mention.
  if grep -qF "$LEGACY_SCRIPT_NAME" "$dropped"; then had_legacy=1; fi

  verify_cron_path "$path"

  if [ "$dry_run" -eq 1 ]; then
    say "--- proposed crontab ---"
    cat "$proposed"
  else
    # Only a real install creates the record directory the cron line appends to.
    # A dry run inspects and prints; it leaves no trace.
    mkdir -p "$SYNC_DIR"
    crontab - < "$proposed" || die "crontab install failed"
    say "installed: $CRON_MARKER"
    say "  $line"
  fi
  say ""
  say "--- the cron environment this line runs under ---"
  report_cron_environment "$path"

  if [ -s "$dropped" ]; then
    say ""
    say "replaced these lines (nothing else in the crontab was touched):"
    sed 's/^/  - /' "$dropped"
  fi
  [ "$had_legacy" -eq 0 ] || say "migrated off the legacy $LEGACY_SCRIPT_NAME job; its script file is left on disk untouched"

  if [ -s "$foreign" ]; then
    say ""
    say "LEFT IN PLACE - related entries this install does not own:"
    sed 's/^/  - /' "$foreign"
    say "  An entry is replaced only when it provably belongs to this home ($FM_HOME)."
    say "  Retire or rebind these by hand if they are in fact stale."
  fi

  # A crontab that still names the legacy script somewhere this filter did not
  # drop (a wrapper, a redirect, a second job) would leave two schedules
  # running. Say so rather than reporting a clean migration.
  if grep -qF "$LEGACY_SCRIPT_NAME" "$proposed"; then
    say ""
    say "WARNING the crontab still mentions $LEGACY_SCRIPT_NAME outside a plain scheduled call:"
    grep -nF "$LEGACY_SCRIPT_NAME" "$proposed" | sed 's/^/  /'
    say "  Check it by hand; this install only replaces a direct invocation of that script."
  fi

  report_reconciliation_item
}

# The legacy job filed its request as backlog item $TASK_ID. Name whatever is
# there out loud at migration time and say exactly what the sweep will do with
# it, because an item left unmentioned is the one way this hand-off loses work.
report_reconciliation_item() {
  local recon_raw recon
  recon_raw=$(reconciliation_state)
  recon=$(recon_bearing "$recon_raw")
  case "$recon" in
    open)
      say ""
      say "MIGRATION: backlog item $TASK_ID is filed and not held; it carries the current reconciliation request."
      say "  The sweep treats it as the open request and queues no duplicate intake while it stands."
      ;;
    held)
      say ""
      say "MIGRATION: backlog item $TASK_ID exists and is HELD ($(recon_detail "$recon_raw"))."
      say "  The first sweep that sees new upstream commits will queue one intake note naming it, because"
      say "  suppressing on a held item would leave this routine inert for as long as the hold stands."
      say "  That is reporting only. This routine cannot release a hold and does not ask for one to be lifted:"
      say "  the hold may be the legacy drift reminder, or a landing or decision gate on work already under review."
      say "  Firstmate owns that item: reconcile the hold against the captain's recorded instructions with the"
      say "  captain-hold-lifecycle skill. Do not leave it held and unmentioned."
      ;;
    unknown)
      say ""
      say "MIGRATION: backlog item $TASK_ID could not be read from here ($(recon_detail "$recon_raw"))."
      say "  Check it by hand before the first sweep; an unreadable backlog does not suppress intake, so the"
      say "  sweep will queue a note that says it could not check rather than assuming nothing is filed."
      ;;
  esac
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  sweep)        shift; cmd_sweep "$@" ;;
  status)       shift; cmd_status ;;
  install-cron) shift; cmd_install_cron "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac
