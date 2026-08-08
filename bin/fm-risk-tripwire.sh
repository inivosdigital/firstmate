#!/usr/bin/env bash
# Mechanical risk trip-wire (guardrail #2): greps a task's brief text and, once
# code exists, its changed file paths for migration/auth/schema/security
# signals - a second, structurally different check from the natural-language
# "when" match a crew-dispatch rule already made, so a misclassified risky task
# cannot slip to a cheap model/effort tier on a single judgment call
# (data/research-resource-tiering-synthesis.md).
#
# Usage: fm-risk-tripwire.sh <task-id>
#
# Checks whatever is available for <task-id>:
#   - data/<task-id>/brief.md, if it exists (works before spawn, right after
#     bin/fm-brief.sh scaffolds it - the first checkpoint)
#   - the worktree's changed file paths vs its project's default branch, if
#     state/<task-id>.meta records worktree=/project= (works after spawn, at
#     Validate time - the second, binding checkpoint against the real diff)
# Exit codes:
#   0  no risk signal found
#   1  a RISK hit fired (one "RISK: <reason>" line per hit is printed)
#   2  could not check: a malformed invocation, neither a brief nor a usable
#      worktree/project exists yet (nothing to check), the worktree/project
#      exist but their diff base could not be resolved, or the diff base
#      resolved but the diff command itself failed (a bad ref, a corrupt
#      object, or any other git error), so the binding diff checkpoint could
#      not run (warned to stderr, never a silent clean pass)
# Distinct codes matter so a caller branching on $? cannot mistake a malformed
# invocation for a real risk hit. A hit means: floor this task's model/effort to
# the safety-critical profile (opus/xhigh, ultracode independent-review)
# regardless of which rule the natural-language dispatch match picked, per
# AGENTS.md section 4's risk floor.
#
# This is a coarse, unpushed-diff-vs-default-branch name-only comparison, not
# the PR-aware exact diff bin/fm-review-diff.sh computes - good enough for a
# keyword scan, not a substitute for that script's authoritative base.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"

usage() {
  echo "usage: fm-risk-tripwire.sh <task-id>" >&2
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

ID=${1:-}
[ -n "$ID" ] || { usage; exit 2; }
[ $# -le 1 ] || { usage; exit 2; }

# Case-insensitive, word-bounded match against the brief's prose, tolerating the
# inflections and affixes real task phrasing uses. Word bounding stops substring
# false positives like "auth" inside "authoritative", but three things must still
# reach the scan or a genuinely risky task slips to a cheap tier (the dangerous
# direction for a safety floor):
#   - verb forms need their own stems: appending the outer (s|ed|ing|ion|...)
#     suffix to a bare NOUN literal cannot reach the verb, so "migration" alone
#     could only become "migrations", never "migrate"/"migrating"/"migrated",
#     and the bare "auth" branch never reaches "authenticate".
#   - the un/re/de/pre prefixes ("unauthorized"/"unauthenticated" - the most
#     common access-control phrasing) glue a letter onto the stem's front, so
#     the auth stems carry an explicit prefix alternative. On the authoriz stem
#     that prefix is REQUIRED rather than optional, for the reason recorded
#     under "authoriz" below; on the authenticat stem it stays optional.
#   - a bare "auth"-anything stem is still avoided, so "authoritative"/"author"
#     stay shut.
# Word bounding is done by splitting the body into whole tokens (below), NOT by
# grep's \< / \> anchors: those are a GNU extension BSD grep does not honor, so
# on macOS they would silently match nothing and let every risky brief through -
# a false negative in the dangerous direction. Whole-token matching is identical
# on GNU and BSD grep and, unlike a boundary-consuming grep -o pattern, still
# reports BOTH words of an adjacent risk pair like "session token" (a consumed
# shared delimiter would drop the second).
#
# THE SAFETY DIRECTION IS NOT SYMMETRICAL. A missed real hit is far worse than a
# false one: a false hit costs an over-tiered task, a missed one lets safety-
# critical work run on a cheap model with no second check. So WIDENING the match
# set is cheap and needs little justification, while NARROWING it must be proven
# safe against the whole brief corpus, term by term, with the evidence recorded
# here. A term that cannot be proven safe to drop stays in.
#
# There are three classes, because the corpus showed that some words are risky
# on their own and some are risky only in company:
#   WORD_REGEX    single words that carry risk wherever they appear.
#   PHRASE_REGEX  multi-word risk terms that have no lone token to match.
#   PAIR_REGEX    AMBIGUOUS heads that carry risk only next to a qualifier.
#                 "session token" and "session cookie" name a credential; "this
#                 session" and "leading token" do not. The pair test is what
#                 keeps the first shape tripping without the second.
#
# ---------------------------------------------------------------------------
# The measured record behind this list. Every figure below was produced by
# running the brief half of this scan (no worktree, so the diff checkpoint never
# runs) over every data/<id>/brief.md this fleet had on disk on 2026-08-08 - 613
# briefs - and counting a brief as tripping when a RISK line is printed. The
# previous list tripped 358 of 613 (58.4%); this one trips 274 (44.7%), moving 91
# briefs to clean and 7 to tripping. Both directions are enumerated below.
#
# MOVED OUT OF WORD_REGEX AND INTO PAIR_REGEX. Each was read brief by brief, not
# sampled, over every brief whose verdict the move changes. Of the 91 briefs this
# list moves to clean, 39 tripped on session alone, 16 on token alone, 22 on the
# bare authoriz family alone, and the remaining 14 on two or more of the three:
#   - session/sessions. All 39 are a firstmate, tmux, browser,
#     chrome-devtools-axi, CAD, brainstorming or diagnostic session, or an
#     application's own domain object (scaffold-returns' "session create",
#     carscanner's "session state" walkup). Not one is an authentication
#     session. One of them is a recorded false fire whose own review brief says
#     the floor "flagged it for it mentions session state handling".
#   - token/tokens. All 16 are a parsing token ("the leading token", "any
#     2-letter token", "the colon-delimited token that matches the known verb
#     vocabulary") or an LLM token ("reasoning token gotchas", "200k tokens",
#     "image tokens are priced differently"). Not one is a credential.
#   - authoriz(e|ed|es|ing|ation|ations|er|ers) with no un/re/de/pre prefix.
#     All 22 are firstmate's APPROVAL sense, never access control: "the captain
#     authorized implementation", "a recommendation is evidence, not
#     authorization", "you are explicitly authorized to write throwaway
#     scripts", "this does not authorize building the feature". No scoping
#     rule reaches these, because approval language is ordinary background
#     prose rather than the constraint prose the narrowing below suppresses.
#     The prefixed forms stay in WORD_REGEX untouched:
#     "unauthorized"/"reauthorized" are never the approval sense.
#
# ADDED TO WORD_REGEX:
#   - cookie/cookies. Catches a labeling task whose whole risk surface is a
#     cookie carrying labeler identity across mutating routes, and which the
#     previous list missed outright. It is the ONLY brief of 613 that this term
#     newly matches: zero false fires corpus-wide.
#   - login. Newly trips 3 briefs: an account that "locks out after failed
#     login", a scrape blocked by "captcha, rate limiting, login walls", and one
#     healthcheck that "only hit GET /login". Two of three are real, the third
#     is cheap, and widening is the safe direction.
#   - authn/authz. The unambiguous abbreviations, which PATH_STRONG_REGEX below
#     already treats as strong signals while this list did not. With the bare
#     authoriz family moved to PAIR_REGEX, "add an authz check" needs authz to
#     stay caught by a single word. 0 briefs move; this closes a gap rather than
#     answering one the corpus raised.
#   - injection. Newly trips exactly 4 briefs and no brief goes clean. Three are
#     a real injection surface: quoting a launch string the memory wrapper is
#     prepended to, closing a control-character injection risk in a value being
#     written out, and CSV formula injection in an export. The fourth is a test
#     shim's own "injection patterns". Three of four real is the cheap trade
#     this file's asymmetry rule describes, so it is a standalone word rather
#     than a pair head. Note "inject" is deliberately NOT the term: it would
#     also catch away mode's own escalation injection vocabulary.
#
# ADDED TO PAIR_REGEX AS HEADS (added, but qualified rather than standalone,
# because as standalone words the corpus shows them firing mostly on non-risk):
#   - uid/uids. "uid guard" catches a uid-guard relocation task the previous
#     list missed outright. As a standalone word it would also have fired on an
#     IMAP "uid range", which is a message number, not a user.
#   - identity/identities. "identity gate" is the second signal in that same
#     labeling task. As a standalone word it would have fired on 6 more briefs,
#     all of them "shape identity", "byte identity", "job identity" or "a live
#     identity matched state" - none about access control.
#
# ADDED TO PAIR_REGEX AS QUALIFIERS:
#   - expire/expires/expired/expiring, logout/logouts, invalidate/invalidated/
#     invalidation. Session-expiry prose is the one realistic authentication
#     shape that carries no other term in this whole file: "expire the session
#     after an hour of inactivity" has no auth, cookie, login, credential,
#     password, secret, permission or access control anywhere in it, so without
#     these qualifiers it trips nothing at all. Measured cost is zero over the
#     616 briefs on disk when they were added: the same 271 trip before and
#     after with identical hit sets, and the only change is three
#     already-tripping briefs gaining "expire session", "expired token" and
#     "session invalidated". Qualifiers are monotonic - they
#     can only add a pair, never remove one - so lengthening this list can never
#     re-open anything the narrowing above closed.
#
# REJECTED, with the count of briefs each would newly trip and what they are.
# Every count below is measured over the 339 of those 613 briefs that the list at
# the head of this file leaves clean, which is the only baseline that answers
# "what would adding this cost me now":
#   - guard as a standalone word. It would newly trip 47 clean briefs, and they
#     are ordinary code guards: a negation guard, a timeout guard, an
#     idempotency guard, a digit guard, a packed-refs lock-race guard, and
#     firstmate's own tier and turn-end guards. Kept as a PAIR qualifier, where
#     "uid guard" trips and "turn-end guard" does not.
#   - root (67 clean briefs, every one a filesystem, worktree or repo root),
#     escalation (15, all firstmate's own model/effort escalation), hash (5, all
#     git hashes and hash maps). Ordinary engineering nouns with no auth sense
#     in this corpus.
#   - signature (4), exploit (3), sanitize (2), sudo (2), tls, pii, salt (1
#     each). Each is a handful of briefs with mixed senses, none of them a miss
#     anyone reported; both sudo briefs, for instance, are lab-machine benchmark
#     prose rather than a privilege-escalation surface. Left out to keep the
#     list defensible rather than long; add one the moment a brief needs it,
#     since widening is the cheap direction. injection was rejected here on an
#     undercount and has since been added above, which is that rule working.
#   - Removing the authoriz family outright instead of qualifying it. It would
#     have cost "add an authorization check" its only signal, and the corpus
#     does carry the access-control sense: SSH authorized_keys in two briefs,
#     "is authorization actually enforced on every path", an OAuth authorize
#     URL, "is the key still authorized".
#   - Narrowing PATH_STRONG_REGEX/PATH_WEAK_REGEX the same way. Left alone
#     deliberately: a path COMPONENT named session or token (lib/auth/session.rb)
#     is a far stronger signal than the same word in prose, the weak/strong split
#     below already handles firstmate's own bin/fm-session-start.sh, and every
#     false fire reported against this scanner was prose. cookie/cookies is added
#     there only to keep the path list in step with the new prose term.
#
# THE PAIR WINDOW. A qualifier counts when it sits within PAIR_WINDOW words of
# the head in the SAME clause, and 1 is not a guess:
#   - Strict adjacency (window 0) was measured first and drops real work prose.
#     "Authorize each request before the handler runs" and "Rotate the session
#     identifier whenever privileges change" both put the qualifier two words
#     out; both are pinned as must-trip cases in tests/fm-risk-tripwire.test.sh.
#   - Widening to a whole clause was measured too, and re-admits 41 briefs of
#     which every single one is a false fire: "guard ... session" (firstmate's
#     turn-end guard), "check ... session" (a check at session start), "session
#     session", "token token", "authorized ... check" (a captain-authorized beam
#     check). Not one genuine risk brief is among them.
#   - Window 1 costs exactly 2 of those 41 back and buys the verb-determiner-
#     object shape above, which is how ordinary English states the work.
# Clause scoping is free here because brief_scan_text emits one clause per line,
# so newlines are preserved for this scan (unlike the phrase stream, which is
# flattened) and a pair can never form across two clauses.
#
# WHAT THIS STILL MISSES, stated plainly for the same reason the narrowing's own
# gap is stated below. There are two shapes, and they fail for different reasons:
#   - A bare unqualified head, where the brief's only risk signal is "session",
#     "token" or "authorization" on its own: "the authorization is broken on the
#     admin page" no longer trips the prose scan.
#   - A head whose qualifier IS present but falls outside the window: "log the
#     user out after an hour of inactivity and clear the session" pairs nothing,
#     because "log ... out" is three tokens apart and "clear the session" has no
#     qualifier in range. This one has no cheap fix and should not get one -
#     widening the window is exactly what was measured above and rejected, since
#     a whole-clause window re-admits 41 briefs of which every one is a false
#     fire.
# That is the price of clearing 91 briefs' worth of firstmate's own everyday
# vocabulary. It is bounded by the diff checkpoint and by the qualifier list
# being cheap to widen, but NOT reliably by the rest of WORD_REGEX: session
# expiry prose genuinely carries no auth, cookie, login, credential, password,
# secret or permission, which is what made the expiry qualifiers necessary.
# ---------------------------------------------------------------------------
WORD_KEYWORDS='auth|authn|authz|authentication|(un|re|de|pre)authoriz(e|ed|es|ing|ation|ations|er|ers)?|(un|re|de|pre)?authenticat(e|ed|es|ing|ion|ions|or|ors)?|cookie|login|credential|password|secret|payment|billing|migrat(e|ed|es|ing|ion|ions)|schema|security|encrypt|decrypt|permission|injection'
WORD_REGEX="(${WORD_KEYWORDS})(s|es|ed|ing|ion|ions)?"
PHRASE_REGEX='(access[[:space:]]+control|data[[:space:]]+deletion|bulk[[:space:]]+mutation|public[[:space:]]+exposure|breaking[[:space:]]+change)(s|es|ed|ing|ion|ions)?'
# Ambiguous heads and the qualifiers that make them risk terms. A head also
# qualifies another head, because two ambiguous words together ("session token")
# are not ambiguous. The qualifier list is closed and drawn from the collocations
# the corpus actually carries plus standard authentication vocabulary; every
# entry only ever ADDS a hit, so lengthening it is the cheap direction and
# shortening it is what needs the evidence.
AMBIG_HEADS='sessions?|tokens?|uids?|identity|identities|authoriz(e|ed|es|ing|ation|ations|er|ers)?'
AMBIG_QUALIFIERS='auth|authn|authz|authenticat(e|ed|es|ing|ion|ions|or|ors)?|unauthenticated|unauthorized|login|logins|logged|signin|sso|oauth|jwt|saml|csrf|xsrf|bearer|refresh|access|api|invite|reset|pairing|rotat(e|ed|es|ing|ion)|revoke|revoked|revocation|expiry|expiration|cookie|cookies|credential|credentials|secret|secrets|password|passwords|key|keys|id|ids|identifier|identifiers|user|users|gate|gated|gating|guard|guards|check|checks|header|headers|middleware|endpoint|endpoints|route|routes|request|requests|role|roles|permission|permissions|privilege|privileges|policy|policies|bypass|enforce|enforced|enforcement|admin|hijack|hijacked|hijacking|fixation|spoof|spoofed|spoofing|store|provider|platform|expire|expires|expired|expiring|logout|logouts|invalidate|invalidated|invalidation'
PAIR_WINDOW=1

# Scan only the task-specific body of the brief (the # Task section up to the
# next scaffold section heading), never the fixed scaffold boilerplate
# bin/fm-brief.sh writes into every brief - that boilerplate contains benign
# words like "authoritative" and "future session" that would otherwise trip the
# wire on every task. The Herdr block bin/fm-brief.sh injects immediately after
# # Task (either the # Herdr isolation ... hard-safety contract, whose text is
# dense with "session"/"--session", or the # Herdr lifecycle declaration ...
# not-enabled stub) is scaffold boilerplate too, so its heading is a boundary as
# well; without it every --herdr-lab brief would trip on the contract's own
# "session" wording rather than the real task text. The section boundary is one
# of the scaffold's own known headings (# Herdr isolation .../# Herdr lifecycle
# declaration .../# Setup/# Rules/# Project memory/# Definition of done), not any
# column-0 "# " line: a shell/code comment embedded in the task body (e.g.
# "# then run the schema migration") must NOT end the scan, or the risk words
# after it are silently dropped - the dangerous direction for a safety floor.
# A boundary heading must also be blank-line-preceded, as every real scaffold
# heading is (bin/fm-brief.sh emits a blank line before each), so a task body
# that itself quotes a bare "# Setup" line inline does not cut the scan short.
# Lines inside a fenced code block are likewise never treated as a boundary, and
# the fence delimiters themselves are emitted when they fall inside the task
# section so brief_scan_text's narrowing can apply the same rule downstream.
# Both CommonMark fence characters count, and a fence closes only on the
# character that opened it, though not on the length of the run that opened it,
# so a fence opened with more than three of that character can still be closed
# early by a shorter inner run of the same character, a case CommonMark
# forbids but this rule does not check for. "~~~" is the idiomatic wrapper for
# a pasted markdown template that itself contains backtick fences, which is
# exactly the shape this tracking exists for, so recognising only backticks
# left that case open.
# Falls back to the whole brief when there is no # Task section (a non-standard
# or hand-written brief), keeping the permissive safety bias.
brief_task_body() {
  local body
  body=$(awk '
    { blank = ($0 ~ /^[[:space:]]*$/) }
    /^(```|~~~)/ {
      ch = substr($0, 1, 1)
      if (!fence) { fence = 1; fencech = ch } else if (ch == fencech) fence = 0
      if (intask) print
      prevblank = blank
      next
    }
    !fence && /^# Task[[:space:]]*$/ { intask=1; prevblank = blank; next }
    intask && !fence && prevblank && /^# (Herdr isolation.*|Herdr lifecycle declaration.*|Setup|Rules|Project memory|Definition of done)[[:space:]]*$/ { intask=0 }
    intask { print }
    { prevblank = blank }
  ' "$1")
  if [ -n "$body" ]; then
    printf '%s\n' "$body"
  else
    cat "$1"
  fi
}

# Whether the brief has the "# Task" section brief_task_body scopes to, using
# the identical match so the two can never disagree about what is parseable.
brief_has_task_section() {
  awk '
    /^(```|~~~)/ {
      ch = substr($0, 1, 1)
      if (!fence) { fence = 1; fencech = ch } else if (ch == fencech) fence = 0
      next
    }
    !fence && /^# Task[[:space:]]*$/ { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

# Component/token match against one changed file's path (already lowercased by
# the caller). Deliberately NOT a blanket bin/* match: firstmate's own
# supervision backbone lives under bin/ and is routed by an explicit dispatch
# rule (see docs/examples/crew-dispatch.json), so flooring every bin/ change
# here would override that rule and defeat the finer tiers.
#
# The same word-boundary discipline as the brief-text scan applies here, so a
# risk word must be a real path component or delimited token, not a bare
# substring: "strong" words (auth/migrat/schema/... families) match anywhere
# they appear as a /, -, _, or . delimited token, catching bin/auth-setup.sh,
# bin/run-migration.sh, and db/schema.sql; the weaker "session" matches only as
# a whole path component or filename base (lib/auth/session.rb,
# app/models/session.rb), never as a hyphen fragment - otherwise the
# supervision backbone bin/fm-session-start.sh would over-match. Bare-substring
# false positives like "auth" inside AUTHORS/docs/authors.md no longer trip.
# The flip side is intentional: a risk word glued into a compound component with
# NO delimiter (e.g. "authsetup.rb") is not matched, because catching it would
# require substring matching again and reopen exactly those false positives; the
# brief-text scan and the delimiter tokenization below cover the realistic cases.
PATH_STRONG_REGEX='^(auth|authn|authz|authoriz(e|ed|es|ing|ation|ations|er|ers)?|authenticat(e|ed|es|ing|ion|ions|or|ors)?|cookie|cookies|migrat(e|ed|es|ing|ion|ions)|schema|schemas|secret|secrets|credential|credentials|payment|payments|billing|security|password|passwords|token|tokens|permission|permissions|encrypt(s|ed|ing|ion|ions)?|decrypt(s|ed|ing|ion|ions)?)$'
PATH_WEAK_REGEX='^(session|sessions)$'
path_is_risky() {
  local path=$1 comp base
  case "$path" in
    .github/workflows/*|*/.github/workflows/*) return 0 ;;
    *dockerfile*|*docker-compose*) return 0 ;;
  esac
  while IFS= read -r comp; do
    [ -n "$comp" ] || continue
    base=${comp%.*}
    # Whole path component or filename base equal to a strong or weak word.
    if printf '%s\n%s\n' "$comp" "$base" | grep -Eiq "$PATH_STRONG_REGEX|$PATH_WEAK_REGEX"; then
      return 0
    fi
    # Strong words also match as a ., -, or _ delimited token inside a compound
    # name (e.g. config.schema.json, run-migration.sh), the fail-safe direction.
    if printf '%s\n' "$base" | tr '._-' '\n' | grep -Eiq "$PATH_STRONG_REGEX"; then
      return 0
    fi
  done < <(printf '%s\n' "$path" | tr '/' '\n')
  return 1
}

# The task body alone is still far too permissive a scan surface, because
# firstmate writes what a task must NOT touch into the same # Task region as
# what it must do. The better written the brief, the more risky surfaces it
# names, so the scan fired hardest on the most careful briefs. Measured over the
# 605 briefs this fleet had on disk when this narrowing was written, the body
# scan tripped 403 of them (66.6%), and ten consecutive fires across five
# repositories were pure constraint prose about paths the task never went near.
# After the narrowing, the same sweep over the same 605 briefs trips 353 (58.3%)
# with 0 briefs newly tripping, so the trip set is a strict subset of what the
# unnarrowed scan caught. Both figures come from running each version over every
# data/<id>/brief.md with no worktree, and counting a brief as tripping when the
# brief half of the scan prints a RISK line.
# A floor that applies to two thirds of all work is not a floor; worse, it
# pushes firstmate into deciding case by case whether to honor its own gate,
# which is the erosion a mechanical gate exists to prevent.
#
# So the body is narrowed to the prose that describes the WORK by dropping the
# prose that fences the work off, in three deliberately narrow steps:
#
#   D1  a scope-declaring SECTION. A "##"-or-deeper heading that declares a
#       non-change scope ("Explicitly out of scope", "What should NOT need
#       changing") opens an excluded region, closed by the next heading at the
#       same or shallower depth.
#   D2  a prohibition BLOCK. A PROSE list item or paragraph whose OPENING
#       SENTENCE is prohibitive in every one of its clauses is dropped, keeping
#       only those later sentences that read as instructions to change
#       something, because what else follows an all-prohibitive opening
#       elaborates the prohibition rather than the task. This is what reaches a
#       matching word that sits in a positively phrased sentence inside an
#       otherwise prohibitive bullet ("... A live supervision cycle is active
#       for this session.").
#   D3  a prohibition CLAUSE. Any surviving clause that is itself a prohibition
#       or an explicit non-change assertion is dropped on its own.
#
# D2 and D3 both judge CLAUSES, not whole sentences, because a compound sentence
# routinely carries a work instruction and a caveat about the same surface at
# once ("Document that Gmail needs an App Password for IMAP auth, do not assume
# plain password auth works"). Judging that sentence as one unit loses the work
# instruction along with the caveat. Splitting at the deontic marker keeps it:
# across the 613 briefs, 1661 sentences read as prohibitions taken whole yet
# keep at least one clause once split.
#
# D2's three qualifiers above - PROSE, OPENING SENTENCE rather than opening
# clause, and the WORK-SENTENCE RESCUE - are what stop one prohibition from
# taking unrelated work text down with it. All three replace an earlier rule
# that dropped any block whose opening CLAUSE was a prohibition, and all three
# only ever return text to the scan:
#
#   - PROSE. "Is this block's opening clause a prohibition?" presumes the block
#     is one authored prose point, which a paragraph or a list item is and a
#     fenced code block is not. A comment among code lines is a note ABOUT the
#     code, not an umbrella over it, so a caveat comment fronting a snippet used
#     to drop the snippet. That was reported in two consecutive review rounds,
#     first for "#" and then for "--", "//", "<!--", ";" and "%", each answered
#     by giving one more line shape its own block boundary rather than asking
#     whether a fenced block should be judged this way at all. A third round,
#     the earliest, had already reported the same mechanism without a comment in
#     sight: prohibition prose fronting work text took the work text.
#     Exempting fenced blocks from the whole-block drop closes every comment
#     syntax at once and names none of them, so a syntax nobody has written down
#     yet is closed too. D3 still judges each fenced clause on its own, so a
#     genuine standing prohibition inside a fence is still suppressed.
#   - OPENING SENTENCE. Keying on the opening clause made the rescue in the
#     paragraph above one-directional: a work clause that PRECEDED its caveat
#     survived, while one that FOLLOWED a leading prohibition in the same
#     sentence ("Do not touch the report queries, but do add a session index")
#     went down with the whole block. Requiring every clause of the opening
#     sentence to be prohibitive before dropping the block closes that
#     direction, because the work clause makes the opening sentence not
#     all-prohibitive and the block survives to be judged clause by clause.
#     For this to reach the example, "but" and "instead" split a clause the way
#     a deontic marker does (see clause_split below).
#   - WORK-SENTENCE RESCUE. The qualifier above closes that direction only
#     within one sentence. Put the same two thoughts either side of a full stop
#     ("Do not touch the report queries. Do add a session index.") and the
#     opening sentence is all-prohibitive again, so D2 drops the block and takes
#     the work sentence with it. So when D2 fires, the block is not returned
#     immediately: its LATER sentences are still scanned, and a later sentence
#     survives if it reads as an instruction to change something and is not
#     itself a prohibition (see work_sentence below). The rescue is per
#     SENTENCE, never per block: one work sentence returns itself and nothing
#     else, so a block that mixes an instruction with a statement about what is
#     already true keeps only the instruction.
#     This is a closed verb list, and this file rejects a closed verb list
#     elsewhere (see the change-verb entry among the rejected alternatives). The
#     difference is which side of the test the open word class sits on. As a
#     CORROBORATION test - requiring a change verb near a term before it may
#     trip - every phrasing the list misses becomes a new silence, which is the
#     dangerous direction. As a RESCUE inside a block that is already being
#     dropped, every phrasing it misses is one that is dropped today anyway, so
#     an incomplete list is a partial improvement and can never be a new miss.
#     The list is incomplete by construction and always will be.
#
# Every step above is strictly permissive AS A NARROWING STEP: D2 now fires on a
# subset of the blocks it used to fire on, it keeps a subset of what it used to
# drop when it does fire, and splitting a clause can only turn one dropped clause
# into a dropped clause plus a kept one, never the reverse (any prohibition
# pattern matching a fragment also matches the clause it came from, since
# normalisation puts a space at both ends of each). So the text this narrowing
# hands on can only grow, never shrink.
#
# That is a claim about the narrowing, and NOT about the scan end to end. Read
# only that far and it licenses "any increase in permissiveness is free", which
# is false: the narrowing is not the last stage. brief_scan_text ends in an
# emptiness fallback that prints the whole unnarrowed body when the narrowed text
# comes back blank. A fallback keyed on emptiness is a step function, so it is
# not monotone in the narrowing, and one more surviving fragment can mean
# strictly LESS text scanned. The third entry under "What this still misses"
# names that shape and bounds it. The next change here has to clear that entry as
# well as this paragraph.
#
# One end-to-end bound does hold, for a separate reason: every stage here only
# ever removes text from the task body, and the fallback restores that body
# whole, so the scanned text is always some subset of the body the pre-narrowing
# scanner read. The trip set therefore stays inside that scanner's, never past
# it, however permissive the narrowing becomes.
#
# Measured in two steps, because the PROSE and OPENING SENTENCE qualifiers
# landed before the work-sentence rescue and each was measured against the rule
# in front of it. Both runs are the brief half only, running each version over
# every data/<id>/brief.md with no worktree, and both state their corpus size
# because the fleet's brief count grows between runs.
#
# The rescue, over the 617 briefs on disk when it was added. Against the rule
# without it: 1 brief goes from clean to tripping, 0 go from tripping to clean,
# and at token level 0 briefs lose a term while 6 gain one, so nothing was
# traded for the residual it closes. Trip rate moves from 361 briefs to 362,
# against 413 unnarrowed. Against the pre-narrowing scan: 0 briefs trip that it
# did not and no brief's hit list carries a term the unnarrowed scan did not
# also find, so the subset bound above holds at token level and not just at
# verdict level; 51 of the briefs the unnarrowed scan tripped stay clean, one
# fewer than before the rescue. Both residual phrasings close, all nine recorded
# false fires stay clean, and the emptiness fallback still fires on 0 of the 617.
#
# The PROSE and OPENING SENTENCE qualifiers, over the 613 briefs on disk when
# they were added.
# Against the previous rule: 1 brief goes from clean to tripping and 0 go from
# tripping to clean. Checked at token level and not only at verdict level,
# because a brief can keep its verdict while quietly losing a term: that same
# brief is the only hit list that differs anywhere in the corpus, so no brief
# lost a term either.
# Against the pre-narrowing scan: 0 briefs trip that it did not, so the trip
# set is still a strict subset of the scan this whole narrowing had to stay
# inside, and 51 of the briefs it tripped stay clean (52 under the previous
# rule). Trip rate moves from 358 briefs (58.4%) to 359 (58.6%), against 410
# (66.9%) unnarrowed. The narrowing steps themselves move as the permissive
# direction predicts: whole-block drops fall from 1223 to 1197, clause drops
# rise from 3277 to 3316 as the blocks D2 no longer takes reach D3 instead, and
# split rescues rise from 1610 to 1661.
#
# Heading lines are ALWAYS scanned and never dropped by D2/D3: a heading is the
# most compressed statement of what its section is about, so a risk word in one
# is the strongest prose signal available.
#
# Rejected alternatives, recorded because the choice is the substance here.
# Every figure below states how it was counted, so a later reader can re-derive
# it rather than guess what was measured:
#   - Excluding a section named "Constraints". Counting each LINE of each
#     brief's task body that carries at least one whole-token match-set hit, and
#     attributing it to the nearest preceding markdown heading: of 1747 hit
#     lines across the 605 briefs, 197 (11%) sat under a heading whose text
#     contains "constraint" and 327 (18%) under no heading at all, the rest
#     spread across free-form headings ("Background", "What to build", "Hard
#     safety rules"). Firstmate names these sections however the task reads
#     best, so the name is not a boundary. Of the nine fixtured false fires, two
#     put a hit under an ordinary descriptive heading ("Background, and what is
#     already true"; "What the numbering has to mean") and one names its section
#     "What should NOT need changing", so three of nine are out of a name-based
#     rule's reach.
#   - Treating any negation in a heading as a scope declaration. Bug-report
#     headings use bare "not"/"never" constantly ("Finding 1 - AUTH_DIR is never
#     resolved", "atomicWrite's mode promise is not kept"). Measured by widening
#     scope_heading() to accept bare "not"/"never" and re-running both versions
#     over all 605 briefs: 19 briefs change verdict and 4 go clean outright. Two
#     of those four are plainly risk-bearing - one pins Stripe and Lob live keys
#     and an analytics token behind a heading reading "Scope: M0 and M0.5 ONLY.
#     Do NOT start M0.6", the other loses a data-package schema behind "why it
#     should not block you". The remaining 15 keep tripping but lose real terms
#     ("auth", "public exposure", "schema", "token"). Losing two risk-bearing
#     briefs outright is precisely the failure this guardrail exists to prevent,
#     so D1 matches only explicit scope-declaration phrases and never bare
#     negation.
#   - Dropping the prose scan and matching only the changed paths. Not
#     available: the first checkpoint runs before the task is spawned, when no
#     diff exists, and that is the checkpoint that sets the dispatch tier.
#   - Per-sentence negation handling alone. It cannot reach a matching word that
#     sits in a positively phrased sentence of a prohibitive bullet, which is
#     why D2 exists alongside D3.
#   - Dropping D2 outright, so every clause is judged on its own. It closes the
#     comment channel and the whole asymmetry at once and needs no fence
#     exemption, which is why it was measured first. Measured against the nine
#     recorded false fires the narrowing exists to stop: eight stay clean and
#     the ninth comes straight back, because its shape IS a prohibitive bullet
#     whose later sentence reads positively ("... A live supervision cycle is
#     active for this session."). D1 and D3 clear the other eight on their own,
#     so D2's entire remaining job is that one shape, and it cannot be given up
#     without giving that up. Whole-corpus effect, re-measured against the rule
#     below as it now stands, over the same 617 briefs: 366 briefs trip against
#     362, four more than the rule keeps, and recorded false fire 7 trips on
#     "session" again. The work-sentence rescue above is what makes this trade a
#     bad one rather than a close call: it recovers the work text dropping D2
#     was wanted for, at one brief instead of four, and leaves that false fire
#     suppressed. (When first measured, before the rescue, the same comparison
#     read 364 against 359 over the 613 briefs then on disk, with two of the five
#     returning briefs being the ones behind recorded false fires 4 and 7.)
#   - Requiring EVERY clause in the whole BLOCK to be a prohibition, rather than
#     every clause of its opening sentence. Measured on the 613-brief corpus,
#     against the rule as it stood before the work-sentence rescue, to be the
#     same trade as dropping D2 and no better: 364 briefs, the same five
#     returning, the same recorded false fire back. Its later sentences are
#     exactly the non-prohibitions the rule would require to be absent, so the
#     one shape D2 still exists for is the one shape this cannot express, and
#     the rescue reaches that text without giving the shape up.
#   - Giving a comment line its own block boundary, one comment syntax at a
#     time. This is what the previous round did for "#" and what the next one
#     would have done for "--" and "//", and it measurably does not converge: a
#     nine-line rule adding "--" and "//" to the boundary set closed
#     two of at least five syntaxes and left "<!--", markdown's own comment
#     syntax, still open. It also costs text in the other direction, since a new
#     block boundary promotes a D3 clause-drop into a D2 whole-block drop. The
#     PROSE qualifier above closes all of them without naming any.
#   - Ending D2's drop at the first later sentence that reads as a work
#     instruction. This WAS rejected here, on the same word-class grounds as the
#     change-verb entry below, and the rejection was wrong. It carried that
#     entry's conclusion across without re-checking its premise: what makes the
#     change-verb test unsafe is not that recognising work is an open class, it
#     is that a CORROBORATION test puts the open class on the SUPPRESSION side.
#     A rescue puts the same open class on the trip side, where this file's own
#     stated rule says it belongs, and the argument reverses with it. It is now
#     the work-sentence rescue above. Recorded rather than deleted because the
#     mistake is worth more to the next reader than the tidy list is: an
#     argument about an open word class is only as good as the direction it is
#     pointed in, and this one was reused pointing the wrong way.
#   - Never letting the narrowing remove the LAST match-set token from a brief,
#     so no brief can go from tripping to clean. It sounds like a free safety
#     net and it is not: it was implemented and measured, and it restores the
#     recorded false fires this narrowing exists to stop. They are cleared by
#     D2/D3, not by D1, because "## Constraints" is not a scope-declaring
#     heading, so the constraint prose holds the brief's only match-set tokens
#     and a last-token guard puts every one of them back. Do not implement it.
#   - Requiring a recognised change verb near the term instead of suppressing
#     fencing prose. That inverts the safety direction: ways to describe work
#     are an open word class ("move the session token out of localStorage" uses
#     none of the obvious ones), while prohibition phrasings are a closed one.
#     The open class must sit on the trip side, so this is a suppression test
#     and never a corroboration test. Note carefully what this rejects and what
#     it does not: the same change-verb list is used above as a RESCUE, where a
#     match returns text to the scan rather than withholding it, which puts the
#     open class on the trip side and is admissible for that reason alone. What
#     is rejected here is the list deciding whether a term may trip at all.
#   - Counting bare negation, or scope qualifiers like "with no downtime" and
#     "without breaking X", as prohibitions. Those mark negative polarity, not a
#     prohibition, and firstmate's two commonest registers are both negative
#     polarity about work it fully intends to do: the bug symptom and the safety
#     qualifier. Only deontic forms addressed to the worker count (see
#     prohibition() below).
#
# What this still misses, stated plainly because the safety direction is NOT
# symmetrical and a missed real hit is far worse than a false one:
#   - A genuinely risky task whose ONLY mention of the risky surface sits inside
#     a prohibition that concedes no work on it ("Never touch the session
#     store.", in a brief that otherwise describes its session work in words the
#     match set does not carry) is not caught by the prose scan.
#   - A work instruction whose verb is not on the rescue's closed list, sitting
#     in a later sentence of a block D2 dropped. "Do not touch the report
#     queries. Do add a session index." trips, because "add" is listed;
#     "... Set up a session index." does not, because "set" is not. This is the
#     residual the rescue leaves rather than the one it removes, and it is
#     bounded in the one way that matters: it is exactly the text a block drop
#     already suppressed before the rescue existed, so widening the list is a
#     free improvement and no phrasing can be made worse by being absent from
#     it. Widen it on the same evidence any other list here is widened on.
#     A previous version of this file argued no rescue was possible at all,
#     because an all-prohibitive opening followed by a positively phrased later
#     sentence is also the shape of recorded false fire 7, so the two want
#     opposite verdicts on text a structural rule cannot tell apart. That claim
#     was too strong. The two shapes ARE distinguishable, just not by structure:
#     the false fire's later sentence states what is already true ("A live
#     supervision cycle is active for this session"), while the missed brief's
#     instructs a change. Measured, the rescue closes both residual phrasings,
#     leaves all nine recorded false fires clean, and costs 1 brief on the
#     corpus, against the 5 and the reopened false fire that dropping D2 costs.
#   - A brief whose task body the narrowing would previously have emptied, and
#     now leaves one surviving fragment instead. The emptiness fallback below
#     restores the whole unnarrowed body only when narrowing leaves NOTHING, so
#     that one fragment switches the fallback off and the rest of the body stops
#     being scanned. This is the single direction in which a more permissive
#     narrowing scans strictly less, and it shows up as a brief going from
#     tripping to clean. Bounded by measurement rather than by argument: over the
#     617 briefs on disk when this entry was written, the fallback fires on 0 of
#     them both before and after the rule change, counted by marking the fallback
#     branch itself and sweeping every brief, so no brief on this fleet moves.
#     What is one ordinary edit away is the precondition, not the outcome: 154 of
#     the 617 have a task body with no markdown heading anywhere, and 24 of those
#     are six content lines or shorter. Left as a named gap on purpose. The
#     obvious repair is to keep the fallback from ever switching off, which is
#     the last-token guard measured and rejected above on recorded evidence, and
#     there is no cheap monotone form of it.
#
# What actually bounds those, measured over the 613 briefs on disk when the
# block rule above was last changed rather than assumed, because an overstated
# safety margin in a mechanical gate's own header is worse than a stated gap:
#   - Clause splitting is the one bound that carries real weight. 1661 sentences
#     read as prohibitions taken whole yet keep at least one clause, against
#     1197 blocks dropped whole at D2 and 3316 clauses dropped at D3. Every one
#     of those 1661 is work prose a sentence-level rule would have lost.
#   - concedes_work rescues 22 clauses, counting both its paths: 18 clauses
#     printed despite reading as prohibitions, and 4 blocks D2 would otherwise
#     have dropped whole. Small, and it is kept because the case it covers is
#     the one that cost a real access-control brief its whole scan (see
#     concedes_work below), not because the count is reassuring.
#   - A brief with no parseable "# Task" section is scanned whole and
#     unnarrowed, because the structure the narrowing assumes is not there to
#     assume. 3 of 613 briefs take that path.
#   - The empty-narrowing fallback below fires on 0 of 613. It is an emptiness
#     test, not a substance test, and headings print unconditionally, so any
#     heading anywhere in the task body keeps the narrowed text non-empty
#     forever. Treat it as a floor against a pathological brief, never as a
#     bound that operates in practice.
#   - The diff checkpoint below still floors the task once code exists, but it
#     matches file PATHS and never prose, at a later checkpoint, and it is not a
#     backstop for this scan: on a real IMAP intake task, the files actually
#     carrying the app password (src/config.ts and the mail client) tested clean
#     against path_is_risky, and only an unrelated migration riding the same
#     branch made it fire.
#
# So the honest position is one strong bound, one narrow one, and two floors
# that rarely or never fire. That is why the suppression rules above are kept
# deliberately closed-list and why widening any of them needs the same
# whole-corpus measurement rather than an argument.
brief_scan_text() {
  local narrowed body
  # The narrowing's whole premise is the shape of the "# Task" region firstmate
  # writes. When a brief has no parseable one - hand-written, or a decorated
  # heading like "# Task - VALIDATION RESUME" that the section matcher does not
  # recognise - that premise is absent, so the structure it would assume is not
  # there to assume. Scan the whole file unnarrowed instead of guessing, which
  # is the fail-toward-tripping direction this guardrail requires.
  if ! brief_has_task_section "$1"; then
    cat "$1"
    return
  fi
  body=$(brief_task_body "$1")
  narrowed=$(printf '%s\n' "$body" | awk '
    function norm(s) { s = tolower(s); gsub(/[^a-z0-9]+/, " ", s); return " " s " " }
    # A heading that declares what the task does NOT change. Deliberately a
    # closed phrase list, never bare "not"/"never" (see the rejected list above).
    function scope_heading(s,   t) {
      t = norm(s)
      return (t ~ / (out of scope|not in scope|non goal|non goals|should not need|not need changing|does not change|do not change|do not touch|what not to|leave unchanged|leave untouched) /)
    }
    # A sentence that forbids one thing WHILE conceding work on the same surface
    # is not fencing, it is scoping live work, and the surface it names is one
    # the task is about to be inside. "Do not break the login cookie while you
    # change the handler" says the handler is being changed. Measured on a real
    # access-control brief whose only match-set word was the "session middleware"
    # it was told not to touch, next to a route it was rewriting: suppressing
    # that sentence lost the whole task. So a conceding sentence is never a
    # prohibition. The connective list is closed and short on purpose; every
    # entry pulls text back onto the trip side, which is the safe direction.
    function concedes_work(s,   t) {
      t = norm(s)
      return (t ~ / (while you|when you|as you|while changing|while moving|while adding|in the process of|as part of this) /)
    }
    # Only DEONTIC negation counts: language addressed to the worker, telling it
    # what not to do. Descriptive negation is deliberately absent, because it is
    # how a bug report states the defect the task exists to fix. A brief saying
    # the login handler does not rotate the session token describes work that IS
    # needed; one saying do not rotate the session token forbids it. A bug report
    # says "does not work", it never says "must not work". Treating the
    # contracted descriptive forms or "cannot" as prohibitions was measured to
    # clear exactly that kind of brief, so they are excluded here and the
    # noisier reading is preferred.
    # This test was widened as well as bounded, and the widening is the part a
    # reader would not guess: the matched noun became "changes?", where the
    # previous pattern required a space straight after "change" and so never
    # matched the plural at all. It therefore now fires where it did not.
    # Corpus effect is exactly 1 brief of 605, which loses "security" and
    # "credential" from its hit list and still trips on "authorized"; the prose
    # suppressed there is a genuine declared-non-change list.
    # " no <up to six words> change(s) " reads as a declared non-change ("no
    # engine, schema, persistence, or migration change is needed"). Bounded in
    # length, and barred from spanning an infinitive, so ordinary motivation
    # prose like "there is no supported way to change a password" is not read as
    # a declaration that nothing changes.
    function declared_no_change(t,   span) {
      if (!match(t, / no ([a-z0-9]+ )?([a-z0-9]+ )?([a-z0-9]+ )?([a-z0-9]+ )?([a-z0-9]+ )?([a-z0-9]+ )?changes? /)) return 0
      span = substr(t, RSTART, RLENGTH)
      return (span !~ / to /)
    }
    # A later sentence in a block D2 dropped, reading as an instruction to CHANGE
    # something. Used ONLY as a rescue inside an already-dropped block, never as
    # a condition for tripping, and that is exactly what makes a closed verb list
    # admissible here when the header rejects one elsewhere. As a corroboration
    # test (requiring a change verb before a term may trip) it would put an open
    # word class on the suppression side and silence every phrasing it misses.
    # As a rescue, every phrasing it misses is one that is already suppressed
    # today, so an incomplete list is a partial improvement and never a new miss.
    # It is incomplete by construction and always will be; widen it on the same
    # evidence any other list here is widened on.
    function work_sentence(s,   t) {
      t = norm(s)
      return (t ~ / (add|build|chang|creat|delet|fix|implement|migrat|mov|port|remov|renam|replac|rotat|switch|updat|wir|writ)(e|es|ed|s|ing)? /)
    }
    function prohibition(s,   t) {
      t = norm(s)
      if (t ~ / (never|avoid|avoids|avoiding|forbidden|prohibited) /) return 1
      # "nothing" is the one word here that is usually NOT deontic. "Nothing in
      # the accept payload changes" declares a non-change scope; "it inserts a
      # row nothing links back to" describes a defect, and suppressing that was
      # measured to hide a real database table from the scan. So "nothing" only
      # counts beside an explicit non-change verb, which is a closed list and
      # narrows a suppression trigger, the safe direction.
      if (t ~ / nothing /) {
        if (t ~ / (change|changes|changed|move|moves|moved|touch|touches|touched|alter|alters|altered|differ|differs|affected|modified) /) return 1
      }
      if (t ~ / (do not|must not|may not|should not|shall not) /) return 1
      if (t ~ / (don t|mustn t|shouldn t) /) return 1
      if (t ~ / (untouched|unchanged|unaffected|unmodified|off limits|out of scope|read only|hands off) /) return 1
      if (t ~ / (needs no|need no|no need|not needed) /) return 1
      if (declared_no_change(t)) return 1
      return 0
    }
    # Split a sentence immediately before every deontic marker that opens a word,
    # so a compound sentence is judged clause by clause instead of as one unit.
    # This is the difference between "Document that Gmail needs an App Password
    # for IMAP auth, do not assume plain password auth works" reaching the scan
    # and vanishing from it: the main clause is a work instruction and only the
    # trailing caveat is a prohibition. A marker is only a split point when it
    # stands as a whole word, so "whenever" never carves a sentence apart and
    # cannot strand the words after it in a fragment that then reads prohibitive.
    #
    # "but" and "instead" split too, though neither is deontic. They mark where
    # a prohibition ENDS and the sentence turns back to work, which is the half
    # of the asymmetry a deontic-only marker set cannot reach: without them "do
    # not touch the report queries, but do add a session index" is one clause,
    # it reads as a prohibition whole, and the work goes with it. Both are
    # closed-class contrastive connectives and both only ever hand text back to
    # the scan. Kept to the two that were measured to move something: "but"
    # moves the sentence above, "instead" recovers a live brief whose only
    # session mention sat in a clause ending "which needs no auth" and which the
    # pre-narrowing scan tripped on. "however" and "whereas" were measured over
    # the same 613 briefs and moved nothing in either direction, so they are
    # left out rather than added for symmetry; add them on the same evidence if
    # a brief ever needs them.
    function clause_split(s, out,   n, buf, rest, p, len, before, after) {
      n = 0
      buf = ""
      rest = s
      while (match(rest, /(do not|don[^a-z0-9]?t|must not|mustn[^a-z0-9]?t|may not|might not|should not|shouldn[^a-z0-9]?t|shall not|never|avoid|avoids|avoiding|but|instead)/)) {
        p = RSTART
        len = RLENGTH
        before = (p > 1) ? substr(rest, p - 1, 1) : ""
        after = substr(rest, p + len, 1)
        if (before ~ /[a-z0-9]/ || after ~ /[a-z0-9]/) {
          buf = buf substr(rest, 1, p + len - 1)
          rest = substr(rest, p + len)
          continue
        }
        buf = buf substr(rest, 1, p - 1)
        if (buf ~ /[a-z0-9]/) out[++n] = buf
        buf = substr(rest, p, len)
        rest = substr(rest, p + len)
      }
      buf = buf rest
      if (buf ~ /[a-z0-9]/) out[++n] = buf
      return n
    }
    # Emit a finished block. When it is prose and every clause of its opening
    # sentence is a prohibition, D2 fires and only later sentences that read as
    # work instructions survive it; otherwise the block is emitted clause by
    # clause (D3). A concession is judged per SENTENCE, not per clause, so "do not
    # break the login cookie while you change the handler, and do not touch the
    # session middleware" keeps the surface the concession covers instead of
    # losing it at the comma.
    function flush(   ns, nc, i, j, sents, frags, conc, first, allproh, d2) {
      if (block ~ /^[[:space:]]*$/) { block = ""; blockfence = 0; return }
      gsub(/[[:space:]]+/, " ", block)
      # Everything this function emits is lowercased by the caller before it is
      # matched, so folding case here costs nothing and lets clause_split use
      # plain lowercase patterns rather than per-letter classes, which is the
      # only portable way to match case-insensitively across awk implementations.
      block = tolower(block)
      ns = split(block, sents, /[.!?;] +/)
      first = 1
      d2 = 0
      for (i = 1; i <= ns; i++) {
        if (sents[i] !~ /[a-z0-9]/) continue
        conc = concedes_work(sents[i])
        nc = clause_split(sents[i], frags)
        if (first) {
          first = 0
          # D2. blockfence is what keeps this off fenced code: a comment among
          # code lines is a note about the code, never an umbrella over it.
          if (!blockfence && !conc) {
            allproh = 1
            for (j = 1; j <= nc; j++) if (!prohibition(frags[j])) allproh = 0
            if (allproh) d2 = 1
          }
          # The opening sentence is what made D2 fire, so it never survives it.
          # Redundant while allproh means every clause of it is a prohibition,
          # since D3 below would drop all of them anyway; kept explicit so the
          # rule stays right if that condition is ever loosened.
          if (d2) continue
        } else if (d2 && !work_sentence(sents[i])) {
          continue
        }
        for (j = 1; j <= nc; j++) {
          if (conc || !prohibition(frags[j])) print frags[j]
        }
      }
      block = ""
      blockfence = 0
    }
    { blank = ($0 ~ /^[[:space:]]*$/) }
    # Fence delimiters reach this scan because brief_task_body emits them inside
    # the task section. Track them here so a scope-declaring line pasted inside a
    # fenced markdown or issue template cannot open a D1 exclusion that swallows
    # every risk word after it, the same discipline both sibling parsers apply.
    /^(```|~~~)/ {
      flush()
      ch = substr($0, 1, 1)
      if (!fence) { fence = 1; fencech = ch } else if (ch == fencech) fence = 0
      prevblank = blank
      next
    }
    /^#+[[:space:]]/ {
      flush()
      lvl = 0
      while (substr($0, lvl + 1, 1) == "#") lvl++
      if (exclevel > 0 && lvl <= exclevel) exclevel = 0
      # The heading itself always reaches the scan, even when it opens an
      # excluded section.
      print
      # Only a real markdown section heading may open an excluded region: at
      # least "##" deep, blank-line-preceded, and outside a fence. That is the
      # shape bin/fm-brief.sh emits and the same discipline brief_task_body
      # applies to its own boundaries. A column-0 "# " line in the body is a
      # shell comment in an example command ("# then run the schema migration"),
      # and letting one open an exclusion would silently drop every risk word
      # after it to the end of the brief.
      #
      # Only the OPENING decision is fence-gated, deliberately. Suppressing an
      # in-fence "#" line cost a whole fenced snippet, because the comment
      # fronting the block made its opening clause a prohibition and D2 dropped
      # the commands under it. Flushing one used to have a cost of its own in
      # the same direction, since a fresh block boundary can hand D2 an opening
      # that reads prohibitive and promote a clause-drop into a whole-block
      # drop; that cost is gone now that D2 does not apply inside a fence at
      # all, so the boundary here only ever changes where D3 judges one clause
      # to end. And letting an in-fence "#" line CLOSE an open exclusion only
      # ever returns text to the scan, which is the safe direction to be wrong
      # in.
      if (!fence && lvl >= 2 && prevblank && scope_heading($0)) exclevel = lvl
      prevblank = blank
      next
    }
    exclevel > 0 { prevblank = blank; next }
    /^[[:space:]]*$/ { flush(); prevblank = blank; next }
    # A new list item starts a new block; a continuation line joins the current
    # one, so a hard-wrapped bullet is judged as the single sentence it reads as.
    /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/ { flush() }
    # Record whether the text in this block came from inside a fence, at the
    # moment the block opens. flush() runs before every fence toggle, so the
    # live fence flag read there would give the same answer today; capturing it
    # here says what D2 actually needs to know and keeps that true if a future
    # rule ever flushes on the other side of a toggle.
    { if (block == "") blockfence = fence; block = block " " $0; prevblank = blank }
    END { flush() }
  ')
  # Never let the narrowing empty the scan: a brief written entirely as
  # constraints falls back to its full task body rather than passing silently.
  # Keyed on emptiness, so it is a step function and NOT monotone in the
  # narrowing above it: see the third entry under "What this still misses".
  if [ -n "$(printf '%s' "$narrowed" | tr -d '[:space:]')" ]; then
    printf '%s\n' "$narrowed"
  else
    printf '%s\n' "$body"
  fi
}

FOUND=0
CHECKED=0
DIFF_UNRESOLVED=0

BRIEF="$DATA/$ID/brief.md"
if [ -f "$BRIEF" ]; then
  CHECKED=1
  lc=$(brief_scan_text "$BRIEF" | tr '[:upper:]' '[:lower:]')
  # Split on every non-alnum char so each word is its own token (this also
  # splits snake_case identifiers like run_schema_migration), then match whole
  # tokens; phrases keep their inter-word gap on the space-normalized stream.
  word_hits=$(printf '%s\n' "$lc" | tr -c '[:alnum:]' '\n' | grep -xE "$WORD_REGEX" || true)
  phrase_hits=$(printf '%s\n' "$lc" | tr -c '[:alnum:]' ' ' | tr -s ' ' | grep -oE "$PHRASE_REGEX" || true)
  # An ambiguous head counts only when a qualifier sits within PAIR_WINDOW words
  # of it. Newlines survive the tr here, unlike the phrase stream above, so a
  # pair can only form inside one clause of brief_scan_text's output. Matching
  # is on whole awk fields rather than a regex over the flattened stream, so
  # "auth" inside "authoritative" can never qualify an adjacent head.
  pair_hits=$(printf '%s\n' "$lc" | tr -c '[:alnum:]\n' ' ' | tr -s ' ' | awk \
    -v heads="^(${AMBIG_HEADS})$" -v quals="^(${AMBIG_QUALIFIERS})$" -v window="$PAIR_WINDOW" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i !~ heads) continue
        for (d = 1; d <= window + 1; d++) {
          j = i - d
          if (j >= 1 && ($j ~ quals || $j ~ heads)) { print $j " " $i; break }
          j = i + d
          if (j <= NF && ($j ~ quals || $j ~ heads)) { print $i " " $j; break }
        }
      }
    }')
  hit=$(printf '%s\n%s\n%s\n' "$word_hits" "$phrase_hits" "$pair_hits" | sed '/^$/d' | sort -u | tr '\n' ',' | sed 's/,$//')
  if [ -n "$hit" ]; then
    echo "RISK: brief for $ID mentions risk-adjacent term(s): $hit"
    FOUND=1
  fi
fi

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PROJ=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
  if [ -n "$WT" ] && [ -n "$PROJ" ] && [ -d "$WT" ] && [ -d "$PROJ" ]; then
    CHECKED=1
    diff_base_resolved=0
    # The base resolution below duplicates bin/fm-review-diff.sh's origin fetch
    # and origin/<default> verification on purpose: this scan needs the changed
    # PATH LIST, but fm-review-diff.sh only exposes --stat (a diffstat), not a
    # --name-only path list, so there is nothing to reuse for a name scan.
    # Adding a --name-only mode to that script is the clean fix and is left as a
    # follow-up rather than expanding this task's scope into another owner.
    DEFAULT=$(fm_default_branch "$PROJ" 2>/dev/null || true)
    if [ -n "$DEFAULT" ]; then
      BASE="$DEFAULT"
      if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
        git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet 2>/dev/null || true
        git -C "$WT" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT^{commit}" >/dev/null 2>&1 && BASE="origin/$DEFAULT"
      fi
      if git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
        diff_base_resolved=1
        # Unlike the fetch/rev-parse above, a failure here is NOT the legitimate
        # "no base yet" case - the base already resolved - so it must not fall
        # through the same silent "|| true" the base-resolution steps use. A
        # genuine git error (a bad ref, a corrupt object, any other git
        # failure) at this point must still fail the run loudly rather than
        # read as an empty, risk-free diff (the fail-open direction for a
        # safety floor).
        if diff_paths=$(git -C "$WT" diff --name-only "$BASE...HEAD" --); then
          risky_paths=
          if [ -n "$diff_paths" ]; then
            while IFS= read -r path; do
              [ -n "$path" ] || continue
              lower_path=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
              if path_is_risky "$lower_path"; then
                risky_paths="${risky_paths}${risky_paths:+, }$path"
              fi
            done <<< "$diff_paths"
          fi
          if [ -n "$risky_paths" ]; then
            echo "RISK: diff for $ID touches risk-adjacent path(s): $risky_paths"
            FOUND=1
          fi
        else
          echo "error: git diff failed for $ID (base $BASE) even though the diff base resolved; the binding diff checkpoint errored rather than completing - reporting not-checkable (exit 2), not a clean pass" >&2
          DIFF_UNRESOLVED=1
        fi
      fi
    fi
    # The worktree/project exist, so the binding diff checkpoint was expected to
    # run - but the diff base could not be resolved (no default branch, or the
    # base commit does not verify in the worktree). Do not let that read as a
    # clean pass: warn loudly, like the sibling bin/fm-review-diff.sh, and mark
    # the run not-checkable so a caller branching on $? floors the task rather
    # than trusting a silent 0 - the safe direction for this guardrail.
    if [ "$diff_base_resolved" -eq 0 ]; then
      echo "warning: could not resolve a diff base for $ID (project $PROJ, default branch '${DEFAULT:-unresolved}'); the diff checkpoint did not run - reporting not-checkable (exit 2), not a clean pass" >&2
      DIFF_UNRESOLVED=1
    fi
  fi
fi

if [ "$CHECKED" -eq 0 ]; then
  echo "error: neither $BRIEF nor a usable worktree/project in $META was found for $ID; nothing to check" >&2
  exit 2
fi

# A real risk hit (exit 1) always wins over an unresolvable diff base; only when
# nothing tripped does an unresolvable base downgrade the run to could-not-check.
if [ "$FOUND" -eq 0 ] && [ "$DIFF_UNRESOLVED" -eq 1 ]; then
  exit 2
fi

exit "$FOUND"
