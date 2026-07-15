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
#      worktree/project exists yet (nothing to check), or the worktree/project
#      exist but their diff base could not be resolved, so the binding diff
#      checkpoint could not run (warned to stderr, never a silent clean pass)
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
# Lines inside a fenced code block are likewise never treated as a boundary.
# Falls back to the whole brief when there is no # Task section (a non-standard
# or hand-written brief), keeping the permissive safety bias.
brief_task_body() {
  local body
  body=$(awk '
    { blank = ($0 ~ /^[[:space:]]*$/) }
    /^```/ { fence = !fence; prevblank = blank; next }
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

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '') return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

resolve_pr_head() {
  local pr_url=$1 recorded_head=$2 n resolved
  if [ -n "$recorded_head" ] \
    && git -C "$WT" cat-file -e "$recorded_head^{commit}" 2>/dev/null; then
    printf '%s' "$recorded_head"
    return 0
  fi
  n=$(pr_number_from_target "$pr_url") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  resolved=$(git -C "$WT" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null) || return 1
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
}

FOUND=0
CHECKED=0
DIFF_UNRESOLVED=0

BRIEF="$DATA/$ID/brief.md"
if [ -f "$BRIEF" ]; then
  CHECKED=1
  lc=$(brief_task_body "$BRIEF" | tr '[:upper:]' '[:lower:]')
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
    compare_ref=HEAD
    PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
    PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
    if [ -n "$PR_URL$PR_HEAD_RECORDED" ]; then
      if PR_HEAD=$(resolve_pr_head "$PR_URL" "$PR_HEAD_RECORDED"); then
        compare_ref=$PR_HEAD
      elif [ -n "$PR_URL" ]; then
        echo "warning: PR head unavailable for $ID; risk path scan may lag the open PR (using local HEAD)" >&2
      fi
    fi
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
        diff_paths=
        diff_rc=0
        diff_paths=$(git -C "$WT" diff --name-only "$BASE...$compare_ref" -- 2>/dev/null) || diff_rc=$?
        if [ "$diff_rc" -ne 0 ]; then
          echo "warning: could not read changed paths for $ID (project $PROJ, base '$BASE', compare '$compare_ref'); the diff checkpoint did not run - reporting not-checkable (exit 2), not a clean pass" >&2
          DIFF_UNRESOLVED=1
        else
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
  else
    echo "warning: unusable worktree/project for $ID (worktree '${WT:-unresolved}', project '${PROJ:-unresolved}'); the diff checkpoint did not run - reporting not-checkable (exit 2), not a clean pass" >&2
    DIFF_UNRESOLVED=1
  fi
fi

if [ "$CHECKED" -eq 0 ] && [ "$DIFF_UNRESOLVED" -eq 0 ]; then
  echo "error: neither $BRIEF nor a usable worktree/project in $META was found for $ID; nothing to check" >&2
  exit 2
fi

# A real risk hit (exit 1) always wins over an unresolvable diff base; only when
# nothing tripped does an unresolvable base downgrade the run to could-not-check.
if [ "$FOUND" -eq 0 ] && [ "$DIFF_UNRESOLVED" -eq 1 ]; then
  exit 2
fi

exit "$FOUND"
