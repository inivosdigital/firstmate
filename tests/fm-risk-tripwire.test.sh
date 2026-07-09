#!/usr/bin/env bash
# Tests for bin/fm-risk-tripwire.sh: a brief mentioning a risk-adjacent term,
# or a diff touching a risk-adjacent path, must trip the wire regardless of
# how the task's dispatch rule classified it - the mechanical, structurally
# different check behind AGENTS.md section 4's risk floor.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TRIPWIRE="$ROOT/bin/fm-risk-tripwire.sh"
TMP_ROOT=$(fm_test_tmproot fm-risk-tripwire-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"

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
  local case_dir=$1
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project"
}

run_tripwire() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
    "$TRIPWIRE" task-x1
}

# Scaffold a real ship brief via bin/fm-brief.sh, then substitute the {TASK}
# placeholder with the given task text - exercising the actual scaffold
# boilerplate rather than a hand-written stand-in.
scaffold_brief() {
  local case_dir=$1 task=$2 brief
  mkdir -p "$case_dir/state"
  FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$case_dir/data" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-brief.sh" task-x1 someproject >/dev/null 2>&1
  brief="$case_dir/data/task-x1/brief.md"
  sed "s|{TASK}|$task|" "$brief" > "$brief.tmp" && mv "$brief.tmp" "$brief"
}

test_clean_brief_and_diff_passes() {
  local case_dir out status
  case_dir=$(make_case clean)
  printf 'Add a --json flag to the status command.\n' > "$case_dir/data/task-x1/brief.md"
  printf 'ordinary change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "ordinary change"
  write_task_meta "$case_dir"

  set +e
  out=$(run_tripwire "$case_dir")
  status=$?
  set -e

  expect_code 0 "$status" "clean: an ordinary brief and diff must not trip the wire"
  [ -z "$out" ] || fail "clean: expected no RISK output, got: $out"
  pass "fm-risk-tripwire passes a clean brief and diff"
}

test_brief_keyword_trips_wire() {
  local case_dir out status
  case_dir=$(make_case brief-keyword)
  printf 'Add a data migration for the new billing schema.\n' > "$case_dir/data/task-x1/brief.md"
  write_task_meta "$case_dir"

  set +e
  out=$(run_tripwire "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "brief-keyword: a risk-worded brief must trip the wire"
  assert_contains "$out" "RISK: brief for task-x1 mentions risk-adjacent term(s)" "brief-keyword: should name the brief hit"
  assert_contains "$out" "migration" "brief-keyword: should surface the matched term"
  pass "fm-risk-tripwire trips on a brief that mentions risk-adjacent terms"
}

test_diff_path_trips_wire() {
  local case_dir out status
  case_dir=$(make_case diff-path)
  printf 'Fix a typo in the help text.\n' > "$case_dir/data/task-x1/brief.md"
  mkdir -p "$case_dir/wt/lib/auth"
  printf 'session handling\n' > "$case_dir/wt/lib/auth/session.rb"
  git -C "$case_dir/wt" add lib/auth/session.rb
  git -C "$case_dir/wt" commit -qm "touch auth session code"
  write_task_meta "$case_dir"

  set +e
  out=$(run_tripwire "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "diff-path: a diff touching an auth path must trip the wire"
  assert_contains "$out" "RISK: diff for task-x1 touches risk-adjacent path(s)" "diff-path: should name the diff hit"
  assert_contains "$out" "lib/auth/session.rb" "diff-path: should list the risky path"
  pass "fm-risk-tripwire trips on a diff that touches an auth-adjacent path"
}

test_brief_only_mode_before_worktree_exists() {
  local case_dir out status
  case_dir="$TMP_ROOT/brief-only"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
  printf 'Rotate the payment provider credentials.\n' > "$case_dir/data/task-x1/brief.md"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
  status=$?
  set -e

  expect_code 1 "$status" "brief-only: brief-only checkpoint must work before any meta/worktree exists"
  assert_contains "$out" "RISK:" "brief-only: should still trip on the brief text alone"
  pass "fm-risk-tripwire checks the brief alone before a task has been spawned"
}

test_nothing_to_check_errors() {
  local case_dir out status
  case_dir="$TMP_ROOT/nothing-to-check"
  mkdir -p "$case_dir/state" "$case_dir/data"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1 2>&1)
  status=$?
  set -e

  expect_code 2 "$status" "nothing-to-check: neither a brief nor meta must error distinctly"
  assert_contains "$out" "nothing to check" "nothing-to-check: should explain there was nothing to check"
  pass "fm-risk-tripwire errors distinctly when neither a brief nor a usable worktree exists"
}

test_scaffolded_brief_boilerplate_does_not_trip() {
  local case_dir out status
  case_dir="$TMP_ROOT/scaffold-clean"
  scaffold_brief "$case_dir" "Fix a typo in the CLI help text."

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1 2>&1)
  status=$?
  set -e

  expect_code 0 "$status" "scaffold-clean: a real scaffolded ship brief with a benign task must not trip"
  [ -z "$out" ] || fail "scaffold-clean: expected no RISK output from scaffold boilerplate, got: $out"
  pass "fm-risk-tripwire does not trip on fm-brief.sh scaffold boilerplate"
}

test_scaffolded_brief_risky_task_still_trips() {
  local case_dir out status
  case_dir="$TMP_ROOT/scaffold-risky"
  scaffold_brief "$case_dir" "Rotate the payment credentials and run the schema migration."

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
  status=$?
  set -e

  expect_code 1 "$status" "scaffold-risky: a risk-worded task body inside a real scaffold must still trip"
  assert_contains "$out" "RISK: brief for task-x1" "scaffold-risky: should name the brief hit"
  pass "fm-risk-tripwire still scans the task body of a scaffolded brief"
}

test_word_boundary_avoids_substring_false_positive() {
  local case_dir out status
  case_dir="$TMP_ROOT/word-boundary"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
  printf '# Task\nMake the config loader the authoritative source of truth.\n\n# Setup\nnothing risky here.\n' \
    > "$case_dir/data/task-x1/brief.md"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
  status=$?
  set -e

  expect_code 0 "$status" "word-boundary: 'authoritative' must not match the 'auth' keyword"
  [ -z "$out" ] || fail "word-boundary: expected no RISK output, got: $out"
  pass "fm-risk-tripwire does not treat 'authoritative' as an auth keyword hit"
}

test_inflected_keyword_still_trips() {
  local case_dir out status
  case_dir="$TMP_ROOT/inflected"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
  printf '# Task\nRun the pending database migrations and rotate the tokens.\n\n# Setup\nx\n' \
    > "$case_dir/data/task-x1/brief.md"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
  status=$?
  set -e

  expect_code 1 "$status" "inflected: a plural risk word must still trip (no false negative)"
  assert_contains "$out" "migration" "inflected: should surface the matched migration term"
  pass "fm-risk-tripwire still trips on inflected/plural risk words"
}

test_supervision_bin_path_does_not_trip() {
  local case_dir out status
  case_dir=$(make_case bin-path)
  printf 'Tune the watcher poll cadence.\n' > "$case_dir/data/task-x1/brief.md"
  mkdir -p "$case_dir/wt/bin"
  printf 'watcher tweak\n' > "$case_dir/wt/bin/fm-watch.sh"
  printf 'guard tweak\n' > "$case_dir/wt/bin/fm-guard.sh"
  git -C "$case_dir/wt" add bin/fm-watch.sh bin/fm-guard.sh
  git -C "$case_dir/wt" commit -qm "tweak supervision backbone"
  write_task_meta "$case_dir"

  set +e
  out=$(run_tripwire "$case_dir")
  status=$?
  set -e

  expect_code 0 "$status" "bin-path: a supervision-backbone bin/ change alone must not trip the wire"
  [ -z "$out" ] || fail "bin-path: expected no RISK output, got: $out"
  pass "fm-risk-tripwire does not trip on a supervision-backbone bin/ path"
}

test_usage_error_exit_code() {
  local status
  set +e
  FM_ROOT_OVERRIDE="$ROOT" "$TRIPWIRE" >/dev/null 2>&1
  status=$?
  set -e
  expect_code 2 "$status" "usage-empty-id: a malformed invocation must exit 2, not 1 (the RISK code)"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" "$TRIPWIRE" one two >/dev/null 2>&1
  status=$?
  set -e
  expect_code 2 "$status" "usage-extra-args: extra args must exit 2, not 1 (the RISK code)"
  pass "fm-risk-tripwire uses a distinct exit code for malformed invocations"
}

test_clean_brief_and_diff_passes
test_brief_keyword_trips_wire
test_diff_path_trips_wire
test_brief_only_mode_before_worktree_exists
test_nothing_to_check_errors
test_scaffolded_brief_boilerplate_does_not_trip
test_scaffolded_brief_risky_task_still_trips
test_word_boundary_avoids_substring_false_positive
test_inflected_keyword_still_trips
test_supervision_bin_path_does_not_trip
test_usage_error_exit_code

echo "# all fm-risk-tripwire tests passed"
