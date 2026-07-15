#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh's push-to-origin scoping: after fast-forwarding
# a local-only task's project to fm/<id>, the script must push the project's
# origin ONLY when PROJ is firstmate's own repo (the deliberate fork-sync case)
# or when the caller explicitly opts in with --push-origin. Every other
# local-only project's "no remote, no PR" contract (AGENTS.md section 6) must
# hold even when that project happens to carry an origin remote (e.g. kept only
# for pulls).
#
# Matrix:
#   (a) firstmate's own repo (PROJ == FM_ROOT)          -> pushes automatically
#   (b) an arbitrary other local-only project + origin  -> does NOT push
#   (c) same as (b), with --push-origin                 -> DOES push
#   (d) an unknown second argument                       -> refuses before merging
#   (e) a non-local-only task                            -> refuses before merging
#   (f) firstmate's own repo but no origin remote at all -> merges, skips push silently
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# Build a project at <case_dir>/project with `main` checked out and a
# fast-forwardable fm/task-x1 branch one commit ahead, plus a local-only ship
# task meta pointing at it. Args: case_dir
make_case() {
  local case_dir=$1
  mkdir -p "$case_dir/state"
  git init -q -b main "$case_dir/project"
  git -C "$case_dir/project" commit -q --allow-empty -m base
  git -C "$case_dir/project" branch fm/task-x1
  git -C "$case_dir/project" checkout -q fm/task-x1
  git -C "$case_dir/project" commit -q --allow-empty -m "task work"
  git -C "$case_dir/project" checkout -q main
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/project" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
}

# Add a bare, empty origin remote to a case's project (no branches pushed yet).
add_origin() {
  local case_dir=$1 origin_abs
  git init -q --bare "$case_dir/origin.git"
  origin_abs=$(cd "$case_dir/origin.git" && pwd)
  git -C "$case_dir/project" remote add origin "file://$origin_abs"
}

# Run fm-merge-local.sh with a given FM_ROOT_OVERRIDE, capturing stdout/stderr
# to separate files in case_dir. Args: case_dir fm_root [script args...]
run_merge_local() {
  local case_dir=$1 fm_root=$2; shift 2
  FM_ROOT_OVERRIDE="$fm_root" FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr"
}

test_firstmate_own_repo_pushes_automatically() {
  local case_dir rc
  case_dir="$TMP_ROOT/own-repo"
  make_case "$case_dir"
  add_origin "$case_dir"

  set +e
  run_merge_local "$case_dir" "$case_dir/project" task-x1
  rc=$?
  set -e

  expect_code 0 "$rc" "own-repo: fm-merge-local should succeed"
  assert_grep 'merged fm/task-x1 into local main' "$case_dir/stdout" \
    "own-repo: merge confirmation missing"
  assert_grep 'pushed main to origin' "$case_dir/stdout" \
    "own-repo: firstmate's own repo should push to origin automatically"
  pass "fm-merge-local pushes to origin automatically when PROJ is firstmate's own repo"
}

test_other_project_does_not_push_by_default() {
  local case_dir rc origin_head
  case_dir="$TMP_ROOT/other-project"
  make_case "$case_dir"
  add_origin "$case_dir"

  set +e
  run_merge_local "$case_dir" "$ROOT" task-x1
  rc=$?
  set -e

  expect_code 0 "$rc" "other-project: fm-merge-local should still succeed (local merge only)"
  assert_grep 'merged fm/task-x1 into local main' "$case_dir/stdout" \
    "other-project: merge confirmation missing"
  assert_no_grep 'pushed' "$case_dir/stdout" \
    "other-project: an arbitrary local-only project must not auto-push its origin"
  origin_head=$(git -C "$case_dir/origin.git" rev-parse --quiet --verify main 2>/dev/null || echo none)
  [ "$origin_head" = none ] || fail "other-project: origin's main advanced despite no push"
  pass "fm-merge-local does not push an arbitrary local-only project's origin by default"
}

test_other_project_pushes_with_explicit_opt_in() {
  local case_dir rc project_head origin_head
  case_dir="$TMP_ROOT/other-project-opt-in"
  make_case "$case_dir"
  add_origin "$case_dir"

  set +e
  run_merge_local "$case_dir" "$ROOT" task-x1 --push-origin
  rc=$?
  set -e

  expect_code 0 "$rc" "other-project-opt-in: fm-merge-local should succeed"
  assert_grep 'pushed main to origin' "$case_dir/stdout" \
    "other-project-opt-in: --push-origin should push"
  project_head=$(git -C "$case_dir/project" rev-parse main)
  origin_head=$(git -C "$case_dir/origin.git" rev-parse main)
  [ "$project_head" = "$origin_head" ] || fail "other-project-opt-in: origin did not actually advance to the merged commit"
  pass "fm-merge-local pushes an arbitrary local-only project's origin when --push-origin is passed explicitly"
}

test_unknown_second_argument_refuses() {
  local case_dir rc main_head task_head
  case_dir="$TMP_ROOT/unknown-arg"
  make_case "$case_dir"

  set +e
  run_merge_local "$case_dir" "$ROOT" task-x1 --bogus-flag
  rc=$?
  set -e

  expect_code 1 "$rc" "unknown-arg: fm-merge-local should refuse an unrecognized second argument"
  assert_grep "unknown argument '--bogus-flag'" "$case_dir/stderr" \
    "unknown-arg: refusal did not name the bad argument"
  main_head=$(git -C "$case_dir/project" rev-parse main)
  task_head=$(git -C "$case_dir/project" rev-parse fm/task-x1)
  [ "$main_head" != "$task_head" ] || fail "unknown-arg: merge happened despite the invalid argument"
  pass "fm-merge-local refuses an unrecognized second argument before touching the project"
}

test_non_local_only_task_refuses() {
  local case_dir rc
  case_dir="$TMP_ROOT/non-local-only"
  make_case "$case_dir"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/project" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"

  set +e
  run_merge_local "$case_dir" "$ROOT" task-x1
  rc=$?
  set -e

  expect_code 1 "$rc" "non-local-only: fm-merge-local should refuse a non-local-only task"
  assert_grep 'not local-only' "$case_dir/stderr" \
    "non-local-only: refusal did not explain the mode mismatch"
  pass "fm-merge-local refuses to run against a non-local-only task"
}

test_firstmate_own_repo_without_origin_skips_push_silently() {
  local case_dir rc
  case_dir="$TMP_ROOT/own-repo-no-origin"
  make_case "$case_dir"

  set +e
  run_merge_local "$case_dir" "$case_dir/project" task-x1
  rc=$?
  set -e

  expect_code 0 "$rc" "own-repo-no-origin: fm-merge-local should succeed"
  assert_grep 'merged fm/task-x1 into local main' "$case_dir/stdout" \
    "own-repo-no-origin: merge confirmation missing"
  assert_no_grep 'pushed' "$case_dir/stdout" \
    "own-repo-no-origin: no origin remote means nothing to push"
  assert_no_grep 'warning:' "$case_dir/stderr" \
    "own-repo-no-origin: no origin remote should not warn either"
  pass "fm-merge-local skips the push silently when firstmate's own repo has no origin remote"
}

test_firstmate_own_repo_pushes_automatically
test_other_project_does_not_push_by_default
test_other_project_pushes_with_explicit_opt_in
test_unknown_second_argument_refuses
test_non_local_only_task_refuses
test_firstmate_own_repo_without_origin_skips_push_silently
