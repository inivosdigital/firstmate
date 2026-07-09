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
# Errors (exit 2) if neither is available; that means there is nothing to
# check yet.
#
# Prints one "RISK: <reason>" line per hit and exits 1 if any fired; exits 0
# (silent) when neither surface matched. A hit means: floor this task's
# model/effort to the safety-critical profile (opus/xhigh, ultracode
# independent-review) regardless of which rule the natural-language dispatch
# match picked, per AGENTS.md section 4's risk floor.
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
[ -n "$ID" ] || { usage; exit 1; }
[ $# -le 1 ] || { usage; exit 1; }

# Case-insensitive substring match against the brief's prose. Permissive by
# design (a false positive just means "double-check"; a false negative is the
# dangerous direction for a safety floor).
TEXT_KEYWORDS='auth|authentication|authorization|session|credential|password|secret|token|payment|billing|migration|schema|security|encrypt|decrypt|permission|access.control|data.deletion|bulk.mutation|public.exposure|breaking.change'

# Substring match against one changed file's path (already lowercased by the caller).
path_is_risky() {
  case "$1" in
    .github/workflows/*|*/.github/workflows/*) return 0 ;;
    bin/*|*/bin/*) return 0 ;;
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
  hit=$(grep -Eoi "$TEXT_KEYWORDS" "$BRIEF" | tr '[:upper:]' '[:lower:]' | sort -u | tr '\n' ',' | sed 's/,$//')
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
