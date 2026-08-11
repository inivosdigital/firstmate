#!/usr/bin/env bash
# Tests for bin/fm-ultracode-guard.sh: an ultracode-flagged task must not reach
# PR-ready until a genuinely separate, independently-dispatched task recorded
# itself as having reviewed the finished diff - never a self-reference or a
# made-up id - and that review must still cover the code as it stands now.
#
# The second half is the class that shipped a hand-written rewrite past this
# guard: a review recorded once satisfied check forever, so commits landing
# afterwards were never covered by any independent pass. A recorded review is
# therefore pinned to the diff it covered, and check refuses once that diff
# moves. Pinning is by diff CONTENT, not commit id, so the rebases and squashes
# this fleet does routinely do not manufacture false refusals.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

GUARD="$ROOT/bin/fm-ultracode-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-ultracode-guard-tests)

# new_case <name>: a case dir holding state/, a bare origin, a project clone and
# a task worktree on branch fm/task-x1, plus meta for the task and for a second
# separately-dispatched task (task-x2) that can act as the reviewer. Mirrors the
# fixture the sibling guardrail suites use (tests/fm-tier-guard.test.sh).
new_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project"
  fm_write_meta "$case_dir/state/task-x2.meta" \
    "window=fm-task-x2" "worktree=$case_dir/wt" "project=$case_dir/project"

  # Keep fm-guard.sh's supervision banner out of the diff helper's stderr.
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# commit_work <case_dir> <content> <message>: one commit on the task branch.
commit_work() {
  local case_dir=$1 content=$2 message=$3
  printf '%s\n' "$content" > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "$message"
}

# advance_main <case_dir>: land an unrelated commit on origin/main, the way any
# other task merging does while this one is in flight.
advance_main() {
  local case_dir=$1
  git clone -q "$case_dir/origin.git" "$case_dir/_bump" 2>/dev/null
  printf 'unrelated main work\n' > "$case_dir/_bump/main-only.txt"
  git -C "$case_dir/_bump" add main-only.txt
  git -C "$case_dir/_bump" commit -qm "another task lands on main"
  git -C "$case_dir/_bump" push -q origin main
  rm -rf "$case_dir/_bump"
}

tip_of() {
  git -C "$1/wt" rev-parse HEAD
}

run_guard() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" "$GUARD" "$@"
}

test_check_passes_when_never_flagged() {
  local case_dir status
  case_dir=$(new_case never-flagged)

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 0 "$status" "never-flagged: an unflagged task must pass check"
  pass "fm-ultracode-guard check passes a task that was never ultracode-flagged"
}

test_flag_then_check_fails_until_reviewed() {
  local case_dir out status
  case_dir=$(new_case flag-then-check)

  run_guard "$case_dir" flag task-x1 >/dev/null

  set +e
  out=$(run_guard "$case_dir" check task-x1 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "flag-then-check: a flagged, unreviewed task must fail check"
  assert_contains "$out" "is ultracode-flagged" "flag-then-check: should explain why it is blocked"
  assert_contains "$out" "role=independent-review" "flag-then-check: should report the default role"
  pass "fm-ultracode-guard check refuses a flagged task with no recorded review"
}

test_flag_custom_role_reported_in_check() {
  local case_dir out
  case_dir=$(new_case custom-role)

  run_guard "$case_dir" flag task-x1 breadth-fanout >/dev/null

  set +e
  out=$(run_guard "$case_dir" check task-x1 2>&1)
  set -e

  assert_contains "$out" "role=breadth-fanout" "custom-role: check should report the custom role"
  pass "fm-ultracode-guard flag records a custom role and check reports it"
}

test_reviewed_by_self_is_refused() {
  local case_dir out status
  case_dir=$(new_case self-review)
  run_guard "$case_dir" flag task-x1 >/dev/null

  set +e
  out=$(run_guard "$case_dir" reviewed task-x1 task-x1 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "self-review: a task cannot review itself"
  assert_contains "$out" "distinct from task-x1" "self-review: should explain the refusal"
  pass "fm-ultracode-guard reviewed refuses a task naming itself as its own reviewer"
}

test_reviewed_by_unknown_task_is_refused() {
  local case_dir out status
  case_dir=$(new_case unknown-reviewer)
  run_guard "$case_dir" flag task-x1 >/dev/null

  set +e
  out=$(run_guard "$case_dir" reviewed task-x1 made-up-id 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "unknown-reviewer: a made-up reviewer id must be refused"
  assert_contains "$out" "no recorded state/made-up-id.meta" "unknown-reviewer: should explain the refusal"
  pass "fm-ultracode-guard reviewed refuses a reviewer id with no recorded meta"
}

test_reviewed_by_distinct_dispatched_task_passes_check() {
  local case_dir status
  case_dir=$(new_case distinct-reviewer)
  commit_work "$case_dir" "base
implementation" "implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null

  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 0 "$status" "distinct-reviewer: a genuinely separate reviewer must satisfy check"
  pass "fm-ultracode-guard check passes once a distinct dispatched task recorded the review"
}

test_reviewed_without_flag_is_refused() {
  local case_dir out status
  case_dir=$(new_case no-flag)

  set +e
  out=$(run_guard "$case_dir" reviewed task-x1 task-x2 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "no-flag: reviewed must refuse a task that was never flagged"
  assert_contains "$out" "not ultracode-flagged" "no-flag: should explain the refusal"
  pass "fm-ultracode-guard reviewed refuses to mark an unflagged task as reviewed"
}

test_reflag_clears_prior_review() {
  local case_dir out status
  case_dir=$(new_case reflag-clears)
  commit_work "$case_dir" "base
implementation" "implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null
  run_guard "$case_dir" flag task-x1 >/dev/null

  set +e
  out=$(run_guard "$case_dir" check task-x1 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "reflag-clears: re-flagging must clear the prior review"
  assert_contains "$out" "is ultracode-flagged" "reflag-clears: should be blocked again"
  pass "fm-ultracode-guard re-flagging starts the review requirement over"
}

test_flag_rejects_newline_injection_in_role() {
  local case_dir out status payload
  case_dir=$(new_case newline-injection)
  payload=$'independent-review\nreviewed_by=evil-task'

  set +e
  out=$(run_guard "$case_dir" flag task-x1 "$payload" 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "newline-injection: flag must refuse a role containing a newline"
  assert_contains "$out" "must be non-empty and contain only letters, digits, '-', or '_'" \
    "newline-injection: should explain the refusal"
  assert_absent "$case_dir/state/task-x1.ultracode" \
    "newline-injection: no marker file should be written for a rejected role"
  pass "fm-ultracode-guard flag refuses a role containing a newline (marker-injection defense)"
}

test_flag_rejects_role_with_disallowed_characters() {
  local case_dir out status
  case_dir=$(new_case bad-chars)

  set +e
  out=$(run_guard "$case_dir" flag task-x1 "bad role" 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "bad-chars: flag must refuse a role containing a space"
  assert_contains "$out" "must be non-empty and contain only letters, digits, '-', or '_'" \
    "bad-chars: should explain the refusal"
  assert_absent "$case_dir/state/task-x1.ultracode" \
    "bad-chars: no marker file should be written for a rejected role"
  pass "fm-ultracode-guard flag refuses a role containing a disallowed character"
}

test_flag_accepts_role_with_digits_and_underscore() {
  local case_dir out
  case_dir=$(new_case digits-underscore)

  run_guard "$case_dir" flag task-x1 safety_check-2 >/dev/null

  set +e
  out=$(run_guard "$case_dir" check task-x1 2>&1)
  set -e

  assert_contains "$out" "role=safety_check-2" "digits-underscore: check should report the accepted role"
  pass "fm-ultracode-guard flag accepts a role containing digits and underscores"
}

test_reviewed_refuses_a_reviewer_id_containing_a_newline() {
  local case_dir out status payload
  case_dir=$(new_case reviewer-newline)
  commit_work "$case_dir" "base
implementation" "implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  payload=$'task-x2\nreview=deadbeef deadbeef evil-task'
  # A reviewer id is recorded as the last field of a review record, so a newline
  # in it is the one shape that could forge a second, matching record.
  fm_write_meta "$case_dir/state/$payload.meta" "window=w"

  set +e
  out=$(run_guard "$case_dir" reviewed task-x1 "$payload" 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "reviewer-newline: a reviewer id containing a newline must be refused"
  assert_contains "$out" "must not contain a newline" "reviewer-newline: should explain the refusal"
  assert_no_grep "evil-task" "$case_dir/state/task-x1.ultracode" \
    "reviewer-newline: no forged review record should reach the marker"
  pass "fm-ultracode-guard reviewed refuses a reviewer id containing a newline"
}

# --- review currency --------------------------------------------------------

test_check_refuses_once_commits_land_past_the_review() {
  # The exact observed failure: the independent review passed, four more commits
  # landed afterwards including a hand-written rewrite, and check stayed silent.
  local case_dir out status reviewed_commit tip i
  case_dir=$(new_case commits-past-review)
  commit_work "$case_dir" "base
reviewed implementation" "reviewed implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null
  reviewed_commit=$(tip_of "$case_dir")

  for i in 1 2 3; do
    echo "tweak $i" >> "$case_dir/wt/feature.txt"
    git -C "$case_dir/wt" add feature.txt
    git -C "$case_dir/wt" commit -qm "tweak $i"
  done
  : > "$case_dir/wt/feature.txt"
  for i in $(seq 1 211); do echo "rewritten verification line $i" >> "$case_dir/wt/feature.txt"; done
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "hand-written rewrite"
  tip=$(tip_of "$case_dir")

  set +e
  out=$(run_guard "$case_dir" check task-x1 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "commits-past-review: unreviewed commits after the review must refuse"
  assert_contains "$out" "no longer covers the current diff" \
    "commits-past-review: should say the review went stale"
  assert_contains "$out" "$reviewed_commit" \
    "commits-past-review: should name the commit the review covered"
  assert_contains "$out" "$tip" \
    "commits-past-review: should name the current tip so the gap is visible"
  pass "fm-ultracode-guard check refuses once commits land past the recorded review"
}

test_check_passes_when_the_review_is_current() {
  local case_dir out status
  case_dir=$(new_case review-current)
  commit_work "$case_dir" "base
reviewed implementation" "reviewed implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null

  set +e
  out=$(run_guard "$case_dir" check task-x1 2>&1)
  status=$?
  set -e

  expect_code 0 "$status" "review-current: a review covering the current diff must pass"
  [ -z "$out" ] || fail "review-current: a clean pass must be silent, got: $out"
  pass "fm-ultracode-guard check passes while the recorded review still covers the current diff"
}

test_check_passes_after_a_rebase_that_preserves_the_diff() {
  # Rebasing onto an advanced default branch is routine here and rewrites every
  # commit id without changing what the reviewer read. Pinning to a commit id
  # would refuse this; pinning to the diff's content must not.
  local case_dir status reviewed_commit tip
  case_dir=$(new_case rebase-preserves-diff)
  commit_work "$case_dir" "base
reviewed implementation" "reviewed implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null
  reviewed_commit=$(tip_of "$case_dir")

  advance_main "$case_dir"
  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" rebase -q origin/main >/dev/null 2>&1
  tip=$(tip_of "$case_dir")
  [ "$tip" != "$reviewed_commit" ] || fail "rebase-preserves-diff: fixture did not rewrite the commit id"

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 0 "$status" "rebase-preserves-diff: a rebase that preserves the diff must still pass"
  pass "fm-ultracode-guard check survives a rebase that changes the commit id but not the diff"
}

test_check_passes_after_a_squash_that_preserves_the_diff() {
  local case_dir status reviewed_commit tip base
  case_dir=$(new_case squash-preserves-diff)
  commit_work "$case_dir" "base
part one" "part one"
  commit_work "$case_dir" "base
part one
part two" "part two"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null
  reviewed_commit=$(tip_of "$case_dir")

  base=$(git -C "$case_dir/wt" merge-base origin/main HEAD)
  git -C "$case_dir/wt" reset -q --soft "$base"
  git -C "$case_dir/wt" commit -qm "squashed implementation"
  tip=$(tip_of "$case_dir")
  [ "$tip" != "$reviewed_commit" ] || fail "squash-preserves-diff: fixture did not rewrite the commit id"

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 0 "$status" "squash-preserves-diff: a squash that preserves the diff must still pass"
  pass "fm-ultracode-guard check survives a squash that changes the commit id but not the diff"
}

test_check_passes_when_the_default_branch_advances_without_a_rebase() {
  # Every merged task advances main. That must not invalidate an untouched
  # branch's review, or the guard would refuse constantly and get worked around.
  local case_dir status
  case_dir=$(new_case main-advances)
  commit_work "$case_dir" "base
reviewed implementation" "reviewed implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null

  advance_main "$case_dir"

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 0 "$status" "main-advances: an unrelated main advance must not invalidate the review"
  pass "fm-ultracode-guard check is not invalidated by the default branch advancing"
}

test_re_review_after_a_fix_passes_without_discarding_the_first() {
  local case_dir status marker
  case_dir=$(new_case re-review)
  commit_work "$case_dir" "base
reviewed implementation" "reviewed implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null

  commit_work "$case_dir" "base
reviewed implementation
fix from the review" "fix from the review"

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e
  expect_code 1 "$status" "re-review: the fix must invalidate the first review until it is re-recorded"

  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e
  expect_code 0 "$status" "re-review: re-recording the review against the fixed diff must pass"

  marker="$case_dir/state/task-x1.ultracode"
  [ "$(grep -c '^review=' "$marker")" = 2 ] \
    || fail "re-review: both review records should be retained, got: $(cat "$marker")"
  pass "fm-ultracode-guard records a re-review without discarding the earlier one"
}

test_check_passes_when_a_reverted_diff_returns_to_a_reviewed_state() {
  # Every retained record is a state some separate task actually reviewed, so
  # returning to one of them is genuinely covered work, not an escape hatch.
  local case_dir status
  case_dir=$(new_case revert-to-reviewed)
  commit_work "$case_dir" "base
reviewed implementation" "reviewed implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null

  commit_work "$case_dir" "base
reviewed implementation
experiment" "experiment"
  commit_work "$case_dir" "base
reviewed implementation" "back out the experiment"

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 0 "$status" "revert-to-reviewed: returning to a reviewed diff must pass"
  pass "fm-ultracode-guard check passes when the diff returns to a state that was reviewed"
}

test_check_refuses_a_review_recorded_before_reviews_were_pinned() {
  # A marker written by the version that recorded only who reviewed, never what:
  # its currency is unknowable, so it must refuse rather than inherit a pass.
  local case_dir out status
  case_dir=$(new_case legacy-marker)
  commit_work "$case_dir" "base
implementation" "implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  printf 'reviewed_by=task-x2\n' >> "$case_dir/state/task-x1.ultracode"

  set +e
  out=$(run_guard "$case_dir" check task-x1 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "legacy-marker: an unpinned review must not inherit a pass"
  assert_contains "$out" "recorded before reviews were pinned" \
    "legacy-marker: should say why the recorded review cannot be trusted"
  assert_contains "$out" "reviewed by:  task-x2" \
    "legacy-marker: should name the reviewer the unpinned record carries"
  assert_contains "$out" "fm-ultracode-guard.sh reviewed task-x1 task-x2" \
    "legacy-marker: should name the exact command that re-affirms the review against the current diff"
  pass "fm-ultracode-guard check refuses a review recorded before reviews were pinned to a diff"
}

test_re_recording_clears_a_pre_pinning_review() {
  local case_dir status
  case_dir=$(new_case legacy-remediation)
  commit_work "$case_dir" "base
implementation" "implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  printf 'reviewed_by=task-x2\n' >> "$case_dir/state/task-x1.ultracode"

  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 0 "$status" "legacy-remediation: re-affirming against the current diff must clear the refusal"
  pass "fm-ultracode-guard clears a pre-pinning review by re-recording it against the current diff"
}

test_check_refuses_when_the_current_diff_cannot_be_determined() {
  local case_dir out status
  case_dir=$(new_case indeterminate-diff)
  commit_work "$case_dir" "base
implementation" "implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null
  rm -rf "$case_dir/wt"

  set +e
  out=$(run_guard "$case_dir" check task-x1 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "indeterminate-diff: an unreadable diff must refuse, never pass"
  assert_contains "$out" "cannot determine" "indeterminate-diff: should say what it could not establish"
  pass "fm-ultracode-guard check refuses when it cannot establish the current diff"
}

test_reviewed_refuses_when_the_diff_cannot_be_determined() {
  local case_dir out status
  case_dir=$(new_case unpinnable-review)
  run_guard "$case_dir" flag task-x1 >/dev/null
  rm -rf "$case_dir/wt"

  set +e
  out=$(run_guard "$case_dir" reviewed task-x1 task-x2 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "unpinnable-review: a review that cannot be pinned must be refused"
  assert_contains "$out" "cannot determine" "unpinnable-review: should say what it could not establish"
  assert_no_grep "review=" "$case_dir/state/task-x1.ultracode" \
    "unpinnable-review: no unpinned review record should be written"
  pass "fm-ultracode-guard reviewed refuses to record a review it cannot pin to a diff"
}

test_reviewed_reports_the_commit_it_pinned() {
  local case_dir out tip
  case_dir=$(new_case reviewed-reports-commit)
  commit_work "$case_dir" "base
implementation" "implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  tip=$(tip_of "$case_dir")

  out=$(run_guard "$case_dir" reviewed task-x1 task-x2 2>&1)

  assert_contains "$out" "$tip" "reviewed-reports-commit: should name the commit the review was pinned to"
  pass "fm-ultracode-guard reviewed reports the commit its record was pinned to"
}

test_check_passes_when_never_flagged
test_flag_then_check_fails_until_reviewed
test_flag_custom_role_reported_in_check
test_reviewed_by_self_is_refused
test_reviewed_by_unknown_task_is_refused
test_reviewed_by_distinct_dispatched_task_passes_check
test_reviewed_without_flag_is_refused
test_reflag_clears_prior_review
test_flag_rejects_newline_injection_in_role
test_flag_rejects_role_with_disallowed_characters
test_flag_accepts_role_with_digits_and_underscore
test_reviewed_refuses_a_reviewer_id_containing_a_newline
test_check_refuses_once_commits_land_past_the_review
test_check_passes_when_the_review_is_current
test_check_passes_after_a_rebase_that_preserves_the_diff
test_check_passes_after_a_squash_that_preserves_the_diff
test_check_passes_when_the_default_branch_advances_without_a_rebase
test_re_review_after_a_fix_passes_without_discarding_the_first
test_check_passes_when_a_reverted_diff_returns_to_a_reviewed_state
test_check_refuses_a_review_recorded_before_reviews_were_pinned
test_re_recording_clears_a_pre_pinning_review
test_check_refuses_when_the_current_diff_cannot_be_determined
test_reviewed_refuses_when_the_diff_cannot_be_determined
test_reviewed_reports_the_commit_it_pinned

echo "# all fm-ultracode-guard tests passed"
