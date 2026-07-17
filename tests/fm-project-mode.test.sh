#!/usr/bin/env bash
# tests/fm-project-mode.test.sh - unit tests for bin/fm-project-mode.sh's
# delivery-mode resolution: the data/projects.md registry lookup, the
# unregistered-project fallback, and the special case for firstmate's own
# repo (AGENTS.md section 1: never registered, always resolves local-only).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-mode)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"
printf '%s\n' \
  '- app [direct-PR +yolo] - test app (added 2026-06-22)' \
  > "$HOME_DIR/data/projects.md"

out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" app)
[ "$out" = "direct-PR on" ] || fail "registered project did not resolve its configured mode: $out"
pass "a registered project resolves its configured mode and yolo flag"

out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" some-unregistered-project 2>/dev/null)
[ "$out" = "no-mistakes off" ] || fail "unregistered project did not fall back to no-mistakes off: $out"
pass "an unregistered project still falls back to no-mistakes off"

# firstmate's own repo is intentionally never registered in data/projects.md.
# fm-spawn.sh passes basename(PROJ_ABS) as the name, and a firstmate-repo task
# worktree's basename matches basename("$ROOT") the same way any other
# checkout's would, so that is what should resolve to local-only here.
own_name=$(basename "$ROOT")
out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-project-mode.sh" "$own_name" 2>/dev/null)
[ "$out" = "local-only off" ] || fail "firstmate's own repo did not resolve to local-only off: $out"
pass "resolving mode for firstmate's own repo (by its basename) always resolves local-only off"

# The registry is consulted first: a project that happens to be registered
# under the same name as firstmate's own basename keeps its configured mode
# rather than being silently overridden by the own-repo special case.
printf '%s\n' \
  "- $own_name [direct-PR +yolo] - a project that shares firstmate's basename (added 2026-06-22)" \
  > "$HOME_DIR/data/projects.md"
out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-project-mode.sh" "$own_name")
[ "$out" = "direct-PR on" ] || fail "a registered project sharing firstmate's basename was overridden: $out"
pass "a registered project sharing firstmate's basename keeps its own configured mode"

echo "# fm-project-mode.test.sh: all assertions passed"
