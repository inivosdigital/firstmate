#!/usr/bin/env bash
# tests/fm-memcap.test.sh - behavior tests for the per-spawn memory ceiling
# (bin/fm-memcap-lib.sh, bin/fm-memcap.sh, and bin/fm-spawn.sh's launch wrap).
#
# The ceiling exists so one runaway agent dies in its own cgroup instead of
# stalling the whole machine in reclaim. The property that matters most here is
# NOT that the cap is applied - it is that a host which cannot apply it still
# spawns. A missing containment layer must never become a failed spawn, so the
# degrade paths are asserted as hard requirements, not as nice-to-haves.
#
# The scope assertions read the live process's own cgroup rather than the
# command that was supposed to create it, and skip cleanly where systemd user
# scopes do not exist (macOS, a container, a session with no user manager).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-memcap-lib.sh
. "$ROOT/bin/fm-memcap-lib.sh"

MEMCAP="$ROOT/bin/fm-memcap.sh"
TMP_ROOT=$(fm_test_tmproot fm-memcap-tests)

# 16 GiB. Any case that asserts a PERCENTAGE comes back unchanged pins the host
# total to this, because on a host small enough for that percentage to fall
# under the floor the resolver would correctly clamp it and the case would
# quietly be asserting the floor instead. The floor's own behaviour on a small
# host is asserted by test_floor_applies_to_the_default_on_a_small_host.
BIG_HOST_BYTES=17179869184

# True when this host can actually create a memory-capped user scope. Probing is
# the only honest check: the binary alone proves nothing about a delegated
# memory controller or a reachable user manager.
scopes_available() {
  command -v systemd-run >/dev/null 2>&1 || return 1
  systemd-run --user --scope --quiet --collect \
    -p MemoryMax=64M -p MemorySwapMax=0 -- true >/dev/null 2>&1
}

# A PATH with no systemd-run on it, for the degrade paths.
no_systemd_path() {
  local dir="$TMP_ROOT/nosystemd"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    local tool real
    # type -P, not command -v: printf/true are shell builtins, and linking a
    # builtin's bare name to itself makes a dangling symlink that silently
    # turns every assertion below into an empty string.
    for tool in bash sh env true printf timeout; do
      real=$(type -P "$tool" 2>/dev/null) || continue
      [ -n "$real" ] && ln -sf "$real" "$dir/$tool" 2>/dev/null
    done
  fi
  printf '%s\n' "$dir"
}

# --- policy: the per-kind default ------------------------------------------
#
# kind is already resolved and already recorded at spawn time, so it carries the
# ship-vs-investigate signal without a new configuration surface.

test_default_is_per_kind_and_never_absent() {
  [ "$(fm_memcap_default_spec ship)" = '40%' ] || fail "ship default: got $(fm_memcap_default_spec ship)"
  [ "$(fm_memcap_default_spec scout)" = '25%' ] || fail "scout default: got $(fm_memcap_default_spec scout)"
  [ "$(fm_memcap_default_spec secondmate)" = '25%' ] || fail "secondmate default: got $(fm_memcap_default_spec secondmate)"
  # An unrecognized kind gets the LARGER share on purpose: a spawn killed by a
  # ceiling it should not have had is worse than one capped loosely.
  [ "$(fm_memcap_default_spec '')" = '40%' ] || fail "empty kind should fall back to the ship share"
  [ "$(fm_memcap_default_spec something-new)" = '40%' ] || fail "unknown kind should fall back to the ship share"
  pass "fm-memcap: the default ceiling keys off spawn kind and is never absent"
}

test_percent_default_scales_with_the_host() {
  # The default is a percentage, not a byte count, so it means the same thing on
  # a 4 GB box and a 64 GB one. Guard against a future edit pinning bytes.
  case "$(fm_memcap_default_spec ship)" in
    *%) : ;;
    *) fail "the built-in default must stay a percentage of host RAM" ;;
  esac
  pass "fm-memcap: built-in defaults are host-relative percentages, not fixed byte counts"
}

# --- policy: the accepted spec grammar --------------------------------------

test_spec_grammar() {
  local spec
  for spec in off 1 1024 512K 512M 6G 1T 1% 100% 40%; do
    fm_memcap_valid "$spec" || fail "spec '$spec' should be accepted"
  done
  for spec in '' 0 00 0% 000% 101% 1000% -1 6g 6GB 6.5G G '6 G' 'rm -rf /' 40%% max infinity; do
    ! fm_memcap_valid "$spec" || fail "spec '$spec' should be rejected"
  done
  # A pasted number too large for the shell's integer compare must be rejected
  # quietly - a captain typo should produce this lib's warning and nothing else.
  local noise
  noise=$(fm_memcap_valid 99999999999999999999999 2>&1 || true)
  [ -z "$noise" ] || fail "an oversized number leaked a diagnostic: $noise"
  pass "fm-memcap: the spec grammar accepts systemd sizes and percentages, and rejects everything else"
}

# --- config: absent, present, malformed -------------------------------------

test_absent_config_uses_the_default_not_no_cap() {
  local out
  out=$(FM_SPAWN_MEMORY_CAP='' FM_MEMCAP_TOTAL_BYTES="$BIG_HOST_BYTES" \
    fm_memcap_resolve "$TMP_ROOT/does-not-exist" ship 2>/dev/null)
  [ "$out" = '40%' ] || fail "absent config should resolve to the default ceiling, got '$out'"
  [ "$out" != off ] || fail "absent config must never mean 'no cap'"
  pass "fm-memcap: an absent config file means the default ceiling, not no ceiling"
}

test_present_config_wins() {
  local cfg out
  cfg="$TMP_ROOT/cfg-present"
  printf '# a comment\n\n  3G  \n' > "$cfg"
  out=$(FM_SPAWN_MEMORY_CAP='' fm_memcap_resolve "$cfg" ship 2>/dev/null)
  [ "$out" = 3G ] || fail "config value should win and be trimmed, got '$out'"

  printf 'off\n' > "$cfg"
  out=$(FM_SPAWN_MEMORY_CAP='' fm_memcap_resolve "$cfg" ship 2>/dev/null)
  [ "$out" = off ] || fail "'off' should disable the ceiling, got '$out'"
  pass "fm-memcap: a present config file overrides the default, comments and blanks skipped"
}

test_malformed_config_warns_and_falls_back() {
  local cfg out err
  cfg="$TMP_ROOT/cfg-bad"
  printf '6 gigabytes please\n' > "$cfg"
  err="$TMP_ROOT/cfg-bad.err"
  out=$(FM_SPAWN_MEMORY_CAP='' FM_MEMCAP_TOTAL_BYTES="$BIG_HOST_BYTES" \
    fm_memcap_resolve "$cfg" scout 2>"$err")
  [ "$out" = '25%' ] || fail "a malformed value should fall back to the kind default, got '$out'"
  assert_grep 'unusable memory ceiling' "$err" "a malformed value must warn, not fail silently"
  # Falling back to `off` would silently remove the protection the typo asked for.
  [ "$out" != off ] || fail "a malformed value must not disable the ceiling"
  pass "fm-memcap: a malformed config value warns and falls back to the default ceiling"
}

test_env_override_beats_the_file() {
  local cfg out
  cfg="$TMP_ROOT/cfg-env"
  printf '3G\n' > "$cfg"
  # 2G, not a sub-floor value: this case is about precedence, and a fixture
  # below the floor would silently be testing the clamp instead. The floor's own
  # effect on this source is asserted in test_floor_applies_to_every_source.
  out=$(FM_SPAWN_MEMORY_CAP=2G fm_memcap_resolve "$cfg" ship 2>/dev/null)
  [ "$out" = 2G ] || fail "FM_SPAWN_MEMORY_CAP should win over the config file, got '$out'"
  out=$(FM_SPAWN_MEMORY_CAP=nonsense FM_MEMCAP_TOTAL_BYTES="$BIG_HOST_BYTES" \
    fm_memcap_resolve "$cfg" ship 2>/dev/null)
  [ "$out" = '40%' ] || fail "a malformed env override should fall back to the default, got '$out'"
  pass "fm-memcap: FM_SPAWN_MEMORY_CAP overrides the config file and is validated the same way"
}

# --- policy: the floor ------------------------------------------------------
#
# A ceiling below what an agent needs to start does not contain a runaway, it
# kills every launch in the home at once, and the pane shows only `Killed`. The
# floor is the guard, and the warning is half of it: without a message the
# clamp would be as invisible as the failure it prevents.

test_floor_clamps_a_ceiling_too_small_to_start_an_agent() {
  local out err
  err="$TMP_ROOT/floor.err"
  # 40M is one keystroke from the 40% the shipped example carries.
  out=$(fm_memcap_apply_floor 40M 'config/spawn-memory-cap' 2>"$err")
  [ "$out" = "$FM_MEMCAP_FLOOR_SPEC" ] || fail "a sub-floor ceiling should clamp to the floor, got '$out'"
  assert_grep 'below 1G' "$err" "the warning must name the floor"
  assert_grep '40M' "$err" "the warning must name the value it rejected"
  assert_grep 'using 1G instead' "$err" "the warning must say what is being used instead"
  assert_grep 'config/spawn-memory-cap' "$err" "the warning must name where the value came from"
  pass "fm-memcap: a ceiling below the floor is clamped up and says so, naming both values"
}

test_floor_leaves_a_usable_ceiling_exactly_as_it_was() {
  local spec out err
  err="$TMP_ROOT/floor-ok.err"
  # Including both spellings of the floor itself: the floor is a minimum, not a
  # rewrite, so a value AT it must pass through untouched.
  for spec in 1G 1024M 1073741824 2G 6G 1T; do
    out=$(fm_memcap_apply_floor "$spec" test 2>"$err")
    [ "$out" = "$spec" ] || fail "'$spec' is at or above the floor and must not be rewritten, got '$out'"
    [ ! -s "$err" ] || fail "'$spec' must not warn: $(cat "$err")"
  done
  # One byte under is the boundary that must clamp.
  out=$(fm_memcap_apply_floor 1073741823 test 2>/dev/null)
  [ "$out" = "$FM_MEMCAP_FLOOR_SPEC" ] || fail "one byte below the floor must clamp, got '$out'"
  out=$(fm_memcap_apply_floor 1023M test 2>/dev/null)
  [ "$out" = "$FM_MEMCAP_FLOOR_SPEC" ] || fail "1023M is below the floor and must clamp, got '$out'"
  pass "fm-memcap: the floor is a minimum, not a rewrite - a usable ceiling passes through untouched"
}

test_floor_never_overrides_a_deliberate_off() {
  local out err
  err="$TMP_ROOT/floor-off.err"
  out=$(fm_memcap_apply_floor off test 2>"$err")
  # `off` is a captain choosing no ceiling, not a ceiling too small to survive.
  [ "$out" = off ] || fail "'off' must survive the floor, got '$out'"
  [ ! -s "$err" ] || fail "'off' must not warn: $(cat "$err")"
  pass "fm-memcap: the floor does not turn a deliberate 'off' into a ceiling"
}

test_floor_applies_to_every_source() {
  local cfg out err
  cfg="$TMP_ROOT/cfg-floor"
  err="$TMP_ROOT/floor-src.err"
  printf '64M\n' > "$cfg"
  out=$(FM_SPAWN_MEMORY_CAP='' fm_memcap_resolve "$cfg" ship 2>"$err")
  [ "$out" = "$FM_MEMCAP_FLOOR_SPEC" ] || fail "a sub-floor config value must be floored, got '$out'"
  assert_grep "$cfg" "$err" "the warning must name the config file as the source"

  out=$(FM_SPAWN_MEMORY_CAP=100M fm_memcap_resolve "$cfg" ship 2>"$err")
  [ "$out" = "$FM_MEMCAP_FLOOR_SPEC" ] || fail "a sub-floor env override must be floored, got '$out'"
  assert_grep 'FM_SPAWN_MEMORY_CAP' "$err" "the warning must name the environment variable as the source"
  pass "fm-memcap: the floor applies to the config file and the environment override alike"
}

test_floor_applies_to_the_default_on_a_small_host() {
  local out err
  err="$TMP_ROOT/floor-small.err"
  # The case nobody configured and nobody would otherwise be warned about: a
  # percentage default scales down with the host, and agent memory does not.
  # 25% of 2 GB is 512 MB, below what a live crewmate already uses.
  out=$(FM_MEMCAP_TOTAL_BYTES=2147483648 FM_SPAWN_MEMORY_CAP='' \
    fm_memcap_resolve "$TMP_ROOT/does-not-exist" scout 2>"$err")
  [ "$out" = "$FM_MEMCAP_FLOOR_SPEC" ] || fail "the scout default on a 2 GB host must be floored, got '$out'"
  assert_grep 'built-in scout default' "$err" "the warning must name the built-in default as the source"
  assert_grep '25%' "$err" "the warning must name the percentage it rejected"

  out=$(FM_MEMCAP_TOTAL_BYTES=2147483648 FM_SPAWN_MEMORY_CAP='' \
    fm_memcap_resolve "$TMP_ROOT/does-not-exist" ship 2>/dev/null)
  [ "$out" = "$FM_MEMCAP_FLOOR_SPEC" ] || fail "the ship default on a 2 GB host must be floored, got '$out'"

  # 8 GB and up, the same defaults are comfortably above the floor and must be
  # left alone - the floor must not quietly become the policy on normal hosts.
  out=$(FM_MEMCAP_TOTAL_BYTES=8589934592 FM_SPAWN_MEMORY_CAP='' \
    fm_memcap_resolve "$TMP_ROOT/does-not-exist" scout 2>"$err")
  [ "$out" = '25%' ] || fail "the scout default on an 8 GB host must stay a percentage, got '$out'"
  [ ! -s "$err" ] || fail "a healthy default must not warn: $(cat "$err")"
  pass "fm-memcap: a percentage default is floored after it resolves against a small host"
}

test_floor_leaves_an_unevaluable_value_alone_and_quietly() {
  local out err
  err="$TMP_ROOT/floor-huge.err"
  # Too large to multiply safely. Reporting "not below the floor" is the safe
  # direction: the value is left exactly as it was, systemd rejects it itself,
  # the probe fails and the launch degrades - the path it took before the floor
  # existed. What must not happen is a wrap through 64-bit into a small number.
  out=$(fm_memcap_apply_floor 99999999999999999999999 test 2>"$err")
  [ "$out" = 99999999999999999999999 ] || fail "an unevaluable value must be left alone, got '$out'"
  [ ! -s "$err" ] || fail "an unevaluable value must not leak a diagnostic: $(cat "$err")"

  # A leading-zero value must not be judged by digit count either.
  out=$(fm_memcap_apply_floor 0000000040M test 2>/dev/null)
  [ "$out" = "$FM_MEMCAP_FLOOR_SPEC" ] || fail "leading zeros must not hide a sub-floor value, got '$out'"

  # An unreadable /proc/meminfo means a percentage cannot be judged at all.
  out=$(FM_MEMCAP_TOTAL_BYTES=not-a-number fm_memcap_apply_floor '25%' test 2>/dev/null)
  [ "$out" = '25%' ] || fail "an unresolvable percentage must be left alone, got '$out'"
  pass "fm-memcap: a value the floor cannot evaluate is left untouched, with no raw diagnostic"
}

# --- wrapper: usage ---------------------------------------------------------

test_wrapper_usage_errors() {
  local out rc
  out=$("$MEMCAP" -- true 2>&1); rc=$?
  expect_code 2 "$rc" "a missing --max must be a usage error"
  assert_contains "$out" "--max is required" "usage error should name the missing flag"

  out=$("$MEMCAP" --max 1G -- 2>&1); rc=$?
  expect_code 2 "$rc" "no command after -- must be a usage error"

  out=$("$MEMCAP" --max 2>&1); rc=$?
  expect_code 2 "$rc" "a flag with no value must be a usage error, not a shift past the end"
  pass "fm-memcap.sh: usage errors exit 2 and say what is missing"
}

# --- wrapper: env(1)-style leading assignments ------------------------------
#
# fm-spawn prepends this wrapper to a whole launch command, environment prefix
# and all, so the wrapper has to apply that prefix itself. Doing it here rather
# than by splicing the wrapper into the launch STRING is what makes a value
# containing spaces safe: the shell has already word-split and unquoted it.

test_wrapper_applies_leading_assignments() {
  local out path
  path=$(no_systemd_path)
  # shellcheck disable=SC2016  # single quotes are the point: $FM_A/$FM_B must expand in the wrapped shell, not here
  out=$(PATH="$path" "$MEMCAP" --max 1G -- FM_A='x y z' FM_B=2 \
    "$path/bash" -c 'printf "A=[%s] B=[%s]\n" "$FM_A" "$FM_B"' 2>/dev/null)
  [ "$out" = 'A=[x y z] B=[2]' ] || fail "leading assignments should reach the command intact, got '$out'"
  pass "fm-memcap.sh: leading NAME=VALUE arguments are exported, spaces and all"
}

test_wrapper_does_not_eat_a_command_argument_containing_equals() {
  local out path
  path=$(no_systemd_path)
  # `notify=[...]` shapes really do appear in launch templates (codex -c ...),
  # so a bare word containing '=' must not be mistaken for an assignment when it
  # is not a valid identifier.
  out=$(PATH="$path" "$MEMCAP" --max 1G -- "$path/printf" '%s\n' 'notify=[bash]' 2>/dev/null)
  [ "$out" = 'notify=[bash]' ] || fail "a non-identifier '=' word must stay an argument, got '$out'"
  pass "fm-memcap.sh: a command argument containing '=' is not mistaken for an assignment"
}

# --- wrapper: degrade -------------------------------------------------------

test_wrapper_runs_the_command_when_systemd_run_is_absent() {
  local out rc path
  path=$(no_systemd_path)
  out=$(PATH="$path" "$MEMCAP" --max 1G -- "$path/printf" 'ran\n' 2>&1); rc=$?
  expect_code 0 "$rc" "a host without systemd-run must still run the command"
  assert_contains "$out" "ran" "the command must still run when the ceiling cannot be applied"
  assert_contains "$out" "systemd-run is not installed" "the degrade must say why, not be silent"
  pass "fm-memcap.sh: no systemd-run means an unwrapped launch with a stated reason, never a failure"
}

test_wrapper_runs_the_command_when_scope_creation_fails() {
  local out rc dir
  dir="$TMP_ROOT/failing-systemd"
  mkdir -p "$dir"
  printf '#!/bin/sh\nexit 1\n' > "$dir/systemd-run"
  chmod +x "$dir/systemd-run"
  out=$(PATH="$dir:$(no_systemd_path)" "$MEMCAP" --max 1G -- "$(no_systemd_path)/printf" 'ran\n' 2>&1); rc=$?
  expect_code 0 "$rc" "a systemd-run that refuses must still leave the command running"
  assert_contains "$out" "ran" "the command must still run when scope creation fails"
  assert_contains "$out" "no usable systemd user scope" "the degrade must state the reason"
  pass "fm-memcap.sh: a systemd-run that cannot create the scope degrades instead of failing the launch"
}

# --- wrapper: the ceiling is real -------------------------------------------

test_wrapper_puts_the_command_in_a_capped_scope() {
  if ! scopes_available; then
    echo "skip: this host cannot create systemd user scopes (real-scope assertions)"
    return 0
  fi
  local out cg max swap
  # Read the ceiling from the running process's OWN cgroup, not from the
  # command that was supposed to set it. 2G, not a sub-floor value: this case
  # asserts that the requested ceiling reaches the cgroup verbatim, and a
  # fixture below the floor would be asserting the clamp instead. The floor's
  # own arrival in a real cgroup is asserted separately below.
  # shellcheck disable=SC2016  # single quotes are the point: this expands inside the scoped shell, not here
  out=$("$MEMCAP" --max 2G --label 'firstmate memcap-test' -- \
    bash -c 'cg=$(cut -d: -f3 /proc/self/cgroup); printf "%s\n%s\n%s\n" "$cg" "$(cat /sys/fs/cgroup$cg/memory.max)" "$(cat /sys/fs/cgroup$cg/memory.swap.max)"')
  cg=$(printf '%s\n' "$out" | sed -n 1p)
  max=$(printf '%s\n' "$out" | sed -n 2p)
  swap=$(printf '%s\n' "$out" | sed -n 3p)
  case "$cg" in
    *.scope) : ;;
    *) fail "the command should run inside a transient scope, got cgroup '$cg'" ;;
  esac
  [ "$max" = "$(( 2 * 1024 * 1024 * 1024 ))" ] || fail "memory.max should be 2G in bytes, got '$max'"
  # Without this, a capped agent can hold its ceiling in RAM and keep growing
  # into swap - which on a zram host is RAM again.
  [ "$swap" = 0 ] || fail "memory.swap.max should be 0, got '$swap'"
  pass "fm-memcap.sh: the command really runs in a scope whose own memory.max carries the ceiling"
}

test_ceiling_kills_only_inside_the_scope() {
  if ! scopes_available; then
    echo "skip: this host cannot create systemd user scopes (kill assertion)"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "skip: python3 not found (kill assertion)"
    return 0
  fi
  local rc out witness_rc
  # A witness holding real memory OUTSIDE the scope must survive: the point of a
  # per-task ceiling over a machine-wide killer is that the runaway dies and
  # nothing else does.
  python3 -c 'import time; b=bytearray(200*1024*1024); time.sleep(25)' &
  local witness=$!
  sleep 2
  # The ceiling is the floor and the allocation is four times it. Asking for
  # less than the floor would be clamped up to it, and allocating only as much
  # as the ceiling would sit exactly on the boundary; neither makes a decisive
  # kill assertion.
  out=$("$MEMCAP" --max 1G --label 'firstmate memcap-test-oom' -- \
    python3 -c 'b=[]
for i in range(4096):
    b.append(bytearray(1024*1024))
print("SURVIVED")' 2>&1) || true
  rc=$?
  assert_not_contains "$out" "SURVIVED" "a 4 GiB allocation must not survive a 1G ceiling"
  kill -0 "$witness" 2>/dev/null || fail "the out-of-scope witness must survive the in-scope kill"
  kill "$witness" 2>/dev/null
  wait "$witness" 2>/dev/null
  witness_rc=$?
  : "$rc" "$witness_rc"
  pass "fm-memcap.sh: exceeding the ceiling kills inside the scope and leaves other processes alone"
}

test_wrapper_floors_a_ceiling_it_is_handed_directly() {
  if ! scopes_available; then
    echo "skip: this host cannot create systemd user scopes (wrapper floor assertion)"
    return 0
  fi
  local out max err
  err="$TMP_ROOT/wrapper-floor.err"
  # The wrapper applies the floor itself, so a ceiling reaching it by any route
  # other than fm-spawn.sh cannot be smaller than an agent needs either. Read
  # back from the live cgroup, not from the warning.
  # shellcheck disable=SC2016  # single quotes are the point: this expands inside the scoped shell, not here
  out=$("$MEMCAP" --max 40M -- \
    bash -c 'cg=$(cut -d: -f3 /proc/self/cgroup); cat /sys/fs/cgroup$cg/memory.max' 2>"$err")
  max=$(printf '%s\n' "$out" | tail -1)
  [ "$max" = "$FM_MEMCAP_FLOOR_BYTES" ] || fail "the wrapper should raise 40M to the floor, got memory.max '$max'"
  assert_grep 'below 1G' "$err" "the wrapper must say it raised the ceiling"
  pass "fm-memcap.sh: a sub-floor ceiling handed straight to the wrapper is raised before the scope is made"
}

test_wrapper_says_only_its_own_reason_when_the_probe_is_killed() {
  local out dir path
  dir="$TMP_ROOT/killed-systemd"
  mkdir -p "$dir"
  # A systemd-run that dies by signal: bash announces a signal-killed child on
  # the stderr of the shell that reaped it, which would put a raw job-control
  # line in the pane just above the wrapper's own message.
  printf '#!/bin/sh\nkill -9 $$\n' > "$dir/systemd-run"
  chmod +x "$dir/systemd-run"
  path=$(no_systemd_path)
  out=$(PATH="$dir:$path" "$MEMCAP" --max 2G -- "$path/printf" 'ran\n' 2>&1)
  assert_contains "$out" "ran" "the command must still run when the probe is killed"
  assert_contains "$out" "no usable systemd user scope" "the degrade must state the reason"
  assert_not_contains "$out" "Killed" "a raw job-control line must not reach the pane"
  pass "fm-memcap.sh: a probe killed by a signal leaves only this script's own one-line reason"
}

test_unreadable_config_is_quiet() {
  local cfg out err
  cfg="$TMP_ROOT/cfg-unreadable"
  printf '2G\n' > "$cfg"
  chmod 000 "$cfg"
  if [ -r "$cfg" ]; then
    # root, or a filesystem without permission bits.
    echo "skip: this user can read a mode-000 file (unreadable-config assertion)"
    chmod 644 "$cfg"
    return 0
  fi
  err="$TMP_ROOT/cfg-unreadable.err"
  out=$(FM_SPAWN_MEMORY_CAP='' FM_MEMCAP_TOTAL_BYTES="$BIG_HOST_BYTES" \
    fm_memcap_resolve "$cfg" ship 2>"$err")
  chmod 644 "$cfg"
  [ "$out" = '40%' ] || fail "an unreadable config should fall back to the default, got '$out'"
  [ ! -s "$err" ] || fail "an unreadable config must not leak a raw diagnostic: $(cat "$err")"
  pass "fm-memcap: an unreadable config file falls back silently, with no raw permission error"
}

# --- fm-spawn integration ---------------------------------------------------
#
# Drives the REAL bin/fm-spawn.sh with a fake tmux that records what was typed
# into the pane, the same shape as tests/fm-spawn-compose-isolation.test.sh.

fm_git_identity fmtest fmtest@example.invalid

make_spawn_fakebin() {  # <dir> <sendlog>
  local dir=$1 sendlog=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    # record only the literal launch text: send-keys -t <target> -l <text>
    if [ "\${4:-}" = -l ]; then printf '%s\n' "\${5:-}" >> "$sendlog"; fi
    exit 0 ;;
  has-session|new-session|new-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# The host total is pinned for the same reason as BIG_HOST_BYTES above: the
# percentage assertions below have to mean the same thing on every host.
run_spawn() {  # <home> <id> <proj> <pane> <fakebin> [extra-args...]
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5
  shift 5
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    FM_SPAWN_MEMORY_CAP='' \
    FM_MEMCAP_TOTAL_BYTES="$BIG_HOST_BYTES" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "$@" 2>&1
}

spawn_fixture() {  # <tmp> -> echoes "<proj> <wt> <fakebin> <sendlog>"
  local tmp=$1 proj wt fakebin sendlog
  proj="$tmp/proj"
  fm_git_init_commit "$proj"
  wt="$tmp/pool-a1b2c3/1/proj"
  git -C "$proj" worktree add -q --detach "$wt" || fail "setup: worktree add failed"
  fakebin=$(make_spawn_fakebin "$tmp/fake" "$tmp/sendlog")
  sendlog="$tmp/sendlog"
  : > "$sendlog"
  printf '%s %s %s %s\n' "$proj" "$wt" "$fakebin" "$sendlog"
}

launch_line() {  # <sendlog> - the launch command, not the GOTMPDIR export
  grep -v '^export GOTMPDIR=' "$1" | tail -1
}

test_spawn_wraps_the_launch_and_records_the_ceiling() {
  local tmp proj wt fakebin sendlog out line
  tmp=$(fm_test_tmproot fm-memcap-spawn)
  read -r proj wt fakebin sendlog <<EOF
$(spawn_fixture "$tmp")
EOF
  mkdir -p "$tmp/home/config"
  printf '3G\n' > "$tmp/home/config/spawn-memory-cap"

  out=$(run_spawn "$tmp/home" memcap-ship "$proj" "$wt" "$fakebin" codex)
  assert_contains "$out" "spawned memcap-ship" "spawn should succeed"
  assert_grep "memcap=3G" "$tmp/home/state/memcap-ship.meta" "meta should record the requested ceiling"

  line=$(launch_line "$sendlog")
  assert_contains "$line" "bin/fm-memcap.sh" "the launch command should go through the wrapper"
  assert_contains "$line" "--max '3G'" "the launch command should carry the resolved ceiling"
  assert_contains "$line" "--label 'firstmate memcap-ship'" "the scope should be labelled with the task"
  assert_contains "$line" "-- codex" "the original launch command must follow the wrapper unchanged"
  pass "fm-spawn: a launch is wrapped in the memory ceiling and the request is recorded"
}

test_spawn_default_ceiling_follows_kind() {
  local tmp proj wt fakebin sendlog
  tmp=$(fm_test_tmproot fm-memcap-spawn-kind)
  read -r proj wt fakebin sendlog <<EOF
$(spawn_fixture "$tmp")
EOF
  run_spawn "$tmp/home" memcap-scout "$proj" "$wt" "$fakebin" codex --scout >/dev/null
  assert_grep "memcap=25%" "$tmp/home/state/memcap-scout.meta" "a scout should get the smaller default share"
  assert_grep "kind=scout" "$tmp/home/state/memcap-scout.meta" "fixture sanity: this should be a scout"

  : > "$sendlog"
  run_spawn "$tmp/home" memcap-ship2 "$proj" "$wt" "$fakebin" codex >/dev/null
  assert_grep "memcap=40%" "$tmp/home/state/memcap-ship2.meta" "a ship should get the larger default share"
  pass "fm-spawn: with no config, the ceiling follows the spawn kind"
}

test_spawn_malformed_config_still_caps_at_the_default() {
  local tmp proj wt fakebin sendlog out line
  tmp=$(fm_test_tmproot fm-memcap-spawn-bad)
  read -r proj wt fakebin sendlog <<EOF
$(spawn_fixture "$tmp")
EOF
  mkdir -p "$tmp/home/config"
  printf 'six gigs\n' > "$tmp/home/config/spawn-memory-cap"

  out=$(run_spawn "$tmp/home" memcap-bad "$proj" "$wt" "$fakebin" codex)
  assert_contains "$out" "spawned memcap-bad" "a malformed ceiling must not fail the spawn"
  assert_contains "$out" "unusable memory ceiling" "a malformed ceiling must warn at spawn time"
  assert_grep "memcap=40%" "$tmp/home/state/memcap-bad.meta" "a malformed ceiling should fall back to the kind default"
  line=$(launch_line "$sendlog")
  assert_contains "$line" "--max '40%'" "the fallback ceiling should still be applied to the launch"
  pass "fm-spawn: a malformed configured ceiling warns, falls back to the default, and still spawns"
}

test_spawn_off_leaves_the_launch_untouched() {
  local tmp proj wt fakebin sendlog line
  tmp=$(fm_test_tmproot fm-memcap-spawn-off)
  read -r proj wt fakebin sendlog <<EOF
$(spawn_fixture "$tmp")
EOF
  mkdir -p "$tmp/home/config"
  printf 'off\n' > "$tmp/home/config/spawn-memory-cap"

  run_spawn "$tmp/home" memcap-off "$proj" "$wt" "$fakebin" codex >/dev/null
  assert_grep "memcap=off" "$tmp/home/state/memcap-off.meta" "meta should record that no ceiling was asked for"
  line=$(launch_line "$sendlog")
  assert_not_contains "$line" "fm-memcap.sh" "'off' must leave the launch command exactly as it was"
  case "$line" in
    codex*) : ;;
    *) fail "'off' should launch the harness directly, got: $line" ;;
  esac
  pass "fm-spawn: an 'off' ceiling reproduces the pre-existing launch command byte for byte"
}

spawn_with_fmroot() {  # <fmroot> <tmp> <id> <proj> <wt> <fakebin>
  local fmroot=$1 tmp=$2 id=$3 proj=$4 wt=$5 fakebin=$6
  mkdir -p "$tmp/home/data/$id"
  printf 'brief\n' > "$tmp/home/data/$id/brief.md"
  FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$tmp/home" \
    FM_STATE_OVERRIDE="$tmp/home/state" FM_DATA_OVERRIDE="$tmp/home/data" \
    FM_PROJECTS_OVERRIDE="$tmp/home/projects" FM_CONFIG_OVERRIDE="$tmp/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" FM_SPAWN_MEMORY_CAP='' \
    FM_MEMCAP_TOTAL_BYTES="$BIG_HOST_BYTES" \
    PATH="$fakebin:$PATH" \
    "$fmroot/bin/fm-spawn.sh" "$id" "$proj" codex 2>&1
}

test_spawn_still_succeeds_without_the_wrapper_script() {
  local tmp proj wt fakebin sendlog out line fmroot
  tmp=$(fm_test_tmproot fm-memcap-spawn-nowrapper)
  read -r proj wt fakebin sendlog <<EOF
$(spawn_fixture "$tmp")
EOF
  # A partially synced or older checkout has fm-spawn.sh but not fm-memcap.sh.
  # Typing a command the pane shell cannot run would break every spawn, so the
  # ceiling has to drop instead.
  fmroot="$tmp/fmroot"
  mkdir -p "$fmroot"
  cp -R "$ROOT/bin" "$fmroot/bin"
  rm -f "$fmroot/bin/fm-memcap.sh"

  out=$(spawn_with_fmroot "$fmroot" "$tmp" memcap-nowrap "$proj" "$wt" "$fakebin")
  assert_contains "$out" "spawned memcap-nowrap" "a missing wrapper must not fail the spawn"
  assert_contains "$out" "without a memory ceiling" "a missing wrapper must say the ceiling was dropped"
  # `unavailable`, not `off`: a broken checkout must not read back later as a
  # captain who deliberately chose to run with no ceiling.
  assert_grep "memcap=unavailable" "$tmp/home/state/memcap-nowrap.meta" "meta should record that the ceiling was unavailable"
  assert_no_grep "memcap=off" "$tmp/home/state/memcap-nowrap.meta" "a broken checkout must not be recorded as a deliberate 'off'"
  line=$(launch_line "$sendlog")
  assert_not_contains "$line" "fm-memcap.sh" "a missing wrapper must not be typed into the pane"
  pass "fm-spawn: a missing wrapper script drops the ceiling and still spawns"
}

test_spawn_survives_a_corrupt_wrapper_script() {
  local tmp proj wt fakebin sendlog out line fmroot
  tmp=$(fm_test_tmproot fm-memcap-spawn-emptywrapper)
  read -r proj wt fakebin sendlog <<EOF
$(spawn_fixture "$tmp")
EOF
  # An executable, zero-byte wrapper passes an existence-and-mode check, exits
  # 0, and the agent simply never appears - the quietest possible failure. The
  # guard tests for content as well as for the executable bit.
  fmroot="$tmp/fmroot"
  mkdir -p "$fmroot"
  cp -R "$ROOT/bin" "$fmroot/bin"
  : > "$fmroot/bin/fm-memcap.sh"
  chmod +x "$fmroot/bin/fm-memcap.sh"

  out=$(spawn_with_fmroot "$fmroot" "$tmp" memcap-empty "$proj" "$wt" "$fakebin")
  assert_contains "$out" "spawned memcap-empty" "an empty wrapper must not fail the spawn"
  assert_contains "$out" "without a memory ceiling" "an empty wrapper must say the ceiling was dropped"
  assert_grep "memcap=unavailable" "$tmp/home/state/memcap-empty.meta" "meta should record that the ceiling was unavailable"
  line=$(launch_line "$sendlog")
  assert_not_contains "$line" "fm-memcap.sh" "an empty wrapper must not be typed into the pane"
  pass "fm-spawn: an executable but empty wrapper drops the ceiling instead of silently eating the launch"
}

test_spawn_records_a_deliberate_off_distinctly() {
  local tmp proj wt fakebin sendlog
  tmp=$(fm_test_tmproot fm-memcap-spawn-offmeta)
  read -r proj wt fakebin sendlog <<EOF
$(spawn_fixture "$tmp")
EOF
  mkdir -p "$tmp/home/config"
  printf 'off\n' > "$tmp/home/config/spawn-memory-cap"
  run_spawn "$tmp/home" memcap-offmeta "$proj" "$wt" "$fakebin" codex >/dev/null
  # The counterpart to the two cases above: a captain's own `off` must stay
  # `off`, so the two are distinguishable in the durable record.
  assert_grep "memcap=off" "$tmp/home/state/memcap-offmeta.meta" "a deliberate 'off' must be recorded as 'off'"
  assert_no_grep "memcap=unavailable" "$tmp/home/state/memcap-offmeta.meta" "a deliberate 'off' is not an unavailable ceiling"
  pass "fm-spawn: a deliberate 'off' and an unavailable ceiling are distinguishable in the record"
}

test_spawn_floors_a_sub_floor_configured_ceiling() {
  local tmp proj wt fakebin sendlog out line
  tmp=$(fm_test_tmproot fm-memcap-spawn-floor)
  read -r proj wt fakebin sendlog <<EOF
$(spawn_fixture "$tmp")
EOF
  mkdir -p "$tmp/home/config"
  # The typo the shipped example is one keystroke away from.
  printf '40M\n' > "$tmp/home/config/spawn-memory-cap"

  out=$(run_spawn "$tmp/home" memcap-floor "$proj" "$wt" "$fakebin" codex)
  assert_contains "$out" "spawned memcap-floor" "a sub-floor ceiling must not fail the spawn"
  assert_contains "$out" "less than an agent needs to start" "a sub-floor ceiling must warn at spawn time"
  assert_grep "memcap=1G" "$tmp/home/state/memcap-floor.meta" "meta should record the floored ceiling, not the typo"
  line=$(launch_line "$sendlog")
  assert_contains "$line" "--max '1G'" "the floored ceiling should be what reaches the pane"
  assert_not_contains "$line" "--max '40M'" "the sub-floor value must never reach the pane"
  pass "fm-spawn: a configured ceiling below the floor is raised, warned about, and recorded as raised"
}

test_default_is_per_kind_and_never_absent
test_percent_default_scales_with_the_host
test_spec_grammar
test_absent_config_uses_the_default_not_no_cap
test_present_config_wins
test_malformed_config_warns_and_falls_back
test_env_override_beats_the_file
test_floor_clamps_a_ceiling_too_small_to_start_an_agent
test_floor_leaves_a_usable_ceiling_exactly_as_it_was
test_floor_never_overrides_a_deliberate_off
test_floor_applies_to_every_source
test_floor_applies_to_the_default_on_a_small_host
test_floor_leaves_an_unevaluable_value_alone_and_quietly
test_wrapper_usage_errors
test_wrapper_applies_leading_assignments
test_wrapper_does_not_eat_a_command_argument_containing_equals
test_wrapper_runs_the_command_when_systemd_run_is_absent
test_wrapper_runs_the_command_when_scope_creation_fails
test_wrapper_puts_the_command_in_a_capped_scope
test_wrapper_floors_a_ceiling_it_is_handed_directly
test_wrapper_says_only_its_own_reason_when_the_probe_is_killed
test_unreadable_config_is_quiet
test_ceiling_kills_only_inside_the_scope
test_spawn_wraps_the_launch_and_records_the_ceiling
test_spawn_default_ceiling_follows_kind
test_spawn_malformed_config_still_caps_at_the_default
test_spawn_floors_a_sub_floor_configured_ceiling
test_spawn_off_leaves_the_launch_untouched
test_spawn_records_a_deliberate_off_distinctly
test_spawn_still_succeeds_without_the_wrapper_script
test_spawn_survives_a_corrupt_wrapper_script
