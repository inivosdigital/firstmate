# shellcheck shell=bash
# Shared memory-ceiling helpers for spawned direct reports.
# Usage: . bin/fm-memcap-lib.sh
#
# One place owns the ceiling policy: the per-kind default, the accepted spec
# grammar, the floor below which a ceiling is not survivable, and the config
# read. bin/fm-spawn.sh resolves a concrete ceiling at spawn time and hands it
# to bin/fm-memcap.sh, which is the only thing that talks to systemd-run and
# owns why the ceiling is MemoryMax alone.
# docs/configuration.md owns the captain-facing schema.
#
# Specs are systemd's own memory syntax, narrowed to what this lib can scale:
# a positive integer with an optional 1024-based K/M/G/T suffix, or a 1-100
# percentage of physical RAM. `off` disables the ceiling entirely.

# The floor. Every resolved ceiling is raised to at least this, because a
# ceiling below what an agent needs to start does not contain a runaway - it
# kills every launch in the home at once, with nothing in the pane but `Killed`.
# The number is measured, not chosen: on this fleet's host a one-shot agent
# needs between 256 MiB and 384 MiB just to answer (at 256 MiB it is SIGKILLed
# with no output at all), and live crewmates sit at 577-625 MB resident before
# they build or test anything. 1 GiB is the next round number above the observed
# steady state, leaving roughly 400 MB of headroom for the build or test suite a
# ship task runs inside its own ceiling.
FM_MEMCAP_FLOOR_SPEC=1G
FM_MEMCAP_FLOOR_BYTES=1073741824

# fm_memcap_default_spec <kind>
# The built-in ceiling for a spawn kind. Percentages, not byte counts, so the
# default scales with the host instead of pinning a number sized for one
# machine. Ship work builds and runs test suites inside the cap and gets the
# larger share; a scout reads and reasons, and a secondmate supervises and
# spawns its own crewmates into SIBLING scopes (systemd places a transient user
# scope under user@<uid>.service/app.slice, not under its caller's cgroup), so
# neither needs build-sized headroom. `kind` is already resolved at spawn time
# and already recorded in meta, so no new configuration surface carries this.
# An unrecognized kind gets the larger share: a spawn that fails its work
# because of a ceiling is worse than one that is capped loosely.
# A percentage is generous on a large host and below a starting agent on a
# small one, which is why the floor below applies to these defaults too.
fm_memcap_default_spec() {
  case "${1:-ship}" in
    scout|secondmate) printf '25%%\n' ;;
    *) printf '40%%\n' ;;
  esac
}

# fm_memcap_valid <spec>
# True for `off` or a spec this lib can scale. Anything else is unusable.
# "Positive" is tested as "all digits, at least one of them non-zero" rather
# than with arithmetic: a pasted 30-digit number would overflow the shell's
# integer compare and leak a raw `[: integer expression expected` diagnostic
# next to this lib's own warning.
fm_memcap_valid() {
  local spec=${1:-} num
  [ -n "$spec" ] || return 1
  [ "$spec" != off ] || return 0
  case "$spec" in
    *%) num=${spec%\%} ;;
    *[KMGT]) num=${spec%?} ;;
    *) num=$spec ;;
  esac
  case "$num" in
    ''|*[!0-9]*) return 1 ;;
    *[1-9]*) ;;
    *) return 1 ;;
  esac
  case "$spec" in
    # A percentage is the one form with an upper bound, so it is the one form
    # that needs a comparison - safe here because 1-100 is at most three digits.
    *%)
      case "$num" in ????*) return 1 ;; esac
      [ "$num" -le 100 ]
      ;;
    *) return 0 ;;
  esac
}

# fm_memcap_total_bytes
# This host's physical RAM in bytes, or nothing when it cannot be read.
# FM_MEMCAP_TOTAL_BYTES overrides it, which is how a test on a large host
# exercises what a percentage default resolves to on a small one.
fm_memcap_total_bytes() {
  local kb
  if [ -n "${FM_MEMCAP_TOTAL_BYTES:-}" ]; then
    # Validated like the real read: a garbage override must make the total
    # unresolvable, not evaluate to zero and clamp everything.
    case "$FM_MEMCAP_TOTAL_BYTES" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$FM_MEMCAP_TOTAL_BYTES"
    return 0
  fi
  [ -r /proc/meminfo ] || return 1
  kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null) || return 1
  case "$kb" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$(( kb * 1024 ))"
}

# fm_memcap_below_floor <spec>
# True only when <spec> can be SHOWN to resolve below the floor on this host.
# An unreadable /proc/meminfo reports false, so a value this cannot judge is
# left exactly as it was rather than silently rewritten. The suffix and bare
# branches carry the same guarantee for a number too large to compare safely,
# via their digit-count guard below. The percentage branch has no equivalent
# guard: a FM_MEMCAP_TOTAL_BYTES beyond what 64-bit arithmetic can multiply
# wraps negative and clamps to the floor instead of being left alone - safe in
# direction only, and moot in practice since the real source is /proc/meminfo's
# MemTotal, always far too small to reach that range.
fm_memcap_below_floor() {
  local spec=${1:-} num limit total
  case "$spec" in
    ''|off) return 1 ;;
    *%)
      # The default case: 25% is generous on this host and below a starting
      # agent on a 2 GB one, so a percentage has to become bytes before it can
      # be judged. Multiply before dividing to keep the precision, which is safe
      # here: a host total is at most ~1e13 and the percent at most 100, so the
      # product stays four orders of magnitude inside a 64-bit integer.
      num=${spec%\%}
      total=$(fm_memcap_total_bytes) || return 1
      [ "$(( total * num / 100 ))" -lt "$FM_MEMCAP_FLOOR_BYTES" ]
      return $?
      ;;
    *K) num=${spec%?}; limit=$(( FM_MEMCAP_FLOOR_BYTES / 1024 )) ;;
    *M) num=${spec%?}; limit=$(( FM_MEMCAP_FLOOR_BYTES / 1048576 )) ;;
    *G) num=${spec%?}; limit=$(( FM_MEMCAP_FLOOR_BYTES / 1073741824 )) ;;
    *T) num=${spec%?}; limit=$(( FM_MEMCAP_FLOOR_BYTES / 1099511627776 )) ;;
    *) num=$spec; limit=$FM_MEMCAP_FLOOR_BYTES ;;
  esac
  # A value this lib's grammar does not actually accept - a decimal, or a
  # systemd suffix (P, E) this lib does not scale - reaches here only via a
  # hand-typed `--max`, never through fm_memcap_valid. Floor it rather than
  # feeding a non-digit string to the arithmetic comparison below, which would
  # leak a raw `integer expression expected` diagnostic instead of a warning.
  case "$num" in ''|*[!0-9]*) return 0 ;; esac
  # Divide the floor by the suffix instead of multiplying the value up to it.
  # The limit is then always a small number, and an absurd pasted value is
  # decided on digit count before any arithmetic touches it, so nothing here
  # can wrap through 64-bit and come back out as a small, floorable number.
  while [ ${#num} -gt 1 ]; do
    case "$num" in 0*) num=${num#0} ;; *) break ;; esac
  done
  [ ${#num} -le ${#limit} ] || return 1
  [ "$num" -lt "$limit" ]
}

# fm_memcap_apply_floor <spec> <source-label>
# <spec>, or the floor when <spec> is below it, warning on stderr and naming
# both values. The warning matters as much as the clamp: the failure it
# prevents is invisible in the pane, which shows only `Killed`.
# `off` passes through untouched - that is a deliberate choice to run with no
# ceiling, not a ceiling too small to survive.
# On a host with less RAM than the floor the clamp yields a ceiling that never
# binds. That is the honest outcome: containment cannot help a machine that
# small, and refusing to spawn there would be the worse bug.
fm_memcap_apply_floor() {
  local spec=${1:-} src=${2:-the configured value}
  if [ "$spec" != off ] && fm_memcap_below_floor "$spec"; then
    printf 'warning: %s: memory ceiling %s is below %s, less than an agent needs to start; using %s instead\n' \
      "$src" "$spec" "$FM_MEMCAP_FLOOR_SPEC" "$FM_MEMCAP_FLOOR_SPEC" >&2
    printf '%s\n' "$FM_MEMCAP_FLOOR_SPEC"
    return 0
  fi
  printf '%s\n' "$spec"
}

# fm_memcap_config_spec <file>
# The first non-empty, non-comment line of <file>, trimmed - the same one-value
# shape as config/tmp-alert-threshold and config/critical-services. Returns 1
# when the file is absent, unreadable, or carries no such line. The readability
# test is what keeps a mode-000 config from leaking a raw `Permission denied`
# into the pane ahead of this lib's own message.
fm_memcap_config_spec() {
  local file=$1 line
  [ -f "$file" ] && [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    printf '%s\n' "$line"
    return 0
  done < "$file"
  return 1
}

# fm_memcap_resolve <config-file> <kind>
# The effective MemoryMax spec for one spawn: FM_SPAWN_MEMORY_CAP, else the
# config file, else the per-kind default, and then never below the floor.
# Always prints something usable.
# An unusable value warns and falls back to the default rather than refusing -
# a spawn must never fail over its own containment layer, and silently dropping
# to no ceiling would hide the typo that caused it.
fm_memcap_resolve() {
  local file=$1 kind=${2:-ship} spec='' src=''
  if [ -n "${FM_SPAWN_MEMORY_CAP:-}" ]; then
    spec=$FM_SPAWN_MEMORY_CAP
    src=FM_SPAWN_MEMORY_CAP
  elif spec=$(fm_memcap_config_spec "$file"); then
    src=$file
  else
    spec=
  fi
  if [ -n "$spec" ] && ! fm_memcap_valid "$spec"; then
    printf 'warning: %s: unusable memory ceiling %s; using the default %s instead\n' \
      "$src" "$spec" "$(fm_memcap_default_spec "$kind")" >&2
    spec=
  fi
  if [ -z "$spec" ]; then
    spec=$(fm_memcap_default_spec "$kind")
    src="the built-in $kind default"
  fi
  # The floor applies to every source, including the default, and applies after
  # a percentage has been resolved against this host - that is the case nobody
  # configured and nobody would otherwise be warned about.
  fm_memcap_apply_floor "$spec" "$src"
}
