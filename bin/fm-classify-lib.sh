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
#
# There are three documented exceptions. The absorb classification
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

# Bounded re-surface cadence for a declared pause or a dead-agent captain hold.
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
# fm-decision-hold.sh has verified the corresponding captain-held backlog item.
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

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave an exited crew's endpoint idle, so
# the watcher applies its bounded pause cadence when agent death confirms that
# no live decision gate is being silenced.
status_is_paused_or_captain_held() {  # <status-line>
  local line=$1 verb
  status_is_paused "$line" && return 0
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
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
status_line_verb() {  # <status-line> -> leading verb word
  local v
  _fm_status_strip_timestamp "$1"
  v=${_FM_STATUS_NORMALIZED%%:*}
  v=${v%%\[*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
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
  local open=$1 line=$2 resolve=$3 held=$4 verb key note stripped
  stripped=${line//[[:space:]]/}
  [ -n "$stripped" ] || { printf '%s' "$open"; return 0; }
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

FM_OPEN_DECISIONS_FOLD_VERSION=4

# Portable device:inode identity for the rotation/recreation check below.
_fm_open_decisions_file_ident() {  # <file> -> "dev:inode", empty on I/O failure
  local f=$1
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -f '%d:%i' "$f" 2>/dev/null
  else
    LC_ALL=C stat -c '%d:%i' "$f" 2>/dev/null
  fi
}

_fm_status_file_size() {  # <status-file>
  local f=$1
  if [ -n "${FM_STATUS_SIZE_READER:-}" ]; then
    "$FM_STATUS_SIZE_READER" "$f"
    return
  fi
  LC_ALL=C wc -c < "$f" 2>/dev/null
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

status_retire_presentation_task() {  # <state> <task-id>
  local state=$1 task=$2 lock manifest tmp data row_task ident offset extra rc=0 found=0
  lock="$state/.status-presentation-lock"
  manifest="$state/.status-presentation-cursor"
  tmp="$manifest.tmp.$$"

  # A remote-home teardown can legitimately retire an endpoint ID that has no
  # status log in that home. Do not contend with that home's unrelated status
  # presenter in this no-op case. A concurrent presenter cannot add this task
  # without its status file, so a valid manifest with no matching row is a
  # durable proof that there is nothing to retire.
  if [ ! -e "$state/$task.status" ] && [ ! -L "$state/$task.status" ] \
    && [ ! -e "$state/.$task.open-decisions-cursor" ] \
    && [ ! -L "$state/.$task.open-decisions-cursor" ]; then
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
    rm -f -- "$state/$task.status" "$state/.$task.open-decisions-cursor" || rc=1
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
  local line verb key note resolve held open='' stripped pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
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

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
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
# absorb-only-when-provably-working: a no-verb turn-end or stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). For stale panes it is checked before trusting the
# status log so a pre-validation captain-relevant line does not override an active
# run. See crew_absorb_class for the exact working/paused/none decision.
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

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
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

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
