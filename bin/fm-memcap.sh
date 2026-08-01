#!/usr/bin/env bash
# Run a command inside a memory-capped systemd user scope, or run it unchanged
# when this host cannot give it one.
# Usage: fm-memcap.sh --max <spec> [--label <text>] -- [NAME=VALUE ...] <command> [args...]
#   --max is a systemd MemoryMax spec; bin/fm-memcap-lib.sh resolves it and owns
#     the grammar. --label becomes the scope's Description, so
#     `systemctl --user list-units --type=scope` names the task a scope belongs to.
#   Leading NAME=VALUE arguments after `--` are exported before exec, exactly like
#   env(1). That is why bin/fm-spawn.sh prepends this whole wrapper to a launch
#   command rather than splicing it between the command's own environment prefix
#   and the command: by the time these arguments arrive the pane shell has already
#   word-split and unquoted them, so a value containing spaces survives intact,
#   which no textual splice of the launch string can promise.
# Containment is a nice-to-have and a spawn is not. This never refuses: it probes
# the exact scope it is about to create - in the caller's own environment, where
# XDG_RUNTIME_DIR and the user bus may differ from the process that composed the
# command - and on any failure runs the command unwrapped after one stderr line.
# The probe is what makes a non-systemd host, a session with no user manager, a
# delegated cgroup without the memory controller, and a systemd too old for one
# of these properties all degrade the same way instead of breaking the launch.
# The one gap in that: the probe and the real launch are two separate
# systemd-run calls, and the real one is exec'd, so a failure landing in the gap
# between them (a user-manager restart, DBus pressure, a fork failure) replaces
# the caller with no unwrapped retry. Closing it means forking, which costs the
# tty and the single-process shape below, so it is written down rather than
# fixed. It is the one remaining way this layer can take a launch down.
# The probe deliberately runs `true` rather than allocating what an agent
# actually needs. Allocating the measured 384 MiB minimum costs 3092 ms per
# spawn against 21 ms for `true`, and it is a 384 MiB spike at the exact moment
# the host is starting an agent - the pressure this whole layer exists to avoid.
# The floor in bin/fm-memcap-lib.sh answers the same question ("is this ceiling
# big enough to run an agent") for free, so the probe is left to answer only the
# question it is cheap at: can this host create the scope at all.
# Exec, not fork: `systemd-run --scope` registers the transient unit and then
# execs, so the wrapped command keeps the caller's tty and adds no process layer.
# MemorySwapMax=0 is deliberate. cgroup v2 accounts swap separately from
# memory.max, so with swap available a capped agent can hold its ceiling in RAM
# and keep growing into swap - and on a zram host that swap is itself RAM. That
# is both a hole in the ceiling and the thrash-instead-of-fail behavior the
# ceiling exists to end, so a scope that cannot get memory fails inside its box.
# MemoryHigh is deliberately NOT set, which is not the obvious choice. It looks
# like free back-pressure before the hard kill, but it only throttles - and an
# agent's growth is overwhelmingly anonymous memory, which with no swap is not
# reclaimable at all, so the throttle has nothing to reclaim and just parks the
# process in uninterruptible sleep. Measured on this host, a runaway crossed a
# MemoryHigh/MemoryMax gap at about 1 MiB/min, which over a realistic gap is
# hours of a hung agent; the same runaway against MemoryMax alone was killed in
# one second. See docs/verification/spawn-memory-cap.md for the measurement. A
# ceiling exists to end a stall, so it must not introduce a slower one.
# Exit 2 on a usage error; otherwise this process becomes the command.
set -eu

usage() {
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

MAX=
LABEL=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --max|--label)
      [ $# -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
      case "$1" in
        --max) MAX=$2 ;;
        --label) LABEL=$2 ;;
      esac
      shift 2
      ;;
    --max=*) MAX=${1#--max=}; shift ;;
    --label=*) LABEL=${1#--label=}; shift ;;
    --) shift; break ;;
    *) echo "error: unexpected argument '$1' (the command goes after --)" >&2; exit 2 ;;
  esac
done

[ -n "$MAX" ] || { echo "error: --max is required" >&2; exit 2; }

# Apply the same floor bin/fm-spawn.sh applies, so a ceiling that reaches this
# wrapper by any other route cannot be smaller than an agent needs either.
# bin/fm-memcap-lib.sh owns the number, the comparison, and the warning text; a
# checkout without it skips the floor rather than failing the launch.
# Parameter expansion rather than dirname(1): this runs with whatever PATH the
# pane has, and under `set -e` a dirname that is not on it would abort the
# launch - the one thing this script exists to never do.
case "$0" in
  */*) LIB="${0%/*}/fm-memcap-lib.sh" ;;
  *) LIB="./fm-memcap-lib.sh" ;;
esac
if [ -r "$LIB" ]; then
  # shellcheck source=bin/fm-memcap-lib.sh
  . "$LIB"
  MAX=$(fm_memcap_apply_floor "$MAX" 'fm-memcap.sh --max')
fi

# env(1)-style leading assignments. A word only counts when its name is a real
# shell identifier, so a command whose own first argument happens to contain '='
# is never mistaken for an assignment.
while [ $# -gt 0 ]; do
  case "$1" in
    *=*) ;;
    *) break ;;
  esac
  name=${1%%=*}
  case "$name" in
    ''|[0-9]*) break ;;
  esac
  case "${name//[A-Za-z0-9_]/}" in
    '') ;;
    *) break ;;
  esac
  # shellcheck disable=SC2163  # $1 is a literal NAME=VALUE word, which is what export takes
  export "$1"
  shift
done

[ $# -gt 0 ] || { echo "error: no command to run after --" >&2; exit 2; }

SCOPE_ARGS=(--user --scope --quiet --collect
  -p "MemoryMax=$MAX" -p "MemorySwapMax=0")
[ -z "$LABEL" ] || SCOPE_ARGS+=(-p "Description=$LABEL")

# Create and immediately retire one throwaway scope with this exact property
# set. Success proves every requirement at once - the binary, a reachable user
# manager, a delegated memory controller, and a systemd that understands these
# properties - in the environment the real launch will run in. A hung user bus
# would otherwise stall the launch forever, so bound it when timeout(1) exists.
probe_scope() {
  command -v systemd-run >/dev/null 2>&1 || return 1
  # The redirect is on a braced group, not a subshell. Bash announces a
  # signal-killed foreground child on the stderr of the shell that REAPED it, so
  # only a redirect taking effect in that same shell suppresses the raw
  # job-control line; forking a subshell leaves the parent to announce it. This
  # keeps the message below as the pane's only output when a probe is killed.
  {
    if command -v timeout >/dev/null 2>&1; then
      timeout "${FM_MEMCAP_PROBE_TIMEOUT:-10}" systemd-run "${SCOPE_ARGS[@]}" -- true
    else
      systemd-run "${SCOPE_ARGS[@]}" -- true
    fi
  } >/dev/null 2>&1
}

if probe_scope; then
  exec systemd-run "${SCOPE_ARGS[@]}" -- "$@"
fi

if command -v systemd-run >/dev/null 2>&1; then
  reason='no usable systemd user scope here'
else
  reason='systemd-run is not installed'
fi
printf 'fm-memcap: %s; launching without a memory ceiling (wanted MemoryMax=%s)\n' \
  "$reason" "$MAX" >&2
exec "$@"
