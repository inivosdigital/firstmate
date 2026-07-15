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
# boilerplate rather than a hand-written stand-in. Any extra args (e.g.
# --herdr-lab) are forwarded to fm-brief.sh so tests cover the real injected
# sections, not a stand-in.
scaffold_brief() {
  local case_dir=$1 task=$2 brief
  shift 2
  mkdir -p "$case_dir/state"
  FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$case_dir/data" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-brief.sh" task-x1 someproject "$@" >/dev/null 2>&1
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

test_herdr_lab_boilerplate_does_not_trip() {
  # The --herdr-lab contract fm-brief.sh injects between # Task and # Setup is
  # dense with "session"/"--session"; it is scaffold boilerplate, so a benign
  # task must not trip on it.
  local case_dir out status
  case_dir="$TMP_ROOT/scaffold-herdr-clean"
  scaffold_brief "$case_dir" "Fix a typo in the CLI help text." --herdr-lab

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1 2>&1)
  status=$?
  set -e

  expect_code 0 "$status" "scaffold-herdr-clean: the --herdr-lab contract's own 'session' text must not trip a benign task"
  [ -z "$out" ] || fail "scaffold-herdr-clean: expected no RISK output from --herdr-lab boilerplate, got: $out"
  pass "fm-risk-tripwire does not trip on --herdr-lab scaffold boilerplate"
}

test_herdr_lab_risky_task_still_trips() {
  # The Herdr block is now a scan boundary, so its "session" text is excluded -
  # but the real task body between # Task and the Herdr heading must still be
  # scanned, and the boilerplate's "session" must not leak into the hit list.
  local case_dir out status
  case_dir="$TMP_ROOT/scaffold-herdr-risky"
  scaffold_brief "$case_dir" "Rotate the payment credentials and run the schema migration." --herdr-lab

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
  status=$?
  set -e

  expect_code 1 "$status" "scaffold-herdr-risky: a risk-worded task body must still trip under --herdr-lab"
  assert_contains "$out" "RISK: brief for task-x1" "scaffold-herdr-risky: should name the brief hit"
  assert_contains "$out" "payment" "scaffold-herdr-risky: should surface the real task-body term"
  case "$out" in
    *session*) fail "scaffold-herdr-risky: the Herdr boilerplate's 'session' must not leak into the hit list, got: $out" ;;
  esac
  pass "fm-risk-tripwire scans the task body but excludes the --herdr-lab Herdr block"
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

test_embedded_comment_task_body_still_scanned() {
  local case_dir out status
  case_dir="$TMP_ROOT/embedded-comment"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
  # A column-0 "# " line inside the task body (a shell comment in an example
  # command) must NOT end the Task-section scan, or the risk words after it are
  # silently dropped - the dangerous direction for a safety floor.
  printf '# Task\nImplement the DB runner. Example invocation:\n# then run the schema migration and rotate the tokens\n./run up\n\n# Setup\nnothing risky here.\n' \
    > "$case_dir/data/task-x1/brief.md"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
  status=$?
  set -e

  expect_code 1 "$status" "embedded-comment: risk text after an embedded '# ' line must still be scanned"
  assert_contains "$out" "schema" "embedded-comment: should surface the term on the embedded comment line"
  assert_contains "$out" "migration" "embedded-comment: should surface the migration term after the comment line"
  pass "fm-risk-tripwire keeps scanning the task body past an embedded '# ' comment line"
}

test_auth_verbs_trip_wire() {
  local verb case_dir out status i=0
  for verb in authorize authorized authorizing authenticate authenticated; do
    i=$((i + 1))
    case_dir="$TMP_ROOT/auth-verb-$i"
    mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
    printf '# Task\nAdd middleware to %s admin requests.\n\n# Setup\nx\n' "$verb" \
      > "$case_dir/data/task-x1/brief.md"

    set +e
    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
    status=$?
    set -e

    expect_code 1 "$status" "auth-verb: '$verb' must trip the wire"
    assert_contains "$out" "RISK: brief for task-x1" "auth-verb: '$verb' should name the brief hit"
  done
  pass "fm-risk-tripwire trips on auth verbs (authorize/authenticate families)"
}

test_auth_nouns_do_not_false_positive() {
  local word case_dir out status i=0
  for word in authoritative author; do
    i=$((i + 1))
    case_dir="$TMP_ROOT/auth-noun-$i"
    mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
    printf '# Task\nMake the loader the %s source of config.\n\n# Setup\nx\n' "$word" \
      > "$case_dir/data/task-x1/brief.md"

    set +e
    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
    status=$?
    set -e

    expect_code 0 "$status" "auth-noun: '$word' must not trip the wire"
    [ -z "$out" ] || fail "auth-noun: '$word' expected no RISK output, got: $out"
  done
  pass "fm-risk-tripwire does not treat 'authoritative'/'author' as auth hits"
}

test_session_start_bin_path_does_not_trip() {
  local case_dir out status
  case_dir=$(make_case session-start)
  printf 'Tune the digest ordering.\n' > "$case_dir/data/task-x1/brief.md"
  mkdir -p "$case_dir/wt/bin"
  printf 'digest tweak\n' > "$case_dir/wt/bin/fm-session-start.sh"
  git -C "$case_dir/wt" add bin/fm-session-start.sh
  git -C "$case_dir/wt" commit -qm "tweak session-start"
  write_task_meta "$case_dir"

  set +e
  out=$(run_tripwire "$case_dir")
  status=$?
  set -e

  expect_code 0 "$status" "session-start: 'session' as a hyphen fragment of a supervision script must not trip"
  [ -z "$out" ] || fail "session-start: expected no RISK output, got: $out"
  pass "fm-risk-tripwire does not trip on bin/fm-session-start.sh"
}

test_auth_setup_bin_path_trips() {
  local case_dir out status
  case_dir=$(make_case auth-setup)
  printf 'Wire up the setup helper.\n' > "$case_dir/data/task-x1/brief.md"
  mkdir -p "$case_dir/wt/bin"
  printf 'setup\n' > "$case_dir/wt/bin/auth-setup.sh"
  git -C "$case_dir/wt" add bin/auth-setup.sh
  git -C "$case_dir/wt" commit -qm "add auth setup"
  write_task_meta "$case_dir"

  set +e
  out=$(run_tripwire "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "auth-setup: 'auth' as a real hyphen token must still trip under bin/"
  assert_contains "$out" "bin/auth-setup.sh" "auth-setup: should list the risky path"
  pass "fm-risk-tripwire still trips on bin/auth-setup.sh via its auth token"
}

test_dot_delimited_strong_token_trips() {
  local case_dir out status
  case_dir=$(make_case dot-token)
  printf 'Update the generated config file.\n' > "$case_dir/data/task-x1/brief.md"
  mkdir -p "$case_dir/wt/config"
  printf 'x\n' > "$case_dir/wt/config/db.schema.json"
  git -C "$case_dir/wt" add config/db.schema.json
  git -C "$case_dir/wt" commit -qm "add db schema config"
  write_task_meta "$case_dir"

  set +e
  out=$(run_tripwire "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "dot-token: 'schema' as an interior dot token must trip"
  assert_contains "$out" "config/db.schema.json" "dot-token: should list the risky path"
  pass "fm-risk-tripwire trips on a strong risk word as a dot-delimited token"
}

test_authors_doc_path_does_not_trip() {
  local case_dir out status
  case_dir=$(make_case authors-doc)
  printf 'Add a contributors list.\n' > "$case_dir/data/task-x1/brief.md"
  mkdir -p "$case_dir/wt/docs"
  printf 'names\n' > "$case_dir/wt/docs/authors.md"
  git -C "$case_dir/wt" add docs/authors.md
  git -C "$case_dir/wt" commit -qm "add authors doc"
  write_task_meta "$case_dir"

  set +e
  out=$(run_tripwire "$case_dir")
  status=$?
  set -e

  expect_code 0 "$status" "authors-doc: 'authors' is not the 'auth' token, must not trip"
  [ -z "$out" ] || fail "authors-doc: expected no RISK output, got: $out"
  pass "fm-risk-tripwire does not trip on docs/authors.md"
}

test_migrate_verbs_trip_wire() {
  local verb case_dir out status i=0
  for verb in migrate migrating migrated; do
    i=$((i + 1))
    case_dir="$TMP_ROOT/migrate-verb-$i"
    mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
    printf '# Task\n%s the customers table to the new engine.\n\n# Setup\nx\n' "$verb" \
      > "$case_dir/data/task-x1/brief.md"

    set +e
    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
    status=$?
    set -e

    expect_code 1 "$status" "migrate-verb: '$verb' must trip the wire"
    assert_contains "$out" "RISK: brief for task-x1" "migrate-verb: '$verb' should name the brief hit"
  done
  pass "fm-risk-tripwire trips on migrate verb forms (migrate/migrating/migrated)"
}

test_auth_prefix_forms_trip_wire() {
  local word case_dir out status i=0
  for word in unauthorized unauthenticated reauthenticate deauthorize; do
    i=$((i + 1))
    case_dir="$TMP_ROOT/auth-prefix-$i"
    mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
    printf '# Task\nReject %s requests at the gateway.\n\n# Setup\nx\n' "$word" \
      > "$case_dir/data/task-x1/brief.md"

    set +e
    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
    status=$?
    set -e

    expect_code 1 "$status" "auth-prefix: '$word' must trip the wire"
  done
  pass "fm-risk-tripwire trips on prefixed auth forms (unauthorized/unauthenticated/...)"
}

test_authenticator_noun_trips_wire() {
  local word case_dir out status i=0
  for word in authenticator authenticators; do
    i=$((i + 1))
    case_dir="$TMP_ROOT/authenticator-$i"
    mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
    printf '# Task\nAdd support for hardware %s at login.\n\n# Setup\nx\n' "$word" \
      > "$case_dir/data/task-x1/brief.md"

    set +e
    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
    status=$?
    set -e

    expect_code 1 "$status" "authenticator: '$word' must trip the wire"
  done
  pass "fm-risk-tripwire trips on authenticator/authenticators nouns"
}

test_snake_case_risk_word_trips() {
  local case_dir out status
  case_dir="$TMP_ROOT/snake-case"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
  printf '# Task\nImplement the runner. Call run_schema_migration_now to apply it.\n\n# Setup\nx\n' \
    > "$case_dir/data/task-x1/brief.md"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
  status=$?
  set -e

  expect_code 1 "$status" "snake-case: a risk word inside a snake_case identifier must trip"
  assert_contains "$out" "schema" "snake-case: should surface the schema token"
  assert_contains "$out" "migration" "snake-case: should surface the migration token"
  pass "fm-risk-tripwire splits snake_case identifiers so embedded risk words trip"
}

test_task_body_inline_heading_still_scanned() {
  local case_dir out status
  case_dir="$TMP_ROOT/inline-heading"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
  # A bare "# Setup" quoted inline in the task body (not blank-line-preceded, as
  # the real scaffold heading always is) must NOT terminate the scan early.
  printf '# Task\nDo the thing. Configuration follows:\n# Setup\nRotate the credentials and run the migration.\n\n# Setup\nbenign boilerplate goes here.\n' \
    > "$case_dir/data/task-x1/brief.md"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
  status=$?
  set -e

  expect_code 1 "$status" "inline-heading: risk text after an inline (non-blank-preceded) '# Setup' must still be scanned"
  assert_contains "$out" "credential" "inline-heading: should surface the credentials term"
  assert_contains "$out" "migration" "inline-heading: should surface the migration term"
  pass "fm-risk-tripwire keeps scanning past an inline heading that is not the scaffold boundary"
}

test_authorizer_path_trips() {
  local case_dir out status
  case_dir=$(make_case authorizer-path)
  printf 'Refactor the request pipeline.\n' > "$case_dir/data/task-x1/brief.md"
  mkdir -p "$case_dir/wt/app/authorizers"
  printf 'x\n' > "$case_dir/wt/app/authorizers/user_authorizer.rb"
  git -C "$case_dir/wt" add app/authorizers/user_authorizer.rb
  git -C "$case_dir/wt" commit -qm "add user authorizer"
  write_task_meta "$case_dir"

  set +e
  out=$(run_tripwire "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "authorizer-path: an 'authorizer' component must trip (path authoriz stem parity)"
  assert_contains "$out" "app/authorizers/user_authorizer.rb" "authorizer-path: should list the risky path"
  pass "fm-risk-tripwire trips on authorizer paths"
}

test_bare_auth_matches_but_authoritative_does_not() {
  # Guards the portable word boundary against silently no-op'ing on BSD grep: a
  # no-op that matches nothing would miss the bare 'auth' (part b), and a no-op
  # that matches substrings would trip on 'authoritative' (part a). Both asserted.
  local case_dir out status
  # (a) 'authoritative' alone must not match the 'auth' keyword.
  case_dir="$TMP_ROOT/authoritative-only"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
  printf '# Task\nMake the loader the authoritative config source only.\n\n# Setup\nx\n' \
    > "$case_dir/data/task-x1/brief.md"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
  status=$?
  set -e
  expect_code 0 "$status" "authoritative-only: 'authoritative' must not match the auth keyword"
  [ -z "$out" ] || fail "authoritative-only: expected no RISK output, got: $out"

  # (b) a bare 'auth' word appearing mid-line (not at the string edges) must trip.
  case_dir="$TMP_ROOT/bare-auth-midline"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
  printf '# Task\nPlease auth the request before the handler runs.\n\n# Setup\nx\n' \
    > "$case_dir/data/task-x1/brief.md"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
  status=$?
  set -e
  expect_code 1 "$status" "bare-auth-midline: a standalone mid-line 'auth' must trip the wire"
  assert_contains "$out" "auth" "bare-auth-midline: should surface the auth token"
  pass "fm-risk-tripwire matches a bare mid-line 'auth' but never 'authoritative'"
}

test_adjacent_keywords_both_reported() {
  # A boundary-consuming grep -o pattern drops the second word of an adjacent
  # pair (the shared delimiter is eaten); whole-token matching reports both.
  local case_dir out status
  case_dir="$TMP_ROOT/adjacent-pair"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
  printf '# Task\nRotate the session token on every login.\n\n# Setup\nx\n' \
    > "$case_dir/data/task-x1/brief.md"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
  status=$?
  set -e
  expect_code 1 "$status" "adjacent-pair: adjacent risk words must trip"
  assert_contains "$out" "session" "adjacent-pair: should surface session"
  assert_contains "$out" "token" "adjacent-pair: should surface the adjacent token too"
  pass "fm-risk-tripwire reports both words of an adjacent risk pair"
}

test_unresolvable_diff_base_is_not_a_clean_pass() {
  # A meta with a real worktree/project but an unresolvable diff base (no default
  # branch, no origin) must NOT silently read as a clean pass (exit 0). The
  # binding second checkpoint could not run, so it must warn and report
  # could-not-check (2), matching the sibling fm-tier-guard.sh/fm-review-diff.sh.
  local case_dir out status
  case_dir="$TMP_ROOT/unresolvable-base"
  mkdir -p "$case_dir/state" "$case_dir/wt"
  git init -q "$case_dir/project"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1 2>&1)
  status=$?
  set -e

  expect_code 2 "$status" "unresolvable-base: an unresolvable diff base must read as could-not-check (2), not a clean pass (0)"
  assert_contains "$out" "could not resolve a diff base" "unresolvable-base: should warn that the diff checkpoint did not run"
  pass "fm-risk-tripwire reports could-not-check when the diff base is unresolvable, not a clean pass"
}

test_unresolvable_diff_base_still_reports_brief_hit() {
  # A brief risk hit must still win (exit 1) even when the diff base is
  # unresolvable - the risk floor beats the could-not-check downgrade.
  local case_dir out status
  case_dir="$TMP_ROOT/unresolvable-base-brief-hit"
  mkdir -p "$case_dir/state" "$case_dir/wt" "$case_dir/data/task-x1"
  git init -q "$case_dir/project"
  printf 'Add a data migration for the new billing schema.\n' > "$case_dir/data/task-x1/brief.md"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1 2>/dev/null)
  status=$?
  set -e

  expect_code 1 "$status" "unresolvable-base-brief-hit: a brief risk hit must still win (1) even when the diff base is unresolvable"
  assert_contains "$out" "RISK: brief for task-x1" "unresolvable-base-brief-hit: should still name the brief hit"
  pass "fm-risk-tripwire still reports a brief hit (1) when the diff base is unresolvable"
}

test_multiword_phrase_keyword_trips() {
  local case_dir out status
  case_dir="$TMP_ROOT/phrase-keyword"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
  printf '# Task\nEnforce access control and handle data deletion on the endpoint.\n\n# Setup\nx\n' \
    > "$case_dir/data/task-x1/brief.md"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" "$TRIPWIRE" task-x1)
  status=$?
  set -e
  expect_code 1 "$status" "phrase-keyword: a multi-word risk phrase must still trip"
  assert_contains "$out" "access control" "phrase-keyword: should surface the access control phrase"
  pass "fm-risk-tripwire still trips on multi-word risk phrases"
}

test_diff_uses_recorded_pr_head_when_present() {
  local case_dir pr_head out status
  case_dir=$(make_case pr-head)
  printf 'Update generated docs.\n' > "$case_dir/data/task-x1/brief.md"
  printf 'ordinary local change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "ordinary local change"
  mkdir -p "$case_dir/wt/lib/auth"
  printf 'auth change\n' > "$case_dir/wt/lib/auth/token.rb"
  git -C "$case_dir/wt" add lib/auth/token.rb
  git -C "$case_dir/wt" commit -qm "remote pr head touches auth"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" reset -q --hard HEAD~1
  write_task_meta "$case_dir"
  printf '%s\n' "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"

  set +e
  out=$(run_tripwire "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "pr-head: risk-adjacent paths present only in recorded pr_head must trip"
  assert_contains "$out" "lib/auth/token.rb" "pr-head: should scan paths through recorded pr_head"
  pass "fm-risk-tripwire scans the recorded PR head when it is ahead of local HEAD"
}

test_clean_brief_and_diff_passes
test_bare_auth_matches_but_authoritative_does_not
test_adjacent_keywords_both_reported
test_unresolvable_diff_base_is_not_a_clean_pass
test_unresolvable_diff_base_still_reports_brief_hit
test_multiword_phrase_keyword_trips
test_diff_uses_recorded_pr_head_when_present
test_brief_keyword_trips_wire
test_diff_path_trips_wire
test_brief_only_mode_before_worktree_exists
test_nothing_to_check_errors
test_scaffolded_brief_boilerplate_does_not_trip
test_scaffolded_brief_risky_task_still_trips
test_herdr_lab_boilerplate_does_not_trip
test_herdr_lab_risky_task_still_trips
test_word_boundary_avoids_substring_false_positive
test_inflected_keyword_still_trips
test_supervision_bin_path_does_not_trip
test_usage_error_exit_code
test_embedded_comment_task_body_still_scanned
test_auth_verbs_trip_wire
test_auth_nouns_do_not_false_positive
test_session_start_bin_path_does_not_trip
test_auth_setup_bin_path_trips
test_dot_delimited_strong_token_trips
test_authors_doc_path_does_not_trip
test_migrate_verbs_trip_wire
test_auth_prefix_forms_trip_wire
test_authenticator_noun_trips_wire
test_snake_case_risk_word_trips
test_task_body_inline_heading_still_scanned
test_authorizer_path_trips

echo "# all fm-risk-tripwire tests passed"
