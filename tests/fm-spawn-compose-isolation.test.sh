#!/usr/bin/env bash
# tests/fm-spawn-compose-isolation.test.sh - behavior tests for the
# docker-compose project-name isolation marker (AGENTS.md "Layout and state",
# bin/fm-spawn.sh's fm_compose_project_name).
#
# Two treehouse worktrees of the SAME project always share the same leaf
# directory basename (e.g. both are checked out at .../<pool>/<slot>/wealthsync),
# so Compose's default project-naming (derived from cwd basename) collides
# across them on container/volume/network names. fm-spawn.sh now derives a
# stable name from the worktree's own pool-slot path and drops it at
# <worktree>/.treehouse-compose-project, git-excluded so it never pollutes a
# crewmate's dirty-worktree check or commits, and records it in the task's
# meta as compose_project=<name>.
#
# Drives the REAL bin/fm-spawn.sh end to end, exactly like
# tests/fm-tangle-guard.test.sh's isolation-abort case: a fake tmux reports
# FM_FAKE_PANE_PATH as the post-`treehouse get` pane cwd, and a real git
# worktree is added at a path shaped like a genuine treehouse pool slot
# (.../<pool>-<hash>/<slot>/<repo-leaf-name>) so fm_compose_project_name sees
# realistic input. `treehouse` itself is stubbed to exit 0 (unused: the fake
# tmux answers the cwd query directly).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

# A fake tmux that reports FM_FAKE_PANE_PATH as the pane's cwd after
# `treehouse get`, names the session on '#S', and swallows window ops.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn() {  # <home> <id> <proj> <pane> <fakebin> [extra-args...]
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5
  shift 5
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex "$@" 2>&1
}

# --- two worktrees of the same project, same leaf basename, different pool
# slots: this is the exact near-miss from the wealthsync incident this fix
# targets. Each must get its own compose_project name. --------------------

test_two_worktrees_same_leaf_get_distinct_compose_names() {
  local tmp proj fakebin wt_a wt_b out_a out_b
  tmp=$(fm_test_tmproot fm-spawn-compose)
  proj=$(fm_git_init_commit "$tmp/proj" && printf '%s\n' "$tmp/proj")
  fakebin=$(make_spawn_fakebin "$tmp/fake")

  # Two pool-slot worktrees of the SAME project, sharing the leaf name
  # "wealthsync" - mirrors a real treehouse pool: <pool>-<hash>/<slot>/<repo>.
  wt_a="$tmp/wealthsync-323ec0/2/wealthsync"
  wt_b="$tmp/wealthsync-323ec0/7/wealthsync"
  git -C "$proj" worktree add -q --detach "$wt_a" || fail "setup: worktree add (slot 2) failed"
  git -C "$proj" worktree add -q --detach "$wt_b" || fail "setup: worktree add (slot 7) failed"

  out_a=$(run_spawn "$tmp/home" wealthsync-task-a "$proj" "$wt_a" "$fakebin")
  expect_code 0 "$?" "spawn into pool slot 2 should succeed"
  assert_contains "$out_a" "spawned wealthsync-task-a" "slot-2 spawn did not report success"

  out_b=$(run_spawn "$tmp/home" wealthsync-task-b "$proj" "$wt_b" "$fakebin")
  expect_code 0 "$?" "spawn into pool slot 7 should succeed"
  assert_contains "$out_b" "spawned wealthsync-task-b" "slot-7 spawn did not report success"

  assert_present "$wt_a/.treehouse-compose-project" "slot-2 worktree missing the compose-project marker"
  assert_present "$wt_b/.treehouse-compose-project" "slot-7 worktree missing the compose-project marker"

  local name_a name_b
  name_a=$(cat "$wt_a/.treehouse-compose-project")
  name_b=$(cat "$wt_b/.treehouse-compose-project")

  [ "$name_a" = "wealthsync-323ec0-2" ] || fail "slot-2 compose project name: expected 'wealthsync-323ec0-2', got '$name_a'"
  [ "$name_b" = "wealthsync-323ec0-7" ] || fail "slot-7 compose project name: expected 'wealthsync-323ec0-7', got '$name_b'"
  [ "$name_a" != "$name_b" ] || fail "two worktrees of the same project must not collide on the same compose project name"

  assert_grep "compose_project=$name_a" "$tmp/home/state/wealthsync-task-a.meta" "task-a meta missing compose_project="
  assert_grep "compose_project=$name_b" "$tmp/home/state/wealthsync-task-b.meta" "task-b meta missing compose_project="

  pass "fm-spawn: two worktrees of the same project (same leaf basename, different pool slots) get distinct, stable compose_project names"
}

# --- the marker must be invisible to the worktree's own git status, so it
# never trips teardown's dirty-worktree check or leaks into a crewmate commit.

test_marker_is_git_excluded() {
  local tmp proj fakebin wt status_out
  tmp=$(fm_test_tmproot fm-spawn-compose-excl)
  proj=$(fm_git_init_commit "$tmp/proj" && printf '%s\n' "$tmp/proj")
  fakebin=$(make_spawn_fakebin "$tmp/fake")

  wt="$tmp/excltest-9ab1/3/excltest"
  git -C "$proj" worktree add -q --detach "$wt" || fail "setup: worktree add failed"

  run_spawn "$tmp/home" excl-task-c "$proj" "$wt" "$fakebin" >/dev/null
  expect_code 0 "$?" "spawn should succeed"
  assert_present "$wt/.treehouse-compose-project" "worktree missing the compose-project marker"

  status_out=$(git -C "$wt" status --porcelain)
  assert_not_contains "$status_out" ".treehouse-compose-project" "compose-project marker must be git-excluded, not shown as untracked"

  pass "fm-spawn: the compose-project marker is excluded from the worktree's own git status"
}

# Secondmate spawns never write the marker (a secondmate runs in its own
# persistent firstmate home, not a per-task pool worktree). Setting up a real
# secondmate home's full validation contract (SUB_HOME_MARKER, AGENTS.md,
# bin/, registry) duplicates tests/fm-secondmate-lifecycle-e2e.test.sh's own
# fixture, so that suite's phase_spawn carries the corresponding assertions
# instead of re-deriving the fixture here.

test_two_worktrees_same_leaf_get_distinct_compose_names
test_marker_is_git_excluded
