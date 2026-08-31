#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting) and fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment). Teardown uses only
# strict branch-and-head identity; crew-state layers its own narrower
# unresolvable-head dispensation on fm_nm_head_relation instead of the broader
# pipeline-owned exemption defined below. Getting this wrong in either
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

# 0 if head $2 resolves to a commit object in worktree $1 at all. This
# distinguishes a PROVEN mismatch (resolvable but not current: a historical or
# diverged head fm_nm_head_matches_worktree correctly rejects) from UNKNOWN
# attribution (unresolvable: e.g. a pipeline-owned lane head that never
# reached this worktree). A caller scanning run rows newest-first must stop on
# unknown attribution rather than surface an older, superseded run.
fm_nm_head_resolvable() {  # <worktree> <head>
  [ -n "$2" ] || return 1
  git -C "$1" rev-parse --verify --quiet "$2^{commit}" >/dev/null 2>&1
}

# branch_sync.state from captured `axi status` TOON $1: the scalar directly
# under the top-level `branch_sync:` block. The first `state:` inside the
# block is the direct child (the nested local/pipeline/target/remote
# sub-blocks carry no `state:` key). Empty when the block is absent: no run
# on the current branch, another branch's run, or a CLI without branch sync.
fm_nm_branch_sync_state() {  # <toon-output>
  local s
  s=$(printf '%s\n' "$1" \
    | sed -n '/^[[:space:]]*branch_sync:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]\{1,\}state:[[:space:]]*\(.*\)/\1/p' \
    | head -1)
  fm_nm_strip_quotes "$s"
}

# 0 if the run in captured `axi status` TOON $1 is still in flight: no
# terminal outcome and no terminal status.
fm_nm_run_is_active() {  # <toon-output>
  local status outcome
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$1" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$1" outcome)")
  [ -z "$outcome" ] || return 1
  case "$status" in completed|failed|cancelled) return 1 ;; esac
}

# The one exemption to the head rule above: while the pipeline OWNS the branch
# (branch_sync.state=pipeline_owned), the daemon's own branch attribution IS
# the attribution for an ACTIVE run, and
# head equality must not be required - the pipeline's lane head is routinely
# not a git object in the task worktree (rebase and fix commits that were
# never pushed back), so the head rule rejects exactly the run that is most
# current. The exemption never applies to a terminal run: a terminal run has
# released the branch, and binding one by branch name alone is the historical
# reused-branch misattribution the head rule exists to prevent.
fm_nm_run_is_pipeline_owned_active() {  # <toon-output>
  [ "$(fm_nm_branch_sync_state "$1")" = pipeline_owned ] || return 1
  fm_nm_run_is_active "$1"
}
