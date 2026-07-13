#!/usr/bin/env bash
# Behavior tests for fm-bootstrap.sh tool detection.
#
# Bootstrap prints one block or line per problem or capability fact and is silent when all
# is well. firstmate consumes the exact 'MISSING: treehouse (install: ...)',
# 'MISSING: tasks-axi (install: ...)', and 'TASKS_AXI: available' lines, so those
# contracts are pinned verbatim. The cases are table-driven over the inputs that
# vary: whether `treehouse get --help` advertises --lease, which (if any)
# tasks-axi version is on PATH, whether the local backend config opts out, and
# which no-mistakes version is on PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-bootstrap-tests)

# A fake toolchain where every required tool is present and gh is authenticated.
# treehouse's `get --help` advertises --lease only when FM_FAKE_TREEHOUSE_LEASE_HELP=1.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  if [ "${FM_FAKE_TREEHOUSE_LEASE_HELP:-}" = 1 ]; then
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\n' 'Usage: treehouse get'
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_NO_MISTAKES_VERSION:-no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# Fake systemctl for the critical-services check. It shadows any real systemctl
# on PATH so the test is deterministic on a systemd host. FM_FAKE_FAILED_UNITS is
# a space-separated set of units reported as failed; FM_FAKE_SERVICE_TS is the
# StateChangeTimestamp value returned for `show` (empty = unavailable). is-failed
# prints its state to stdout (as the real one does without --quiet), so a case
# expecting silence also proves the production call redirects that stream.
add_fake_systemctl() {
  local fakebin=$1
  cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  is-failed)
    shift
    unit=
    for a in "$@"; do
      case "$a" in --*) ;; *) unit=$a ;; esac
    done
    for f in ${FM_FAKE_FAILED_UNITS:-}; do
      if [ "$f" = "$unit" ]; then
        printf '%s\n' failed
        exit 0
      fi
    done
    printf '%s\n' inactive
    exit 1
    ;;
  show)
    printf '%s\n' "${FM_FAKE_SERVICE_TS:-}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/systemctl"
}

add_tasks_axi() {
  local fakebin=$1 version=$2
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '$version'
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

add_real_jq() {
  local fakebin=$1 real_jq
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for dispatch profile validation tests"
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  chmod +x "$fakebin/jq"
}

# Each row (fields are '^'-separated; the install URL contains a literal '|'):
#   <label>^<lease 1/0>^<tasks-axi version or ->^<backend or ->^<mode>^<expect>^<notcontains>
#   mode=empty -> output must be empty (expect/notcontains ignored)
#   mode=exact -> output must equal <expect>
#   mode=grep  -> output must contain <expect> (fixed string); <notcontains> must not appear
test_bootstrap_reporting() {
  local label lease tasks backend mode expect notcontains case_dir fakebin out n
  n=0
  while IFS='^' read -r label lease tasks backend mode expect notcontains; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/case-$n"
    mkdir -p "$case_dir/home"
    if [ "$backend" != "-" ]; then
      mkdir -p "$case_dir/home/config"
      printf '%s\n' "$backend" > "$case_dir/home/config/backlog-backend"
    fi
    fakebin=$(make_fake_toolchain "$case_dir")
    [ "$tasks" = "-" ] || add_tasks_axi "$fakebin" "$tasks"
    # FM_ROOT_OVERRIDE points the worktree-tangle check at the non-git home dir so
    # it stays inert: this suite pins tool detection, not the tangle guard, and the
    # ambient checkout (CI runs on a feature branch) must not leak a TANGLE line in.
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP="$lease" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
      grep)
        printf '%s\n' "$out" | grep -Fx "$expect" >/dev/null || fail "$label: missing '$expect' (got: $out)"
        if [ -n "$notcontains" ]; then
          printf '%s\n' "$out" | grep -F "$notcontains" >/dev/null && fail "$label: unexpected '$notcontains' in: $out"
        fi
        ;;
    esac
  done <<'ROWS'
treehouse --lease support is accepted silently^1^-^manual^empty^^
treehouse without --lease reports an upgrade, gh auth is fine^0^0.1.1^-^grep^MISSING: treehouse (install: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh)^NEEDS_GH_AUTH
compatible tasks-axi is reported available by default^1^0.1.1^-^exact^TASKS_AXI: available^
missing tasks-axi is suggested by default^1^-^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
incompatible tasks-axi is suggested by default^1^0.1.0^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
manual backlog backend suppresses missing tasks-axi^1^-^manual^empty^^
manual backlog backend suppresses tasks-axi availability^1^0.1.1^manual^empty^^
ROWS
  pass "bootstrap reports treehouse lease + tasks-axi default/backend contracts"
}

test_no_mistakes_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: no-mistakes (install: curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/no-mistakes-$n"
    mkdir -p "$case_dir/home"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_tasks_axi "$fakebin" "0.1.1"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_NO_MISTAKES_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum no-mistakes version is accepted^no-mistakes version v1.31.2 (fake)^empty
newer no-mistakes minor is accepted^no-mistakes version v1.32.0 (fake)^empty
newer no-mistakes major is accepted^no-mistakes version v2.0.0 (fake)^empty
older no-mistakes patch reports an upgrade^no-mistakes version v1.31.1 (fake)^missing
unparseable no-mistakes version reports an upgrade^no-mistakes development build^missing
ROWS
  pass "bootstrap enforces no-mistakes minimum version"
}

test_orca_backend_gates_orca_tool_only_when_selected() {
  local case_dir fakebin out missing_orca
  missing_orca="MISSING: orca (install: brew install orca  # or the platform's package manager)"

  case_dir="$TMP_ROOT/orca-backend-selected"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' orca > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ "$out" = "$missing_orca" ] || fail "backend=orca should require only the Orca-specific missing tool, got: $out"

  case_dir="$TMP_ROOT/orca-backend-not-selected"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "MISSING: orca" "bootstrap should not require orca unless backend=orca is selected"
  pass "bootstrap: backend=orca gates the Orca CLI without requiring it on the default backend"
}

test_crew_dispatch_active_rules_are_surfaced() {
  local case_dir fakebin out expect
  case_dir="$TMP_ROOT/dispatch-active"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' '{"rules":[{"when":"fresh news","use":{"harness":"grok"},"why":"current context"},{"when":"big feature","use":[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}],"select":"quota-balanced"}],"default":{"harness":"claude","model":"haiku","effort":"low"}}' > "$case_dir/home/config/crew-dispatch.json"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")

  expect=$'CREW_DISPATCH: active config/crew-dispatch.json\n  rule: fresh news -> grok\n  rule: big feature -> quota-balanced[claude/claude-sonnet-5/high, codex/gpt-5.5/high]\n  default: claude/haiku/low'
  [ "$out" = "$expect" ] || fail "active dispatch profile block mismatch"$'\n'"expected: $expect"$'\n'"actual:   $out"
  pass "bootstrap surfaces active crew-dispatch rules and default"
}

test_crew_dispatch_validation() {
  local label body expect mode case_dir fakebin out n
  n=0
  while IFS='^' read -r label body mode expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/dispatch-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$body" > "$case_dir/home/config/crew-dispatch.json"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_real_jq "$fakebin"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
      grep)
        printf '%s\n' "$out" | grep -Fx "$expect" >/dev/null || fail "$label: missing '$expect' (got: $out)" ;;
    esac
  done <<'ROWS'
malformed dispatch config is flagged^{"rules":[^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON
unverified dispatch harness is flagged^{"rules":[{"when":"anything","use":{"harness":"spaceship"}}],"default":{"harness":"codex"}}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - unverified harness: spaceship
unsupported codex max effort is flagged^{"rules":[{"when":"big feature","use":{"harness":"codex","model":"gpt-5","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: codex:max
unsupported grok max effort is flagged^{"rules":[{"when":"deep current work","use":{"harness":"grok","model":"grok-4","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: grok:max
unsupported opencode effort is flagged^{"rules":[{"when":"opencode work","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5","effort":"high"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: opencode:high
array use with quota-balanced is accepted^{"rules":[{"when":"big feature","use":[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}],"select":"quota-balanced"}]}^grep^CREW_DISPATCH: active config/crew-dispatch.json
array use without select is accepted^{"rules":[{"when":"big feature","use":[{"harness":"claude"},{"harness":"codex"}]}]}^grep^CREW_DISPATCH: active config/crew-dispatch.json
empty array use is flagged^{"rules":[{"when":"big feature","use":[]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each rule needs at least one use profile
array profile without harness is flagged^{"rules":[{"when":"big feature","use":[{"model":"gpt-5.5"}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each use profile needs harness
unknown select is flagged^{"rules":[{"when":"big feature","use":[{"harness":"claude"},{"harness":"codex"}],"select":"mystery"}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - unknown select: mystery
array profile unsupported effort is flagged^{"rules":[{"when":"big feature","use":[{"harness":"codex","effort":"max"}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: codex:max
ROWS
  pass "bootstrap validates crew-dispatch.json and reports malformed or unverified configs"
}

# A home whose backlog backend is manual (suppresses TASKS_AXI) with a fully
# present toolchain and a fake systemctl, so SERVICE_FAILED lines are the only
# possible bootstrap output. Prints the fakebin path.
setup_critical_case() {
  local case_dir=$1 fakebin
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_fake_systemctl "$fakebin"
  printf '%s\n' "$fakebin"
}

run_critical_bootstrap() {
  local home=$1 fakebin=$2 failed=$3 ts=$4
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_FAKE_FAILED_UNITS="$failed" FM_FAKE_SERVICE_TS="$ts" \
    "$ROOT/bin/fm-bootstrap.sh"
}

test_critical_services_check() {
  local case_dir home fakebin out ts expect bash_env
  ts='Wed 2026-07-01 03:14:07 UTC'

  # A failed unit with a StateChangeTimestamp surfaces with the since clause.
  case_dir="$TMP_ROOT/critical-failed-ts"
  home="$case_dir/home"
  fakebin=$(setup_critical_case "$case_dir")
  printf '%s\n' 'my-app.service' > "$home/config/critical-services"
  out=$(run_critical_bootstrap "$home" "$fakebin" 'my-app.service' "$ts")
  [ "$out" = "SERVICE_FAILED: my-app.service - failed since $ts" ] \
    || fail "failed unit with timestamp: got: $out"

  # A failed unit with no StateChangeTimestamp drops the since clause.
  case_dir="$TMP_ROOT/critical-failed-no-ts"
  home="$case_dir/home"
  fakebin=$(setup_critical_case "$case_dir")
  printf '%s\n' 'my-app.service' > "$home/config/critical-services"
  out=$(run_critical_bootstrap "$home" "$fakebin" 'my-app.service' '')
  [ "$out" = "SERVICE_FAILED: my-app.service - in failed state" ] \
    || fail "failed unit without timestamp: got: $out"

  # A listed unit that is not failed stays silent (also proves is-failed's stdout
  # is redirected: the fake would otherwise leak 'inactive' into the output).
  case_dir="$TMP_ROOT/critical-not-failed"
  home="$case_dir/home"
  fakebin=$(setup_critical_case "$case_dir")
  printf '%s\n' 'my-app.service' > "$home/config/critical-services"
  out=$(run_critical_bootstrap "$home" "$fakebin" 'other.service' "$ts")
  [ -z "$out" ] || fail "not-failed unit should be silent, got: $out"

  # Blank lines and full-line '#' comments are ignored, whitespace is trimmed,
  # and only the listed units are reported, in file order.
  case_dir="$TMP_ROOT/critical-comments"
  home="$case_dir/home"
  fakebin=$(setup_critical_case "$case_dir")
  printf '%s\n' '# critical units' '' '  spaced.service  ' 'ok.timer' '#skip.service' 'down.service' \
    > "$home/config/critical-services"
  out=$(run_critical_bootstrap "$home" "$fakebin" 'spaced.service down.service' "$ts")
  expect=$'SERVICE_FAILED: spaced.service - failed since '"$ts"$'\nSERVICE_FAILED: down.service - failed since '"$ts"
  [ "$out" = "$expect" ] || fail "comment/whitespace handling: got: $out"

  # An absent config file is a no-op even with systemctl present.
  case_dir="$TMP_ROOT/critical-absent"
  home="$case_dir/home"
  fakebin=$(setup_critical_case "$case_dir")
  out=$(run_critical_bootstrap "$home" "$fakebin" 'my-app.service' "$ts")
  [ -z "$out" ] || fail "absent config should be a no-op, got: $out"

  # Without systemctl on PATH (a non-systemd host) the check is a silent no-op
  # even when the config lists a unit. Override `command -v systemctl` so the
  # host's real systemctl cannot satisfy the guard.
  case_dir="$TMP_ROOT/critical-no-systemctl"
  home="$case_dir/home"
  fakebin=$(setup_critical_case "$case_dir")
  rm -f "$fakebin/systemctl"
  printf '%s\n' 'my-app.service' > "$home/config/critical-services"
  bash_env="$case_dir/no-systemctl.bash"
  cat > "$bash_env" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = systemctl ]; then
    return 1
  fi
  builtin command "$@"
}
SH
  out=$(PATH="$fakebin:$BASE_PATH" BASH_ENV="$bash_env" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_FAILED_UNITS='my-app.service' FM_FAKE_SERVICE_TS="$ts" \
    "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "no systemctl should be a silent no-op, got: $out"

  pass "bootstrap surfaces failed critical services and stays silent otherwise"
}

test_bootstrap_reporting
test_no_mistakes_min_version
test_orca_backend_gates_orca_tool_only_when_selected
test_crew_dispatch_active_rules_are_surfaced
test_crew_dispatch_validation
test_critical_services_check
