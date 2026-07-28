#!/usr/bin/env bash
# tests/fm-tmp-sweep.test.sh - end-to-end behavior of bin/fm-tmp-sweep.sh, the
# periodic /tmp cleanup (docs/configuration.md "/tmp sweep and cleanup"). Runs
# the REAL, unmodified script as a subprocess against a fixture tree via
# FM_TMP_SWEEP_ROOT (a test-only override the script exposes for exactly this
# purpose - see its own header comment), with FM_ROOT_OVERRIDE pointing at a
# fake main firstmate home. Nothing here touches the machine's real /tmp.
#
# Covers age, liveness (including the blocking fix: a home's own top-level
# session, which is never spawned and so never has a state/*.meta of its own,
# must still survive), the symlink-escape guard, and the open-file-handle
# guard. bin/fm-tmp-lib.sh's functions are unit-tested directly in
# tests/fm-tmp-lib.test.sh; this file proves the sweep script actually wires
# them into its removal decision end to end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-tmp-lib.sh
. "$ROOT/bin/fm-tmp-lib.sh"

SWEEP="$ROOT/bin/fm-tmp-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-tmp-sweep-tests)
UIDN=$(id -u)

run_sweep_dry() {  # <fake_tmp_root> <main_home> <log_dir>
  FM_TMP_SWEEP_ROOT="$1" FM_ROOT_OVERRIDE="$2" FM_TMP_SWEEP_LOG="$3/sweep.log" "$SWEEP" 2>&1
}

run_sweep_apply() {  # <fake_tmp_root> <main_home> <log_dir>
  FM_TMP_SWEEP_ROOT="$1" FM_ROOT_OVERRIDE="$2" FM_TMP_SWEEP_LOG="$3/sweep.log" "$SWEEP" --apply 2>&1
}

# Backdate a path (and everything under it) well past the 48h default age
# threshold; newest_mtime_age scans the whole tree, not just the top entry.
backdate() {
  find "$1" -exec touch -d '10 days ago' {} +
}

test_sweep_live_session_scratch_survives_despite_old_mtime() {
  # The finding-1 case, explicitly: a live session (here, the main home's own
  # top-level session, which fm-spawn.sh never spawns and so never records in
  # state/*.meta) whose harness scratch has an old mtime must survive on
  # liveness alone, not on being freshly written to.
  local dir fake main scratch out
  dir="$TMP_ROOT/live-home"; mkdir -p "$dir"; fake="$dir/fake-tmp"; main="$dir/main-home"
  mkdir -p "$fake/claude-$UIDN" "$main/state"
  scratch="$fake/claude-$UIDN/$(fm_tmp_claude_sanitize "$main")"
  mkdir -p "$scratch"
  printf 'session state\n' > "$scratch/session.json"
  backdate "$scratch"
  out=$(run_sweep_apply "$fake" "$main" "$dir")
  [ -d "$scratch" ] || fail "the main home's own scratch was removed despite being live: $out"
  assert_contains "$out" "live worktree's harness scratch" "sweep did not credit the main home's scratch as live"
  pass "the main home's own harness scratch survives an --apply sweep despite an old mtime"
}

test_sweep_secondmate_home_scratch_survives_despite_old_mtime() {
  # One level deep: a secondmate's own top-level session is equally never
  # spawned, so it needs the same synthesized liveness as the main home.
  local dir fake main sm scratch out
  dir="$TMP_ROOT/live-sm"; mkdir -p "$dir"; fake="$dir/fake-tmp"; main="$dir/main-home"; sm="$dir/sm-home"
  mkdir -p "$fake/claude-$UIDN" "$main/state" "$sm/state"
  fm_write_secondmate_meta "$main/state/domain.meta" "$sm"
  scratch="$fake/claude-$UIDN/$(fm_tmp_claude_sanitize "$sm")"
  mkdir -p "$scratch"
  backdate "$scratch"
  out=$(run_sweep_apply "$fake" "$main" "$dir")
  [ -d "$scratch" ] || fail "the secondmate home's own scratch was removed despite being live: $out"
  pass "a secondmate home's own harness scratch survives an --apply sweep despite an old mtime"
}

test_sweep_live_task_scratch_and_tmproot_survive() {
  local dir fake main wt task_scratch task_tmproot out
  dir="$TMP_ROOT/live-task"; mkdir -p "$dir"; fake="$dir/fake-tmp"; main="$dir/main-home"; wt="$dir/task-wt"
  mkdir -p "$fake/claude-$UIDN" "$main/state" "$wt"
  fm_write_meta "$main/state/mytask.meta" \
    "window=fakeses:fm-mytask" "worktree=$wt" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  task_scratch="$fake/claude-$UIDN/$(fm_tmp_claude_sanitize "$wt")"
  task_tmproot="$fake/fm-mytask"
  mkdir -p "$task_scratch" "$task_tmproot"
  printf 'x\n' > "$task_tmproot/gotmp-artifact"
  backdate "$task_scratch"
  backdate "$task_tmproot"
  out=$(run_sweep_apply "$fake" "$main" "$dir")
  [ -d "$task_scratch" ] || fail "a live task's harness scratch was removed: $out"
  [ -d "$task_tmproot" ] || fail "a live task's /tmp/fm-<id> root was removed: $out"
  assert_contains "$out" "live task tmp root" "sweep did not credit fm-mytask as a live task tmp root"
  pass "a live task's harness scratch and /tmp/fm-<id> root both survive an --apply sweep"
}

test_sweep_unregistered_old_entries_removed_on_apply() {
  local dir fake main garbage_scratch garbage_tmproot out
  dir="$TMP_ROOT/garbage"; mkdir -p "$dir"; fake="$dir/fake-tmp"; main="$dir/main-home"
  mkdir -p "$fake/claude-$UIDN" "$main/state"
  garbage_scratch="$fake/claude-$UIDN/$(fm_tmp_claude_sanitize "$dir/nobody-owns-this-worktree")"
  garbage_tmproot="$fake/fm-not-a-real-task-id"
  mkdir -p "$garbage_scratch" "$garbage_tmproot"
  printf 'tmpNNN.db\n' > "$garbage_scratch/leftover"
  printf 'tmpNNN.db\n' > "$garbage_tmproot/leftover"
  backdate "$garbage_scratch"
  backdate "$garbage_tmproot"
  out=$(run_sweep_apply "$fake" "$main" "$dir")
  [ ! -e "$garbage_scratch" ] || fail "an old, unregistered claude-scratch entry survived --apply: $out"
  [ ! -e "$garbage_tmproot" ] || fail "an old, unregistered fm-<id> tmp root survived --apply: $out"
  assert_contains "$out" "removed:" "sweep did not report a removal for the unregistered garbage"
  pass "an old entry with no live registration anywhere is removed by --apply"
}

test_sweep_fresh_unregistered_entry_survives_due_to_age() {
  # Age protects independently of liveness: a brand new, entirely unregistered
  # entry must still survive because it has not crossed the age threshold yet.
  local dir fake main fresh_scratch out
  dir="$TMP_ROOT/fresh"; mkdir -p "$dir"; fake="$dir/fake-tmp"; main="$dir/main-home"
  mkdir -p "$fake/claude-$UIDN" "$main/state"
  fresh_scratch="$fake/claude-$UIDN/$(fm_tmp_claude_sanitize "$dir/brand-new-unregistered-worktree")"
  mkdir -p "$fresh_scratch"
  printf 'just written\n' > "$fresh_scratch/file"
  # No backdate: mtime is "now".
  out=$(run_sweep_apply "$fake" "$main" "$dir")
  [ -d "$fresh_scratch" ] || fail "a fresh, unregistered entry was removed before it aged past the threshold: $out"
  assert_contains "$out" "within 48h threshold" "sweep did not report the fresh entry as protected by age"
  pass "a fresh, entirely unregistered entry survives --apply on age alone"
}

test_sweep_dry_run_reports_without_removing() {
  local dir fake main garbage_scratch out
  dir="$TMP_ROOT/dryrun"; mkdir -p "$dir"; fake="$dir/fake-tmp"; main="$dir/main-home"
  mkdir -p "$fake/claude-$UIDN" "$main/state"
  garbage_scratch="$fake/claude-$UIDN/$(fm_tmp_claude_sanitize "$dir/dry-run-candidate")"
  mkdir -p "$garbage_scratch"
  printf 'x\n' > "$garbage_scratch/file"
  backdate "$garbage_scratch"
  out=$(run_sweep_dry "$fake" "$main" "$dir")
  [ -d "$garbage_scratch" ] || fail "a dry run (no --apply) actually removed something"
  assert_contains "$out" "would-remove:" "dry run did not report a would-remove decision"
  pass "a dry run reports what it would remove without changing anything"
}

test_sweep_symlink_escape_never_removed() {
  local dir fake main outside link out
  dir="$TMP_ROOT/symlink"; mkdir -p "$dir"; fake="$dir/fake-tmp"; main="$dir/main-home"
  outside="$dir/outside-target"; link="$fake/escape-link"
  mkdir -p "$fake" "$main/state" "$outside"
  printf 'must never be touched\n' > "$outside/precious"
  ln -s "$outside" "$link"
  backdate "$outside"
  out=$(run_sweep_apply "$fake" "$main" "$dir")
  [ -e "$outside/precious" ] || fail "a symlink escaping the swept root led to real removal outside it: $out"
  [ -L "$link" ] || fail "the escaping symlink itself was removed instead of just skipped"
  assert_contains "$out" "symlink-escape guard" "sweep did not report the symlink-escape guard reason"
  pass "a top-level symlink resolving outside the swept root is always skipped, never followed for removal"
}

test_sweep_open_handle_protects_even_when_stale_and_unregistered() {
  local dir fake main target heldfile out holder_pid
  dir="$TMP_ROOT/openhandle"; mkdir -p "$dir"; fake="$dir/fake-tmp"; main="$dir/main-home"
  mkdir -p "$fake/claude-$UIDN" "$main/state"
  target="$fake/claude-$UIDN/$(fm_tmp_claude_sanitize "$dir/held-open-unregistered-worktree")"
  mkdir -p "$target"
  heldfile="$target/open.log"
  printf 'still writing\n' > "$heldfile"
  backdate "$target"
  tail -f "$heldfile" >/dev/null 2>&1 &
  holder_pid=$!
  sleep 0.3   # let tail actually open the fd before the sweep's lsof scan runs
  out=$(run_sweep_apply "$fake" "$main" "$dir")
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  [ -d "$target" ] || fail "an old, unregistered entry with an open file handle was removed anyway: $out"
  assert_contains "$out" "open file handle" "sweep did not report the open-handle guard reason"
  pass "an old, unregistered entry with a live open file handle survives --apply"
}

test_sweep_protected_service_name_never_removed() {
  local dir fake main protected out
  dir="$TMP_ROOT/protected"; mkdir -p "$dir"; fake="$dir/fake-tmp"; main="$dir/main-home"
  protected="$fake/tmux-$UIDN"
  mkdir -p "$protected" "$main/state"
  printf 'socket-placeholder\n' > "$protected/default"
  backdate "$protected"
  out=$(run_sweep_apply "$fake" "$main" "$dir")
  [ -d "$protected" ] || fail "a well-known protected-prefix service path was removed: $out"
  assert_contains "$out" "protected system/service path" "sweep did not report the protected-name reason"
  pass "a well-known protected service path (tmux- prefix) is never removed regardless of age or liveness"
}

test_sweep_live_session_scratch_survives_despite_old_mtime
test_sweep_secondmate_home_scratch_survives_despite_old_mtime
test_sweep_live_task_scratch_and_tmproot_survive
test_sweep_unregistered_old_entries_removed_on_apply
test_sweep_fresh_unregistered_entry_survives_due_to_age
test_sweep_dry_run_reports_without_removing
test_sweep_symlink_escape_never_removed
test_sweep_open_handle_protects_even_when_stale_and_unregistered
test_sweep_protected_service_name_never_removed
