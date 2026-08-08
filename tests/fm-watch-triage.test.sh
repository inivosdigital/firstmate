#!/usr/bin/env bash
# tests/fm-watch-triage.test.sh - the always-on wake triage built into
# bin/fm-watch.sh and the shared classifier (bin/fm-classify-lib.sh). The watcher
# now absorbs the benign majority of wakes in bash and exits ONLY on an actionable
# wake, so firstmate's LLM re-arms once per actionable event instead of once per
# wake. These tests cover the classifier predicates as pure functions, then drive
# a real fm-watch.sh subprocess to assert the behavioral contract:
# provably-working no-verb wakes absorbed (no exit, no queue entry, suppressor
# advanced, beacon fresh), stopped-crew no-verb wakes surfaced (queue + exit),
# provably-working stale panes absorbed-then-escalated past the threshold,
# terminal-looking stale status lines overridden by an active run, wedge alarms
# deferred while an attributed validation run is advancing or is finished and
# awaiting merge (and still raised once it stops moving), the heartbeat
# backstop fail-safe, and afk coherence (no double-triage while the away-mode
# daemon owns supervision).
#
# Daemon-side classification/injection lives in fm-daemon.test.sh; watcher/lock
# liveness in fm-watcher-lock.test.sh; the durable-queue safety matrix in
# fm-wake-queue.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-tests)

# Common watcher knobs: tight poll/grace, no check or heartbeat cadence unless a
# test overrides them, so a test only exercises the path it targets. FM_CREW_STATE_BIN
# points at the case's hermetic fake fm-crew-state.sh (installed by make_case) so the
# absorb-only-when-provably-working triage reads a canned verdict; a test fixes that
# verdict via FM_FAKE_CREW_STATE in its environment before calling watch_bg.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

wait_numeric_file() {
  local file=$1 limit=${2:-30} i=0 value
  while [ "$i" -lt "$limit" ]; do
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_path_exists() {
  local file=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -e "$file" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

wait_mtime_after() {
  local file=$1 before=$2 limit=${3:-80} i=0 m
  while [ "$i" -lt "$limit" ]; do
    m=$(file_mtime "$file" || true)
    case "$m" in
      ''|*[!0-9]*) ;;
      *) [ "$m" -gt "$before" ] && return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Set <file>'s mtime to exactly <epoch> seconds, for aging a busy-turn marker by
# a precise amount (touch -t takes a local-time stamp, not an epoch, on both
# platforms, so convert via BSD `date -r` or GNU `date -d @`).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# Prime <file>'s .seen-* suppressor to its CURRENT signature, so the per-poll
# no-verb signal scan (which watches every *.turn-ended for a size:mtime change)
# treats a just-created or just-backdated turn-ended marker as already seen.
# Busy-turn-age fixtures create/backdate turn-ended directly (there is no real
# harness touching it), so without this the marker's own first sighting would
# fire an unrelated "signal:" wake and mask the busy-turn-age assertion under
# test. Call again after any further touch/set_mtime on the same file.
prime_turnend_seen() {  # <file>
  local f=$1 base
  base=$(basename "$f" | tr '.' '_')
  printf '%s' "$(seen_sig "$f")" > "$(dirname "$f")/.seen-$base"
}

record_pi_busy() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source pi-ext --event agent-start
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- pure classifier predicates (fm-classify-lib.sh) ------------------------

test_signal_reason_is_actionable_classifier() {
  local dir state
  dir=$(make_case classify-signal); state="$dir/state"
  printf 'working: step 1\nworking: step 2\n' > "$state/a.status"
  signal_reason_is_actionable "$state/a.status" && fail "benign working: signal classified actionable"
  printf 'working: x\nneeds-decision: pick A or B\n' > "$state/b.status"
  signal_reason_is_actionable "$state/b.status" || fail "captain-relevant signal classified benign"
  : > "$state/c.turn-ended"
  signal_reason_is_actionable "$state/c.turn-ended" && fail "a bare turn-ended marker classified actionable"
  # Coalesced batch: one benign + one captain-relevant -> actionable.
  signal_reason_is_actionable "$state/a.status" "$state/b.status" || fail "coalesced benign+actionable not actionable"
  pass "signal_reason_is_actionable: benign absorbed, captain verbs and coalesced batches surfaced"
}

test_stale_is_terminal_classifier() {
  local dir state
  dir=$(make_case classify-stale); state="$dir/state"
  printf 'done: ready in branch fm/x\n' > "$state/term.status"
  stale_is_terminal "sess:fm-term" "$state" || fail "terminal stale status not classified terminal"
  fm_write_meta "$state/herdr-term.meta" "window=default:w1:p2" "backend=herdr"
  printf 'done: ready in branch fm/herdr\n' > "$state/herdr-term.status"
  stale_is_terminal "default:w1:p2" "$state" || fail "terminal herdr stale status not resolved through metadata"
  printf 'working: compiling\n' > "$state/nonterm.status"
  stale_is_terminal "sess:fm-nonterm" "$state" && fail "non-terminal stale classified terminal"
  stale_is_terminal "sess:fm-missing" "$state" && fail "stale with no status classified terminal"
  pass "stale_is_terminal: terminal status surfaces, non-terminal and no-status are benign"
}

test_scan_captain_relevant_statuses_classifier() {
  local dir state out
  dir=$(make_case classify-scan); state="$dir/state"
  printf 'working: a\n' > "$state/one.status"
  printf 'blocked: no perms\n' > "$state/two.status"
  printf 'done: PR https://x/y/pull/1\n' > "$state/three.status"
  out=$(scan_captain_relevant_statuses "$state")
  printf '%s' "$out" | grep -F "two.status" >/dev/null || fail "scan missed a blocked: status"
  printf '%s' "$out" | grep -F "three.status" >/dev/null || fail "scan missed a done: status"
  printf '%s' "$out" | grep -F "one.status" >/dev/null && fail "scan surfaced a benign working: status"
  pass "scan_captain_relevant_statuses lists only captain-relevant statuses"
}

test_classifier_primitives() {
  local dir state open activity
  dir=$(make_case classify-primitives); state="$dir/state"
  printf 'working: a\n\ndone: b\n\n' > "$state/x.status"
  [ "$(last_status_line "$state/x.status")" = "done: b" ] || fail "last_status_line did not return the last non-blank line"
  status_is_captain_relevant "done: b" || fail "done: not recognized as captain-relevant"
  status_is_captain_relevant "needs-decision [key=q1]: b" || fail "keyed needs-decision not recognized as captain-relevant"
  status_is_captain_relevant "working: b" && fail "working: wrongly recognized as captain-relevant"
  # Incident regression: free-text "merged" inside a nonterminal working: line must
  # not become captain-relevant (AFK false-terminal path).
  status_is_captain_relevant \
    "working: stage 2 setup complete on PR #74 exact source branch rebased onto merged #76; task dates preserved" \
    && fail "working: ... merged #N wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: rebased onto predecessor #76" \
    && fail "working: predecessor prose wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: PR ready checks green merged ready in branch" \
    && fail "working: free-text tokens wrongly recognized as captain-relevant"
  status_is_captain_relevant "done: PR https://x/pull/76 checks green" \
    || fail "genuine done: checks green not captain-relevant"
  status_is_terminal_verb "done: PR https://x/pull/76 checks green" \
    || fail "done: not a terminal verb"
  status_is_terminal_verb "working: rebased onto merged #76" \
    && fail "working: wrongly classed as terminal verb"
  status_is_captain_relevant "merged" || fail "legacy bare merged free-text not captain-relevant"
  status_is_captain_relevant "PR ready https://x/pull/2" \
    || fail "legacy bare PR ready free-text not captain-relevant"
  [ "$(window_to_task "sess:fm-fix-login-k3")" = "fix-login-k3" ] || fail "window_to_task did not strip session+fm- prefix"
  fm_write_meta "$state/herdr-task.meta" "window=default:w1:p2" "backend=herdr"
  [ "$(window_to_task "default:w1:p2" "$state")" = "herdr-task" ] || fail "window_to_task did not resolve opaque backend target through metadata"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" || fail "FM_CAPTAIN_RE override not honored"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "done: x" && fail "FM_CAPTAIN_RE override did not replace the default verb set"
  FM_CAPTAIN_RE='merged|custom-verb:' status_is_captain_relevant "working: rebased onto merged #76" \
    && fail "FM_CAPTAIN_RE override bypassed working: suppression"
  FM_CAPTAIN_RE='checks green|custom-verb:' status_is_captain_relevant "paused: checks green pending approval" \
    && fail "FM_CAPTAIN_RE override bypassed paused: suppression"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" \
    || fail "nonterminal suppression weakened custom bare-line behavior"
  printf 'needs-decision: should docs mention [key=prose]?\nneeds-decision [key=q1]: real choice\nresolved: docs still mention [key=q1]\nneeds-decision [key=bad key]: malformed\n' > "$state/keys.status"
  open=$(status_open_decisions "$state/keys.status")
  printf '%s' "$open" | grep -F $'q1\t' >/dev/null \
    || fail "a key token in resolved note prose closed the keyed decision"
  printf '%s' "$open" | grep -F $'prose\t' >/dev/null \
    && fail "a key token in note prose changed the decision key"
  printf '%s' "$open" | grep -F $'bad key\t' >/dev/null \
    && fail "an invalid key slug entered the open-decision set"
  cat > "$state/activity.status" <<'EOF'
working [key=phase7]: Phase 7 started
working [key=phase6]: Phase 6 started
working [key=legal]: reviewing legal dependency
done [key=phase6]: Phase 6 completed
resolved [key=phase7]: Phase 7 completed and moved to Done
paused [key=legal]: awaiting external counsel
resolved [key=legal]: legal item returned to the queue
working [key=phase8]: Phase 8 started
EOF
  activity=$(status_open_activities "$state/activity.status")
  printf '%s' "$activity" | grep -F $'phase8\tworking\tPhase 8 started' >/dev/null \
    || fail "the current keyed working phase was not retained"
  printf '%s' "$activity" | grep -F $'phase7\t' >/dev/null \
    && fail "a keyed resolved event did not close the older working phase"
  printf '%s' "$activity" | grep -F $'phase6\t' >/dev/null \
    && fail "a same-key terminal event did not supersede the older working phase"
  printf '%s' "$activity" | grep -F $'legal\t' >/dev/null \
    && fail "a keyed resolved event did not close the declared pause"
  printf 'working: legacy start\ndone: legacy completion\n' > "$state/legacy-activity.status"
  [ -z "$(status_open_activities "$state/legacy-activity.status")" ] \
    || fail "a legacy terminal event did not supersede the default working phase"
  pass "classifier primitives: keyed decisions and activity phases, captain relevance, window-to-task, and overrides"
}

# crew_is_provably_working: the absorb-only-when-provably-working predicate. It is
# benign (absorb) ONLY when fm-crew-state.sh reports the crew as working from an
# actively-running pipeline step (source run-step) or a busy pane (source pane);
# everything else - a stale working: status-log line, a finished/parked/failed run,
# an unknown/torn-down crew, or an empty id - is NOT provable, so it surfaces. The
# fake fm-crew-state.sh (FM_CREW_STATE_BIN) returns a canned verdict per case.
test_crew_is_provably_working_classifier() {
  local dir fakebin
  dir=$(make_case provably-working); fakebin="$dir/fakebin"
  # Point the predicate at this case's hermetic fake and drive its verdict per case.
  # export marks the var for the fake subprocess; it is unset again at the end so it
  # cannot leak into a later test (every behavioral test sets its own verdict anyway).
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  crew_is_provably_working a || fail "active run-step not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  crew_is_provably_working a || fail "busy pane not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  ! crew_is_provably_working a || fail "stale status-log working: treated as provably working"
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  ! crew_is_provably_working a || fail "finished run treated as provably working"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  ! crew_is_provably_working a || fail "parked run treated as provably working"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  ! crew_is_provably_working a || fail "failed run treated as provably working"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  ! crew_is_provably_working a || fail "unknown crew treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: run-step · x'
  ! crew_is_provably_working "" || fail "empty id treated as provably working"
  unset FM_FAKE_CREW_STATE
  pass "crew_is_provably_working: only working+run-step/pane is provable; idle/finished/parked/failed/unknown surface"
}

# status_is_paused: the shared pause verb test both consumers read (so neither
# hardcodes the literal). Matches only the verb before the first colon, so a reason
# that merely mentions "paused" does not false-match, and a genuine blocker stays a
# blocker.
test_status_is_paused_classifier() {
  status_is_paused 'paused: holding for the upstream release' || fail "paused verb not recognized"
  status_is_paused '  paused:   waiting on a rate-limit reset' || fail "leading-space paused verb not recognized"
  status_is_paused 'blocked: the build is paused upstream' && fail "a blocked line mentioning paused false-matched"
  status_is_paused 'working: paused the animation loop' && fail "a working line mentioning paused false-matched"
  status_is_paused 'done: shipped' && fail "done classified as paused"
  status_is_paused '' && fail "empty line classified as paused"
  # A pause is deliberately NOT captain-relevant: it is a stop-nagging signal, not
  # work to keep surfacing.
  status_is_captain_relevant 'paused: holding for the upstream release' && fail "paused is captain-relevant (should not be)"
  status_is_paused_or_captain_held 'paused: holding for the upstream release' \
    || fail "declared pause not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'captain-held [key=route]: tracked by task-decision-route' \
    || fail "captain-held transfer not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'resolved [key=route]: captain answered' \
    && fail "resolved decision remained classed as captain-held"
  pass "status_is_paused: only the leading paused verb matches, and paused is not captain-relevant"
}

# crew_absorb_class: the single fm-crew-state.sh read that returns BOTH absorb
# reasons - working (active run/busy pane), paused (declared external wait), or none
# (surface it) - so the watcher's stale path gets both for one bounded call.
# crew_is_paused delegates to it exactly as crew_is_provably_working does.
test_crew_absorb_class_classifier() {
  local dir fakebin
  dir=$(make_case absorb-class); fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class a)" = working ] || fail "active run-step not classed working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  [ "$(crew_absorb_class a)" = working ] || fail "busy pane not classed working"
  FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting upstream'
  [ "$(crew_absorb_class a)" = paused ] || fail "declared pause not classed paused"
  crew_is_paused a || fail "crew_is_paused did not recognize a paused verdict"
  ! crew_is_provably_working a || fail "a paused crew was treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  [ "$(crew_absorb_class a)" = none ] || fail "stale working: status-log classed absorbable"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  [ "$(crew_absorb_class a)" = none ] || fail "unknown crew classed absorbable"
  ! crew_is_paused a || fail "unknown crew classed paused"
  [ "$(crew_absorb_class "")" = none ] || fail "empty id not classed none"
  unset FM_FAKE_CREW_STATE
  pass "crew_absorb_class: working/paused/none from one read; crew_is_paused and crew_is_provably_working agree"
}

# Regression (2026-07-15 live incident: ship-firstmate-autodeploy-alert-relay,
# ship-firstmate-fmsend-verify): an EXITED crewmate can leave a no-mistakes run's
# step orphaned mid-flight - never cancelled, so fm-crew-state.sh keeps reading a
# stale in-progress CI poll as `working · source: run-step` forever, even though
# nothing is actually advancing that run anymore. When the task itself declared a
# `paused:` status line and its own agent process is CONFIRMED dead
# (fm_backend_agent_alive), the declared pause is the more authoritative signal -
# crew_absorb_class must defer to it instead of the stale run-step, or the
# watcher's stale path never latches .paused-<key> and keeps re-nagging every
# poll instead of honoring the documented pause recheck cadence
# (FM_PAUSE_RESURFACE_SECS, docs/architecture.md "Event-driven supervision"). A
# live or ambiguous-liveness crewmate must NOT be overridden by a stray paused:
# line - run-step precedence still holds while the crewmate could plausibly
# resume the run itself.
test_crew_absorb_class_honors_declared_pause_over_orphaned_run_step() {
  local dir fakebin state
  dir=$(make_case absorb-orphaned-pause); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · checks green: PR ready for review (still monitoring for merge/close)'
  printf 'paused: awaiting the deploy window\n' > "$state/task-a.status"
  fm_write_meta "$state/task-a.meta" "window=sess:fm-task-a" "backend=tmux"

  # shellcheck disable=SC2329 # invoked indirectly via the sourced fm-classify-lib.sh
  fm_backend_agent_alive() { printf 'dead'; }
  [ "$(crew_absorb_class task-a)" = paused ] \
    || fail "an exited crewmate's orphaned run-step working verdict was not overridden by its own declared pause"

  # shellcheck disable=SC2329 # invoked indirectly via the sourced fm-classify-lib.sh
  fm_backend_agent_alive() { printf 'alive'; }
  [ "$(crew_absorb_class task-a)" = working ] \
    || fail "a live crewmate's run-step was wrongly overridden by a stray paused: line"

  # shellcheck disable=SC2329 # invoked indirectly via the sourced fm-classify-lib.sh
  fm_backend_agent_alive() { printf 'unknown'; }
  [ "$(crew_absorb_class task-a)" = working ] \
    || fail "an unconfirmed (unknown) liveness read wrongly licensed the paused override"

  unset -f fm_backend_agent_alive
  unset FM_FAKE_CREW_STATE FM_STATE_OVERRIDE
  pass "crew_absorb_class: an exited crewmate's declared pause overrides an orphaned run-step verdict; live/unknown liveness keeps run-step precedence"
}

# Regression (2026-07-19 live incident: carscanner-nmvtis-paid-pull): a no-mistakes
# run genuinely PARKED at a captain-decision gate (an open needs-decision, e.g. an
# ask-user finding) can still read `working · source: run-step` from
# fm-crew-state.sh - its cross-branch run lookup falls back to a coarse listing
# with no per-step gate detail when the primary attribution misses, so a parked
# gate looks identical to a genuinely active run. The crew's own last status line
# correctly declares `paused: ...` for this expected wait, but the ALIVE backend
# used to block the demotion (the orphaned-crewmate override above requires
# CONFIRMED DEAD), so the declared pause was silently ignored and the watcher kept
# re-surfacing an identical stale wake every poll instead of the hour-long pause
# recheck cadence. A still-open needs-decision/blocked hold is proof the crew
# cannot progress on its own regardless of whether its process happens to still be
# resident, so it must license the same demotion the dead-check licenses - with an
# ALIVE backend and no liveness check involved at all.
test_crew_absorb_class_honors_declared_pause_at_open_gate_even_when_alive() {
  local dir fakebin state
  dir=$(make_case absorb-open-gate-pause); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (background run)'
  {
    printf 'needs-decision: run parked at the document gate on one ask-user finding\n'
    printf 'paused: holding at document gate for captain footer-wording decision - do not treat as a wedge\n'
  } > "$state/task-a.status"
  fm_write_meta "$state/task-a.meta" "window=sess:fm-task-a" "backend=tmux"

  # shellcheck disable=SC2329 # invoked indirectly via the sourced fm-classify-lib.sh
  fm_backend_agent_alive() { printf 'alive'; }
  [ "$(crew_absorb_class task-a)" = paused ] \
    || fail "an alive crewmate genuinely parked at an open captain-decision gate was not classed paused"
  crew_is_paused task-a || fail "crew_is_paused did not recognize the open-gate pause verdict"

  # shellcheck disable=SC2329 # invoked indirectly via the sourced fm-classify-lib.sh
  fm_backend_agent_alive() { printf 'unknown'; }
  [ "$(crew_absorb_class task-a)" = paused ] \
    || fail "unknown liveness must not block the open-gate pause override"

  unset -f fm_backend_agent_alive
  unset FM_FAKE_CREW_STATE FM_STATE_OVERRIDE
  pass "crew_absorb_class: a declared pause at a still-open captain-decision gate is honored regardless of backend liveness"
}

# Disconfirming check for the fix above: a task with NO declared paused: line, and
# no open decision either, must still read as NOT provably working (surfaces as a
# possible wedge) exactly as before - the gate override only fires behind
# status_is_paused, so an ordinary stale working/run-step verdict with no pause
# declaration is completely untouched by this change.
test_crew_absorb_class_unpaused_wedge_still_surfaces() {
  local dir fakebin state
  dir=$(make_case absorb-unpaused-wedge); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (background run)'
  printf 'needs-decision: run parked at the document gate on one ask-user finding\n' > "$state/task-a.status"
  fm_write_meta "$state/task-a.meta" "window=sess:fm-task-a" "backend=tmux"

  # shellcheck disable=SC2329 # invoked indirectly via the sourced fm-classify-lib.sh
  fm_backend_agent_alive() { printf 'alive'; }
  [ "$(crew_absorb_class task-a)" = working ] \
    || fail "a task with an open gate but no declared paused: line was wrongly classed paused"
  crew_is_provably_working task-a \
    || fail "a task with an open gate but no declared paused: line lost its provably-working classification"

  unset -f fm_backend_agent_alive
  unset FM_FAKE_CREW_STATE FM_STATE_OVERRIDE
  pass "crew_absorb_class: an open gate with no declared paused: line keeps ordinary working classification, unaffected by the gate override"
}

# Regression (2026-07-26 live incident: beamanalyzer-steel-shear-ltb PR 46,
# beamanalyzer-capacity-finder PR 47): a task can finish its no-mistakes run
# (fm-crew-state.sh reports `done`) and then deliberately idle afterward - the
# independent review a ship task awaits before merge (AGENTS.md section 7,
# bin/fm-ultracode-guard.sh). Before this fix, crew_absorb_class's working/paused
# checks only look at state=working and state=paused; a `done` state fell
# straight through to `none` regardless of the task's own declared paused: line,
# so the watcher's pause_state_class (bin/fm-watch.sh) never got a `paused`
# verdict to latch its per-hash guard on and instead re-surfaced the identical
# stale hash on every single poll, forever.
test_crew_absorb_class_honors_declared_pause_after_done() {
  local dir fakebin state
  dir=$(make_case absorb-done-pause); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  printf 'paused: awaiting independent review before merge\n' > "$state/task-a.status"
  fm_write_meta "$state/task-a.meta" "window=sess:fm-task-a" "backend=tmux"

  [ "$(crew_absorb_class task-a)" = paused ] \
    || fail "a finished (done) task's own declared pause was not honored (fell through to none)"
  crew_is_paused task-a || fail "crew_is_paused did not recognize a done task's declared pause"

  unset FM_FAKE_CREW_STATE FM_STATE_OVERRIDE
  pass "crew_absorb_class: a done task's own declared pause is honored instead of falling through to none"
}

# Disconfirming check for the fix above: a done task with NO declared paused:
# line - the ordinary ready-to-report case - must still classify as none and
# surface promptly, exactly as before. The done override only fires behind
# status_is_paused, so a plain done:/failed:/etc. last line is untouched.
test_crew_absorb_class_done_without_pause_still_surfaces() {
  local dir fakebin state
  dir=$(make_case absorb-done-no-pause); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  printf 'done: ready in branch fm/x\n' > "$state/task-a.status"
  fm_write_meta "$state/task-a.meta" "window=sess:fm-task-a" "backend=tmux"

  [ "$(crew_absorb_class task-a)" = none ] \
    || fail "a done task with no declared pause was wrongly classed absorbable"
  ! crew_is_paused task-a || fail "a done task with no declared pause was wrongly classed paused"

  unset FM_FAKE_CREW_STATE FM_STATE_OVERRIDE
  pass "crew_absorb_class: a done task with no declared pause keeps ordinary none classification, unaffected by the done-pause override"
}

# Regression (2026-08-08 live incident: beamanalyzer-round-hss-k22-bearing): a
# worker may prefix its status lines with an ISO-8601 timestamp - bin/fm-brief.sh
# specifies "<state>: <one short line>" and says nothing about a prefix - which
# puts a colon INSIDE the text every parser in fm-classify-lib.sh reads as the
# verb. The whole family then misread at once: the verb became "2026-08-08T06",
# the note "18:42Z blocked: ...", and a keyed decision fell back to "default". The
# visible symptom was a declared pause that never registered, so a correctly
# paused pane wedge-escalated every window; the severe one was a keyed
# needs-decision that read as neither captain-relevant nor a decision under its
# own key, so no matching resolution could ever close it.
#
# Each verb is asserted in BOTH forms against the SAME expected verdict, not
# merely against each other, so the pair cannot go vacuous by both forms breaking
# together.
test_timestamped_status_lines_classify_as_plain_ones() {
  local ts='2026-08-08T06:18:42Z ' verb want_paused want_held want_term want_capt
  local plain stamped got_p got_s

  # Verdict of one predicate on one line, as a comparable token.
  _ts_pred() {  # <fn> <line> -> yes|no
    if "$1" "$2"; then printf 'yes'; else printf 'no'; fi
  }
  # Assert one predicate agrees with <want> in both the plain and stamped form.
  _ts_both() {  # <fn> <want> <plain> <stamped> <verb>
    got_p=$(_ts_pred "$1" "$3"); got_s=$(_ts_pred "$1" "$4")
    [ "$got_p" = "$2" ] || fail "$5: plain form changed behavior - $1 returned $got_p, expected $2"
    [ "$got_s" = "$2" ] || fail "$5: timestamped form misclassified - $1 returned $got_s, expected $2"
  }

  # verb paused paused_or_held terminal_verb captain_relevant
  while read -r verb want_paused want_held want_term want_capt; do
    [ -n "$verb" ] || continue
    plain="$verb [key=api-shape]: some summary"
    stamped="$ts$plain"

    [ "$(status_line_verb "$stamped")" = "$verb" ] \
      || fail "$verb: timestamped verb parsed as '$(status_line_verb "$stamped")'"
    [ "$(status_line_verb "$plain")" = "$verb" ] \
      || fail "$verb: plain verb parsed as '$(status_line_verb "$plain")'"
    [ "$(status_line_note "$stamped")" = 'some summary' ] \
      || fail "$verb: timestamped note parsed as '$(status_line_note "$stamped")'"
    [ "$(status_line_note "$plain")" = 'some summary' ] \
      || fail "$verb: plain note parsed as '$(status_line_note "$plain")'"

    _ts_both status_is_paused "$want_paused" "$plain" "$stamped" "$verb"
    _ts_both status_is_paused_or_captain_held "$want_held" "$plain" "$stamped" "$verb"
    _ts_both status_is_terminal_verb "$want_term" "$plain" "$stamped" "$verb"
    _ts_both status_is_captain_relevant "$want_capt" "$plain" "$stamped" "$verb"
  done <<'VERBS'
working         no  no  no  no
paused          yes yes no  no
blocked         no  no  yes yes
needs-decision  no  no  yes yes
done            no  no  yes yes
failed          no  no  yes yes
resolved        no  no  no  no
captain-held    no  yes no  no
VERBS
  unset -f _ts_pred _ts_both

  # The colon-free +HHMM zone, pinned because it is the exact shape this repo's
  # own watcher log writes (state/.watch-triage.log records
  # "[2026-08-08T13:28:04-0400]"), and it is the one zone form no other
  # assertion here covers.
  status_is_paused '[2026-08-08T13:28:04-0400] paused: awaiting review' \
    || fail "a bracketed +HHMM-zone stamp was not read as a declared pause"
  status_is_paused '2026-08-08T13:28:04+0400 paused: awaiting review' \
    || fail "a bare +HHMM-zone stamp was not read as a declared pause"

  pass "every status verb classifies identically stamped and plain across the paused, captain-held, terminal and captain-relevant tests"
}

# The keyed decision and activity folds read the same verb/note/key family, so a
# stamped line must open and close a decision under its REAL key. Before the fix
# the key fell back to "default", so a stamped needs-decision opened a decision
# its own matching resolution could never close.
test_timestamped_status_lines_fold_under_their_real_key() {
  local dir state open activity
  dir=$(make_case classify-timestamped-fold); state="$dir/state"

  printf '%s\n' \
    '2026-08-08T04:10:30Z needs-decision [key=qf-floor]: floor Qf at 0 or not' \
    '2026-08-08T04:11:00Z done: implemented and committed' \
    > "$state/stamped.status"
  open=$(status_open_decisions "$state/stamped.status")
  printf '%s' "$open" | grep -F $'qf-floor\tneeds-decision\tfloor Qf at 0 or not' >/dev/null \
    || fail "a stamped needs-decision did not open under its real key with its real note: [$open]"
  printf '%s' "$open" | grep -F $'default\t' >/dev/null \
    && fail "a stamped needs-decision fell back to the default key"

  # ... and its matching stamped resolution closes it.
  printf '%s\n' '2026-08-08T04:15:00Z resolved [key=qf-floor]: captain kept the scope as briefed' \
    >> "$state/stamped.status"
  [ -z "$(status_open_decisions "$state/stamped.status")" ] \
    || fail "a stamped resolution did not close the decision its stamped opener raised"

  # The activity fold shares the family: a stamped declared pause opens a phase
  # under its own key, and a stamped terminal event closes it.
  printf '%s\n' \
    '2026-08-08T04:41:59Z paused [key=review]: awaiting validation review step' \
    > "$state/stamped-activity.status"
  activity=$(status_open_activities "$state/stamped-activity.status")
  printf '%s' "$activity" | grep -F $'review\tpaused\tawaiting validation review step' >/dev/null \
    || fail "a stamped declared pause did not open an activity phase under its real key: [$activity]"
  printf '%s\n' '2026-08-08T05:38:13Z done [key=review]: review returned green' \
    >> "$state/stamped-activity.status"
  [ -z "$(status_open_activities "$state/stamped-activity.status")" ] \
    || fail "a stamped terminal event did not close the phase its stamped pause opened"

  pass "stamped lines open and close keyed decisions and activity phases under their real key"
}

# crew_absorb_class is the fourth caller routed through the same parse: its
# declared-pause overrides all gate on status_is_paused reading this task's own
# last status line. With the verb mangled, a stamped `paused:` line was invisible
# here, so the watcher never latched a paused verdict and re-surfaced the
# identical stale hash every poll - the five consecutive wedge escalations that
# filed this defect.
test_crew_absorb_class_honors_timestamped_declared_pause() {
  local dir fakebin state
  dir=$(make_case absorb-timestamped-pause); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  fm_write_meta "$state/task-a.meta" "window=sess:fm-task-a" "backend=tmux"

  printf '2026-08-08T04:41:59Z paused: awaiting validation review step\n' > "$state/task-a.status"
  [ "$(crew_absorb_class task-a)" = paused ] \
    || fail "a stamped declared pause was not honored by crew_absorb_class (got $(crew_absorb_class task-a))"
  crew_is_paused task-a || fail "crew_is_paused did not recognize a stamped declared pause"
  ! crew_is_provably_working task-a || fail "a stamped paused crew was treated as provably working"

  # Same verdict as the plain form it is equivalent to.
  printf 'paused: awaiting validation review step\n' > "$state/task-a.status"
  [ "$(crew_absorb_class task-a)" = paused ] \
    || fail "the plain declared pause changed behavior"

  # The parked-gate override reads the stamped decision fold too: both signals
  # (a declared pause AND a still-open keyed decision) must be seen on stamped
  # lines, or a parked run re-surfaces on every poll.
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  printf '%s\n' \
    '2026-08-08T04:10:30Z needs-decision [key=qf-floor]: floor Qf at 0 or not' \
    '2026-08-08T04:41:59Z paused: awaiting the captain on the Qf floor' \
    > "$state/task-a.status"
  [ "$(crew_absorb_class task-a)" = paused ] \
    || fail "a stamped parked gate (stamped pause + stamped open decision) was not honored"

  # Disconfirming: once the stamped decision is resolved, the parked-gate
  # override must stop firing, so a genuinely wedged parked run still surfaces.
  # The pause is re-declared as the LAST line so that the open decision is the
  # only signal differing from the absorbed case above - otherwise the pause
  # test alone would carry this assertion and the two-signal bar would go
  # unpinned.
  printf '%s\n' \
    '2026-08-08T04:50:40Z resolved [key=qf-floor]: captain answered' \
    '2026-08-08T04:51:00Z paused: still idling after the answer landed' \
    >> "$state/task-a.status"
  [ "$(crew_absorb_class task-a)" = none ] \
    || fail "a parked run still declaring a pause but with no open decision left was absorbed as paused"

  unset FM_FAKE_CREW_STATE FM_STATE_OVERRIDE
  pass "crew_absorb_class: stamped declared pauses and stamped open decisions drive the same overrides as plain ones"
}

# A prefix format the normalizer does NOT recognize still leaves a verb it cannot
# parse. The deliberate rule (recorded in bin/fm-classify-lib.sh) is that such a
# line may never SUPPRESS anything: it is not the pause verb, not captain-held,
# not terminal, and it neither opens nor closes a decision or activity phase, so
# an unreadable line cannot quiet a pane and it keeps aging on the ordinary wedge
# path. Captain-relevance is deliberately NOT granted, because the away-mode
# daemon treats a captain-relevant nonterminal verdict as already surfaced and
# clears wedge aging, which would make it quieter rather than louder.
test_unparseable_status_verb_never_suppresses() {
  local dir state open activity
  dir=$(make_case classify-unparseable); state="$dir/state"

  # A US-style stamp, deliberately outside the ISO-8601 shape the normalizer
  # anchors on, so the verb genuinely cannot be recovered.
  local u='08/08/2026 06:18:42 '
  [ "$(status_line_verb "${u}paused: waiting")" = paused ] \
    && fail "fixture is not actually unparseable - the normalizer recovered the verb"

  status_is_paused "${u}paused: waiting" \
    && fail "an unparseable line was allowed to declare a pause and quiet the pane"
  status_is_paused_or_captain_held "${u}captain-held: tracked" \
    && fail "an unparseable line was allowed to claim a captain-held transfer"
  status_is_terminal_verb "${u}done: shipped" \
    && fail "an unparseable line was classed as a terminal verb"

  # The normalizer's other two anchors, each pinned here because loosening
  # either one moves a line from this non-suppressing path to a declared pause,
  # which silences the pane. The date anchor is pinned by the fixture guard
  # above; these two were previously held by nothing.
  status_is_paused '[2026-08-08T06:18:42Z paused: waiting on release' \
    && fail "a stamp whose bracket is never closed was allowed to declare a pause"
  status_is_paused '2026-08-08T06:18:42Zpaused: waiting on release' \
    && fail "a stamp with no whitespace after it was allowed to declare a pause"

  # It must not be able to CLOSE a real open decision. Asserted on a keyed AND a
  # default-key decision: under a key the unreadable key slug alone would block
  # the close, so only the bare form proves the unparseable VERB is what refuses
  # the transition.
  printf '%s\n' \
    'needs-decision [key=api-shape]: A or B' \
    "${u}resolved [key=api-shape]: answered" \
    > "$state/u.status"
  open=$(status_open_decisions "$state/u.status")
  printf '%s' "$open" | grep -F $'api-shape\tneeds-decision\t' >/dev/null \
    || fail "an unparseable resolution silently closed a genuinely open keyed decision: [$open]"

  printf '%s\n' 'needs-decision: A or B' "${u}resolved: answered" > "$state/u-default.status"
  open=$(status_open_decisions "$state/u-default.status")
  printf '%s' "$open" | grep -F $'default\tneeds-decision\t' >/dev/null \
    || fail "an unparseable resolution silently closed a genuinely open default-key decision: [$open]"

  # Nor silently supersede a running activity phase, keyed or default.
  printf '%s\n' \
    'working [key=phase1]: building' \
    "${u}done [key=phase1]: finished" \
    > "$state/u-activity.status"
  activity=$(status_open_activities "$state/u-activity.status")
  printf '%s' "$activity" | grep -F $'phase1\tworking\t' >/dev/null \
    || fail "an unparseable terminal event silently closed an open keyed activity phase: [$activity]"

  printf '%s\n' 'working: building' "${u}done: finished" > "$state/u-default-activity.status"
  activity=$(status_open_activities "$state/u-default-activity.status")
  printf '%s' "$activity" | grep -F $'default\tworking\t' >/dev/null \
    || fail "an unparseable terminal event silently closed an open default-key activity phase: [$activity]"

  pass "an unparseable status verb can never suppress: no pause, no captain-held, no terminal verdict, and no silent decision or phase close"
}

# Hard-constraint disconfirming checks for the pause_state_class fix in
# bin/fm-watch.sh (regression: beamanalyzer-caveat-em-dashes and siblings,
# see the comment above pause_state_class there): once a direct `paused`
# verdict from crew_absorb_class is trusted outright with no second liveness
# gate, the only remaining safety property is that crew_absorb_class itself
# keeps reporting a NON-paused verdict the moment reality no longer supports
# a pause. pause_state_class's dispatch is a straight passthrough for
# anything crew_absorb_class does NOT call `paused` (see its `case "$class"`
# block), so pinning crew_absorb_class here is equivalent to pinning
# pause_state_class for these cases; none of them exercise the fix's own new
# code path (the outright-trust branch), by design. A trailing stale
# `paused:` line is present in every case below to prove the override does
# NOT reach for it once the fresher state contradicts it.
test_crew_absorb_class_hard_constraints_still_surface() {
  local dir fakebin state
  dir=$(make_case absorb-hard-constraints); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  fm_write_meta "$state/task-a.meta" "window=sess:fm-task-a" "backend=tmux"

  # A PR that was green (done) and has since gone red.
  export FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed: tests red'
  printf 'paused: awaiting independent review before merge\n' > "$state/task-a.status"
  [ "$(crew_absorb_class task-a)" = none ] \
    || fail "a PR that went red after done was masked by its own stale declared pause"

  # A PR that was closed without merging.
  export FM_FAKE_CREW_STATE='state: failed · source: run-step · run cancelled: PR closed without merging'
  printf 'paused: awaiting independent review before merge\n' > "$state/task-a.status"
  [ "$(crew_absorb_class task-a)" = none ] \
    || fail "a PR closed without merging was masked by its own stale declared pause"

  # done: reported while the validation run is in fact still active, with a
  # confirmed-alive agent (rules out the orphaned-run-step dead-agent override).
  # shellcheck disable=SC2329 # invoked indirectly via the sourced fm-classify-lib.sh
  fm_backend_agent_alive() { printf 'alive'; }
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  printf 'paused: awaiting independent review before merge\n' > "$state/task-a.status"
  [ "$(crew_absorb_class task-a)" = working ] \
    || fail "an actually-still-active run was masked by a stale declared pause"
  unset -f fm_backend_agent_alive

  # done: reported but the worktree has since diverged (branch moved, new
  # uncommitted work resumed) - fm-crew-state.sh's own run-head matching
  # (unmodified by this fix, see tests/fm-crew-state.test.sh
  # test_historical_same_branch_rewritten_head_not_current) stops attributing
  # the old run and instead reports the pane genuinely busy with fresh activity.
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  printf 'paused: awaiting independent review before merge\n' > "$state/task-a.status"
  [ "$(crew_absorb_class task-a)" = working ] \
    || fail "fresh pane activity after a branch move was masked by a stale declared pause"

  unset FM_FAKE_CREW_STATE FM_STATE_OVERRIDE
  pass "crew_absorb_class: a red/cancelled run, a still-active run, and resumed pane activity all still surface despite a stale declared pause; see test_crew_absorb_class_done_without_pause_still_surfaces for the genuinely-wedged-done case and test_nonterminal_stale_not_working_surfaced for the plain idle-with-no-pause case"
}

# Regression (2026-07-31 live incident: scaffold-returns-readme-currency,
# falsework-cos-deliver-to-a-human): a no-mistakes run genuinely PARKED at a
# gate (fm-crew-state.sh's own `state: parked`, not the run-step fallback the
# gate override above handles) fell straight through to `none` because neither
# the working nor the done branch matches `state: parked` at all. The task's
# own last status line correctly declares `paused: ...` and it has a still-open
# keyed decision, but crew_absorb_class ignored both, so the watcher's
# pause_state_class never latched a `paused` verdict and re-surfaced the
# identical stale hash on every single poll for as long as the captain's
# decision was outstanding. Fixed with the same two-signal bar as the run-step
# gate override (declared pause AND an open keyed decision), not the
# single-signal done bar - see the "Parked-state override" comment above
# crew_absorb_class for why.
test_crew_absorb_class_honors_declared_pause_at_parked_gate() {
  local dir fakebin state
  dir=$(make_case absorb-parked-gate); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 1 finding(s) (ask-user: authority decision)'
  {
    printf 'needs-decision: run parked at the review gate on one ask-user finding\n'
    printf 'paused: parked at the review gate awaiting the captain decision\n'
  } > "$state/task-a.status"
  fm_write_meta "$state/task-a.meta" "window=sess:fm-task-a" "backend=tmux"

  [ "$(crew_absorb_class task-a)" = paused ] \
    || fail "a parked run with a declared pause and an open keyed decision was not classed paused"
  crew_is_paused task-a || fail "crew_is_paused did not recognize the parked-gate pause verdict"

  unset FM_FAKE_CREW_STATE FM_STATE_OVERRIDE
  pass "crew_absorb_class: a parked run with a declared pause and an open keyed decision is honored as paused"
}

# Disconfirming check for the fix above: a parked run with NEITHER a declared
# pause NOR an open decision - the genuinely wedged case the alarm exists to
# catch - must still classify as none and surface immediately, exactly as
# before. The override only fires behind BOTH signals together.
test_crew_absorb_class_parked_without_pause_or_decision_still_surfaces() {
  local dir fakebin state
  dir=$(make_case absorb-parked-no-signal); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 1 finding(s)'
  printf 'working: implementing the fix\n' > "$state/task-a.status"
  fm_write_meta "$state/task-a.meta" "window=sess:fm-task-a" "backend=tmux"

  [ "$(crew_absorb_class task-a)" = none ] \
    || fail "a parked run with no declared pause and no open decision was wrongly classed absorbable"
  ! crew_is_paused task-a || fail "a parked run with no declared pause and no open decision was wrongly classed paused"

  unset FM_FAKE_CREW_STATE FM_STATE_OVERRIDE
  pass "crew_absorb_class: a parked run with neither signal keeps ordinary none classification and still surfaces"
}

# Disconfirming check for only ONE of the two required signals: a parked run
# with an open decision but NO declared paused: line must still surface - the
# override requires both, so a worker that opens a decision without appending
# its own pause line is unaffected (matches the run-step gate override's own
# single-signal disconfirming test above).
test_crew_absorb_class_parked_with_only_open_decision_still_surfaces() {
  local dir fakebin state
  dir=$(make_case absorb-parked-decision-only); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 1 finding(s)'
  printf 'needs-decision: run parked at the review gate on one ask-user finding\n' > "$state/task-a.status"
  fm_write_meta "$state/task-a.meta" "window=sess:fm-task-a" "backend=tmux"

  [ "$(crew_absorb_class task-a)" = none ] \
    || fail "a parked run with an open decision but no declared pause was wrongly classed absorbable"

  unset FM_FAKE_CREW_STATE FM_STATE_OVERRIDE
  pass "crew_absorb_class: a parked run with an open decision but no declared pause keeps ordinary none classification"
}

# Behavioral regression, same live incident: drives the real fm-watch.sh subprocess
# through several poll cycles (FM_POLL=1) with an unchanging pane, an orphaned
# working/run-step verdict, a declared pause, and a fake tmux reporting the
# crewmate's foreground process as a bare shell (exited). Before the fix,
# crew_absorb_class returned `working` every cycle (never latching
# .paused-<key>), so the watcher kept re-running the classify path and would
# eventually wedge-escalate instead of quietly honoring the pause cadence. Pins
# that the marker latches on first sight and the watcher stays silent across
# repeated polls of the unchanged pane.
test_nonterminal_stale_paused_orphaned_run_step_latches_marker() {
  local dir state fakebin out window key pane_hash sig pid statusf
  dir=$(make_case nonterminal-stale-orphaned-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  window="test:fm-orphaned"
  printf 'idle, holding for upstream' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nbackend=tmux\n' "$window" > "$state/orphaned.meta"
  statusf="$state/orphaned.status"
  printf 'paused: awaiting the deploy window\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-orphaned_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, holding for upstream")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Fake tmux: capture-pane/list-windows as usual, plus a display-message
  # answer reporting a bare shell foreground process - the crewmate has
  # exited, so fm_backend_agent_alive reads it as `dead`.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    exit 0 ;;
  capture-pane)
    [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && cat "$FM_FAKE_TMUX_CAPTURE"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *pane_current_command*) printf '%s\n' zsh; exit 0 ;; esac; done
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · checks green: PR ready for review (still monitoring for merge/close)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 40; then
    reap "$pid"; fail "watcher exited over several poll cycles for an exited crewmate's declared pause behind an orphaned run-step (should stay absorbed): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "an exited crewmate's declared pause behind an orphaned run-step re-surfaced within a few poll cycles instead of staying absorbed"
  [ ! -s "$state/.wake-queue" ] || fail "an exited crewmate's declared pause behind an orphaned run-step enqueued a wake instead of staying absorbed"
  [ -e "$state/.paused-$key" ] || fail "the .paused-<key> marker did not latch for an exited crewmate's declared pause behind an orphaned run-step"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused absorb must not start the wedge timer even behind an orphaned run-step"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "an exited crewmate's declared pause latches .paused-<key> behind an orphaned run-step and stays absorbed across repeated polls instead of re-nagging every cycle"
}

# Regression (2026-07-26 live incident: beamanalyzer-steel-shear-ltb PR 46,
# beamanalyzer-capacity-finder PR 47): a task whose no-mistakes run has already
# reached `done` (fm-crew-state.sh reports it, no active run-step at all) but
# whose own last status line declares a `paused:` external wait - the
# independent review firstmate requires before merge. Primes .stale-<key>
# already equal to the pane hash, so the very first real poll enters the
# per-hash guard's non-first-sight branch (bin/fm-watch.sh's Layer-1 stale
# loop) directly - the exact branch the incident report identifies. Before the
# fix, crew_absorb_class returned `none` for a done state regardless of the
# declared pause, so pause_state_class never returned `paused`, and the `*)`
# arm surfaced this stale hash on literally every poll, forever, exiting the
# watcher each time. Watch this fail against the pre-fix code: the process
# should die almost immediately with a "stale: ..." wake instead of staying
# alive across several poll cycles.
test_nonterminal_stale_paused_after_done_no_wedge_storm() {
  local dir state fakebin out window key pane_hash sig pid statusf
  dir=$(make_case nonterminal-stale-paused-after-done); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  window="test:fm-done-paused"
  printf 'idle, awaiting independent review' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nbackend=tmux\n' "$window" > "$state/done-paused.meta"
  statusf="$state/done-paused.status"
  printf 'paused: awaiting independent review before merge\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-done-paused_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, awaiting independent review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review (awaiting independent review)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 40; then
    reap "$pid"; fail "a done task's declared pause re-surfaced instead of staying absorbed across repeated polls (the wedge-storm regression): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a done task's declared pause printed a wake reason instead of staying absorbed"
  [ ! -s "$state/.wake-queue" ] || fail "a done task's declared pause enqueued a wake instead of staying absorbed"
  [ -e "$state/.paused-$key" ] || fail "the .paused-<key> marker did not latch for a done task's declared pause"
  [ ! -e "$state/.stale-since-$key" ] || fail "a done task's declared pause must not start the wedge timer"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a done task's own declared pause latches .paused-<key> and stays absorbed across repeated polls instead of re-nagging every one"
}

# Regression (2026-08 live incident: beamanalyzer-caveat-em-dashes,
# beamanalyzer-hss-pipe-catalog-reimport, beamanalyzer-verdict-scope-line-followups):
# the test above uses an unset/unreadable backend agent (liveness reads
# "unknown"), which is not what any of the three live tasks actually had - each
# was a genuinely ALIVE claude session sitting at the merge gate. Before this
# fix, bin/fm-watch.sh's pause_state_class unconditionally re-checked liveness
# even for a verdict crew_absorb_class already returned as `paused`, and
# demoted it to `none` for any agent not confirmed dead - so a done+paused task
# with a live agent NEVER latched .paused-<key> at all (handle_paused_stale,
# which sets that marker, is only reached on a `paused` verdict) and re-derived
# `none` on every single poll, forever. Each poll's own idle-pane capture also
# drifts slightly in real operation (a redrawn prompt, a blinking cursor), so
# this reproduces that churn directly instead of holding the pane byte-static,
# to prove the fix holds even when the hash itself keeps changing underneath
# it. Watch this fail against the pre-fix pause_state_class: it should die with
# a stale or possible-wedge wake well before the loop below finishes.
test_nonterminal_stale_paused_after_done_alive_agent_hash_churn_no_wedge_storm() {
  local dir state fakebin out window key sig pid statusf i
  dir=$(make_case nonterminal-stale-paused-after-done-alive-churn); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  window="test:fm-done-paused-alive"
  printf 'idle, awaiting independent review (0)' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$window" > "$state/done-paused.meta"
  statusf="$state/done-paused.status"
  printf 'paused: awaiting independent review before merge\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-done-paused_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review (still monitoring for merge/close)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 6 ]; do
    if ! is_live_non_zombie "$pid"; then
      wait "$pid"
      fail "a live done+paused agent's churning pane woke the watcher after $i churn cycles: $(cat "$out")"
    fi
    sleep 0.4
    printf 'idle, awaiting independent review (%s)' "$i" > "$dir/pane.txt"
    i=$((i + 1))
  done
  if ! wait_live "$pid" 20; then
    reap "$pid"; fail "a live done+paused agent's churning pane woke the watcher: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a live done+paused agent's churning pane printed a wake reason"
  [ ! -s "$state/.wake-queue" ] || fail "a live done+paused agent's churning pane enqueued a wake"
  [ -e "$state/.paused-$key" ] || fail "a live done+paused agent's declared pause did not latch .paused-<key>"
  [ ! -e "$state/.stale-since-$key" ] || fail "a live done+paused agent's churning pane started the wedge timer"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a done task's own declared pause stays absorbed for a genuinely alive agent across a repeatedly churning pane hash (the real live-incident mechanism)"
}

# Regression (2026-07-31 live incident: scaffold-returns-readme-currency,
# falsework-cos-deliver-to-a-human): a task whose no-mistakes run is genuinely
# PARKED at a gate (fm-crew-state.sh reports `state: parked`), with its own
# last status line declaring a `paused:` external wait and a still-open keyed
# decision. Primes .stale-<key> to the pane hash so the very first real poll
# enters the per-hash guard's non-first-sight branch directly. Before the fix,
# crew_absorb_class returned `none` for a parked state regardless of the
# declared pause and open decision, so pause_state_class never returned
# `paused`, and the watcher re-surfaced this stale hash on literally every
# poll, forever, exiting the watcher each time. Confirms the library fix
# actually latches through fm-watch.sh's own pause_state_class, not just in
# isolation.
test_nonterminal_stale_paused_at_parked_gate_no_wedge_storm() {
  local dir state fakebin out window key pane_hash sig pid statusf
  dir=$(make_case nonterminal-stale-paused-at-parked-gate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  window="test:fm-parked-gate"
  printf 'idle, parked at the review gate' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nbackend=tmux\n' "$window" > "$state/parked-gate.meta"
  statusf="$state/parked-gate.status"
  {
    printf 'needs-decision: run parked at the review gate on one ask-user finding\n'
    printf 'paused: parked at the review gate awaiting the captain decision\n'
  } > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-parked-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, parked at the review gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 1 finding(s) (ask-user: authority decision)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 40; then
    reap "$pid"; fail "a parked task's declared pause at an open gate re-surfaced instead of staying absorbed across repeated polls (the wedge-storm regression): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a parked task's declared pause at an open gate printed a wake reason instead of staying absorbed"
  [ ! -s "$state/.wake-queue" ] || fail "a parked task's declared pause at an open gate enqueued a wake instead of staying absorbed"
  [ -e "$state/.paused-$key" ] || fail "the .paused-<key> marker did not latch for a parked task's declared pause at an open gate"
  [ ! -e "$state/.stale-since-$key" ] || fail "a parked task's declared pause at an open gate must not start the wedge timer"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a parked task's own declared pause at a still-open gate latches .paused-<key> and stays absorbed across repeated polls instead of re-nagging every one"
}

# Regression: FM_CREW_STATE_NM_TIMEOUT=0 previously slipped past its sanitizer
# and reached `timeout` as a literal 0, which GNU coreutils treats as "disable
# the timeout" - the exact failure mode this outer bound exists to guarantee
# against. FM_CREW_ABSORB_TIMEOUT/FM_CREW_ABSORB_KILL_AFTER use the identical
# exclusion pattern (bin/fm-classify-lib.sh), so pin that a literal 0 for either
# one also falls back to its sanitized default rather than reaching
# fm_hard_timeout unbounded. Re-sources the library after setting the env vars
# so the sanitizer's case statement actually re-evaluates them.
test_absorb_zero_env_values_sanitized_to_default() {
  local out
  out=$(FM_CREW_ABSORB_TIMEOUT=0 FM_CREW_ABSORB_KILL_AFTER=0 bash -c \
    ". \"$ROOT/bin/fm-classify-lib.sh\"; printf 'timeout=%s kill_after=%s\n' \"\$FM_CREW_ABSORB_TIMEOUT\" \"\$FM_CREW_ABSORB_KILL_AFTER\"")
  assert_not_contains "$out" "timeout=0 " "FM_CREW_ABSORB_TIMEOUT=0 was not sanitized away from a literal 0 (disables the outer hard-timeout bound)"
  assert_not_contains "$out" "kill_after=0" "FM_CREW_ABSORB_KILL_AFTER=0 was not sanitized away from a literal 0"
  assert_contains "$out" "timeout=45 kill_after=5" "FM_CREW_ABSORB_TIMEOUT/KILL_AFTER=0 fall back to their sanitized defaults (45/5)"
  pass "FM_CREW_ABSORB_TIMEOUT=0 and FM_CREW_ABSORB_KILL_AFTER=0 fall back to sanitized defaults, never a literal 0"
}

# Regression: the exclusion pattern above only caught the literal string "0",
# not other all-zero digit spellings GNU `timeout` also treats as "no
# timeout" - verified empirically, `timeout -k 1 00 sleep N` runs the full N
# seconds, identical to a literal 0. Pins that FM_CREW_ABSORB_TIMEOUT=00 and
# FM_CREW_ABSORB_KILL_AFTER=00 also fall back to their sanitized defaults.
test_absorb_zero_padded_env_values_sanitized_to_default() {
  local out
  out=$(FM_CREW_ABSORB_TIMEOUT=00 FM_CREW_ABSORB_KILL_AFTER=00 bash -c \
    ". \"$ROOT/bin/fm-classify-lib.sh\"; printf 'timeout=%s kill_after=%s\n' \"\$FM_CREW_ABSORB_TIMEOUT\" \"\$FM_CREW_ABSORB_KILL_AFTER\"")
  assert_not_contains "$out" "timeout=00 " "FM_CREW_ABSORB_TIMEOUT=00 was not sanitized away from a zero-padded 0 (disables the outer hard-timeout bound)"
  assert_not_contains "$out" "kill_after=00" "FM_CREW_ABSORB_KILL_AFTER=00 was not sanitized away from a zero-padded 0"
  assert_contains "$out" "timeout=45 kill_after=5" "FM_CREW_ABSORB_TIMEOUT/KILL_AFTER=00 fall back to their sanitized defaults (45/5)"
  pass "FM_CREW_ABSORB_TIMEOUT=00 and FM_CREW_ABSORB_KILL_AFTER=00 fall back to sanitized defaults, never a zero-padded 0"
}

# signal_crew_provably_working: a no-verb "signal:" wake is benign ONLY when EVERY
# task it references is provably working; if any crew has stopped, or no task can be
# resolved, it surfaces. Files map to ids by stripping .status / .turn-ended.
test_signal_crew_provably_working_classifier() {
  local dir fakebin state
  dir=$(make_case signal-provably-working); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE_a='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_b='state: done · source: run-step · run passed'
  signal_crew_provably_working "$state/a.status" "$state/a.turn-ended" \
    || fail "a single provably-working crew (status+turn-end) was not benign"
  ! signal_crew_provably_working "$state/a.status" "$state/b.turn-ended" \
    || fail "a coalesced batch including a stopped crew was treated as benign"
  ! signal_crew_provably_working "$state/b.turn-ended" \
    || fail "a stopped crew's bare turn-end was treated as benign"
  ! signal_crew_provably_working "$state/a.meta" \
    || fail "a non-signal file resolved to a benign verdict"
  ! signal_crew_provably_working \
    || fail "an empty signal file list was treated as benign"
  unset FM_FAKE_CREW_STATE_a FM_FAKE_CREW_STATE_b
  pass "signal_crew_provably_working: benign only when every referenced crew is provably working"
}

# --- benign wakes are absorbed ONLY when the crew is provably working ---------

test_provably_working_signal_absorbed() {
  local dir state fakebin out status_file pid
  dir=$(make_case provably-working-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # The crew's pipeline is in an actively-running step: positive evidence it is
  # still working, so a no-verb working: signal is absorbed (the original low-churn
  # case during a long validation).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a working: signal whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working signal printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working signal enqueued a durable wake record"
  [ -s "$state/.seen-task_status" ] || fail "provably-working signal did not advance its .seen-* suppressor"
  [ -e "$state/.last-watcher-beat" ] || fail "watcher beacon was not touched while absorbing"
  reap "$pid"
  pass "a no-verb signal whose crew is provably working is absorbed (no exit, no queue, suppressor advanced, beacon present)"
}

test_turn_ended_provably_working_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case turn-ended-working); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  : > "$state/task.turn-ended"
  # A busy pane is the second form of positive evidence (covers a queued
  # continuation right after the turn-end).
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a turn-end whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working turn-end printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working turn-end enqueued a durable wake record"
  reap "$pid"
  pass "a bare turn-end whose crew is provably working (busy pane) is absorbed"
}

# --- a no-verb signal whose crew is NOT provably working SURFACES -------------
# This is the swallowed-finish fix: a crew that finished (or stopped and waits)
# reports its final turn-end with no captain-relevant status and no running
# pipeline, so the wake must surface instead of being absorbed.

test_turn_ended_not_working_surfaced() {
  local dir state fakebin out drain_out pid
  dir=$(make_case turn-ended-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  : > "$state/task.turn-ended"
  # No running pipeline, no busy pane: the crew has stopped (e.g. it finished via
  # an interactive menu and wrote no done: status). Default unknown verdict.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a turn-end whose crew is not provably working"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "watcher did not print the surfaced turn-end signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.turn-ended" >/dev/null || fail "surfaced turn-end was not queued"
  pass "a bare turn-end whose crew is not provably working is surfaced (the swallowed-finish fix)"
}

test_working_note_not_working_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case working-note-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # A non-no-mistakes crew (no run) whose pane went idle: fm-crew-state falls back
  # to the stale working: status-log line. That is NOT positive evidence, so the
  # wake must surface - these users must never be left hanging.
  export FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling step 2'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a working: note whose crew has no running pipeline and an idle pane"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the surfaced working: signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced working: note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "surfaced working: note was not queued"
  [ -s "$state/.seen-task_status" ] || fail "surfaced working: note did not advance its .seen-* suppressor"
  pass "a no-verb working: note whose crew is idle with no running pipeline is surfaced"
}

# Regression for the 2026-07-09 89-minute watcher stall: crew_absorb_class's
# read (which stands in for a real crew whose `no-mistakes axi status` call is
# stuck behind a busy shared daemon) hangs past its own signal - a fake
# fm-crew-state.sh that traps and ignores TERM, exactly like the real CLI can
# under concurrent validation load. Before the outer hard-timeout
# (bin/fm-classify-lib.sh's fm_hard_timeout, wrapping crew_absorb_class's call)
# this blocked the watcher's poll loop indefinitely, so its liveness beacon
# went stale for the incident's full 89 minutes. With the fix, the read is
# force-killed and reads as "none" (not provably working) - fail toward the
# safe side, never a false "working" - so the wake correctly surfaces rather
# than hanging or being silently absorbed. Asserting the watcher exits within a
# small bound (not the 40-tick/4s default used elsewhere, but still orders of
# magnitude under an unbounded hang) is the direct proof: pre-fix this hangs
# past the bound and the assertion fails instead of passing.
test_hung_crew_state_read_does_not_stall_watcher() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case hung-crew-state-read); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # Overwrite make_case's default (instant, canned-verdict) fake fm-crew-state.sh
  # with one that never answers on its own - it must be force-killed.
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
while :; do sleep 1; done
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  export FM_CREW_ABSORB_TIMEOUT=2 FM_CREW_ABSORB_KILL_AFTER=1
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 80 || fail "watcher did not resolve a hung crew-state read within a small bound (would hang indefinitely pre-fix)"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not surface the signal once the hung read was force-killed"
  [ -e "$state/.last-watcher-beat" ] || fail "watcher beacon was never touched"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the hung-read surface failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "hung-read surface was not queued"
  unset FM_CREW_ABSORB_TIMEOUT FM_CREW_ABSORB_KILL_AFTER
  pass "a hung crew-state read is force-killed and correctly surfaces instead of stalling the watcher's poll loop"
}

test_hung_no_mistakes_status_does_not_freeze_watcher_beacon() {
  local dir state fakebin out status_file calls_file wt pid beat1 beat2
  dir=$(make_case hung-no-mistakes-status); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/task.status"; calls_file="$dir/no-mistakes.calls"; wt="$dir/wt"
  mkdir -p "$wt"
  git -C "$wt" init -q
  git -C "$wt" commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b fm/hung-no-mistakes-status
  : > "$calls_file"
  printf 'working: compiling step 2\n' > "$status_file"
  fm_write_meta "$state/task.meta" "window=fm:fm-task" "worktree=$wt" "kind=ship" "harness=claude"
  # The semantic busy-state redesign (bin/fm-busy-lib.sh) retired rendered
  # pane-text scraping for a converted adapter like claude: a busy verdict
  # now comes only from the crew's own semantic lifecycle record, so a busy
  # pane must be armed through the real writer exactly like
  # tests/fm-crew-state.test.sh's test_no_run_busy_pane does.
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" task)
  "$ROOT/bin/fm-busy-event.sh" apply "$state" task busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        trap '' TERM
        printf '%s\n' "$*" >> "${FM_FAKE_NM_CALLS:-/dev/null}"
        while :; do sleep 1; done ;;
    esac ;;
esac
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    printf '%%1\n'
    exit 0 ;;
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    exit 0 ;;
  capture-pane)
    printf 'work in progress\nesc to interrupt\n'
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" \
    FM_FAKE_NM_CALLS="$calls_file" FM_CREW_STATE_NM_TIMEOUT=1 FM_CREW_STATE_NM_KILL_AFTER=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_path_exists "$state/.last-watcher-beat" 30 || { reap "$pid"; fail "watcher beacon was never touched"; }
  beat1=$(file_mtime "$state/.last-watcher-beat")
  wait_mtime_after "$state/.last-watcher-beat" "$beat1" 90 \
    || { reap "$pid"; fail "watcher beacon did not advance after a hung no-mistakes status timed out"; }
  beat2=$(file_mtime "$state/.last-watcher-beat")
  kill -0 "$pid" 2>/dev/null || fail "watcher exited instead of absorbing the no-verb signal after no-mistakes timed out"
  [ ! -s "$out" ] || { reap "$pid"; fail "watcher printed a wake reason after the bounded no-mistakes timeout: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "watcher enqueued a wake instead of continuing after the bounded no-mistakes timeout"; }
  [ -s "$state/.seen-task_status" ] || { reap "$pid"; fail "watcher did not advance the signal suppressor after bounded no-mistakes timeout"; }
  grep -F "status" "$calls_file" >/dev/null || { reap "$pid"; fail "fake no-mistakes axi status was never called"; }
  [ "$beat2" -gt "$beat1" ] || { reap "$pid"; fail "watcher beacon mtime did not increase"; }
  reap "$pid"
  pass "a hung no-mistakes axi status is force-killed and the watcher beacon keeps advancing"
}

# --- actionable wakes are surfaced (queue + exit) ---------------------------

test_actionable_signal_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case actionable-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the actionable signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "actionable signal was not queued"
  [ -s "$state/.hb-surfaced-task" ] || fail "actionable signal did not record the surfaced marker"
  pass "captain-relevant signal is surfaced (queue + exit) and marked surfaced"
}

test_terminal_stale_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-done"
  printf 'finished, awaiting review' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/done.meta"
  printf 'done: PR https://example.test/pr/3\n' > "$state/done.status"
  sig=$(seen_sig "$state/done.status"); printf '%s' "$sig" > "$state/.seen-done_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "finished, awaiting review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for a stale pane on a terminal status"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the terminal stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the terminal stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "terminal stale was not queued"
  pass "a stale pane sitting on a terminal status is surfaced (queue + exit)"
}

# --- stale pane, STALE terminal status overridden by an active run: absorbed ---
# Regression for the 2026-07 herdr false-surface incidents: a crew's own status
# log gets no new entry once firstmate hands it to a no-mistakes validation
# (AGENTS.md's sparse status-reporting contract), so the log keeps showing its
# pre-validation "done:" line as the LAST line for the run's entire (possibly
# many-minutes) duration. stale_is_terminal alone has no run-step awareness and
# would treat that leftover as still-current every time the pane goes quiet,
# immediately surfacing a crew that is actively validating. crew_is_provably_working
# must get a chance to override a captain-relevant-but-stale status line, exactly
# as it already does for a plain non-terminal one.
test_stale_terminal_status_overridden_by_active_run() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-overridden); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-validating"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/validating.meta"
  # The crew reported done BEFORE firstmate triggered no-mistakes validation;
  # this line never gets superseded by a newer status-log entry while the
  # pipeline itself runs.
  printf 'done: implementation complete, ready to validate\n' > "$state/validating.status"
  sig=$(seen_sig "$state/validating.status"); printf '%s' "$sig" > "$state/.seen-validating_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: a high escalation threshold means the first sighting is absorbed,
  # not surfaced, despite the captain-relevant "done:" status-log line.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a stale terminal-looking status the run-step overrides (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the overridden stale terminal status printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "the overridden stale terminal status enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  [ ! -e "$state/.hb-surfaced-validating" ] || fail "an absorbed wake must not mark the status line as surfaced"
  reap "$pid"

  # Phase B: backdate the idle timer past the threshold; the run genuinely
  # wedges and the next poll escalates exactly like the non-terminal case.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not escalate an overridden stale terminal status past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  unset FM_FAKE_CREW_STATE
  pass "a stale terminal-looking status is overridden and absorbed while a run is actively working, then wedge-escalated"
}

# --- non-terminal stale, crew provably working: absorbed, then wedge-escalated ---
# A provably-working crew (an actively-running pipeline) legitimately sits on a
# static pane (e.g. waiting on CI), so a non-terminal stale is absorbed and only
# the wedge timer eventually escalates it - the low-churn behavior preserved.

test_nonterminal_stale_provably_working_absorbed_then_escalated() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet.meta"
  # Non-terminal status, and prime .seen-* so the signal scan does not pre-empt
  # the stale path.
  printf 'working: still compiling\n' > "$state/quiet.status"
  sig=$(seen_sig "$state/quiet.status"); printf '%s' "$sig" > "$state/.seen-quiet_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Phase A: a high escalation threshold means the first sighting is absorbed.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a fresh provably-working non-terminal stale (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh provably-working stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh provably-working stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  reap "$pid"

  # Phase B: backdate the idle timer past the threshold; the next run escalates.
  # (The subsequent-sight timer path does not re-read the crew state.)
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not escalate a provably-working non-terminal stale past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer was not cleared after escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the wedge escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "wedge escalation was not queued"
  pass "provably-working non-terminal stale is absorbed on first sight, then wedge-escalated past the threshold"
}

# --- non-terminal stale, crew NOT provably working: surfaced immediately ------
# The key requirement: a crew with no running pipeline that has gone quiet (and is
# not busy) has stopped - it may be done via interactive menus, waiting, or wedged.
# It must surface at once, never wait out the wedge timer, so these users (a
# non-no-mistakes crew, or any crew with no running pipeline) are never left hanging.

test_nonterminal_stale_not_working_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (the crew never wrote a captain-relevant verb), .seen-*
  # primed so the signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  sig=$(seen_sig "$state/stopped.status"); printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No running pipeline; the pane is idle. NOT provably working.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # Even with a high wedge threshold, a not-provably-working stale surfaces at once.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a not-provably-working non-terminal stale at once"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  grep -F "possible wedge" "$out" >/dev/null && fail "an immediate stopped-crew stale was mislabeled a wedge"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced on surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer should not be set when surfacing immediately"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the immediate stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  pass "a not-provably-working non-terminal stale is surfaced immediately (never left to wait out the timer)"
}

# --- non-terminal stale, crew DECLARED a pause: absorbed, re-surfaced on a long
#     cadence, never wedge-escalated ------------------------------------------
# The live 2026-07-09/10 case: a crew intentionally held awaiting an upstream tool
# release (paused: ...) whose idle pane tripped repeated possible-wedge escalations
# all day. With the paused verb, its stale is absorbed like a working crew but never
# uses the wedge timer; it re-surfaces once past PAUSE_RESURFACE_SECS (anchored on
# the pause's own status-file age, so a churny idle pane cannot reset the cadence)
# for a recheck, so a forgotten pause cannot rot invisibly.
test_nonterminal_stale_paused_absorbed_then_resurfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back statusf
  dir=$(make_case nonterminal-stale-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-held"
  printf 'idle, holding for upstream' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/held.meta"
  statusf="$state/held.status"
  # A DECLARED pause (not captain-relevant), .seen-* primed so the signal scan does
  # not pre-empt the stale path.
  printf 'paused: holding for the upstream tool release\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, holding for upstream")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # crew_absorb_class reads the declared pause from fm-crew-state.sh.
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'

  # Phase A: a fresh pause (status file just written) under a high re-surface
  # threshold is absorbed - no wake, no wedge timer.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a fresh declared pause (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh paused stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh paused stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on paused absorb"
  [ -e "$state/.paused-$key" ] || fail "paused flag not recorded on absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused absorb must not start the wedge timer"
  reap "$pid"

  # Phase B: age the pause past the (now normal) threshold by backdating its
  # status file, re-prime .seen-* to the new signature so the signal scan stays
  # quiet, and confirm it re-surfaces as a paused recheck - never a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  : > "$out"
  printf 'idle, holding for upstream (token 2)' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-surface a declared pause past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "re-surface did not print a stale wake"
  grep -F "awaiting external" "$out" >/dev/null || fail "re-surface was not labeled a paused/awaiting-external recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause was mislabeled a possible wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the paused re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused re-surface must not use the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the paused re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "paused re-surface was not queued"
  pass "a declared pause is absorbed on first sight, then re-surfaced as a recheck past the threshold, never wedge-escalated"
}

# A captain-held crew can leave a stable backend endpoint after its agent exits.
# fm-crew-state then authoritatively reports stopped rather than paused, but the
# confirmed-dead agent plus the declared wait or captain-held transfer must retain
# bounded pause handling.
# A still-live agent directly classified paused by crew_absorb_class gets the SAME
# bounded cadence, not a special immediate surface: the status-log write that
# declared the pause already woke firstmate once through the ordinary signal path
# (unrelated to this stale-pane cadence), so a second immediate surface here was
# pure duplication - and keying that duplicate to "first sight of this exact pane
# hash" repeated it every time an idle pane's captured tail drifted, which is the
# every-few-minutes false wedge alarm fixed in bin/fm-watch.sh's pause_state_class
# (regression: beamanalyzer-caveat-em-dashes and siblings, done + declared-paused
# with a live agent, re-alarming on every sweep before this fix).
test_exited_declared_pause_and_live_gate_share_bounded_cadence() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back round wakes bare
  dir=$(make_case exited-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after agent exit\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'paused: held per captain while an external decision is pending\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after agent exit")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  round=1
  while [ "$round" -le 6 ]; do
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    if wait_live "$pid" 15; then reap "$pid"; else wait "$pid" || fail "dead-agent watcher round $round failed"; fi
    round=$((round + 1))
  done
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue")
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$wakes" -le 1 ] || fail "dead-agent declared pause flooded $wakes stale wakes across six unchanged polls"
  [ "$bare" -eq 0 ] || fail "dead-agent declared pause surfaced as $bare bare stopped-crew wakes"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "dead-agent declared pause did not use the bounded paused recheck"

  dir=$(make_case exited-captain-held); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after captain-held transfer\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'captain-held [key=route]: tracked by held-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after captain-held transfer")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "captain-held dead-agent pane did not re-surface on the bounded cadence"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "captain-held dead-agent pane surfaced as a stopped crew"

  dir=$(make_case alive-decision-gate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/gate.status"
  window="test:fm-gate"
  printf 'idle external-decision gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/gate.meta"
  printf 'paused: waiting at an active external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle external-decision gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # First sight of a fresh, live, directly-paused crew is absorbed exactly like
  # a dead one above - no special immediate surface. The status-log write that
  # declared this pause already woke firstmate once through the ordinary signal
  # path, so a second immediate wake here would be pure duplication.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"
    fail "a fresh live declared pause surfaced instead of absorbing on first sight: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a fresh live declared pause printed a wake reason during absorb"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a fresh live declared pause enqueued a wake during absorb"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "a fresh live declared pause did not latch the pause marker"; }
  reap "$pid"

  # Age the pause past the threshold: it must still re-surface as a bounded
  # recheck, exactly like the dead-agent case above - a live agent's pause is
  # not silenced forever either.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a live declared pause past the threshold did not re-surface on the bounded cadence"
  grep -F "awaiting external" "$out" >/dev/null || fail "a live declared pause recheck was not labeled awaiting-external"
  grep -F "possible wedge" "$out" >/dev/null && fail "a live declared pause recheck was mislabeled a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "a live declared pause recheck retained a wedge timer"

  # Simulate a churning pane hash on the SAME still-paused crew (a redrawn
  # timestamp, a cursor blink) - the exact live mechanism behind the fixed
  # incident: repeated "first sight" of a drifting pane hash must not repeatedly
  # wake firstmate just because the terminal capture differs byte-for-byte.
  printf 'idle external-decision gate (redrawn)\n' > "$capture_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"
    fail "a churned pane hash on an unchanged declared pause re-surfaced instead of absorbing: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a churned pane hash on an unchanged declared pause printed a wake reason"; }
  reap "$pid"
  pass "exited declared-pause, captain-held, and a live decision gate all share the same bounded pause cadence, including across a churning pane hash"
}

test_secondmate_paused_resurfaces_in_normal_mode() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case secondmate-paused-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-held.status"
  window="test:fm-secondmate-held"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-held.meta"
  printf 'paused: awaiting the upstream release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-held_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-surface a paused secondmate"
  grep -F "stale: $window" "$out" >/dev/null || fail "paused secondmate did not emit a stale recheck"
  grep -F "awaiting external" "$out" >/dev/null || fail "paused secondmate recheck omitted its external-wait reason"
  grep -F "possible wedge" "$out" >/dev/null && fail "paused secondmate was mislabeled a wedge"
  unset FM_FAKE_CREW_STATE
  pass "a declared paused secondmate re-surfaces on the bounded normal-mode cadence"
}

test_secondmate_nonpaused_stale_remains_suppressed() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid
  dir=$(make_case secondmate-stale-suppressed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-working.status"
  window="test:fm-secondmate-working"
  printf 'idle while the parent supervises\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-working.meta"
  printf 'working: the parent supervises this secondmate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-working_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle while the parent supervises")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher surfaced an ordinary secondmate stale pane: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "ordinary secondmate stale pane printed a wake reason: $(cat "$out")"; }
  reap "$pid"
  pass "a non-paused secondmate retains normal stale suppression"
}

test_secondmate_unpause_clears_pause_tracking() {
  local dir state fakebin out statusf window key pid
  dir=$(make_case secondmate-unpause-clears); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; statusf="$state/secondmate-resumed.status"; window="test:fm-secondmate-resumed"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-resumed.meta"
  printf 'working: upstream landed\n' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-secondmate-resumed_status"
  key=${window//:/_}
  key=${key//\//_}
  key=${key//./_}
  : > "$state/.paused-$key"
  : > "$state/.paused-rechecked-$key"
  : > "$state/.paused-resurfaced-$key"
  : > "$state/.stale-$key"
  : > "$state/.stale-since-$key"
  : > "$state/.wedge-escalations-$key"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 20 || fail "watcher exited while reconciling a resumed secondmate: $(cat "$out")"
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "resumed secondmate retained the pause marker"; }
  [ ! -e "$state/.stale-$key" ] || { reap "$pid"; fail "resumed secondmate retained stale tracking"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "resumed secondmate retained wedge tracking"; }
  reap "$pid"
  pass "a resumed secondmate clears pause and stale tracking before stale exemption"
}

test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash() {
  local dir state fakebin out capture_file window key pane_hash sig pid i
  dir=$(make_case nonterminal-stale-pause-transition); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-transition"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/transition.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ -e "$state/.paused-$key" ] && [ ! -e "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash did not enter paused mode"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "pause transition retained its wedge timer"; }
  wait_live "$pid" 30 || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  reap "$pid"

  printf 'working: upstream landed, resuming\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ ! -e "$state/.paused-$key" ] && [ -s "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash retained paused mode after resume"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "unchanged stale hash did not restart wedge tracking after resume"; }
  wait_live "$pid" 30 || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "unchanged stale hashes reclassify when a crew enters or leaves pause"
}

test_nonterminal_paused_rechecks_authoritative_state() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-paused-recheck); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-pause-recheck"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/pause-recheck.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/pause-recheck.status"
  sig=$(seen_sig "$state/pause-recheck.status"); printf '%s' "$sig" > "$state/.seen-pause-recheck_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "an active run behind a declared pause surfaced instead of resuming wedge tracking: $(cat "$out")"
  fi
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "authoritative active run retained paused mode"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "authoritative active run did not resume wedge tracking"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause is periodically rechecked against authoritative active-run state"
}

test_paused_authoritative_working_preserves_wedge_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case paused-working-preserves-wedge-timer); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-working"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/paused-working.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/paused-working.status"
  sig=$(seen_sig "$state/paused-working.status"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "authoritative working state did not start wedge tracking"; }
  since=$(cat "$state/.stale-since-$key")
  sleep 2
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || true)" = "$since" ] \
    || { reap "$pid"; fail "repeat authoritative working recheck reset the wedge timer"; }
  reap "$pid"

  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "authoritative working state did not wedge-escalate past the threshold"
  grep -F "possible wedge" "$out" >/dev/null || fail "authoritative working wedge escalation omitted its reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "wedge timer remained after authoritative working escalation"
  unset FM_FAKE_CREW_STATE
  pass "a paused status overridden by authoritative working preserves its wedge timer and escalates"
}

# --- consecutive wedge escalations on the same pane demand deep inspection ----
# Root cause of the PR #252 incident's ~20 minutes of unnoticed green: each
# wedge escalation fires, gets classified as "still validating" one poll later
# (the timer restarts, see wedge_timer_check), and repeats forever on a pane
# that never changes. A single escalation reason looks identical every round,
# so nothing in the payload itself signals "this has now happened N times in a
# row" - that judgment call was left entirely to the supervisor noticing the
# repetition on its own. This is the safety-net fix: past
# FM_WEDGE_DEMAND_INSPECT_COUNT consecutive escalations on the SAME pane, the
# wake reason itself carries a "demand-deep-inspection" marker.

test_wedge_escalation_marks_demand_deep_inspection_after_threshold() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case wedge-escalation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged.status"
  sig=$(seen_sig "$state/wedged.status"); printf '%s' "$sig" > "$state/.seen-wedged_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: first sighting of this stale hash classifies and absorbs it
  # (establishing .stale-$key and starting the wedge timer) without going
  # through wedge_timer_check at all - mirrors the existing wedge tests' Phase A.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited on the priming round (should absorb): $(cat "$out")"
  fi
  reap "$pid"

  n=1
  while [ "$n" -le 3 ]; do
    # Backdate the wedge timer past the threshold before each round, mirroring
    # the existing wedge-escalation tests' Phase B (the subsequent-sight timer
    # path does not re-read the crew state).
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 40 || fail "watcher did not escalate on consecutive wedge round $n: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "escalation counter did not persist across consecutive rounds"
  unset FM_FAKE_CREW_STATE
  pass "consecutive wedge escalations on the same pane accumulate and demand deep inspection at the threshold"
}

test_wedge_escalation_resets_when_pane_becomes_active() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case wedge-escalation-reset); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged-reset"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged-reset.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged-reset.status"
  sig=$(seen_sig "$state/wedged-reset.status"); printf '%s' "$sig" > "$state/.seen-wedged-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Pre-seed one escalation as if a prior wedge round already fired.
  printf '1\n' > "$state/.wedge-escalations-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # The pane content changes (the crew is active again): the hash no longer
  # matches, so the watcher resets escalation bookkeeping instead of escalating.
  printf 'new output, crew active again' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited on a fresh (changed) pane hash: $(cat "$out")"
  fi
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a changed pane hash did not reset the wedge-escalation counter"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a pane becoming active again resets the consecutive wedge-escalation counter"
}

# --- busy pane duration bound: a completed-turn age gate on top of busy -----
# 2026-07 hibit-agent-focus-nonsteal-r1 incident: a busy pane (herdr "working"
# and/or the harness's rendered busy footer) is unconditional, unbounded proof
# of liveness in every existing classifier, so a genuinely hung foreground tool
# call behind a busy signature ran undetected for 25h. BUSY_TURN_MAX_SECS bounds
# how long a busy pane may run with no completed turn (state/<id>.turn-ended, or
# the task's spawn record before any turn completes); past the bound the SAME
# wedge_timer_check already used for a provably-working non-busy stale takes
# over, so escalation reuses the identical stale reason, escalation counter, and
# demand-deep-inspection marker - never an automatic interrupt or restart.

test_busy_pane_below_turn_age_bound_is_absorbed() {
  local dir state fakebin out capture_file window key sig pid
  dir=$(make_case busy-below-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-fresh"
  printf 'Working... (12.3s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-fresh.meta"
  record_pi_busy "$state" busy-fresh
  printf 'working: setup complete\n' > "$state/busy-fresh.status"
  sig=$(seen_sig "$state/busy-fresh.status"); printf '%s' "$sig" > "$state/.seen-busy-fresh_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch "$state/busy-fresh.turn-ended"
  prime_turnend_seen "$state/busy-fresh.turn-ended"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=999 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a busy pane below the turn-age bound was escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a busy pane below the turn-age bound printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a busy pane below the turn-age bound started a wedge timer"
  reap "$pid"
  pass "a busy worker below the turn-age bound remains working with no escalation"
}

test_busy_pane_stable_hash_escalates_past_turn_age_bound() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-stable-hash-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-stable"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-stable.meta"
  record_pi_busy "$state" busy-stable
  printf 'working: setup complete\n' > "$state/busy-stable.status"
  sig=$(seen_sig "$state/busy-stable.status"); printf '%s' "$sig" > "$state/.seen-busy-stable_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No completed turn ever recorded for this task: age the spawn record itself.
  touch -t 200001010000 "$state/busy-stable.meta"

  # Phase A: past the bound, the stable-hash busy pane is absorbed but starts
  # the wedge timer (mirrors the existing provably-working-stale Phase A/B).
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a stable-hash busy pane past the turn-age bound escalated before the wedge threshold: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a stable-hash busy pane past the turn-age bound did not start a wedge timer"
  reap "$pid"

  # Phase B: backdate the wedge timer past the threshold; the next poll escalates.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a stable-hash busy pane did not wedge-escalate past the turn-age bound"
  grep -F "stale: $window" "$out" >/dev/null || fail "busy turn-age escalation did not print the stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "busy turn-age escalation did not flag a possible wedge"
  pass "a busy worker with a stable pane hash still escalates once its completed-turn age reaches the bound"
}

# Regression fixture for the incident's actual masking condition: Pi's rendered
# elapsed-time footer changes every poll, so the pane hash never repeats and the
# watcher always takes the "new hash" branch, never the stable-hash one above.
test_busy_pane_changing_hash_escalates_past_turn_age_bound() {
  local dir state fakebin out capture_file window key pid
  dir=$(make_case busy-changing-hash-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-ticking"
  printf 'Working... (3600.1s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-ticking.meta"
  record_pi_busy "$state" busy-ticking
  printf 'working: setup complete\n' > "$state/busy-ticking.status"
  sig=$(seen_sig "$state/busy-ticking.status"); printf '%s' "$sig" > "$state/.seen-busy-ticking_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch -t 200001010000 "$state/busy-ticking.meta"
  # No pre-seeded .hash-<key>: with a real ticking elapsed footer, every poll
  # lands here (h != prev) - the reproduction's actual masking condition.

  # Phase A: first sight past the bound absorbs and starts the wedge timer,
  # without ever needing the "genuinely stale" hash-match path.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a changing-hash busy pane past the turn-age bound escalated before the wedge threshold: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a changing-hash busy pane past the turn-age bound did not start a wedge timer"
  reap "$pid"

  # Phase B: another tick (still a fresh, never-before-seen hash) plus a
  # backdated wedge timer escalates exactly as the stable-hash case does.
  printf 'Working... (3601.2s)' > "$capture_file"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a changing-hash busy pane did not wedge-escalate past the turn-age bound"
  grep -F "stale: $window" "$out" >/dev/null || fail "busy turn-age escalation (changing hash) did not print the stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "busy turn-age escalation (changing hash) did not flag a possible wedge"
  pass "a busy worker whose pane hash changes every poll still escalates once its completed-turn age reaches the bound"
}

test_busy_pane_turn_end_touch_resets_age() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-turn-end-resets-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-reset"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-reset.meta"
  record_pi_busy "$state" busy-reset
  printf 'working: setup complete\n' > "$state/busy-reset.status"
  sig=$(seen_sig "$state/busy-reset.status"); printf '%s' "$sig" > "$state/.seen-busy-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # A wedge is already mid-escalation, as if several over-age polls already ran.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '1\n' > "$state/.wedge-escalations-$key"
  # The worker's most recent turn just completed: touching turn-ended resets age.
  touch "$state/busy-reset.turn-ended"
  prime_turnend_seen "$state/busy-reset.turn-ended"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=3600 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a freshly completed turn on a busy pane was still escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a freshly completed turn on a busy pane printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a freshly completed turn did not clear the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a freshly completed turn did not clear the escalation counter"
  reap "$pid"
  pass "touching a busy worker's completed-turn marker resets the age and prevents an old-age escalation"
}

test_busy_pane_repeated_escalation_reaches_demand_deep_inspection() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case busy-turn-age-demand-inspect); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-demand-inspect"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-demand.meta"
  record_pi_busy "$state" busy-demand
  printf 'working: setup complete\n' > "$state/busy-demand.status"
  sig=$(seen_sig "$state/busy-demand.status"); printf '%s' "$sig" > "$state/.seen-busy-demand_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  touch -t 200001010000 "$state/busy-demand.turn-ended"
  prime_turnend_seen "$state/busy-demand.turn-ended"

  # Priming round: first sighting past the turn-age bound absorbs and starts
  # the wedge timer, mirroring the existing provably-working wedge tests.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "priming round for busy turn-age escalation was not absorbed: $(cat "$out")"
  fi
  reap "$pid"

  n=1
  while [ "$n" -le 3 ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 40 || fail "busy turn-age escalation round $n did not escalate: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "busy turn-age round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "busy turn-age round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "busy turn-age round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "busy turn-age escalation counter did not persist across consecutive rounds"
  pass "repeated busy turn-age escalations reuse the existing escalation counter and demand deep inspection at the threshold"
}

# Behavioral proof that the production default (no FM_BUSY_TURN_MAX_SECS override
# anywhere in this env) is 3600s: a completed turn 5 minutes old must not start a
# wedge timer, while one 66 minutes old must - bracketing the default around 3600
# without waiting a literal hour.
test_busy_pane_default_turn_age_bound_is_3600s() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-default-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-default"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-default.meta"
  record_pi_busy "$state" busy-default
  printf 'working: setup complete\n' > "$state/busy-default.status"
  sig=$(seen_sig "$state/busy-default.status"); printf '%s' "$sig" > "$state/.seen-busy-default_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  set_mtime $(( $(date +%s) - 300 )) "$state/busy-default.turn-ended"
  prime_turnend_seen "$state/busy-default.turn-ended"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a 5-minute-old completed turn tripped the default busy-turn-age bound: $(cat "$out")"
  fi
  [ ! -e "$state/.stale-since-$key" ] || fail "a 5-minute-old completed turn started a wedge timer under the default bound"
  reap "$pid"

  set_mtime $(( $(date +%s) - 4000 )) "$state/busy-default.turn-ended"
  prime_turnend_seen "$state/busy-default.turn-ended"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a 66-minute-old completed turn escalated before the wedge threshold under the default bound: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a 66-minute-old completed turn did not start a wedge timer under the default bound (default is not 3600s)"
  reap "$pid"
  pass "the production default busy-turn-age bound is 3600s (5min under does not wedge, 66min over does)"
}

test_nonterminal_stale_repairs_missing_or_corrupt_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case nonterminal-stale-timer-repair); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet-timer"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet-timer.meta"
  printf 'working: still compiling\n' > "$state/quiet-timer.status"
  sig=$(seen_sig "$state/quiet-timer.status"); printf '%s' "$sig" > "$state/.seen-quiet-timer_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with missing timer did not initialize stale-since"; }
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    fail "watcher exited while repairing a missing stale-since timer: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "missing stale-since repair enqueued a wake"; }
  reap "$pid"

  printf 'corrupt\n' > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with corrupt timer did not repair stale-since"; }
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  [ "$since" != "corrupt" ] || { reap "$pid"; fail "corrupt stale-since value was left in place"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "corrupt stale-since repair enqueued a wake"; }
  reap "$pid"
  pass "matching non-terminal stale suppressors repair missing or corrupt stale-since timers"
}

# --- triage debug log stays size capped -------------------------------------

test_triage_log_size_cap_accepts_spaced_wc_counts() {
  local dir state fakebin out status_file pid lines i
  dir=$(make_case triage-log-spaced-wc); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  i=1
  while [ "$i" -le 3000 ]; do
    printf 'old line %04d\n' "$i" >> "$state/.watch-triage.log"
    i=$((i + 1))
  done
  cat > "$fakebin/wc" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "-c" ]; then
  printf '   999999\n'
  exit 0
fi
exit 127
SH
  chmod +x "$fakebin/wc"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # Provably working so the no-verb signal is absorbed (which is what writes the
  # triage log line under test).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_TRIAGE_LOG_MAX_BYTES=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a benign signal while testing log capping: $(cat "$out")"
  fi
  i=0
  while [ "$i" -lt 30 ]; do
    lines=$(awk 'END { print NR + 0 }' "$state/.watch-triage.log")
    [ "$lines" -le 2000 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$lines" -le 2000 ] || { reap "$pid"; fail "triage log was not capped when wc emitted a spaced byte count (lines=$lines)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "benign signal enqueued a wake while testing log capping"; }
  reap "$pid"
  pass "triage log capping handles wc byte counts with leading spaces"
}

# --- process-event delivery -------------------------------------------------
# A durably captured process-event result publishes an ordinary `check` wake on
# the durable queue. The watcher must deliver that queued wake proactively -
# print an actionable reason and exit into the same rewake path every other
# actionable wake uses - rather than leaving it to be found by a manual drain.

# Run the runner against a case home. FM_ROOT_OVERRIDE (exported by the shared
# wake harness to keep the drain's tangle check inert) would otherwise point the
# runner at a root with no installed adapters, and the claim root must stay
# inside the case so nothing here can observe a real home's source ownership.
pe_case() {  # <dir> <command>...
  local dir=$1
  shift
  (unset FM_ROOT_OVERRIDE
   FM_PROCEVENT_CLAIM_ROOT="$dir/claims" FM_HOME="$dir" "$ROOT/bin/fm-procevent.sh" "$@")
}

# Capture one real process-event result into <dir>'s home, then retire the
# source so the fixture holds exactly the reported end state: one durably
# captured, unhandled, queued result and no remaining poll work.
seed_captured_procevent_result() {  # <dir>
  local dir=$1 i=0
  pe_case "$dir" register lavish delivery-src -- \
    /bin/sh -c 'printf "session:\n  file: /a.html\n  status: waiting\n"' >/dev/null || return 1
  pe_case "$dir" reconcile >/dev/null || return 1
  while [ "$i" -lt 100 ]; do
    [ -s "$dir/state/.wake-queue" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  pe_case "$dir" retire delivery-src >/dev/null || return 1
  [ -s "$dir/state/.wake-queue" ]
}

# The watcher, scoped by FM_HOME rather than FM_STATE_OVERRIDE, so the
# per-cycle reconcile it launches resolves the same home's state.
procevent_watch_bg() {  # <dir> <out>
  local dir=$1 out=$2
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
}

test_procevent_captured_result_surfaces_proactively() {
  local dir state out drain_out pid beacon_age
  dir=$(make_case procevent-delivery); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  seed_captured_procevent_result "$dir" || fail "the fixture captured no process-event result"
  grep -F "procevent lavish delivery-src 1" "$state/.wake-queue" >/dev/null \
    || fail "the captured result was never published to the durable queue"

  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "a healthy watcher never surfaced a durably captured process-event result: $(cat "$out")"
  grep -F "check:" "$out" >/dev/null \
    || fail "the process-event wake was not reported as an actionable check: $(cat "$out")"
  grep -F "procevent:delivery-src:1" "$out" >/dev/null \
    || fail "the actionable reason did not name the queued result: $(cat "$out")"
  beacon_age=$(FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_path_age "$2"' _ "$ROOT" "$state/.last-watcher-beat")
  [ "$beacon_age" -lt 60 ] || fail "the surfacing watcher was not a healthy one (beacon age ${beacon_age}s)"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the process-event wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "procevent lavish delivery-src 1" >/dev/null \
    || fail "the process-event result was not queued for the drain that follows the wake"
  pass "a captured process-event result wakes a healthy watcher proactively, with no manual drain"
}

test_procevent_surfaced_result_does_not_rewake() {
  local dir state out pid before after
  dir=$(make_case procevent-no-rewake); state="$dir/state"
  out="$dir/watch.out"
  seed_captured_procevent_result "$dir" || fail "the fixture captured no process-event result"

  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "the first proactive wake never happened: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain after the first process-event wake failed"

  # Still unhandled: the result stays eligible for re-announcement on the durable
  # queue, but that must never produce a second proactive wake.
  : > "$out"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  if ! wait_live "$pid" 40; then
    fail "an already-surfaced process-event result woke the watcher again: $(cat "$out")"
  fi
  reap "$pid"
  grep -F "procevent lavish delivery-src 1" "$state/.wake-queue" >/dev/null \
    || fail "re-announcement of the unhandled result stopped when its wake was suppressed"

  pe_case "$dir" handled delivery-src 1 >/dev/null || fail "could not acknowledge the captured result"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain before the handled control failed"
  before=$(awk 'END { print NR + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  : > "$out"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  if ! wait_live "$pid" 40; then
    fail "a handled process-event result woke the watcher: $(cat "$out")"
  fi
  reap "$pid"
  after=$(awk 'END { print NR + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$after" = "$before" ] || fail "a handled result was announced again ($before -> $after queued records)"
  pass "a process-event wake is delivered once: no duplicate wake while queued, and none once handled"
}

test_procevent_marker_keys_are_injective() {
  local dir state out pid marker_count
  dir=$(make_case procevent-marker-identity); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:a.b:1" "check: procevent fixture a.b 1"
  append_wake "$state" check "procevent:a_b:1" "check: procevent fixture a_b 1"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "colliding-looking process-event keys were not surfaced"
  grep -F "procevent:a.b:1" "$out" >/dev/null || fail "the dotted queue key was suppressed"
  grep -F "procevent:a_b:1" "$out" >/dev/null || fail "the underscored queue key was suppressed"
  marker_count=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | awk 'END { print NR + 0 }')
  [ "$marker_count" = 2 ] || fail "distinct queue keys produced $marker_count seen markers"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "marker identity fixture drain failed"
  pass "complete process-event queue keys map to distinct seen markers"
}

install_marker_mv_fault() {  # <dir>
  local dir=$1
  REAL_MV=$(command -v mv)
  export REAL_MV
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
dest=${!#}
case "$dest" in
  */.seen-procevent-*)
    case "${FM_MARKER_MV_MODE:-}" in
      pause)
        printf '1\n' > "$FM_MARKER_MV_READY"
        while [ ! -e "$FM_MARKER_MV_RELEASE" ]; do sleep 0.02; done
        ;;
      kill-before) kill -KILL "$PPID"; exit 1 ;;
      kill-after) "$REAL_MV" "$@" || exit; kill -KILL "$PPID"; exit 1 ;;
      fail) exit 1 ;;
    esac
    ;;
esac
exec "$REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
}

test_procevent_surface_serializes_with_drain() {
  local dir state out drain_out ready release pid drain_pid
  dir=$(make_case procevent-drain-race); state="$dir/state"; out="$dir/watch.out"
  drain_out="$dir/drain.out"; ready="$dir/marker-ready"; release="$dir/marker-release"
  append_wake "$state" check "procevent:drain-race:1" "check: procevent fixture drain-race 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=pause FM_MARKER_MV_READY="$ready" FM_MARKER_MV_RELEASE="$release" \
    procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_numeric_file "$ready" 100 || fail "the watcher never reached its marker commit boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" &
  drain_pid=$!
  wait_live "$drain_pid" 10 || fail "a concurrent drain split the surfacing transition"
  [ -s "$state/.wake-queue" ] || fail "the concurrent drain consumed the record before marker commit"
  touch "$release"
  wait "$pid" || fail "the paused watcher did not finish surfacing"
  wait "$drain_pid" || fail "the concurrent drain failed after surfacing committed"
  grep -F "procevent:drain-race:1" "$drain_out" >/dev/null \
    || fail "the serialized drain lost the process-event record"
  pass "queue revalidation, proactive output, and marker commit serialize with drain"
}

test_procevent_surface_crash_boundaries() {
  local dir state out fifo pid reader marker exit_status
  dir=$(make_case procevent-output-fail); state="$dir/state"; out="$dir/watch.out"; fifo="$dir/output.fifo"
  append_wake "$state" check "procevent:output-fail:1" "check: procevent fixture output-fail 1"
  mkfifo "$fifo"
  sh -c ': < "$1"' _ "$fifo" & reader=$!
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$fifo" &
  pid=$!
  wait "$reader" || true
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived a failed actionable output write"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "failed output committed a suppression marker"
  [ -s "$state/.wake-queue" ] || fail "failed output consumed the durable queue record"
  procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100 || fail "the record was not replayable after output failure"
  grep -F "procevent:output-fail:1" "$out" >/dev/null || fail "output failure lost proactive replay"

  dir=$(make_case procevent-before-marker); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:before-marker:1" "check: procevent fixture before-marker 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=kill-before procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived the injected pre-marker crash"
  grep -F "procevent:before-marker:1" "$out" >/dev/null || fail "the pre-marker crash happened before output"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "a pre-marker crash committed suppression"
  procevent_watch_bg "$dir" "$out.replay"; pid=$!
  wait_for_exit "$pid" 100 || fail "a pre-marker crash was not replayable"

  dir=$(make_case procevent-after-marker); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:after-marker:1" "check: procevent fixture after-marker 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=kill-after procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived the injected post-marker crash"
  grep -F "procevent:after-marker:1" "$out" >/dev/null || fail "the post-marker crash lost actionable output"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -n "$marker" ] || fail "the post-marker crash did not reach marker commit"
  : > "$out.replay"
  procevent_watch_bg "$dir" "$out.replay"; pid=$!
  if ! wait_live "$pid" 40; then
    fail "a delivered and durably marked record woke again: $(cat "$out.replay")"
  fi
  reap "$pid"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "post-marker fixture drain failed"
  pass "surfacing failures replay before marker commit and suppress only after delivered output"
}

test_procevent_marker_failure_exits_and_replays() {
  local dir state out pid marker output_count
  dir=$(make_case procevent-marker-failure); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:marker-failure:1" "check: procevent fixture marker-failure 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=fail procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "marker failure did not end the actionable watcher cycle successfully"
  output_count=$(grep -Fc "procevent:marker-failure:1" "$out" || true)
  [ "$output_count" = 1 ] || fail "marker failure printed the actionable reason $output_count times"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "marker failure committed suppression"
  [ ! -e "$state/.wake-queue.lock" ] && [ ! -L "$state/.wake-queue.lock" ] \
    || fail "marker failure left the queue lock held"
  procevent_watch_bg "$dir" "$out.replay"
  pid=$!
  wait_for_exit "$pid" 100 || fail "marker failure did not leave the durable record replayable"
  grep -F "procevent:marker-failure:1" "$out.replay" >/dev/null \
    || fail "marker failure lost the later proactive replay"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "marker-failure fixture drain failed"
  pass "marker failure exits through the shared wake owner, releases its lock, and replays later"
}

# --- heartbeat: no-change absorbed, backstop surfaces a missed status --------

test_heartbeat_no_change_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case heartbeat-absorb); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # A truly quiet fleet (no windows, no statuses) with a fast heartbeat cadence.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a no-change heartbeat (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "no-change heartbeat printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "no-change heartbeat enqueued a durable wake record"
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] || fail "heartbeat backoff streak did not advance while absorbing"
  reap "$pid"
  pass "a heartbeat with no captain-relevant change is absorbed and backs off the cadence"
}

test_heartbeat_backstop_surfaces_unsurfaced_status() {
  local dir state fakebin out drain_out sig pid
  dir=$(make_case heartbeat-backstop); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # A captain-relevant status whose .seen-* signature ALREADY matches (so the
  # per-poll signal scan stays quiet) but which was never surfaced (no
  # .hb-surfaced-* marker). This stands in for a per-wake-path miss; the heartbeat
  # fleet-scan backstop must catch it and wake firstmate.
  printf 'done: PR https://example.test/pr/5\n' > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "heartbeat backstop did not surface an unsurfaced captain-relevant status"
  grep -Fx "heartbeat" "$out" >/dev/null || fail "backstop did not exit with a heartbeat wake"
  [ "$(cat "$state/.hb-surfaced-miss" 2>/dev/null || true)" = "done: PR https://example.test/pr/5" ] \
    || fail "backstop did not record the status as surfaced (would re-fire next heartbeat)"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the backstop heartbeat failed"
  grep "$(printf '\theartbeat\t')" "$drain_out" >/dev/null || fail "backstop heartbeat was not queued"
  pass "heartbeat backstop fail-safe surfaces a captain-relevant status the per-wake path missed"
}

# --- beacon stays fresh while absorbing -------------------------------------

test_beacon_stays_fresh_while_absorbing() {
  local dir state fakebin out status_file pid m1 m2 now
  dir=$(make_case beacon-fresh); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: a\n' > "$status_file"
  # Provably working so the working: notes are absorbed (the path that must keep the
  # beacon fresh).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 15 || { reap "$pid"; fail "watcher exited while absorbing the first benign signal"; }
  m1=$(file_mtime "$state/.last-watcher-beat")
  # A second benign signal keeps it absorbing; the beacon must keep advancing.
  printf 'working: b\n' >> "$status_file"
  wait_live "$pid" 20 || { reap "$pid"; fail "watcher exited while absorbing a second benign signal"; }
  m2=$(file_mtime "$state/.last-watcher-beat")
  now=$(date +%s)
  if [ -z "$m1" ] || [ -z "$m2" ]; then
    reap "$pid"
    fail "watcher beacon missing while absorbing"
  fi
  [ "$m2" -ge "$m1" ] || { reap "$pid"; fail "beacon mtime regressed while absorbing"; }
  [ "$(( now - m2 ))" -lt 10 ] || { reap "$pid"; fail "beacon went stale while absorbing (age $(( now - m2 ))s)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "absorbing benign signals enqueued a wake"; }
  reap "$pid"
  pass "the liveness beacon stays fresh while the watcher absorbs benign wakes (fm-guard never false-alarms)"
}

# --- afk coherence: the daemon owns triage; the watcher does not double-triage ---

test_afk_present_reverts_watcher_to_one_shot() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case afk-coherence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: routine note\n' > "$status_file"
  date '+%s' > "$state/.afk"   # away mode: the supervise-daemon owns triage
  # Set a PROVABLY-WORKING verdict: if afk failed to bypass the provably-working
  # check, this no-verb signal would be absorbed (not surfaced). The test asserting
  # a surface therefore also proves afk reverts to one-shot and skips the costly read.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "with .afk present the watcher did not exit one-shot for a benign signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "afk-mode watcher did not surface the signal for the daemon"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the afk-mode signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "afk-mode benign signal was not queued for the daemon to classify"
  pass "with .afk present the watcher reverts to one-shot so the daemon owns triage (no double-triage)"
}

# A paused pane can first appear as a changed hash. In AFK mode that initial path
# must still hand off the plain window identity to the daemon, rather than running
# the normal-mode pause re-surface and decorating the stale identity.
test_afk_paused_changed_pane_hands_off_plain_stale() {
  local dir state fakebin out drain_out capture_file statusf window key sig pid back
  dir=$(make_case afk-paused-changed-pane); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-afk-held"
  printf 'idle, awaiting upstream\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/afk-held.meta"
  statusf="$state/afk-held.status"
  printf 'paused: awaiting the upstream tool release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-held_status"
  date '+%s' > "$state/.afk"
  key=$(printf '%s' "$window" | tr '.:/' '___')

  # Deliberately do not seed .hash-*: this is the changed-pane path that used to
  # call handle_paused_stale before AFK's one-shot daemon handoff.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream tool release' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "AFK paused changed pane did not hand off a stale wake"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "AFK paused stale did not preserve its plain window identity: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null && fail "AFK watcher decorated a stale identity instead of handing it to the daemon"
  [ ! -e "$state/.paused-$key" ] || fail "AFK watcher recorded normal-mode pause tracking instead of handing off"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after AFK paused stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "stale: $window" >/dev/null \
    || fail "AFK paused stale was not queued with the plain window identity"
  pass "AFK changed paused panes hand off plain stale identities for daemon-owned pause triage"
}

# --- periodic autodeploy-log sweep (config/autodeploy-logs) ------------------

# --- run-aware wedge deferral (bin/fm-classify-lib.sh) ------------------------
#
# THE regression: a crewmate that hands off to a backgrounded no-mistakes run is
# idle BY DESIGN - it is waiting to be notified - but wedge_timer_check escalated
# on pane idleness alone and never re-read the run. Reproduced live as five
# consecutive "possible wedge" escalations about four minutes apart while the run
# was demonstrably healthy and moving (review,fixing with the head advancing ->
# test,running -> document,running -> lint,running), each one costing firstmate a
# full turn on a deep inspection of a run that was fine.
#
# The same alarm fired for a second idle-by-design case: a run that already
# succeeded and is only waiting for its PR to land, which re-escalated every few
# minutes for as long as the PR stayed open even though the merge poll is what
# watches for the landing.
#
# The fix makes both outrank pane idleness, WITHOUT becoming a blanket
# suppression: the token must actually change. A run frozen on one step with no
# new commits for the whole run-wedge window still escalates, and a run parked at
# a gate or failed never defers at all.

test_run_progress_defers_wedge_while_advancing() {
  local dir state fakebin prev
  dir=$(make_case run-progress-advancing); state="$dir/state"; fakebin="$dir/fakebin"
  prev=$FM_CREW_STATE_BIN
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  fm_write_meta "$state/task.meta" "window=sess:fm-task" "backend=tmux"
  # shellcheck disable=SC2329 # invoked indirectly via the sourced fm-classify-lib.sh
  fm_backend_agent_alive() { printf 'alive'; }
  export FM_FAKE_RUN_PROGRESS='working/01RUN/abc1234/intent:completed,review:fixing'
  crew_run_progress_defers_wedge task "$state" \
    || fail "first sighting of an attributed run did not defer the wedge"
  [ -s "$state/.run-progress-task" ] || fail "no progress marker was recorded on first sighting"
  # Unchanged token, but only moments old: still well inside the window.
  crew_run_progress_defers_wedge task "$state" \
    || fail "an unchanged token inside the window escalated early"
  # The pipeline advances a step: the token is renewed and the window restarts.
  export FM_FAKE_RUN_PROGRESS='working/01RUN/abc1234/intent:completed,review:completed,test:running'
  crew_run_progress_defers_wedge task "$state" \
    || fail "an advancing run did not defer the wedge"
  grep -Fq 'test:running' "$state/.run-progress-task" \
    || fail "progress marker did not record the advanced token"
  unset -f fm_backend_agent_alive
  export FM_CREW_STATE_BIN="$prev"
  unset FM_FAKE_RUN_PROGRESS
  pass "crew_run_progress_defers_wedge: an advancing validation run defers the wedge alarm"
}

test_run_progress_escalates_a_frozen_run() {
  local dir state fakebin prev marker stamped
  dir=$(make_case run-progress-frozen); state="$dir/state"; fakebin="$dir/fakebin"
  prev=$FM_CREW_STATE_BIN
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  fm_write_meta "$state/task.meta" "window=sess:fm-task" "backend=tmux"
  # shellcheck disable=SC2329 # invoked indirectly via the sourced fm-classify-lib.sh
  fm_backend_agent_alive() { printf 'alive'; }
  export FM_FAKE_RUN_PROGRESS='working/01RUN/abc1234/test:running'
  marker="$state/.run-progress-task"
  # Same step, same head, no structural movement at all for longer than the
  # run-wedge window: a genuinely wedged pipeline, which must still surface.
  printf '%s\t%s\n' "$(( $(date +%s) - 6000 ))" '01RUN/abc1234/test:running' > "$marker"
  crew_run_progress_defers_wedge task "$state" \
    && fail "a run frozen past the window was deferred instead of escalated"
  stamped=$(cut -f1 "$marker")
  [ "$(( $(date +%s) - stamped ))" -lt 60 ] \
    || fail "escalation did not re-stamp the progress marker"
  # Re-stamped, so it nags once per window rather than on every poll from here.
  crew_run_progress_defers_wedge task "$state" \
    || fail "the escalated run re-escalated immediately instead of waiting a window"
  unset -f fm_backend_agent_alive
  export FM_CREW_STATE_BIN="$prev"
  unset FM_FAKE_RUN_PROGRESS
  pass "crew_run_progress_defers_wedge: a frozen run still escalates, then once per window"
}

test_run_progress_escalates_without_an_attributed_run() {
  local dir state fakebin prev
  dir=$(make_case run-progress-no-run); state="$dir/state"; fakebin="$dir/fakebin"
  prev=$FM_CREW_STATE_BIN
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  # No FM_FAKE_RUN_PROGRESS: the reader reports `none`, the pre-validation case.
  crew_run_progress_defers_wedge task "$state" \
    && fail "a crew with no attributed run deferred the wedge"
  [ ! -e "$state/.run-progress-task" ] \
    || fail "a crew with no attributed run wrote a progress marker"
  export FM_CREW_STATE_BIN="$prev"
  pass "crew_run_progress_defers_wedge: no attributed run escalates exactly as the pane timer alone did"
}

# The second reported false alarm: a task whose run reconciles to terminal
# success awaiting merge. That worker is FINISHED and idle by design - usually
# exited outright - and the merge poll is what watches for the landing, yet its
# pane kept wedge-escalating every few minutes for as long as the PR stayed open.
# Note the endpoint is deliberately gone here: the dead-agent escalation that
# guards an in-flight run must NOT fire for a run that already succeeded.
test_run_progress_defers_a_finished_run_awaiting_merge() {
  local dir state fakebin prev
  dir=$(make_case run-progress-awaiting-merge); state="$dir/state"; fakebin="$dir/fakebin"
  prev=$FM_CREW_STATE_BIN
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  fm_write_meta "$state/task.meta" "window=sess:fm-task" "backend=tmux"
  # Deliberately dead: the worker reported its result and exited, which is its
  # expected end state, so the dead-agent escalation must not fire here.
  # shellcheck disable=SC2329 # invoked indirectly via the sourced fm-classify-lib.sh
  fm_backend_agent_alive() { printf 'dead'; }
  export FM_FAKE_RUN_PROGRESS='done/01RUN/abc1234/lint:completed,push:completed,pr:completed,ci:running'
  crew_run_progress_defers_wedge task "$state" \
    || fail "a finished run awaiting merge did not defer the wedge alarm"
  crew_run_progress_defers_wedge task "$state" \
    || fail "a finished run awaiting merge re-escalated on the very next poll"
  # Bounded, not silenced: an unmerged PR still re-surfaces once per window.
  printf '%s\t%s\n' "$(( $(date +%s) - 6000 ))" \
    '01RUN/abc1234/lint:completed,push:completed,pr:completed,ci:running' \
    > "$state/.run-progress-task"
  crew_run_progress_defers_wedge task "$state" \
    && fail "a finished run awaiting merge was silenced forever instead of rechecked once per window"
  unset -f fm_backend_agent_alive
  export FM_CREW_STATE_BIN="$prev"
  unset FM_FAKE_RUN_PROGRESS
  pass "crew_run_progress_defers_wedge: a finished run awaiting merge defers even with its worker exited, and still rechecks once per window"
}

# Disconfirming counterpart: only a terminal-SUCCESS run is idle by design. A run
# parked at a gate is waiting on firstmate and a failed run needs reporting, so
# neither may buy quiet from this policy.
test_run_progress_never_defers_a_parked_or_failed_run() {
  local dir state fakebin prev
  dir=$(make_case run-progress-parked); state="$dir/state"; fakebin="$dir/fakebin"
  prev=$FM_CREW_STATE_BIN
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  fm_write_meta "$state/task.meta" "window=sess:fm-task" "backend=tmux"
  # Alive on purpose, so the refusal below is attributable to the phase alone.
  # shellcheck disable=SC2329 # invoked indirectly via the sourced fm-classify-lib.sh
  fm_backend_agent_alive() { printf 'alive'; }
  export FM_FAKE_RUN_PROGRESS='parked/01RUN/abc1234/review:awaiting_approval'
  crew_run_progress_defers_wedge task "$state" \
    && fail "a run parked at a gate deferred the wedge instead of surfacing for firstmate"
  export FM_FAKE_RUN_PROGRESS='failed/01RUN/abc1234/test:failed'
  crew_run_progress_defers_wedge task "$state" \
    && fail "a failed run deferred the wedge instead of surfacing"
  unset -f fm_backend_agent_alive
  export FM_CREW_STATE_BIN="$prev"
  unset FM_FAKE_RUN_PROGRESS
  pass "crew_run_progress_defers_wedge: a parked or failed run never defers, only advancing and finished-awaiting-merge do"
}

test_run_progress_escalates_a_confirmed_dead_agent() {
  local dir state fakebin prev
  dir=$(make_case run-progress-dead-agent); state="$dir/state"; fakebin="$dir/fakebin"
  prev=$FM_CREW_STATE_BIN
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  fm_write_meta "$state/task.meta" "window=sess:fm-task" "backend=tmux"
  export FM_FAKE_RUN_PROGRESS='working/01RUN/abc1234/test:running'
  # The endpoint is gone, so nothing is driving this run whatever its run-step
  # still claims. A left-behind running step must not buy a crashed crewmate a
  # long quiet window - that would trade one false alarm for a genuinely missed
  # one.
  # shellcheck disable=SC2329 # invoked indirectly via the sourced fm-classify-lib.sh
  fm_backend_agent_alive() { printf 'dead'; }
  crew_run_progress_defers_wedge task "$state" \
    && fail "a confirmed-dead agent deferred the wedge on the strength of a stale run-step"
  [ ! -e "$state/.run-progress-task" ] \
    || fail "a confirmed-dead agent's run stamped a progress marker instead of escalating"
  unset -f fm_backend_agent_alive
  export FM_CREW_STATE_BIN="$prev"
  unset FM_FAKE_RUN_PROGRESS
  pass "crew_run_progress_defers_wedge: a confirmed-dead agent escalates even with an attributed run"
}

test_run_progress_fails_closed_on_an_unreadable_token() {
  local dir state fakebin prev
  dir=$(make_case run-progress-failclosed); state="$dir/state"; fakebin="$dir/fakebin"
  prev=$FM_CREW_STATE_BIN
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  # A reader that does not understand --run-progress and echoes a state line, and
  # then one that says nothing at all. Neither is evidence of an advancing run, so
  # both must escalate rather than silently suppressing the alarm.
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: run-step · validating (running)\n'
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  crew_run_progress_defers_wedge task "$state" \
    && fail "a state line from an older reader was accepted as progress evidence"
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  crew_run_progress_defers_wedge task "$state" \
    && fail "an unreadable progress read was accepted as progress evidence"
  export FM_CREW_STATE_BIN="$prev"
  pass "crew_run_progress_defers_wedge: an unrecognized or unreadable read escalates (fail-closed)"
}

# The always-on watcher and the away-mode daemon must apply this policy from ONE
# implementation, not two that can drift. Structural proof to back the behavioral
# tests here and in fm-daemon.test.sh: exactly one definition, both callers.
test_run_wedge_policy_has_a_single_owner() {
  local defs
  defs=$(grep -lE '^crew_run_progress_defers_wedge\(\)' "$ROOT"/bin/*.sh | tr '\n' ' ')
  [ "$defs" = "$ROOT/bin/fm-classify-lib.sh " ] \
    || fail "expected exactly one definition, in bin/fm-classify-lib.sh; found: $defs"
  grep -q 'crew_run_progress_defers_wedge' "$ROOT/bin/fm-watch.sh" \
    || fail "the always-on watcher does not consult the shared run-wedge policy"
  grep -q 'crew_run_progress_defers_wedge' "$ROOT/bin/fm-supervise-daemon.sh" \
    || fail "the away-mode daemon does not consult the shared run-wedge policy"
  pass "the run-aware wedge policy has one owner, used by both the watcher and the away-mode daemon"
}

# Behavioral: a real fm-watch.sh subprocess, pane idle far past the wedge
# threshold, with an attributed run that is advancing. Pre-fix this escalated.
test_watcher_defers_wedge_while_validation_run_advances() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case watch-wedge-advancing); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-advancing"
  printf 'no-mistakes axi run: validating...\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/advancing.meta"
  printf 'working: handed off to the validation run\n' > "$state/advancing.status"
  sig=$(seen_sig "$state/advancing.status"); printf '%s' "$sig" > "$state/.seen-advancing_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  export FM_FAKE_RUN_PROGRESS='working/01RUN/abc1234/review:completed,test:running'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 40; then
    reap "$pid"; fail "an advancing validation run was wedge-escalated on pane idleness alone: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "an advancing validation run printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "an advancing validation run enqueued a wedge wake"
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  case "$since" in ''|*[!0-9]*) reap "$pid"; fail "the deferred wedge did not restart the pane timer" ;; esac
  [ "$(( $(date +%s) - since ))" -lt 240 ] \
    || { reap "$pid"; fail "the deferred wedge left the pane timer already past its threshold"; }
  [ -s "$state/.run-progress-advancing" ] || { reap "$pid"; fail "no run-progress marker was recorded"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE FM_FAKE_RUN_PROGRESS
  pass "the watcher defers the wedge alarm while an attributed validation run is advancing"
}

# The live second case, end to end: the run finished successfully and the PR is
# open and unmerged, so the worker sits idle (here, gone entirely) while the
# merge poll watches for the landing. Its pane was re-escalating as a possible
# wedge every FM_STALE_ESCALATE_SECS for as long as the PR stayed open.
test_watcher_defers_wedge_for_a_finished_run_awaiting_merge() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case watch-wedge-awaiting-merge); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-merging"
  printf 'no-mistakes axi run: monitoring CI until merge...\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/merging.meta"
  # A non-captain-relevant last line: this is the path that re-nagged, because a
  # terminal-looking log line takes the separate already-surfaced branch instead.
  printf 'working: handed off to the validation run\n' > "$state/merging.status"
  sig=$(seen_sig "$state/merging.status"); printf '%s' "$sig" > "$state/.seen-merging_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: monitoring CI until merge...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review (still monitoring for merge/close)'
  export FM_FAKE_RUN_PROGRESS='done/01RUN/abc1234/pr:completed,ci:running'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 40; then
    reap "$pid"; fail "a finished run awaiting merge was wedge-escalated on pane idleness: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a finished run awaiting merge printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "a finished run awaiting merge enqueued a wedge wake"
  reap "$pid"
  unset FM_FAKE_CREW_STATE FM_FAKE_RUN_PROGRESS
  pass "the watcher defers the wedge alarm for a finished run awaiting merge"
}

# The disconfirming counterpart: identical setup, but the run has not moved for
# longer than the run-wedge window. The alarm must still fire.
test_watcher_still_escalates_a_frozen_validation_run() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case watch-wedge-frozen); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-frozen"
  printf 'no-mistakes axi run: validating...\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/frozen.meta"
  printf 'working: handed off to the validation run\n' > "$state/frozen.status"
  sig=$(seen_sig "$state/frozen.status"); printf '%s' "$sig" > "$state/.seen-frozen_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '%s\t%s\n' "$(( $(date +%s) - 6000 ))" '01RUN/abc1234/test:running' \
    > "$state/.run-progress-frozen"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  export FM_FAKE_RUN_PROGRESS='working/01RUN/abc1234/test:running'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || { reap "$pid"; fail "a frozen validation run was never wedge-escalated"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "frozen-run escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "frozen-run escalation did not flag a possible wedge"
  unset FM_FAKE_CREW_STATE FM_FAKE_RUN_PROGRESS
  pass "the watcher still wedge-escalates a validation run that has stopped advancing"
}

# Run autodeploy_scan once against <state>/<config> by sourcing fm-watch.sh in a
# subshell - its source guard returns before the runtime lock/loop, so only the
# functions load. Echoes "rc=<exit>"; the durable wake queue and per-log surfaced
# markers land under <state>. Keeps the scan hermetic (no real watcher, no timing).
run_autodeploy_scan() {  # <state> <config>
  # Pass fm-watch.sh as $1 (not $0), so its BASH_SOURCE[0] != $0 source guard
  # fires and the runtime loop below it never starts (same trick as append_wake).
  FM_STATE_OVERRIDE="$1" FM_CONFIG_OVERRIDE="$2" \
    bash -c '. "$1"; autodeploy_scan; printf "rc=%s\n" "$?"' _ "$WATCH" 2>/dev/null
}

# Marker path fm-watch.sh's autodeploy_scan uses for a given log (mirror the
# script's tr sanitization so a test can assert on the record directly).
autodeploy_marker() {  # <state> <log-path>
  printf '%s/.autodeploy-surfaced-%s' "$1" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_')"
}

test_autodeploy_absent_config_is_noop() {
  local dir state config rc
  dir=$(make_case autodeploy-absent); state="$dir/state"; config="$dir/config"
  mkdir -p "$config"   # config dir present, but no autodeploy-logs file in it
  rc=$(run_autodeploy_scan "$state" "$config")
  [ "$rc" = "rc=1" ] || fail "absent config/autodeploy-logs was not a no-op (got $rc)"
  [ ! -s "$state/.wake-queue" ] || fail "absent config enqueued a wake"
  pass "an absent config/autodeploy-logs is a silent no-op"
}

test_autodeploy_failure_enqueues_labelled_check() {
  local dir state config log rc
  dir=$(make_case autodeploy-fail); state="$dir/state"; config="$dir/config"
  mkdir -p "$config" "$state/beamanalyzer-autodeploy"
  log="$state/beamanalyzer-autodeploy/status.log"
  printf '%s\n' "$log" > "$config/autodeploy-logs"
  # A failing run: an ok rollup, then a STUCK alert line, then the ALERT rollup
  # that is the run's authoritative last line.
  printf '2026-07-15T10:00:00+00:00 ok nas=unchanged prod=unchanged deployed=no\n' > "$log"
  printf '2026-07-15T10:05:00+00:00 beamanalyzer-autodeploy: prod: STUCK: v2 has diverged - needs attention\n' >> "$log"
  printf '2026-07-15T10:05:00+00:00 ALERT nas=unchanged prod=unsafe deployed=no\n' >> "$log"
  rc=$(run_autodeploy_scan "$state" "$config")
  [ "$rc" = "rc=0" ] || fail "a failing autodeploy last line was not actionable (got $rc)"
  grep "$(printf '\tcheck\t')" "$state/.wake-queue" >/dev/null || fail "no check wake enqueued for the failure"
  grep -F "ALERT nas=unchanged prod=unsafe" "$state/.wake-queue" >/dev/null || fail "check wake did not carry the failing last line"
  grep -F "autodeploy beamanalyzer-autodeploy reports failure" "$state/.wake-queue" >/dev/null || fail "check wake did not label the deploy"
  [ -s "$(autodeploy_marker "$state" "$log")" ] || fail "failure was not recorded surfaced"
  pass "a failing autodeploy last line enqueues a labelled check wake and records it surfaced"
}

test_autodeploy_healthy_is_silent_and_rearms() {
  local dir state config log marker rc
  dir=$(make_case autodeploy-healthy); state="$dir/state"; config="$dir/config"
  mkdir -p "$config" "$state/deploy"
  log="$state/deploy/status.log"
  printf '%s\n' "$log" > "$config/autodeploy-logs"
  marker=$(autodeploy_marker "$state" "$log")
  printf 'ALERT nas=unsafe prod=unchanged deployed=no' > "$marker"   # stale prior alarm
  printf '2026-07-15T11:00:00+00:00 ok nas=unchanged prod=unchanged deployed=no\n' > "$log"
  rc=$(run_autodeploy_scan "$state" "$config")
  [ "$rc" = "rc=1" ] || fail "a healthy ok last line was treated as actionable (got $rc)"
  [ ! -s "$state/.wake-queue" ] || fail "a healthy last line enqueued a wake"
  [ ! -e "$marker" ] || fail "a healthy run did not clear the surfaced marker (alarm would never re-arm)"
  pass "a healthy ok last line is silent and clears any prior surfaced marker"
}

test_autodeploy_persistent_failure_dedupes() {
  local dir state config log rc1 rc2 count
  dir=$(make_case autodeploy-dedupe); state="$dir/state"; config="$dir/config"
  mkdir -p "$config" "$state/deploy"
  log="$state/deploy/status.log"
  printf '%s\n' "$log" > "$config/autodeploy-logs"
  printf '2026-07-15T12:00:00+00:00 ALERT nas=unsafe prod=unchanged deployed=no\n' > "$log"
  rc1=$(run_autodeploy_scan "$state" "$config")
  # A later run reports the SAME failure but stamps a fresh time (autodeploy re-runs
  # every few minutes); the timestamp must not defeat dedupe.
  printf '2026-07-15T12:05:00+00:00 ALERT nas=unsafe prod=unchanged deployed=no\n' >> "$log"
  rc2=$(run_autodeploy_scan "$state" "$config")
  [ "$rc1" = "rc=0" ] || fail "first scan of a new failure was not actionable (got $rc1)"
  [ "$rc2" = "rc=1" ] || fail "an unchanged persistent failure re-surfaced despite a fresh timestamp (got $rc2)"
  count=$(grep -c "$(printf '\tcheck\t')" "$state/.wake-queue" 2>/dev/null || true)
  [ "${count:-0}" = "1" ] || fail "persistent failure enqueued ${count:-0} check wakes, expected exactly 1"
  pass "a persistent identical failure surfaces once despite each run's changing timestamp"
}

test_autodeploy_recurrence_after_clear_resurfaces() {
  local dir state config log rc_fail rc_ok rc_again count
  dir=$(make_case autodeploy-recur); state="$dir/state"; config="$dir/config"
  mkdir -p "$config" "$state/deploy"
  log="$state/deploy/status.log"
  printf '%s\n' "$log" > "$config/autodeploy-logs"
  printf '2026-07-15T13:00:00+00:00 ALERT nas=unsafe prod=unchanged deployed=no\n' > "$log"
  rc_fail=$(run_autodeploy_scan "$state" "$config")
  printf '2026-07-15T13:05:00+00:00 ok nas=unchanged prod=unchanged deployed=no\n' >> "$log"
  rc_ok=$(run_autodeploy_scan "$state" "$config")
  printf '2026-07-15T13:10:00+00:00 ALERT nas=unsafe prod=unchanged deployed=no\n' >> "$log"
  rc_again=$(run_autodeploy_scan "$state" "$config")
  [ "$rc_fail" = "rc=0" ] || fail "initial failure not actionable (got $rc_fail)"
  [ "$rc_ok" = "rc=1" ] || fail "healthy recovery not silent (got $rc_ok)"
  [ "$rc_again" = "rc=0" ] || fail "a failure recurring after a clean run did not re-surface (got $rc_again)"
  count=$(grep -c "$(printf '\tcheck\t')" "$state/.wake-queue" 2>/dev/null || true)
  [ "${count:-0}" = "2" ] || fail "expected 2 check wakes across fail/clear/fail, got ${count:-0}"
  pass "a failure recurring after a healthy run re-surfaces once the alarm re-armed"
}

test_autodeploy_unreadable_log_is_silent() {
  local dir state config rc
  dir=$(make_case autodeploy-unreadable); state="$dir/state"; config="$dir/config"
  mkdir -p "$config"
  # Point at a log that does not exist; a NAS mount hiccup looks the same.
  printf '%s\n' "$state/nope/status.log" > "$config/autodeploy-logs"
  rc=$(run_autodeploy_scan "$state" "$config")
  [ "$rc" = "rc=1" ] || fail "a missing/unreadable log was not skipped silently (got $rc)"
  [ ! -s "$state/.wake-queue" ] || fail "a missing log enqueued a wake"
  pass "a missing or unreadable configured log is skipped silently, not alarmed"
}

test_autodeploy_timed_out_log_is_silent() {
  local dir state config fakebin log rc elapsed real_tail
  dir=$(make_case autodeploy-timeout); state="$dir/state"; config="$dir/config"; fakebin="$dir/fakebin"
  mkdir -p "$config" "$state/hung-deploy"
  log="$state/hung-deploy/status.log"
  printf '%s\n' "$log" > "$config/autodeploy-logs"
  printf 'ALERT should time out\n' > "$log"
  real_tail=$(command -v tail)
  cat > "$fakebin/tail" <<SH
#!/usr/bin/env bash
if [ "\${FM_FAKE_TAIL_SLEEP:-}" = 1 ]; then
  perl -e 'sleep 20'
  exit 0
fi
exec '$real_tail' "\$@"
SH
  chmod +x "$fakebin/tail"

  SECONDS=0
  rc=$(PATH="$fakebin:$PATH" FM_FAKE_TAIL_SLEEP=1 FM_AUTODEPLOY_LOG_READ_TIMEOUT=1 run_autodeploy_scan "$state" "$config")
  elapsed=$SECONDS
  [ "$rc" = "rc=1" ] || fail "a timed-out log read was not skipped silently (got $rc)"
  [ "$elapsed" -lt 5 ] || fail "timed-out log read blocked watcher scan for ${elapsed}s"
  [ ! -s "$state/.wake-queue" ] || fail "a timed-out log read enqueued a wake"
  pass "a timed-out configured log read is skipped silently, not alarmed"
}

test_autodeploy_comments_blanks_and_whitespace() {
  local dir state config log rc
  dir=$(make_case autodeploy-comments); state="$dir/state"; config="$dir/config"
  mkdir -p "$config" "$state/deploy"
  log="$state/deploy/status.log"
  {
    printf '# watched autodeploy logs\n'
    printf '\n'
    printf '   %s   \n' "$log"   # surrounding whitespace must be trimmed
  } > "$config/autodeploy-logs"
  printf '2026-07-15T14:00:00+00:00 deploy: build: FAILED: npm ERR code ELIFECYCLE\n' > "$log"
  rc=$(run_autodeploy_scan "$state" "$config")
  [ "$rc" = "rc=0" ] || fail "a FAILED: last line on a whitespace-padded path was not detected (got $rc)"
  grep -F "build: FAILED: npm ERR" "$state/.wake-queue" >/dev/null || fail "FAILED: line not surfaced"
  pass "blank lines and # comments are ignored and surrounding whitespace on a path is trimmed"
}

test_autodeploy_failure_surfaced_on_heartbeat() {
  local dir state fakebin config out drain_out pid
  dir=$(make_case autodeploy-heartbeat); state="$dir/state"; fakebin="$dir/fakebin"
  config="$dir/config"; out="$dir/watch.out"; drain_out="$dir/drain.out"
  mkdir -p "$config" "$state/beamanalyzer-autodeploy"
  printf '%s\n' "$state/beamanalyzer-autodeploy/status.log" > "$config/autodeploy-logs"
  printf '2026-07-15T10:30:00+00:00 ALERT nas=unsafe prod=unchanged deployed=no\n' \
    > "$state/beamanalyzer-autodeploy/status.log"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a configured autodeploy failure on the periodic sweep"
  grep -F "check: autodeploy" "$out" >/dev/null || fail "watcher did not exit with a check wake for the autodeploy failure: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after autodeploy heartbeat failed"
  grep "$(printf '\tcheck\t')" "$drain_out" >/dev/null || fail "autodeploy check wake was not queued"
  grep -F "ALERT nas=unsafe" "$drain_out" >/dev/null || fail "drained check wake did not carry the failure line"
  pass "a configured autodeploy status log's failure surfaces as a check wake on the watcher's periodic sweep"
}

# --- Periodic /tmp usage-threshold sweep (tmp_alert_scan) -------------------
# The always-on twin of bootstrap's tmp_alert_check (tests/fm-bootstrap.test.sh),
# for a breach that crosses config/tmp-alert-threshold between sessions. Unlike
# autodeploy_scan there is only one thing watched (/tmp itself), so dedup is a
# single boolean marker (.tmp-alert-surfaced) rather than a per-log content hash.

# Fake df for tmp_alert_scan. FM_FAKE_DF_PCT controls the reported Capacity
# column (bare integer, no %); fm_tmp_alert_usage_pct's only invocation is
# `df -P /tmp`, reading column 5 of line 2, matching real `df -P` output shape.
add_fake_df() {
  local fakebin=$1
  cat > "$fakebin/df" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Filesystem     1024-blocks    Used Available Capacity Mounted on'
printf 'tmpfs             8130560   975667   7154893      %s%% /tmp\n' "${FM_FAKE_DF_PCT:-0}"
SH
  chmod +x "$fakebin/df"
}

# Run tmp_alert_scan once against <state>/<config> by sourcing fm-watch.sh in a
# subshell, same hermetic trick as run_autodeploy_scan. Echoes "rc=<exit>".
run_tmp_alert_scan() {  # <state> <config> <fakebin> <pct>
  PATH="$3:$PATH" FM_STATE_OVERRIDE="$1" FM_CONFIG_OVERRIDE="$2" FM_FAKE_DF_PCT="$4" \
    bash -c '. "$1"; tmp_alert_scan; printf "rc=%s\n" "$?"' _ "$WATCH" 2>/dev/null
}

tmp_alert_marker() {  # <state>
  printf '%s/.tmp-alert-surfaced' "$1"
}

test_tmp_alert_absent_config_is_noop() {
  local dir state config fakebin rc
  dir=$(make_case tmp-alert-absent); state="$dir/state"; config="$dir/config"; fakebin="$dir/fakebin"
  mkdir -p "$config"   # config dir present, but no tmp-alert-threshold file in it
  add_fake_df "$fakebin"
  rc=$(run_tmp_alert_scan "$state" "$config" "$fakebin" 95)
  [ "$rc" = "rc=1" ] || fail "absent config/tmp-alert-threshold was not a no-op (got $rc)"
  [ ! -s "$state/.wake-queue" ] || fail "absent threshold config enqueued a wake"
  pass "an absent config/tmp-alert-threshold is a silent no-op even near-full"
}

test_tmp_alert_breach_enqueues_check_wake() {
  local dir state config fakebin rc
  dir=$(make_case tmp-alert-breach); state="$dir/state"; config="$dir/config"; fakebin="$dir/fakebin"
  mkdir -p "$config"
  printf '80\n' > "$config/tmp-alert-threshold"
  add_fake_df "$fakebin"
  rc=$(run_tmp_alert_scan "$state" "$config" "$fakebin" 85)
  [ "$rc" = "rc=0" ] || fail "usage over threshold was not actionable (got $rc)"
  grep "$(printf '\tcheck\t')" "$state/.wake-queue" >/dev/null || fail "no check wake enqueued for the breach"
  grep -F "tmp-usage" "$state/.wake-queue" >/dev/null || fail "check wake was not keyed tmp-usage"
  grep -F "/tmp is 85% full (threshold 80%)" "$state/.wake-queue" >/dev/null || fail "check wake did not carry the usage/threshold numbers"
  [ -e "$(tmp_alert_marker "$state")" ] || fail "breach was not recorded surfaced"
  pass "usage at or above the configured threshold enqueues a check wake and records it surfaced"
}

test_tmp_alert_exactly_at_threshold_breaches() {
  local dir state config fakebin rc
  dir=$(make_case tmp-alert-exact); state="$dir/state"; config="$dir/config"; fakebin="$dir/fakebin"
  mkdir -p "$config"
  printf '80\n' > "$config/tmp-alert-threshold"
  add_fake_df "$fakebin"
  rc=$(run_tmp_alert_scan "$state" "$config" "$fakebin" 80)
  [ "$rc" = "rc=0" ] || fail "usage exactly at threshold was not actionable (got $rc)"
  pass "usage exactly at the configured threshold breaches (>=, not >)"
}

test_tmp_alert_healthy_is_silent_and_rearms() {
  local dir state config fakebin marker rc
  dir=$(make_case tmp-alert-healthy); state="$dir/state"; config="$dir/config"; fakebin="$dir/fakebin"
  mkdir -p "$config"
  printf '80\n' > "$config/tmp-alert-threshold"
  add_fake_df "$fakebin"
  marker=$(tmp_alert_marker "$state")
  mkdir -p "$state"
  : > "$marker"   # stale prior alarm
  rc=$(run_tmp_alert_scan "$state" "$config" "$fakebin" 40)
  [ "$rc" = "rc=1" ] || fail "usage below threshold was treated as actionable (got $rc)"
  [ ! -s "$state/.wake-queue" ] || fail "usage below threshold enqueued a wake"
  [ ! -e "$marker" ] || fail "a healthy reading did not clear the surfaced marker (alarm would never re-arm)"
  pass "usage below the configured threshold is silent and clears any prior surfaced marker"
}

test_tmp_alert_persistent_breach_dedupes() {
  local dir state config fakebin rc1 rc2 count
  dir=$(make_case tmp-alert-dedupe); state="$dir/state"; config="$dir/config"; fakebin="$dir/fakebin"
  mkdir -p "$config"
  printf '80\n' > "$config/tmp-alert-threshold"
  add_fake_df "$fakebin"
  rc1=$(run_tmp_alert_scan "$state" "$config" "$fakebin" 90)
  rc2=$(run_tmp_alert_scan "$state" "$config" "$fakebin" 91)   # still over, reading drifts
  [ "$rc1" = "rc=0" ] || fail "first scan of a new breach was not actionable (got $rc1)"
  [ "$rc2" = "rc=1" ] || fail "an unchanged persistent breach re-surfaced despite a drifting reading (got $rc2)"
  count=$(grep -c "$(printf '\tcheck\t')" "$state/.wake-queue" 2>/dev/null || true)
  [ "${count:-0}" = "1" ] || fail "persistent breach enqueued ${count:-0} check wakes, expected exactly 1"
  pass "a persistent breach surfaces once despite each run's drifting usage reading"
}

test_tmp_alert_recurrence_after_clear_resurfaces() {
  local dir state config fakebin rc_high rc_ok rc_again count
  dir=$(make_case tmp-alert-recur); state="$dir/state"; config="$dir/config"; fakebin="$dir/fakebin"
  mkdir -p "$config"
  printf '80\n' > "$config/tmp-alert-threshold"
  add_fake_df "$fakebin"
  rc_high=$(run_tmp_alert_scan "$state" "$config" "$fakebin" 90)
  rc_ok=$(run_tmp_alert_scan "$state" "$config" "$fakebin" 50)
  rc_again=$(run_tmp_alert_scan "$state" "$config" "$fakebin" 92)
  [ "$rc_high" = "rc=0" ] || fail "initial breach not actionable (got $rc_high)"
  [ "$rc_ok" = "rc=1" ] || fail "healthy recovery not silent (got $rc_ok)"
  [ "$rc_again" = "rc=0" ] || fail "a breach recurring after a healthy reading did not re-surface (got $rc_again)"
  count=$(grep -c "$(printf '\tcheck\t')" "$state/.wake-queue" 2>/dev/null || true)
  [ "${count:-0}" = "2" ] || fail "expected 2 check wakes across breach/clear/breach, got ${count:-0}"
  pass "a breach recurring after a healthy reading re-surfaces once the alarm re-armed"
}

test_tmp_alert_no_df_on_path_is_silent() {
  local dir state config fakebin rc bash_env
  dir=$(make_case tmp-alert-no-df); state="$dir/state"; config="$dir/config"; fakebin="$dir/fakebin"
  mkdir -p "$config"
  printf '80\n' > "$config/tmp-alert-threshold"
  # No add_fake_df: simulate df genuinely absent from PATH via a command()
  # override (BASH_ENV), the same technique tests/fm-bootstrap.test.sh uses for
  # its no-df/no-systemctl/no-timeout-mechanism cases, since a real df usually
  # exists elsewhere on PATH.
  bash_env="$dir/no-df-env.sh"
  cat > "$bash_env" <<'SH'
command() {
  if [ "$1" = -v ] && [ "$2" = df ]; then return 1; fi
  builtin command "$@"
}
SH
  rc=$(PATH="$fakebin:$PATH" BASH_ENV="$bash_env" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    bash -c '. "$1"; tmp_alert_scan; printf "rc=%s\n" "$?"' _ "$WATCH" 2>/dev/null)
  [ "$rc" = "rc=1" ] || fail "a missing df on PATH was not skipped silently (got $rc)"
  [ ! -s "$state/.wake-queue" ] || fail "a missing df enqueued a wake"
  pass "df missing from PATH is skipped silently, not alarmed"
}

test_tmp_alert_breach_surfaced_on_heartbeat() {
  local dir state fakebin config out drain_out pid
  dir=$(make_case tmp-alert-heartbeat); state="$dir/state"; fakebin="$dir/fakebin"
  config="$dir/config"; out="$dir/watch.out"; drain_out="$dir/drain.out"
  mkdir -p "$config"
  printf '80\n' > "$config/tmp-alert-threshold"
  add_fake_df "$fakebin"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" FM_FAKE_DF_PCT=90 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a /tmp usage breach on the periodic sweep"
  grep -F "check: tmp usage" "$out" >/dev/null || fail "watcher did not exit with a check wake for the /tmp usage breach: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after tmp-usage heartbeat failed"
  grep "$(printf '\tcheck\t')" "$drain_out" >/dev/null || fail "tmp-usage check wake was not queued"
  grep -F "/tmp is 90% full" "$drain_out" >/dev/null || fail "drained check wake did not carry the usage percentage"
  pass "a /tmp usage breach surfaces as a check wake on the watcher's periodic sweep"
}

test_signal_reason_is_actionable_classifier
test_stale_is_terminal_classifier
test_scan_captain_relevant_statuses_classifier
test_classifier_primitives
test_crew_is_provably_working_classifier
test_status_is_paused_classifier
test_crew_absorb_class_classifier
test_crew_absorb_class_honors_declared_pause_over_orphaned_run_step
test_crew_absorb_class_honors_declared_pause_at_open_gate_even_when_alive
test_crew_absorb_class_unpaused_wedge_still_surfaces
test_crew_absorb_class_honors_declared_pause_after_done
test_crew_absorb_class_done_without_pause_still_surfaces
test_timestamped_status_lines_classify_as_plain_ones
test_timestamped_status_lines_fold_under_their_real_key
test_crew_absorb_class_honors_timestamped_declared_pause
test_unparseable_status_verb_never_suppresses
test_crew_absorb_class_hard_constraints_still_surface
test_crew_absorb_class_honors_declared_pause_at_parked_gate
test_crew_absorb_class_parked_without_pause_or_decision_still_surfaces
test_crew_absorb_class_parked_with_only_open_decision_still_surfaces
test_nonterminal_stale_paused_orphaned_run_step_latches_marker
test_nonterminal_stale_paused_after_done_no_wedge_storm
test_nonterminal_stale_paused_after_done_alive_agent_hash_churn_no_wedge_storm
test_nonterminal_stale_paused_at_parked_gate_no_wedge_storm
test_absorb_zero_env_values_sanitized_to_default
test_absorb_zero_padded_env_values_sanitized_to_default
test_signal_crew_provably_working_classifier
test_provably_working_signal_absorbed
test_turn_ended_provably_working_absorbed
test_turn_ended_not_working_surfaced
test_working_note_not_working_surfaced
test_hung_crew_state_read_does_not_stall_watcher
test_hung_no_mistakes_status_does_not_freeze_watcher_beacon
test_actionable_signal_surfaced
test_terminal_stale_surfaced
test_stale_terminal_status_overridden_by_active_run
test_nonterminal_stale_provably_working_absorbed_then_escalated
test_wedge_escalation_marks_demand_deep_inspection_after_threshold
test_wedge_escalation_resets_when_pane_becomes_active
test_busy_pane_below_turn_age_bound_is_absorbed
test_busy_pane_stable_hash_escalates_past_turn_age_bound
test_busy_pane_changing_hash_escalates_past_turn_age_bound
test_busy_pane_turn_end_touch_resets_age
test_busy_pane_repeated_escalation_reaches_demand_deep_inspection
test_busy_pane_default_turn_age_bound_is_3600s
test_nonterminal_stale_not_working_surfaced
test_nonterminal_stale_paused_absorbed_then_resurfaced
test_exited_declared_pause_and_live_gate_share_bounded_cadence
test_secondmate_paused_resurfaces_in_normal_mode
test_secondmate_nonpaused_stale_remains_suppressed
test_secondmate_unpause_clears_pause_tracking
test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash
test_nonterminal_paused_rechecks_authoritative_state
test_paused_authoritative_working_preserves_wedge_timer
test_nonterminal_stale_repairs_missing_or_corrupt_timer
test_triage_log_size_cap_accepts_spaced_wc_counts
test_procevent_captured_result_surfaces_proactively
test_procevent_surfaced_result_does_not_rewake
test_procevent_marker_keys_are_injective
test_procevent_surface_serializes_with_drain
test_procevent_surface_crash_boundaries
test_procevent_marker_failure_exits_and_replays
test_heartbeat_no_change_absorbed
test_heartbeat_backstop_surfaces_unsurfaced_status
test_beacon_stays_fresh_while_absorbing
test_afk_present_reverts_watcher_to_one_shot
test_afk_paused_changed_pane_hands_off_plain_stale
test_run_progress_defers_wedge_while_advancing
test_run_progress_escalates_a_frozen_run
test_run_progress_escalates_without_an_attributed_run
test_run_progress_defers_a_finished_run_awaiting_merge
test_run_progress_never_defers_a_parked_or_failed_run
test_run_progress_escalates_a_confirmed_dead_agent
test_run_progress_fails_closed_on_an_unreadable_token
test_run_wedge_policy_has_a_single_owner
test_watcher_defers_wedge_while_validation_run_advances
test_watcher_defers_wedge_for_a_finished_run_awaiting_merge
test_watcher_still_escalates_a_frozen_validation_run
test_autodeploy_absent_config_is_noop
test_autodeploy_failure_enqueues_labelled_check
test_autodeploy_healthy_is_silent_and_rearms
test_autodeploy_persistent_failure_dedupes
test_autodeploy_recurrence_after_clear_resurfaces
test_autodeploy_unreadable_log_is_silent
test_autodeploy_timed_out_log_is_silent
test_autodeploy_comments_blanks_and_whitespace
test_autodeploy_failure_surfaced_on_heartbeat
test_tmp_alert_absent_config_is_noop
test_tmp_alert_breach_enqueues_check_wake
test_tmp_alert_exactly_at_threshold_breaches
test_tmp_alert_healthy_is_silent_and_rearms
test_tmp_alert_persistent_breach_dedupes
test_tmp_alert_recurrence_after_clear_resurfaces
test_tmp_alert_no_df_on_path_is_silent
test_tmp_alert_breach_surfaced_on_heartbeat
