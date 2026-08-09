#!/usr/bin/env bash
# fm-python-lib.sh - the single owner of "which python3 interpreter to run".
#
# Sourced, never executed. Firstmate's own scripts and tests use only the
# standard library, so any Python 3 interpreter works, but a host can carry
# several at once, some much older than others. A "python3.11+" feature
# (tomllib, chiefly) can sit unused on a host that also has a newer
# interpreter installed under a version-qualified name, just because nothing
# asked for it by name. This picks the newest one present instead of
# hardcoding a version or a path.
#
#   fm_python_bin
#       Prints the interpreter to run: the highest-versioned "python3.N" found
#       on PATH, or plain "python3" when none is found (a host with only a
#       bare python3 - or none at all - behaves exactly as before). Never
#       fails, and never prints a path: the returned word is meant to be run
#       through PATH lookup, same as a plain "python3" call would be.
#       FM_PYTHON_BIN overrides the search outright, for tests that need to
#       pin or constrain what the resolver can find.
set -u

fm_python_bin() {
  if [ -n "${FM_PYTHON_BIN:-}" ]; then
    printf '%s\n' "$FM_PYTHON_BIN"
    return 0
  fi
  local dir candidate name minor best='' best_minor=-1 old_ifs=$IFS
  IFS=:
  # shellcheck disable=SC2231  # Word-splitting $PATH by IFS=: is deliberate.
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    for candidate in "$dir"/python3.*; do
      [ -e "$candidate" ] && [ -x "$candidate" ] || continue
      name=${candidate##*/}
      case "$name" in
        python3.*) minor=${name#python3.} ;;
        *) continue ;;
      esac
      case "$minor" in ''|*[!0-9]*) continue ;; esac
      if [ "$minor" -gt "$best_minor" ]; then
        best=$name
        best_minor=$minor
      fi
    done
  done
  IFS=$old_ifs
  printf '%s\n' "${best:-python3}"
}
