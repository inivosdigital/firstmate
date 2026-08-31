#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, and the working/paused absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
# Status-span classification captures one file endpoint and reports every
# actionable event through that endpoint before the endpoint may be committed.
# An absent status file is a successful empty span, while an existing status
# object that cannot be read or identified is a classification failure with no
# committable endpoint.
# A presentation marker independently stores the last reported file signature
# and the last successfully classified position.
# Successful classification advances both facts through the captured endpoint;
# after a failure is reported, only the reported signature advances, so the same
# observed state alarms once while every unclassified byte remains for recovery.
# The reported signature includes path type, mode, symlink target, and observable
# failure kind, so a readability change is a new state that triggers another read.
# A missing, malformed, identity-mismatched, or past-end classified position reads
# from byte 0, preferring a bounded duplicate over a lost event.
#
# There are four documented exceptions. The absorb classification
# (crew_absorb_class and its working/paused wrappers) is NOT a pure status-file
# read: it reuses bin/fm-crew-state.sh, which may make a bounded no-mistakes call,
# to decide whether a crew that just stopped its turn or went stale is working,
# deliberately paused, or neither. Callers run it ONLY on no-verb signal handling
# and first sighting of a stale hash, never on every wake, so the per-wake triage
# stays cheap. status_open_decisions_incremental (see "incremental (cursor-backed)
# open-decisions fold" below) also writes: it persists a per-status-file byte
# cursor and folded open-set as a side effect, so a per-drain fleet-wide scan
# stays bounded by new appends instead of re-reading each task's whole lifetime
# log every time. The third is _fm_status_strip_timestamp, which returns its
# result in the _FM_STATUS_NORMALIZED global rather than printing it, so the
# three status-line parsers do not fork a subshell per call; the reason and the
# rule that keeps it safe are recorded at that function.
# The fourth is crew_worktree_written_since, which reads the task's meta file and
# walks a bounded slice of its worktree instead of a status file, so callers run
# it only at the moment they would otherwise escalate.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# crew_absorb_class's orphaned-run-step override (below) needs
# fm_backend_agent_alive to confirm a crewmate's process is actually gone.
# Both bin/fm-watch.sh and bin/fm-supervise-daemon.sh already source
# fm-backend.sh themselves, but a standalone sourcing (as tests do) would not
# have it, so source it here too - re-sourcing is idempotent (function/default
# definitions only, no side effects) and safe either way.
# shellcheck source=bin/fm-backend.sh
. "$_FM_CLASSIFY_LIB_DIR/fm-backend.sh"

# fm_run_timed, the shared hard bound the worktree write probe below puts around
# its one filesystem walk. bin/fm-timeout-lib.sh owns bounded execution for this
# repo, so nothing here re-derives the coreutils/BSD/perl selection. That library
# declares `set -u` for its own hygiene, which a sourced sibling must not impose on
# THIS library's consumers - several of them deliberately run without it - so the
# caller's setting is restored around the source.
case $- in *u*) _fm_classify_nounset=on ;; *) _fm_classify_nounset=off ;; esac
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$_FM_CLASSIFY_LIB_DIR/fm-timeout-lib.sh"
[ "$_fm_classify_nounset" = on ] || set +u
unset _fm_classify_nounset

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause or a verified captain hold.
# Far longer than the wedge threshold (FM_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten hold cannot rot
# invisibly - it re-surfaces once for a recheck every window. One hour by default;
# both consumers read FM_PAUSE_RESURFACE_SECS with this default so the cadence has
# one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# fm-captain-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count here;
# callers that need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed) return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the leading verb
# (status_line_verb), so a reason mentioning "paused" elsewhere does not
# false-match and a stamped line is read the same as a plain one.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line's leading verb is the verified captain-held transfer verb.
# The same pure verb read as status_is_paused, and the discriminator a supervisor
# needs once a declared wait has already been recognized: the two declarations get
# the same bounded cadence, but they block on DIFFERENT humans, so a recheck that
# names an external dependency for a hold points the captain away from the fact
# that they are the one who can clear it.
status_is_captain_held() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave a crew's endpoint idle, so both
# supervisors give them one cadence: the away-mode daemon defers the wedge and
# ages a pause marker instead, and the watcher applies its bounded pause cadence
# once pause_state_class has admitted the wait (fm-watch.sh owns which liveness
# evidence each kind of crew must supply for that).
status_is_paused_or_captain_held() {  # <status-line>
  local line=$1
  status_is_paused "$line" || status_is_captain_held "$line"
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line above) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the status-fold contract that fixes this - a needs-decision/blocked
# line OPENS a keyed decision, and only an explicit resolution or a verified
# captain-held backlog transfer referencing that key CLOSES it; a later unrelated
# terminal line never clears an open captain decision.
# Who WRITES the closing line is owned elsewhere: the answering firstmate closes
# at answer time through fm-send's --resolve-key (bin/fm-send.sh header), and a
# worker self-closes only a blocker that cleared without an answer (bin/fm-brief.sh
# rule 6), so closure never depends on a busy worker's discipline.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token names the decision. Its documented
# position sits between the verb and the colon, and a complete token at the
# head of the note is accepted as an EQUIVALENT position, because that
# misplaced-colon shape is common real worker output whose stated key must
# never silently collapse into the shared "default" bucket (issue #2109):
#   needs-decision [key=api-shape]: <summary>
#   needs-decision: [key=api-shape] <summary>
#   resolved       [key=api-shape]: <how it was decided>
# Both positions state the same key and yield the same note (a consumed
# note-head token is key metadata, stripped from the note); when both positions
# carry a token, the documented before-colon one wins and the note-head token
# stays note text. A token deeper inside the note is prose, never a stated key,
# so a summary merely MENTIONING "[key=x]" cannot open or close that decision.
# A line with no token in either position uses the key "default", preserving
# the historical one-open-decision-per-task behavior (a bare "resolved:" closes
# "default"). A stated key whose slug fails the charset below is rejected (the
# folds skip the line), never rewritten to "default".
# The three parsers are pure reads of a single line. Status metadata may contain
# any number of "[name=value]" tags before the colon, in any order, so verb
# parsing ends at the first tag rather than special-casing "[key=...]".
#
# All three split on the first colon, so all three break identically
# on any prefix that contains a colon of its own. The one that occurs in practice
# is an ISO-8601 timestamp: nothing tells a worker not to prefix its status lines
# with one (bin/fm-brief.sh's scaffold specifies "<state>: <one short line>" and
# is silent about a prefix), and workers do. On such a line the whole family
# misreads at once - the verb parses as "2026-08-08T06", the note as
# "18:42Z blocked: ...", and the key falls back to "default".
#
# That produces three failures, measured against the shipped library, 2026-08-08:
#
#   1. A declared pause stops registering, so an idle pane that is correctly
#      paused re-escalates as a possible wedge every window. Noisy, but visible.
#
#   2. A stamped needs-decision or blocked line opens NO decision at all: the
#      mangled verb never matches the needs-decision|blocked arm below, so there
#      is no record to close and nothing ever reaches the fleet-wide OPEN
#      DECISIONS surface. A keyed line loses its last line of defence too, since
#      the free-text fallback greps for a literal "needs-decision:" that a
#      "needs-decision [key=x]:" line does not contain.
#
#   3. The unclosable case is the mirror image: a PLAIN opener answered by a
#      STAMPED resolution. The opener registers, the resolution's mangled verb
#      matches no closing arm, and the decision stays open forever.
#
# Two and three are the dangerous pair, and they fail in opposite directions:
# one hides an escalation that was raised, the other keeps one alive that was
# already answered.
#
# The fix normalizes ONCE, here, via _fm_status_strip_timestamp below, rather
# than teaching each caller to distrust the first colon. Two approaches were
# considered:
#
#   Chosen: strip a leading timestamp before parsing. It needs no knowledge of
#   the verb vocabulary, so it keeps working under the FM_CAPTAIN_RE,
#   FM_CLASSIFY_PAUSED_VERB, FM_CLASSIFY_RESOLVE_VERB and
#   FM_CLASSIFY_CAPTAIN_HELD_VERB overrides; and because all three parsers share
#   the one normalizer, verb, note and key cannot disagree about where the
#   status line really starts.
#
#   Rejected: parse the verb as whichever colon-delimited token matches a known
#   verb. It inverts the dependency (the parser would have to know every
#   consumer's vocabulary, including the overridable ones); it would empty the
#   verb VALUE for a legacy bare line such as "merged", which two consumers use
#   for more than a membership test (bin/fm-fleet-snapshot.sh publishes it as
#   last_event.state in the snapshot JSON the session digest reads, and
#   bin/fm-crew-state.sh maps it), so such a line would report an empty state;
#   and, decisively, it fixes only the verb, leaving the note garbled and the
#   key wrong, so a keyed decision would open under "default" while its
#   resolution closes the real key - strictly worse than the unfixed parse,
#   because it manufactures the unclosable decision described above instead of
#   merely failing to open one.
#   (status_is_captain_relevant's free-text fallback would NOT break under that
#   alternative: an empty verb still clears the exclusion set and the free-text
#   match still runs against the whole original line. Measured, not assumed.)
#
# When the verb still cannot be parsed - an unrecognized prefix format leaves a
# multi-word token before the colon - the deliberate rule is that it may never
# SUPPRESS anything. It is not the pause verb, not captain-held, not terminal,
# and opens no activity phase or decision, so an unreadable line cannot quiet a
# pane; it keeps aging on the ordinary wedge path, which re-escalates once per
# window. Captain-relevance is deliberately NOT granted to it: the away-mode
# daemon treats a captain-relevant nonterminal verdict as "already surfaced" and
# clears wedge aging (bin/fm-supervise-daemon.sh), then dedupes the line by
# content, so granting it would trade a repeating wedge alarm for a single
# one-shot surface - quieter, not louder, which is the wrong direction for
# exactly the failure this whole section exists to prevent.

# Strip a leading ISO-8601 timestamp from a status line, so the parsers below
# see the same "<verb>[ key-token]: <note>" shape whether or not the worker
# stamped its line. Accepts the bare and bracketed forms of a date, optionally
# followed by a time (T-, t- or space-separated, seconds and fractional seconds
# optional) and a zone (Z or an offset). Assigns the normalized line to
# _FM_STATUS_NORMALIZED rather than printing it; see the cost note below.
#
# Anchoring is what makes this safe rather than a second guess: the prefix must
# begin with a full YYYY-MM-DD date, which no status verb can, AND be followed
# by its closing bracket where bracketed and then whitespace. Anything that
# fails either check is returned untouched, so a plain line - including an
# unstamped legacy line such as "merged" or "PR ready" - is never rewritten.
# All three anchors are pinned by tests; loosening any of them moves a line from
# the non-suppressing unparseable path to a declared pause, which is the
# expensive direction, so none of them may be relaxed without replacing the
# assertion that holds it.
#
# Cost, so the next reader does not have to re-measure it, and why this helper
# writes a global instead of printing its result. Printing would keep it a pure
# read, but each of the three parsers would then fork a subshell per call:
# measured on this ARM host, roughly 266us -> 2988us for status_line_verb, with
# a whole-file status_open_decisions over 500 lines going from about 7.4s to
# about 11.5s. Assigning to _FM_STATUS_NORMALIZED and having the parsers read it
# costs about 216us to 468us per call instead, and one function still owns the
# rule, so verb, note and key still cannot disagree about where the status line
# really starts. It stays bash-3.2 safe, using no local -n.
#
# The trade paid for that is this helper being the third documented exception to
# the pure-read character claimed in the file header, and one rule every caller
# owes: read _FM_STATUS_NORMALIZED immediately after the call, before any other
# parser call can overwrite it. All three callers below do, and each sets it on
# every return path, so no caller can read a value left by an earlier line.
_fm_status_strip_timestamp() {  # <status-line> -> sets _FM_STATUS_NORMALIZED
  local rest bracketed=''
  rest=$1
  rest=${rest#"${rest%%[![:space:]]*}"}
  case "$rest" in
    \[*) rest=${rest#\[}; bracketed=yes ;;
  esac
  case "$rest" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) rest=${rest#??????????} ;;
    *) _FM_STATUS_NORMALIZED=$1; return 0 ;;
  esac
  case "$rest" in
    [Tt][0-9][0-9]:[0-9][0-9]*|' '[0-9][0-9]:[0-9][0-9]*)
      rest=${rest#?}                                     # T / t / space separator
      rest=${rest#?????}                                 # HH:MM
      case "$rest" in :[0-9][0-9]*) rest=${rest#???} ;; esac       # :SS
      case "$rest" in                                              # .fff
        .[0-9]*) rest=${rest#.}; rest=${rest#"${rest%%[!0-9]*}"} ;;
      esac
      case "$rest" in                                              # zone
        [Zz]*) rest=${rest#?} ;;
        [+-][0-9][0-9]:[0-9][0-9]*) rest=${rest#??????} ;;
        [+-][0-9][0-9][0-9][0-9]*) rest=${rest#?????} ;;
        [+-][0-9][0-9]*) rest=${rest#???} ;;
      esac
      ;;
  esac
  if [ -n "$bracketed" ]; then
    case "$rest" in
      \]*) rest=${rest#?} ;;
      *) _FM_STATUS_NORMALIZED=$1; return 0 ;;
    esac
  fi
  case "$rest" in
    [[:space:]]*) ;;
    *) _FM_STATUS_NORMALIZED=$1; return 0 ;;
  esac
  _FM_STATUS_NORMALIZED=${rest#"${rest%%[![:space:]]*}"}
}

# Correlation tokens. That bracket rule already covers every BRACKETED tag,
# including the "[corr=<16 hex>]" form bin/fm-secondmate-report.sh writes. It
# does not cover the UNBRACKETED token that bin/fm-pending-reply-lib.sh writes
# (fm_pending_reply_corr_token), which a secondmate answering a marked request
# echoes on its parent status line ahead of the key tag (bin/fm-brief.sh), so a
# real transition routinely arrives as
#   needs-decision corr=<16 hex> [key=texte-du-mur]: <summary>
#   resolved       corr=<16 hex> [key=texte-du-mur]: <how it was decided>
# and a recovery turn can leave two such tokens on one line. All of those must
# read as the bare verb, in BOTH directions: a verb parse that keeps the token
# glued on matches no arm of _fm_decision_fold_line, so the opener never opens
# and the closer never closes, and a captain decision goes silently missing.
# Recognition starts only AFTER the retained leading verb: a token-first line
# keeps that token, so its following word cannot impersonate a transition and
# close a decision the captain is owed.
#
# The token grammar is OWNED by bin/fm-pending-reply-lib.sh
# (fm_pending_reply_corr_token, FM_PENDING_REPLY_CORR_RE). That library sources
# this one, so it cannot be sourced back here; the pattern below is a deliberate
# second statement of the SHAPE alone, and tests/fm-classify-corr-token.test.sh
# pins the two together through the real writers so they cannot drift.
#
# Recognition is deliberately narrow: EXACTLY the token that writer emits, whole
# word, and nothing else. An arbitrary "<name>=<value>" token is NOT skipped.
# Skipping unknown tokens would be the permissive road - it would let any
# free-text word carrying an equals sign ("resolved x=1 [key=k]: ...") reduce to
# a bare verb and impersonate a transition, which is the takeover the strict
# parse and _fm_decision_key_transition_allowed exist to prevent. Recognising
# only what a firstmate library actually writes costs one more line here each
# time a real new token shape is introduced, and that is the intended trade: a
# new shape is a deliberate, reviewed edit rather than a silent widening. A line
# whose token is malformed, wrong-length, or merely mentioned in prose keeps its
# extra words and therefore stays a non-transition, exactly as before.
#
# The 16 hex classes are written out literally rather than built from a
# variable, the same way bin/fm-secondmate-report.sh validates the id it is
# handed: a variable holding a glob is only re-read as a pattern under some
# shells' expansion rules, and a safety parse must not turn on that.
#
# 0 if <word> is, in whole, an unbracketed correlation token this fleet's own
# tooling writes. The bracketed form never reaches here: the tag rule above has
# already ended the verb parse at its opening bracket.
_fm_classify_is_corr_token() {  # <word>
  case "$1" in
    corr=[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
      return 0
      ;;
  esac
  return 1
}

status_line_verb() {  # <status-line> -> leading verb word
  local v out='' word
  _fm_status_strip_timestamp "$1"
  v=${_FM_STATUS_NORMALIZED%%:*}
  v=${v%%\[*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  # Fast path, and the whole no-regression guarantee: a prefix that cannot
  # contain a correlation token is returned byte-for-byte as before, so every
  # line without one keeps its exact historical verb, spacing included.
  case "$v" in
    *corr=*) ;;
    *) printf '%s' "$v"; return 0 ;;
  esac
  # Retain the first word, then drop only recognised tokens from the remaining
  # whole words. Anything unrecognised stays, so prose still matches no verb.
  word=${v%%[[:space:]]*}
  out=$word
  v=${v#"$word"}
  v=${v#"${v%%[![:space:]]*}"}
  while [ -n "$v" ]; do
    word=${v%%[[:space:]]*}
    v=${v#"$word"}
    v=${v#"${v%%[![:space:]]*}"}
    _fm_classify_is_corr_token "$word" && continue
    out="$out $word"
  done
  printf '%s' "$out"
}
# 0 when a complete "[key=...]" token sits in the documented position before
# the line's first colon (or anywhere on a line that has no colon at all).
_fm_key_before_colon() {  # <status-line>
  case "${1%%:*}" in
    *\[key=*\]*) return 0 ;;
    *) return 1 ;;
  esac
}
# Raw slug of a complete "[key=<slug>]" token at the head of the note (the
# first thing after the line's first colon, ignoring whitespace). Fails when
# the line has no colon or no complete token there; slug charset validity is
# the caller's check via _fm_decision_slug_ok, exactly as for the before-colon
# position.
#
# Assigns to _FM_KEY_NOTE_HEAD rather than printing, for the same measured
# reason _fm_status_strip_timestamp does: both of its callers sit on the
# per-status-line parse path, and printing would fork a subshell per line. The
# same one rule applies - read _FM_KEY_NOTE_HEAD immediately after a 0 return,
# before any other parser call can overwrite it.
_fm_key_at_note_head() {  # <status-line> -> sets _FM_KEY_NOTE_HEAD
  local rest
  case "$1" in
    *:*) rest=${1#*:} ;;
    *) return 1 ;;
  esac
  rest=${rest#"${rest%%[![:space:]]*}"}
  case "$rest" in
    \[key=*\]*) rest=${rest#\[key=}; _FM_KEY_NOTE_HEAD=${rest%%\]*} ;;
    *) return 1 ;;
  esac
}
# 0 when a stated key slug is well-formed: nonempty, A-Za-z0-9._- only.
_fm_decision_slug_ok() {  # <slug>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}
status_line_note() {  # <status-line> -> text after the first colon, trimmed
  local line n k
  _fm_status_strip_timestamp "$1"
  line=$_FM_STATUS_NORMALIZED
  case "$line" in
    *:*) n=${line#*:}; n=${n#"${n%%[![:space:]]*}"} ;;
    *) printf '%s' "$line"; return 0 ;;
  esac
  # A note-head token that states this line's key (no before-colon token, valid
  # slug) is key metadata, not note text: strip it so both stated-key positions
  # yield the same note. Read from the normalized line so a timestamp-stamped
  # line resolves its note-head key exactly like an unstamped one.
  if ! _fm_key_before_colon "$line" && _fm_key_at_note_head "$line" \
    && k=$_FM_KEY_NOTE_HEAD && _fm_decision_slug_ok "$k"; then
    n=${n#"[key=$k]"}
    n=${n#"${n%%[![:space:]]*}"}
  fi
  printf '%s' "$n"
}
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local line k
  _fm_status_strip_timestamp "$1"
  line=$_FM_STATUS_NORMALIZED
  if _fm_key_before_colon "$line"; then
    k=${line%%:*}
    k=${k#*\[key=}
    k=${k%%\]*}
  else
    _fm_key_at_note_head "$line" || { printf 'default'; return 0; }
    k=$_FM_KEY_NOTE_HEAD
  fi
  _fm_decision_slug_ok "$k" || return 1
  printf '%s' "$k"
}
# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
# Fold ONE status line into an existing "<key>\t<verb>\t<note>\n"-per-line open
# set, applying the same needs-decision/blocked-opens, resolved/captain-held-closes
# rule status_open_decisions documents above. Pure text transform, no file I/O.
# This is the ONE place the per-line open/resolved rule is written; both the
# whole-file fold (status_open_decisions) and the incremental cursor-backed fold
# (status_open_decisions_incremental) below call this instead of re-deriving the
# rule, so the two consumption strategies can never drift apart on semantics.
# Reserved decision-key namespaces, and the rule that makes them mean something.
#
# A key like `pending-reply-<id>` names a decision that one library raises and is
# the only thing that ever closes it. Every writer reaches this same stream: a
# local mate appends straight into it, and a remote mate's lines are mirrored
# into it verbatim. So without a rule here, any writer could claim a reserved
# key with an unrelated note, take the key over in this fold, and permanently
# block the owner's close - leaving a decision nothing will ever resolve - or
# clear the owner's decision with a bare resolution.
#
# The rule is deliberately generic, so this fold needs no knowledge of any
# particular owner: a reserved key may only be opened or closed by a line whose
# note speaks that namespace's own vocabulary, which its owner states by
# beginning the note with a `<namespace>...:` token. A line failing that is not a
# decision transition at all here and is folded as ordinary status. This is a
# consumer-side rule on purpose - it protects local and remote writers
# identically, and it can never fail a whole delta or wedge a stream the way a
# writer-side rejection would.
FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT='pending-reply-'

# 0 when <key> is not reserved, or is reserved and <note> speaks its vocabulary.
_fm_decision_key_transition_allowed() {  # <key> <note>
  local key=$1 note=$2 prefix
  for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}; do
    case "$key" in
      "$prefix"*)
        case "$note" in
          "$prefix"*:*) return 0 ;;
          *) return 1 ;;
        esac
        ;;
    esac
  done
  return 0
}

_fm_decision_fold_line() {  # <open-set> <status-line> <resolve-verb> <held-verb>
  local open=$1 line=$2 resolve=$3 held=$4 verb key note
  # Blank-line guard. A `case` glob answers "does this line hold any non-space
  # character" in one pattern match; the equivalent ${line//[[:space:]]/} costs
  # tens of milliseconds per line under bash 3.2's global bracket-class
  # substitution, which is the whole per-line cost of both folds on a status log
  # of ordinary width. Same verdict, bounded cost.
  case "$line" in
    *[![:space:]]*) ;;
    *) printf '%s' "$open"; return 0 ;;
  esac
  verb=$(status_line_verb "$line")
  key=$(_fm_decision_key "$line") || { printf '%s' "$open"; return 0; }
  _fm_decision_key_transition_allowed "$key" "$(status_line_note "$line")" \
    || { printf '%s' "$open"; return 0; }
  case "$verb" in
    needs-decision|blocked)
      note=$(status_line_note "$line")
      open=$(_fm_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
      ;;
    "$resolve"|"$held")
      open=$(_fm_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      ;;
  esac
  printf '%s' "$open"
}

# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read of
# the file, no globals beyond the optional FM_CLASSIFY_RESOLVE_VERB override. This
# is the durable open-set the fleet snapshot and any point-in-time consumer must use
# instead of trusting the last status line.
# The scan_open_decisions wrapper below enumerates a whole directory rather than
# a single caller-chosen path, so a status file that is itself a symlink (e.g.
# escaping the state directory) is rejected outright with a plain [ -L ] check
# before any read - a cheap builtin, unlike fm_wake_latest_event's O_NOFOLLOW
# subprocess read, which exists for that function's much narrower payload-driven
# path resolution rather than this directory-local glob.
status_open_decisions() {  # <status-file>
  local f=$1 line resolve held open=''
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held")
  done < "$f"
  printf '%s' "$open"
}

# 0 when <key> has a record in a folded "<key>\t<verb>\t<note>" open set.
_fm_open_set_has() {  # <open-set> <key>
  case "$1" in
    "$2"$'\t'*|*$'\n'"$2"$'\t'*) return 0 ;;
    *) return 1 ;;
  esac
}

# The verb stored for <key> in a folded open set (empty when it has no record).
_fm_open_set_verb() {  # <open-set> <key>
  local line
  while IFS= read -r line; do
    case "$line" in
      "$2"$'\t'*) line=${line#*$'\t'}; printf '%s' "${line%%$'\t'*}"; return 0 ;;
    esac
  done <<EOF
$1
EOF
  return 0
}

# The verb that last moved <key> in a status stream, which is what tells a
# consumer HOW the status side currently reads that key. Prints the opening verb
# (needs-decision or blocked) while the key is still open, the closing verb
# (resolved, or the captain-held durable-transfer verb) once it is closed, and
# nothing at all when no line in the stream ever stated a transition for it.
#
# The distinction between the two closing verbs is the whole point: a
# `captain-held` close is the VERIFIED handoff to a durable captain-held task
# (fm-captain-hold.sh complete writes it only after verifying that task), so the
# structured row staying open afterwards is correct. A `resolved` close claims
# the question is settled outright, so a structured row still open behind it is a
# contradiction between the two records - see fm-captain-hold.sh's `diverged`.
#
# Semantics are not re-derived here: every line goes through the same
# _fm_decision_fold_line rule the two folds use, and the reported verb is read
# off the transitions that rule produces. Only lines whose parsed key equals the
# requested one can move that key, so a caller-supplied key other than "default"
# lets the scan pre-filter the stream to lines carrying its token and stay cheap
# on a long log.
status_key_closing_verb() {  # <status-file> <key>
  local f=$1 want=$2 line resolve held open='' was verb='' stream
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  [ -n "$want" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  if [ "$want" = default ]; then
    stream=$(cat "$f") || return 0
  else
    stream=$(grep -F "[key=$want]" "$f") || stream=''
  fi
  [ -n "$stream" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    was=0
    _fm_open_set_has "$open" "$want" && was=1
    open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held")
    if [ "$was" = 1 ] && ! _fm_open_set_has "$open" "$want"; then
      verb=$(status_line_verb "$line")
    fi
  done <<EOF
$stream
EOF
  if _fm_open_set_has "$open" "$want"; then
    _fm_open_set_verb "$open" "$want"
    return 0
  fi
  printf '%s' "$verb"
}

# Fleet-wide wrapper around status_open_decisions: scans every task's status
# log under <state> and prefixes each still-open decision with its owning task
# id, so a per-wake or per-session surface can print the consolidated open set
# without re-walking the fold itself. A thin directory scan only - the fold
# above remains the ONE place the open/resolved semantics are decided. Prints
# one "<task>\t<key>\t<verb>\t<note>" line per open decision, in glob (task id)
# order; prints nothing when none are open.
scan_open_decisions() {  # <state>
  local state=$1 f task open line
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    open=$(status_open_decisions "$f") || continue
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done
  return 0
}

# --- incremental (cursor-backed) open-decisions fold ------------------------
#
# status_open_decisions above re-reads and re-folds a status file's ENTIRE
# lifetime on every call, so its cost grows with total log size. A per-drain
# fleet-wide scan using that whole-file function would pay that cost for every
# task on every wake, which grows unbounded as tasks run longer and accumulate
# status history. status_open_decisions_incremental and scan_open_decisions_incremental
# below are the bounded-cost siblings used for that per-drain path: each call
# reads only the bytes appended to a status file since its own last call (a
# persisted per-file byte cursor) and folds just those new lines into a
# persisted running open-set, via the exact same _fm_decision_fold_line rule
# status_open_decisions uses - so the two strategies can never disagree on what
# is open. Cost is bounded by NEW appends since the last drain, not by the
# status file's total lifetime size.
#
# Correctness invariant (unchanged from the whole-file fold): an open decision
# is dropped ONLY by an explicit resolved/captain-held line for its exact key,
# never by cursor advancement, age, or being buried under later appends - the
# persisted open-set carries every still-open key forward across calls
# regardless of how much new unrelated log content has since been folded in.
#
# The cursor format is `version`, `offset`, `ident`, then the folded open set.
# FM_OPEN_DECISIONS_FOLD_VERSION must be bumped whenever
# _fm_decision_fold_line semantics change, so persisted state from an older
# interpretation is discarded and rebuilt from byte 0.
#
# Cursor invalidation is deliberately minimal, matching how status files are
# ACTUALLY used in this repo: every one is created once (`>`) and only ever
# appended to (`>>`) - never replaced, renamed, or rewritten in place. So the
# ways a cursor can go stale are a fold-version mismatch, a shrink (truncated),
# or the file at this path being a different file than before
# (replaced/rotated/recreated), which a changed device+inode makes an O(1) check
# via a single `stat` call - no content hashing, no re-reading the consumed
# prefix. Any signal falls back to a full re-fold of the whole current file from
# byte 0 - byte for byte what status_open_decisions itself would compute - and
# rewrites the cursor from that clean baseline. A same-inode, same-size,
# in-place byte edit is NOT detected; that is a deliberately accepted gap
# because no code path in this repo ever does that to a status file.
#
# The other real failure mode is OUR OWN read failing (a stat/wc/tail I/O
# error), not a malformed writer: every such read here is checked, and on
# failure this reports the already-trusted persisted set unchanged rather than
# risking a silent invalidation that would wipe it - never a bare "empty" as if
# nothing were open.
#
# Not a pure status-file read: this writes/rewrites the sibling cursor file as a
# side effect (state/.<task>.open-decisions-cursor), the library's second
# documented exception to the pure-read rule after crew_absorb_class. The write
# is atomic (temp file + rename), so a crash between calls leaves either the
# prior cursor or the new one, never a partial one. bin/fm-wake-drain.sh calls
# this only after releasing the wake-queue lock, so a hypothetical race between
# two overlapping drains can at worst redo a little folding work twice - never
# drop an open decision - because a losing writer's offset can only ever be
# equal to or behind an already-recorded byte position, and the next call
# re-derives from whatever offset actually landed on disk.
_fm_open_decisions_cursor_path() {  # <status-file>
  local f=$1 dir base
  dir=$(dirname "$f")
  base=$(basename "$f")
  printf '%s/.%s.open-decisions-cursor' "$dir" "${base%.status}"
}

# 4: verb parsing ends at the first "[name=value]" tag rather than only at a
# "[key=...]" one, so lines carrying another bracketed tag first became opens
# and closes.
# 5: status_line_verb now also reads through an UNBRACKETED correlation token,
# so lines that previously folded as ordinary status become opens and closes.
# Version 4 was already spent on the bracketed-tag parser change above, and a
# cursor persisted under that reading predates this one, so it must still be
# discarded and rebuilt from byte 0 under the new reading.
FM_OPEN_DECISIONS_FOLD_VERSION=5

# Portable device:inode identity for the rotation/recreation check below.
_fm_open_decisions_file_ident() {  # <file> -> strongest available identity
  local f=$1 epoch birth ident
  if [ -n "${FM_STATUS_IDENTITY_READER:-}" ]; then
    "$FM_STATUS_IDENTITY_READER" "$f"
    return
  fi
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    ident=$(LC_ALL=C stat -f '%d:%i' "$f" 2>/dev/null) || return 1
    epoch=$(LC_ALL=C stat -f '%B' "$f" 2>/dev/null) || epoch=0
    if [ "$epoch" != 0 ]; then birth=$(LC_ALL=C stat -f '%FB' "$f" 2>/dev/null) || birth=''; else birth=''; fi
  else
    ident=$(LC_ALL=C stat -c '%d:%i' "$f" 2>/dev/null) || return 1
    epoch=$(LC_ALL=C stat -c '%W' "$f" 2>/dev/null) || epoch=0
    if [ "$epoch" != 0 ]; then birth=$(LC_ALL=C stat -c '%w' "$f" 2>/dev/null) || birth=''; else birth=''; fi
  fi
  case "$ident$birth" in *$'\t'*|*$'\n'*|'') return 1 ;; esac
  if [ -n "$birth" ]; then printf 'strong:%s:%s' "$ident" "$birth"; else printf 'weak:%s' "$ident"; fi
}

_fm_status_file_size() {  # <status-file>
  local f=$1
  if [ -n "${FM_STATUS_SIZE_READER:-}" ]; then
    "$FM_STATUS_SIZE_READER" "$f"
    return
  fi
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -f '%z' "$f" 2>/dev/null
  else
    LC_ALL=C stat -c '%s' "$f" 2>/dev/null
  fi
}

# Private scratch path for a one-shot span read, alongside the status file the
# same way the cursor above is, and PID-scoped so concurrent readers of one log
# (the watcher and the away-mode daemon both classify the same stream) never
# truncate each other's chunk.
_fm_status_span_scratch() {  # <status-file>
  printf '%s.span.%s' "$(_fm_open_decisions_cursor_path "$1")" "$$"
}

_fm_status_read_span() {  # <status-file> <start-offset> <byte-length>
  local f=$1 start=$2 length=$3
  if [ -n "${FM_STATUS_SPAN_READER:-}" ]; then
    "$FM_STATUS_SPAN_READER" "$f" "$start" "$length"
    return
  fi
  perl -MFcntl=:DEFAULT -e '
    my ($path, $start, $length) = @ARGV;
    sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    sysseek($file, $start, 0) == $start or exit 1;
    while ($length > 0) {
      my $want = $length > 65536 ? 65536 : $length;
      my $read = sysread($file, my $chunk, $want);
      defined($read) && $read > 0 or exit 1;
      print $chunk or exit 1;
      $length -= $read;
    }
  ' "$f" "$start" "$length"
}

status_open_decisions_incremental() {  # <status-file> [<captured-end-offset>]
  local f=$1 captured_end=${2:-} cf offset ident open='' trusted_open='' cursor_data first rest offset_line ident_line
  local version='' size actual_size cur_ident resolve held chunk_file chunk_size line cursor_dirty=0
  local target_cursor
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  cf=$(_fm_open_decisions_cursor_path "$f")
  offset=0
  ident=''
  if [ -f "$cf" ] && [ -r "$cf" ] && [ ! -L "$cf" ]; then
    cursor_data=$(LC_ALL=C command cat "$cf" 2>/dev/null) || cursor_data=''
  fi
  if [ -n "${cursor_data:-}" ]; then
      first=${cursor_data%%$'\n'*}
      case "$first" in
        version=*)
          version=${first#version=}
          [ "$version" = "$FM_OPEN_DECISIONS_FOLD_VERSION" ] || version=''
          rest=${cursor_data#*$'\n'}
          offset_line=${rest%%$'\n'*}
          case "$offset_line" in
            offset=*) offset=${offset_line#offset=} ;;
            *) offset=0; version='' ;;
          esac
          case "$offset" in
            ''|*[!0-9]*) offset=0; version='' ;;
            *)
              case "$rest" in
                *$'\n'*)
                  rest=${rest#*$'\n'}
                  ident_line=${rest%%$'\n'*}
                  case "$ident_line" in
                    ident=*)
                      ident=${ident_line#ident=}
                      case "$rest" in
                        *$'\n'*) open=${rest#*$'\n'} ;;
                      esac
                      if [ -n "$version" ] && [ -n "$ident" ]; then trusted_open=$open; fi
                      ;;
                    *) offset=0; version='' ;;
                  esac
                  ;;
                *) offset=0; version='' ;;
              esac
              ;;
          esac
          ;;
      esac
  fi

  # A stat/size-read failure is a genuine I/O error, not "the file is empty" -
  # report the already-trusted persisted set unchanged rather than risking a
  # silent invalidation that would wipe it.
  cur_ident=$(_fm_open_decisions_file_ident "$f") || { printf '%s' "$trusted_open"; return 0; }
  [ -n "$cur_ident" ] || { printf '%s' "$trusted_open"; return 0; }
  actual_size=$(_fm_status_file_size "$f") \
    || { printf '%s' "$trusted_open"; return 0; }
  actual_size=${actual_size//[[:space:]]/}
  case "$actual_size" in ''|*[!0-9]*) printf '%s' "$trusted_open"; return 0 ;; esac
  if [ -n "$captured_end" ]; then
    case "$captured_end" in
      ''|*[!0-9]*) printf '%s' "$trusted_open"; return 0 ;;
    esac
    [ "$captured_end" -le "$actual_size" ] || { printf '%s' "$trusted_open"; return 0; }
    size=$captured_end
  else
    size=$actual_size
  fi

  if [ -z "$version" ] || [ -z "$ident" ] || [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$actual_size" ]; then
    offset=0
    open=''
    trusted_open=''
    cursor_dirty=1
  fi

  if [ "$offset" -lt "$size" ]; then
    chunk_file="$cf.read.$$"
    _fm_status_read_span "$f" "$offset" "$((size - offset))" > "$chunk_file" 2>/dev/null \
      || { rm -f "$chunk_file"; printf '%s' "$trusted_open"; return 0; }
    chunk_size=$(LC_ALL=C wc -c < "$chunk_file" 2>/dev/null) \
      || { rm -f "$chunk_file"; printf '%s' "$trusted_open"; return 0; }
    chunk_size=${chunk_size//[[:space:]]/}
    case "$chunk_size" in
      ''|*[!0-9]*) rm -f "$chunk_file"; printf '%s' "$trusted_open"; return 0 ;;
    esac
    # Test-only observability seam (off by default, no production behavior
    # change): when set, records exactly how many bytes THIS call folded, so a
    # test can assert the incremental path stays bounded by new appends rather
    # than re-reading the whole file, without relying on timing or source text.
    [ -n "${FM_OPEN_DECISIONS_READ_PROBE:-}" ] \
      && printf '%s\t%s\n' "$f" "$chunk_size" >> "$FM_OPEN_DECISIONS_READ_PROBE"
    resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
    held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
    while IFS= read -r line || [ -n "$line" ]; do
      open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held")
    done < "$chunk_file"
    rm -f "$chunk_file"
    offset=$size
    cursor_dirty=1
  fi
  if [ "$cursor_dirty" -eq 1 ]; then
    target_cursor="$cf.tmp.$$"
    {
      printf 'version=%s\n' "$FM_OPEN_DECISIONS_FOLD_VERSION"
      printf 'offset=%s\n' "$offset"
      printf 'ident=%s\n' "$cur_ident"
      if [ -n "$open" ]; then printf '%s' "$open"; fi
    } > "$target_cursor" || return 1
    mv -f "$target_cursor" "$cf" || return 1
  fi
  printf '%s' "$open"
}

# Incremental sibling of scan_open_decisions: same fleet-wide directory walk and
# output shape ("<task>\t<key>\t<verb>\t<note>" per open decision), but folds
# each task's status log through status_open_decisions_incremental instead of
# the whole-file status_open_decisions, so a fleet-wide per-drain scan stays
# bounded by new appends rather than total lifetime log size across every task.
scan_open_decisions_incremental() {  # <state>
  local state=$1 f task open line
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    open=$(status_open_decisions_incremental "$f") || continue
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done
  return 0
}

status_presentation_snapshot() {  # <state>
  local state=$1 f task size ident
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    size=$(_fm_status_file_size "$f") || return 1
    size=${size//[[:space:]]/}
    ident=$(_fm_open_decisions_file_ident "$f") || return 1
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$ident" ] || return 1
    printf '%s\t%s\t%s\n' "$task" "$size" "$ident" || return 1
  done
}

status_presentation_cursor_offset() {  # <status-file>
  local f=$1 state task manifest data row_task offset ident extra cur_ident size legacy
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  state=${f%/*}
  task=${f##*/}; task=${task%.status}
  manifest="$state/.status-presentation-cursor"
  if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] || return 1
    data=$(LC_ALL=C command cat "$manifest" 2>/dev/null) || return 1
    offset=
    while IFS=$(printf '\t') read -r row_task ident legacy extra; do
      [ -n "$row_task" ] || continue
      [ -z "$extra" ] || return 1
      case "$legacy" in ''|*[!0-9]*) return 1 ;; esac
      [ -n "$ident" ] || return 1
      if [ "$row_task" = "$task" ]; then
        [ -z "$offset" ] || return 1
        offset=$legacy
        cur_ident=$ident
      fi
    done <<EOF
$data
EOF
    if [ -z "$offset" ]; then
      printf '0'
      return 0
    fi
    ident=$cur_ident
  else
    legacy=$(_fm_open_decisions_cursor_path "$f")
    if [ -e "$legacy" ] || [ -L "$legacy" ]; then
      status_open_decisions_cursor_offset "$f"
      return
    fi
    offset=0
    ident=$(_fm_open_decisions_file_ident "$f") || return 1
  fi
  cur_ident=$(_fm_open_decisions_file_ident "$f") || return 1
  size=$(_fm_status_file_size "$f") || return 1
  size=${size//[[:space:]]/}
  case "$size:$offset" in *[!0-9:]*) return 1 ;; esac
  if [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$size" ]; then offset=0; fi
  printf '%s' "$offset"
}

status_signal_seen_marker_path() {  # <state> <task-id>
  printf '%s/.seen-%s' "$1" "$(printf '%s.status' "$2" | tr '.' '_')"
}

status_heartbeat_seen_marker_path() {  # <state> <task-id>
  printf '%s/.hb-surfaced-%s' "$1" "$(printf '%s' "$2" | tr ':/.' '___')"
}

status_daemon_seen_marker_path() {  # <state> <task-id>
  printf '%s/.subsuper-seen-status-%s' "$1" "$(printf '%s' "$2" | tr ':/.' '___')"
}

_status_presentation_signature_valid() {
  local value=$1 size ident encoded
  [ "$value" = unverifiable ] && return 0
  case "$value" in
    r1:*)
      encoded=${value#r1:}
      case "$encoded" in ''|*[!0-9a-f]*) return 1 ;; esac
      return 0
      ;;
  esac
  case "$value" in *@*) size=${value%%@*}; ident=${value#*@} ;; *) return 1 ;; esac
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  case "$ident" in ''|*$'\t'*|*$'\n'*) return 1 ;; esac
}

STATUS_PRESENTATION_REPORTED=
STATUS_PRESENTATION_CLASSIFIED=
status_presentation_marker_parse() {
  local raw=$1 rest reported classified
  STATUS_PRESENTATION_REPORTED=
  STATUS_PRESENTATION_CLASSIFIED=
  case "$raw" in
    v2$'\t'*)
      rest=${raw#v2$'\t'}
      case "$rest" in *$'\t'*) reported=${rest%%$'\t'*}; classified=${rest#*$'\t'} ;; *) return 1 ;; esac
      case "$classified" in *$'\t'*) return 1 ;; esac
      _status_presentation_signature_valid "$reported" || return 1
      if [ "$classified" != - ]; then
        _status_presentation_signature_valid "$classified" || return 1
        case "$classified" in unverifiable|r1:*) return 1 ;; esac
      fi
      ;;
    *)
      _status_presentation_signature_valid "$raw" || return 1
      case "$raw" in unverifiable|r1:*) return 1 ;; esac
      reported=$raw
      classified=$raw
      ;;
  esac
  STATUS_PRESENTATION_REPORTED=$reported
  STATUS_PRESENTATION_CLASSIFIED=$classified
}

_status_observed_path_state() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -f '%HT:%p' "$1" 2>/dev/null
  else
    LC_ALL=C stat -c '%F:%f' "$1" 2>/dev/null
  fi
}

status_observed_signature() {
  local f=$1 size=${2-} ident=${3-} path_state link_target=- access kind encoded
  path_state=$(_status_observed_path_state "$f") || path_state=stat-error
  if [ -L "$f" ]; then
    link_target=$(readlink "$f" 2>/dev/null) || link_target=readlink-error
    kind=symlink
  elif [ ! -e "$f" ]; then
    kind=absent
  elif [ ! -f "$f" ]; then
    kind=nonregular
  elif [ -r "$f" ]; then
    kind=readable
  else
    kind=unreadable
  fi
  if [ -z "$size" ]; then
    size=$(_fm_status_file_size "$f") || size='size-error'
    size=${size//[[:space:]]/}
    case "$size" in ''|*[!0-9]*) size='size-error' ;; esac
  fi
  if [ -z "$ident" ]; then
    ident=$(_fm_open_decisions_file_ident "$f") || ident=identity-error
    [ -n "$ident" ] || ident=identity-error
  fi
  if [ -r "$f" ]; then access=readable; else access=unreadable; fi
  encoded=$(printf '%s\0%s\0%s\0%s\0%s\0%s' \
    "$size" "$ident" "$path_state" "$link_target" "$access" "$kind" \
    | LC_ALL=C od -An -v -tx1 | tr -d ' \n') || return 1
  printf 'r1:%s' "$encoded"
}

status_presentation_marker_reported_matches() {
  local raw
  raw=$(cat "$1" 2>/dev/null) || return 1
  status_presentation_marker_parse "$raw" || return 1
  [ "$STATUS_PRESENTATION_REPORTED" = "$2" ]
}

status_presentation_marker_offset() {
  local raw classified offset ident current
  raw=$(cat "$1" 2>/dev/null) || { printf '0'; return 0; }
  status_presentation_marker_parse "$raw" || { printf '0'; return 0; }
  classified=$STATUS_PRESENTATION_CLASSIFIED
  [ "$classified" != - ] || { printf '0'; return 0; }
  offset=${classified%%@*}; ident=${classified#*@}
  current=$(_fm_open_decisions_file_ident "$2") || { printf '0'; return 0; }
  [ "$ident" = "$current" ] || { printf '0'; return 0; }
  printf '%s' "$offset"
}

status_presentation_marker_report() {
  local marker=$1 reported=$2 raw classified=-
  _status_presentation_signature_valid "$reported" || return 1
  if raw=$(cat "$marker" 2>/dev/null) && status_presentation_marker_parse "$raw"; then
    classified=$STATUS_PRESENTATION_CLASSIFIED
  fi
  printf 'v2\t%s\t%s' "$reported" "$classified" > "$marker"
}

status_presentation_marker_commit() {
  local marker=$1 file=$2 endpoint=$3 ident=$4 current reported classified
  case "$endpoint" in ''|*[!0-9]*) return 1 ;; esac
  current=$(_fm_open_decisions_file_ident "$file") || return 1
  [ -n "$ident" ] && [ "$ident" = "$current" ] || return 1
  reported=$(status_observed_signature "$file" "$endpoint" "$ident") || return 1
  classified="${endpoint}@${ident}"
  printf 'v2\t%s\t%s' "$reported" "$classified" > "$marker"
}

status_retire_presentation_task() {  # <state> <task-id>
  local state=$1 task=$2 lock manifest tmp data row_task ident offset extra rc=0 found=0
  local signal_marker heartbeat_marker daemon_marker
  lock="$state/.status-presentation-lock"
  manifest="$state/.status-presentation-cursor"
  tmp="$manifest.tmp.$$"
  signal_marker=$(status_signal_seen_marker_path "$state" "$task")
  heartbeat_marker=$(status_heartbeat_seen_marker_path "$state" "$task")
  daemon_marker=$(status_daemon_seen_marker_path "$state" "$task")

  # A remote-home teardown can legitimately retire an endpoint ID that has no
  # status log in that home. Do not contend with that home's unrelated status
  # presenter in this no-op case. A concurrent presenter cannot add this task
  # without its status file, so a valid manifest with no matching row is a
  # durable proof that there is nothing to retire.
  if [ ! -e "$state/$task.status" ] && [ ! -L "$state/$task.status" ] \
    && [ ! -e "$state/.$task.open-decisions-cursor" ] \
    && [ ! -L "$state/.$task.open-decisions-cursor" ] \
    && [ ! -e "$signal_marker" ] && [ ! -L "$signal_marker" ] \
    && [ ! -e "$heartbeat_marker" ] && [ ! -L "$heartbeat_marker" ] \
    && [ ! -e "$daemon_marker" ] && [ ! -L "$daemon_marker" ]; then
    if [ ! -e "$manifest" ] && [ ! -L "$manifest" ]; then
      return 0
    fi
    if [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] \
      && data=$(LC_ALL=C command cat "$manifest" 2>/dev/null); then
      while IFS=$(printf '\t') read -r row_task ident offset extra; do
        [ -n "$row_task" ] || continue
        if [ -n "$extra" ] || [ -z "$ident" ]; then rc=1; break; fi
        case "$offset" in ''|*[!0-9]*) rc=1; break ;; esac
        [ "$row_task" != "$task" ] || found=1
      done <<EOF
$data
EOF
      [ "$rc" -ne 0 ] || [ "$found" -ne 0 ] || return 0
      rc=0
    fi
  fi

  fm_lock_acquire_wait "$lock" || return 1
  if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    if [ ! -f "$manifest" ] || [ ! -r "$manifest" ] || [ -L "$manifest" ]; then
      rc=1
    elif ! data=$(LC_ALL=C command cat "$manifest" 2>/dev/null); then
      rc=1
    elif ! : > "$tmp"; then
      rc=1
    else
      while IFS=$(printf '\t') read -r row_task ident offset extra; do
        [ -n "$row_task" ] || continue
        if [ -n "$extra" ] || [ -z "$ident" ]; then rc=1; break; fi
        case "$offset" in ''|*[!0-9]*) rc=1; break ;; esac
        if [ "$row_task" != "$task" ]; then
          printf '%s\t%s\t%s\n' "$row_task" "$ident" "$offset" >> "$tmp" \
            || { rc=1; break; }
        fi
      done <<EOF
$data
EOF
      if [ "$rc" -eq 0 ]; then mv -f "$tmp" "$manifest" || rc=1; fi
      [ "$rc" -eq 0 ] || rm -f "$tmp"
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$state/$task.status" "$state/.$task.open-decisions-cursor" \
      "$signal_marker" "$heartbeat_marker" "$daemon_marker" || rc=1
  fi
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

status_acknowledge_presented_snapshot() {  # <state> <snapshot> [<fully-presented-task-ids>]
  local state=$1 snapshot=$2 fully_presented=${3:-} task endpoint ident f offset lines line safe
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    safe=false
    case "
$fully_presented
" in *$'\n'"$task"$'\n'*) safe=true ;; esac
    if [ "$safe" = false ]; then
      f="$state/$task.status"
      offset=$(status_presentation_cursor_offset "$f") || return 1
      lines=$(status_new_lines_since_cursor "$f" "$endpoint") || return 1
      # Once any informational line in this span is presented fleet-wide, the
      # contiguous cursor may advance through the captured endpoint. Routine
      # lines remain unacknowledged only while they are the sole unread content,
      # preserving delayed signal annotations without replaying a handled note
      # that happened to follow a routine line.
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          *[![:space:]]*)
            if status_line_is_unread_surface "$line"; then safe=true; break; fi
            ;;
        esac
      done <<EOF
$lines
EOF
      if [ "$safe" = false ]; then endpoint=$offset; fi
    fi
    printf '%s\t%s\t%s\n' "$task" "$endpoint" "$ident" || return 1
  done <<EOF
$snapshot
EOF
}

status_commit_presentation_snapshot() {  # <state> <snapshot>
  local state=$1 snapshot=$2 task endpoint ident f cur_ident size tmp
  tmp="$state/.status-presentation-cursor.tmp.$$"
  : > "$tmp" || return 1
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    case "$endpoint" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
    [ -n "$ident" ] || { rm -f "$tmp"; return 1; }
    f="$state/$task.status"
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || { rm -f "$tmp"; return 1; }
    cur_ident=$(_fm_open_decisions_file_ident "$f") || { rm -f "$tmp"; return 1; }
    size=$(_fm_status_file_size "$f") || { rm -f "$tmp"; return 1; }
    size=${size//[[:space:]]/}
    case "$size" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
    [ "$cur_ident" = "$ident" ] && [ "$endpoint" -le "$size" ] \
      || { rm -f "$tmp"; return 1; }
    printf '%s\t%s\t%s\n' "$task" "$ident" "$endpoint" >> "$tmp" \
      || { rm -f "$tmp"; return 1; }
  done <<EOF
$snapshot
EOF
  mv -f "$tmp" "$state/.status-presentation-cursor" || { rm -f "$tmp"; return 1; }
}

scan_open_decisions_snapshot() {  # <state> <task-and-endpoint-snapshot>
  local state=$1 snapshot=$2 task endpoint ident f open line
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    f="$state/$task.status"
    open=$(status_open_decisions_incremental "$f" "$endpoint") || return 1
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done <<EOF
$snapshot
EOF
}

# --- unread status lines since the presentation cursor ----------------------
#
# The drain annotation historically printed only the newest status line, so a
# substantive `note:` answer immediately followed by a routine `note:` (or a
# pending-reply resolution buried under a later unrelated append) never reached
# the supervisor. Those verbs also never enter the OPEN DECISIONS fold, so they
# had no other surfacing path.
# These helpers are the ONE owner of "what is still unread since the last drain
# presentation": one fleet manifest records each status identity and last-
# presented byte offset, and one atomic replacement commits only the contiguous
# status spans that were successfully presented. A quiet fleet scan leaves
# routine working/done bytes unacknowledged so a subsequently published signal
# can still annotate them. A missing manifest row or changed file identity is
# offset 0 for the current file, while malformed or unreadable cursor state
# aborts presentation without advancing any offset. A trusted cursor at EOF
# prints nothing, so already-presented bytes are not replayed as new. Teardown
# retires a task's manifest row with its status file, so reusing a task ID starts
# the replacement log unread at byte 0. Informational `note:` lines and
# reserved-key pending-reply resolutions are the fleet-wide unread surface;
# they are not open decisions and are not persisted in the folded open-set.

# Read the legacy per-task open-decisions cursor used to seed the presentation
# offset before the fleet manifest exists. A fold-version mismatch, identity
# mismatch, or offset past the current size falls back to 0. Never writes unless
# a caller explicitly requests a migration snapshot.
status_open_decisions_cursor_offset() {  # <status-file>
  local f=$1 cf offset=0 ident='' version='' cursor_data first rest open=''
  local offset_line ident_line cur_ident size
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  cf=$(_fm_open_decisions_cursor_path "$f")
  if [ -e "$cf" ] || [ -L "$cf" ]; then
    [ -f "$cf" ] && [ -r "$cf" ] && [ ! -L "$cf" ] || return 1
    if cursor_data=$(LC_ALL=C command cat "$cf" 2>/dev/null); then
      first=${cursor_data%%$'\n'*}
      case "$first" in
        version=*)
          version=${first#version=}
          [ "$version" = "$FM_OPEN_DECISIONS_FOLD_VERSION" ] || version=''
          rest=${cursor_data#*$'\n'}
          offset_line=${rest%%$'\n'*}
          case "$offset_line" in
            offset=*) offset=${offset_line#offset=} ;;
            *) offset=0; version='' ;;
          esac
          case "$offset" in
            ''|*[!0-9]*) offset=0; version='' ;;
            *)
              case "$rest" in
                *$'\n'*)
                  rest=${rest#*$'\n'}
                  ident_line=${rest%%$'\n'*}
                  case "$ident_line" in
                    ident=*)
                      ident=${ident_line#ident=}
                      case "$rest" in *$'\n'*) open=${rest#*$'\n'} ;; esac
                      ;;
                    *) offset=0; version='' ;;
                  esac
                  ;;
                *) offset=0; version='' ;;
              esac
              ;;
          esac
          ;;
      esac
    else
      return 1
    fi
  fi
  cur_ident=$(_fm_open_decisions_file_ident "$f") || return 1
  [ -n "$cur_ident" ] || return 1
  size=$(_fm_status_file_size "$f") || return 1
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$version" ] || [ -z "$ident" ] || [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$size" ]; then
    offset=0
    open=''
  fi
  if [ -n "${FM_STATUS_CURSOR_SNAPSHOT_FILE:-}" ]; then
    {
      printf 'version=%s\n' "$FM_OPEN_DECISIONS_FOLD_VERSION"
      printf 'offset=%s\n' "$offset"
      printf 'ident=%s\n' "$cur_ident"
      if [ -n "$open" ]; then printf '%s' "$open"; fi
    } > "$FM_STATUS_CURSOR_SNAPSHOT_FILE" || return 1
  fi
  printf '%s' "$offset"
}

# Print every non-blank status line whose bytes begin at or after the persisted
# presentation offset. Does not write the cursor. A missing manifest row or
# changed status identity reads the current file from offset 0; malformed or
# unreadable cursor state fails the scan. Symlinks and unreadable status files
# print nothing.
status_new_lines_since_cursor() {  # <status-file> [<captured-end-offset>]
  local f=$1 captured_end=${2:-} cf offset size actual_size chunk_file line rc=0
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  cf=$(_fm_open_decisions_cursor_path "$f")
  chunk_file="$cf.unread.$$"
  offset=$(status_presentation_cursor_offset "$f") || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  actual_size=$(_fm_status_file_size "$f") || return 1
  actual_size=${actual_size//[[:space:]]/}
  case "$actual_size" in ''|*[!0-9]*) return 1 ;; esac
  if [ -n "$captured_end" ]; then
    case "$captured_end" in ''|*[!0-9]*) return 1 ;; esac
    [ "$captured_end" -le "$actual_size" ] || return 1
    size=$captured_end
  else
    size=$actual_size
  fi
  [ "$offset" -lt "$size" ] || return 0
  _fm_status_read_span "$f" "$offset" "$((size - offset))" > "$chunk_file" 2>/dev/null \
    || { rm -f "$chunk_file"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *[![:space:]]*) printf '%s\n' "$line" || { rc=1; break; } ;;
    esac
  done < "$chunk_file"
  rm -f "$chunk_file"
  return "$rc"
}

# 0 when a status line is an informational `note:` or a reserved-key
# pending-reply resolution. Those lines never fold into OPEN DECISIONS, so the
# drain's unread-status surface is their only guaranteed presentation.
status_line_is_unread_surface() {  # <status-line>
  local line=$1 verb key note resolve held prefix
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = note ] && return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  case "$verb" in
    "$resolve"|"$held") ;;
    *) return 1 ;;
  esac
  key=$(_fm_decision_key "$line") || return 1
  note=$(status_line_note "$line")
  for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}; do
    case "$key" in
      "$prefix"*)
        _fm_decision_key_transition_allowed "$key" "$note"
        return
        ;;
    esac
  done
  return 1
}

# Fleet-wide unread informational lines: one "<task>\t<status-line>" row per
# still-unread `note:` or pending-reply resolution, in glob (task id) order.
# Prints nothing when none are unread. Directory scan rejects status symlinks
# the same way scan_open_decisions does.
scan_unread_surface_lines() {  # <state>
  local state=$1 f task lines line
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    lines=$(status_new_lines_since_cursor "$f") || return 1
    [ -n "$lines" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      status_line_is_unread_surface "$line" || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$lines
EOF
  done
  return 0
}

scan_unread_surface_snapshot() {  # <state> <task-and-endpoint-snapshot>
  local state=$1 snapshot=$2 task endpoint ident f lines line
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    f="$state/$task.status"
    lines=$(status_new_lines_since_cursor "$f" "$endpoint") || return 1
    [ -n "$lines" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      status_line_is_unread_surface "$line" || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$lines
EOF
  done <<EOF
$snapshot
EOF
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying that
# key closes the phase, because it has moved to a terminal or separately tracked
# state.
# A bare legacy event uses the default key, preserving one-phase behavior.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or fm-crew-state result.
_fm_status_open_activities_stream() {
  local line verb key note resolve held open='' pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    # Blank-line guard; see _fm_decision_fold_line for why this is a glob.
    case "$line" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# Capture the bytes of an append-only status log at or after <start-offset> under
# one size-and-identity snapshot.
# The record form prints `<endpoint>\t<identity>\t<events>` and returns 0 when
# the span has actionable events, joining every such event in source order with
# ` ; ` so callers report the complete captured span before committing it.
# It returns 1 after a successful classification with no actionable event; an
# existing log still prints its committable endpoint and identity, while an absent
# log is the ordinary empty case and prints no record.
# It returns 2 with no committable endpoint when an existing status object cannot
# be classified.
# The simpler wrapper prints only the event field, and the predicate discards the
# record; all three inherit the library-header contract above.
#
# A keyed `needs-decision` or `blocked` transition accepted by the whole-file
# fold is included only when that fold still names the exact opening as live.
# A transition rejected by the reserved-key vocabulary is surfaced instead as a
# reconciliation signal and never treated here as an open decision.
# status_open_decisions remains the single owner of open/closed semantics,
# including same-key reopening and reserved-key handling.
# Every other captain-relevant event is terminal and always actionable.
_fm_decision_origin_drop() {  # <origins> <key>
  local origin
  while IFS= read -r origin; do
    case "$origin" in "$2"$'\t'*) ;; *) [ -n "$origin" ] && printf '%s\n' "$origin" ;; esac
  done <<EOF
$1
EOF
}

_fm_status_open_decision_origins() {  # <status-file>
  local f=$1 line open='' after key verb note number=0 origins=''
  local resolve held
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    after=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held")
    key=$(_fm_decision_key "$line") || { open=$after; continue; }
    verb=$(status_line_verb "$line")
    note=$(status_line_note "$line")
    case "$verb" in
      needs-decision|blocked)
        if _fm_open_set_has "$after" "$key" \
          && [ "$(_fm_open_set_verb "$after" "$key")" = "$verb" ]; then
          case "$after" in
            "$key"$'\t'"$verb"$'\t'"$note"|*$'\n'"$key"$'\t'"$verb"$'\t'"$note")
              origins=$(_fm_decision_origin_drop "$origins" "$key")
              [ -n "$origins" ] && origins="${origins}"$'\n'
              origins="${origins}${key}"$'\t'"${number}"
              ;;
          esac
        fi
        ;;
      "$resolve"|"$held")
        _fm_open_set_has "$after" "$key" || origins=$(_fm_decision_origin_drop "$origins" "$key")
        ;;
    esac
    open=$after
  done < "$f"
  printf '%s' "$origins"
}

status_span_first_actionable_record() {  # <status-file> <start-offset>
  local f=$1 start=${2:-0} size ident cur_ident scratch chunk_file full_file prefix_file
  local line verb key origins='' folded=0 rc=1 failed=0 prefix_lines=0 line_number=0 live_line='' events='' _line _key
  [ -e "$f" ] || { [ -L "$f" ] && return 2; return 1; }
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 2
  ident=$(_fm_open_decisions_file_ident "$f") || return 2
  size=$(_fm_status_file_size "$f") || return 2
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 2 ;; esac
  case "$start" in ''|*[!0-9]*) start=0 ;; esac
  [ "$start" -le "$size" ] || start=0
  [ "$start" -lt "$size" ] || { printf '%s\t%s' "$size" "$ident"; return 1; }
  scratch=$(_fm_status_span_scratch "$f") || return 2
  chunk_file="${scratch}.span"; full_file="${scratch}.full"; prefix_file="${scratch}.prefix"
  _fm_status_read_span "$f" "$start" "$((size - start))" > "$chunk_file" 2>/dev/null \
    || { rm -f "$chunk_file" "$full_file" "$prefix_file"; return 2; }
  cur_ident=$(_fm_open_decisions_file_ident "$f") || {
    rm -f "$chunk_file" "$full_file" "$prefix_file"; return 2;
  }
  [ "$cur_ident" = "$ident" ] || { rm -f "$chunk_file" "$full_file" "$prefix_file"; return 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    status_is_captain_relevant "$line" || continue
    verb=$(status_line_verb "$line")
    case "$verb" in
      needs-decision|blocked)
        key=$(_fm_decision_key "$line") || {
          [ -n "$events" ] && events="${events} ; "
          events="${events}${line}"
          rc=0
          continue
        }
        _fm_decision_key_transition_allowed "$key" "$(status_line_note "$line")" || {
          [ -n "$events" ] && events="${events} ; "
          events="${events}reconciliation-required: ${line}"
          rc=0
          continue
        }
        if [ "$folded" -eq 0 ]; then
          _fm_status_read_span "$f" 0 "$size" > "$full_file" 2>/dev/null \
            || { failed=1; break; }
          if [ "$start" -gt 0 ]; then
            _fm_status_read_span "$full_file" 0 "$start" > "$prefix_file" 2>/dev/null \
              || { failed=1; break; }
            while IFS= read -r _line || [ -n "$_line" ]; do prefix_lines=$((prefix_lines + 1)); done < "$prefix_file"
          fi
          origins=$(_fm_status_open_decision_origins "$full_file") || { failed=1; break; }
          folded=1
        fi
        live_line=$(while IFS=$(printf '\t') read -r _key _line; do
          [ "$_key" = "$key" ] && { printf '%s' "$_line"; break; }
        done <<EOF
$origins
EOF
)
        [ -n "$live_line" ] && [ "$((prefix_lines + line_number))" -eq "$live_line" ] || continue
        [ -n "$events" ] && events="${events} ; "
        events="${events}${line}"
        rc=0
        ;;
      *)
        [ -n "$events" ] && events="${events} ; "
        events="${events}${line}"
        rc=0
        ;;
    esac
  done < "$chunk_file"
  rm -f "$chunk_file" "$full_file" "$prefix_file"
  [ "$failed" -eq 0 ] || return 2
  if [ "$rc" -eq 0 ]; then printf '%s\t%s\t%s' "$size" "$ident" "$events"; else printf '%s\t%s' "$size" "$ident"; fi
  return "$rc"
}

status_span_first_actionable() {  # <status-file> <start-offset>
  local record rc rest
  record=$(status_span_first_actionable_record "$1" "${2:-0}")
  rc=$?
  if [ "$rc" -eq 0 ]; then
    rest=${record#*$'\t'}
    printf '%s' "${rest#*$'\t'}"
  fi
  return "$rc"
}

status_span_has_actionable() {  # <status-file> <start-offset>
  status_span_first_actionable_record "$1" "${2:-0}" > /dev/null
}

# Hard-timeout mechanism shared by fm-crew-state.sh's own no-mistakes bound and
# the outer crew-state-read bound below. Detected once at source time. Plain
# `timeout N cmd` (no -k/--kill-after) is only ADVISORY once N elapses: it sends
# the initial signal but never force-kills a command that ignores or is stuck
# past it - e.g. a CLI blocked on a slow/queued daemon RPC under concurrent
# validation load, the exact failure mode behind the 2026-07-09 89-minute
# watcher stall (crew_is_provably_working -> fm-crew-state.sh -> `no-mistakes
# axi status` never returned, so the watcher's poll loop, and therefore its
# liveness beacon touch, never came back around). The perl fallback (no
# timeout/gtimeout on PATH) already force-kills a whole process group, so it
# needs no separate -k equivalent, just the same kill-after grace parameter.
_FM_HARD_TIMEOUT_BIN=none
if command -v timeout >/dev/null 2>&1; then _FM_HARD_TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then _FM_HARD_TIMEOUT_BIN=gtimeout
elif command -v perl >/dev/null 2>&1; then _FM_HARD_TIMEOUT_BIN=perl
fi

# fm_sanitize_timeout_bound <value> <default>
# Validates a positive-integer fm_hard_timeout bound, falling back to
# <default> for anything empty, non-numeric, or all-zero digits ("0", "00",
# "000", ...) - GNU `timeout` treats ANY all-zero duration spelling as "no
# timeout" (`timeout -k 1 00 sleep 5` runs the full 5s, identical to a literal
# 0), which would silently defeat the hard-timeout guarantee every caller of
# this sanitizer relies on.
fm_sanitize_timeout_bound() {
  local v=$1 default=$2
  case "$v" in
    ''|*[!0-9]*) v=$default ;;
    *[1-9]*) ;;
    *) v=$default ;;
  esac
  printf '%s' "$v"
}

# fm_hard_timeout <secs> <kill-after-secs> <cmd> [args...]
# Runs <cmd> bounded to <secs>, GUARANTEEING it is gone by <secs>+<kill-after-secs>:
# still alive that long after the initial signal means a SIGKILL, not just another
# SIGTERM. Prints <cmd>'s stdout. Exit reflects <cmd>'s own code, or the forced-kill
# wrapper's own (124) when it had to intervene. With no bounding tool on PATH at
# all, refuses outright (124) rather than risk an unbounded call.
fm_hard_timeout() {
  local secs=$1 kill_after=$2
  shift 2
  case "$_FM_HARD_TIMEOUT_BIN" in
    timeout)  timeout -k "$kill_after" "$secs" "$@" ;;
    gtimeout) gtimeout -k "$kill_after" "$secs" "$@" ;;
    perl)
      # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
      perl -e 'my ($t, $k) = (shift, shift); my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, $k; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$secs" "$kill_after" "$@"
      ;;
    *) return 124 ;;
  esac
}

# Outer bound wrapping the ENTIRE fm-crew-state.sh read below - defense in depth
# alongside that script's OWN internal per-call no-mistakes bound
# (FM_CREW_STATE_NM_TIMEOUT/FM_CREW_STATE_NM_KILL_AFTER). fm-crew-state.sh can
# make several sequential no-mistakes calls in one read (axi status, the
# cross-branch runs fallback, a ci log tail), so this stays comfortably above
# their worst-case legitimate total, while still guaranteeing the watcher's own
# poll loop - and therefore its liveness beacon - can never block on this read
# past a fixed ceiling, even if some future call site inside fm-crew-state.sh
# forgets to route a no-mistakes call through its own bound.
# Named so the bounds survive being unset after this library was sourced: every
# consumer below reads them with these as the fallback, so a caller that clears
# the override still gets the sanitized default instead of tripping `set -u`.
FM_CREW_ABSORB_TIMEOUT_DEFAULT=45
FM_CREW_ABSORB_KILL_AFTER_DEFAULT=5
FM_CREW_ABSORB_TIMEOUT=$(fm_sanitize_timeout_bound "${FM_CREW_ABSORB_TIMEOUT:-$FM_CREW_ABSORB_TIMEOUT_DEFAULT}" "$FM_CREW_ABSORB_TIMEOUT_DEFAULT")
FM_CREW_ABSORB_KILL_AFTER=$(fm_sanitize_timeout_bound "${FM_CREW_ABSORB_KILL_AFTER:-$FM_CREW_ABSORB_KILL_AFTER_DEFAULT}" "$FM_CREW_ABSORB_KILL_AFTER_DEFAULT")

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/failed/torn-down/
#             unknown crew, a parked crew missing the declared-pause-plus-open-decision
#             pair, or an unreadable verdict) - INCLUDING a
#             fm-crew-state.sh read that hit the hard timeout above: a timed-out
#             read must never read as working, or a genuinely wedged crew behind
#             a hung no-mistakes call would be absorbed instead of surfaced.
# One fm-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused -
# EXCEPT for the two run-step overrides below, which fire only for a task whose
# own last status line is a declared paused:.
#
# Parked-at-gate override: fm-crew-state.sh's cross-branch run lookup falls back
# to a coarse `no-mistakes runs` listing when the primary `axi status` call does
# not attribute a run to this crew's own branch, and that coarse listing carries
# no per-step gate detail - so a run genuinely PARKED at a needs-decision/blocked
# gate can be reported as a plain `working · source: run-step` forever, even
# though the pipeline cannot move without the captain. status_open_decisions
# (above) reading this task's own status log is the proof that a gate is
# genuinely still open: when one is, the declared pause wins outright,
# regardless of backend liveness, because an alive-but-gated crew is exactly as
# unable to progress as a dead one.
#
# Exited-crewmate override: a no-mistakes run whose crewmate has since exited
# (the harness process quit) can separately be left with an orphaned running/ci
# run-step that was never cancelled - e.g. a stale in-progress CI poll - so
# fm-crew-state.sh keeps reporting `working · source: run-step` forever, even
# though nothing is actually advancing that run anymore. This is a DIFFERENT
# case from the gate override above: no decision is open, but the crew that
# could have resumed the run itself is confirmed gone. Confirmed via
# fm_backend_agent_alive (bin/fm-backend.sh) reading the same meta the
# secondmate-liveness sweep uses, and acted on ONLY for its confident `dead`
# verdict - `alive`/`unknown` fall through to the ordinary working
# classification, so a live crewmate whose run-step is genuinely still
# progressing (ci/running/fixing) with a stray paused: line left over from
# earlier is unaffected: only a still-open gate or a confirmed-dead crewmate
# overrides run-step precedence, never a live, ungated, merely-stale pause.
#
# Finished-but-declared-pause override: a task can reach a terminal `done`
# verdict (its no-mistakes run passed/checks-passed) and still be deliberately
# idling afterward - most commonly the independent review a ship task awaits
# before merge (AGENTS.md section 7, bin/fm-ultracode-guard.sh). Unlike the two
# run-step overrides above, this needs no gate/liveness check: a `done` crew
# state already means nothing is running, so a declared pause on top of it is
# never contradicted by an active pipeline the way a stray pause under
# `working` might be. Without this, a done task's own paused: line is invisible
# here and falls straight to `none`, so the watcher's pause_state_class
# (bin/fm-watch.sh) never latches a `paused` verdict and its non-paused
# fallback re-surfaces the identical stale hash on every single poll forever. A
# done task with NO declared pause is unaffected: status_is_paused is false for
# a plain done:/failed:/etc. last line, so it still falls through to `none` and
# surfaces immediately, exactly as before.
#
# Parked-state override: a run genuinely PARKED at a gate (fm-crew-state.sh's
# own `state: parked`, not the run-step fallback above) still fell straight to
# `none` because neither the working nor the done branch matches it, so the
# watcher re-surfaced the identical stale hash on every poll for as long as the
# captain's decision was outstanding (regression: scaffold-returns-readme-currency,
# falsework-cos-deliver-to-a-human). Fixed with the SAME two-signal bar as the
# run-step gate override above, not the single-signal done bar: require BOTH a
# declared paused: line AND a still-open keyed decision. A parked state means
# the pipeline is stopped by construction, but that alone does not prove the
# wait is a deliberate, expected one - a worker can be parked because it is
# genuinely wedged with no decision pending, and the open decision is the
# machine-checked proof the wait is real rather than inferred from prose. Two
# signals were considered: the open decision alone (broader - covers a worker
# that parks correctly but forgets to append a pause line), or both signals
# together (narrower - matches the existing run-step override exactly). Chosen:
# both signals, because the whole point of this classifier is catching a
# genuinely stuck worker, and a bare open-decision-only bar would make a wedged
# parked run with a stray leftover decision indistinguishable from a healthy
# one. A parked run with NEITHER signal - or only one - is unaffected: it falls
# through to `none` and surfaces immediately, exactly as before.
#
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so callers
# run it only on no-verb signal and first-sighting stale paths, never every wake.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src state_dir last statusf meta backend target verdict
  [ -n "$id" ] || { printf 'none'; return; }
  line=$(fm_hard_timeout "${FM_CREW_ABSORB_TIMEOUT:-$FM_CREW_ABSORB_TIMEOUT_DEFAULT}" \
         "${FM_CREW_ABSORB_KILL_AFTER:-$FM_CREW_ABSORB_KILL_AFTER_DEFAULT}" \
         "$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in
      run-step)
        state_dir=${STATE:-${FM_STATE_OVERRIDE:-}}
        if [ -n "$state_dir" ]; then
          statusf="$state_dir/$id.status"
          last=$(last_status_line "$statusf")
          if status_is_paused "$last"; then
            if [ -n "$(status_open_decisions "$statusf")" ]; then
              printf 'paused'; return
            fi
            meta="$state_dir/$id.meta"
            backend=$(fm_backend_of_meta "$meta")
            target=$(fm_backend_target_of_meta "$meta")
            if [ -n "$target" ]; then
              verdict=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null) || verdict=unknown
              [ "$verdict" = dead ] && { printf 'paused'; return; }
            fi
          fi
        fi
        printf 'working'; return
        ;;
      pane) printf 'working'; return ;;
    esac
  fi
  if [ "$state" = "done" ]; then
    state_dir=${STATE:-${FM_STATE_OVERRIDE:-}}
    if [ -n "$state_dir" ]; then
      last=$(last_status_line "$state_dir/$id.status")
      status_is_paused "$last" && { printf 'paused'; return; }
    fi
  fi
  if [ "$state" = "parked" ]; then
    state_dir=${STATE:-${FM_STATE_OVERRIDE:-}}
    if [ -n "$state_dir" ]; then
      statusf="$state_dir/$id.status"
      last=$(last_status_line "$statusf")
      if status_is_paused "$last" && [ -n "$(status_open_decisions "$statusf")" ]; then
        printf 'paused'; return
      fi
    fi
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-on-positive-evidence. This is the sole proof for stale wakes and the
# shared authoritative proof for no-verb signals. Where a home opts in, fm-watch.sh
# may additionally absorb a bare turn-end on bounded pane churn, while every other
# failed verdict surfaces
# because the crew may be done, waiting on a decision, or wedged. For stale panes
# it is checked before trusting the status log so a pre-validation captain-relevant
# line does not override an active run. See crew_absorb_class for the exact
# working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# --- run-aware wedge deferral -----------------------------------------------
#
# How long an attributed run may show NO structural progress before its stale
# pane escalates as a possible wedge. This is the wedge threshold for a
# validating crew, replacing the pane-idleness one (FM_STALE_ESCALATE_SECS,
# default 240s) that a backgrounded run makes meaningless.
#
# Why it is this much larger: a crew that handed off to a no-mistakes run is
# idle BY DESIGN - it is waiting to be notified - so its pane tells us nothing,
# and single pipeline steps legitimately run for tens of minutes (measured on
# this repo's own recorded runs: review 25.8min, lint 33.8min, test 38.9min).
# A 240s pane timer therefore fires many times inside one healthy step, which is
# exactly the false alarm this exists to stop. The default clears the longest
# step observed here with better than 2x headroom.
#
# It is a CEILING, not a suppression: a run that has not moved for the whole
# window still escalates, and the marker below is re-stamped on escalation so it
# keeps re-escalating once per window rather than falling silent.
FM_RUN_WEDGE_SECS_DEFAULT=5400

# 0 (defer the wedge alarm) if crew <id> has an attributed validation run whose
# idle pane is EXPECTED - one that is structurally advancing, or one that has
# finished successfully and is awaiting merge; 1 (escalate now) otherwise. The
# ONE owner of this policy: bin/fm-watch.sh's wedge_timer_check and
# bin/fm-supervise-daemon.sh's housekeeping stale recheck both gate their
# "possible wedge" escalation on this single call, so the always-on and away-mode
# supervisors cannot drift apart.
#
# What it catches and what it does not, stated plainly:
#   - A run moving through steps, or landing pipeline fix commits, renews its
#     token and never escalates. That is the reported false alarm, gone.
#   - A finished run awaiting merge (done / checks green / PR ready) defers too,
#     including after its worker exited: that worker is done by design and the
#     merge poll watches for the landing. It still re-surfaces once per window
#     rather than every FM_STALE_ESCALATE_SECS, so an unmerged PR cannot rot.
#   - A run frozen on one step with no new commits for FM_RUN_WEDGE_SECS DOES
#     escalate. That is the genuinely wedged pipeline, still surfaced.
#   - A run PARKED at a gate, or failed, never defers: those need firstmate.
#   - A crew with no attributed run is untouched: this returns 1 immediately and
#     the caller's existing pane timer applies exactly as before.
#   - A confidently dead agent escalates immediately while a run is still
#     supposed to be advancing, so a crashed harness is not hidden behind a long
#     ceiling merely because a run-step was left running.
#   - A legitimately unbounded external wait (a ci step monitoring a slow PR)
#     will eventually escalate once per window. It errs toward one extra alarm
#     rather than toward silence, which is the direction this must fail in.
# Every failure mode here - an unreadable token, a timed-out read, a missing
# state dir - returns 1 and escalates, so nothing new can silence a wedge.
#
# NOT a pure read: it runs fm-crew-state.sh under the same hard bound as
# crew_absorb_class, so it can never hang a supervisor's poll loop. Callers run
# it only when a wedge is about to fire (once per window per stale task), never
# per wake.
crew_run_progress_defers_wedge() {  # <id> [<state-dir>]
  local id=$1 state_dir=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}}
  local out token phase marker rec_epoch='' rec_token='' now ceiling meta backend target verdict
  [ -n "$id" ] || return 1
  [ -n "$state_dir" ] || return 1

  out=$(fm_hard_timeout "${FM_CREW_ABSORB_TIMEOUT:-$FM_CREW_ABSORB_TIMEOUT_DEFAULT}" \
        "${FM_CREW_ABSORB_KILL_AFTER:-$FM_CREW_ABSORB_KILL_AFTER_DEFAULT}" \
        "$FM_CREW_STATE_BIN" --run-progress "$id" 2>/dev/null) || return 1
  # Fail closed on anything that is not an explicit progress token, including an
  # older reader that does not know the flag and echoes a state line instead.
  case "$out" in progress:*) token=${out#progress: } ;; *) return 1 ;; esac
  token=${token%%$'\n'*}
  [ -n "$token" ] && [ "$token" != none ] || return 1
  phase=${token%%/*}
  token=${token#*/}
  [ -n "$token" ] && [ "$token" != "$phase" ] || return 1

  # Only two phases make an idle pane expected. Everything else - a run parked at
  # a gate waiting on firstmate, a failed run, an unreadable verdict - is exactly
  # what the alarm is for, so it escalates.
  #   working: the pipeline is advancing behind an idle pane (below).
  #   done:    a terminal-SUCCESS run awaiting merge. The worker is finished and
  #            idle by design, and the merge poll is what watches for the landing,
  #            so re-nagging its pane every FM_STALE_ESCALATE_SECS is pure noise
  #            for as long as the PR stays open.
  case "$phase" in working|done) ;; *) return 1 ;; esac

  # A confirmed-dead agent means nothing is driving this run, whatever its
  # run-step still claims; escalate at the caller's own cadence instead of
  # deferring. alive/unknown fall through, so an ambiguous read never suppresses.
  # NOT applied to a finished run: a worker that reported done and exited is in
  # its expected end state, and treating that as a dead-agent wedge is precisely
  # the every-few-minutes false alarm this case exists to stop.
  if [ "$phase" != 'done' ]; then
    meta="$state_dir/$id.meta"
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if [ -n "$target" ]; then
      verdict=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null) || verdict=unknown
      [ "$verdict" = dead ] && return 1
    fi
  fi

  marker="$state_dir/.run-progress-$id"
  now=$(date +%s)
  [ -f "$marker" ] && IFS=$'\t' read -r rec_epoch rec_token < "$marker"
  case "$rec_epoch" in ''|*[!0-9]*) rec_epoch='' ;; esac
  # First sighting, or the run moved: stamp progress as of NOW and defer.
  if [ -z "$rec_epoch" ] || [ "$rec_token" != "$token" ]; then
    printf '%s\t%s\n' "$now" "$token" > "$marker"
    return 0
  fi
  # 0 is a legitimate ceiling (escalate at the caller's own threshold, no
  # deferral); only an unparseable value falls back to the default.
  case "${FM_RUN_WEDGE_SECS:-}" in
    ''|*[!0-9]*) ceiling=$FM_RUN_WEDGE_SECS_DEFAULT ;;
    *) ceiling=$FM_RUN_WEDGE_SECS ;;
  esac
  if [ $(( now - rec_epoch )) -ge "$ceiling" ]; then
    # Re-stamp so the NEXT escalation is a full window away rather than every
    # poll from here on - a wedged run must nag once per window, not constantly.
    printf '%s\t%s\n' "$now" "$token" > "$marker"
    return 1
  fi
  return 0
}

# Directories excluded from the worktree write probe below, and the depth it walks.
# The excluded set is everything a supervisor read or a package manager can write
# without the crew doing any work - .git first, so firstmate's own read-only git
# commands against the worktree can never make the probe self-fulfilling - plus the
# large generated trees that would make the walk expensive. Both are overridable so
# a home with an unusual layout can widen or narrow the probe. The list is a skip
# list, so clearing it skips nothing and widens the walk to the whole depth-bounded
# tree; it never disables the probe, which would quietly cost the wedge detector a
# liveness input on a home that meant to widen it. Defaulted with the plain form so
# an explicitly empty value stays empty: clearing the knob in the environment is the
# documented way to ask for that wider walk, and treating empty as unset would hand
# the default skip list back to exactly the home that asked for more coverage.
FM_WORKTREE_WRITE_PRUNE=${FM_WORKTREE_WRITE_PRUNE-'.git node_modules .venv venv __pycache__ .mypy_cache .pytest_cache .ruff_cache .tox target dist build .next .cache vendor'}
FM_WORKTREE_WRITE_MAXDEPTH=${FM_WORKTREE_WRITE_MAXDEPTH:-6}

# Wall-clock seconds the probe's single walk may take. The walk runs synchronously
# inside the caller's poll loop at the exact moment an escalation would otherwise
# fire, and -xdev keeps it out of a nested mount but cannot help when the worktree
# root ITSELF sits on a hung network or container mount; unbounded, such a walk
# would wedge the very supervisor that exists to notice a wedge, stalling its
# heartbeat instead of escalating. Hitting the bound is a negative outcome like
# every other: it reads as no evidence, so the caller's escalation schedule is
# untouched and a stall that writes nothing still escalates on the existing
# schedule. A value that is not a positive integer is not a bound at all (`timeout
# 0` and the perl fallback's `alarm 0` both disable the deadline), so the default
# applies instead; the check lives at the point of use so an in-process override
# gets it too.
FM_WORKTREE_WRITE_TIMEOUT=${FM_WORKTREE_WRITE_TIMEOUT:-10}

# 0 when some regular file under <id>'s recorded worktree is newer than
# <anchor-file>: positive evidence the crew is still producing work even though its
# rendered pane has gone quiet. This is the third liveness input the wedge detector
# has, after pane quietness and the run step, and it exists because neither of
# those can see a crew that is writing source, then tests, then documentation
# behind a static pane - the 2026-08-14 case of eight consecutive possible-wedge
# escalations against a crew that was demonstrably working the whole time.
#
# 1 for every other outcome, including an id with no recorded worktree, a worktree
# that is gone, a missing anchor, and a walk that fails or finds nothing. Absence of
# evidence therefore always leaves the caller's existing escalation schedule
# untouched, so a crew that writes nothing still escalates exactly as before.
#
# A kind=secondmate task records a provisioned firstmate home, not a code tree, and
# such a home runs its OWN supervision inside it: its state/ directory churns a
# watcher beacon, pane hashes, and heartbeats whether or not the mate is producing
# anything, so a walk there would report liveness for a mate that has done nothing.
# Those homes are excluded outright rather than by pruning "state", which would also
# hide a legitimate source directory of that name in an ordinary worktree. The
# exclusion is a negative outcome like any other, so an unproductive mate keeps
# escalating on the caller's unchanged schedule.
#
# The anchor is the caller's own idle-window timer file, whose mtime already marks
# when the quiet window opened, so `-newer` needs no clock arithmetic, no temp
# file, and no portable mtime-setting. Not a pure status-file read (see the header):
# one pruned, depth-bounded, wall-clock-bounded walk per call, which callers must
# reach only when they are otherwise about to escalate, never on every poll. A walk
# that outlives FM_WORKTREE_WRITE_TIMEOUT is killed and reported as no evidence, so
# a hung mount costs the escalation nothing but the bound. -xdev holds that walk to the
# worktree's own filesystem rather than descending into a nested network or container
# mount, so a write that lands only under such a mount is one more negative outcome.
crew_worktree_written_since() {  # <id> <state> <anchor-file>
  local id=$1 state=$2 anchor=$3 wt kind name hit bound
  local -a names=() prune=()
  [ -n "$id" ] || return 1
  [ -f "$anchor" ] || return 1
  wt=$(grep '^worktree=' "$state/$id.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  kind=$(grep '^kind=' "$state/$id.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ "$kind" != secondmate ] || return 1
  if [ -e "$wt/.fm-secondmate-home" ] || [ -L "$wt/.fm-secondmate-home" ]; then
    return 1
  fi
  read -r -a names <<< "$FM_WORKTREE_WRITE_PRUNE"
  for name in ${names[@]+"${names[@]}"}; do
    [ "${#prune[@]}" -eq 0 ] || prune+=( -o )
    prune+=( -name "$name" )
  done
  bound=$FM_WORKTREE_WRITE_TIMEOUT
  case "$bound" in ''|*[!0-9]*|0) bound=10 ;; esac
  if [ "${#prune[@]}" -gt 0 ]; then
    hit=$(fm_run_timed "$bound" find "$wt" -xdev -maxdepth "$FM_WORKTREE_WRITE_MAXDEPTH" \
      \( "${prune[@]}" \) -prune -o -type f -newer "$anchor" -print -quit 2>/dev/null || true)
  else
    hit=$(fm_run_timed "$bound" find "$wt" -xdev -maxdepth "$FM_WORKTREE_WRITE_MAXDEPTH" \
      -type f -newer "$anchor" -print -quit 2>/dev/null || true)
  fi
  [ -n "$hit" ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list the caller classified with the span read above.
# Files are mapped to task ids by stripping the .status / .turn-ended suffix;
# a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
# A kind=secondmate task's .status signal is never absorbable here regardless of
# busy evidence: that stream is the mate's routed-reply channel, so every append
# is parent-directed content the supervisor must read (a routed reply, a newly
# raised decision, a mirrored remote line), and a busy mate agent makes its note
# more current, not less deliverable. Scoped to .status files - a mate's bare
# turn-ended ping still uses the ordinary provably-working absorb.
signal_crew_provably_working() {  # <file> ...
  local f base dir task seen=""
  for f in "$@"; do
    base=${f##*/}
    dir=${f%/*}
    [ "$dir" != "$f" ] || dir=.
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case "$base" in
      *.status)
        if [ "$(grep '^kind=' "$dir/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2-)" = secondmate ]; then
          return 1
        fi
        ;;
    esac
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}
