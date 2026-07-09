#!/usr/bin/env bash
# Tests for bin/fm-tier-guard.sh: the trivial (haiku/low) dispatch tier must
# escalate when its actual diff or elapsed time outgrows its assigned envelope,
# and any tier must escalate once its diff crosses the general heavy-scale
# ceiling, regardless of model/effort.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TIER_GUARD="$ROOT/bin/fm-tier-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-tier-guard-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b "fm/$name" "$case_dir/wt" main

  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1 id=$2
  shift 2
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=fm-$id" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "$@"
}

run_tier_guard() {
  local case_dir=$1 id=$2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$TIER_GUARD" "$id"
}

test_trivial_tier_within_envelope_passes() {
  local case_dir out status
  case_dir=$(make_case within-envelope)
  printf 'base\nsmall change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "small edit"
  write_task_meta "$case_dir" task-x1 "model=claude-haiku-4-5" "effort=low"

  set +e
  out=$(run_tier_guard "$case_dir" task-x1)
  status=$?
  set -e

  expect_code 0 "$status" "within-envelope: trivial task inside its size/age ceiling must pass"
  [ -z "$out" ] || fail "within-envelope: expected no ESCALATE output, got: $out"
  pass "fm-tier-guard passes a trivial task within its size and age envelope"
}

test_trivial_tier_exceeds_line_ceiling_escalates() {
  local case_dir out status i
  case_dir=$(make_case line-ceiling)
  : > "$case_dir/wt/feature.txt"
  for i in $(seq 1 40); do echo "line $i" >> "$case_dir/wt/feature.txt"; done
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "big edit"
  write_task_meta "$case_dir" task-x1 "model=claude-haiku-4-5" "effort=low"

  set +e
  out=$(run_tier_guard "$case_dir" task-x1)
  status=$?
  set -e

  expect_code 1 "$status" "line-ceiling: trivial task past the line ceiling must escalate"
  assert_contains "$out" "ESCALATE: trivial (haiku/low) task task-x1" "line-ceiling: should name the trivial-tier escalation"
  assert_contains "$out" "bump to at least sonnet/high" "line-ceiling: should say what to bump to"
  pass "fm-tier-guard escalates a trivial task once its diff exceeds the line ceiling"
}

test_trivial_tier_exceeds_file_ceiling_escalates() {
  local case_dir out status
  case_dir=$(make_case file-ceiling)
  printf 'a\n' > "$case_dir/wt/a.txt"
  printf 'b\n' > "$case_dir/wt/b.txt"
  printf 'c\n' > "$case_dir/wt/c.txt"
  git -C "$case_dir/wt" add a.txt b.txt c.txt
  git -C "$case_dir/wt" commit -qm "three new files"
  write_task_meta "$case_dir" task-x1 "model=claude-haiku-4-5" "effort=low"

  set +e
  out=$(run_tier_guard "$case_dir" task-x1)
  status=$?
  set -e

  expect_code 1 "$status" "file-ceiling: trivial task past the file ceiling must escalate"
  assert_contains "$out" "ESCALATE: trivial (haiku/low) task task-x1" "file-ceiling: should name the trivial-tier escalation"
  pass "fm-tier-guard escalates a trivial task once its diff exceeds the file ceiling"
}

test_trivial_tier_stale_age_escalates() {
  local case_dir out status
  case_dir=$(make_case stale-age)
  printf 'base\nsmall change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "small edit"
  write_task_meta "$case_dir" task-x1 "model=claude-haiku-4-5" "effort=low"
  touch -t 202001010000 "$case_dir/state/task-x1.meta"

  set +e
  out=$(run_tier_guard "$case_dir" task-x1)
  status=$?
  set -e

  expect_code 1 "$status" "stale-age: trivial task past the age ceiling must escalate"
  assert_contains "$out" "has run" "stale-age: should name the age escalation"
  assert_contains "$out" "bump to at least sonnet/high" "stale-age: should say what to bump to"
  pass "fm-tier-guard escalates a trivial task that has run past its age ceiling"
}

test_non_trivial_tier_small_diff_no_ceiling() {
  local case_dir out status i
  case_dir=$(make_case non-trivial-ok)
  : > "$case_dir/wt/feature.txt"
  for i in $(seq 1 40); do echo "line $i" >> "$case_dir/wt/feature.txt"; done
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "ordinary sonnet-tier edit"
  write_task_meta "$case_dir" task-x1 "model=claude-sonnet-5" "effort=high"

  set +e
  out=$(run_tier_guard "$case_dir" task-x1)
  status=$?
  set -e

  expect_code 0 "$status" "non-trivial-ok: sonnet/high has no trivial-tier ceiling to trip"
  [ -z "$out" ] || fail "non-trivial-ok: expected no ESCALATE output, got: $out"
  pass "fm-tier-guard does not apply the trivial-tier ceiling to a non-trivial task"
}

test_any_tier_past_heavy_scale_escalates() {
  local case_dir out status i
  case_dir=$(make_case heavy-scale)
  : > "$case_dir/wt/feature.txt"
  for i in $(seq 1 6); do echo "line $i" >> "$case_dir/wt/feature.txt"; done
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "sonnet-tier edit that turned out large"
  write_task_meta "$case_dir" task-x1 "model=claude-sonnet-5" "effort=high"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TIER_HEAVY_MIN_LINES=5 FM_TIER_HEAVY_MIN_FILES=5 "$TIER_GUARD" task-x1)
  status=$?
  set -e

  expect_code 1 "$status" "heavy-scale: any tier past the heavy-scale ceiling must escalate"
  assert_contains "$out" "exceeds the heavy-scale ceiling" "heavy-scale: should name the general heavy-scale escalation"
  pass "fm-tier-guard escalates any tier once its diff crosses the general heavy-scale ceiling"
}

test_missing_meta_errors() {
  local case_dir out status
  case_dir=$(make_case missing-meta)

  set +e
  out=$(run_tier_guard "$case_dir" task-x1 2>&1)
  status=$?
  set -e

  expect_code 2 "$status" "missing-meta: no meta file must exit 2 (setup error), not 1 (an escalation)"
  assert_contains "$out" "no meta for task" "missing-meta: should report the missing meta file"
  pass "fm-tier-guard errors distinctly (exit 2) when the task has no recorded meta"
}

test_usage_error_exit_code() {
  local status
  set +e
  FM_ROOT_OVERRIDE="$ROOT" "$TIER_GUARD" >/dev/null 2>&1
  status=$?
  set -e
  expect_code 2 "$status" "usage-empty-id: a malformed invocation must exit 2, not 1 (the escalation code)"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" "$TIER_GUARD" one two >/dev/null 2>&1
  status=$?
  set -e
  expect_code 2 "$status" "usage-extra-args: extra args must exit 2, not 1 (the escalation code)"
  pass "fm-tier-guard uses a distinct exit code for malformed invocations"
}

test_trivial_tier_within_envelope_passes
test_trivial_tier_exceeds_line_ceiling_escalates
test_trivial_tier_exceeds_file_ceiling_escalates
test_trivial_tier_stale_age_escalates
test_non_trivial_tier_small_diff_no_ceiling
test_any_tier_past_heavy_scale_escalates
test_missing_meta_errors
test_usage_error_exit_code

echo "# all fm-tier-guard tests passed"
