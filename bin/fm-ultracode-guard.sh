#!/usr/bin/env bash
# Ultracode enforcement (guardrail #3): holds an ultracode-flagged task back
# from PR-ready until firstmate has recorded a review against its finished
# diff, and until that record still covers the code as it stands
# (data/research-resource-tiering-synthesis.md). That the review was a genuine
# second pass is firstmate's judgment, not this script's finding; the section
# below draws the line exactly. Tracks state via a plain
# marker file, state/<task-id>.ultracode, the same convention as other
# firstmate state/ markers (state/.afk, state/<id>.turn-ended); it never
# touches fm-spawn.sh or the task's own meta.
#
# WHAT THIS GUARD IS FOR - read this before hardening it again
#   It is a gate against SUPERVISOR ERROR: firstmate advancing a flagged task
#   without having commissioned a review, or talking itself into believing one
#   basically happened. It has caught exactly that. It is NOT a security
#   boundary against a hostile worker, and it cannot become one at this layer.
#   Every worker already runs as the same user that owns state/, and every brief
#   tells its worker to append to state/<id>.status. A worker that wanted to
#   forge a review would write the review= line into this marker directly - no
#   traversal, no aliasing, no symlink, nothing this script could notice.
#   Hardening the identity checks against filesystem tricks therefore buys
#   nothing that is not already given away: it is a better lock on a door
#   standing next to an open wall. Four rounds of review were spent polishing
#   that lock before anyone measured the wall. If you are here to add
#   resolved-path containment, -ef comparisons, or link checks on the reviewer's
#   metadata, that is the phantom; go and change who can write state/ instead.
#   What genuinely keeps the gate useful is the list below being small, true,
#   and cheap enough that nobody routes around it.
#
# What this guard establishes, and what it does not
#   Mechanically enforced, and this list is exhaustive:
#     - a flagged task cannot pass with no review recorded at all;
#     - the named reviewer is a different string from the task's own id;
#     - a file exists at state/<reviewer-task-id>.meta. Existence is the whole
#       test: an empty file passes it. Contents, kind, provenance and any link
#       to the reviewed task are neither read nor validated;
#     - the record is pinned to a canonical content identity of the diff it was
#       recorded against - blob ids, not rendered text, so it moves whenever the
#       committed bytes move, and it does not move when only local repository
#       configuration does - and check refuses once the current diff no longer
#       matches any recorded one;
#     - the record names the generation of the requirement it was recorded
#       against, so re-flagging retires it;
#     - the diff being compared is established, never inferred from a PR head
#       that could not be freshly resolved;
#     - both the task id and the reviewer id are lexically constrained before
#       either is compared or turned into a path, and the role is constrained
#       before it is written;
#     - flag, reviewed and check hold this task's marker lock for their whole
#       run, so no two of them interleave;
#     - the marker is published by rename, so a half-written one is never
#       observable, and a marker that is a symlink is replaced rather than
#       written through - including a link to a directory;
#     - a marker path that exists but is not a regular file is refused by flag,
#       reviewed and check alike, rather than read as "absent, so not flagged".
#       Absence is the one permissive state, and it stays permissive; a
#       directory or other object sitting at that path is a different state and
#       is reported, not repaired and not passed.
#   NOT enforced: that the reviewer id names a task this home really dispatched,
#   that it is independent of the task under review, or that it reviewed
#   anything at all. Those three are assertions the caller makes by running
#   `reviewed`; nothing here can observe them. `reviewed` is a SUPERVISOR-OWNED
#   mutation - firstmate runs it after satisfying itself that a separately
#   dispatched task reviewed the finished diff and its findings were addressed -
#   and the independence guarantee rests there, not in this predicate. Stated
#   plainly because an overclaim in a safety guard's own documentation is its
#   own hazard: a reader who believes independence is machine-checked stops
#   checking it.
#   Re-checking that boundary later: the wording drifts back toward the
#   overclaim on its own, because "the independent review" is the shorter
#   phrase. Sweep for it rather than re-reading, across every surface that
#   describes this guard, not just this file:
#     CLAIMS='genuinely|independent|dispatched|second pass|certif|actually reviewed'
#     CLAIMS="$CLAIMS|prevent|protect|defen[cs]|secur|tamper|forge|attack|guarantee"
#     grep -nEi "$CLAIMS" \
#       bin/fm-ultracode-guard.sh tests/fm-ultracode-guard.test.sh docs/scripts.md \
#       | grep -vE 'independent-review|ultracode_role'
#     grep -nEi 'ultracode' AGENTS.md docs/architecture.md | grep -Ei "$CLAIMS"
#   Every hit must be one of: the NOT-enforced list above, an instruction
#   telling a supervisor what to go do, or prose naming firstmate as the
#   asserter. A hit that makes the SCRIPT the subject of dispatch provenance,
#   reviewer independence, or "a review happened" is the defect. So is a hit
#   claiming this stops a worker who wanted to forge a review, or naming it a
#   protection rather than a gate - "this prevents X" overclaims exactly the
#   way "this proves Y" does, and the threat-model paragraph above is what the
#   second half of that word list defends. (It is a documented sweep, not a
#   test, because tests here must not assert implementation-source bytes.)
#   Known false positive: "forge" also means GitHub/GitLab in the test fixture
#   names. Read the line, do not widen the pattern.
#   The sweep only works if its output is read against that rule INCLUDING the
#   lines of this header - the round-3 pass printed its own overclaiming
#   summary line at the top of this file and shipped it anyway, which is how a
#   fourth review still found three of these in the docs above.
#
#   Making independence mechanical would need provenance recorded when the
#   reviewer is dispatched (its own metadata binding it to the task it reviews),
#   which is a change to the flagging and dispatch path rather than to this
#   guard. That is reported, deliberately not built here.
#
#   Note for the next reader: bin/fm-tier-guard.sh recognises only the older
#   "PR head unavailable" marker, so it still sizes a possibly-stale recorded
#   head silently. Pre-existing and tracked separately as
#   fm-tier-guard-swallows-degraded-pr-head; do not assume both guards treat a
#   degraded PR head alike.
#
# A recorded review is pinned to the diff it covered, so it goes stale when the
# code moves. Without that binding a review recorded once satisfied check
# forever, and commits landing afterwards - up to and including a hand-written
# rewrite - reached PR-ready with no independent pass covering them at all.
#
# Marker format (one record per line; this header is the format's only owner):
#   role=<ultracode_role>
#   gen=<generation-token>
#   review=<generation> <diff-fingerprint> <reviewed-commit> <reviewer-task-id>
# The reviewer id is last because it is the longest and least constrained field;
# keeping it there means it cannot shift the fields check actually compares.
# flag mints a fresh generation, and check accepts only records naming the
# current one, so re-flagging retires every earlier review even if one was
# already in flight when the requirement was reset.
#
# What a review is pinned to
#   The fingerprint is a hash of bin/fm-review-diff.sh --identity for the task:
#   the raw before/after blob ids of every path that differs from the
#   authoritative base. Deliberately NOT a hash of the rendered diff a reviewer
#   reads - a project's own .gitattributes can bind a path to a textconv or
#   external diff driver, and then changed content renders identically and a
#   hash of the rendering sits still over code nobody reviewed. Notebooks,
#   generated files and binary formats do this in ordinary honest projects.
#   Blob ids move whenever the committed bytes move.
#   That is a CONTENT identity, not a commit id, and the distinction is the
#   whole design:
#     rebase onto an advanced default branch - commit ids all change, and the
#       review still stands PROVIDED the advance did not touch a file the task
#       also touches. This fleet rebases routinely; pinning to a commit id would
#       refuse every one of those, and a guard that cries wolf gets worked
#       around.
#       When the advance DOES touch the same file, the identity moves and check
#       refuses, even though the task's own change is unaltered. That is the
#       honest consequence of identifying whole before/after blobs rather than
#       patch text, and it is the safe direction: the content that would now
#       ship really is different from what was reviewed, because the task's
#       change is sitting on top of someone else's edit to the same file. Re-
#       record the review against the rebased diff. This paragraph is a promise
#       narrowed to what the code keeps - an earlier version of it claimed every
#       routine rebase held, which was false in exactly this case.
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
#   When a PR is recorded, the diff must come from a freshly resolved PR head.
#   bin/fm-review-diff.sh will otherwise fall back to the local branch or to the
#   pr_head recorded when the PR was first seen, and a fingerprint taken from
#   either can match while unreviewed commits sit on the PR. Both fallbacks are
#   therefore refusals here, not warnings, which does mean an ultracode check
#   cannot be satisfied offline once a PR exists. That cost is deliberate: this
#   guard exists to keep a recorded review bound to the code it covered, and a
#   head it was unable to confirm cannot anchor that binding.
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
#     Records firstmate's decision that <task-id> owes an ultracode review,
#     taken from the dispatch profile that set ultracode=true; nothing about
#     that dispatch is read here. <role> defaults to
#     "independent-review" (the only role this fleet's rules use today; see
#     docs/examples/crew-dispatch.json). Firstmate runs this right after
#     spawning the task.
#   fm-ultracode-guard.sh reviewed <task-id> <reviewer-task-id>
#     The supervisor's assertion that <reviewer-task-id> was a separate task,
#     independent of <task-id>, and reviewed its finished diff with the findings
#     addressed; this pins that assertion to the diff as it stands now.
#     What it checks is above under "What this guard proves": the assertion that
#     a review happened is the caller's, and only its pinning is mechanical.
#     Refuses if <reviewer-task-id> equals <task-id>, or if no file exists at
#     state/<reviewer-task-id>.meta, which catches a bare invented id but not a
#     real id that reviewed nothing; refuses too if the current diff cannot be
#     established, since an unpinnable record would be indistinguishable from
#     the unpinned ones above.
#     Re-running it after a fix APPENDS a record and keeps the earlier ones, so
#     a reviewer who only needs to read the delta can be recorded without
#     discarding the review of everything before it, and the marker keeps the
#     whole review chain. check accepts a match against any retained record:
#     each one is a state the supervisor asserted a review covered, so work that
#     returns to one (a backed-out experiment) is covered by the same assertion
#     rather than escaping it.
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

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# fm-wake-lib.sh owns this repo's portable per-path mutex (stale-owner handling
# included); the marker lock below is one, not a second implementation.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

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

# Both identifiers become state/ paths, and the reviewer id is additionally
# compared against the task id to stop a task being recorded as its own
# reviewer. An id carrying / or .. defeats both at once: "../state/<task>" is a
# different string from "<task>", so the distinctness comparison passes, while
# "$STATE/../state/<task>.meta" resolves back to the task's OWN metadata - a
# clean pass with no second task in existence. Validate at entry,
# before any comparison or path construction, so no later code sees a value
# whose string form and path form disagree.
# fm_task_id_path_safe is bin/fm-pr-lib.sh's existing predicate for exactly
# this; it is deliberately reused rather than restated here.
reject_unsafe_id() {
  local kind=$1 value=$2
  fm_task_id_path_safe "$value" && return 0
  {
    echo "error: $kind must be a plain task id - letters, digits, '.', '_' and '-' only, and not starting with '.'"
    echo "  got: $value"
    echo "  It is used to build a path under state/, so a value containing '/' or '..' could reach a file outside it."
  } >&2
  exit 1
}
reject_unsafe_id "task-id" "$ID"

MARKER="$STATE/$ID.ultracode"
MARKER_LOCK="$STATE/$ID.ultracode.lock"

# hold_marker_lock: serialize this task's flag/reviewed/check against each
# other. Without it, flag's overwrite, reviewed's read-then-append and check's
# read-then-compare interleave: a review can be recorded against a requirement
# that was just reset, and check can report success while the marker on disk
# holds no review. The lock is held across the whole command, git fetch
# included, so the diff a decision is made on is the diff the marker is written
# against.
hold_marker_lock() {
  mkdir -p "$STATE"
  fm_lock_acquire_wait "$MARKER_LOCK"
  # shellcheck disable=SC2064 # MARKER_LOCK is fixed by now; expand it here.
  trap "fm_lock_release '$MARKER_LOCK'" EXIT INT TERM
}

# write_marker: replace the marker from stdin atomically, and never through a
# symlink. A partly written marker is never observable either.
#
# rename(2) does not follow symlinks, but `mv` is not rename(2): given a
# destination that is a symlink to a DIRECTORY, mv treats it as that directory
# and deposits the temp file inside it - the marker stays a link and a stray
# file lands outside state/. Links to a regular file, to nothing, and hard links
# were all already handled; only this shape was not, and it is the shape the
# damage control was added for.
# GNU `mv -T` refuses to treat the destination that way, but it is a GNU
# extension and this repo supports macOS, whose mv has no -T. So the link is
# unlinked first and the rename then lands on a plain name. That is safe here
# for a reason worth stating: every caller holds this task's marker lock, so no
# other guard command can observe the gap, and check treats an absent marker as
# "not flagged" - a gap another reader could misread. The lock is what makes
# the two-step sound; do not lift this out from under it.
# refuse_malformed_marker: a marker path that EXISTS but cannot be read as a
# regular file is malformed, and malformed is not the same state as absent.
# Absent rightly means "not flagged, nothing to enforce" and stays permissive.
# Collapsing malformed into it meant a flagged task whose marker path was a
# directory sailed through the gate that exists to refuse it. Readers refuse
# instead, and deliberately do not repair: rearranging odd state on a caller's
# behalf is the shape that put a stray file outside state/ two rounds ago.
refuse_malformed_marker() {
  if [ -f "$MARKER" ]; then
    return 0
  fi
  if [ -e "$MARKER" ] || [ -L "$MARKER" ]; then
    {
      echo "error: $MARKER exists but is not a regular file, so $ID's ultracode state cannot be read."
      echo "  It is left exactly as found - nothing here removes or repairs it."
      echo "  Inspect it, clear it deliberately, then re-flag $ID if it still owes a review."
    } >&2
    exit 1
  fi
  return 0
}

write_marker() {
  local tmp
  # A symlink of any kind is replaced below, which is settled behaviour. A real
  # directory or other non-regular object is not: mv would infer directory
  # semantics and deposit the marker inside it, leaving flag reporting success
  # with no marker published. Refuse rather than guess at what belongs there.
  if [ ! -L "$MARKER" ] && [ -e "$MARKER" ] && [ ! -f "$MARKER" ]; then
    {
      echo "error: $MARKER exists and is not a regular file, so the marker cannot be published there."
      echo "  It is left exactly as found - nothing here removes or repairs it."
      echo "  Inspect it and clear it deliberately, then re-run."
    } >&2
    return 1
  fi
  tmp=$(mktemp "$STATE/.$ID.ultracode.XXXXXX") || return 1
  cat > "$tmp"
  chmod 0644 "$tmp"
  if [ -L "$MARKER" ]; then
    rm -f "$MARKER"
  fi
  mv -f "$tmp" "$MARKER"
}

# marker_generation: the token flag stamps when it (re)opens the requirement.
# Every review record names the generation it was recorded against, and check
# accepts only records naming the current one. The lock above already closes
# the interleaving, but it can steal a lock whose owner it proves dead, so
# mutual exclusion is not absolute; this binding makes a record from a
# superseded requirement unusable rather than trusting that it never lands.
marker_generation() {
  grep '^gen=' "$MARKER" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

new_generation() {
  local raw
  if raw=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null) && [ -n "$raw" ]; then
    printf '%s' "$raw" | tr -d ' \n'
    return 0
  fi
  printf '%s-%s-%s' "$(date +%s)" "$$" "${RANDOM:-0}${RANDOM:-0}"
}

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
  local wt=$1 errfile outfile rc
  errfile=$(mktemp)
  # --identity is NUL-delimited, so it is captured as a file rather than into a
  # variable: command substitution drops NUL bytes, which would let one record's
  # path run into the next record's fields and collapse distinct diffs onto one
  # identity. --no-filters keeps the hash off the attributes mechanism, the same
  # reason --identity avoids textconv in the first place.
  outfile=$(mktemp)
  # --identity, not the rendered diff: a project's own .gitattributes can bind a
  # path to a textconv or external diff driver, and then changed content renders
  # identically and a hash of the rendering never moves. That is ordinary in
  # projects holding notebooks or generated files, not an attack. --identity
  # names the before/after blob ids instead, which move with the bytes.
  if ! "$SCRIPT_DIR/fm-review-diff.sh" "$ID" --identity >"$outfile" 2>"$errfile"; then
    echo "error: cannot determine the diff for $ID - bin/fm-review-diff.sh failed:" >&2
    sed 's/^/  /' "$errfile" >&2
    rm -f "$errfile" "$outfile"
    return 1
  fi
  # fm-review-diff.sh still exits 0 when it cannot freshly resolve an open PR's
  # head: it falls back either to the local branch ("PR head unavailable") or to
  # the pr_head recorded when the PR was first seen ("not freshly resolved").
  # Both leave the compared diff unestablished as what the PR contains, and a
  # fingerprint taken from either can match the recorded review while unreviewed
  # commits sit on the PR - this guard's own defect reached through the PR path.
  # So refuse rather than warn. Warning was not enough: only one of the two
  # branches announced itself, and the silent one was the dangerous one.
  if grep -qE 'PR head unavailable|PR head not freshly resolved' "$errfile"; then
    {
      echo "error: cannot determine the diff for $ID - the open PR's head could not be freshly resolved, so the diff compared here is not established to be what the PR contains:"
      grep 'PR head' "$errfile" | sed 's/^/  /'
      echo "  Restore access to the PR's remote and re-run. Do not record or accept a review against a head that could not be confirmed."
    } >&2
    rm -f "$errfile" "$outfile"
    return 1
  fi
  rm -f "$errfile"
  rc=0
  git -C "$wt" hash-object --no-filters --stdin < "$outfile" || rc=$?
  rm -f "$outfile"
  return "$rc"
}

cmd_flag() {
  local role=${3:-independent-review}
  [ $# -le 3 ] || { usage; exit 1; }
  # The marker is a line-based file (see cmd_reviewed/cmd_check), so a role
  # carrying a newline or other control character would put a second line into
  # it and leave check reading a record nobody wrote. Keeping the file's line
  # structure intact, not stopping anyone: a worker can write this file.
  case "$role" in
    *[!A-Za-z0-9_-]*|'')
      echo "error: role '$role' must be non-empty and contain only letters, digits, '-', or '_'" >&2
      exit 1
      ;;
  esac
  hold_marker_lock
  # Overwrites any existing marker: re-flagging (e.g. after an escalation)
  # deliberately clears every prior review record, since those reviews were
  # against an earlier version of the diff and the requirement starts over. The
  # fresh generation is what makes that stick for a review already in flight.
  printf 'role=%s\ngen=%s\n' "$role" "$(new_generation)" | write_marker || exit 1
  echo "flagged $ID ultracode role=$role"
}

cmd_reviewed() {
  local reviewer=${3:-} wt tip fingerprint record gen
  [ $# -eq 3 ] || { usage; exit 1; }
  [ -n "$reviewer" ] || { echo "error: reviewed requires a reviewer-task-id" >&2; exit 1; }
  hold_marker_lock
  # Before the distinctness comparison below, which a path alias would other-
  # wise walk straight past. It also keeps a newline out of the marker, whose
  # line structure would otherwise gain a record nobody wrote.
  reject_unsafe_id "reviewer-task-id" "$reviewer"
  # Ahead of the absence message below, so a marker path that is there but
  # unreadable is not reported as "never flagged", which is a different problem
  # with a different fix.
  refuse_malformed_marker
  [ -f "$MARKER" ] || { echo "error: $ID is not ultracode-flagged (no $MARKER); nothing to mark reviewed" >&2; exit 1; }
  if [ "$reviewer" = "$ID" ]; then
    echo "error: reviewer-task-id must be a task distinct from $ID - a task cannot review itself" >&2
    exit 1
  fi
  if [ ! -f "$STATE/$reviewer.meta" ]; then
    {
      echo "error: nothing is present at state/$reviewer.meta."
      echo "  That one path check is the whole test here. It rejects an invented id, and equally a real task whose metadata was retired or never written."
      echo "  That the reviewer was separately dispatched, and reviewed anything, is what you assert by running this - neither is checked."
    } >&2
    exit 1
  fi
  # A marker written before generations existed has none; mint one in place
  # rather than refusing. It cannot relax anything: no record predating this
  # carries a generation, so none can match the one being minted now.
  gen=$(marker_generation)
  if [ -z "$gen" ]; then
    gen=$(new_generation)
    { cat "$MARKER"; printf 'gen=%s\n' "$gen"; } | write_marker
  fi

  wt=$(task_worktree) || exit 1
  tip=$(current_tip "$wt") || exit 1
  fingerprint=$(diff_fingerprint "$wt") || exit 1

  record="review=$gen $fingerprint $tip $reviewer"
  if ! grep -qxF "$record" "$MARKER" 2>/dev/null; then
    { cat "$MARKER"; printf '%s\n' "$record"; } | write_marker
  fi
  echo "recorded your assertion that $reviewer reviewed $ID, pinned to the diff at $tip"
}

cmd_check() {
  [ $# -eq 2 ] || { usage; exit 1; }
  # Taken before the marker is read, so the whole read-then-compare cannot
  # interleave with a flag or a reviewed on the same task.
  hold_marker_lock
  refuse_malformed_marker
  # Absent, which the line above has just told apart from malformed: this task
  # was never flagged, so there is nothing to enforce. (Worded without the
  # obvious adverb on purpose - it is one of the sweep words in the header, and
  # a false positive there costs every later reader a triage.)
  if [ ! -f "$MARKER" ]; then
    exit 0
  fi
  local role records unpinned wt current record body fingerprint latest gen
  local reviewed_commit reviewer tip extra record_gen
  role=$(grep '^role=' "$MARKER" | tail -1 | cut -d= -f2- || true)
  role=${role:-independent-review}
  records=$(grep '^review=' "$MARKER" || true)
  unpinned=$(grep '^reviewed_by=' "$MARKER" || true)

  if [ -z "$records" ] && [ -z "$unpinned" ]; then
    echo "error: $ID is ultracode-flagged (role=$role) but has no review recorded yet - dispatch a genuinely separate task to review the finished diff, then run: fm-ultracode-guard.sh reviewed $ID <reviewer-task-id>" >&2
    exit 1
  fi

  if [ -z "$records" ]; then
    reviewer=$(printf '%s\n' "$unpinned" | tail -1 | cut -d= -f2-)
    {
      echo "error: $ID is ultracode-flagged (role=$role) and its review was recorded before reviews were pinned to the diff they covered:"
      echo "  reviewed by:  $reviewer (recorded by whoever ran reviewed; not verified here)"
      echo "  Nothing in that record shows whether the review still matches the current code, so it cannot stand in for one that does."
      echo "  Have the reviewer confirm the current diff (bin/fm-review-diff.sh $ID), then re-run: fm-ultracode-guard.sh reviewed $ID $reviewer"
    } >&2
    exit 1
  fi

  wt=$(task_worktree) || exit 1
  current=$(diff_fingerprint "$wt") || exit 1
  gen=$(marker_generation)

  # A record must name the CURRENT generation and the CURRENT diff identity.
  # Any other shape - a record from a superseded requirement, or one written
  # before generations existed - is simply not a match, so the refusal below
  # is what a caller gets.
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    body=${record#review=}
    case "$body" in
      *' '*' '*' '*) ;;
      *) continue ;;
    esac
    record_gen=${body%% *}
    body=${body#* }
    fingerprint=${body%% *}
    if [ -n "$gen" ] && [ "$record_gen" = "$gen" ] && [ "$fingerprint" = "$current" ]; then
      exit 0
    fi
  done <<EOF
$records
EOF

  latest=$(printf '%s\n' "$records" | tail -1)
  body=${latest#review=}
  body=${body#* }
  body=${body#* }
  reviewed_commit=${body%% *}
  reviewer=${body#* }
  tip=$(current_tip "$wt") || tip="<unresolved>"
  {
    echo "error: $ID is ultracode-flagged (role=$role) and the recorded review no longer covers the current diff:"
    echo "  reviewed by:  $reviewer (recorded by whoever ran reviewed; not verified here)"
    echo "  reviewed at:  $reviewed_commit"
    echo "  current tip:  $tip"
    if [ "$reviewed_commit" = "$tip" ]; then
      echo "  The local tip is unchanged, so the compared diff itself moved - typically the open PR head advanced past this worktree."
    else
      echo "  The code has changed since that review, so nothing recorded covers what would ship."
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
