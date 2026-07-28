#!/usr/bin/env bash
# tests/fm-tmp-lib.test.sh - bin/fm-tmp-lib.sh, the shared "which sessions are
# live" implementation both bin/fm-tmp-sweep.sh's periodic /tmp cleanup and
# bin/fm-teardown.sh's per-task harness-scratch cleanup source. Exercises the
# functions directly (sourced, not a subprocess): fm_tmp_live_homes discovery
# of a main home plus its live secondmate homes, fm_tmp_live_tasks's real
# spawned-task entries AND its synthesized per-home "own top-level session"
# entry (the blocking fix: neither the primary checkout nor a secondmate's own
# top-level instance is ever spawned by fm-spawn.sh, so without a synthesized
# entry neither would ever be recorded live), the sentinel ID's collision
# safety against fm-pr-lib.sh's real task-ID validator, the Claude Code scratch
# sanitizer, and the harness-scratch-dir seam's fail-closed behavior for an
# unverified harness. End-to-end sweep behavior (does a live entry actually
# survive a real sweep run) lives in tests/fm-tmp-sweep.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-tmp-lib.sh
. "$ROOT/bin/fm-tmp-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tmp-lib-tests)

# --- fm_tmp_live_homes -------------------------------------------------------

test_live_homes_lists_main_home_first_with_no_secondmates() {
  local main homes
  main="$TMP_ROOT/main-solo"
  mkdir -p "$main/state"
  homes=$(fm_tmp_live_homes "$main")
  [ "$homes" = "$main" ] || fail "expected exactly the main home with no secondmates, got: $homes"
  pass "fm_tmp_live_homes lists just the main home when it has no live secondmates"
}

test_live_homes_discovers_live_secondmate_home() {
  local main sm homes
  main="$TMP_ROOT/main-with-sm"; sm="$TMP_ROOT/sm-home-a"
  mkdir -p "$main/state" "$sm/state"
  fm_write_secondmate_meta "$main/state/domain.meta" "$sm"
  homes=$(fm_tmp_live_homes "$main")
  assert_contains "$homes" "$main" "main home missing from fm_tmp_live_homes output"
  assert_contains "$homes" "$sm" "live secondmate home missing from fm_tmp_live_homes output"
  pass "fm_tmp_live_homes discovers a live secondmate home from its kind=secondmate meta"
}

test_live_homes_skips_secondmate_whose_home_dir_is_gone() {
  local main sm homes
  main="$TMP_ROOT/main-stale-sm"; sm="$TMP_ROOT/sm-home-gone"
  mkdir -p "$main/state"   # $sm intentionally never created
  fm_write_secondmate_meta "$main/state/domain.meta" "$sm"
  homes=$(fm_tmp_live_homes "$main")
  assert_not_contains "$homes" "$sm" "a secondmate home= pointing at a nonexistent dir was still listed live"
  pass "fm_tmp_live_homes skips a secondmate meta whose recorded home no longer exists"
}

# --- fm_tmp_live_tasks: synthesized own-home entry (the blocking fix) -------

test_live_tasks_synthesizes_main_home_entry() {
  local main out
  main="$TMP_ROOT/main-synth"
  mkdir -p "$main/state"
  out=$(fm_tmp_live_tasks "$main")
  assert_contains "$out" "$(printf '%s\t%s' "$FM_TMP_SYNTHETIC_HOME_ID" "$main")" \
    "no synthesized entry for the main home's own top-level session"
  pass "fm_tmp_live_tasks synthesizes a live entry for the main home's own session, even with zero spawned tasks"
}

test_live_tasks_synthesizes_secondmate_home_entry_too() {
  local main sm out
  main="$TMP_ROOT/main-synth-sm"; sm="$TMP_ROOT/sm-synth"
  mkdir -p "$main/state" "$sm/state"
  fm_write_secondmate_meta "$main/state/domain.meta" "$sm"
  out=$(fm_tmp_live_tasks "$main")
  assert_contains "$out" "$(printf '%s\t%s' "$FM_TMP_SYNTHETIC_HOME_ID" "$main")" \
    "no synthesized entry for the main home"
  assert_contains "$out" "$(printf '%s\t%s' "$FM_TMP_SYNTHETIC_HOME_ID" "$sm")" \
    "no synthesized entry for the secondmate home's own top-level session"
  pass "fm_tmp_live_tasks synthesizes a live entry for a secondmate home's own session too, one level deep"
}

test_live_tasks_synthetic_id_is_rejected_by_real_task_id_validator() {
  # The sentinel must be structurally incapable of colliding with, or falsely
  # protecting, a real spawned task's /tmp/fm-<id> root - proven against the
  # actual validator fm-spawn.sh/fm-pr-lib.sh use for a real task id, not just
  # by inspection.
  if fm_task_id_path_safe "$FM_TMP_SYNTHETIC_HOME_ID"; then
    fail "sentinel home id '$FM_TMP_SYNTHETIC_HOME_ID' passed fm_task_id_path_safe; it could collide with a real task id"
  fi
  pass "the synthesized home id is rejected by fm_task_id_path_safe, so it can never collide with a real task id"
}

# --- fm_tmp_live_tasks: real spawned-task entries still work ----------------

test_live_tasks_lists_real_spawned_task_with_worktree() {
  local main wt out
  main="$TMP_ROOT/main-real-task"; wt="$TMP_ROOT/real-task-wt"
  mkdir -p "$main/state" "$wt"
  fm_write_meta "$main/state/mytask.meta" \
    "window=fakeses:fm-mytask" \
    "worktree=$wt" \
    "project=$TMP_ROOT/proj" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  out=$(fm_tmp_live_tasks "$main")
  assert_contains "$out" "$(printf 'mytask\t%s' "$wt")" "real spawned task's id/worktree pair missing from fm_tmp_live_tasks"
  pass "fm_tmp_live_tasks lists a real spawned task's id and worktree from its meta"
}

test_live_tasks_handles_meta_with_no_worktree_line() {
  local main out
  main="$TMP_ROOT/main-no-wt"
  mkdir -p "$main/state"
  fm_write_meta "$main/state/nowt.meta" \
    "window=fakeses:fm-nowt" \
    "harness=claude" \
    "kind=scout"
  # Must not crash, and must round-trip id with an empty worktree field rather
  # than misparsing the NEXT synthesized/real entry's data into this one's slot
  # (the leading-empty-field IFS-whitespace-stripping hazard this fix's own
  # implementation had to avoid).
  out=$(fm_tmp_live_tasks "$main")
  assert_contains "$out" "$(printf 'nowt\t')" "task with no worktree= line was not listed with an empty worktree field"
  pass "fm_tmp_live_tasks tolerates a meta with no worktree= line without misparsing"
}

test_live_tasks_covers_both_homes_and_real_tasks_together() {
  # The full shape fm-tmp-sweep.sh actually consumes: main home's own session,
  # a live secondmate's own session, AND a real task spawned under the main
  # home, all in one pass.
  local main sm wt out
  main="$TMP_ROOT/main-combo"; sm="$TMP_ROOT/sm-combo"; wt="$TMP_ROOT/combo-wt"
  mkdir -p "$main/state" "$sm/state" "$wt"
  fm_write_secondmate_meta "$main/state/domain.meta" "$sm"
  fm_write_meta "$main/state/realtask.meta" \
    "window=fakeses:fm-realtask" \
    "worktree=$wt" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  out=$(fm_tmp_live_tasks "$main")
  assert_contains "$out" "$(printf '%s\t%s' "$FM_TMP_SYNTHETIC_HOME_ID" "$main")" "main home's own session missing"
  assert_contains "$out" "$(printf '%s\t%s' "$FM_TMP_SYNTHETIC_HOME_ID" "$sm")" "secondmate home's own session missing"
  assert_contains "$out" "$(printf 'realtask\t%s' "$wt")" "real spawned task missing"
  pass "fm_tmp_live_tasks covers the main home's own session, a secondmate's own session, and a real task together"
}

# --- fm_tmp_claude_sanitize --------------------------------------------------

test_claude_sanitize_replaces_non_alnum_with_dash() {
  local out
  out=$(fm_tmp_claude_sanitize "/home/orangepi/.treehouse/firstmate-1954af/1/firstmate")
  case "$out" in
    *[!A-Za-z0-9-]*) fail "sanitized output still contains a non [A-Za-z0-9-] byte: $out" ;;
  esac
  assert_contains "$out" "firstmate" "sanitized output lost the alphanumeric run 'firstmate'"
  pass "fm_tmp_claude_sanitize maps every non-alphanumeric byte to '-'"
}

test_claude_sanitize_is_pure_alnum_passthrough() {
  local out
  out=$(fm_tmp_claude_sanitize "abcXYZ789")
  [ "$out" = "abcXYZ789" ] || fail "a pure alphanumeric string was altered: $out"
  pass "fm_tmp_claude_sanitize leaves a pure alphanumeric string unchanged"
}

# --- fm_tmp_harness_scratch_dir ----------------------------------------------

test_harness_scratch_dir_claude_matches_convention() {
  local out expect
  out=$(fm_tmp_harness_scratch_dir claude /some/worktree/path) || fail "claude harness returned nonzero"
  expect="/tmp/claude-$(id -u)/$(fm_tmp_claude_sanitize /some/worktree/path)"
  [ "$out" = "$expect" ] || fail "claude scratch dir mismatch: got '$out', expected '$expect'"
  pass "fm_tmp_harness_scratch_dir builds the verified claude scratch path"
}

test_harness_scratch_dir_unverified_harness_is_hard_noop() {
  local out rc
  out=$(fm_tmp_harness_scratch_dir codex /some/worktree/path 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] || fail "an unverified harness (codex) returned success instead of failing closed"
  [ -z "$out" ] || fail "an unverified harness printed a guessed path instead of nothing: $out"
  pass "fm_tmp_harness_scratch_dir fails closed (nonzero, no output) for a harness whose convention is not verified"
}

test_harness_scratch_dir_empty_worktree_is_noop() {
  local rc
  fm_tmp_harness_scratch_dir claude "" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "an empty worktree argument returned success instead of failing"
  pass "fm_tmp_harness_scratch_dir fails when the worktree argument is empty"
}

test_live_homes_lists_main_home_first_with_no_secondmates
test_live_homes_discovers_live_secondmate_home
test_live_homes_skips_secondmate_whose_home_dir_is_gone
test_live_tasks_synthesizes_main_home_entry
test_live_tasks_synthesizes_secondmate_home_entry_too
test_live_tasks_synthetic_id_is_rejected_by_real_task_id_validator
test_live_tasks_lists_real_spawned_task_with_worktree
test_live_tasks_handles_meta_with_no_worktree_line
test_live_tasks_covers_both_homes_and_real_tasks_together
test_claude_sanitize_replaces_non_alnum_with_dash
test_claude_sanitize_is_pure_alnum_passthrough
test_harness_scratch_dir_claude_matches_convention
test_harness_scratch_dir_unverified_harness_is_hard_noop
test_harness_scratch_dir_empty_worktree_is_noop
