#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reads the authoritative source (a
# no-mistakes run-step attributed to this crew's branch and current code
# identity, else the pane busy-signature) and reconciles the possibly-stale log
# against it.
#
# The determinism lives entirely here - only run-step / pane / log reads plus
# fixed mapping logic, no heuristics and no LLM. Output is one stable, parseable,
# token-tight line firstmate can read every heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta.
#   2. Matching no-mistakes run for this crew's branch AND current code identity,
#      active or terminal (from `axi status`, or the coarse `no-mistakes runs`
#      fallback)? Branch name alone is not enough: a historical run on a reused
#      branch whose head was rewritten or diverged must not be attributed.
#      A run matches when its head equals the worktree HEAD, or the worktree HEAD
#      is an ancestor of the run head (pipeline fix commits advanced the run on
#      the same line of history). An actively-executing run (running/fixing/ci,
#      no outcome yet, not parked at a gate) also matches when its head is not
#      an object in this repo at all: no-mistakes executes runs in its own
#      private worktree, so a rebased or fix-advanced head reaches this repo
#      only at push - but ONLY when the runs list corroborates it as the single
#      live run for this branch (see nm_run_attributes_here for the full
#      fail-closed conditions). Local work that advanced past a resolvable run
#      head, or diverged from it, invalidates attribution, and a terminal or
#      gate-parked run with a locally-absent head stays unattributed.
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. EXCEPT: while
#      the active step is ci, `axi status` alone cannot tell "still waiting on
#      checks" from "checks green, waiting on merge" (see nm_ci_checks_state) -
#      a ci-step log-tail check overrides working -> done once checks read
#      green, so a green PR is never silently read as still-validating.
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. No run for this crew (pre-validation, or kind=scout): fall back to the
#      recorded backend's pane busy state, then the status log's last line only
#      when its verb maps to a recognized run-state. Decision-only events such as
#      `resolved` never become current state or detail.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log.
#
# `--run-progress <id>` swaps the output for the run's PHASE and PROGRESS TOKEN:
#
#   progress: <phase>/<run-id>/<run-head>/<step:status,...>   an attributed run
#   progress: <phase>/coarse/<status>/<worktree-head>         coarse runs-list fallback
#   progress: none                                            no run attributed to this crew
#
# <phase> is the same reconciled state this script would report normally
# (working, done, parked, failed), so a caller can tell an advancing run from a
# finished one awaiting merge from one stopped at a gate, without a second read.
# The token after it is meaningful only by EQUALITY across two reads: unchanged
# means the run has not structurally moved. See the token builder below for
# exactly which fields it carries and why duration_ms is deliberately excluded.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

# --run-progress switches the output to the run PROGRESS TOKEN instead of the
# current-state line: one opaque-but-stable string that changes if and only if
# this crew's attributed run made STRUCTURAL progress. It exists because pane
# idleness cannot distinguish a validating crew that is advancing from one whose
# pipeline has frozen - both render an idle pane for many minutes - so the shared
# wedge policy (crew_run_progress_defers_wedge, bin/fm-classify-lib.sh) needs a
# progress signal, and run attribution/parsing lives here rather than being
# duplicated into the classifier.
PROGRESS_MODE=0
if [ "${1:-}" = --run-progress ]; then
  PROGRESS_MODE=1
  shift
fi
ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh [--run-progress] <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=$(fm_sanitize_timeout_bound "${FM_CREW_STATE_NM_TIMEOUT:-10}" 10)
NM_KILL_AFTER=$(fm_sanitize_timeout_bound "${FM_CREW_STATE_NM_KILL_AFTER:-2}" 2)
# How many of the most recent `no-mistakes runs` rows the cross-branch fallback
# (nm_runs_status_for_branch, below) scans. Generous enough to still find a
# branch's own run on a busy multi-crew fleet without listing the entire
# history every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
#
# Under --run-progress this emits `<phase>/<token>` instead, where <phase> is
# this same reconciled state ($1) and <token> is the run progress token built
# below. Routing progress through the ONE emit point means the phase is always
# fm-crew-state's own verdict for that read - working, done, parked, failed -
# rather than a second interpretation of the run that could disagree with it.
# Any emit reached with no token means there is no attributed run to measure
# progress against (a missing meta, a torn-down worktree, the pane/log fallback),
# which reports `none` and lets the caller escalate on its own terms.
PROGRESS_TOKEN=""
emit() {  # <state> <source> [detail]
  if [ "$PROGRESS_MODE" = 1 ]; then
    if [ -n "$PROGRESS_TOKEN" ]; then
      printf 'progress: %s/%s\n' "$1" "$PROGRESS_TOKEN"
    else
      printf 'progress: none\n'
    fi
    exit 0
  fi
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
HARNESS=$(meta_value harness)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line, and its leading verb (the word before the colon).
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
# Map a status-log verb onto a canonical state for the fallback path. `paused` is
# the deliberate-external-wait verb (fm-classify-lib.sh's FM_CLASSIFY_PAUSED_VERB):
# a crew with no active run and an idle pane that declared a known external wait
# reports `paused` distinctly, so a supervisor reading this sees a declared pause
# and its reason rather than a wedge-suspect idle.
map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  case "$(status_line_verb "$1")" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(status_line_verb "$LOG_LINE")

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished crew whose endpoint has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown. Backend-aware
# (fm_backend_of_meta defaults absent backend= to tmux, the P1 contract): a
# herdr task is read through fm_backend_capture instead of a bare tmux probe.
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
pane_readable() {  # <target>
  case "$TASK_BACKEND" in
    tmux) tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1 ;;
    *) fm_backend_capture "$TASK_BACKEND" "$1" 1 "$EXPECTED_LABEL" >/dev/null 2>&1 ;;
  esac
}
# crew_busy_verdict: the crew's semantic busy state from the one contract
# owner (bin/fm-busy-lib.sh), as "<busy|idle|unknown> <source>". A converted
# adapter answers from its own lifecycle record; Grok answers from its
# isolated rendered-tail fallback; a herdr crew's native `busy` is accepted
# when no record exists, but its native `idle` is NOT, because agent.get
# reports generation state (idle while a crew blocks on its own long-running
# foreground tool call) rather than turn state.
crew_busy_verdict() {  # <target>
  local tail40=''
  case "$HARNESS" in
    grok*) tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || tail40='' ;;
  esac
  fm_busy_classify "$TASK_BACKEND" "$1" "$HARNESS" "$ID" "$STATE" "$tail40"
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --
# trim, strip_quotes, the bounded nm_run call, nm_field's TOON parse, and the
# branch+head attribution rule below are thin wrappers over the ONE owner in
# bin/fm-nm-run-lib.sh, shared with fm-teardown.sh's pre-teardown run abort.
# nm_run keeps fm_nm_run's fail-open contract (best-effort text, exit status
# discarded) for the axi status/logs reads; the runs-list scan below is the
# one deliberate exception and calls the status-preserving form itself.

trim() { fm_nm_trim "$@"; }
strip_quotes() { fm_nm_strip_quotes "$@"; }
nm_run() {  # <args...>
  fm_nm_run "$WT" "$NM_TIMEOUT" "$NM_KILL_AFTER" "$@"
}

# Scalar value of a TOON key in the captured run output ($RUN_OUT).
RUN_OUT=""
nm_field() {  # <key>
  fm_nm_field "$RUN_OUT" "$1"
}
# Finding count from a findings[N]{...} table header; empty when none.
nm_findings_count() {
  printf '%s\n' "$RUN_OUT" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
nm_gate_step_row() {
  local row step rest status findings
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  step=$(trim "${row%%,*}")
  rest=${row#*,}
  status=$(strip_quotes "$(trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}
nm_gate_status() {
  local s row
  s=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(strip_quotes "$(trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(nm_gate_step_row)
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}
nm_has_gate() {
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}
nm_gate_line_name() {
  local gate step
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(printf '%s\n' "$RUN_OUT" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}
nm_gate_name() {
  local gate row
  gate=$(nm_gate_line_name)
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}
nm_gate_findings_count() {
  local f row rest
  f=$(nm_findings_count)
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}
# 0 when the captured axi-status run ($RUN_OUT) is parked at a gate, in ANY of
# the representations no-mistakes uses: a top-level awaiting_approval or
# fix_review status, an awaiting_agent line, a scalar `gate:` or a `gate:`
# block, or a gate step row. The ONE owner of that disjunction, shared by the
# run-step interpreter and the unresolvable-head attribution guard below - a
# real scalar or block gate carries top-level `status: running`, so a guard
# reading only the top-level status does not see it (independent-review
# finding on the 2026-08-10 fix).
nm_run_is_gated() {
  case "$(strip_quotes "$(nm_field status)")" in
    awaiting_approval|fix_review) return 0 ;;
  esac
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*awaiting_agent:' && return 0
  [ -n "$(nm_gate_status)" ] && return 0
  nm_has_gate
}
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(status_line_note "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

nm_ci_step_status() {
  local row rest
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  rest=${row#*,}
  strip_quotes "$(trim "${rest%%,*}")"
}

nm_effective_ci_step_status() {
  local step_status
  if [ "${RUN_STATUS:-}" = fixing ]; then
    printf 'fixing'
    return 0
  fi
  step_status=$(nm_ci_step_status)
  if [ -n "$step_status" ]; then
    printf '%s' "$step_status"
    return 0
  fi
  if [ "${RUN_STATUS:-}" = ci ]; then
    printf 'running'
  fi
}

# Root cause of the PR #252 incident (2026-07): for a repo where merge is left
# to the captain, no-mistakes' ci step (and therefore top-level status/outcome)
# stays "running" for the ENTIRE CI-monitor phase, including long after GitHub
# reports every check green - it only reaches outcome=passed once the PR is
# actually merged (or failed/cancelled if closed). `axi status`'s steps[] table
# never distinguishes "still waiting on checks" from "checks green, waiting on
# merge": both read as plain `ci,running,...`. The only place that transition is
# recorded is the ci step's own log text, e.g. "all CI checks passed - still
# monitoring until merged or closed" or "no CI checks reported - still
# monitoring until merged or closed" (verified against 360+ real run logs under
# ~/.no-mistakes/logs/*/ci.log on the installed v1.32.2 binary, including the
# actual PR #252 run). Reads the ci step's log tail via `axi logs` and scans it
# for the MOST RECENT recognized marker (the log is append-only/chronological,
# so the last match is current): green with nothing red after it means CI is
# green right now, still only waiting on merge/close.
nm_ci_checks_state() {
  local run_id log_tail marker
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}
# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# reports the active-or-most-recent run for the CURRENT branch when one
# exists, else falls back to some other branch's run purely as informational
# display (verified empirically: querying a worktree with its own active run
# reliably returns that run, even under concurrent load from several other
# validating crews on the same underlying repo). A crew whose branch genuinely
# has no run yet therefore sees another branch's answer here.
#
# This fallback used to shell out to `no-mistakes axi` (bare, no subcommand)
# expecting a `runs[N]{id,branch,status,...}:` TOON table and re-query the
# matched id via `axi status --run <id>`. Verified against the real installed
# CLI (v1.32.2): the `axi` surface exposes only abort/logs/respond/run/status -
# there is no runs-listing subcommand under `axi` at all, so that table never
# appears and the lookup was silently dead code; whenever the bare `axi
# status` answer was not this crew's own branch, attribution always failed and
# the caller fell straight through to the pane/log fallback below. (The
# PRIMARY cause of the 2026-07 herdr false-surface incidents turned out to be
# a separate bug in bin/fm-watch.sh's stale_is_terminal precedence - see that
# file's history - but this cross-branch path was independently confirmed
# dead code and is worth having actually work.)
#
# The real run-listing command is the top-level `no-mistakes runs` (verified:
# `no-mistakes --help` lists it separately from `axi`). It is plain, human-
# oriented text - no run id, no JSON/TOON, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]" separated by runs of
# spaces (verified: no quoting, so splitting on the first two whitespace runs
# is exact).
#
# One scan serves two consumers that need different slices of the same view,
# via globals: the coarse status fallback below, and the uniqueness proof the
# unresolvable-head dispensation requires (nm_run_attributes_here). After a
# call:
#   NM_RUNS_MATCH_STATUS  newest same-branch row whose short-sha strictly
#                         matches this worktree's code identity ('' if none)
#   NM_RUNS_LIVE_N        count of same-branch rows still `running`, whatever
#                         their head relation
#   NM_RUNS_LIVE_SHA      the LAST-counted running row's short-sha; meaningful
#                         only when NM_RUNS_LIVE_N is exactly 1
#   NM_RUNS_ROWS_TAINTED  1 when the query exited nonzero (timed out or
#                         failed): a killed byte stream can cut a line
#                         mid-token, so nothing row-derived is trustworthy
#                         and the partial output is DISCARDED UNPARSED
#   NM_RUNS_INCOMPLETE    1 when the view cannot be proven complete: the rows
#                         are tainted (above), or the returned row count
#                         filled the requested limit and more rows could sit
#                         beyond the slice
# An empty/unavailable list leaves the first three at their empty defaults,
# which every consumer reads as "cannot bind".
# THE DISTINCTION THE TWO FLAGS CARRY - the line that kept being got wrong
# across three review rounds, so it is stated once, here, explicitly:
#   - a NONZERO EXIT poisons the ROWS themselves. No token in a killed byte
#     stream is provably whole (a cut SHA prefix can still resolve, and `<<<`
#     hands a newline-less tail to `read` as a line), so it gates EVERY
#     row-derived binding, strict head-identity matches included.
#   - a FILLED LIMIT only un-proves COMPLETENESS of the list. Every row a
#     cleanly-exited producer wrote is whole, and newest-first ordering means
#     truncation can only HIDE match rows, never corrupt one - so it gates
#     only the count-based uniqueness dispensation, and an intact strict
#     match keeps binding: head identity is ownership proof on its own and
#     needs row integrity, not global completeness.
# The installed `no-mistakes runs` (v1.31.2) documents --limit only as
# "maximum number of runs to display", orders by creation time, and DOES mark
# a cut listing with a human-oriented footer line, e.g. "(52 more runs, use
# --limit to see more)". The refusal below stays count-based and does not
# parse that footer (a separate change, deliberately not made here). The
# parser does NOT validate row shape - that is the durable fact - so the
# footer parses as an ordinary row: it increments `total`, pushing the
# filled-limit test toward refusal; it can never read as LIVE, because that
# requires status exactly `running` and its first field is "(52"; but it is
# not excluded from STRICT MATCHING, which ignores status entirely - under
# contrived names (a branch literally named `more`, a ref named `runs,` at
# HEAD) its second and third fields can produce a match, which renders the
# unrecognised phase `unknown` rather than `working`, so the effect on stall
# suppression stays conservative even then. What makes that unreachable in
# practice is this fleet's `fm/*` branch naming - a property of our naming,
# not of this code. A live-runs-only or completeness-marked query on a newer
# CLI would let the consumers prove the active set instead of refusing on
# possible truncation.
# Unlike every other no-mistakes read in this file, this call site keeps the
# query's exit status (fm_nm_run_checked, not the fail-open fm_nm_run): the
# discarded status was the only signal separating a short complete list from
# a killed query's partial - possibly torn - prefix.
NM_RUNS_MATCH_STATUS=''
NM_RUNS_LIVE_N=0
NM_RUNS_LIVE_SHA=''
NM_RUNS_ROWS_TAINTED=0
NM_RUNS_INCOMPLETE=0
nm_scan_runs_for_branch() {  # <branch>
  local branch=$1 out row st rest br sha total=0
  NM_RUNS_MATCH_STATUS=''
  NM_RUNS_LIVE_N=0
  NM_RUNS_LIVE_SHA=''
  NM_RUNS_ROWS_TAINTED=0
  NM_RUNS_INCOMPLETE=0
  if ! out=$(fm_nm_run_checked "$WT" "$NM_TIMEOUT" "$NM_KILL_AFTER" \
    runs --limit "$FM_CREW_STATE_RUNS_LIMIT"); then
    NM_RUNS_ROWS_TAINTED=1
    NM_RUNS_INCOMPLETE=1
    return 0
  fi
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(trim "$row")
    [ -n "$row" ] || continue
    total=$((total + 1))
    st=${row%% *}
    rest=${row#* }
    rest=$(trim "$rest")
    br=${rest%% *}
    rest=${rest#* }
    rest=$(trim "$rest")
    sha=${rest%% *}
    [ "$br" = "$branch" ] || continue
    if [ "$st" = running ]; then
      NM_RUNS_LIVE_N=$((NM_RUNS_LIVE_N + 1))
      NM_RUNS_LIVE_SHA=$sha
    fi
    if [ -z "$NM_RUNS_MATCH_STATUS" ] \
      && [ "$(fm_nm_head_relation "$WT" "$sha")" = match ]; then
      NM_RUNS_MATCH_STATUS=$st
    fi
  done <<< "$out"
  [ "$total" -ge "$FM_CREW_STATE_RUNS_LIMIT" ] && NM_RUNS_INCOMPLETE=1
  return 0
}

# Coarse status for <branch>: the newest strictly-matching row's status word
# (running/completed/cancelled/failed), else `running` only when the branch has
# EXACTLY one still-running row and its sha is unresolvable here - the
# mid-flight pipeline-worktree shape nm_run_attributes_here explains. Two or
# more live rows means the branch's live run cannot be told apart from another
# incarnation's, so nothing binds (fail closed, independent-review finding on
# the 2026-08-10 fix); echoes empty when the branch has no acceptable run
# within FM_CREW_STATE_RUNS_LIMIT rows.
# <allow-unresolvable> must be 0 when `axi status` already answered for this
# same branch and nm_run_attributes_here rejected that answer: the sole live
# row is then a coarser view of the very run the detailed surface just refused
# (gated, terminal, ambiguous, or diverged), and binding it here would launder
# the rejection through the fallback. A possibly-incomplete view
# (NM_RUNS_INCOMPLETE) also refuses the dispensation: a sole-live count from
# an incomplete view proves nothing. An intact strict-match row from an
# untainted view still binds even when the slice filled its limit - head
# identity is ownership proof on its own. A tainted query's rows never reach
# the returns below twice over: the scan discards them unparsed, AND the
# explicit taint check here keeps the strict-match return refusing even if
# that discard were ever loosened - the round-4 torn-row bind was exactly an
# unstated precondition on this return, so it is stated in code.
nm_runs_status_for_branch() {  # <branch> <allow-unresolvable:1|0>
  nm_scan_runs_for_branch "$1"
  [ "$NM_RUNS_ROWS_TAINTED" = 0 ] || return 0
  if [ -n "$NM_RUNS_MATCH_STATUS" ]; then
    printf '%s' "$NM_RUNS_MATCH_STATUS"
    return 0
  fi
  [ "${2:-1}" = 1 ] || return 0
  [ "$NM_RUNS_INCOMPLETE" = 0 ] || return 0
  if [ "$NM_RUNS_LIVE_N" = 1 ] \
    && [ "$(fm_nm_head_relation "$WT" "$NM_RUNS_LIVE_SHA")" = unresolvable ]; then
    printf 'running'
  fi
  return 0
}

# 0 when one hex commit id is a prefix of the other: runs-list rows carry a
# short sha while `axi status` may carry the full one, and correspondence
# between the two surfaces is what ties the sole live row to the axi run.
nm_sha_corresponds() {  # <a> <b>
  [ -n "$1" ] && [ -n "$2" ] || return 1
  case "$1" in "$2"*) return 0 ;; esac
  case "$2" in "$1"*) return 0 ;; esac
  return 1
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned crew, or a scout's
# scratch worktree); with no branch there is no run to attribute to this crew.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# 0 if the active axi-status run binds to this worktree's code identity.
# Branch match is a precondition (caller); the head relation itself is owned by
# fm_nm_head_relation in bin/fm-nm-run-lib.sh. A strict `match` always binds.
# An `unresolvable` head - not an object in this repo at all - may additionally
# bind: no-mistakes executes the run in its own private worktree, so from the
# rebase step onward the run head exists only there until push, and demanding
# local resolvability misread every such mid-flight run as unattributed (the
# 2026-08-10 false-wedge incident: a healthy nine-minute review step on a
# rebased head kept wedge-escalating because --run-progress reported none).
#
# A branch name plus a live-looking status is NOT ownership proof, so the
# dispensation fails closed unless ALL of these hold (independent-review
# findings on the first cut of this fix):
#   - the run is not parked at a gate in ANY representation (nm_run_is_gated;
#     a scalar or block gate carries top-level `status: running`, so the
#     top-level status alone cannot exclude it);
#   - no outcome yet and top-level status running/fixing/ci;
#   - the runs list shows EXACTLY ONE still-running row for this branch, that
#     row's sha is itself unresolvable here, and it corresponds to the axi
#     run's head - two live same-branch candidates cannot be told apart, and
#     binding the wrong one would let its progress mask a genuinely stalled
#     task, which is precisely the alarm this must never silence;
#   - the runs view is provably complete (NM_RUNS_INCOMPLETE=0): it neither
#     filled its requested limit (a full slice may hide a second live
#     candidate beyond it, and raising the limit would only move that
#     boundary) nor came from a failed or timed-out query, whose partial
#     stdout is indistinguishable from a short complete list by count alone -
#     the scan keeps the query's exit status for exactly this reason (see
#     nm_scan_runs_for_branch).
# STATED RESIDUALS, deliberately not papered over - what the code actually
# leaves open, not what it was meant to leave open:
#   - a stale-but-agreeing view: a snapshot that still shows the
#     corresponding sole live row while omitting a second candidate that
#     went live after the snapshot was taken passes every condition above,
#     and no freshness or generation signal exists on the installed CLI to
#     rule it out. Neither the incompleteness nor the taint refusal covers
#     it; it is accepted as the residual risk of the dispensation.
#   - row integrity on a zero-exit query is trusted, not verified: the row
#     format carries no terminator or checksum, so a producer that emitted
#     corrupted-but-well-formed-looking rows and still exited zero would be
#     believed, strict matches included. Only a nonzero exit marks rows
#     untrustworthy.
# The refusal direction is deliberately NOISY, never silent: whenever
# corroboration is empty, unavailable, failed or timed out mid-list,
# ambiguous, mismatched, or possibly truncated, a genuinely healthy mid-flight
# run reads unattributed and its crew may draw a visible wedge alarm - that
# alarm is recoverable, a suppressed one is not. Read a surprising false
# wedge on a validating crew against these conditions first.
# A terminal or gate-parked run whose head never reached this repo stays
# unbound exactly as before - that is the reused-branch stale-run shape the
# strict rule exists to reject - so a cancelled, superseded, or long-parked
# historical run cannot claim a crew that has already rebuilt its branch.
nm_run_attributes_here() {
  local run_head outcome
  run_head=$(strip_quotes "$(nm_field head)")
  case "$(fm_nm_head_relation "$WT" "$run_head")" in
    match) return 0 ;;
    unresolvable) ;;
    *) return 1 ;;
  esac
  nm_run_is_gated && return 1
  outcome=$(strip_quotes "$(nm_field outcome)")
  [ -z "$outcome" ] || return 1
  case "$(strip_quotes "$(nm_field status)")" in
    running|fixing|ci) ;;
    *) return 1 ;;
  esac
  nm_scan_runs_for_branch "$CREW_BRANCH"
  [ "$NM_RUNS_INCOMPLETE" = 0 ] || return 1
  [ "$NM_RUNS_LIVE_N" = 1 ] || return 1
  [ "$(fm_nm_head_relation "$WT" "$NM_RUNS_LIVE_SHA")" = unresolvable ] || return 1
  nm_sha_corresponds "$run_head" "$NM_RUNS_LIVE_SHA"
}

HAVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means only
# a bare status word came back from the runs-list fallback above, so the
# run-step block below skips the TOON field parsing entirely for this crew.
RUN_SOURCE=full
COARSE_STATUS=""
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(nm_run axi status)
  if [ -n "$RUN_OUT" ]; then
    run_branch=$(strip_quotes "$(nm_field branch)")
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] && nm_run_attributes_here; then
      HAVE_RUN=1
    else
      # The active-or-most-recent run is for another branch, or same branch with
      # a rewritten/diverged head (the CLI is alive and answered; only the
      # attribution missed) - try the coarse fallback.
      # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
      # When the rejected answer was for THIS branch, forbid the fallback's
      # unresolvable-row dispensation (see nm_runs_status_for_branch).
      allow_unres=1
      [ "$run_branch" = "$CREW_BRANCH" ] && allow_unres=0
      COARSE_STATUS=$(nm_runs_status_for_branch "$CREW_BRANCH" "$allow_unres")
      if [ -n "$COARSE_STATUS" ]; then
        HAVE_RUN=1
        RUN_SOURCE=coarse
      fi
    fi
  fi
fi

# --- run progress token (--run-progress only) -------------------------------
#
# The token deliberately carries ONLY fields whose change means the pipeline
# structurally moved: the run id, the run head, and each step's name:status
# pair. duration_ms and per-step findings counts are excluded on purpose. If a
# running step's duration ticks upward between reads (it is recorded only on
# completion in every run observed here, but that is no-mistakes' choice to
# change, not ours), a duration-bearing token would differ on EVERY read, the
# wedge deferral would renew forever, and a genuinely frozen pipeline would be
# silenced permanently - a silent safety failure. Excluding it means the token
# can only be renewed by real structural progress, so the worst case is an extra
# alarm rather than a missed wedge.
#
# Steps rows are the TOON table body ("  <step>,<status>,<findings>,<duration>");
# rows that do not parse are simply left out, which can only make the token
# coarser (more likely to look frozen), never falsely fresh.
nm_step_pairs() {
  printf '%s\n' "$RUN_OUT" \
    | sed -n 's/^[[:space:]]*\([A-Za-z0-9_-][A-Za-z0-9_-]*\),\([A-Za-z0-9_-][A-Za-z0-9_-]*\),[0-9][0-9]*,[0-9][0-9]*[[:space:]]*$/\1:\2/p' \
    | tr '\n' ',' | sed 's/,$//'
}

if [ "$PROGRESS_MODE" = 1 ]; then
  # No attributed run: report `none` here rather than falling through to the
  # pane/log fallback, whose backend reads buy nothing for a progress read.
  [ "$HAVE_RUN" = 1 ] || emit unknown none
  WT_HEAD=$(git -C "$WT" rev-parse --short HEAD 2>/dev/null || true)
  if [ "$RUN_SOURCE" = coarse ]; then
    # The coarse runs-list fallback carries no step detail at all, so the only
    # progress it can witness is a new commit. A long coarse-attributed step
    # therefore reads as frozen and eventually alarms - correct, since we have
    # no evidence it is advancing.
    PROGRESS_TOKEN="coarse/${COARSE_STATUS}/${WT_HEAD:-nohead}"
  else
    RUN_ID=$(strip_quotes "$(nm_field id)")
    RUN_HEAD=$(strip_quotes "$(nm_field head)")
    [ -n "$RUN_HEAD" ] || RUN_HEAD=$WT_HEAD
    STEP_PAIRS=$(nm_step_pairs)
    [ -n "$STEP_PAIRS" ] || STEP_PAIRS="status:$(strip_quotes "$(nm_field status)")"
    PROGRESS_TOKEN="${RUN_ID:-norun}/${RUN_HEAD:-nohead}/${STEP_PAIRS}"
  fi
  # Fall through: the run-step interpretation below decides the phase, and its
  # emit renders `<phase>/<token>`.
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  CI_STEP_STATUS=""
  CI_LOG_STATE=""
  RUN_STATUS=""
  if [ "$RUN_SOURCE" = coarse ]; then
    # No step/gate detail is available from the plain runs list - only ever
    # true/working, done, or failed. A crew genuinely parked at a gate still
    # gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a captain-relevant VERB) is
    # surfaced through signal_reason_is_actionable regardless of this
    # coarse-vs-full distinction, so a real gate is never silently missed.
    case "$COARSE_STATUS" in
      running)   RUN_STATE=working; RUN_DETAIL="validating (background run)" ;;
      completed) RUN_STATE="done";  RUN_DETAIL="run completed" ;;
      failed)    RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled) RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      *)         RUN_STATE=unknown; RUN_DETAIL="runs list status: $COARSE_STATUS" ;;
    esac
  else
    status=$(strip_quotes "$(nm_field status)")
    RUN_STATUS=$status
    outcome=$(strip_quotes "$(nm_field outcome)")

    if [ -n "$outcome" ]; then
      case "$outcome" in
        passed)        RUN_STATE="done"; RUN_DETAIL="run passed: PR merged/closed" ;;
        checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review" ;;
        failed)        RUN_STATE=failed; RUN_DETAIL="run failed" ;;
        cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled" ;;
        *)             RUN_STATE=unknown; RUN_DETAIL="outcome: $outcome" ;;
      esac
    elif nm_run_is_gated; then
      has_gate=0
      nm_has_gate && has_gate=1
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: authority decision)"
      fi
    else
      case "$status" in
        ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
        running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
        completed)      RUN_STATE="done"; RUN_DETAIL="run completed" ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
        "")             RUN_STATE=working; RUN_DETAIL="run active" ;;
        *)              RUN_STATE=working; RUN_DETAIL="run active ($status)" ;;
      esac
      if [ "$RUN_STATE" = working ]; then
        CI_STEP_STATUS=$(nm_effective_ci_step_status)
        case "$CI_STEP_STATUS" in
          running)
            CI_LOG_STATE=$(nm_ci_checks_state)
            if [ "$CI_LOG_STATE" = green ]; then
              RUN_STATE="done"
              RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
            fi
            ;;
          fixing)
            CI_LOG_STATE=not-ready
            ;;
        esac
      fi
    fi
  fi

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" = coarse ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
    [ -n "$CI_STEP_STATUS" ] || CI_STEP_STATUS=$(nm_effective_ci_step_status)
    if [ "$RUN_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    elif [ "$CI_STEP_STATUS" = running ] && [ -z "$CI_LOG_STATE" ]; then
      CI_LOG_STATE=$(nm_ci_checks_state)
    elif [ "$CI_STEP_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    fi
    if [ "$CI_LOG_STATE" != not-ready ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
  fi

  # Reconcile the status log. A needs-decision/blocked log line that the run-step
  # has moved past (anything but a genuinely parked run) is deterministically
  # stale: the gate resolved and the run resumed or finished.
  case "$LOG_VERB" in
    needs-decision|blocked)
      if [ "$RUN_STATE" != parked ]; then
        if [ "$RUN_STATE" = working ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (run $RUN_STATE)"
        fi
      fi
      ;;
  esac

  emit "$RUN_STATE" run-step "$RUN_DETAIL"
fi

# --- fallback: no run attributed to this crew ------------------------------
# The run-step path above already handled any crew with a run, regardless of pane
# liveness, so a finished-but-pane-closed crew never reaches here. Down here there
# is no run to consult, so a dead/unreadable target means the crew is gone: report
# unknown rather than trusting a possibly-stale status log as the current state.
[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
pane_readable "$BACKEND_TARGET" || emit unknown none "backend target gone: $BACKEND_TARGET"

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# state is not meaningful for them; read their state from the status log only.
# Only an exact busy verdict reports working here, and only an exact idle
# verdict permits the status-log fallback below. Missing, malformed, stale, or
# unverified semantic state remains unknown.
if [ "$KIND" != secondmate ]; then
  BUSY_VERDICT=$(crew_busy_verdict "$BACKEND_TARGET")
  case "${BUSY_VERDICT%% *}" in
    busy) emit working pane "harness busy (${BUSY_VERDICT#* })" ;;
    idle) ;;
    *) emit unknown pane "harness state unavailable ($BUSY_VERDICT)" ;;
  esac
fi

# Fall back to the status log's last line, but ONLY when its verb maps to a real
# run-state. A decision-closing event - resolved: (fm-classify-lib.sh's
# FM_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle crew (typically a secondmate, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

emit unknown none "no current-state source available"
