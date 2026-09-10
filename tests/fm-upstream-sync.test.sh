#!/usr/bin/env bash
# Behavior tests for bin/fm-upstream-sync.sh, the scheduled upstream-template
# drift sweep. Every case runs against disposable git repositories and a private
# FM_HOME, so nothing here reads or writes the real fork, crontab, or backlog.
#
# Coverage follows what the executable actually owns: bounded scheduled
# detection, durable success/failure evidence, intake de-duplication against the
# existing inbox and backlog owners, and safe cron migration. The reconciliation
# merge itself belongs to the upstream-reconciliation skill and is exercised by
# its fixture (docs/examples/upstream-semantic-merge-fixture.sh), not here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/fm-upstream-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-sync)
REAL_GIT=$(command -v git)
fm_git_identity

# --- fixture ----------------------------------------------------------------

# make_world <name>: a bare upstream template, a fork clone whose `upstream`
# remote points at it, and a private operational home. Echoes the world root.
make_world() {
  local name=$1 world
  world="$TMP_ROOT/$name"
  mkdir -p "$world/upstream" "$world/home/state" "$world/home/data"
  git -C "$world/upstream" init -q -b main .
  printf 'base\n' > "$world/upstream/base.txt"
  git -C "$world/upstream" add base.txt
  git -C "$world/upstream" commit -qm base
  git clone -q "$world/upstream" "$world/fork"
  git -C "$world/fork" remote rename origin upstream
  printf '%s\n' "$world"
}

# Run the sweep against <world> with a private home. Extra env assignments may
# be passed as leading VAR=VALUE arguments.
sweep() { # <world> [VAR=VALUE...]
  local world=$1
  shift
  env FM_ROOT_OVERRIDE="$world/fork" \
      FM_HOME="$world/home" \
      FM_STATE_OVERRIDE="$world/home/state" \
      FM_DATA_OVERRIDE="$world/home/data" \
      "$@" "$SYNC" sweep 2>&1
}

upstream_commit() { # <world> <message>
  local world=$1 message=$2
  printf '%s\n' "$message" >> "$world/upstream/base.txt"
  git -C "$world/upstream" commit -qam "$message"
}

fork_commit() { # <world> <message>
  printf '%s\n' "$2" > "$1/fork/fork-$2.txt"
  git -C "$1/fork" add -A
  git -C "$1/fork" commit -qm "$2"
}

state_of() { printf '%s\n' "$1/home/state/upstream-sync"; }

record_field() { # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

note_count() { # <world>
  local n
  n=$(find "$1/home/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l)
  printf '%s\n' "$((n))"
}

wake_count() { # <world>
  local q="$1/home/state/.wake-queue"
  [ -f "$q" ] || { printf '0\n'; return 0; }
  wc -l < "$q" | tr -d ' '
}

# Acknowledge every pending note the way firstmate does, so the next sweep sees
# an empty inbox rather than a still-waiting request.
ack_notes() { # <world>
  local f
  mkdir -p "$1/home/state/inbox/handled"
  for f in "$1"/home/state/inbox/*.note; do
    [ -e "$f" ] || return 0
    mv "$f" "$1/home/state/inbox/handled/"
  done
}

# Shadow git with a stub whose `fetch` fails or stalls and which delegates every
# other subcommand to the real binary, so only the network step is simulated.
# `stall-hard` additionally IGNORES SIGTERM, which is the case a bare
# `kill -TERM` plus `wait` never escapes.
install_git_stub() { # <world> <mode: fail|stall|stall-hard>
  local world=$1 mode=$2 fakebin
  fakebin=$(fm_fakebin "$world")
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = fetch ]; then
    if [ "$mode" = stall ]; then sleep 120; exit 0; fi
    if [ "$mode" = stall-hard ]; then
      trap '' TERM INT HUP
      i=0
      while [ "\$i" -lt 120 ]; do sleep 1 || true; i=\$((i + 1)); done
      exit 0
    fi
    printf 'fatal: unable to access upstream\n' >&2
    exit 128
  fi
done
exec "$REAL_GIT" "\$@"
SH
  chmod +x "$fakebin/git"
  printf '%s\n' "$fakebin"
}

# --- detection --------------------------------------------------------------

test_no_drift_is_a_recorded_success() {
  local world out sync
  world=$(make_world no-drift)
  sync=$(state_of "$world")
  out=$(sweep "$world") || fail "sweep failed with no drift: $out"

  assert_contains "$out" "no-change" "a fork level with upstream reports no-change"
  [ "$(record_field "$sync/last-success" result)" = no-change ] \
    || fail "last-success did not record result=no-change"
  [ -f "$sync/last-failure" ] && fail "a clean sweep wrote a failure record"
  [ "$(note_count "$world")" = 0 ] || fail "a clean sweep queued an intake note"
  [ "$(wake_count "$world")" = 0 ] || fail "a clean sweep queued a wake"
  pass "no drift records a success and queues nothing"
}

test_fork_only_commits_are_not_drift() {
  local world out sync
  world=$(make_world fork-only)
  sync=$(state_of "$world")
  fork_commit "$world" one
  fork_commit "$world" two
  out=$(sweep "$world") || fail "sweep failed with fork-only commits: $out"

  assert_contains "$out" "no-change" "fork-only commits are not upstream drift"
  [ "$(record_field "$sync/last-success" ahead)" = 2 ] \
    || fail "last-success did not record the fork's two ahead commits"
  [ "$(record_field "$sync/last-success" behind)" = 0 ] \
    || fail "fork-only commits were counted as behind"
  [ "$(note_count "$world")" = 0 ] || fail "fork-only commits queued an intake note"
  pass "fork-only commits stay a no-change success"
}

test_new_upstream_commits_publish_one_intake() {
  local world out sync body
  world=$(make_world new-upstream)
  sync=$(state_of "$world")
  fork_commit "$world" local-work
  upstream_commit "$world" upstream-one
  upstream_commit "$world" upstream-two
  out=$(sweep "$world") || fail "sweep failed with new upstream commits: $out"

  assert_contains "$out" "intake-published" "new upstream commits publish an intake"
  [ "$(note_count "$world")" = 1 ] || fail "expected exactly one intake note"
  [ "$(wake_count "$world")" = 1 ] || fail "expected exactly one wake"
  [ "$(record_field "$sync/last-success" behind)" = 2 ] \
    || fail "last-success did not record behind=2"
  [ -n "$(record_field "$sync/last-intake" upstream_sha)" ] \
    || fail "last-intake did not pin the upstream head"

  body=$(cat "$world"/home/state/inbox/*.note)
  assert_contains "$body" "[upstream-sync:intake]" "the note carries this routine's intake marker"
  assert_contains "$body" "upstream-drift-alert" "the note names the reconciliation backlog id"
  assert_contains "$body" "landing is still the captain's call" \
    "the note keeps landing with the captain"
  pass "new upstream commits publish exactly one durable intake"
}

# --- intake de-duplication --------------------------------------------------

test_pending_note_suppresses_a_second_intake() {
  local world out
  world=$(make_world pending-note)
  upstream_commit "$world" upstream-one
  sweep "$world" >/dev/null || fail "first sweep failed"
  upstream_commit "$world" upstream-two
  out=$(sweep "$world") || fail "second sweep failed: $out"

  assert_contains "$out" "no new intake" "a pending note suppresses a second intake"
  assert_contains "$out" "still waiting for firstmate" "the reason names the pending note"
  [ "$(note_count "$world")" = 1 ] || fail "a second note was queued alongside the pending one"
  [ "$(wake_count "$world")" = 1 ] || fail "a second wake was queued"
  [ "$(record_field "$(state_of "$world")/last-success" result)" = intake-suppressed ] \
    || fail "the suppressed sweep was not recorded as a success"
  pass "a pending intake note suppresses duplicate intake"
}

# Stand in for the backlog owner. <held> is the item's held: field; an empty
# <state> makes the stub report the id as missing the way tasks-axi does.
install_tasks_axi_stub() { # <world> <state> <held> [hold_kind] [hold_reason]
  local world=$1 state=$2 held=$3 kind=${4:-captain} reason=${5:-a recorded reason} fakebin
  fakebin=$(fm_fakebin "$world")
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ] && [ "\${2:-}" = upstream-drift-alert ]; then
  if [ -z "$state" ]; then
    printf 'error: "Task \\"upstream-drift-alert\\" not found in this backlog"\ncode: NOT_FOUND\n'
    exit 1
  fi
  printf 'task:\n  id: upstream-drift-alert\n  state: $state\n  held: $held\n'
  printf '  hold_reason: $reason\n  hold_kind: $kind\n  hold_until: "-"\n'
  exit 0
fi
printf 'error: "not found"\ncode: NOT_FOUND\n'
exit 1
SH
  chmod +x "$fakebin/tasks-axi"
  printf '%s\n' "$fakebin"
}

test_open_backlog_item_suppresses_intake() {
  local world out fakebin
  world=$(make_world open-item)
  fakebin=$(install_tasks_axi_stub "$world" queued no)
  : > "$world/home/data/backlog.md"
  upstream_commit "$world" upstream-one
  out=$(sweep "$world" PATH="$fakebin:$PATH") || fail "sweep failed: $out"

  assert_contains "$out" "backlog item upstream-drift-alert is filed and not held" \
    "a filed, unheld backlog item suppresses intake"
  [ "$(note_count "$world")" = 0 ] || fail "intake was queued beside an open backlog item"
  pass "a filed, unheld reconciliation backlog item suppresses duplicate intake"
}

# The captain's existing upstream-drift-alert item is HELD. Suppressing on it
# would leave the whole routine inert for as long as the hold stands, which is
# the opposite of turning a held reminder into an actionable request.
test_held_backlog_item_does_not_suppress_intake() {
  local world out fakebin body
  world=$(make_world held-item)
  fakebin=$(install_tasks_axi_stub "$world" queued yes)
  : > "$world/home/data/backlog.md"
  upstream_commit "$world" upstream-one
  out=$(sweep "$world" PATH="$fakebin:$PATH") || fail "sweep failed: $out"

  assert_contains "$out" "intake-published" "a held item does not make the routine inert"
  [ "$(note_count "$world")" = 1 ] || fail "a held item suppressed the intake note"
  [ "$(record_field "$(state_of "$world")/last-success" backlog_item)" = held ] \
    || fail "the outcome record did not note the held backlog item"

  body=$(cat "$world"/home/state/inbox/*.note)
  assert_contains "$body" "is HELD" "the note says the item is held"
  assert_contains "$body" "captain-hold-lifecycle" \
    "the note routes the hold to its own owner rather than judging it"
  assert_contains "$body" "do not file a duplicate item" \
    "the note routes firstmate to the existing item rather than a duplicate"
  assert_not_contains "$body" "unhold" \
    "a detection sweep must not ask for a hold to be released"

  # Still exactly one note per upstream head: the held item is not a licence to
  # re-report the same drift every day.
  ack_notes "$world"
  out=$(sweep "$world" PATH="$fakebin:$PATH") || fail "second sweep failed: $out"
  assert_contains "$out" "already published" "a held item still gets one note per head"
  [ "$(note_count "$world")" = 0 ] || fail "the held item re-reported the same head"
  pass "a held backlog item is reported once per head instead of silencing the routine"
}

# The same id can be held as a LANDING gate on a reconciliation already under
# review. A detection sweep cannot tell that apart from the legacy reminder and
# has no authority over either, so it reports the recorded hold verbatim and
# never asks for a release.
test_held_for_landing_approval_reports_without_claiming_authority() {
  local world out fakebin body
  world=$(make_world held-landing-gate)
  fakebin=$(install_tasks_axi_stub "$world" in_flight yes captain \
    "merge reviewed and ready; captain approves the local landing")
  : > "$world/home/data/backlog.md"
  upstream_commit "$world" upstream-one
  out=$(sweep "$world" PATH="$fakebin:$PATH") || fail "sweep failed: $out"
  [ "$(note_count "$world")" = 1 ] || fail "the landing-gate hold suppressed the first note"
  ack_notes "$world"

  # Upstream moves while the landing decision is still outstanding: exactly one
  # further note, because the pinned merge under review is now behind again.
  upstream_commit "$world" upstream-two
  out=$(sweep "$world" PATH="$fakebin:$PATH") || fail "second sweep failed: $out"
  assert_contains "$out" "intake-published" "a moved head is reported past a landing hold"
  [ "$(note_count "$world")" = 1 ] || fail "expected exactly one note for the moved head"

  body=$(cat "$world"/home/state/inbox/*.note)
  assert_contains "$body" "captain approves the local landing" \
    "the note repeats the hold's own recorded reason instead of characterizing it"
  assert_contains "$body" "hold_kind=captain" "the note repeats the recorded hold kind"
  assert_contains "$body" "grants no authority to release it" \
    "the note says plainly that detection carries no release authority"
  assert_contains "$body" "captain-hold-lifecycle" "the note routes the hold to its owner"
  assert_not_contains "$body" "unhold" "a landing gate is never asked to be lifted"
  assert_not_contains "$body" "deferred reminder rather than" \
    "the note does not assert which kind of hold this is"

  # And still no re-report while that head stands.
  ack_notes "$world"
  out=$(sweep "$world" PATH="$fakebin:$PATH") || fail "third sweep failed: $out"
  assert_contains "$out" "already published" "the landing hold is not nagged every day"
  pass "a landing-approval hold is reported once per head with no claim of release authority"
}

# tasks-axi failing for any reason other than "no such task" must not read as
# "nothing is filed": the sweep proceeds and says it could not check.
test_unreadable_backlog_backend_is_disclosed_not_assumed() {
  local world out fakebin body
  world=$(make_world backend-unreadable)
  fakebin=$(fm_fakebin "$world")
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf 'error: "backlog backend unavailable"\ncode: BACKEND_ERROR\n' >&2
exit 3
SH
  chmod +x "$fakebin/tasks-axi"
  : > "$world/home/data/backlog.md"
  upstream_commit "$world" upstream-one
  out=$(sweep "$world" PATH="$fakebin:$PATH") || fail "sweep failed: $out"

  assert_contains "$out" "intake-published" "an unreadable backlog does not suppress intake"
  [ "$(record_field "$(state_of "$world")/last-success" backlog_item)" = unknown ] \
    || fail "an unreadable backlog was recorded as something other than unknown"
  body=$(cat "$world"/home/state/inbox/*.note)
  assert_contains "$body" "could not be read" "the note discloses that it could not check"
  pass "an unreadable backlog backend is disclosed rather than read as no item"
}

test_acked_note_without_new_upstream_head_stays_quiet() {
  local world out
  world=$(make_world acked-same-head)
  upstream_commit "$world" upstream-one
  sweep "$world" >/dev/null || fail "first sweep failed"
  ack_notes "$world"
  out=$(sweep "$world") || fail "second sweep failed: $out"

  assert_contains "$out" "already published" \
    "the same upstream head is not re-reported after the note is handled"
  [ "$(note_count "$world")" = 0 ] || fail "the same head queued a fresh note"
  pass "an unreconciled fork is not re-reported every day"
}

test_acked_note_with_a_new_upstream_head_reports_again() {
  local world out
  world=$(make_world acked-new-head)
  upstream_commit "$world" upstream-one
  sweep "$world" >/dev/null || fail "first sweep failed"
  ack_notes "$world"
  upstream_commit "$world" upstream-two
  out=$(sweep "$world") || fail "third sweep failed: $out"

  assert_contains "$out" "intake-published" "genuinely new upstream work is reported again"
  [ "$(note_count "$world")" = 1 ] || fail "expected one fresh note for the moved head"
  pass "a moved upstream head reopens intake after the previous note was handled"
}

# --- failure handling -------------------------------------------------------

test_offline_fetch_is_distinct_from_no_change() {
  local world out status sync fakebin
  world=$(make_world offline)
  sync=$(state_of "$world")
  fakebin=$(install_git_stub "$world" fail)
  set +e
  out=$(sweep "$world" PATH="$fakebin:$PATH")
  status=$?
  set -e

  expect_code 2 "$status" "an unreachable upstream"
  assert_contains "$out" "upstream was not reached" "offline is reported as offline"
  assert_not_contains "$out" "no-change" "an offline sweep never claims no-change"
  [ "$(record_field "$sync/last-failure" reason)" = fetch-failed ] \
    || fail "last-failure did not record reason=fetch-failed"
  [ -f "$sync/last-success" ] && fail "a failed fetch wrote a success record"
  [ "$(note_count "$world")" = 1 ] || fail "the first failure of an episode was not announced"
  pass "an offline fetch is recorded and announced distinctly from no-change"
}

test_repeated_failure_announces_once_but_records_every_time() {
  local world sync fakebin first second
  world=$(make_world repeat-failure)
  sync=$(state_of "$world")
  fakebin=$(install_git_stub "$world" fail)
  sweep "$world" PATH="$fakebin:$PATH" >/dev/null 2>&1 || true
  first=$(record_field "$sync/last-failure" at)
  [ "$(note_count "$world")" = 1 ] || fail "the first failure was not announced"
  sleep 1
  sweep "$world" PATH="$fakebin:$PATH" >/dev/null 2>&1 || true
  second=$(record_field "$sync/last-failure" at)

  [ "$(note_count "$world")" = 1 ] || fail "a repeat failure announced itself again"
  [ "$first" != "$second" ] || fail "a repeat failure did not refresh the durable record"
  pass "a continuing failure stays durable without re-announcing itself"
}

# A failure that could not be announced must NOT be marked as announced. The
# other way round, one unwritable inbox would silence that reason forever.
test_unannounced_failure_is_retried_not_marked_announced() {
  local world sync fakebin out status
  world=$(make_world failure-unannounceable)
  sync=$(state_of "$world")
  fakebin=$(install_git_stub "$world" fail)
  mkdir -p "$world/home/state/inbox"
  chmod 500 "$world/home/state/inbox"
  set +e
  out=$(sweep "$world" PATH="$fakebin:$PATH")
  status=$?
  set -e
  chmod 700 "$world/home/state/inbox"

  expect_code 2 "$status" "a failed fetch whose note could not be queued"
  [ "$(record_field "$sync/last-failure" reason)" = fetch-failed ] \
    || fail "the failure itself was not recorded durably"
  [ -f "$sync/failure-episode" ] && fail "an unpublished note was marked as announced"
  [ "$(note_count "$world")" = 0 ] || fail "a note was queued into an unwritable inbox"

  sweep "$world" PATH="$fakebin:$PATH" >/dev/null 2>&1 || true
  [ "$(note_count "$world")" = 1 ] || fail "the next sweep did not retry the announcement"
  pass "a failure that could not be announced is retried instead of silenced"
}

# A pending FAILURE note is a different fact from a pending intake request. It
# must not stand in for one and suppress the reconciliation the sweep found.
test_pending_failure_note_does_not_suppress_intake() {
  local world out fakebin body
  world=$(make_world failure-note-vs-intake)
  fakebin=$(install_git_stub "$world" fail)
  sweep "$world" PATH="$fakebin:$PATH" >/dev/null 2>&1 || true
  [ "$(note_count "$world")" = 1 ] || fail "the failure was not announced"

  # Upstream comes back and has moved; the failure note is still unhandled.
  upstream_commit "$world" upstream-one
  out=$(sweep "$world") || fail "recovery sweep failed: $out"

  assert_contains "$out" "intake-published" \
    "a pending failure note did not suppress the reconciliation request"
  [ "$(note_count "$world")" = 2 ] || fail "expected the failure note plus one intake note"
  body=$(grep -lF '[upstream-sync:intake]' "$world"/home/state/inbox/*.note | wc -l)
  [ "$((body))" = 1 ] || fail "expected exactly one intake note beside the failure note"
  pass "a pending failure note does not stand in for a pending intake request"
}

# The built-in fallback, on a host with no usable timeout(1), against a fetch
# that ignores SIGTERM: `kill -TERM` plus `wait` would hang here forever.
test_fetch_bound_holds_when_the_fetch_ignores_sigterm() {
  local world out status sync fakebin started elapsed
  world=$(make_world stalled-hard)
  sync=$(state_of "$world")
  fakebin=$(install_git_stub "$world" stall-hard)
  started=$(date +%s)
  set +e
  out=$(sweep "$world" PATH="$fakebin:$PATH" \
    FM_UPSTREAM_SYNC_TIMEOUT_TOOL=none \
    FM_UPSTREAM_SYNC_FETCH_TIMEOUT=2 \
    FM_UPSTREAM_SYNC_FETCH_KILL_GRACE=2)
  status=$?
  set -e
  elapsed=$(( $(date +%s) - started ))

  expect_code 2 "$status" "a fetch that ignores SIGTERM"
  assert_contains "$out" "fetch-timeout" "the escalated kill is still reported as a timeout"
  [ "$(record_field "$sync/last-failure" reason)" = fetch-timeout ] \
    || fail "last-failure did not record reason=fetch-timeout"
  [ "$elapsed" -lt 30 ] || fail \
    "a TERM-ignoring fetch ran ${elapsed}s past its 2s bound plus 2s kill grace"
  pass "the fetch bound escalates to SIGKILL instead of waiting forever"
}

test_stalled_fetch_is_bounded_and_reported_as_a_timeout() {
  local world out status sync fakebin started elapsed
  world=$(make_world stalled)
  sync=$(state_of "$world")
  fakebin=$(install_git_stub "$world" stall)
  started=$(date +%s)
  set +e
  out=$(sweep "$world" PATH="$fakebin:$PATH" FM_UPSTREAM_SYNC_FETCH_TIMEOUT=2)
  status=$?
  set -e
  elapsed=$(( $(date +%s) - started ))

  expect_code 2 "$status" "a stalled fetch"
  assert_contains "$out" "fetch-timeout" "a stalled fetch is reported as a timeout"
  [ "$(record_field "$sync/last-failure" reason)" = fetch-timeout ] \
    || fail "last-failure did not record reason=fetch-timeout"
  [ "$elapsed" -lt 30 ] || fail "a stalled fetch ran ${elapsed}s past its 2s bound"
  pass "a stalled fetch is bounded and recorded as a timeout"
}

test_unpublishable_intake_is_retried_by_the_next_sweep() {
  local world out status sync
  world=$(make_world intake-interrupted)
  sync=$(state_of "$world")
  upstream_commit "$world" upstream-one
  # Interrupt publication the way a full or unwritable disk would, after the
  # drift is measured and before any record claims it was announced.
  mkdir -p "$world/home/state/inbox"
  chmod 500 "$world/home/state/inbox"
  set +e
  out=$(sweep "$world")
  status=$?
  set -e
  chmod 700 "$world/home/state/inbox"

  expect_code 2 "$status" "an intake that could not be queued"
  assert_contains "$out" "the request was not queued" "a failed intake says so"
  [ -f "$sync/last-intake" ] && fail "last-intake claimed an intake that was never published"

  out=$(sweep "$world") || fail "the retry sweep failed: $out"
  assert_contains "$out" "intake-published" "the next sweep completes the interrupted intake"
  [ "$(note_count "$world")" = 1 ] || fail "the retry did not queue exactly one note"
  pass "an interrupted intake publication is retried, not silently dropped"
}

test_concurrent_sweeps_do_not_both_run() {
  local world fakebin out status sync
  world=$(make_world concurrent)
  sync=$(state_of "$world")
  fakebin=$(install_git_stub "$world" stall)
  ( sweep "$world" PATH="$fakebin:$PATH" FM_UPSTREAM_SYNC_FETCH_TIMEOUT=6 >/dev/null 2>&1 ) &
  local holder=$!
  sleep 2
  set +e
  out=$(sweep "$world")
  status=$?
  set -e
  wait "$holder" 2>/dev/null || true

  expect_code 3 "$status" "a sweep that found the lock held"
  assert_contains "$out" "already running" "the second sweep says why it did nothing"
  [ -f "$sync/last-success" ] && fail "the locked-out sweep wrote a success record"
  pass "overlapping sweeps are serialized by the lock"
}

# --- ownership boundaries ---------------------------------------------------

test_sweep_never_writes_the_backlog() {
  local world before after
  world=$(make_world backlog-untouched)
  printf '# Backlog\n\n## Queued\n' > "$world/home/data/backlog.md"
  before=$(cksum < "$world/home/data/backlog.md")
  upstream_commit "$world" upstream-one
  sweep "$world" >/dev/null || fail "sweep failed"
  after=$(cksum < "$world/home/data/backlog.md")

  [ "$before" = "$after" ] || fail "the sweep modified data/backlog.md"
  pass "a scheduled sweep never writes the backlog it has no lock for"
}

test_status_reports_records_without_touching_the_network() {
  local world out fakebin
  world=$(make_world status-view)
  upstream_commit "$world" upstream-one
  sweep "$world" >/dev/null || fail "sweep failed"
  # Any network use would go through this stub and fail loudly.
  fakebin=$(install_git_stub "$world" fail)
  out=$(env FM_ROOT_OVERRIDE="$world/fork" FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    PATH="$fakebin:$PATH" "$SYNC" status) || fail "status failed: $out"

  assert_contains "$out" "last successful sweep" "status shows the last success"
  assert_contains "$out" "last published intake" "status shows the last intake"
  [ "$(wake_count "$world")" = 1 ] || fail "status queued a wake"
  pass "status reports durable records without network or wakes"
}

# --- cron migration ---------------------------------------------------------

# Written as exact bytes, including the two trailing blank lines, because
# install-cron claims to preserve every unrelated line byte-for-byte and a
# variable round-trip would quietly drop trailing newlines before the test
# could check that claim.
write_cron_fixture() { # <file>
  cat > "$1" <<'CRON'
TZ=America/New_York
PATH=/home/orangepi/.local/bin:/usr/local/bin:/usr/bin:/bin

# Check 42macro KISS portfolio
0 10 * * * /usr/bin/python3 /home/orangepi/experiments/42macro/v1/monitor.py

# Weekly upstream-drift check for the pinned ui-ux-pro-max skill
15 4 * * 0 /home/orangepi/.local/bin/uiux-skill-drift-check.sh >/dev/null 2>&1

# Daily firstmate upstream-template drift sweep (detection only)
35 4 * * * /home/orangepi/.local/bin/fm-upstream-drift-check.sh >/dev/null 2>&1

# Archive the old checker rather than run it
LEGACY_TOOL=fm-upstream-drift-check.sh
0 5 * * * cp /home/orangepi/.local/bin/fm-upstream-drift-check.sh /mnt/nas/backups/

# Nightly WealthSync deploy
30 2 * * * /home/orangepi/.local/bin/wealthsync-autodeploy.sh >/dev/null 2>&1


CRON
}

# A crontab stub backed by a file. <mode> picks which read behavior it models:
#   fixture     a readable crontab with the fixture above
#   none        this user has no crontab: non-zero plus the wording vixie-cron
#               and cronie both print, which IS an established empty crontab
#   unreadable  a backend failure: non-zero with nothing on either stream, the
#               shape that must never be mistaken for an empty crontab
install_crontab_stub() { # <world> [mode] -> echoes the fakebin
  local world=$1 mode=${2:-fixture} fakebin store
  fakebin=$(fm_fakebin "$world")
  store="$world/crontab.txt"
  rm -f "$store" "$world/crontab.unreadable"
  case "$mode" in
    fixture) write_cron_fixture "$store" ;;
    none) : ;;
    unreadable) : > "$world/crontab.unreadable" ;;
    *) fail "unknown crontab stub mode: $mode" ;;
  esac
  cat > "$fakebin/crontab" <<SH
#!/usr/bin/env bash
store="$store"
if [ -e "$world/crontab.unreadable" ]; then exit 1; fi
if [ "\${1:-}" = -l ]; then
  if [ ! -f "\$store" ]; then
    printf 'no crontab for %s\n' "\${USER:-tester}" >&2
    exit 1
  fi
  cat "\$store"
  exit 0
fi
if [ "\${1:-}" = - ]; then
  cat > "\$store"
  exit 0
fi
exit 2
SH
  chmod +x "$fakebin/crontab"
  printf '%s\n' "$fakebin"
}

CRON_PATH_FIXTURE=/opt/testbin:/usr/local/bin:/usr/bin:/bin

run_install() { # <world> <fakebin> [args...]
  local world=$1 fakebin=$2
  shift 2
  env FM_ROOT_OVERRIDE="$world/fork" FM_HOME="$world/home" \
      FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
      FM_UPSTREAM_SYNC_CRON_PATH="$CRON_PATH_FIXTURE" \
      PATH="$fakebin:$PATH" "$SYNC" install-cron "$@" 2>&1
}

test_install_cron_preserves_unrelated_entries_and_is_idempotent() {
  local world fakebin out installed second expected preserved
  world=$(make_world cron-install)
  fakebin=$(install_crontab_stub "$world")
  out=$(run_install "$world" "$fakebin") || fail "install-cron failed: $out"
  installed=$(cat "$world/crontab.txt")

  assert_contains "$installed" "TZ=America/New_York" "the TZ assignment survived"
  assert_contains "$installed" "PATH=/home/orangepi/.local/bin" "the PATH assignment survived"
  assert_contains "$installed" "42macro" "an unrelated job survived"
  assert_contains "$installed" "uiux-skill-drift-check.sh" \
    "the unrelated weekly upstream-drift job for another tool survived"
  assert_contains "$installed" "Weekly upstream-drift check for the pinned ui-ux-pro-max skill" \
    "the surviving job kept its own comment"
  assert_contains "$installed" "wealthsync-autodeploy.sh" "the nightly deploy survived"
  assert_not_contains "$installed" "35 4 * * * /home/orangepi/.local/bin/fm-upstream-drift-check.sh" \
    "the legacy job was removed"
  assert_not_contains "$installed" "Daily firstmate upstream-template drift sweep" \
    "the legacy job's own comment was removed with it"
  assert_contains "$installed" "35 4 * * * PATH='$CRON_PATH_FIXTURE' $world/fork/bin/fm-upstream-sync.sh sweep" \
    "the managed line kept the legacy schedule and carries a usable PATH"
  assert_contains "$installed" "upstream-sync/cron.log" \
    "the managed line records its output instead of discarding it"
  assert_contains "$out" "migrated off the legacy" "the migration is reported"
  assert_contains "$out" "replaced these lines" "the removed lines are named, not dropped silently"

  # An entry that merely NAMES the legacy script is not a scheduled call of it.
  assert_contains "$installed" "LEGACY_TOOL=fm-upstream-drift-check.sh" \
    "an environment assignment naming the legacy script survived"
  assert_contains "$installed" "cp /home/orangepi/.local/bin/fm-upstream-drift-check.sh" \
    "a backup job naming the legacy script survived"
  assert_contains "$out" "still mentions fm-upstream-drift-check.sh" \
    "a surviving mention of the legacy script is disclosed rather than assumed clean"

  # Byte-for-byte: everything except the two legacy lines is unchanged, in
  # order, including the fixture's trailing blank lines.
  expected="$world/expected.txt"
  preserved="$world/preserved.txt"
  write_cron_fixture "$expected"
  sed -i '/^# Daily firstmate upstream-template drift sweep/d;
          /^35 4 \* \* \* \/home\/orangepi\/\.local\/bin\/fm-upstream-drift-check\.sh/d' "$expected"
  head -n -2 "$world/crontab.txt" > "$preserved"
  diff -u "$expected" "$preserved" >/dev/null \
    || fail "unrelated crontab bytes were not preserved"$'\n'"$(diff -u "$expected" "$preserved")"

  run_install "$world" "$fakebin" >/dev/null || fail "second install-cron failed"
  second=$(cat "$world/crontab.txt")
  [ "$installed" = "$second" ] || fail \
    "install-cron is not idempotent"$'\n'"--- first ---"$'\n'"$installed"$'\n'"--- second ---"$'\n'"$second"
  pass "install-cron preserves unrelated entries byte-for-byte, migrates the legacy job, and is idempotent"
}

test_install_cron_dry_run_changes_nothing() {
  local world fakebin before out after
  world=$(make_world cron-dry-run)
  fakebin=$(install_crontab_stub "$world")
  before=$(cksum < "$world/crontab.txt")
  out=$(run_install "$world" "$fakebin" --dry-run) || fail "dry run failed: $out"
  after=$(cksum < "$world/crontab.txt")

  [ "$before" = "$after" ] || fail "--dry-run modified the crontab"
  assert_contains "$out" "proposed crontab" "the dry run shows what it would install"
  assert_contains "$out" "fm-upstream-sync.sh sweep" "the dry run shows the managed line"
  assert_absent "$world/home/state/upstream-sync" \
    "--dry-run created the record directory it only claimed it would use"
  pass "install-cron --dry-run previews without installing"
}

test_install_cron_reports_the_held_reconciliation_item() {
  local world fakebin out
  world=$(make_world cron-held-item)
  fakebin=$(install_crontab_stub "$world")
  install_tasks_axi_stub "$world" queued yes >/dev/null
  : > "$world/home/data/backlog.md"
  out=$(run_install "$world" "$fakebin") || fail "install-cron failed: $out"

  assert_contains "$out" "MIGRATION" "the migration names the existing request"
  assert_contains "$out" "is HELD" "the held legacy request is surfaced, not silently suppressed"
  assert_contains "$out" "will queue one intake note naming it" \
    "the migration says the routine is not inert while the hold stands"
  assert_contains "$out" "cannot release a hold" \
    "the migration disclaims any authority over the hold"
  assert_contains "$out" "captain-hold-lifecycle" "the migration routes the hold to its owner"
  assert_not_contains "$out" "unhold" "the migration never asks for the hold to be lifted"
  assert_contains "$out" "Do not leave it held and unmentioned" \
    "the hand-off says who owns the item"
  pass "install-cron surfaces the held legacy request and what the sweep will do with it"
}

test_install_cron_on_a_user_with_no_crontab() {
  local world fakebin out installed
  world=$(make_world cron-empty)
  fakebin=$(install_crontab_stub "$world" none)
  out=$(run_install "$world" "$fakebin") || fail "install-cron failed: $out"
  installed=$(cat "$world/crontab.txt")

  assert_contains "$installed" "fm-upstream-sync.sh sweep" "the managed line was installed"
  [ "$(printf '%s\n' "$installed" | head -1)" = \
    "# fm-upstream-sync (managed by bin/fm-upstream-sync.sh install-cron)" ] \
    || fail "a first crontab gained leading blank lines"
  pass "install-cron works for a user who has no crontab yet"
}

# The dangerous shape: non-zero exit with nothing on stdout. Read as "empty",
# it would replace every entry the user has with one managed line.
test_install_cron_fails_closed_on_an_unreadable_crontab() {
  local world fakebin out status
  world=$(make_world cron-unreadable)
  fakebin=$(install_crontab_stub "$world" unreadable)
  set +e
  out=$(run_install "$world" "$fakebin")
  status=$?
  set -e

  expect_code 1 "$status" "an unreadable crontab"
  assert_contains "$out" "could not read the current crontab" "the refusal says what failed"
  assert_contains "$out" "refusing to install" "the refusal says it did not install"
  [ -f "$world/crontab.txt" ] && fail "a failed read still wrote a crontab"
  pass "an unreadable crontab fails closed instead of being replaced as empty"
}

# Not "replace the working PATH with defaults": keep the captured directories
# that actually provide a tool the sweep needs, drop the ones that provide
# none, and collapse the duplication a nested agent host accumulates.
test_install_cron_keeps_only_useful_captured_path_entries() {
  local world fakebin junk out line
  world=$(make_world cron-path-filter)
  fakebin=$(install_crontab_stub "$world")
  install_tasks_axi_stub "$world" "" no >/dev/null
  junk="$world/empty-bin"
  mkdir -p "$junk"

  out=$(env FM_ROOT_OVERRIDE="$world/fork" FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    PATH="$fakebin:$junk:/usr/bin:/usr/bin:/bin" \
    "$SYNC" install-cron 2>&1) || fail "install-cron failed: $out"
  line=$(grep -m1 "fm-upstream-sync.sh sweep" "$world/crontab.txt")

  assert_contains "$line" "$fakebin" "the directory providing tasks-axi was kept"
  assert_not_contains "$line" "$junk" "a captured directory providing nothing was kept"
  assert_contains "$line" "/usr/bin" "the directory providing git and coreutils was kept"
  [ "$(printf '%s\n' "$line" | grep -o '/usr/bin' | wc -l)" = 1 ] \
    || fail "the duplicated captured entry was carried into the crontab"$'\n'"$line"
  assert_contains "$out" "cron resolves tasks-axi" \
    "the install verifies the generated environment rather than assuming it"
  pass "the cron PATH keeps the captured directories that carry a needed tool and drops the rest"
}

# Assuming the generated line works is how a scheduled job ends up unable to run
# its own helpers, so the environment is resolved the way cron would resolve it.
test_install_cron_refuses_a_cron_environment_that_cannot_run_the_sweep() {
  local world fakebin out status before
  world=$(make_world cron-path-unusable)
  fakebin=$(install_crontab_stub "$world")
  before=$(cksum < "$world/crontab.txt")
  set +e
  out=$(env FM_ROOT_OVERRIDE="$world/fork" FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_UPSTREAM_SYNC_CRON_PATH="$world/nowhere" \
    PATH="$fakebin:$PATH" "$SYNC" install-cron 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "a cron PATH that resolves nothing"
  assert_contains "$out" "could not resolve" "the refusal names what is missing"
  assert_contains "$out" "git" "the refusal names the missing binaries"
  [ "$before" = "$(cksum < "$world/crontab.txt")" ] \
    || fail "an unusable cron environment was still installed"
  pass "install-cron verifies the generated cron environment instead of assuming it"
}

test_install_cron_refuses_a_path_cron_would_mangle() {
  local world fakebin out status before
  world=$(make_world cron-bad-path)
  fakebin=$(install_crontab_stub "$world")
  before=$(cksum < "$world/crontab.txt")
  set +e
  out=$(env FM_ROOT_OVERRIDE="$world/fork" FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_UPSTREAM_SYNC_CRON_PATH="/opt/my tools/bin:/usr/bin" \
    PATH="$fakebin:$PATH" "$SYNC" install-cron 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "a PATH containing whitespace"
  assert_contains "$out" "whitespace" "the refusal names the problem"
  [ "$before" = "$(cksum < "$world/crontab.txt")" ] || fail "a refused install changed the crontab"
  pass "install-cron refuses a cron PATH it cannot represent instead of installing a broken line"
}

test_no_drift_is_a_recorded_success
test_fork_only_commits_are_not_drift
test_new_upstream_commits_publish_one_intake
test_pending_note_suppresses_a_second_intake
test_open_backlog_item_suppresses_intake
test_held_backlog_item_does_not_suppress_intake
test_held_for_landing_approval_reports_without_claiming_authority
test_unreadable_backlog_backend_is_disclosed_not_assumed
test_acked_note_without_new_upstream_head_stays_quiet
test_acked_note_with_a_new_upstream_head_reports_again
test_offline_fetch_is_distinct_from_no_change
test_repeated_failure_announces_once_but_records_every_time
test_unannounced_failure_is_retried_not_marked_announced
test_pending_failure_note_does_not_suppress_intake
test_stalled_fetch_is_bounded_and_reported_as_a_timeout
test_fetch_bound_holds_when_the_fetch_ignores_sigterm
test_unpublishable_intake_is_retried_by_the_next_sweep
test_concurrent_sweeps_do_not_both_run
test_sweep_never_writes_the_backlog
test_status_reports_records_without_touching_the_network
test_install_cron_preserves_unrelated_entries_and_is_idempotent
test_install_cron_dry_run_changes_nothing
test_install_cron_reports_the_held_reconciliation_item
test_install_cron_on_a_user_with_no_crontab
test_install_cron_fails_closed_on_an_unreadable_crontab
test_install_cron_keeps_only_useful_captured_path_entries
test_install_cron_refuses_a_cron_environment_that_cannot_run_the_sweep
test_install_cron_refuses_a_path_cron_would_mangle
