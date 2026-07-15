#!/usr/bin/env bash
# Behavior tests for fm-nas-deploy-sync.sh.
#
# A merged PR does not, by itself, reach the live site: every deployed app runs
# from its own separate checkout under /mnt/nas/experiments/<name>/, managed by
# pm2, independent from the projects/<name> clone firstmate/crewmates develop in
# (see the 2026-07-04 entry in data/learnings.md). fm-nas-deploy-sync.sh closes
# that gap: fast-forward the NAS checkout, restart and verify the pm2
# process(es) that serve it - mirroring bin/fm-fleet-sync.sh's dirty/diverged
# safety exactly (never force, never touch a dirty or diverged checkout).
#
# This suite never touches a real /mnt/nas/experiments/ path or a real pm2
# process: NAS checkouts are throwaway git repos under a per-test tmp home, and
# pm2 is a PATH-shimmed stub that records restarts and reports them online.
#
# Covers:
#   - a clean, behind checkout fast-forwards and its pm2 process(es) restart and
#     verify online
#   - a dirty checkout is left completely untouched (reported, not fast-forwarded)
#   - a diverged checkout is reported STUCK-style and left completely untouched
#   - a project absent from data/nas-deployments.md (or the file itself absent)
#     is a silent no-op: one skip line, exit 0
#   - bin/fm-teardown.sh's post-landing hook actually invokes the real script for
#     a landed ship task, end to end (the NAS fixture fast-forwards and its pm2
#     process is restarted as a side effect of running teardown)
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SYNC="$ROOT/bin/fm-nas-deploy-sync.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-nas-deploy-sync-tests)
HOME_N=0

# --- generic fixtures --------------------------------------------------------

new_home() {
  HOME_N=$((HOME_N + 1))
  local h="$TMP_ROOT/home-$HOME_N"
  mkdir -p "$h/data" "$h/fakebin"
  printf '%s\n' "$h"
}

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add -- "$file"
  git -C "$dir" commit -qm "$msg"
}

# build_nas_pair <home> <name>: a bare "remote" origin plus a "work" repo wired to
# it (for advancing origin later) and a plain clone standing in for the NAS
# checkout, all with one commit on main. Echoes the NAS checkout path.
build_nas_pair() {
  local home=$1 name=$2 work remote nas remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  nas="$home/nas-$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0

  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  git clone --quiet "file://$remote_abs" "$nas"
  printf '%s\n' "$nas"
}

# advance_origin <home> <name> <msg>: push one more commit to <name>'s origin via
# its work repo, so the NAS checkout (until synced) is behind origin/main.
advance_origin() {
  local home=$1 name=$2 msg=$3 work
  work="$home/work-$name"
  commit_file "$work" file.txt "$msg" "$msg"
  git -C "$work" push -q origin main
}

head_sha() { git -C "$1" rev-parse HEAD; }

# write_map <home> <project> <nas_path> <pm2_procs>: (re)write a one-row
# nas-deployments.md pipe table at $home/data/nas-deployments.md.
write_map() {
  local home=$1 project=$2 nas_path=$3 procs=$4
  {
    printf '| project | nas_repo_path | pm2_process(es) |\n'
    printf '| --- | --- | --- |\n'
    printf '| %s | %s | %s |\n' "$project" "$nas_path" "$procs"
  } > "$home/data/nas-deployments.md"
}

# write_pm2_stub <fakebin> <restart_log>: `pm2 restart <name>` appends <name> to
# $restart_log and succeeds; `pm2 jlist` reports every logged name as online, so a
# process comes back "online" exactly when (and only when) it was restarted.
write_pm2_stub() {
  local fakebin=$1 log=$2
  : > "$log"
  cat > "$fakebin/pm2" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  restart)
    printf '%s\n' "\$2" >> "$log"
    exit 0
    ;;
  jlist)
    printf '['
    first=1
    while IFS= read -r name; do
      [ -n "\$name" ] || continue
      [ "\$first" = 1 ] || printf ','
      first=0
      printf '{"name":"%s","pm2_env":{"status":"online"}}' "\$name"
    done < "$log"
    printf ']\n'
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/pm2"
}

# write_pm2_cluster_stub <fakebin> <restart_log> <proc>: like write_pm2_stub, but
# `pm2 jlist` always reports TWO instances of <proc> - one online, one stopped -
# regardless of what was restarted, simulating a clustered pm2 app where one
# instance in the cluster never comes back after a restart.
write_pm2_cluster_stub() {
  local fakebin=$1 log=$2 proc=$3
  : > "$log"
  cat > "$fakebin/pm2" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  restart)
    printf '%s\n' "\$2" >> "$log"
    exit 0
    ;;
  jlist)
    printf '[{"name":"%s","pm2_env":{"status":"online"}},{"name":"%s","pm2_env":{"status":"stopped"}}]\n' "$proc" "$proc"
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/pm2"
}

# run_sync <home> [args...]: run the sync script against an isolated home.
run_sync() {
  local home=$1
  shift
  FM_HOME="$home" PATH="$home/fakebin:$PATH" "$SYNC" "$@"
}

# write_git_hung_fetch_stub <fakebin>: any `fetch` call hangs indefinitely
# (well past FM_NAS_SYNC_TIMEOUT), so only the bounded wrapper's `timeout` kill
# can make the sync return promptly; every other call delegates to the real git.
write_git_hung_fetch_stub() {
  local fakebin=$1 realgit
  realgit=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
real="$realgit"
for a in "\$@"; do
  if [ "\$a" = fetch ]; then
    sleep 20
    exit 0
  fi
done
exec "\$real" "\$@"
SH
  chmod +x "$fakebin/git"
}

# write_git_transient_packed_refs_lock_stub <fakebin> <counter>: fail the FIRST
# `fetch` with the packed-refs.lock "File exists" signature, then delegate every
# later call - including the retried fetch - to the real git. Mirrors
# tests/fm-fleet-sync.test.sh's git_transient_packed_refs_lock, adapted to fake
# the stderr signature directly since fm-nas-deploy-sync.sh's fetch has no
# --prune to organically trigger a real packed-refs rewrite.
write_git_transient_packed_refs_lock_stub() {
  local fakebin=$1 counter=$2 realgit
  realgit=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
real="$realgit"
is_fetch=0
for a in "\$@"; do [ "\$a" = fetch ] && is_fetch=1; done
if [ "\$is_fetch" = 1 ]; then
  n=\$(cat "$counter" 2>/dev/null || echo 0); n=\$(( n + 1 ))
  printf '%s\n' "\$n" > "$counter"
  if [ "\$n" -eq 1 ]; then
    echo "error: could not delete reference refs/remotes/origin/feature: Unable to create '.git/packed-refs.lock': File exists." >&2
    exit 1
  fi
fi
exec "\$real" "\$@"
SH
  chmod +x "$fakebin/git"
}

# --- tests: standalone script -------------------------------------------------

test_clean_behind_fast_forwards_and_restarts() {
  local home nas log out origin_head nas_head
  home=$(new_home)
  nas=$(build_nas_pair "$home" carscanner-test)
  advance_origin "$home" carscanner-test C1
  write_map "$home" carscanner-test "$nas" carscanner-test
  log="$home/restart.log"
  write_pm2_stub "$home/fakebin" "$log"

  out=$(run_sync "$home" carscanner-test)

  assert_contains "$out" "carscanner-test: synced" "clean-behind: did not report a sync"
  assert_contains "$out" "restarted carscanner-test and verified online" "clean-behind: did not report a verified restart"
  origin_head=$(git -C "$home/work-carscanner-test" rev-parse main)
  nas_head=$(head_sha "$nas")
  [ "$origin_head" = "$nas_head" ] || fail "clean-behind: NAS checkout did not fast-forward to origin"
  assert_grep carscanner-test "$log" "clean-behind: pm2 restart was not invoked"
  pass "a clean, behind NAS checkout fast-forwards and its pm2 process restarts and verifies online"
}

test_dirty_is_skipped_untouched() {
  local home nas log out before after
  home=$(new_home)
  nas=$(build_nas_pair "$home" dirty-test)
  advance_origin "$home" dirty-test C1
  before=$(head_sha "$nas")
  printf 'uncommitted\n' >> "$nas/file.txt"
  write_map "$home" dirty-test "$nas" dirty-test
  log="$home/restart.log"
  write_pm2_stub "$home/fakebin" "$log"

  out=$(run_sync "$home" dirty-test)

  assert_contains "$out" "STUCK" "dirty: did not report STUCK"
  assert_contains "$out" "uncommitted changes" "dirty: did not name the dirty reason"
  after=$(head_sha "$nas")
  [ "$before" = "$after" ] || fail "dirty: NAS checkout HEAD moved despite being dirty"
  git -C "$nas" diff --quiet -- file.txt && fail "dirty: uncommitted change was discarded"
  [ ! -s "$log" ] || fail "dirty: pm2 restart was invoked on an untouched checkout"
  pass "a dirty NAS checkout is reported STUCK and left completely untouched"
}

test_diverged_is_stuck_untouched() {
  local home nas log out before after
  home=$(new_home)
  nas=$(build_nas_pair "$home" diverged-test)
  advance_origin "$home" diverged-test C1
  commit_file "$nas" local-only.txt local "local-only commit not on origin"
  before=$(head_sha "$nas")
  write_map "$home" diverged-test "$nas" diverged-test
  log="$home/restart.log"
  write_pm2_stub "$home/fakebin" "$log"

  out=$(run_sync "$home" diverged-test)

  assert_contains "$out" "STUCK" "diverged: did not report STUCK"
  assert_contains "$out" "diverged" "diverged: did not name the diverged reason"
  after=$(head_sha "$nas")
  [ "$before" = "$after" ] || fail "diverged: NAS checkout HEAD moved despite diverging"
  [ ! -s "$log" ] || fail "diverged: pm2 restart was invoked on an untouched checkout"
  pass "a diverged NAS checkout is reported STUCK and left completely untouched"
}

test_absent_project_is_silent_noop() {
  local home nas out rc
  home=$(new_home)
  nas=$(build_nas_pair "$home" tracked-test)
  write_map "$home" tracked-test "$nas" tracked-test

  set +e
  out=$(run_sync "$home" untracked-project)
  rc=$?
  set -e

  expect_code 0 "$rc" "absent: sync should exit 0 for a project with no recorded deployment"
  assert_contains "$out" "untracked-project: skipped: no recorded NAS deployment" "absent: did not report the expected skip line"
  pass "a project absent from data/nas-deployments.md is a silent no-op"
}

test_clustered_partial_restart_is_not_masked_online() {
  local home nas log out
  home=$(new_home)
  nas=$(build_nas_pair "$home" cluster-test)
  advance_origin "$home" cluster-test C1
  write_map "$home" cluster-test "$nas" cluster-test
  log="$home/restart.log"
  write_pm2_cluster_stub "$home/fakebin" "$log" cluster-test

  out=$(run_sync "$home" cluster-test)

  assert_contains "$out" "not online after restart" \
    "clustered: did not report the lagging cluster instance as a restart problem"
  assert_contains "$out" "needs attention" "clustered: did not flag the deployment as needing attention"
  case "$out" in
    *"verified online"*) fail "clustered: a lagging cluster instance was masked as fully verified online" ;;
  esac
  pass "a clustered pm2 app with one lagging instance is reported as a restart problem, not masked as online"
}

test_empty_procs_row_is_not_reported_verified() {
  local home nas log out
  home=$(new_home)
  nas=$(build_nas_pair "$home" noprocs-test)
  advance_origin "$home" noprocs-test C1
  write_map "$home" noprocs-test "$nas" ""
  log="$home/restart.log"
  write_pm2_stub "$home/fakebin" "$log"

  out=$(run_sync "$home" noprocs-test)

  assert_contains "$out" "no pm2 processes recorded" \
    "empty-procs: did not report the missing pm2 mapping"
  assert_contains "$out" "needs attention" "empty-procs: did not flag the deployment as needing attention"
  case "$out" in
    *"verified online"*) fail "empty-procs: a row with no pm2 processes was reported as verified online" ;;
  esac
  [ ! -s "$log" ] || fail "empty-procs: pm2 restart was invoked despite an empty process column"
  pass "a mapping row with an empty pm2 column syncs but reports no processes to restart, never verified online"
}

test_hung_fetch_is_bounded_by_timeout() {
  local home nas out rc start elapsed
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    pass "SKIP (no timeout/gtimeout binary): hung-fetch timeout bound check"
    return
  fi
  home=$(new_home)
  nas=$(build_nas_pair "$home" hungfetch-test)
  advance_origin "$home" hungfetch-test C1
  write_map "$home" hungfetch-test "$nas" hungfetch-test
  write_pm2_stub "$home/fakebin" "$home/restart.log"
  write_git_hung_fetch_stub "$home/fakebin"

  start=$SECONDS
  set +e
  out=$(FM_NAS_SYNC_TIMEOUT=1 run_sync "$home" hungfetch-test 2>/dev/null)
  rc=$?
  set -e
  elapsed=$(( SECONDS - start ))

  expect_code 0 "$rc" "hung-fetch: sync should still exit 0 when the fetch hangs"
  [ "$elapsed" -lt 10 ] || fail "hung-fetch: sync took ${elapsed}s - the timeout bound did not stop the hung fetch (stub sleeps 20s)"
  assert_contains "$out" "hungfetch-test: skipped: fetch failed" "hung-fetch: did not report the bounded fetch as a failure"
  pass "a hung NAS fetch is killed by FM_NAS_SYNC_TIMEOUT instead of blocking the caller"
}

test_transient_packed_refs_lock_is_retried() {
  local home nas out counter err
  home=$(new_home)
  nas=$(build_nas_pair "$home" locktrans-test)
  advance_origin "$home" locktrans-test C1
  write_map "$home" locktrans-test "$nas" locktrans-test
  write_pm2_stub "$home/fakebin" "$home/restart.log"
  counter="$home/git-fetch-count"; : > "$counter"
  write_git_transient_packed_refs_lock_stub "$home/fakebin" "$counter"
  err="$home/err-locktrans"

  out=$(FM_NAS_SYNC_PACKED_REFS_LOCK_RETRIES=3 FM_NAS_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    run_sync "$home" locktrans-test 2>"$err")

  assert_contains "$out" "locktrans-test: synced" "transient lock: sync did not complete after the lock self-cleared"
  assert_grep "cleared on its own" "$err" "transient lock: guard did not report the self-clear"
  pass "a transient packed-refs.lock signature on the NAS fetch is retried instead of giving up immediately"
}

test_missing_map_file_is_silent_noop() {
  local home out rc
  home=$(new_home)
  rm -f "$home/data/nas-deployments.md"

  set +e
  out=$(run_sync "$home" anything)
  rc=$?
  set -e

  expect_code 0 "$rc" "no-map: sync should exit 0 when data/nas-deployments.md does not exist"
  assert_contains "$out" "anything: skipped: no recorded NAS deployment" "no-map: did not report the expected skip line"
  pass "a project checked with no data/nas-deployments.md at all is a silent no-op"
}

# --- tests: teardown integration ---------------------------------------------

# make_teardown_case <name>: a trimmed fixture mirroring tests/fm-teardown.test.sh
# make_case's ALLOW path (no-mistakes mode, task branch pushed to origin), plus a
# NAS-fixture pair and a nas-deployments.md row for the project so the real
# post-teardown fm-nas-deploy-sync.sh call has real work to do. Echoes the case dir.
make_teardown_case() {
  local name=$1 case_dir fakebin nas
  case_dir="$TMP_ROOT/teardown-$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"

  git -C "$case_dir/wt" commit -q --allow-empty -m "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  nas=$(build_nas_pair "$case_dir" project-nas)
  advance_origin "$case_dir" project-nas C1
  write_map "$case_dir" project "$nas" project-nas
  write_pm2_stub "$fakebin" "$case_dir/restart.log"

  printf '%s\n' "$case_dir"
}

run_teardown() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_NAS_DEPLOYMENTS_OVERRIDE="$case_dir/data/nas-deployments.md" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1
}

test_teardown_invokes_nas_deploy_sync_for_landed_project() {
  local case_dir rc origin_head nas_head
  case_dir=$(make_teardown_case invokes)

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "teardown-invokes: teardown should succeed for landed work"
  ! grep -q REFUSED "$case_dir/stderr" || fail "teardown-invokes: teardown printed a REFUSED line"

  origin_head=$(git -C "$case_dir/work-project-nas" rev-parse main)
  nas_head=$(head_sha "$case_dir/nas-project-nas")
  [ "$origin_head" = "$nas_head" ] \
    || fail "teardown-invokes: post-teardown hook did not fast-forward the NAS fixture"
  assert_grep project-nas "$case_dir/restart.log" \
    "teardown-invokes: post-teardown hook did not restart the NAS deployment's pm2 process"
  pass "a landed ship-task teardown invokes fm-nas-deploy-sync.sh, which syncs and restarts the live NAS deployment"
}

test_clean_behind_fast_forwards_and_restarts
test_dirty_is_skipped_untouched
test_diverged_is_stuck_untouched
test_clustered_partial_restart_is_not_masked_online
test_empty_procs_row_is_not_reported_verified
test_absent_project_is_silent_noop
test_hung_fetch_is_bounded_by_timeout
test_transient_packed_refs_lock_is_retried
test_missing_map_file_is_silent_noop
test_teardown_invokes_nas_deploy_sync_for_landed_project
