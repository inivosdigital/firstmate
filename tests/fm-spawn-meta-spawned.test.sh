#!/usr/bin/env bash
# tests/fm-spawn-meta-spawned.test.sh - behavior tests for the task creation
# epoch bin/fm-spawn.sh records as `spawned=` in state/<id>.meta.
#
# The busy-turn bound in bin/fm-watch.sh reads that field as the one proof of
# life every harness has, armed or not: a task whose first turn has not ended
# yet is measured from its own creation instead of having no start at all. What
# the bound needs from this writer is that the field is there after any spawn,
# and that a second spawn over an existing record keeps the epoch already there
# rather than stamping a new one, since a later stamp could only postpone that
# alarm. A record that names two epochs, or one this side cannot read, names no
# start at all: the rewrite carries none forward rather than choosing one, and
# the task is bounded as having no start until its next turn ends.
#
# Drives the REAL bin/fm-spawn.sh, following tests/fm-memcap.test.sh's spawn
# fixture: a fake tmux answers the pane-cwd query with a real git worktree
# shaped like a treehouse pool slot, so the worktree-isolation assertion passes
# with no treehouse, no harness process, and no live watcher.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

# A fake tmux that reports FM_FAKE_PANE_PATH as the pane's cwd after the
# worktree step, names the session on '#S', and swallows every window op.
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
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

spawn_fixture() {  # <tmp> -> echoes "<proj> <wt> <fakebin>"
  local tmp=$1 proj wt fakebin
  proj="$tmp/proj"
  fm_git_init_commit "$proj"
  wt="$tmp/pool-a1b2c3/1/proj"
  git -C "$proj" worktree add -q --detach "$wt" || fail "setup: worktree add failed"
  fakebin=$(make_spawn_fakebin "$tmp/fake")
  printf '%s %s %s\n' "$proj" "$wt" "$fakebin"
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
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "$@" 2>&1
}

# The recorded epoch as the shared metadata reader would resolve it: the LAST
# matching line. Only for cases that have established the field appears once -
# a duplicate case asserted through this would report whichever line came last
# and call that the record's value, which is the very confusion under test.
spawned_of() {  # <meta>
  grep '^spawned=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Every recorded epoch in file order, comma separated, selecting nothing.
spawned_values() {  # <meta>
  grep '^spawned=' "$1" 2>/dev/null | cut -d= -f2- | paste -sd, - || true
}

# One line, not an accumulating history: the bound reads the last value, so a
# file gaining a second one would make the field's meaning depend on which
# writer ran last.
spawned_count() {  # <meta>
  grep -c '^spawned=' "$1" 2>/dev/null || true
}

# Put <value> in the recorded field, leaving every other line alone (rewrite
# and move, so the edit is portable and never leaves a stray backup behind).
set_spawned() {  # <meta> <value>
  local meta=$1 value=$2
  sed "s/^spawned=.*/spawned=$value/" "$meta" > "$meta.edit" || fail "setup: could not rewrite $meta"
  mv "$meta.edit" "$meta"
}

test_spawn_records_the_creation_epoch() {
  local tmp proj wt fakebin out meta before after epoch
  tmp=$(fm_test_tmproot fm-spawn-meta-spawned-fresh)
  read -r proj wt fakebin <<EOF
$(spawn_fixture "$tmp")
EOF
  meta="$tmp/home/state/spawned-fresh.meta"

  before=$(date +%s)
  out=$(run_spawn "$tmp/home" spawned-fresh "$proj" "$wt" "$fakebin" codex --mode no-mistakes --yolo off)
  after=$(date +%s)
  assert_contains "$out" "spawned spawned-fresh" "spawn should succeed"

  epoch=$(spawned_of "$meta")
  [ -n "$epoch" ] || fail "a spawn recorded no creation epoch: $(cat "$meta")"
  case "$epoch" in ''|*[!0-9]*) fail "recorded creation epoch is not an epoch: '$epoch'" ;; esac
  [ "$epoch" -ge "$before" ] && [ "$epoch" -le "$after" ] \
    || fail "recorded creation epoch $epoch is outside the spawn window $before..$after"
  [ "$(spawned_count "$meta")" = 1 ] || fail "a spawn recorded more than one creation epoch: $(cat "$meta")"
  pass "fm-spawn records the task's creation epoch in its metadata"
}

# A relaunch through this script rewrites the whole metadata file. The epoch it
# already holds survives that rewrite, so a task recovered hours into a call
# cannot be handed a start later than the call the bound is measuring.
test_relaunch_keeps_the_recorded_epoch() {
  local tmp proj wt fakebin out meta old
  tmp=$(fm_test_tmproot fm-spawn-meta-spawned-relaunch)
  read -r proj wt fakebin <<EOF
$(spawn_fixture "$tmp")
EOF
  meta="$tmp/home/state/spawned-relaunch.meta"

  out=$(run_spawn "$tmp/home" spawned-relaunch "$proj" "$wt" "$fakebin" codex --mode no-mistakes --yolo off)
  assert_contains "$out" "spawned spawned-relaunch" "first spawn should succeed"

  old=$(( $(date +%s) - 9000 ))
  set_spawned "$meta" "$old"
  [ "$(spawned_of "$meta")" = "$old" ] || fail "setup: the recorded epoch was not backdated"

  out=$(run_spawn "$tmp/home" spawned-relaunch "$proj" "$wt" "$fakebin" codex --mode no-mistakes --yolo off)
  assert_contains "$out" "spawned spawned-relaunch" "relaunch should succeed"
  [ "$(spawned_of "$meta")" = "$old" ] \
    || fail "a relaunch advanced the creation epoch to $(spawned_of "$meta"), expected $old"
  [ "$(spawned_count "$meta")" = 1 ] || fail "a relaunch left more than one creation epoch: $(cat "$meta")"
  pass "a relaunch carries the recorded creation epoch forward instead of stamping a new one"
}

# A record already naming two epochs names no single one, and this writer may
# not settle that by keeping either: writing the later one back as the sole
# value would make an appended line permanent and push the wedge alarm out by a
# full bound every time one appears. The rewritten record carries no epoch, so
# the task counts as having no start until its next turn ends.
#
# The fixture is the reviewer's respawn-duplicate probe from the independent
# review of 515f00b, whose run showed before_count=2 collapsing to after_count=1
# holding the later value. Asserted through spawned_values, which selects
# nothing, because the reader that selects the last value is what hid this.
test_respawn_does_not_canonize_a_duplicate_epoch() {
  local tmp proj wt fakebin out meta old fresh
  tmp=$(fm_test_tmproot fm-spawn-meta-spawned-duplicate)
  read -r proj wt fakebin <<EOF
$(spawn_fixture "$tmp")
EOF
  meta="$tmp/home/state/spawned-duplicate.meta"

  out=$(run_spawn "$tmp/home" spawned-duplicate "$proj" "$wt" "$fakebin" codex --mode no-mistakes --yolo off)
  assert_contains "$out" "spawned spawned-duplicate" "first spawn should succeed"

  old=$(( $(date +%s) - 9000 ))
  fresh=$(date +%s)
  set_spawned "$meta" "$old"
  printf 'spawned=%s\n' "$fresh" >> "$meta"
  [ "$(spawned_values "$meta")" = "$old,$fresh" ] \
    || fail "setup: the record does not hold both epochs in order: $(spawned_values "$meta")"

  out=$(run_spawn "$tmp/home" spawned-duplicate "$proj" "$wt" "$fakebin" codex --mode no-mistakes --yolo off)
  assert_contains "$out" "spawned spawned-duplicate" "relaunch should succeed"
  [ "$(spawned_values "$meta")" = "" ] \
    || fail "a relaunch settled an ambiguous record on '$(spawned_values "$meta")' instead of leaving it without one"
  pass "a relaunch over two recorded epochs writes neither back"
}

# A value the bound cannot parse names no epoch either, and the same rule
# applies: this writer carries an epoch forward, it does not invent one to
# stand in for a value it cannot read.
test_unreadable_recorded_epoch_is_dropped() {
  local tmp proj wt fakebin out meta
  tmp=$(fm_test_tmproot fm-spawn-meta-spawned-corrupt)
  read -r proj wt fakebin <<EOF
$(spawn_fixture "$tmp")
EOF
  meta="$tmp/home/state/spawned-corrupt.meta"

  out=$(run_spawn "$tmp/home" spawned-corrupt "$proj" "$wt" "$fakebin" codex --mode no-mistakes --yolo off)
  assert_contains "$out" "spawned spawned-corrupt" "first spawn should succeed"
  set_spawned "$meta" yesterday

  out=$(run_spawn "$tmp/home" spawned-corrupt "$proj" "$wt" "$fakebin" codex --mode no-mistakes --yolo off)
  assert_contains "$out" "spawned spawned-corrupt" "relaunch should succeed"
  [ "$(spawned_values "$meta")" = "" ] \
    || fail "an unreadable creation epoch became '$(spawned_values "$meta")' instead of none"
  pass "an unreadable creation epoch is dropped rather than replaced with a fresh one"
}

test_spawn_records_the_creation_epoch
test_relaunch_keeps_the_recorded_epoch
test_respawn_does_not_canonize_a_duplicate_epoch
test_unreadable_recorded_epoch_is_dropped
