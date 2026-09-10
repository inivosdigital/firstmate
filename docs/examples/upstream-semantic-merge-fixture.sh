#!/usr/bin/env bash
# Workflow fixture for the upstream-reconciliation skill.
#
# It builds three disposable repository pairs that reproduce the three outcomes
# an upstream merge can have, and asserts each one, so the risk the skill's
# fork-behavior inventory step exists for is demonstrated rather than described:
#
#   disjoint   upstream and the fork changed different files. Clean merge, and
#              the fork/upstream overlap list is empty. This is the control.
#   conflict   both sides changed the same region. git stops and asks, which is
#              the SAFE failure: nothing is lost silently.
#   semantic   both sides changed the same file in different regions. git
#              merges it cleanly, every line of fork code survives, and the
#              fork's behavior is gone anyway. Nothing conflicts, nothing warns,
#              and only the overlap list points at the file worth re-checking.
#
# The semantic case is the reason step 5 of the skill is not optional: a green
# merge and a green build both pass while a fail-closed guard stops running.
#
# Usage: tests/assets/upstream-semantic-merge-fixture.sh
# Exits 0 when all three outcomes still hold, non-zero with the failing case
# named otherwise. It writes only inside its own temp directory.
set -u

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-upstream-fixture.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# The shared starting point: a dispatcher that calls a worker through a wrapper.
write_base() { # <dir>
  cat > "$1/run.sh" <<'SH'
#!/usr/bin/env bash
set -u

main() {
  do_work "$1"
}

do_work() {
  printf 'work %s\n' "$1"
}

main "${1-}"
SH
  chmod +x "$1/run.sh"
  printf 'shared notes\n' > "$1/notes.txt"
}

# build <name> <upstream-edit-fn>: an upstream repo and a fork clone of it, with
# one fork commit and one upstream commit. Echoes the pair's root.
build() {
  local name=$1 upstream_edit=$2 root
  root="$WORK/$name"
  mkdir -p "$root/upstream"
  git -C "$root/upstream" init -q -b main .
  write_base "$root/upstream"
  git -C "$root/upstream" add -A
  git -C "$root/upstream" commit -qm base

  git clone -q "$root/upstream" "$root/fork"
  git -C "$root/fork" remote rename origin upstream

  # The fork's own behavioral contract: refuse to run with no target. It lives
  # in main(), the wrapper, which is where a fork guard naturally goes.
  perl -0pi -e 's/main\(\) \{\n  do_work/main() {\n  if [ -z "\$1" ]; then\n    printf "refusing: no target\\n" >&2\n    return 1\n  fi\n  do_work/' "$root/fork/run.sh"
  git -C "$root/fork" commit -qam 'fork: refuse to run without a target'

  "$upstream_edit" "$root/upstream"
  # A no-op edit would leave the fixture silently comparing a repo against
  # itself, so refuse rather than build a case that proves nothing.
  git -C "$root/upstream" diff --quiet \
    && { printf 'not ok - %s: the upstream edit changed nothing\n' "$name" >&2; exit 1; }
  git -C "$root/upstream" commit -qam "upstream: $name" >/dev/null
  git -C "$root/fork" fetch -q upstream
  printf '%s\n' "$root"
}

# The three upstream edits.
edit_disjoint() { printf 'upstream notes\n' > "$1/notes.txt"; }
# Inserts at the same point in main() the fork's guard occupies, so the two
# edits are a genuine same-region collision rather than a near miss.
edit_conflicting() { perl -0pi -e 's/main\(\) \{\n/main() {\n  printf "entering main\\n" >&2\n/' "$1/run.sh"; }
# Drops the wrapper from the dispatch line: a different region of the same file,
# and the fork's guard in main() is simply never reached again.
edit_semantic() { perl -0pi -e 's/^main "\$\{1-\}"$/do_work "\${1-}"/m' "$1/run.sh"; }

# Prints the paths both sides changed since their merge base.
overlap() { # <fork-repo>
  local base
  base=$(git -C "$1" merge-base main upstream/main)
  LC_ALL=C comm -12 \
    <(git -C "$1" diff --name-only "$base" main | LC_ALL=C sort) \
    <(git -C "$1" diff --name-only "$base" upstream/main | LC_ALL=C sort)
}

# Runs run.sh with no argument and prints "<exit> <first line of output>".
behavior() { # <repo>
  local out status
  out=$(cd "$1" && ./run.sh 2>&1)
  status=$?
  printf '%s %s\n' "$status" "$(printf '%s' "$out" | head -1)"
}

merge_upstream() { # <fork-repo> -> exit status of the merge
  git -C "$1" merge --no-ff --no-commit upstream/main >/dev/null 2>&1
}

# --- disjoint: the control --------------------------------------------------

root=$(build disjoint edit_disjoint)
merge_upstream "$root/fork" || fail "disjoint: a disjoint upstream change did not merge cleanly"
[ -z "$(overlap "$root/fork")" ] \
  || fail "disjoint: the control case reported a fork/upstream overlap"
[ "$(behavior "$root/fork")" = "1 refusing: no target" ] \
  || fail "disjoint: the fork's refusal did not survive a disjoint merge"
pass "disjoint upstream work merges clean, overlaps nothing, and keeps fork behavior"

# --- conflict: the safe failure ---------------------------------------------

root=$(build conflict edit_conflicting)
if merge_upstream "$root/fork"; then
  fail "conflict: overlapping edits to the same region merged without stopping"
fi
git -C "$root/fork" diff --name-only --diff-filter=U | grep -qx run.sh \
  || fail "conflict: run.sh was not reported as conflicted"
pass "same-region upstream work conflicts, which is the safe outcome"

# --- semantic: the silent regression ----------------------------------------

root=$(build semantic edit_semantic)
before=$(behavior "$root/fork")
[ "$before" = "1 refusing: no target" ] \
  || fail "semantic: the fixture's fork did not start out refusing (got: $before)"

merge_upstream "$root/fork" \
  || fail "semantic: the fixture no longer produces a CLEAN merge, so it no longer demonstrates the risk"
[ -z "$(git -C "$root/fork" diff --name-only --diff-filter=U)" ] \
  || fail "semantic: the merge reported a conflict, so this is no longer the silent case"

# Every line of the fork's guard is still in the merged file.
grep -q 'refusing: no target' "$root/fork/run.sh" \
  || fail "semantic: the merge deleted the fork's guard, which would at least be visible"

after=$(behavior "$root/fork")
[ "$after" != "$before" ] \
  || fail "semantic: behavior did not change, so the fixture no longer demonstrates a regression"
overlap "$root/fork" | grep -qx run.sh \
  || fail "semantic: run.sh was missing from the fork/upstream overlap that is the only warning"

pass "same-file, different-region upstream work merges CLEAN and silently drops fork behavior"
printf '  before merge: %s\n' "$before"
printf '  after merge:  %s\n' "$after"
printf '  git said nothing. The only signal was the overlap list: run.sh\n'
