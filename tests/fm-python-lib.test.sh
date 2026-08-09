#!/usr/bin/env bash
# tests/fm-python-lib.test.sh - unit tests for the shared "which python3
# interpreter to run" resolver (bin/fm-python-lib.sh). Pure PATH-scanning
# logic, exercised against fabricated PATH directories rather than whatever
# interpreters happen to be installed on the machine running the suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-python-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-python-lib)

make_interpreter() {  # <dir> <name>
  local dir=$1 name=$2
  cat > "$dir/$name" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/$name"
}

# A directory holding only the real bash binary, appended after each
# fabricated PATH below so `bash -c` can still find an interpreter to run
# without introducing a real python3.* alongside it that would confound what
# the resolver is being tested to find.
REALBASH_DIR="$TMP_ROOT/realbash"
mkdir -p "$REALBASH_DIR"
ln -s "$(command -v bash)" "$REALBASH_DIR/bash"

# A host with only a bare python3 (no version-qualified name at all) falls
# back to it unchanged - the "behaves exactly as today" floor.
BAREDIR="$TMP_ROOT/bare"
mkdir -p "$BAREDIR"
make_interpreter "$BAREDIR" python3
GOT=$(PATH="$BAREDIR:$REALBASH_DIR" bash -c '. "$1"; fm_python_bin' _ "$ROOT/bin/fm-python-lib.sh")
[ "$GOT" = python3 ] || fail "a bare-only PATH must resolve to plain python3, got: $GOT"
pass "fm_python_bin falls back to plain python3 when no versioned interpreter is on PATH"

# Several version-qualified interpreters on PATH: the newest minor wins,
# regardless of PATH order or which else are present.
MULTIDIR="$TMP_ROOT/multi"
mkdir -p "$MULTIDIR"
make_interpreter "$MULTIDIR" python3.9
make_interpreter "$MULTIDIR" python3.13
make_interpreter "$MULTIDIR" python3.10
GOT=$(PATH="$MULTIDIR:$REALBASH_DIR" bash -c '. "$1"; fm_python_bin' _ "$ROOT/bin/fm-python-lib.sh")
[ "$GOT" = python3.13 ] || fail "the highest minor version must win among several, got: $GOT"
pass "fm_python_bin picks the newest python3.N minor version present, independent of creation order"

# A directory later in PATH still wins on version even when an earlier PATH
# entry has an older interpreter, and a bare python3 loses to any versioned
# name once one exists.
EARLYDIR="$TMP_ROOT/early"
LATEDIR="$TMP_ROOT/late"
mkdir -p "$EARLYDIR" "$LATEDIR"
make_interpreter "$EARLYDIR" python3
make_interpreter "$EARLYDIR" python3.10
make_interpreter "$LATEDIR" python3.11
GOT=$(PATH="$EARLYDIR:$LATEDIR:$REALBASH_DIR" bash -c '. "$1"; fm_python_bin' _ "$ROOT/bin/fm-python-lib.sh")
[ "$GOT" = python3.11 ] || fail "a newer interpreter later in PATH must still win, got: $GOT"
pass "fm_python_bin prefers the newest interpreter across PATH entries, not just the first directory"

# A version-suffixed non-interpreter (e.g. python3.10-config, python3.10m on
# an old build) must never be mistaken for an interpreter.
DECOYDIR="$TMP_ROOT/decoy"
mkdir -p "$DECOYDIR"
make_interpreter "$DECOYDIR" python3.10
cat > "$DECOYDIR/python3.99-config" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$DECOYDIR/python3.99-config"
GOT=$(PATH="$DECOYDIR:$REALBASH_DIR" bash -c '. "$1"; fm_python_bin' _ "$ROOT/bin/fm-python-lib.sh")
[ "$GOT" = python3.10 ] || fail "a non-digit version suffix must be ignored, got: $GOT"
pass "fm_python_bin ignores version-suffixed non-interpreters like python3.N-config"

# FM_PYTHON_BIN pins the resolver outright, bypassing the PATH scan.
GOT=$(FM_PYTHON_BIN=/pinned/python PATH="$REALBASH_DIR" bash -c '. "$1"; fm_python_bin' _ "$ROOT/bin/fm-python-lib.sh")
[ "$GOT" = /pinned/python ] || fail "FM_PYTHON_BIN must override the search outright, got: $GOT"
pass "FM_PYTHON_BIN pins the resolver for tests that need to constrain what it finds"

echo "# fm-python-lib.test.sh: all assertions passed"
