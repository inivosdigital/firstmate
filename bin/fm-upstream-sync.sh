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
#   status        Print the last success, the last failure, and the last
#                 published intake from durable records. No network, no wake.
#   install-cron  Idempotently install the sweep in the user crontab, migrating
#                 off the legacy ~/.local/bin/fm-upstream-drift-check.sh job.
#                 Every unrelated crontab entry is preserved byte-for-byte.
#
# De-duplication reads the EXISTING owners rather than keeping a second task
# state of its own, in this order:
#   1. this routine already published intake for this exact upstream head, so an
#      unreconciled fork is not re-reported every day (last-intake below);
#   2. an intake note from this routine is still unacknowledged in the inbox, so
#      firstmate has not even read the previous request (bin/fm-inbox.sh owns
#      that record and its acknowledgement);
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
# Exit codes:
#   0  success (including result=no-change)
#   1  usage error or a refusal
#   2  the fetch failed or timed out (offline; NOT "no changes"), or intake
#      could not be queued
#   3  another sweep holds the lock
#
# Durable records under <state>/upstream-sync/:
#   last-success    the last sweep that completed, with its result
#   last-failure    the last sweep that failed, with its distinct reason
#   last-intake     the upstream head this routine last published intake for
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
#   FM_UPSTREAM_SYNC_FETCH_KILL_GRACE seconds between the fetch's SIGTERM and
#                                     its SIGKILL (default 10)
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
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SYNC_DIR="$STATE/upstream-sync"

LAST_SUCCESS="$SYNC_DIR/last-success"
LAST_FAILURE="$SYNC_DIR/last-failure"
FAILURE_EPISODE="$SYNC_DIR/failure-episode"
LAST_INTAKE="$SYNC_DIR/last-intake"
CRON_LOG="$SYNC_DIR/cron.log"
SWEEP_LOCK="$SYNC_DIR/.sweep.lock"

CRON_LOG_MAX_LINES=2000
FETCH_TIMEOUT="${FM_UPSTREAM_SYNC_FETCH_TIMEOUT:-60}"
FETCH_KILL_GRACE="${FM_UPSTREAM_SYNC_FETCH_KILL_GRACE:-10}"
SCHEDULE="${FM_UPSTREAM_SYNC_SCHEDULE:-35 4 * * *}"
TASK_ID="${FM_UPSTREAM_SYNC_TASK_ID:-upstream-drift-alert}"
SELF_SCRIPT_NAME=fm-upstream-sync.sh
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
CRON_MARKER='# fm-upstream-sync (managed by bin/fm-upstream-sync.sh install-cron)'

CRONTAB_READ_ERROR=""

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
  # Mark the episode announced only AFTER the note is durable. Writing the
  # marker first would let one failed publication silence this reason forever,
  # which is the same silent failure in a new place.
  if publish_note "$FAILURE_MARKER upstream sync sweep failed ($reason): $detail. Upstream was not reached, so the last recorded drift is stale rather than clean. Evidence: $LAST_FAILURE" >/dev/null; then
    printf '%s\n' "$reason" > "$FAILURE_EPISODE"
  else
    say "WARNING could not queue the failure note; it stays unannounced and the next sweep retries"
  fi
}

# --- durable intake ---------------------------------------------------------

# One durable, separately acknowledged record plus one wake, through the inbox
# that already owns both.
publish_note() { # <body>  -> prints the note id
  local out id
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-inbox.sh" note - <<< "$1") || return 1
  id=$(printf '%s\n' "$out" | sed -n 's/^queued //p' | head -1)
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

# True when an INTAKE note from this routine is still waiting for firstmate.
# fm-inbox.sh owns the record: a handled note moves out of this directory. A
# pending FAILURE note is deliberately not counted here, so a stuck error report
# cannot suppress the reconciliation request it has nothing to do with.
intake_pending() {
  local f
  for f in "$STATE"/inbox/*.note; do
    [ -e "$f" ] || return 1
    grep -qF "$INTAKE_MARKER" "$f" && return 0
  done
  return 1
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
  command -v tasks-axi >/dev/null 2>&1 || { printf 'unknown|\n'; return 0; }
  [ -f "$DATA/backlog.md" ] || { printf 'absent|\n'; return 0; }
  out=$(tasks-axi show "$TASK_ID" --file "$DATA/backlog.md" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *NOT_FOUND*) printf 'absent|\n' ;;
      *) printf 'unknown|\n' ;;
    esac
    return 0
  fi
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
      tail=("The backlog backend could not be read from this run, so an already-filed request could not be checked for; confirm $TASK_ID before filing a second one.") ;;
    *)
      tail=("File or refresh backlog item $TASK_ID, then run the reconciliation with the upstream-reconciliation skill.") ;;
  esac
  printf '%s\n' \
    "$INTAKE_MARKER upstream template has $4 new commit$plural to reconcile into local main." \
    "upstream=${1:0:12} local=${2:0:12} merge_base=${3:0:12} behind=$4 ahead=$5" \
    "${tail[@]}" \
    "The merge is never automated and landing is still the captain's call."
}

# --- bounded fetch ----------------------------------------------------------

# Which external timeout tool to use, if any. `none` selects the built-in
# fallback, which is otherwise unreachable on a host that has timeout(1).
timeout_tool() {
  case "${FM_UPSTREAM_SYNC_TIMEOUT_TOOL:-auto}" in
    none) : ;;
    timeout|gtimeout) printf '%s\n' "$FM_UPSTREAM_SYNC_TIMEOUT_TOOL" ;;
    auto)
      if command -v timeout >/dev/null 2>&1; then printf 'timeout\n'
      elif command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout\n'
      fi ;;
    *) die "FM_UPSTREAM_SYNC_TIMEOUT_TOOL must be auto, timeout, gtimeout or none" ;;
  esac
}

# No usable timeout(1). Run the fetch in its own process group and escalate
# SIGTERM -> SIGKILL, because a `kill -TERM` followed by a bare `wait` is not a
# bound at all: a child that ignores TERM leaves the scheduled run hanging
# forever, which is exactly what the deadline exists to prevent.
fetch_upstream_fallback() {
  local pid start monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  git -C "$FM_ROOT" fetch --quiet upstream 2>/dev/null &
  pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    [ "$(( $(date +%s) - start ))" -lt "$FETCH_TIMEOUT" ] || break
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

# Prints the failure reason on stdout and returns 1; returns 0 on a real fetch.
fetch_upstream() {
  local rc=0 tool
  tool=$(timeout_tool)
  if [ -n "$tool" ]; then
    # -k escalates to SIGKILL when the fetch ignores SIGTERM. Probe support once
    # instead of assuming it, so a timeout(1) without -k degrades to the plain
    # form rather than dying on a usage error and reporting a fetch failure.
    if "$tool" -k 1 1 true >/dev/null 2>&1; then
      "$tool" -k "$FETCH_KILL_GRACE" "$FETCH_TIMEOUT" \
        git -C "$FM_ROOT" fetch --quiet upstream 2>/dev/null || rc=$?
    else
      "$tool" "$FETCH_TIMEOUT" \
        git -C "$FM_ROOT" fetch --quiet upstream 2>/dev/null || rc=$?
    fi
  else
    fetch_upstream_fallback || rc=$?
  fi
  case "$rc" in
    0) return 0 ;;
    124|137) printf 'fetch-timeout\n'; return 1 ;;
    *) printf 'fetch-failed\n'; return 1 ;;
  esac
}

# --- measurement ------------------------------------------------------------

# Sets UPSTREAM_SHA, LOCAL_SHA, MERGE_BASE, BEHIND, AHEAD from local refs only.
measure() {
  git_repo remote get-url upstream >/dev/null 2>&1 \
    || die "no 'upstream' remote in $FM_ROOT"
  UPSTREAM_SHA=$(git_repo rev-parse --verify --quiet refs/remotes/upstream/main) \
    || die "no refs/remotes/upstream/main in $FM_ROOT"
  LOCAL_SHA=$(git_repo rev-parse --verify --quiet refs/heads/main) \
    || die "no local main branch in $FM_ROOT"
  MERGE_BASE=$(git_repo merge-base "$LOCAL_SHA" "$UPSTREAM_SHA") \
    || die "local main and upstream/main share no history"
  BEHIND=$(git_repo rev-list --count "$LOCAL_SHA..$UPSTREAM_SHA")
  AHEAD=$(git_repo rev-list --count "$UPSTREAM_SHA..$LOCAL_SHA")
}

# --- sweep ------------------------------------------------------------------

cmd_sweep() {
  mkdir -p "$SYNC_DIR"
  trim_log "$CRON_LOG" "$CRON_LOG_MAX_LINES"

  # STATE and FM_HOME are already set above and the library defers to them.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if ! fm_lock_try_acquire "$SWEEP_LOCK"; then
    say "sweep already running (lock held); this run did nothing"
    exit 3
  fi
  # shellcheck disable=SC2064
  trap "fm_lock_release '$SWEEP_LOCK'" EXIT

  local reason
  if ! reason=$(fetch_upstream); then
    record_failure "$reason" "git fetch upstream in $FM_ROOT (bound ${FETCH_TIMEOUT}s)"
    say "FAILED $reason - upstream was not reached; the recorded drift is stale, not clean"
    exit 2
  fi

  measure

  local recon_raw recon recon_detail
  recon_raw=$(reconciliation_state)
  recon=$(recon_bearing "$recon_raw")
  recon_detail=$(recon_detail "$recon_raw")

  if [ "$BEHIND" -eq 0 ]; then
    record_success no-change "$UPSTREAM_SHA" "$LOCAL_SHA" "$BEHIND" "$AHEAD" "$recon"
    say "no-change - no new upstream commits (local main is $AHEAD ahead)"
    return 0
  fi

  local suppressed=""
  if [ "$UPSTREAM_SHA" = "$(record_get "$LAST_INTAKE" upstream_sha)" ]; then
    suppressed="intake for this upstream head was already published"
  elif intake_pending; then
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
  if note=$(publish_note "$(intake_body "$UPSTREAM_SHA" "$LOCAL_SHA" "$MERGE_BASE" "$BEHIND" "$AHEAD" "$recon" "$recon_detail")"); then
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
  say "records    $SYNC_DIR"
  say ""
  show_record "last successful sweep" "$LAST_SUCCESS" "no successful sweep recorded"
  show_record "last failed sweep" "$LAST_FAILURE" "no failed sweep recorded"
  show_record "last published intake" "$LAST_INTAKE" "no intake published yet"
  local recon_raw
  recon_raw=$(reconciliation_state)
  case "$(recon_bearing "$recon_raw")" in
    open) say "backlog item $TASK_ID is filed and not held; new intake stays suppressed until it is done" ;;
    held) say "backlog item $TASK_ID is HELD ($(recon_detail "$recon_raw")); a hold does not suppress intake, and this routine cannot release it" ;;
    unknown) say "backlog item $TASK_ID could not be read from here (backend unavailable); intake is not suppressed by it" ;;
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

cron_line() {
  printf "%s PATH='%s' %s/bin/%s sweep >> %s 2>&1\n" \
    "$SCHEDULE" "$(cron_path)" "$FM_ROOT" "$SELF_SCRIPT_NAME" "$CRON_LOG"
}

# Rewrite a crontab, dropping ONLY this routine's own managed lines and the
# legacy drift-check job. A job is identified by its COMMAND STRUCTURE, not by
# mentioning a filename: the schedule fields are skipped, any inline VAR=value
# prefix is skipped, and the remaining command word's basename must be exactly
# the managed or legacy script. An `echo`, a backup job, or an environment
# assignment that merely names one of those scripts is an unrelated entry and is
# preserved. Comment lines are never treated as jobs; a contiguous comment block
# directly above a dropped job is dropped with it only when it mentions
# "upstream", which is the legacy job's own descriptive comment, and every
# dropped line is reported rather than removed silently.
filter_crontab() { # <dropfile>; reads stdin, writes stdout
  awk -v marker="$CRON_MARKER" -v legacy="$LEGACY_SCRIPT_NAME" \
      -v self="$SELF_SCRIPT_NAME" -v dropfile="$1" '
    function basename(p,   n, a) { n = split(p, a, "/"); return a[n] }
    # Index of the first command field, or 0 when this line is not a cron job.
    function cmd_start() {
      if ($0 ~ /^[[:space:]]*$/) return 0
      if ($0 ~ /^[[:space:]]*#/) return 0
      # NAME=value environment assignment, not a job
      if ($0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) return 0
      if ($1 ~ /^@/) return 2
      if (NF < 6) return 0
      return 6
    }
    function managed(   i, b) {
      i = cmd_start()
      if (i == 0 || i > NF) return 0
      while (i <= NF && $i ~ /^[A-Za-z_][A-Za-z0-9_]*=/) i++
      if (i > NF) return 0
      b = basename($i)
      if (b == legacy) return 1
      if (b == self && (i + 1) <= NF && $(i + 1) == "sweep") return 1
      return 0
    }
    function drop(l) { if (dropfile != "") print l >> dropfile }
    function flush_pending(   i) {
      for (i = 1; i <= pending_n; i++) print pending[i]
      pending_n = 0
    }
    {
      line = $0
      if (line == marker) { drop(line); next }
      if (line ~ /^[[:space:]]*#/) {
        if (tolower(line) ~ /upstream/) { pending[++pending_n] = line; next }
        flush_pending(); print line; next
      }
      if (managed()) {
        for (i = 1; i <= pending_n; i++) drop(pending[i])
        pending_n = 0
        drop(line)
        next
      }
      flush_pending()
      print line
    }
    END { flush_pending() }
  '
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
  command -v crontab >/dev/null 2>&1 || die "crontab not found on PATH"

  local path
  path=$(cron_path)
  case "$path" in
    *[[:space:]]*) die "PATH for the cron line contains whitespace, which cron would split into separate arguments: set FM_UPSTREAM_SYNC_CRON_PATH to a value without spaces" ;;
    *\'*) die "PATH for the cron line contains a single quote: set FM_UPSTREAM_SYNC_CRON_PATH" ;;
    *%*) die "PATH for the cron line contains '%', which cron rewrites as a newline: set FM_UPSTREAM_SYNC_CRON_PATH" ;;
  esac

  local current dropped proposed had_legacy=0
  current=$(mktemp_here)
  dropped=$(mktemp_here)
  proposed=$(mktemp_here)
  # shellcheck disable=SC2064
  trap "rm -f '$current' '$dropped' '$proposed'" EXIT

  read_crontab "$current" \
    || die "could not read the current crontab ($CRONTAB_READ_ERROR); refusing to install over a crontab this run cannot see"

  : > "$dropped"
  # Byte-for-byte: every surviving line, including blank lines and trailing
  # blank lines, is copied through unchanged and in order. The only difference
  # from the bytes read is that the file always ends in a newline, which cron
  # requires anyway. Nothing else is trimmed or normalized.
  filter_crontab "$dropped" < "$current" > "$proposed"
  printf '%s\n%s\n' "$CRON_MARKER" "$(cron_line)" >> "$proposed"

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
    say "  $(cron_line)"
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
      say "MIGRATION: backlog item $TASK_ID could not be read from here (tasks-axi missing, or the backlog unreadable)."
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
