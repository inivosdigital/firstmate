# shellcheck shell=bash
# Shared "which sessions are live" implementation for bin/fm-tmp-sweep.sh's
# periodic /tmp cleanup and bin/fm-teardown.sh's per-task harness-scratch
# cleanup. ONE copy so a drifted second copy can never delete a live session's
# scratch (docs/configuration.md "/tmp sweep and cleanup").
#
# "Live" here means "recorded in a state/<id>.meta", the same durable-record
# meaning AGENTS.md section 2 already gives worktree= - not "a process is
# provably running at this instant". A paused task, or one between turns,
# still owns its scratch until fm-teardown.sh removes its meta.
#
# Usage: . bin/fm-tmp-lib.sh   (no FM_ROOT/FM_HOME setup required by this file
# itself; every function takes the main firstmate home as an explicit
# argument, so callers stay in control of which home is "main")

FM_TMP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-ff-lib.sh
. "$FM_TMP_LIB_DIR/fm-ff-lib.sh"

# Every home with possibly-live tasks on this machine: the main home plus
# every currently live secondmate home reachable from its own state/*.meta.
# Secondmates do not spawn secondmates (AGENTS.md's config/secondmate-harness
# note), so this is exactly one level deep. Reuses fm-ff-lib.sh's
# live_secondmate_meta_records - the same secondmate-discovery fm-bootstrap.sh
# and fm-update.sh already rely on - rather than re-deriving it here.
# Emits one absolute path per line, main home first.
fm_tmp_live_homes() {
  local main_home=$1 home
  printf '%s\n' "$main_home"
  live_secondmate_meta_records "$main_home/state" "$main_home/data/secondmates.md" 2>/dev/null |
    while IFS='|' read -r _id home _window _meta; do
      [ -n "$home" ] && [ -d "$home" ] && printf '%s\n' "$home"
    done
}

# Every live task across every home on this machine (main + secondmates), one
# "<id><TAB><worktree>" line each; worktree is empty when a meta record has
# none. Reads worktree= directly (grep|tail|cut, matching fm-teardown.sh's own
# existing convention for this field) rather than pulling in fm-backend.sh's
# much larger fm_meta_get for a single field that is written exactly once, at
# spawn, and never appended.
fm_tmp_live_tasks() {
  local main_home=$1 home meta id wt
  while IFS= read -r home; do
    [ -d "$home/state" ] || continue
    for meta in "$home/state"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      wt=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      printf '%s\t%s\n' "$id" "$wt"
    done
  done < <(fm_tmp_live_homes "$main_home")
}

# Sanitize a worktree path the way Claude Code keys its /tmp/claude-<uid>
# scratch directory: every byte outside [A-Za-z0-9] becomes '-'. Verified
# empirically against a live session's own recorded scratchpad path - see
# docs/configuration.md "/tmp sweep and cleanup" for the evidence.
fm_tmp_claude_sanitize() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9' '-'
}

# Harness-specific scratch directory for a (harness, worktree) pair. Prints
# nothing and returns 1 for a harness whose convention has not been verified -
# callers MUST treat that as a hard no-op, never a guessed path (AGENTS.md
# section 4's harness-verification discipline). Only claude is implemented;
# add codex/opencode/pi/grok here only after confirming each one's own scratch
# convention the way this one was confirmed, never by inference.
fm_tmp_harness_scratch_dir() {
  local harness=$1 worktree=$2
  [ -n "$worktree" ] || return 1
  case "$harness" in
    claude*)
      printf '/tmp/claude-%s/%s\n' "$(id -u)" "$(fm_tmp_claude_sanitize "$worktree")"
      ;;
    *)
      return 1
      ;;
  esac
}
