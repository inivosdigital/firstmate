#!/usr/bin/env bash
# Tests for bin/fm-ultracode-guard.sh: an ultracode-flagged task must not reach
# PR-ready until a genuinely separate, independently-dispatched task recorded
# itself as having reviewed the finished diff - never a self-reference or a
# made-up id.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-ultracode-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-ultracode-guard-tests)

new_state_dir() {
  local name=$1 dir
  dir="$TMP_ROOT/$name/state"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

run_guard() {
  local state=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$GUARD" "$@"
}

test_check_passes_when_never_flagged() {
  local state status
  state=$(new_state_dir never-flagged)
  fm_write_meta "$state/task-x1.meta" "worktree=/tmp/x" "project=/tmp/x"

  set +e
  run_guard "$state" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 0 "$status" "never-flagged: an unflagged task must pass check"
  pass "fm-ultracode-guard check passes a task that was never ultracode-flagged"
}

test_flag_then_check_fails_until_reviewed() {
  local state out status
  state=$(new_state_dir flag-then-check)
  fm_write_meta "$state/task-x1.meta" "worktree=/tmp/x" "project=/tmp/x"

  run_guard "$state" flag task-x1 >/dev/null

  set +e
  out=$(run_guard "$state" check task-x1 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "flag-then-check: a flagged, unreviewed task must fail check"
  assert_contains "$out" "is ultracode-flagged" "flag-then-check: should explain why it is blocked"
  assert_contains "$out" "role=independent-review" "flag-then-check: should report the default role"
  pass "fm-ultracode-guard check refuses a flagged task with no recorded review"
}

test_flag_custom_role_reported_in_check() {
  local state out
  state=$(new_state_dir custom-role)
  fm_write_meta "$state/task-x1.meta" "worktree=/tmp/x" "project=/tmp/x"

  run_guard "$state" flag task-x1 breadth-fanout >/dev/null

  set +e
  out=$(run_guard "$state" check task-x1 2>&1)
  set -e

  assert_contains "$out" "role=breadth-fanout" "custom-role: check should report the custom role"
  pass "fm-ultracode-guard flag records a custom role and check reports it"
}

test_reviewed_by_self_is_refused() {
  local state out status
  state=$(new_state_dir self-review)
  fm_write_meta "$state/task-x1.meta" "worktree=/tmp/x" "project=/tmp/x"
  run_guard "$state" flag task-x1 >/dev/null

  set +e
  out=$(run_guard "$state" reviewed task-x1 task-x1 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "self-review: a task cannot review itself"
  assert_contains "$out" "distinct from task-x1" "self-review: should explain the refusal"
  pass "fm-ultracode-guard reviewed refuses a task naming itself as its own reviewer"
}

test_reviewed_by_unknown_task_is_refused() {
  local state out status
  state=$(new_state_dir unknown-reviewer)
  fm_write_meta "$state/task-x1.meta" "worktree=/tmp/x" "project=/tmp/x"
  run_guard "$state" flag task-x1 >/dev/null

  set +e
  out=$(run_guard "$state" reviewed task-x1 made-up-id 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "unknown-reviewer: a made-up reviewer id must be refused"
  assert_contains "$out" "no recorded state/made-up-id.meta" "unknown-reviewer: should explain the refusal"
  pass "fm-ultracode-guard reviewed refuses a reviewer id with no recorded meta"
}

test_reviewed_by_distinct_dispatched_task_passes_check() {
  local state status
  state=$(new_state_dir distinct-reviewer)
  fm_write_meta "$state/task-x1.meta" "worktree=/tmp/x" "project=/tmp/x"
  fm_write_meta "$state/task-x2.meta" "worktree=/tmp/y" "project=/tmp/y"
  run_guard "$state" flag task-x1 >/dev/null

  run_guard "$state" reviewed task-x1 task-x2 >/dev/null

  set +e
  run_guard "$state" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 0 "$status" "distinct-reviewer: a genuinely separate reviewer must satisfy check"
  pass "fm-ultracode-guard check passes once a distinct dispatched task recorded the review"
}

test_reviewed_without_flag_is_refused() {
  local state out status
  state=$(new_state_dir no-flag)
  fm_write_meta "$state/task-x1.meta" "worktree=/tmp/x" "project=/tmp/x"
  fm_write_meta "$state/task-x2.meta" "worktree=/tmp/y" "project=/tmp/y"

  set +e
  out=$(run_guard "$state" reviewed task-x1 task-x2 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "no-flag: reviewed must refuse a task that was never flagged"
  assert_contains "$out" "not ultracode-flagged" "no-flag: should explain the refusal"
  pass "fm-ultracode-guard reviewed refuses to mark an unflagged task as reviewed"
}

test_reflag_clears_prior_review() {
  local state out status
  state=$(new_state_dir reflag-clears)
  fm_write_meta "$state/task-x1.meta" "worktree=/tmp/x" "project=/tmp/x"
  fm_write_meta "$state/task-x2.meta" "worktree=/tmp/y" "project=/tmp/y"
  run_guard "$state" flag task-x1 >/dev/null
  run_guard "$state" reviewed task-x1 task-x2 >/dev/null
  run_guard "$state" flag task-x1 >/dev/null

  set +e
  out=$(run_guard "$state" check task-x1 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "reflag-clears: re-flagging must clear the prior review"
  assert_contains "$out" "is ultracode-flagged" "reflag-clears: should be blocked again"
  pass "fm-ultracode-guard re-flagging starts the review requirement over"
}

test_check_passes_when_never_flagged
test_flag_then_check_fails_until_reviewed
test_flag_custom_role_reported_in_check
test_reviewed_by_self_is_refused
test_reviewed_by_unknown_task_is_refused
test_reviewed_by_distinct_dispatched_task_passes_check
test_reviewed_without_flag_is_refused
test_reflag_clears_prior_review

echo "# all fm-ultracode-guard tests passed"
