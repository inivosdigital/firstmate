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

# run_tripwire_with_fakebin <case_dir> <fakebin>: like run_tripwire, but
# prepends <fakebin> onto PATH so a shimmed git shadows the real one for every
# git call the script (and its sourced fm-tangle-lib.sh helpers) make.
run_tripwire_with_fakebin() {
  local case_dir=$1 fakebin=$2
  PATH="$fakebin:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
    "$TRIPWIRE" task-x1
}

# write_git_diff_name_only_fails_stub <fakebin>: fail any `git ... diff
# --name-only ...` call (a bad ref, a corrupt object, or any other git error
# hitting the binding diff checkpoint after its base already resolved), and
# delegate every other git call - including the rev-parse that resolves the
# base itself - to the real binary. Mirrors tests/fm-nas-deploy-sync.test.sh's
# write_git_hung_fetch_stub pattern, adapted to target the diff call site.
write_git_diff_name_only_fails_stub() {
  local fakebin=$1 realgit
  realgit=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
real="$realgit"
for a in "\$@"; do
  if [ "\$a" = --name-only ]; then
    echo "fatal: simulated corrupt object (test stub)" >&2
    exit 128
  fi
done
exec "\$real" "\$@"
SH
  chmod +x "$fakebin/git"
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
    "$ROOT/bin/fm-brief.sh" task-x1 someproject --mode no-mistakes "$@" >/dev/null 2>&1
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

test_diff_command_failure_after_base_resolved_is_not_a_clean_pass() {
  # A diff base that resolves cleanly but whose actual `git diff --name-only`
  # call then fails (a bad ref, a corrupt object, any other git error) must NOT
  # fall through the same "|| true" the base-resolution steps legitimately use,
  # and must NOT read as an empty, risk-free diff. This is distinct from the
  # "no base resolved yet" case (test_unresolvable_diff_base_is_not_a_clean_pass):
  # here the base resolved fine, only the diff command itself errored, so the
  # message must say so rather than claiming the base was unresolvable.
  local case_dir out status fakebin
  case_dir=$(make_case diff-cmd-fails)
  printf 'Fix a typo in the help text.\n' > "$case_dir/data/task-x1/brief.md"
  printf 'ordinary change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "ordinary change"
  write_task_meta "$case_dir"

  fakebin=$(fm_fakebin "$case_dir")
  write_git_diff_name_only_fails_stub "$fakebin"

  set +e
  out=$(run_tripwire_with_fakebin "$case_dir" "$fakebin" 2>&1)
  status=$?
  set -e

  expect_code 2 "$status" "diff-cmd-fails: a diff error after the base resolved must read as could-not-check (2), not a clean pass (0)"
  assert_contains "$out" "git diff failed" "diff-cmd-fails: should warn that the diff command itself failed, not just that the base was unresolvable"
  case "$out" in
    *"could not resolve a diff base"*)
      fail "diff-cmd-fails: must be distinguished from the unresolved-base case, got: $out" ;;
  esac
  pass "fm-risk-tripwire reports could-not-check when the diff command itself fails after the base resolved, not a clean pass"
}

test_diff_command_failure_still_reports_brief_hit() {
  # A brief risk hit must still win (exit 1) even when the diff command itself
  # errors after its base resolved - the risk floor beats the could-not-check
  # downgrade, exactly like the unresolvable-base sibling case.
  local case_dir out status fakebin
  case_dir=$(make_case diff-cmd-fails-brief-hit)
  printf 'Add a data migration for the new billing schema.\n' > "$case_dir/data/task-x1/brief.md"
  printf 'ordinary change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "ordinary change"
  write_task_meta "$case_dir"

  fakebin=$(fm_fakebin "$case_dir")
  write_git_diff_name_only_fails_stub "$fakebin"

  set +e
  out=$(run_tripwire_with_fakebin "$case_dir" "$fakebin" 2>/dev/null)
  status=$?
  set -e

  expect_code 1 "$status" "diff-cmd-fails-brief-hit: a brief risk hit must still win (1) even when the diff command itself fails"
  assert_contains "$out" "RISK: brief for task-x1" "diff-cmd-fails-brief-hit: should still name the brief hit"
  pass "fm-risk-tripwire still reports a brief hit (1) when the diff command itself fails after the base resolved"
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

# write_task_brief <case_dir>: read a task body from stdin and write a brief
# with a real "# Task" section closed by a scaffold boundary heading, so the
# narrowing runs over exactly that body.
write_task_brief() {
  local case_dir=$1
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
  {
    printf '# Task\n'
    cat
    printf '\n# Setup\nnothing risky here.\n'
  } > "$case_dir/data/task-x1/brief.md"
}

run_brief_only() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    "$TRIPWIRE" task-x1
}

# The standing project-constraint bullet that produced three of the recorded
# false fires verbatim. Reproduced here so the regression is pinned by this
# repo's own fixture rather than by a live task's brief on some machine.
nas_constraint_bullet() {
  cat <<'EOF'
- **Never read, modify, move, or delete anything under `/mnt/nas/experiments/beamanalyzer-data`, and never point a test or a running server at that path.** It is real client data and it is read-only to you. Use a temporary directory via `DATA_DIR` for anything that needs a store. The live credentials under that path's `v2/auth/` are especially off limits, and no real password or hash may appear in a test fixture, a log line or a commit.
EOF
}

# recorded_false_fire <n>: the exact triggering prose of each recorded false
# fire, transcribed from the brief that produced it. Each is paired with the
# benign work the task actually did, because the point of the regression is that
# the work prose is scanned and the fencing prose is not.
recorded_false_fire() {
  case $1 in
    1)
      cat <<'EOF'
Add a read guard to the backup path in `server/store.mjs`.

## Constraints

EOF
      nas_constraint_bullet
      ;;
    2)
      printf 'Add cleanup hooks to five server test files so each removes the temp directory it created.\n\n## Constraints\n\n'
      nas_constraint_bullet
      ;;
    3)
      printf 'Make promote carry the shape identity through unchanged.\n\n## Constraints\n\n'
      nas_constraint_bullet
      ;;
    4)
      cat <<'EOF'
Install the counting pipeline permanently on edc-bee.

## Background, and what is already true

Access: `ssh -o BatchMode=yes "engineering dept"@example.invalid`. Note the space in the account name; quote it everywhere. Key authentication works and needs no password.

## Constraints, all hard

- **Do not disable, relax, add exclusions to, or otherwise weaken App Control for Business, Smart App Control, Defender, or any other security control on that machine.** If something blocks you, that is a finding to report, not an obstacle to work around.
- **Never ask for, handle, echo, log, or store the captain's password.** Privileged commands are handed to the captain to run.
EOF
      ;;
    5)
      cat <<'EOF'
Draw a number beside each accepted dot on the canvas.

## What the numbering has to mean

- The number must not change what is sent on accept. `acceptPayload()`, the correction-event schema, and the kept/removed guarantee are untouched by this; these coordinates become immutable training labels and nothing about them moves.

## Acceptance criteria

5. Nothing in the accept payload, the correction-event schema, or any stored coordinate changes. Prove it rather than asserting it.
EOF
      ;;
    6)
      cat <<'EOF'
Extend the HSS pipe clause set in the calculation package.

## Constraints

- Do not restart, redeploy or modify the production `calc` process, `calc-tunnel`, or `/home/orangepi/projects/beamanalyzer-v2`. Everything under `/mnt/nas/experiments/beamanalyzer-data` is real client data and read-only; never read or point anything at its `v2/auth/` directory.
EOF
      ;;
    7)
      cat <<'EOF'
Independently review one commit before it lands on local `main`.

## Constraints

- **Never restart, kill, or interfere with the running watcher, and never `pkill -f bin/fm-watch.sh`**: that can kill sibling firstmate homes. A live supervision cycle is active for this session. Build your own fixtures instead.
EOF
      ;;
    8)
      cat <<'EOF'
Add an L/500 option to the deflection limit dropdown.

## What should NOT need changing, but verify rather than assume

The ratio appears to be carried as a plain number all the way through: `z.number().optional()` in
the package schema, `project.deflLimitRatio ?? 360` at the consumers, and the allowable computed as
`(span x 12) / ratio`. If that holds, no engine, schema, persistence, or migration change is needed
and 500 flows through the existing chain untouched.
EOF
      ;;
    9)
      # The one recorded case whose brief cannot be identified on disk: its
      # quoted sentence appears verbatim in several surviving briefs and the
      # record does not name the task, so this is the quoted text rather than a
      # located file. Kept because its shape is distinct from the others: the
      # prohibition opens the bullet and the risk words land on a later wrapped
      # line, so it pins that a hard-wrapped bullet is judged as one block.
      cat <<'EOF'
Review the angle-section results against the worked examples.

## Constraints

- **Never read, modify, move, or delete anything under
  `/mnt/nas/experiments/beamanalyzer-data/v2/auth/`.** Those are live production credentials.
  Never point a test or a manual run at that path. Use a throwaway directory via `DATA_DIR` if
  you need one.
EOF
      ;;
  esac
}

# Each recorded false fire matched only on prose that fences the work off from a
# risky surface the task never went near. All nine fixtures must pass clean.
#
# Ten were recorded, nine are fixtured here, and the gap is deliberate. Eight
# were reproduced from their own brief files. The ninth is fixtured from its
# recorded quoted text because that sentence appears verbatim in several
# surviving briefs and the record does not name the task, so no one file can be
# said to be it. The tenth was recorded only as "a fourth in the same session
# had the same shape", with no task id and no quoted sentence anywhere, so there
# is nothing to build a fixture from and inventing a replacement would assert
# coverage that does not exist.
test_recorded_false_fires_no_longer_trip() {
  local n case_dir out status
  for n in 1 2 3 4 5 6 7 8 9; do
    case_dir="$TMP_ROOT/false-fire-$n"
    recorded_false_fire "$n" | write_task_brief "$case_dir"

    set +e
    out=$(run_brief_only "$case_dir")
    status=$?
    set -e

    expect_code 0 "$status" "false-fire-$n: fencing prose alone must not trip the wire"
    [ -z "$out" ] || fail "false-fire-$n: expected no RISK output, got: $out"
  done
  pass "fm-risk-tripwire no longer trips on the recorded constraint-prose false fires"
}

# The other half of the same contract: every term in the match set must still
# trip when it describes the WORK, even with the standing constraint bullet that
# caused the false fires sitting right beside it in the same brief. These fail
# if the narrowing is ever widened far enough to swallow task prose.
test_every_match_term_trips_beside_constraint_prose() {
  local case_dir out status term work expect i=0
  while IFS='|' read -r term work expect; do
    [ -n "$term" ] || continue
    i=$((i + 1))
    case_dir="$TMP_ROOT/term-$i"
    {
      printf '%s\n\n## Constraints\n\n' "$work"
      nas_constraint_bullet
    } | write_task_brief "$case_dir"

    set +e
    out=$(run_brief_only "$case_dir")
    status=$?
    set -e

    expect_code 1 "$status" "term-$term: real $term work must still trip beside a constraint block"
    assert_contains "$out" "$expect" "term-$term: should surface the $term term from the task prose"
  done <<'EOF'
auth|Move the auth directory resolution into the shared loader.|auth
authentication|Add authentication to the CSV export endpoint.|authentication
authorization|Add an authorization check to the admin route.|authorization
authorize|Authorize each request before the handler runs.|authorize
authenticate|Authenticate the websocket upgrade handshake.|authenticate
session|Rotate the session identifier whenever privileges change.|session
credential|Store the provider credential in the OS keyring.|credential
password|Add a password reset flow to the account page.|password
secret|Move the signing secret out of the repository.|secret
token|Refresh the access token before it expires.|token
payment|Capture the payment when an order is confirmed.|payment
billing|Add proration to the billing cycle calculation.|billing
migration|Run the pending database migration on deploy.|migration
schema|Add a status column to the orders schema.|schema
security|Tighten the security headers on the public API.|security
encrypt|Encrypt the nightly backup archive at rest.|encrypt
decrypt|Decrypt the archive during a restore run.|decrypt
permission|Widen the file permission on the upload directory.|permission
access-control|Enforce access control on the report endpoint.|access control
data-deletion|Implement data deletion for closed accounts.|data deletion
bulk-mutation|Add a bulk mutation endpoint for tag updates.|bulk mutation
public-exposure|Review the public exposure of the metrics port.|public exposure
breaking-change|Ship the breaking change to the response shape.|breaking change
EOF
  pass "fm-risk-tripwire still trips on every match-set term that describes the work"
}

# Sharper form of the same claim: in ONE brief, the term in the task description
# must trip while the terms that appear only in the constraint bullet must not
# be reported at all. This is what "a term in a task description but not in a
# constraint still trips" means operationally.
test_task_prose_term_trips_while_constraint_terms_stay_quiet() {
  local case_dir out status
  case_dir="$TMP_ROOT/prose-vs-constraint"
  {
    printf 'Add a status column to the orders schema and backfill it.\n\n## Constraints\n\n'
    nas_constraint_bullet
  } | write_task_brief "$case_dir"

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "prose-vs-constraint: the task's own schema work must trip"
  assert_contains "$out" "schema" "prose-vs-constraint: should surface the term from the task prose"
  assert_not_contains "$out" "credential" "prose-vs-constraint: constraint-only terms must not be reported"
  assert_not_contains "$out" "password" "prose-vs-constraint: constraint-only terms must not be reported"
  pass "fm-risk-tripwire reports task-prose terms and not constraint-only terms"
}

# The hardest form of the same claim, and the one that catches an over-wide
# narrowing: the work sentence and a prohibition share a single block. Only the
# prohibition may be dropped. A rule that discarded the whole block because
# something in it was prohibitive would lose the task's own schema work.
# The leading benign paragraph is load-bearing in the fixture itself: it keeps
# the narrowed text non-empty, so an over-wide rule fails this test outright
# instead of being masked by the empty-narrowing fallback.
test_work_sentence_beside_prohibition_in_same_block_still_trips() {
  local case_dir out status
  case_dir="$TMP_ROOT/same-block"
  cat <<'EOF' | write_task_brief "$case_dir"
Rename the toolbar button label.

Add a status column to the orders schema and backfill it. Do not drop the existing column.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "same-block: a prohibition beside the work must not discard the work"
  assert_contains "$out" "schema" "same-block: the work sentence must still be scanned"
  pass "fm-risk-tripwire keeps the work sentence when a prohibition shares its block"
}

# "With no downtime", "Without breaking X" and friends are scope qualifiers on
# an affirmative instruction, not prohibitions. Reading them as prohibitions
# would suppress a signing-key rotation and a session-store move, which are the
# archetypal cases the floor exists for, so the exclusion vocabulary must stay
# out of that word class.
test_prohibition_conceding_adjacent_work_still_trips() {
  local case_dir out status
  case_dir="$TMP_ROOT/concedes-work"
  # An access-control fix whose only match-set word is the surface it is told
  # not to break, in the same sentence that concedes it is rewriting the route
  # beside it. Nothing else here is in the match set: "owner", "signed in" and
  # "404" are how a real brief describes this work.
  cat <<'EOF' | write_task_brief "$case_dir"
`GET /api/projects` hands back every stored record to any signed-in caller. Scope the listing to its own owner, and return 404 rather than 403 for a record that belongs to someone else so the picker cannot enumerate other engineers' job numbers.

## Constraints

- Do not break the existing login cookie while you change the handler, and do not touch the session middleware.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "concedes-work: a prohibition that concedes work on the surface must not suppress it"
  assert_contains "$out" "session" "concedes-work: the conceded surface must be reported"
  pass "fm-risk-tripwire trips when a prohibition concedes work on the surface it names"
}

test_standing_prohibition_without_conceded_work_stays_quiet() {
  local case_dir out status
  case_dir="$TMP_ROOT/concedes-control"
  # The control for the test above, and the reason its connective list has to
  # stay closed. "while the fleet is live" is a temporal scope, not a concession
  # that the surface is being worked on, and it is firstmate's ordinary standing
  # register. Widening the list to a bare "while"/"when"/"as" reads it as a
  # concession and reopens the whole class of boilerplate false fires, so this
  # fixture is written to fail exactly when that happens.
  cat <<'EOF' | write_task_brief "$case_dir"
`GET /api/projects` hands back every stored record to any signed-in caller. Scope the listing to its own owner.

## Constraints

- Do not touch the session middleware while the fleet is live. Never read or modify the live credentials directory, and never let a real password reach a log line.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 0 "$status" "concedes-control: a standing prohibition with no conceded work must stay suppressed"
  [ -z "$out" ] || fail "concedes-control: expected no RISK output, got: $out"
  pass "fm-risk-tripwire still suppresses a prohibition that concedes no work"
}

test_work_clause_survives_a_trailing_prohibition_clause() {
  local case_dir out status
  case_dir="$TMP_ROOT/trailing-caveat"
  # A real regression: an IMAP connector brief whose only match-set words sat in
  # a work instruction with a trailing caveat. Judging the sentence as one unit
  # dropped the instruction with the caveat and the whole brief went clean.
  cat <<'EOF' | write_task_brief "$case_dir"
Add an IMAP intake connector for the RFQ mailbox.

Point it at a dedicated label rather than the whole mailbox, so it never mixes with the owner's real inbox. Document in your PR description that Gmail requires either an App Password or OAuth2 for IMAP auth - do not assume plain password auth works.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "trailing-caveat: a work instruction must survive its own trailing caveat"
  assert_contains "$out" "password" "trailing-caveat: the work clause's terms must reach the scan"
  assert_contains "$out" "auth" "trailing-caveat: the work clause's terms must reach the scan"
  pass "fm-risk-tripwire keeps a work clause whose sentence ends in a prohibition"
}

test_leading_prohibition_clause_still_suppresses_its_own_sentence() {
  local case_dir out status
  case_dir="$TMP_ROOT/leading-prohibition"
  # The direction that must not move: when the prohibition leads, everything it
  # governs is still fencing prose. This is the shape of every standing safety
  # bullet in the fleet, and the reason the split is anchored on the marker
  # opening a clause rather than merely appearing in one.
  # The elaborating sentence deliberately carries the only match-set word and is
  # not itself a prohibition, so nothing but the block drop can suppress it.
  cat <<'EOF' | write_task_brief "$case_dir"
Rename the export button label.

- **Never read, modify, move, or delete anything under the shared data path**. It holds the live credentials the production login service reads at boot.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 0 "$status" "leading-prohibition: a bullet that opens with a prohibition is still fencing prose"
  [ -z "$out" ] || fail "leading-prohibition: expected no RISK output, got: $out"
  pass "fm-risk-tripwire still drops a block whose opening clause is a prohibition"
}

test_fenced_scope_heading_cannot_open_an_excluded_section() {
  local case_dir out status
  case_dir="$TMP_ROOT/fenced-heading"
  # Pasting a markdown or issue template into a brief is ordinary authoring. A
  # scope-declaring line inside the fence must not exclude everything after it.
  cat <<'EOF' | write_task_brief "$case_dir"
Update the contributor docs to describe the new PR template.

Paste this template into `.github/PULL_REQUEST_TEMPLATE.md`:

```markdown
## Summary

## Out of scope

```

Then rotate the signing secret and re-issue the session token.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "fenced-heading: a scope heading inside a code fence must not exclude the rest"
  assert_contains "$out" "secret" "fenced-heading: text after the fence must still be scanned"
  assert_contains "$out" "session" "fenced-heading: text after the fence must still be scanned"
  pass "fm-risk-tripwire does not let a fenced scope heading open an excluded section"
}

test_unbounded_no_change_span_does_not_suppress_motivation_prose() {
  local case_dir out status
  case_dir="$TMP_ROOT/no-change-span"
  # "no ... change" declares a non-change only as a noun phrase. Here "change" is
  # the verb the sentence is describing, and the span crosses an infinitive.
  cat <<'EOF' | write_task_brief "$case_dir"
Add an admin-token path to the account tool.

There is no supported way to change a user's password without an admin token today, which is why support has to do it by hand.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "no-change-span: an infinitive inside the span must not read as a declared non-change"
  assert_contains "$out" "password" "no-change-span: the described surface must reach the scan"

  # The other half of the bound: a span far too long to be one noun phrase, with
  # no infinitive in it, so only the length limit can keep this on the trip side.
  case_dir="$TMP_ROOT/no-change-span-long"
  cat <<'EOF' | write_task_brief "$case_dir"
Add an admin-token path to the account tool.

Support has no way of resetting a password until the operator approves the change.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "no-change-span: a long span must not read as a declared non-change"
  assert_contains "$out" "password" "no-change-span: the long-span surface must reach the scan"
  pass "fm-risk-tripwire does not read 'no way to change X' as a declared non-change"
}

test_declared_no_change_phrase_is_still_suppressed() {
  local case_dir out status
  case_dir="$TMP_ROOT/no-change-declared"
  # The control for the test above: the noun-phrase form is the one real briefs
  # use to fence a surface off, and it must stay suppressed.
  cat <<'EOF' | write_task_brief "$case_dir"
Add an L/500 option to the deflection limit dropdown.

The ratio is carried as a plain number all the way through, so no schema change is needed.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 0 "$status" "no-change-declared: a declared non-change noun phrase must stay suppressed"
  [ -z "$out" ] || fail "no-change-declared: expected no RISK output, got: $out"
  pass "fm-risk-tripwire still suppresses a declared non-change noun phrase"
}

test_excluded_section_closes_at_the_next_heading() {
  local case_dir out status
  case_dir="$TMP_ROOT/exclevel-reset"
  # The reset that closes a D1 excluded region. Without it the exclusion runs to
  # the end of the task body and every risk word after it is silently dropped.
  cat <<'EOF' | write_task_brief "$case_dir"
Tidy the export button label.

## Out of scope

The billing screen is not part of this.

## What to build

Add a status column to the orders schema and backfill it from the ledger.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "exclevel-reset: a heading at the same depth must close the excluded section"
  assert_contains "$out" "schema" "exclevel-reset: work after the excluded section must be scanned"
  pass "fm-risk-tripwire closes an excluded section at the next heading of the same depth"
}

test_excluded_section_closes_at_a_shallower_heading() {
  local case_dir out status
  case_dir="$TMP_ROOT/exclevel-shallower"
  cat <<'EOF' | write_task_brief "$case_dir"
Tidy the export button label.

### Out of scope

The billing screen is not part of this.

## What to build

Add a status column to the orders schema and backfill it from the ledger.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "exclevel-shallower: a shallower heading must close the excluded section"
  assert_contains "$out" "schema" "exclevel-shallower: work after the excluded section must be scanned"
  pass "fm-risk-tripwire closes an excluded section at a shallower heading"
}

test_top_level_scope_heading_does_not_exclude() {
  local case_dir out status
  case_dir="$TMP_ROOT/exclevel-depth"
  # D1's depth guard. A column-0 "# " line in a task body is a shell comment in
  # an example command far more often than it is a section heading.
  cat <<'EOF' | write_task_brief "$case_dir"
Tidy the export button label.

# Out of scope

Add a status column to the orders schema and backfill it from the ledger.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "exclevel-depth: a top-level heading must not open an excluded section"
  assert_contains "$out" "schema" "exclevel-depth: text after it must still be scanned"
  pass "fm-risk-tripwire requires at least two hashes to open an excluded section"
}

test_scope_heading_without_a_blank_line_before_it_does_not_exclude() {
  local case_dir out status
  case_dir="$TMP_ROOT/exclevel-blankline"
  # D1's blank-line-precedence guard: every heading bin/fm-brief.sh emits is
  # blank-line-preceded, so a "##" line butted against prose is quoted text.
  cat <<'EOF' | write_task_brief "$case_dir"
Tidy the export button label. The reviewer asked for the section below verbatim:
## Out of scope

Add a status column to the orders schema and backfill it from the ledger.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "exclevel-blankline: a heading with no blank line before it must not exclude"
  assert_contains "$out" "schema" "exclevel-blankline: text after it must still be scanned"
  pass "fm-risk-tripwire requires a blank line before a heading that opens an excluded section"
}

test_list_item_starts_a_new_block() {
  local case_dir out status
  case_dir="$TMP_ROOT/block-list-boundary"
  # D2 drops a block as a unit, so the list-item boundary decides its blast
  # radius. Without it the prohibition bullet and the work bullet merge and the
  # work bullet goes with it.
  cat <<'EOF' | write_task_brief "$case_dir"
Tidy the export button label.

- Never touch the billing screen.
- Add a status column to the orders schema and backfill it from the ledger.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "block-list-boundary: a following bullet must not be swallowed by a prohibition bullet"
  assert_contains "$out" "schema" "block-list-boundary: the work bullet must be scanned on its own"
  pass "fm-risk-tripwire starts a new block at each list item"
}

test_blank_line_starts_a_new_block() {
  local case_dir out status
  case_dir="$TMP_ROOT/block-blank-boundary"
  # The paragraph counterpart of the boundary above. The prohibition leads, so
  # without the blank-line flush the whole body is one block and the block drop
  # takes the work paragraph down with it. The heading is there to keep the
  # narrowed text non-empty, so the whole-body fallback cannot mask the loss.
  cat <<'EOF' | write_task_brief "$case_dir"
## What to do

Never touch the billing screen.

Add a status column to the orders schema and backfill it from the ledger.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "block-blank-boundary: a following paragraph must not be swallowed by a prohibition paragraph"
  assert_contains "$out" "schema" "block-blank-boundary: the work paragraph must be scanned on its own"
  pass "fm-risk-tripwire starts a new block at each blank line"
}

test_empty_task_section_falls_back_to_the_whole_brief() {
  local case_dir out status
  case_dir="$TMP_ROOT/empty-task-body"
  # brief_task_body's own fallback: a "# Task" heading with nothing under it
  # before the next scaffold boundary must scan the whole file, not nothing.
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
  cat > "$case_dir/data/task-x1/brief.md" <<'EOF'
Rotate the signing secret and re-issue the session token.

# Task

# Setup
You are in a disposable worktree.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "empty-task-body: an empty task section must scan the whole brief, not nothing"
  assert_contains "$out" "secret" "empty-task-body: the whole file should be scanned"
  pass "fm-risk-tripwire scans the whole brief when the task section is empty"
}

test_descriptive_nothing_is_not_a_prohibition() {
  local case_dir out status
  case_dir="$TMP_ROOT/descriptive-nothing"
  # "nothing" reads as a non-change declaration only beside a change verb.
  # Here it is the subject of a defect report about a real table, which is how
  # a bug is described, and the recorded case that legitimately declares a
  # non-change scope with the same word is pinned separately as false-fire 5.
  cat <<'EOF' | write_task_brief "$case_dir"
Handle a frozen upload target in the accept route.

When the write times out midway the route still commits, so it inserts a photo row nothing links back to `sessions.slate_photo_id`, leaving a permanently orphaned record.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "descriptive-nothing: a defect described with 'nothing' must not read as a prohibition"
  assert_contains "$out" "session" "descriptive-nothing: the named table must be reported"
  pass "fm-risk-tripwire reads a bare 'nothing' as description, not as a declared non-change"
}

test_scope_qualifier_does_not_suppress_real_work() {
  local case_dir out status work expect i=0
  while IFS='|' read -r work expect; do
    [ -n "$work" ] || continue
    i=$((i + 1))
    case_dir="$TMP_ROOT/scope-qualifier-$i"
    # The benign first paragraph is load-bearing in the fixture: it keeps the
    # narrowed text non-empty so a rule that wrongly suppressed the work
    # sentence fails here instead of being masked by the fallback.
    printf 'Tidy the yard office release notes.\n\n%s\n' "$work" | write_task_brief "$case_dir"

    set +e
    out=$(run_brief_only "$case_dir")
    status=$?
    set -e

    expect_code 1 "$status" "scope-qualifier-$i: a scope qualifier must not read as a prohibition"
    assert_contains "$out" "$expect" "scope-qualifier-$i: should still surface the $expect term"
  done <<'EOF'
With no downtime, rotate the signing secret to the new KMS-held key.|secret
Without breaking the existing sign-in flow, replace the browser-held session cookie with a server-side record.|session
EOF
  pass "fm-risk-tripwire does not read a scope qualifier as a prohibition"
}

# The narrowing is a suppression test over a closed class of prohibition
# phrasings, deliberately NOT a corroboration test requiring a recognised change
# verb. Ways to describe work are an open word class: "move the session token
# out of localStorage" is the most ordinary phrasing of the most common
# auth-storage change there is, and no verb allowlist would contain every such
# verb. Putting the open class on the trip side is what keeps the safety
# direction right.
test_realistic_risky_brief_trips_without_a_recognised_change_verb() {
  local case_dir out status
  case_dir="$TMP_ROOT/no-verb-allowlist"
  cat <<'EOF' | write_task_brief "$case_dir"
## Background

The web client keeps people signed in after they quit the browser. On a shared machine the next person lands in the previous person's account.

## What to build

Move the session token out of `localStorage` and have the server hand it back as an httpOnly, SameSite=Lax cookie instead. The client should stop reading it at all.

## Acceptance criteria

1. Signing in, quitting the browser, and reopening it lands on the sign-in page.
2. The existing sign-in spec still passes with no edits.
3. Nothing is left behind in `localStorage` after sign-out.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "no-verb-allowlist: ordinary work phrasing must trip without a listed verb"
  assert_contains "$out" "session" "no-verb-allowlist: should surface the session term"
  assert_contains "$out" "token" "no-verb-allowlist: should surface the token term"
  pass "fm-risk-tripwire trips on real work phrased without any recognised change verb"
}

# A heading is the most compressed statement of what its section is about, so it
# is always scanned even when it opens a section the narrowing excludes.
test_risk_word_in_excluded_section_heading_still_trips() {
  local case_dir out status
  case_dir="$TMP_ROOT/excluded-heading"
  cat <<'EOF' | write_task_brief "$case_dir"
Rename a button label in the toolbar.

## Out of scope - the session store
Nothing in here moves.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "excluded-heading: a risk word in the heading itself must still trip"
  assert_contains "$out" "session" "excluded-heading: should surface the term from the heading"
  pass "fm-risk-tripwire still scans a heading that opens an excluded section"
}

# The section exclusion keys on explicit scope-declaration phrases, never on
# bare negation, because bug-report headings describe broken behaviour with
# "not" and "never" constantly. Keying it on those words was measured to clear
# genuinely auth-bearing briefs outright, so this pins the narrower rule.
test_descriptive_negation_heading_is_not_a_scope_exclusion() {
  local case_dir out status heading
  for heading in 'Finding 1 - the value is never resolved relative to cwd' \
                 'Finding 2 - the mode promise is not kept on rename'; do
    case_dir="$TMP_ROOT/descriptive-negation-${heading%% *}${RANDOM}"
    {
      printf 'Close the review findings.\n\n## %s\n' "$heading"
      printf 'The loader must resolve it before the schema check runs.\n'
    } | write_task_brief "$case_dir"

    set +e
    out=$(run_brief_only "$case_dir")
    status=$?
    set -e

    expect_code 1 "$status" "descriptive-negation: a descriptive '$heading' must not exclude its section"
    assert_contains "$out" "schema" "descriptive-negation: the section body must still be scanned"
  done
  pass "fm-risk-tripwire treats bare negation in a heading as description, not scope exclusion"
}

# A column-0 "# " line in the task body is a shell comment in an example
# command, not a section heading. One that happens to read like a scope
# declaration must not open an excluded region, or every risk word after it is
# dropped to the end of the brief.
test_shell_comment_cannot_open_an_excluded_section() {
  local case_dir out status
  case_dir="$TMP_ROOT/shell-comment-scope"
  cat <<'EOF' | write_task_brief "$case_dir"
Wire up the deploy runner.
Example invocation:
# do not change the orders schema by hand
./run up
Then rotate the signing secret and restart.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "shell-comment-scope: a '# ' comment must not exclude the rest of the body"
  assert_contains "$out" "secret" "shell-comment-scope: risk text after the comment must still be scanned"
  pass "fm-risk-tripwire does not let a shell comment open an excluded section"
}

# The counterpart: a heading that really does declare a non-change scope closes
# its section, which is what cleared the eighth recorded false fire.
test_scope_declaring_heading_excludes_its_section() {
  local case_dir out status
  case_dir="$TMP_ROOT/scope-declaring"
  cat <<'EOF' | write_task_brief "$case_dir"
Add an option to the dropdown.

## What should NOT need changing, but verify rather than assume
The package schema and the persistence path carry it as a plain number already.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 0 "$status" "scope-declaring: a declared non-change section must not trip"
  [ -z "$out" ] || fail "scope-declaring: expected no RISK output, got: $out"
  pass "fm-risk-tripwire excludes a section whose heading declares a non-change scope"
}

# Failing toward tripping is correct: if the narrowing would leave nothing at
# all to scan, the full task body is scanned instead rather than passing silent.
test_all_prohibition_brief_falls_back_and_still_trips() {
  local case_dir out status
  case_dir="$TMP_ROOT/all-prohibition"
  cat <<'EOF' | write_task_brief "$case_dir"
- Never touch the session store.
- Do not run the schema migration by hand.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "all-prohibition: narrowing must never empty the scan into a silent pass"
  assert_contains "$out" "session" "all-prohibition: fallback should scan the whole task body"
  pass "fm-risk-tripwire falls back to the full task body when narrowing would empty the scan"
}

# Descriptive negation is how a bug report states the defect a task exists to
# fix, so it must not read as a prohibition. Only language addressed to the
# worker ("do not rotate it") fences work off; language about the system ("it
# does not rotate") is the work itself. The benign first paragraph keeps the
# narrowed text non-empty so a wrong answer fails here rather than being masked
# by the empty-narrowing fallback.
test_descriptive_negation_sentence_is_not_a_prohibition() {
  local case_dir out status sentence i=0
  while IFS= read -r sentence; do
    [ -n "$sentence" ] || continue
    i=$((i + 1))
    case_dir="$TMP_ROOT/descriptive-sentence-$i"
    printf 'Fix the sign-in bug reported from the yard office.\n\n%s\n' "$sentence" \
      | write_task_brief "$case_dir"

    set +e
    out=$(run_brief_only "$case_dir")
    status=$?
    set -e

    expect_code 1 "$status" "descriptive-sentence-$i: a described defect must not read as a prohibition"
    assert_contains "$out" "session" "descriptive-sentence-$i: should still surface the session term"
  done <<'EOF'
The login handler does not rotate the session identifier on sign-in.
The login handler cannot rotate the session identifier on sign-in.
Sign-out will not clear the session identifier.
EOF
  pass "fm-risk-tripwire treats described defects as work, not as prohibitions"
}

# The narrowing assumes the shape of the "# Task" region firstmate writes. A
# brief whose heading the section matcher does not recognise has no such region,
# so the whole file is scanned unnarrowed rather than narrowed on an assumption
# that does not hold. The parseable twin proves the unscoped path is what
# produced the hit.
test_unparseable_task_heading_is_scanned_unscoped() {
  local case_dir out status
  case_dir="$TMP_ROOT/unparseable-heading"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
  cat > "$case_dir/data/task-x1/brief.md" <<'EOF'
# Task - VALIDATION RESUME (do NOT re-implement)

Pick the validation run back up where it stopped.

## Constraints

- Never touch the session store or the credentials directory.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "unparseable-heading: an unrecognised '# Task' heading must be scanned unscoped"
  assert_contains "$out" "session" "unparseable-heading: the whole file should be scanned"

  # Same brief, parseable heading: the narrowing applies and the fencing prose
  # is dropped, so the two paths are demonstrably different.
  cat > "$case_dir/data/task-x1/brief.md" <<'EOF'
# Task

Pick the validation run back up where it stopped.

## Constraints

- Never touch the session store or the credentials directory.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 0 "$status" "unparseable-heading: the parseable twin must narrow to clean"
  pass "fm-risk-tripwire scans a brief with an unrecognised Task heading unscoped"
}

# A hand-written brief with no scaffold structure at all is the case the scanner
# cannot parse. It must still trip, even when every sentence in it is fencing
# prose the narrowing would otherwise drop.
test_unparseable_constraint_only_brief_still_trips() {
  local case_dir out status
  case_dir="$TMP_ROOT/unparseable"
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"
  cat > "$case_dir/data/task-x1/brief.md" <<'EOF'
Never read or modify anything under the credentials directory.
Do not run the schema migration by hand.
EOF

  set +e
  out=$(run_brief_only "$case_dir")
  status=$?
  set -e

  expect_code 1 "$status" "unparseable: an unstructured brief must trip rather than pass silently"
  assert_contains "$out" "credentials" "unparseable: the whole file should be scanned"
  pass "fm-risk-tripwire still trips on a brief it cannot structurally parse"
}

test_clean_brief_and_diff_passes
test_bare_auth_matches_but_authoritative_does_not
test_adjacent_keywords_both_reported
test_unresolvable_diff_base_is_not_a_clean_pass
test_unresolvable_diff_base_still_reports_brief_hit
test_diff_command_failure_after_base_resolved_is_not_a_clean_pass
test_diff_command_failure_still_reports_brief_hit
test_multiword_phrase_keyword_trips
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
test_recorded_false_fires_no_longer_trip
test_every_match_term_trips_beside_constraint_prose
test_task_prose_term_trips_while_constraint_terms_stay_quiet
test_work_sentence_beside_prohibition_in_same_block_still_trips
test_prohibition_conceding_adjacent_work_still_trips
test_standing_prohibition_without_conceded_work_stays_quiet
test_work_clause_survives_a_trailing_prohibition_clause
test_leading_prohibition_clause_still_suppresses_its_own_sentence
test_fenced_scope_heading_cannot_open_an_excluded_section
test_unbounded_no_change_span_does_not_suppress_motivation_prose
test_declared_no_change_phrase_is_still_suppressed
test_excluded_section_closes_at_the_next_heading
test_excluded_section_closes_at_a_shallower_heading
test_top_level_scope_heading_does_not_exclude
test_scope_heading_without_a_blank_line_before_it_does_not_exclude
test_list_item_starts_a_new_block
test_blank_line_starts_a_new_block
test_empty_task_section_falls_back_to_the_whole_brief
test_descriptive_nothing_is_not_a_prohibition
test_scope_qualifier_does_not_suppress_real_work
test_realistic_risky_brief_trips_without_a_recognised_change_verb
test_risk_word_in_excluded_section_heading_still_trips
test_descriptive_negation_heading_is_not_a_scope_exclusion
test_shell_comment_cannot_open_an_excluded_section
test_scope_declaring_heading_excludes_its_section
test_all_prohibition_brief_falls_back_and_still_trips
test_descriptive_negation_sentence_is_not_a_prohibition
test_unparseable_task_heading_is_scanned_unscoped
test_unparseable_constraint_only_brief_still_trips

echo "# all fm-risk-tripwire tests passed"
