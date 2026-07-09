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
#   2  could not check: a malformed invocation, or neither a brief nor a usable
#      worktree/project exists yet (nothing to check)
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

# Case-insensitive, word-bounded match (tolerating plural/verb inflections such
# as migration -> migrations and encrypt -> encryption) against the brief's prose.
# Word boundaries stop substring false positives like "auth" inside
# "authoritative"; inflection tolerance keeps the safety bias intact, since a
# missed plural is a false negative and false negatives are the dangerous
# direction for a safety floor.
TEXT_KEYWORDS='auth|authentication|authorization|session|credential|password|secret|token|payment|billing|migration|schema|security|encrypt|decrypt|permission|access.control|data.deletion|bulk.mutation|public.exposure|breaking.change'
TEXT_REGEX="\\<(${TEXT_KEYWORDS})(s|es|ed|ing|ion|ions)?\\>"

# Scan only the task-specific body of the brief (the # Task section up to the
# next top-level heading), never the fixed scaffold boilerplate bin/fm-brief.sh
# writes into every brief - that boilerplate contains benign words like
# "authoritative" and "future session" that would otherwise trip the wire on
# every task. Falls back to the whole brief when there is no # Task section
# (a non-standard or hand-written brief), keeping the permissive safety bias.
brief_task_body() {
  local body
  body=$(awk '
    /^# Task[[:space:]]*$/ { intask=1; next }
    intask && /^# / { intask=0 }
    intask { print }
  ' "$1")
  if [ -n "$body" ]; then
    printf '%s\n' "$body"
  else
    cat "$1"
  fi
}

# Substring match against one changed file's path (already lowercased by the
# caller). Deliberately NOT a blanket bin/* match: firstmate's own supervision
# backbone lives under bin/ and is routed by an explicit dispatch rule (see
# docs/examples/crew-dispatch.json), so flooring every bin/ change here would
# override that rule and defeat the finer tiers. A genuinely risky script still
# trips via its name (e.g. bin/run-migration.sh, bin/auth-setup.sh).
path_is_risky() {
  case "$1" in
    .github/workflows/*|*/.github/workflows/*) return 0 ;;
    *dockerfile*|*docker-compose*) return 0 ;;
    *auth*|*migrat*|*schema*|*secret*|*credential*|*payment*|*billing*|*security*|*session*) return 0 ;;
  esac
  return 1
}

FOUND=0
CHECKED=0

BRIEF="$DATA/$ID/brief.md"
if [ -f "$BRIEF" ]; then
  CHECKED=1
  hit=$(brief_task_body "$BRIEF" | grep -Eoi "$TEXT_REGEX" | tr '[:upper:]' '[:lower:]' | sort -u | tr '\n' ',' | sed 's/,$//')
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
    DEFAULT=$(fm_default_branch "$PROJ" 2>/dev/null || true)
    if [ -n "$DEFAULT" ]; then
      BASE="$DEFAULT"
      if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
        git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet 2>/dev/null || true
        git -C "$WT" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT^{commit}" >/dev/null 2>&1 && BASE="origin/$DEFAULT"
      fi
      if git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
        diff_paths=$(git -C "$WT" diff --name-only "$BASE...HEAD" -- 2>/dev/null || true)
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
fi

if [ "$CHECKED" -eq 0 ]; then
  echo "error: neither $BRIEF nor a usable worktree/project in $META was found for $ID; nothing to check" >&2
  exit 2
fi

exit "$FOUND"
