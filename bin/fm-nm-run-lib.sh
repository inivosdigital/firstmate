#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# shellcheck source=bin/fm-classify-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-classify-lib.sh"

# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds, GUARANTEED
# gone by $2+$3 seconds (kill-after $3 seconds) via fm-classify-lib.sh's
# fm_hard_timeout - the ONE owner of that mechanism; see its header for why a
# plain `timeout` with no kill-after is only advisory (the 2026-07-09
# 89-minute watcher stall this call site is itself named after in that
# header). The bounded form preserves stdout, stderr, and exit status; the
# checked form discards stderr, while fm_nm_run keeps the fail-open query
# contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <kill_after_secs> <args...>
  local dir=$1 timeout_secs=$2 kill_after_secs=$3
  shift 3
  ( cd "$dir" && fm_hard_timeout "$timeout_secs" "$kill_after_secs" no-mistakes "$@" )
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <kill_after_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <kill_after_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# Relation between run head $2 and worktree $1's code identity, one word on
# stdout, per the same rule everywhere this attribution is needed:
#   match        equal commits (short or full SHA), or worktree HEAD is an
#                ancestor of the run head (pipeline fix commits on the same
#                history advanced the run tip past local HEAD)
#   mismatch     the run head resolves locally but is a strict ancestor of
#                worktree HEAD, or diverged (local work advanced outside the
#                run, or a reused branch's tip was rewritten)
#   unresolvable the run head is not an object in the worktree's repo at all -
#                the shape of a run executing in no-mistakes' own private
#                worktree, whose rebased or fix-advanced commits reach this
#                repo only when the pipeline pushes
# A missing/empty head or unreadable worktree HEAD prints mismatch: nothing can
# bind. Callers decide their own policy for `unresolvable`; the strict
# predicate below treats it as no match.
fm_nm_head_relation() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || { printf 'mismatch'; return; }
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { printf 'mismatch'; return; }
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) \
    || { printf 'unresolvable'; return; }
  if [ "$run_full" = "$local_full" ] \
    || git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    printf 'match'
  else
    printf 'mismatch'
  fi
}

# 0 only on the strict `match` relation above. fm-teardown.sh's pre-teardown
# run abort binds with THIS predicate on purpose: a head this repo cannot even
# resolve is not ownership proof strong enough to abort a run over.
# fm-crew-state.sh layers its live-run policy on fm_nm_head_relation instead
# (see its attribution block for why `unresolvable` can still bind there).
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  [ "$(fm_nm_head_relation "$1" "$2")" = match ]
}
