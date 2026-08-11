#!/usr/bin/env bash
# Ultracode enforcement (guardrail #3): mechanically confirms a genuinely
# independent second pass ran on an ultracode-flagged task's finished diff
# before it can go PR-ready - not a sub-task the same crewmate spawned itself
# (data/research-resource-tiering-synthesis.md). Tracks state via a plain
# marker file, state/<task-id>.ultracode, the same convention as other
# firstmate state/ markers (state/.afk, state/<id>.turn-ended); it never
# touches fm-spawn.sh or the task's own meta.
#
# A recorded review is pinned to the diff it covered, so it goes stale when the
# code moves. Without that binding a review recorded once satisfied check
# forever, and commits landing afterwards - up to and including a hand-written
# rewrite - reached PR-ready with no independent pass covering them at all.
#
# Marker format (one record per line; this header is the format's only owner):
#   role=<ultracode_role>
#   review=<diff-fingerprint> <reviewed-commit> <reviewer-task-id>
# The reviewer id is last because it is the longest and least constrained field;
# keeping it there means it cannot shift the two fields check actually compares.
#
# What a review is pinned to
#   The fingerprint is a hash of what bin/fm-review-diff.sh prints for the task,
#   which is the diff a reviewer is pointed at, against the authoritative base.
#   That is a CONTENT identity, not a commit id, and the distinction is the
#   whole design:
#     rebase onto an advanced default branch - commit ids all change, the diff
#       against the merge-base does not, so the review still stands. This fleet
#       rebases routinely; pinning to a commit id would refuse here every time,
#       and a guard that cries wolf gets worked around.
#     squash - many commits collapse into one, final content identical, review
#       still stands.
#     amend - a reworded commit changes its id and nothing else; an amend that
#       does change content changes the fingerprint and is refused.
#     force-push - judged purely on the content that lands, whatever history
#       shape produced it.
#   Only a real change to the reviewed content moves the fingerprint. The
#   reviewed-commit field is recorded for the refusal message alone (it gives a
#   supervisor something to `git log`), never for the comparison.
#
#   Residual gaps, stated rather than implied: an identical diff rebased onto a
#   different base can still interact badly with what landed underneath it, and
#   the comparison covers committed work only. Neither is silent - the first
#   ships through a base whose own changes were reviewed when they landed, and
#   the second surfaces the moment the work is committed, which it must be
#   before bin/fm-teardown.sh will release the task.
#
# Reviews recorded before pinning existed
#   Those markers name a reviewer and nothing about what was reviewed, so their
#   currency is not knowable from the marker, from git, or from anywhere else.
#   check REFUSES them rather than granting a pass. Passing would have been the
#   convenient choice and would have preserved this exact defect for every task
#   already in flight - a guard that fails open during its own upgrade is the
#   same defect wearing a different hat. The refusal is cheap to clear and says
#   so: re-run `reviewed <task-id> <reviewer-task-id>` once the reviewer has
#   confirmed the current diff, which pins the record going forward. That is a
#   deliberate re-affirmation by a supervisor, which is the strongest thing this
#   guard can ever mechanically require of a review.
#
# Usage:
#   fm-ultracode-guard.sh flag <task-id> [<role>]
#     Records that <task-id> was dispatched under a crew-dispatch rule whose
#     resolved profile set ultracode=true. <role> defaults to
#     "independent-review" (the only role this fleet's rules use today; see
#     docs/examples/crew-dispatch.json). Firstmate runs this right after
#     spawning the task.
#   fm-ultracode-guard.sh reviewed <task-id> <reviewer-task-id>
#     Records that <reviewer-task-id> - a distinct, separately dispatched task
#     (its own state/<reviewer-task-id>.meta must exist) - independently
#     reviewed <task-id>'s finished diff and its findings were addressed, and
#     pins that record to the diff as it stands now. Refuses if
#     <reviewer-task-id> equals <task-id> or has no recorded meta, so a sub-task
#     the same crewmate spawned itself cannot satisfy this; refuses too if the
#     current diff cannot be established, since an unpinnable record would be
#     indistinguishable from the unpinned ones above.
#     Re-running it after a fix APPENDS a record and keeps the earlier ones, so
#     a reviewer who only needs to read the delta can be recorded without
#     discarding the review of everything before it, and the marker keeps the
#     whole review chain. check accepts a match against any retained record:
#     each one is a state some separate task actually reviewed, so work that
#     returns to one (a backed-out experiment) is covered, not smuggled.
#   fm-ultracode-guard.sh check <task-id>
#     Exits 0 if <task-id> was never flagged, or was flagged and a recorded
#     review still covers the current diff. Exits 1 with an explanatory message
#     if flagged and unreviewed, if every recorded review predates the current
#     diff, if the only records predate pinning, or if the current diff cannot
#     be established at all - firstmate runs this before treating an
#     ultracode-flagged task as PR-ready (AGENTS.md section 7's Validate step).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  echo "usage: fm-ultracode-guard.sh flag <task-id> [<role>]" >&2
  echo "       fm-ultracode-guard.sh reviewed <task-id> <reviewer-task-id>" >&2
  echo "       fm-ultracode-guard.sh check <task-id>" >&2
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

CMD=${1:-}
ID=${2:-}
if [ -z "$CMD" ] || [ -z "$ID" ]; then
  usage
  exit 1
fi

MARKER="$STATE/$ID.ultracode"

# task_worktree: the task's own worktree, read from its meta. Read-only; this
# script still never writes the task's meta.
task_worktree() {
  local meta="$STATE/$ID.meta" wt
  if [ ! -f "$meta" ]; then
    echo "error: cannot determine the diff for $ID - no meta at $meta" >&2
    return 1
  fi
  wt=$(grep '^worktree=' "$meta" | tail -1 | cut -d= -f2-)
  if [ -z "$wt" ]; then
    echo "error: cannot determine the diff for $ID - its meta records no worktree=" >&2
    return 1
  fi
  if [ ! -d "$wt" ]; then
    echo "error: cannot determine the diff for $ID - its worktree is missing: $wt" >&2
    return 1
  fi
  printf '%s' "$wt"
}

# current_tip: the task branch's local tip. Human-readable pointer for the
# refusal message only - never what check compares.
current_tip() {
  local wt=$1 sha
  if sha=$(git -C "$wt" rev-parse --verify --quiet "refs/heads/fm/$ID^{commit}" 2>/dev/null); then
    printf '%s' "$sha"
    return 0
  fi
  if sha=$(git -C "$wt" rev-parse --verify --quiet "HEAD^{commit}" 2>/dev/null); then
    printf '%s' "$sha"
    return 0
  fi
  echo "error: cannot determine the diff for $ID - no commit resolves in $wt" >&2
  return 1
}

# diff_fingerprint: a content identity for the task's current diff. Delegates
# what that diff IS to bin/fm-review-diff.sh, the one owner of base and PR-head
# resolution (the same delegation the sibling guardrail bin/fm-tier-guard.sh
# makes), and only hashes the result.
diff_fingerprint() {
  local wt=$1 errfile out
  errfile=$(mktemp)
  if ! out=$("$SCRIPT_DIR/fm-review-diff.sh" "$ID" 2>"$errfile"); then
    echo "error: cannot determine the diff for $ID - bin/fm-review-diff.sh failed:" >&2
    sed 's/^/  /' "$errfile" >&2
    rm -f "$errfile"
    return 1
  fi
  # fm-review-diff.sh still exits 0 but warns when it cannot resolve an open
  # PR's head and falls back to the possibly-stale local branch. A fingerprint
  # taken from that fallback can match while the real PR head has moved, so the
  # degradation has to stay visible instead of reading as an authoritative pass
  # - the same silent-reads-clean class fm-tier-guard.sh surfaces.
  if grep -q 'PR head unavailable' "$errfile"; then
    echo "warning: the diff for $ID was fingerprinted against a possibly-stale local branch because the open PR head could not be resolved; a pass here may not cover what the PR actually contains - re-check against the current PR before trusting it" >&2
  fi
  rm -f "$errfile"
  printf '%s' "$out" | git -C "$wt" hash-object --stdin
}

cmd_flag() {
  local role=${3:-independent-review}
  [ $# -le 3 ] || { usage; exit 1; }
  # The marker is a line-based file (see cmd_reviewed/cmd_check), so a role
  # containing a newline or other control character could inject a forged
  # review= record and bypass the independent-review requirement entirely.
  case "$role" in
    *[!A-Za-z0-9_-]*|'')
      echo "error: role '$role' must be non-empty and contain only letters, digits, '-', or '_'" >&2
      exit 1
      ;;
  esac
  mkdir -p "$STATE"
  # Overwrites any existing marker: re-flagging (e.g. after an escalation)
  # deliberately clears every prior review record, since those reviews were
  # against an earlier version of the diff and the requirement starts over.
  echo "role=$role" > "$MARKER"
  echo "flagged $ID ultracode role=$role"
}

cmd_reviewed() {
  local reviewer=${3:-} nl wt tip fingerprint record
  [ $# -eq 3 ] || { usage; exit 1; }
  [ -n "$reviewer" ] || { echo "error: reviewed requires a reviewer-task-id" >&2; exit 1; }
  [ -f "$MARKER" ] || { echo "error: $ID is not ultracode-flagged (no $MARKER); nothing to mark reviewed" >&2; exit 1; }
  if [ "$reviewer" = "$ID" ]; then
    echo "error: reviewer-task-id must be a task distinct from $ID - a task cannot independently review itself" >&2
    exit 1
  fi
  if [ ! -f "$STATE/$reviewer.meta" ]; then
    echo "error: $reviewer has no recorded state/$reviewer.meta - it must be a genuinely, separately dispatched task, not a made-up id or a sub-task $ID spawned itself" >&2
    exit 1
  fi
  # The reviewer id is the last field of a review record, so a newline in it is
  # the one shape that could still forge a second, matching record behind it.
  nl=$'\n'
  case "$reviewer" in
    *"$nl"*)
      echo "error: reviewer-task-id must not contain a newline" >&2
      exit 1
      ;;
  esac

  wt=$(task_worktree) || exit 1
  tip=$(current_tip "$wt") || exit 1
  fingerprint=$(diff_fingerprint "$wt") || exit 1

  record="review=$fingerprint $tip $reviewer"
  grep -qxF "$record" "$MARKER" 2>/dev/null || printf '%s\n' "$record" >> "$MARKER"
  echo "recorded $reviewer as the independent review of $ID, pinned to the diff at $tip"
}

cmd_check() {
  [ $# -eq 2 ] || { usage; exit 1; }
  if [ ! -f "$MARKER" ]; then
    exit 0
  fi
  local role records unpinned wt current record body fingerprint latest
  local reviewed_commit reviewer tip extra
  role=$(grep '^role=' "$MARKER" | tail -1 | cut -d= -f2- || true)
  role=${role:-independent-review}
  records=$(grep '^review=' "$MARKER" || true)
  unpinned=$(grep '^reviewed_by=' "$MARKER" || true)

  if [ -z "$records" ] && [ -z "$unpinned" ]; then
    echo "error: $ID is ultracode-flagged (role=$role) but has no recorded independent review yet - dispatch a genuinely separate task to review the finished diff, then run: fm-ultracode-guard.sh reviewed $ID <reviewer-task-id>" >&2
    exit 1
  fi

  if [ -z "$records" ]; then
    reviewer=$(printf '%s\n' "$unpinned" | tail -1 | cut -d= -f2-)
    {
      echo "error: $ID is ultracode-flagged (role=$role) and its review was recorded before reviews were pinned to the diff they covered:"
      echo "  reviewed by:  $reviewer"
      echo "  Nothing in that record shows whether the review still matches the current code, so it cannot stand in for one that does."
      echo "  Have the reviewer confirm the current diff (bin/fm-review-diff.sh $ID), then re-run: fm-ultracode-guard.sh reviewed $ID $reviewer"
    } >&2
    exit 1
  fi

  wt=$(task_worktree) || exit 1
  current=$(diff_fingerprint "$wt") || exit 1

  while IFS= read -r record; do
    [ -n "$record" ] || continue
    body=${record#review=}
    case "$body" in
      *' '*' '*) ;;
      *) continue ;;
    esac
    fingerprint=${body%% *}
    if [ "$fingerprint" = "$current" ]; then
      exit 0
    fi
  done <<EOF
$records
EOF

  latest=$(printf '%s\n' "$records" | tail -1)
  body=${latest#review=}
  body=${body#* }
  reviewed_commit=${body%% *}
  reviewer=${body#* }
  tip=$(current_tip "$wt") || tip="<unresolved>"
  {
    echo "error: $ID is ultracode-flagged (role=$role) and the recorded independent review no longer covers the current diff:"
    echo "  reviewed by:  $reviewer"
    echo "  reviewed at:  $reviewed_commit"
    echo "  current tip:  $tip"
    if [ "$reviewed_commit" = "$tip" ]; then
      echo "  The local tip is unchanged, so the compared diff itself moved - typically the open PR head advanced past this worktree."
    else
      echo "  The code has changed since that review, so no independent pass covers what would ship."
    fi
    extra=$(printf '%s\n' "$records" | grep -c '^review=' || true)
    if [ "${extra:-1}" -gt 1 ]; then
      echo "  ($extra reviews are recorded; none of them matches the current diff.)"
    fi
    echo "  Have a genuinely separate task review the current diff (bin/fm-review-diff.sh $ID), then run: fm-ultracode-guard.sh reviewed $ID <reviewer-task-id>"
  } >&2
  exit 1
}

case "$CMD" in
  flag) cmd_flag "$@" ;;
  reviewed) cmd_reviewed "$@" ;;
  check) cmd_check "$@" ;;
  *) usage; exit 1 ;;
esac
