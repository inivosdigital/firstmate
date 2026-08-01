# shellcheck shell=bash
# Shared memory-ceiling helpers for spawned direct reports.
# Usage: . bin/fm-memcap-lib.sh
#
# One place owns the ceiling policy: the per-kind default, the accepted spec
# grammar, and the config read. bin/fm-spawn.sh resolves a concrete ceiling at
# spawn time and hands it to bin/fm-memcap.sh, which is the only thing that
# talks to systemd-run and owns why the ceiling is MemoryMax alone.
# docs/configuration.md owns the captain-facing schema.
#
# Specs are systemd's own memory syntax, narrowed to what this lib can scale:
# a positive integer with an optional 1024-based K/M/G/T suffix, or a 1-100
# percentage of physical RAM. `off` disables the ceiling entirely.

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

# fm_memcap_config_spec <file>
# The first non-empty, non-comment line of <file>, trimmed - the same one-value
# shape as config/tmp-alert-threshold and config/critical-services. Returns 1
# when the file is absent or carries no such line.
fm_memcap_config_spec() {
  local file=$1 line
  [ -f "$file" ] || return 1
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
# config file, else the per-kind default. Always prints something usable.
# An unusable value warns on stderr and falls back to the default rather than
# refusing - a spawn must never fail over its own containment layer, and
# silently dropping to no ceiling would hide the typo that caused it.
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
  if [ -z "$spec" ]; then
    fm_memcap_default_spec "$kind"
    return 0
  fi
  if ! fm_memcap_valid "$spec"; then
    printf 'warning: %s: unusable memory ceiling %s; using the default %s instead\n' \
      "$src" "$spec" "$(fm_memcap_default_spec "$kind")" >&2
    fm_memcap_default_spec "$kind"
    return 0
  fi
  printf '%s\n' "$spec"
}
