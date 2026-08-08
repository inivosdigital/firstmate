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
#     and the bare "auth" branch never reaches "authorize"/"authenticate".
#   - the un/re/de/pre prefixes ("unauthorized"/"unauthenticated" - the most
#     common access-control phrasing) glue a letter onto the stem's front, so
#     the auth stems carry an explicit optional prefix.
#   - a bare "auth"-anything stem is still avoided, so "authoritative"/"author"
#     stay shut.
# Word bounding is done by splitting the body into whole tokens (below), NOT by
# grep's \< / \> anchors: those are a GNU extension BSD grep does not honor, so
# on macOS they would silently match nothing and let every risky brief through -
# a false negative in the dangerous direction. Whole-token matching is identical
# on GNU and BSD grep and, unlike a boundary-consuming grep -o pattern, still
# reports BOTH words of an adjacent risk pair like "session token" (a consumed
# shared delimiter would drop the second). Single-word keywords go in WORD_REGEX;
# the multi-word phrases have no lone token and are matched on the
# space-normalized stream via PHRASE_REGEX.
WORD_KEYWORDS='auth|authentication|authorization|(un|re|de|pre)?authoriz(e|ed|es|ing|ation|ations|er|ers)?|(un|re|de|pre)?authenticat(e|ed|es|ing|ion|ions|or|ors)?|session|credential|password|secret|token|payment|billing|migrat(e|ed|es|ing|ion|ions)|schema|security|encrypt|decrypt|permission'
WORD_REGEX="(${WORD_KEYWORDS})(s|es|ed|ing|ion|ions)?"
PHRASE_REGEX='(access[[:space:]]+control|data[[:space:]]+deletion|bulk[[:space:]]+mutation|public[[:space:]]+exposure|breaking[[:space:]]+change)(s|es|ed|ing|ion|ions)?'

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
# character that opened it: "~~~" is the idiomatic wrapper for a pasted markdown
# template that itself contains backtick fences, which is exactly the shape this
# tracking exists for, so recognising only backticks left that case open.
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
PATH_STRONG_REGEX='^(auth|authn|authz|authoriz(e|ed|es|ing|ation|ations|er|ers)?|authenticat(e|ed|es|ing|ion|ions|or|ors)?|migrat(e|ed|es|ing|ion|ions)|schema|schemas|secret|secrets|credential|credentials|payment|payments|billing|security|password|passwords|token|tokens|permission|permissions|encrypt(s|ed|ing|ion|ions)?|decrypt(s|ed|ing|ion|ions)?)$'
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
#   D2  a prohibition BLOCK. A list item or paragraph whose FIRST clause is a
#       prohibition is dropped whole, because what follows it elaborates the
#       prohibition rather than the task. This is what reaches a matching word
#       that sits in a positively phrased sentence inside an otherwise
#       prohibitive bullet ("... A live supervision cycle is active for this
#       session.").
#   D3  a prohibition CLAUSE. Any surviving clause that is itself a prohibition
#       or an explicit non-change assertion is dropped on its own.
#
# D2 and D3 both judge CLAUSES, not whole sentences, because a compound sentence
# routinely carries a work instruction and a caveat about the same surface at
# once ("Document that Gmail needs an App Password for IMAP auth, do not assume
# plain password auth works"). Judging that sentence as one unit loses the work
# instruction along with the caveat. Splitting at the deontic marker keeps it:
# across the 605 briefs, 1597 sentences read as prohibitions taken whole yet
# keep at least one clause once split. The rescue is one-directional, though:
# a work clause that PRECEDES its caveat survives, while one that follows a
# leading prohibition ("Do not touch the report queries, but do add a session
# index") still goes down with the block, because D2 judges the opening clause.
# That asymmetry is inherited from the block rule, not introduced by the split.
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
#     and never a corroboration test.
#   - Counting bare negation, or scope qualifiers like "with no downtime" and
#     "without breaking X", as prohibitions. Those mark negative polarity, not a
#     prohibition, and firstmate's two commonest registers are both negative
#     polarity about work it fully intends to do: the bug symptom and the safety
#     qualifier. Only deontic forms addressed to the worker count (see
#     prohibition() below).
#
# What this still misses, stated plainly because the safety direction is NOT
# symmetrical and a missed real hit is far worse than a false one: a genuinely
# risky task whose ONLY mention of the risky surface sits inside a prohibition
# that concedes no work on it ("Never touch the session store.", in a brief that
# otherwise describes its session work in words the match set does not carry) is
# no longer caught by the prose scan.
#
# What actually bounds that, measured over the same 605 briefs rather than
# assumed, because an overstated safety margin in a mechanical gate's own header
# is worse than a stated gap:
#   - Clause splitting is the one bound that carries real weight. 1597 sentences
#     read as prohibitions taken whole yet keep at least one clause, against
#     1184 blocks dropped whole at D2 and 3236 clauses dropped at D3. Every one
#     of those 1597 is work prose a sentence-level rule would have lost.
#   - concedes_work rescues 21 clauses. Small, and it is kept because the case
#     it covers is the one that cost a real access-control brief its whole scan
#     (see concedes_work below), not because the count is reassuring.
#   - A brief with no parseable "# Task" section is scanned whole and
#     unnarrowed, because the structure the narrowing assumes is not there to
#     assume. 3 of 605 briefs take that path.
#   - The empty-narrowing fallback below fires on 0 of 605. It is an emptiness
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
    function clause_split(s, out,   n, buf, rest, p, len, before, after) {
      n = 0
      buf = ""
      rest = s
      while (match(rest, /(do not|don[^a-z0-9]?t|must not|mustn[^a-z0-9]?t|may not|might not|should not|shouldn[^a-z0-9]?t|shall not|never|avoid|avoids|avoiding)/)) {
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
    # Emit a finished block: dropped whole when its opening clause is a
    # prohibition (D2), otherwise clause by clause (D3). A concession is judged
    # per SENTENCE, not per clause, so "do not break the login cookie while you
    # change the handler, and do not touch the session middleware" keeps the
    # surface the concession covers instead of losing it at the comma.
    function flush(   ns, nc, i, j, sents, frags, conc, first) {
      if (block ~ /^[[:space:]]*$/) { block = ""; return }
      gsub(/[[:space:]]+/, " ", block)
      # Everything this function emits is lowercased by the caller before it is
      # matched, so folding case here costs nothing and lets clause_split use
      # plain lowercase patterns rather than per-letter classes, which is the
      # only portable way to match case-insensitively across awk implementations.
      block = tolower(block)
      ns = split(block, sents, /[.!?;] +/)
      first = 1
      for (i = 1; i <= ns; i++) {
        if (sents[i] !~ /[a-z0-9]/) continue
        conc = concedes_work(sents[i])
        nc = clause_split(sents[i], frags)
        for (j = 1; j <= nc; j++) {
          if (first) {
            first = 0
            if (!conc && prohibition(frags[j])) { block = ""; return }
          }
          if (conc || !prohibition(frags[j])) print frags[j]
        }
      }
      block = ""
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
      # Only the OPENING decision is fence-gated, deliberately. Flushing and
      # printing a "#" line inside a fence costs nothing, while suppressing them
      # cost a whole fenced snippet: the comment fronting the block made its
      # opening clause a prohibition, so D2 dropped the commands under it. And
      # letting an in-fence "#" line CLOSE an open exclusion only ever returns
      # text to the scan, which is the safe direction to be wrong in.
      if (!fence && lvl >= 2 && prevblank && scope_heading($0)) exclevel = lvl
      prevblank = blank
      next
    }
    exclevel > 0 { prevblank = blank; next }
    /^[[:space:]]*$/ { flush(); prevblank = blank; next }
    # A new list item starts a new block; a continuation line joins the current
    # one, so a hard-wrapped bullet is judged as the single sentence it reads as.
    /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/ { flush() }
    { block = block " " $0; prevblank = blank }
    END { flush() }
  ')
  # Never let the narrowing empty the scan: a brief written entirely as
  # constraints falls back to its full task body rather than passing silently.
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
  hit=$(printf '%s\n%s\n' "$word_hits" "$phrase_hits" | sed '/^$/d' | sort -u | tr '\n' ',' | sed 's/,$//')
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
