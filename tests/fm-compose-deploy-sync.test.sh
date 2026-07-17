#!/usr/bin/env bash
# Behavior tests for fm-compose-deploy-sync.sh.
#
# The second live-deployment topology alongside fm-nas-deploy-sync.sh's pm2 model:
# a project served from a NAS git checkout brought up by Docker Compose, optionally
# wrapped by a systemd unit, on a volume that must be mounted (e.g. an encrypted
# LUKS data volume) before it is safe to deploy. Like the pm2 script it is
# best-effort and non-fatal: fast-forward the checkout, migrate, rebuild, bring up,
# verify health, always print exactly one result line and exit 0, never force or
# touch a dirty/diverged checkout.
#
# This suite never touches a real /mnt/nas checkout, docker, systemd, or mount:
# NAS checkouts are throwaway git repos under a per-test tmp home; docker,
# systemctl, mountpoint, and curl are PATH-shimmed stubs that record what ran; the
# mount gate's /proc/mounts fallback reads a fixture file via FM_COMPOSE_PROC_MOUNTS.
#
# Covers:
#   - a clean, behind checkout on a mounted volume migrates, rebuilds, restarts via
#     systemd, and passes its configured health check
#   - the mount gate: an unmounted required volume is an expected pre-unlock skip,
#     left untouched, via both mountpoint(1) and the /proc/mounts fallback
#   - dirty / diverged checkouts are STUCK and left completely untouched
#   - deploy runs only when the fast-forward actually advanced HEAD (already-current
#     does nothing)
#   - a project (or the whole mapping file) absent is a silent no-op
#   - migration / compose-build / systemd-restart / compose-up / health failures are
#     each reported "needs attention" without falsely claiming success, and abort
#     the remaining steps
#   - the container-running fallback when no health check is configured, and that it
#     says so plainly (lower confidence)
#   - a shell-command health check, health-check retries, and a custom compose file
#   - a hung fetch is bounded by FM_COMPOSE_SYNC_TIMEOUT; a transient packed-refs
#     lock is retried
#   - the script is NOT auto-wired into fm-teardown.sh (wiring is a separate decision)
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SYNC="$ROOT/bin/fm-compose-deploy-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-compose-deploy-sync-tests)

# --- generic fixtures --------------------------------------------------------

# new_home: a fresh isolated home per call. mktemp (not a counter) keeps it unique
# even though every call runs in a `home=$(new_home)` command-substitution
# subshell, so tests that reuse a project name never collide on one home.
new_home() {
  local h
  h=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
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

# write_map <home> <project> <nas_path> <compose_file> <systemd_service>
#           <required_mount> <migrate_cmd> <health_check>: (re)write a one-row
# compose-deployments.md pipe table at $home/data/compose-deployments.md. Pass "-"
# for any unset optional column, exactly as the real table's "not set" marker.
write_map() {
  local home=$1 project=$2 nas_path=$3 compose_file=$4 systemd=$5 mount=$6 migrate=$7 health=$8
  {
    printf '| project | nas_repo_path | compose_file | systemd_service | required_mount | migrate_cmd | health_check |\n'
    printf '| --- | --- | --- | --- | --- | --- | --- |\n'
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
      "$project" "$nas_path" "$compose_file" "$systemd" "$mount" "$migrate" "$health"
  } > "$home/data/compose-deployments.md"
}

# write_mounts_fixture <path> <mount_target>...: a minimal /proc/mounts-shaped file
# whose second whitespace field is each given mount target.
write_mounts_fixture() {
  local path=$1 target
  shift
  : > "$path"
  for target in "$@"; do
    printf 'dev %s ext4 rw 0 0\n' "$target" >> "$path"
  done
}

# write_mountpoint_stub <fakebin> <mounted>: `mountpoint -q <path>` exits 0 when
# <mounted> is 1 (path is a mountpoint), non-zero otherwise.
write_mountpoint_stub() {
  local fakebin=$1 mounted=$2
  cat > "$fakebin/mountpoint" <<SH
#!/usr/bin/env bash
[ "$mounted" = 1 ] && exit 0 || exit 1
SH
  chmod +x "$fakebin/mountpoint"
}

# write_docker_stub <fakebin> <log> <ps_state> [fail_step]: intercept
# `docker compose ...`, logging each full compose argv to <log>. `build`/`up`
# exit 0 unless they match <fail_step>; `ps --format json` reports one service in
# <ps_state>. Anything else exits 0.
write_docker_stub() {
  local fakebin=$1 log=$2 ps_state=$3 fail_step=${4:-}
  : > "$log"
  cat > "$fakebin/docker" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = compose ] || exit 0
shift
printf 'compose %s\n' "\$*" >> "$log"
sub=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -f|--file|-p|--project-name|--profile) shift 2 ;;
    --) shift; sub="\${1:-}"; break ;;
    -*) shift ;;
    *) sub="\$1"; break ;;
  esac
done
case "\$sub" in
  build) [ "$fail_step" = build ] && exit 1; exit 0 ;;
  up) [ "$fail_step" = up ] && exit 1; exit 0 ;;
  ps) printf '[{"Service":"web","Name":"proj-web-1","State":"$ps_state"}]\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/docker"
}

# write_systemctl_stub <fakebin> <log> [fail]: log each invocation; `restart`
# fails when <fail> is 1.
write_systemctl_stub() {
  local fakebin=$1 log=$2 fail=${3:-0}
  : > "$log"
  cat > "$fakebin/systemctl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
if [ "\${1:-}" = restart ] && [ "$fail" = 1 ]; then exit 1; fi
exit 0
SH
  chmod +x "$fakebin/systemctl"
}

# write_curl_stub <fakebin> <fail_first> <counter>: `curl` fails its first
# <fail_first> calls, then succeeds; each call is counted in <counter> so a caller
# can assert whether curl ran at all.
write_curl_stub() {
  local fakebin=$1 fail_first=$2 counter=$3
  : > "$counter"
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
n=\$(cat "$counter" 2>/dev/null || echo 0); n=\$(( n + 1 ))
printf '%s\n' "\$n" > "$counter"
[ "\$n" -le "$fail_first" ] && exit 22
exit 0
SH
  chmod +x "$fakebin/curl"
}

# run_sync <home> [args...]: run the sync script against an isolated home.
run_sync() {
  local home=$1
  shift
  FM_HOME="$home" PATH="$home/fakebin:$PATH" "$SYNC" "$@"
}

# run_deploy <home> [args...]: run_sync with fast, non-sleeping health retries so a
# deploy-path test never waits on the retry loop.
run_deploy() {
  local home=$1
  shift
  FM_COMPOSE_HEALTH_RETRIES=1 FM_COMPOSE_HEALTH_RETRY_WAIT_SECS=0 run_sync "$home" "$@"
}

# write_git_hung_fetch_stub <fakebin>: any `fetch` call hangs well past
# FM_COMPOSE_SYNC_TIMEOUT; every other call delegates to the real git.
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
# later call to the real git.
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

# --- tests -------------------------------------------------------------------

test_clean_behind_deploys_and_health_passes() {
  local home nas out origin_head nas_head dlog slog counter
  home=$(new_home)
  nas=$(build_nas_pair "$home" wealthsync)
  advance_origin "$home" wealthsync C1
  write_map "$home" wealthsync "$nas" - wealthsync /var/lib/wealthsync 'touch migrated.marker' http://localhost:3000/health
  write_mountpoint_stub "$home/fakebin" 1
  dlog="$home/docker.log"; slog="$home/systemctl.log"; counter="$home/curl.count"
  write_docker_stub "$home/fakebin" "$dlog" running
  write_systemctl_stub "$home/fakebin" "$slog"
  write_curl_stub "$home/fakebin" 0 "$counter"

  out=$(run_deploy "$home" wealthsync)

  assert_contains "$out" "wealthsync: synced" "clean-behind: did not report a sync"
  assert_contains "$out" "health check passed" "clean-behind: did not report health passing"
  assert_not_contains "$out" "needs attention" "clean-behind: falsely flagged needs attention"
  origin_head=$(git -C "$home/work-wealthsync" rev-parse main)
  nas_head=$(head_sha "$nas")
  [ "$origin_head" = "$nas_head" ] || fail "clean-behind: NAS checkout did not fast-forward to origin"
  assert_present "$nas/migrated.marker" "clean-behind: migration step did not run in the checkout"
  assert_grep build "$dlog" "clean-behind: compose build was not invoked"
  assert_no_grep "up" "$dlog" "clean-behind: compose up ran despite a wrapping systemd unit (should build then systemctl restart)"
  assert_grep "restart wealthsync" "$slog" "clean-behind: systemd unit was not restarted"
  [ -s "$counter" ] || fail "clean-behind: health-check curl was never invoked"
  pass "a clean, behind checkout on a mounted volume migrates, rebuilds, restarts via systemd, and passes its health check"
}

test_mount_not_mounted_is_skipped_untouched() {
  local home nas out before after dlog
  home=$(new_home)
  nas=$(build_nas_pair "$home" wealthsync)
  advance_origin "$home" wealthsync C1
  before=$(head_sha "$nas")
  write_map "$home" wealthsync "$nas" - wealthsync /var/lib/wealthsync 'touch migrated.marker' http://localhost:3000/health
  write_mountpoint_stub "$home/fakebin" 0
  dlog="$home/docker.log"
  write_docker_stub "$home/fakebin" "$dlog" running

  out=$(run_deploy "$home" wealthsync)

  assert_contains "$out" "not mounted yet" "unmounted: did not report the mount-gate skip"
  assert_contains "$out" "leaving deployment untouched" "unmounted: did not say the deployment was left untouched"
  after=$(head_sha "$nas")
  [ "$before" = "$after" ] || fail "unmounted: NAS checkout HEAD moved despite the volume being unmounted"
  assert_absent "$nas/migrated.marker" "unmounted: migration ran despite the mount gate"
  [ ! -s "$dlog" ] || fail "unmounted: docker compose was invoked despite the mount gate"
  pass "an unmounted required volume is an expected pre-unlock skip that leaves the deployment untouched"
}

test_mount_gate_proc_mounts_fallback() {
  local home nas out before after dlog fixture
  # Part A: fallback table lacking the required mount -> skip, untouched.
  home=$(new_home)
  nas=$(build_nas_pair "$home" wealthsync)
  advance_origin "$home" wealthsync C1
  before=$(head_sha "$nas")
  write_map "$home" wealthsync "$nas" - - /mnt/data 'touch migrated.marker' -
  dlog="$home/docker.log"
  write_docker_stub "$home/fakebin" "$dlog" running
  fixture="$home/mounts.absent"
  write_mounts_fixture "$fixture" /some/other/path

  out=$(FM_COMPOSE_PROC_MOUNTS="$fixture" run_deploy "$home" wealthsync)
  assert_contains "$out" "not mounted yet" "fallback-absent: did not skip via /proc/mounts fallback"
  after=$(head_sha "$nas")
  [ "$before" = "$after" ] || fail "fallback-absent: HEAD moved despite the fallback showing unmounted"
  [ ! -s "$dlog" ] || fail "fallback-absent: docker ran despite the fallback mount gate"

  # Part B: fallback table containing the required mount -> proceeds to deploy.
  home=$(new_home)
  nas=$(build_nas_pair "$home" wealthsync)
  advance_origin "$home" wealthsync C1
  write_map "$home" wealthsync "$nas" - - /mnt/data 'touch migrated.marker' -
  dlog="$home/docker.log"
  write_docker_stub "$home/fakebin" "$dlog" running
  fixture="$home/mounts.present"
  write_mounts_fixture "$fixture" /mnt/data

  out=$(FM_COMPOSE_PROC_MOUNTS="$fixture" run_deploy "$home" wealthsync)
  assert_contains "$out" "wealthsync: synced" "fallback-present: did not deploy when the fallback showed the volume mounted"
  assert_present "$nas/migrated.marker" "fallback-present: migration did not run once the mount gate passed via fallback"
  pass "the mount gate honors the /proc/mounts fallback in both the unmounted and mounted directions"
}

test_dirty_is_skipped_untouched() {
  local home nas out before after dlog
  home=$(new_home)
  nas=$(build_nas_pair "$home" appx)
  advance_origin "$home" appx C1
  before=$(head_sha "$nas")
  printf 'uncommitted\n' >> "$nas/file.txt"
  write_map "$home" appx "$nas" - - - 'touch migrated.marker' -
  dlog="$home/docker.log"
  write_docker_stub "$home/fakebin" "$dlog" running

  out=$(run_deploy "$home" appx)

  assert_contains "$out" "STUCK" "dirty: did not report STUCK"
  assert_contains "$out" "uncommitted changes" "dirty: did not name the dirty reason"
  after=$(head_sha "$nas")
  [ "$before" = "$after" ] || fail "dirty: NAS checkout HEAD moved despite being dirty"
  git -C "$nas" diff --quiet -- file.txt && fail "dirty: uncommitted change was discarded"
  [ ! -s "$dlog" ] || fail "dirty: docker compose ran on an untouched checkout"
  pass "a dirty compose checkout is reported STUCK and left completely untouched"
}

test_diverged_is_stuck_untouched() {
  local home nas out before after dlog
  home=$(new_home)
  nas=$(build_nas_pair "$home" appx)
  advance_origin "$home" appx C1
  commit_file "$nas" local-only.txt local "local-only commit not on origin"
  before=$(head_sha "$nas")
  write_map "$home" appx "$nas" - - - 'touch migrated.marker' -
  dlog="$home/docker.log"
  write_docker_stub "$home/fakebin" "$dlog" running

  out=$(run_deploy "$home" appx)

  assert_contains "$out" "STUCK" "diverged: did not report STUCK"
  assert_contains "$out" "diverged" "diverged: did not name the diverged reason"
  after=$(head_sha "$nas")
  [ "$before" = "$after" ] || fail "diverged: NAS checkout HEAD moved despite diverging"
  [ ! -s "$dlog" ] || fail "diverged: docker compose ran on an untouched checkout"
  pass "a diverged compose checkout is reported STUCK and left completely untouched"
}

test_already_current_skips_deploy() {
  local home nas out dlog
  home=$(new_home)
  nas=$(build_nas_pair "$home" appx)   # no advance_origin: NAS == origin
  write_map "$home" appx "$nas" - - - 'touch migrated.marker' -
  dlog="$home/docker.log"
  write_docker_stub "$home/fakebin" "$dlog" running

  out=$(run_deploy "$home" appx)

  assert_contains "$out" "already current" "already-current: did not report already current"
  assert_absent "$nas/migrated.marker" "already-current: migration ran without an advancing merge"
  [ ! -s "$dlog" ] || fail "already-current: docker compose ran without an advancing merge"
  pass "an already-current checkout does no migrate/rebuild/restart work"
}

test_absent_project_is_silent_noop() {
  local home nas out rc
  home=$(new_home)
  nas=$(build_nas_pair "$home" tracked)
  write_map "$home" tracked "$nas" - - - - -

  set +e
  out=$(run_sync "$home" untracked-project)
  rc=$?
  set -e

  expect_code 0 "$rc" "absent: sync should exit 0 for a project with no recorded deployment"
  assert_contains "$out" "untracked-project: skipped: no recorded compose deployment" "absent: did not report the expected skip line"
  pass "a project absent from data/compose-deployments.md is a silent no-op"
}

test_missing_map_file_is_silent_noop() {
  local home out rc
  home=$(new_home)
  rm -f "$home/data/compose-deployments.md"

  set +e
  out=$(run_sync "$home" anything)
  rc=$?
  set -e

  expect_code 0 "$rc" "no-map: sync should exit 0 when data/compose-deployments.md does not exist"
  assert_contains "$out" "anything: skipped: no recorded compose deployment" "no-map: did not report the expected skip line"
  pass "a project checked with no data/compose-deployments.md at all is a silent no-op"
}

test_migration_failure_reported_no_deploy() {
  local home nas out dlog
  home=$(new_home)
  nas=$(build_nas_pair "$home" appx)
  advance_origin "$home" appx C1
  write_map "$home" appx "$nas" - - - false -
  dlog="$home/docker.log"
  write_docker_stub "$home/fakebin" "$dlog" running

  out=$(run_deploy "$home" appx)

  assert_contains "$out" "synced" "migrate-fail: should still report the completed fast-forward"
  assert_contains "$out" "migration failed" "migrate-fail: did not report the migration failure"
  assert_contains "$out" "needs attention" "migrate-fail: did not flag needs attention"
  [ ! -s "$dlog" ] || fail "migrate-fail: docker compose ran despite a failed migration"
  pass "a failed migration is reported needs-attention and aborts before any rebuild"
}

test_compose_build_failure_reported() {
  local home nas out dlog slog
  home=$(new_home)
  nas=$(build_nas_pair "$home" appx)
  advance_origin "$home" appx C1
  write_map "$home" appx "$nas" - appx-svc - - -
  dlog="$home/docker.log"; slog="$home/systemctl.log"
  write_docker_stub "$home/fakebin" "$dlog" running build
  write_systemctl_stub "$home/fakebin" "$slog"

  out=$(run_deploy "$home" appx)

  assert_contains "$out" "compose build failed" "build-fail: did not report the build failure"
  assert_contains "$out" "needs attention" "build-fail: did not flag needs attention"
  [ ! -s "$slog" ] || fail "build-fail: systemd restart ran despite a failed build"
  pass "a failed compose build is reported needs-attention and aborts before the systemd restart"
}

test_systemd_restart_failure_reported() {
  local home nas out dlog slog
  home=$(new_home)
  nas=$(build_nas_pair "$home" appx)
  advance_origin "$home" appx C1
  write_map "$home" appx "$nas" - appx-svc - - -
  dlog="$home/docker.log"; slog="$home/systemctl.log"
  write_docker_stub "$home/fakebin" "$dlog" running
  write_systemctl_stub "$home/fakebin" "$slog" 1

  out=$(run_deploy "$home" appx)

  assert_contains "$out" "systemd restart of appx-svc failed" "restart-fail: did not report the systemd restart failure"
  assert_contains "$out" "needs attention" "restart-fail: did not flag needs attention"
  pass "a failed systemd restart is reported needs-attention"
}

test_bare_compose_up_failure_reported() {
  local home nas out dlog
  home=$(new_home)
  nas=$(build_nas_pair "$home" appx)
  advance_origin "$home" appx C1
  write_map "$home" appx "$nas" - - - - -   # no systemd unit -> bare compose up
  dlog="$home/docker.log"
  write_docker_stub "$home/fakebin" "$dlog" running up

  out=$(run_deploy "$home" appx)

  assert_contains "$out" "compose up failed" "up-fail: did not report the compose up failure"
  assert_contains "$out" "needs attention" "up-fail: did not flag needs attention"
  pass "a failed bare compose up is reported needs-attention"
}

test_health_check_failure_reported() {
  local home nas out dlog counter
  home=$(new_home)
  nas=$(build_nas_pair "$home" appx)
  advance_origin "$home" appx C1
  write_map "$home" appx "$nas" - - - - http://localhost:3000/health
  dlog="$home/docker.log"; counter="$home/curl.count"
  write_docker_stub "$home/fakebin" "$dlog" running
  write_curl_stub "$home/fakebin" 99 "$counter"   # always fails

  out=$(run_deploy "$home" appx)

  assert_contains "$out" "health check failed" "health-fail: did not report the health-check failure"
  assert_contains "$out" "needs attention" "health-fail: did not flag needs attention"
  assert_grep "up" "$dlog" "health-fail: the stack was not brought up before the health check"
  pass "a failed health check is reported needs-attention after the deploy"
}

test_no_health_check_container_fallback_running() {
  local home nas out dlog
  home=$(new_home)
  nas=$(build_nas_pair "$home" appx)
  advance_origin "$home" appx C1
  write_map "$home" appx "$nas" - - - - -   # no health check -> container fallback
  dlog="$home/docker.log"
  write_docker_stub "$home/fakebin" "$dlog" running

  out=$(run_deploy "$home" appx)

  assert_contains "$out" "containers report running" "container-fallback: did not report the fallback running check"
  assert_contains "$out" "lower confidence" "container-fallback: did not flag the lower confidence of the fallback"
  assert_not_contains "$out" "needs attention" "container-fallback: falsely flagged needs attention"
  assert_grep "ps" "$dlog" "container-fallback: docker compose ps was not consulted"
  pass "with no health check configured, all-containers-running is reported with an explicit lower-confidence note"
}

test_container_fallback_detects_not_running() {
  local home nas out dlog
  home=$(new_home)
  nas=$(build_nas_pair "$home" appx)
  advance_origin "$home" appx C1
  write_map "$home" appx "$nas" - - - - -
  dlog="$home/docker.log"
  write_docker_stub "$home/fakebin" "$dlog" exited   # a container not in "running"

  out=$(run_deploy "$home" appx)

  assert_contains "$out" "containers are not all running" "container-down: did not detect the stopped container"
  assert_contains "$out" "needs attention" "container-down: did not flag needs attention"
  pass "the container-running fallback detects a not-running container instead of masking it as healthy"
}

test_health_check_shell_command() {
  local home nas out dlog counter
  home=$(new_home)
  nas=$(build_nas_pair "$home" appx)
  advance_origin "$home" appx C1
  write_map "$home" appx "$nas" - - - - true   # non-URL -> run as a shell command
  dlog="$home/docker.log"; counter="$home/curl.count"
  write_docker_stub "$home/fakebin" "$dlog" running
  write_curl_stub "$home/fakebin" 99 "$counter"   # would fail if used

  out=$(run_deploy "$home" appx)

  assert_contains "$out" "health check passed" "shell-health: a shell-command health check did not pass"
  [ ! -s "$counter" ] || fail "shell-health: curl was invoked for a non-URL health check"
  pass "a non-URL health check is run as a shell command, not curled"
}

test_health_check_retries_then_passes() {
  local home nas out counter
  home=$(new_home)
  nas=$(build_nas_pair "$home" appx)
  advance_origin "$home" appx C1
  write_map "$home" appx "$nas" - - - - http://localhost:3000/health
  write_docker_stub "$home/fakebin" "$home/docker.log" running
  counter="$home/curl.count"
  write_curl_stub "$home/fakebin" 2 "$counter"   # fail twice, then pass

  out=$(FM_COMPOSE_HEALTH_RETRIES=5 FM_COMPOSE_HEALTH_RETRY_WAIT_SECS=0 run_sync "$home" appx)

  assert_contains "$out" "health check passed" "health-retry: did not eventually pass after transient failures"
  [ "$(cat "$counter")" -ge 3 ] || fail "health-retry: health check was not retried (expected >= 3 attempts)"
  pass "a health check that fails transiently is retried until it passes"
}

test_custom_compose_file_passed() {
  local home nas out dlog
  home=$(new_home)
  nas=$(build_nas_pair "$home" appx)
  advance_origin "$home" appx C1
  write_map "$home" appx "$nas" deploy/docker-compose.yml - - - -
  dlog="$home/docker.log"
  write_docker_stub "$home/fakebin" "$dlog" running

  out=$(run_deploy "$home" appx)

  assert_contains "$out" "synced" "custom-compose: deploy did not run"
  assert_grep "-f deploy/docker-compose.yml" "$dlog" "custom-compose: the configured compose file was not passed to docker compose"
  pass "a configured compose_file is passed through to docker compose"
}

test_hung_fetch_is_bounded_by_timeout() {
  local home nas out rc start elapsed
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    pass "SKIP (no timeout/gtimeout binary): hung-fetch timeout bound check"
    return
  fi
  home=$(new_home)
  nas=$(build_nas_pair "$home" hungfetch)
  advance_origin "$home" hungfetch C1
  write_map "$home" hungfetch "$nas" - - - - -
  write_git_hung_fetch_stub "$home/fakebin"

  start=$SECONDS
  set +e
  out=$(FM_COMPOSE_SYNC_TIMEOUT=1 run_sync "$home" hungfetch 2>/dev/null)
  rc=$?
  set -e
  elapsed=$(( SECONDS - start ))

  expect_code 0 "$rc" "hung-fetch: sync should still exit 0 when the fetch hangs"
  [ "$elapsed" -lt 10 ] || fail "hung-fetch: sync took ${elapsed}s - the timeout bound did not stop the hung fetch (stub sleeps 20s)"
  assert_contains "$out" "hungfetch: skipped: fetch failed" "hung-fetch: did not report the bounded fetch as a failure"
  pass "a hung compose-checkout fetch is killed by FM_COMPOSE_SYNC_TIMEOUT instead of blocking the caller"
}

test_transient_packed_refs_lock_is_retried() {
  local home nas out counter err
  home=$(new_home)
  nas=$(build_nas_pair "$home" locktrans)
  advance_origin "$home" locktrans C1
  write_map "$home" locktrans "$nas" - - - - -
  write_docker_stub "$home/fakebin" "$home/docker.log" running
  counter="$home/git-fetch-count"; : > "$counter"
  write_git_transient_packed_refs_lock_stub "$home/fakebin" "$counter"
  err="$home/err-locktrans"

  out=$(FM_COMPOSE_SYNC_PACKED_REFS_LOCK_RETRIES=3 FM_COMPOSE_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    FM_COMPOSE_HEALTH_RETRIES=1 FM_COMPOSE_HEALTH_RETRY_WAIT_SECS=0 \
    run_sync "$home" locktrans 2>"$err")

  assert_contains "$out" "locktrans: synced" "transient lock: sync did not complete after the lock self-cleared"
  assert_grep "cleared on its own" "$err" "transient lock: guard did not report the self-clear"
  pass "a transient packed-refs.lock signature on the compose-checkout fetch is retried instead of giving up immediately"
}

test_not_wired_into_teardown() {
  assert_no_grep "fm-compose-deploy-sync" "$ROOT/bin/fm-teardown.sh" \
    "wiring: fm-teardown.sh must NOT auto-invoke fm-compose-deploy-sync.sh yet (that is a separate, explicit decision)"
  pass "fm-compose-deploy-sync.sh is standalone and not auto-wired into fm-teardown.sh"
}

test_clean_behind_deploys_and_health_passes
test_mount_not_mounted_is_skipped_untouched
test_mount_gate_proc_mounts_fallback
test_dirty_is_skipped_untouched
test_diverged_is_stuck_untouched
test_already_current_skips_deploy
test_absent_project_is_silent_noop
test_missing_map_file_is_silent_noop
test_migration_failure_reported_no_deploy
test_compose_build_failure_reported
test_systemd_restart_failure_reported
test_bare_compose_up_failure_reported
test_health_check_failure_reported
test_no_health_check_container_fallback_running
test_container_fallback_detects_not_running
test_health_check_shell_command
test_health_check_retries_then_passes
test_custom_compose_file_passed
test_hung_fetch_is_bounded_by_timeout
test_transient_packed_refs_lock_is_retried
test_not_wired_into_teardown
