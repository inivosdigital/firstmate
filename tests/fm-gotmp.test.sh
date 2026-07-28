#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each task a temp root /tmp/fm-<id>/ with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the task's
# meta. fm-teardown reads tasktmp= and removes the whole root on cleanup.
#
# These tests exercise behavior directly: fm-teardown is run as a subprocess against a
# fake FM_HOME/FM_ROOT (built so the real script resolves into it), with stub helper scripts.
# Nothing is sourced. The fm-spawn side is verified both structurally (the source has
# the contract lines) and behaviorally (the mkdir + meta-write pattern it uses).
set -u

# This suite does not source tests/lib.sh, so exempt its teardown subprocess from
# the gate-lifecycle refusal (bin/fm-gate-refuse-lib.sh) the way lib.sh does for
# the rest of the suite: the no-mistakes gate runs this suite from a gate worktree,
# which the guard would otherwise refuse.
export FM_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
# shellcheck source=bin/fm-tmp-lib.sh
. "$ROOT/bin/fm-tmp-lib.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-gotmp-tests.XXXXXX")

# Build a fake FM_HOME/FM_ROOT so the real fm-teardown.sh (symlinked in) resolves
# state and helper scripts inside it. Stub the helper scripts fm-teardown calls so no
# live tmux/treehouse/fleet state is touched. A nonexistent worktree path makes both
# `if [ -d "$WT" ]` guards skip, so teardown runs straight to the cleanup + state rm.
make_fake_root() {
  local id=$1 tasktmp=$2
  local fake="$TMP_ROOT/$id"
  mkdir -p "$fake/bin/backends" "$fake/state"
  # Symlink the REAL teardown so the test exercises actual code, not a copy.
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  # fm-backend.sh + its tmux adapter: symlink the REAL files (teardown sources
  # fm-backend.sh unconditionally, and dispatches the kill call through the
  # tmux adapter; both are unchanged by this suite's fixture, just newly
  # required siblings since the P1 backend extraction).
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  # fm-lock-lib.sh: teardown sources it for the shared lock-staleness proof.
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-tmp-lib.sh + its own fm-ff-lib.sh dependency: teardown sources it
  # unconditionally for remove_harness_scratch's live-session lookup.
  ln -s "$ROOT/bin/fm-tmp-lib.sh" "$fake/bin/fm-tmp-lib.sh"
  ln -s "$ROOT/bin/fm-ff-lib.sh" "$fake/bin/fm-ff-lib.sh"
  # fm-guard.sh: stub (teardown calls it with `|| true`).
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  # fm-fleet-sync.sh: stub (called for non-scout/non-local-only teardowns).
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  # fm-nas-deploy-sync.sh: stub (called for the same non-scout/non-local-only
  # teardowns, right after fm-fleet-sync.sh).
  cat > "$fake/bin/fm-nas-deploy-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-nas-deploy-sync.sh"
  # fm-tasks-axi-lib.sh: stub (teardown sources it). Report no backend so
  # backlog_refresh_reminder takes the plain-message path; no tasks-axi here.
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  # Meta with a nonexistent worktree so the dirty/treehouse blocks skip.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-worktree-$id
project=$TMP_ROOT/nonexistent-project-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$tasktmp
META
  printf '%s' "$fake"
}

# --- fm-spawn side ---

test_spawn_contract_and_mkdir_pattern() {
  # Structural: fm-spawn must create the gotmp dir, record tasktmp in meta, and export
  # GOTMPDIR into the pane. Assert the contract lines are present in the source.
  # shellcheck disable=SC2016  # single quotes are deliberate: these are literal source strings
  grep -F 'mkdir -p "$TASK_TMP/gotmp"' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: mkdir of gotmp under TASK_TMP"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source string
  grep -F 'echo "tasktmp=$TASK_TMP"' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: tasktmp= line in meta write"
  grep -F 'export GOTMPDIR=' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: GOTMPDIR export into pane"
  # Behavioral: the mkdir + meta-write pattern spawn uses must produce a gotmp dir and
  # a meta line whose value the teardown grep (tasktmp=, cut -d= -f2-) reads back whole.
  local id=spawn-sim-z1
  local sim_root="$TMP_ROOT/$id-root"
  local task_tmp="$sim_root/tmp/fm-$id"
  mkdir -p "$sim_root/state"
  # Replicate spawn's exact mkdir + meta-write lines.
  TASK_TMP="$task_tmp"
  mkdir -p "$TASK_TMP/gotmp"
  {
    echo "tasktmp=$TASK_TMP"
  } > "$sim_root/state/$id.meta"
  [ -d "$task_tmp/gotmp" ] || fail "simulated spawn did not create gotmp dir"
  # Teardown reads tasktmp= with `grep '^tasktmp=' | cut -d= -f2-`; round-trip it.
  local read_back
  read_back=$(grep '^tasktmp=' "$sim_root/state/$id.meta" | cut -d= -f2-)
  [ "$read_back" = "$task_tmp" ] \
    || fail "tasktmp value not round-tripped by teardown's grep|cut (got '$read_back')"
  pass "fm-spawn creates gotmp dir and records tasktmp in meta"
}

# --- fm-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2
  local task_tmp="$TMP_ROOT/fm-$id"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  # Sanity: dir + contents exist before teardown.
  [ -d "$task_tmp/gotmp" ] || fail "precondition: gotmp missing before teardown"
  # Run the REAL teardown against the fake root.
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero with a valid tasktmp"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"
  pass "fm-teardown removes the dir pointed to by tasktmp= in meta"
}

test_remove_harness_scratch_uses_verified_claude_convention() {
  # Structural + direct-unit hybrid, the same shape test_spawn_contract_and_
  # mkdir_pattern above uses for fm-spawn.sh: fm-teardown.sh has no main()
  # guard (its bottom half is unconditional top-level script, not a callable
  # entry point), so it cannot be sourced for a clean function-only test the
  # way fm-tmp-lib.sh's own functions are. First assert the real call sites
  # are actually wired (grep on the literal source line, at all three removal
  # paths: orca, treehouse-pool, and secondmate retirement). Then pull the
  # real remove_harness_scratch function body verbatim out of the file and
  # exercise it directly - not a re-typed copy, the actual code - against a
  # real directory under /tmp/claude-<uid>/ (remove_harness_scratch has no
  # FM_TMP_SWEEP_ROOT-style test seam, so this really touches that path,
  # exactly like production; the id keeps it unique and cleanup runs even on
  # failure).
  local call_sites
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source strings
  call_sites=$(grep -c 'remove_harness_scratch "\$HARNESS" "\$WT"' "$TEARDOWN")
  [ "$call_sites" -eq 2 ] \
    || fail "expected 2 remove_harness_scratch \"\$HARNESS\" \"\$WT\" call sites (orca + treehouse-pool), found $call_sites"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source string
  grep -F 'remove_harness_scratch "$HARNESS" "$HOME_PATH"' "$TEARDOWN" >/dev/null \
    || fail "fm-teardown missing the secondmate-retirement remove_harness_scratch call site"

  local fn_body worktree scratch
  fn_body=$(sed -n '/^remove_harness_scratch() {/,/^}/p' "$TEARDOWN")
  [ -n "$fn_body" ] || fail "could not extract remove_harness_scratch's body from fm-teardown.sh"
  worktree="$TMP_ROOT/rhs-worktree-z7"
  scratch=$(fm_tmp_harness_scratch_dir claude "$worktree")
  mkdir -p "$scratch"
  printf 'session\n' > "$scratch/session.json"
  # shellcheck disable=SC1090  # dynamically extracted from the real file above, not a literal path
  eval "$fn_body"
  if ! remove_harness_scratch claude "$worktree" 2>/dev/null; then
    rm -rf "$scratch"
    fail "remove_harness_scratch returned non-zero for a real, verified-harness scratch dir"
  fi
  if [ -e "$scratch" ]; then
    rm -rf "$scratch"
    fail "remove_harness_scratch did not remove the claude scratch dir it computed ($scratch still exists)"
  fi
  pass "remove_harness_scratch is wired at all three removal call sites and actually removes a claude scratch dir"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake="$TMP_ROOT/$id-root"
  mkdir -p "$fake/bin/backends" "$fake/state"
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-tmp-lib.sh + its own fm-ff-lib.sh dependency: teardown sources it
  # unconditionally for remove_harness_scratch's live-session lookup.
  ln -s "$ROOT/bin/fm-tmp-lib.sh" "$fake/bin/fm-tmp-lib.sh"
  ln -s "$ROOT/bin/fm-ff-lib.sh" "$fake/bin/fm-ff-lib.sh"
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  cat > "$fake/bin/fm-nas-deploy-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-nas-deploy-sync.sh"
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  # No tasktmp= line at all.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-wt-$id
project=$TMP_ROOT/nonexistent-proj-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
META
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp= was absent"
  pass "fm-teardown skips gracefully when tasktmp= is absent (backward compat)"
}

test_teardown_skips_gracefully_when_dir_missing() {
  # tasktmp= points to a path that does not exist. Teardown must not error.
  local id=td-missing-z4
  local task_tmp="$TMP_ROOT/never-created-fm-$id"
  # Intentionally do NOT create $task_tmp.
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "fm-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_spawn_contract_and_mkdir_pattern
test_teardown_removes_tasktmp_dir
test_remove_harness_scratch_uses_verified_claude_convention
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
