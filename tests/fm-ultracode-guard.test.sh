#!/usr/bin/env bash
# Tests for bin/fm-ultracode-guard.sh: an ultracode-flagged task must not reach
# PR-ready until a review has been recorded against it, naming an id that is
# neither the task's own nor unknown to this home, and that record must still
# cover the code as it stands now. Whether the recorded reviewer was
# genuinely separate is firstmate's assertion when it runs `reviewed`; these
# tests pin what the script checks, which is narrower. The guard's header says
# where that line falls.
#
# The second half is the class that shipped a hand-written rewrite past this
# guard: a review recorded once satisfied check forever, so commits landing
# afterwards were covered by nothing. A recorded review is therefore pinned to
# the diff it covered, and check refuses once that diff moves. Pinning is by
# diff CONTENT, not commit id, so the rebases and squashes this fleet does
# routinely do not manufacture false refusals.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

GUARD="$ROOT/bin/fm-ultracode-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-ultracode-guard-tests)

# new_case <name>: a case dir holding state/, a bare origin, a project clone and
# a task worktree on branch fm/task-x1, plus meta for the task and for a second
# task (task-x2) whose id can therefore be recorded as the reviewer - that meta
# file is all the script looks for. Mirrors the fixture the sibling guardrail
# suites use (tests/fm-tier-guard.test.sh).
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

# publish_pr_head <case_dir>: expose the branch tip as the forge would expose an
# open PR's head, so the guard's diff comes from a freshly fetched PR head.
publish_pr_head() {
  git -C "$1/wt" push -q --force origin "HEAD:refs/pull/1/head"
}

# hide_pr_head <case_dir>: the PR ref stops resolving, the way an unreachable
# remote or a dropped ref does, leaving only the recorded pr_head behind.
hide_pr_head() {
  git -C "$1/origin.git" update-ref -d refs/pull/1/head
}

# record_pr_meta <case_dir> <pr_head>: what bin/fm-pr-check.sh records once a PR
# exists. pr_head is captured when the PR is first seen, so it ages from then on.
record_pr_meta() {
  local case_dir=$1 head=$2
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "pr=https://github.com/example/repo/pull/1" "pr_head=$head"
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

  expect_code 1 "$status" "self-review: the reviewer id must differ from the task id"
  assert_contains "$out" "distinct from task-x1" "self-review: should explain the refusal"
  pass "fm-ultracode-guard reviewed refuses a reviewer id equal to the task's own id"
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
  assert_contains "$out" "nothing is present at state/made-up-id.meta" "unknown-reviewer: should explain the refusal"
  pass "fm-ultracode-guard reviewed refuses a reviewer id with no file at its metadata path"
}

test_reviewed_by_a_distinct_id_with_meta_passes_check() {
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

  expect_code 0 "$status" "distinct-reviewer: a distinct id with a meta file must satisfy check"
  pass "fm-ultracode-guard check passes once a review is recorded against a distinct known id"
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
  pass "fm-ultracode-guard flag refuses a role containing a newline (the marker is line-based)"
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
  # in it is the one shape that would leave a second, matching record behind it.
  fm_write_meta "$case_dir/state/$payload.meta" "window=w"

  set +e
  out=$(run_guard "$case_dir" reviewed task-x1 "$payload" 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "reviewer-newline: a reviewer id containing a newline must be refused"
  assert_contains "$out" "must be a plain task id" "reviewer-newline: should explain the refusal"
  assert_no_grep "evil-task" "$case_dir/state/task-x1.ultracode" \
    "reviewer-newline: no second review record should reach the marker"
  pass "fm-ultracode-guard reviewed refuses a reviewer id containing a newline"
}

# --- identifiers are used to build state/ paths -----------------------------

test_reviewed_refuses_a_reviewer_id_that_aliases_the_task_itself() {
  # The certification bypass: "../state/task-x1" is a different STRING from
  # "task-x1", so the distinctness comparison passes, but it resolves to the
  # task's OWN meta, so the existence check passes too. Before validation this
  # recorded a review and check returned a clean pass with no second task in
  # existence - the exact outcome this gate exists to catch.
  local case_dir out status
  case_dir=$(new_case reviewer-self-alias)
  commit_work "$case_dir" "base
implementation" "implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null

  set +e
  out=$(run_guard "$case_dir" reviewed task-x1 "../state/task-x1" 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "reviewer-self-alias: a path alias for the task itself must be refused"
  assert_contains "$out" "must be a plain task id" "reviewer-self-alias: should explain the refusal"
  assert_no_grep "^review=" "$case_dir/state/task-x1.ultracode" \
    "reviewer-self-alias: no review record should reach the marker"

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e
  expect_code 1 "$status" "reviewer-self-alias: check must still refuse the task"
  pass "fm-ultracode-guard reviewed refuses a reviewer id that path-aliases the task itself"
}

test_reviewed_refuses_a_reviewer_id_escaping_the_state_directory() {
  # The same alias reaching a .meta OUTSIDE state/ entirely, so a file the fleet
  # never wrote can satisfy the reviewer check.
  local case_dir out status
  case_dir=$(new_case reviewer-escape)
  commit_work "$case_dir" "base
implementation" "implementation"
  mkdir -p "$case_dir/outside"
  : > "$case_dir/outside/planted.meta"
  run_guard "$case_dir" flag task-x1 >/dev/null

  set +e
  out=$(run_guard "$case_dir" reviewed task-x1 "../outside/planted" 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "reviewer-escape: a reviewer id reaching outside state/ must be refused"
  assert_contains "$out" "must be a plain task id" "reviewer-escape: should explain the refusal"
  assert_no_grep "planted" "$case_dir/state/task-x1.ultracode" \
    "reviewer-escape: no review record should reach the marker"
  pass "fm-ultracode-guard reviewed refuses a reviewer id resolving outside state/"
}

test_flag_refuses_a_task_id_escaping_the_state_directory() {
  # The task id is interpolated into state/<id>.ultracode the same way, so it
  # could plant a marker anywhere the process can write.
  local case_dir out status
  case_dir=$(new_case flag-id-escape)
  mkdir -p "$case_dir/outside"

  set +e
  out=$(run_guard "$case_dir" flag "../outside/escaped" 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "flag-id-escape: a task id reaching outside state/ must be refused"
  assert_contains "$out" "must be a plain task id" "flag-id-escape: should explain the refusal"
  if [ -e "$case_dir/outside/escaped.ultracode" ]; then
    fail "flag-id-escape: a marker was written outside state/"
  fi
  pass "fm-ultracode-guard flag refuses a task id resolving outside state/"
}

# --- review currency --------------------------------------------------------

test_check_refuses_once_commits_land_past_the_review() {
  # The exact observed failure: a review was recorded at one commit, four more
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
  # Every retained record is a state the supervisor asserted a review covered,
  # so returning to one of them stays under that same assertion rather than
  # slipping out from under it.
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

test_check_passes_after_a_message_only_amend() {
  local case_dir status reviewed_commit tip
  case_dir=$(new_case amend-message-only)
  commit_work "$case_dir" "base
reviewed implementation" "reviewed implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null
  reviewed_commit=$(tip_of "$case_dir")

  git -C "$case_dir/wt" commit -q --amend -m "reviewed implementation, reworded"
  tip=$(tip_of "$case_dir")
  [ "$tip" != "$reviewed_commit" ] || fail "amend-message-only: fixture did not rewrite the commit id"

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 0 "$status" "amend-message-only: rewording a commit must not invalidate the review"
  pass "fm-ultracode-guard check survives an amend that only rewords the commit"
}

test_check_refuses_after_an_amend_that_changes_content() {
  local case_dir status
  case_dir=$(new_case amend-content)
  commit_work "$case_dir" "base
reviewed implementation" "reviewed implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null

  printf 'base\nquietly rewritten\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -q --amend --no-edit

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 1 "$status" "amend-content: an amend that changes content must refuse"
  pass "fm-ultracode-guard check refuses an amend that rewrites the reviewed content"
}

test_check_passes_after_a_force_push_preserving_the_diff() {
  local case_dir status reviewed_commit tip
  case_dir=$(new_case force-push-same-tree)
  commit_work "$case_dir" "base
reviewed implementation" "reviewed implementation"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null
  reviewed_commit=$(tip_of "$case_dir")

  # Same tree, different commit: exactly what a history rewrite force-pushes.
  git -C "$case_dir/wt" commit -q --amend --no-edit --date "2020-01-01T00:00:00"
  git -C "$case_dir/wt" push -q --force origin fm/task-x1
  tip=$(tip_of "$case_dir")
  [ "$tip" != "$reviewed_commit" ] || fail "force-push-same-tree: fixture did not rewrite the commit id"
  [ "$(git -C "$case_dir/wt" rev-parse "$tip^{tree}")" = "$(git -C "$case_dir/wt" rev-parse "$reviewed_commit^{tree}")" ] \
    || fail "force-push-same-tree: fixture changed the tree, so it is not testing a same-tree rewrite"

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 0 "$status" "force-push-same-tree: a rewrite that preserves the diff must still pass"
  pass "fm-ultracode-guard check survives a force-push that preserves the reviewed content"
}

test_check_refuses_after_a_force_push_that_changes_content() {
  local case_dir status
  case_dir=$(new_case force-push-changed)
  commit_work "$case_dir" "base
reviewed implementation" "reviewed implementation"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null

  printf 'base\nsomething else entirely\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -q --amend --no-edit
  git -C "$case_dir/wt" push -q --force origin fm/task-x1

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 1 "$status" "force-push-changed: a rewrite that changes content must refuse"
  pass "fm-ultracode-guard check refuses a force-push that rewrites the reviewed content"
}

# --- the identity must track content, not rendering -------------------------

# use_textconv_driver <case_dir>: bind *.nb to a text conversion driver, the way
# a project holding notebooks or generated files ordinarily does. The driver
# normalises the payload away, so two different committed files render as the
# same diff. Nothing adversarial: .gitattributes is committed, the driver is
# ordinary local config.
use_textconv_driver() {
  local case_dir=$1
  cat > "$case_dir/strip.sh" <<'EOS'
#!/bin/sh
sed 's/"outputs":"[^"]*"/"outputs":"<stripped>"/' "$1"
EOS
  chmod +x "$case_dir/strip.sh"
  # The driver-bound file has to already exist on the BASE branch. Only then do
  # both sides of the comparison normalise to the same text, git emit no hunk,
  # and the rendering hold still. Added on the branch instead, the patch carries
  # an "index <old>..<new>" line whose blob id moves with the payload - which is
  # what the vacuity guard below caught on the first attempt at this fixture.
  git clone -q "$case_dir/origin.git" "$case_dir/_nb" 2>/dev/null
  printf '*.nb diff=stripped\n' > "$case_dir/_nb/.gitattributes"
  printf '{"outputs":"v0"}\n' > "$case_dir/_nb/data.nb"
  git -C "$case_dir/_nb" add -A
  git -C "$case_dir/_nb" commit -qm "notebook and its diff driver"
  git -C "$case_dir/_nb" push -q origin main
  rm -rf "$case_dir/_nb"
  git -C "$case_dir/wt" fetch -q origin main
  git -C "$case_dir/wt" reset -q --hard FETCH_HEAD
  # Driver config is local, the way a developer's checkout carries it.
  git -C "$case_dir/wt" config diff.stripped.textconv "$case_dir/strip.sh"
}

# commit_nb <case_dir> <payload>: change the committed bytes only inside the
# region the driver normalises, so the rendered diff cannot move.
commit_nb() {
  local case_dir=$1 payload=$2
  printf '{"outputs":"%s"}\n' "$payload" > "$case_dir/wt/data.nb"
  git -C "$case_dir/wt" add data.nb
  git -C "$case_dir/wt" commit -qm "change payload to $payload"
}

test_check_refuses_when_content_moves_under_a_textconv_driver() {
  local case_dir out status rendered_before rendered_after
  case_dir=$(new_case textconv-content)
  use_textconv_driver "$case_dir"
  commit_nb "$case_dir" "REVIEWED"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null
  rendered_before=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-review-diff.sh" task-x1 2>/dev/null)

  commit_nb "$case_dir" "NOBODY-REVIEWED-THIS"
  rendered_after=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-review-diff.sh" task-x1 2>/dev/null)

  # The premise: this case is only meaningful while the rendering really is
  # unchanged. If the driver stops hiding the change, the test has gone vacuous
  # and must fail rather than pass for the wrong reason.
  if [ "$rendered_before" != "$rendered_after" ]; then
    fail "textconv-content: the rendered diff moved, so this case no longer tests a hidden content change"
  fi
  assert_contains "$(git -C "$case_dir/wt" show HEAD:data.nb)" "NOBODY-REVIEWED-THIS" \
    "textconv-content: the committed bytes must really have changed"

  set +e
  out=$(run_guard "$case_dir" check task-x1 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "textconv-content: check must refuse when committed content moved"
  assert_contains "$out" "no longer covers the current diff" "textconv-content: should explain the refusal"
  pass "fm-ultracode-guard check refuses content that moved while the rendered diff held still"
}

test_check_passes_when_only_the_rendering_would_differ() {
  local case_dir status
  case_dir=$(new_case textconv-stable)
  use_textconv_driver "$case_dir"
  commit_nb "$case_dir" "REVIEWED"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null

  # Same committed bytes, reached by a different history shape.
  git -C "$case_dir/wt" commit -q --amend --no-edit -m "reworded, same content"

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 0 "$status" "textconv-stable: unchanged content must still satisfy check"
  pass "fm-ultracode-guard check still passes when content is unchanged under a diff driver"
}

# --- the requirement's generation, and one writer at a time -----------------

test_reflagging_retires_a_review_recorded_against_the_old_requirement() {
  # The race the reviewer produced by hand: reviewed reads the marker and does
  # its slow work, flag resets the requirement, and reviewed's append lands
  # afterwards. The record it writes describes the CURRENT diff, so nothing
  # about the content can reject it - only knowing which requirement it was
  # recorded against can. The append is replayed literally here because that is
  # exactly what the losing side of that race writes.
  local case_dir out status in_flight
  case_dir=$(new_case stale-generation)
  commit_work "$case_dir" "base
implementation" "implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null
  in_flight=$(grep '^review=' "$case_dir/state/task-x1.ultracode" | tail -1)

  # The requirement is reset, exactly as an escalation does.
  run_guard "$case_dir" flag task-x1 >/dev/null
  printf '%s\n' "$in_flight" >> "$case_dir/state/task-x1.ultracode"

  set +e
  out=$(run_guard "$case_dir" check task-x1 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "stale-generation: a review from the superseded requirement must not satisfy check"
  pass "fm-ultracode-guard check refuses a review recorded against a superseded requirement"
}

test_flag_replaces_a_marker_symlink_instead_of_writing_through_it() {
  # Not a forgery defence - a worker can write the marker directly either way.
  # This is about damage: a tool that silently overwrites an arbitrary file when
  # its own state is odd is worth a few lines to stop.
  local case_dir victim
  case_dir=$(new_case marker-symlink)
  victim="$case_dir/important.txt"
  printf 'do not clobber me\n' > "$victim"
  ln -s "$victim" "$case_dir/state/task-x1.ultracode"

  run_guard "$case_dir" flag task-x1 >/dev/null

  assert_contains "$(cat "$victim")" "do not clobber me" \
    "marker-symlink: the link target must be left alone"
  if [ -L "$case_dir/state/task-x1.ultracode" ]; then
    fail "marker-symlink: the marker should have replaced the link, not followed it"
  fi
  assert_grep "role=independent-review" "$case_dir/state/task-x1.ultracode" \
    "marker-symlink: a real marker should now be in place"
  pass "fm-ultracode-guard flag replaces a marker symlink rather than writing through it"
}

# --- the diff must be established, never inferred ---------------------------

test_check_passes_against_a_freshly_resolved_pr_head() {
  local case_dir status
  case_dir=$(new_case pr-head-fresh)
  commit_work "$case_dir" "base
reviewed implementation" "reviewed implementation"
  publish_pr_head "$case_dir"
  record_pr_meta "$case_dir" "$(tip_of "$case_dir")"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 0 "$status" "pr-head-fresh: a review pinned against the live PR head must pass"
  pass "fm-ultracode-guard check passes when the PR head resolves and still matches the review"
}

test_check_refuses_when_only_the_recorded_pr_head_remains() {
  # The dangerous half of the degraded PR path: the fresh fetch fails but the
  # pr_head recorded when the PR opened is still a local object, so the diff
  # helper returns it as though it were resolved. The compared diff is then the
  # reviewed one while unreviewed commits sit past it, and the guard passed
  # silently - this guard's own defect, reached through the PR path.
  local case_dir out status reviewed_head
  case_dir=$(new_case pr-head-recorded-only)
  commit_work "$case_dir" "base
reviewed implementation" "reviewed implementation"
  publish_pr_head "$case_dir"
  reviewed_head=$(tip_of "$case_dir")
  record_pr_meta "$case_dir" "$reviewed_head"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null

  commit_work "$case_dir" "base
reviewed implementation
unreviewed work nobody read" "unreviewed work"
  hide_pr_head "$case_dir"
  git -C "$case_dir/wt" cat-file -e "$reviewed_head^{commit}" \
    || fail "pr-head-recorded-only: fixture lost the recorded head object, so the fallback cannot be exercised"

  set +e
  out=$(run_guard "$case_dir" check task-x1 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "pr-head-recorded-only: an unconfirmable PR head must refuse, never pass"
  assert_contains "$out" "could not be freshly resolved" \
    "pr-head-recorded-only: should say the PR head could not be established"
  pass "fm-ultracode-guard check refuses when only a recorded, unconfirmable PR head remains"
}

test_check_refuses_when_the_pr_head_is_unreachable() {
  # The other degraded shape: neither a fresh fetch nor the recorded pr_head
  # resolves, so the diff helper falls back to the LOCAL BRANCH. The local
  # branch still carries the reviewed content, so its fingerprint matches and
  # the guard passed - while the PR itself carried unreviewed work.
  #
  # Only the PR head is made unresolvable here. The base remote stays reachable
  # throughout, so the refusal comes from the path under test rather than from a
  # changed base label incidentally moving the fingerprint.
  local case_dir out status unreviewed_head
  case_dir=$(new_case pr-head-unreachable)
  commit_work "$case_dir" "base
reviewed implementation" "reviewed implementation"
  publish_pr_head "$case_dir"
  record_pr_meta "$case_dir" "$(tip_of "$case_dir")"
  run_guard "$case_dir" flag task-x1 >/dev/null
  run_guard "$case_dir" reviewed task-x1 task-x2 >/dev/null

  # Unreviewed work reaches the PR from elsewhere, so its commit never becomes a
  # local object here; then the PR ref stops resolving.
  git clone -q "$case_dir/origin.git" "$case_dir/_pr"
  git -C "$case_dir/_pr" fetch -q origin "+refs/pull/1/head:refs/heads/prwork"
  git -C "$case_dir/_pr" checkout -q prwork
  printf 'base\nreviewed implementation\nunreviewed work nobody read\n' > "$case_dir/_pr/feature.txt"
  git -C "$case_dir/_pr" add feature.txt
  git -C "$case_dir/_pr" commit -qm "unreviewed work pushed straight to the PR"
  unreviewed_head=$(git -C "$case_dir/_pr" rev-parse HEAD)
  git -C "$case_dir/_pr" push -q --force origin "prwork:refs/pull/1/head"
  rm -rf "$case_dir/_pr"
  record_pr_meta "$case_dir" "$unreviewed_head"
  hide_pr_head "$case_dir"

  if git -C "$case_dir/wt" cat-file -e "$unreviewed_head^{commit}" 2>/dev/null; then
    fail "pr-head-unreachable: fixture leaked the PR-only commit locally, so this exercises the recorded-head path instead"
  fi
  if ! git -C "$case_dir/wt" remote get-url origin >/dev/null 2>&1; then
    fail "pr-head-unreachable: fixture must keep the base remote reachable"
  fi

  set +e
  out=$(run_guard "$case_dir" check task-x1 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "pr-head-unreachable: an unresolvable PR head must refuse, never pass"
  assert_contains "$out" "could not be freshly resolved" \
    "pr-head-unreachable: should say the PR head could not be established"
  pass "fm-ultracode-guard check refuses when neither the PR head nor a recorded head resolves"
}

test_reviewed_refuses_to_pin_against_an_unconfirmable_pr_head() {
  local case_dir out status
  case_dir=$(new_case pr-head-unpinnable)
  commit_work "$case_dir" "base
implementation" "implementation"
  run_guard "$case_dir" flag task-x1 >/dev/null
  git -C "$case_dir/wt" remote remove origin
  record_pr_meta "$case_dir" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  set +e
  out=$(run_guard "$case_dir" reviewed task-x1 task-x2 2>&1)
  status=$?
  set -e

  expect_code 1 "$status" "pr-head-unpinnable: a review must not be pinned to an unconfirmable head"
  assert_contains "$out" "could not be freshly resolved" \
    "pr-head-unpinnable: should say the PR head could not be established"
  assert_no_grep "review=" "$case_dir/state/task-x1.ultracode" \
    "pr-head-unpinnable: no record should be written against an unconfirmable head"
  pass "fm-ultracode-guard reviewed refuses to pin a review to an unconfirmable PR head"
}

test_reviewer_metadata_path_alone_satisfies_the_reviewer_check() {
  # A DOCUMENTED LIMIT, pinned so it stays deliberate. The reviewer check is a
  # distinct id plus a file existing at the expected metadata path, and nothing
  # more: the file here is EMPTY and still satisfies it. Dispatch provenance,
  # independence from the reviewed task, and whether any review happened are
  # none of them established mechanically; they rest on the supervisor who runs
  # `reviewed` (see the script header). Anything that makes independence
  # mechanical has to change this test knowingly rather than by accident.
  local case_dir status
  case_dir=$(new_case reviewer-path-limit)
  commit_work "$case_dir" "base
implementation" "implementation"
  : > "$case_dir/state/unrelated-helper.meta"
  run_guard "$case_dir" flag task-x1 >/dev/null

  run_guard "$case_dir" reviewed task-x1 unrelated-helper >/dev/null

  set +e
  run_guard "$case_dir" check task-x1 >/dev/null 2>&1
  status=$?
  set -e

  expect_code 0 "$status" "reviewer-path-limit: a file at the metadata path is all the reviewer check enforces"
  pass "fm-ultracode-guard treats a file at the reviewer metadata path as the whole reviewer check"
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
test_reviewed_by_a_distinct_id_with_meta_passes_check
test_reviewed_without_flag_is_refused
test_reflag_clears_prior_review
test_flag_rejects_newline_injection_in_role
test_flag_rejects_role_with_disallowed_characters
test_flag_accepts_role_with_digits_and_underscore
test_reviewed_refuses_a_reviewer_id_containing_a_newline
test_reviewed_refuses_a_reviewer_id_that_aliases_the_task_itself
test_reviewed_refuses_a_reviewer_id_escaping_the_state_directory
test_flag_refuses_a_task_id_escaping_the_state_directory
test_check_refuses_once_commits_land_past_the_review
test_check_passes_when_the_review_is_current
test_check_passes_after_a_rebase_that_preserves_the_diff
test_check_passes_after_a_squash_that_preserves_the_diff
test_check_passes_when_the_default_branch_advances_without_a_rebase
test_re_review_after_a_fix_passes_without_discarding_the_first
test_check_passes_when_a_reverted_diff_returns_to_a_reviewed_state
test_check_refuses_a_review_recorded_before_reviews_were_pinned
test_re_recording_clears_a_pre_pinning_review
test_check_passes_after_a_message_only_amend
test_check_refuses_after_an_amend_that_changes_content
test_check_passes_after_a_force_push_preserving_the_diff
test_check_refuses_after_a_force_push_that_changes_content
test_check_passes_against_a_freshly_resolved_pr_head
test_check_refuses_when_only_the_recorded_pr_head_remains
test_check_refuses_when_the_pr_head_is_unreachable
test_reviewed_refuses_to_pin_against_an_unconfirmable_pr_head
test_reviewer_metadata_path_alone_satisfies_the_reviewer_check
test_check_refuses_when_the_current_diff_cannot_be_determined
test_reviewed_refuses_when_the_diff_cannot_be_determined
test_reviewed_reports_the_commit_it_pinned
test_check_refuses_when_content_moves_under_a_textconv_driver
test_check_passes_when_only_the_rendering_would_differ
test_reflagging_retires_a_review_recorded_against_the_old_requirement
test_flag_replaces_a_marker_symlink_instead_of_writing_through_it

echo "# all fm-ultracode-guard tests passed"
