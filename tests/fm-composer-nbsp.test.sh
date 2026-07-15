#!/usr/bin/env bash
# tests/fm-composer-nbsp.test.sh - non-breaking-space composer padding.
#
# INCIDENT (2026-07-14, three occurrences, all against a claude composer target):
# bin/fm-send.sh reported `exit 1` / "Enter swallowed; text left in composer"
# even though the message had genuinely reached the target and been submitted
# (fm-peek showed the crewmate processing it moments later). The caller could not
# tell this false alarm apart from a real swallow without manually peeking.
#
# ROOT CAUSE (captured live from a working claude pane, tmux 3.x, 2026-07-14):
# claude draws its composer prompt as the glyph "❯" (U+276F) followed by a
# NON-BREAKING SPACE (U+00A0), not an ASCII space. The exact cursor-line bytes,
# `tmux capture-pane -e -p` of the cursor row while the agent was working, were:
#   1b 5b 33 37 6d   e2 9d af   c2 a0   1b 5b 33 39 6d
#   ESC [ 3 7 m       ❯          <nbsp>  ESC [ 3 9 m
# glibc's en_US.UTF-8 [:space:] does NOT classify U+00A0 as whitespace, so the
# composer reader's ASCII whitespace trimming and its "❯ " (glyph + ASCII space)
# strip both leave the U+00A0 behind as phantom "content". An empty composer that
# has cleared to "❯ " therefore misclassifies as `pending`, and fm-send's
# submit loop reads `pending` on every retry, exhausts them, and returns the
# false swallow. Because the same idle line sometimes carries a busy footer or
# dim ghost text on the cursor row (both read empty), the false alarm was
# intermittent, which is why it took three occurrences to pin.
#
# FIX (bin/fm-composer-lib.sh): the shared classifier normalizes no-break space
# characters (U+00A0 and its narrow sibling U+202F) to an ASCII space before
# trimming, so an otherwise-empty composer reads empty on every backend. These
# tests pin the fix at three layers - the shared classifier, the tmux composer
# reader that captures the real styled bytes, and the submit loop / full fm-send
# exit code that the incident actually surfaced through.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-composer-nbsp)

# The two no-break spaces the fix normalizes, as literal UTF-8 bytes.
NBSP=$(printf '\302\240')      # U+00A0 NO-BREAK SPACE (claude's composer padding)
NNBSP=$(printf '\342\200\257')  # U+202F NARROW NO-BREAK SPACE (its narrow sibling)

# The EXACT styled cursor line captured live from a working claude pane: a white
# (SGR 37) prompt glyph followed by a bare U+00A0, reset to default fg (SGR 39).
CLAUDE_LINE=$(printf '\033[37m\xe2\x9d\xaf\xc2\xa0\033[39m')

classify() { fm_composer_classify_content "$@"; }

# A fake tmux that serves one styled cursor line (FM_FAKE_STYLED, a raw string in
# the env) for `capture-pane -e` and the SGR-stripped plain form otherwise, with a
# numeric cursor_y (FM_FAKE_CY) and always-succeeding send-keys. Mirrors the
# harness in tests/fm-composer-ghost.test.sh but takes the line from the
# environment so a test can pass raw bytes without a temp file.
make_fake_tmux() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '%s\n' "${FM_FAKE_CY:-0}"; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    has_e=0; for a in "$@"; do [ "$a" = "-e" ] && has_e=1; done
    if [ "$has_e" = 1 ]; then printf '%s\n' "${FM_FAKE_STYLED:-}"
    else printf '%s\n' "${FM_FAKE_STYLED:-}" | LC_ALL=C sed 's/\x1b\[[0-9;:?]*[[:alpha:]]//g'; fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# --- Layer 1: the shared classifier -----------------------------------------

test_classify_nbsp_padded_agent_glyph_is_empty() {
  local out
  # claude's real cleared composer: agent glyph + a trailing non-breaking space.
  out=$(classify 0 "❯$NBSP")
  [ "$out" = empty ] || fail "bare '❯<nbsp>' (claude's cleared composer) must read empty, got '$out'"
  out=$(classify 1 "❯$NBSP")
  [ "$out" = empty ] || fail "bordered '❯<nbsp>' must read empty, got '$out'"
  # Leading and surrounding no-break spaces trim away too.
  out=$(classify 0 "$NBSP❯$NBSP")
  [ "$out" = empty ] || fail "'<nbsp>❯<nbsp>' must read empty, got '$out'"
  pass "fm_composer_classify_content: an agent glyph padded with U+00A0 reads empty"
}

test_classify_narrow_nbsp_padded_glyph_is_empty() {
  local out
  out=$(classify 0 "❯$NNBSP")
  [ "$out" = empty ] || fail "'❯<narrow-nbsp>' (U+202F) must read empty, got '$out'"
  pass "fm_composer_classify_content: an agent glyph padded with U+202F reads empty"
}

test_classify_nbsp_only_is_empty() {
  local out
  # A composer holding only no-break space is empty, not pending.
  out=$(classify 1 "$NBSP")
  [ "$out" = empty ] || fail "a bordered composer holding only U+00A0 must read empty, got '$out'"
  pass "fm_composer_classify_content: a composer of only no-break space reads empty"
}

test_classify_nbsp_with_real_text_stays_pending() {
  local out
  # Real typed content must still win - the no-break space is just a separator.
  out=$(classify 0 "❯${NBSP}fix findings 1 and 3")
  [ "$out" = pending ] || fail "real text after a no-break space must stay pending, got '$out'"
  out=$(classify 0 "deploy staging now$NBSP")
  [ "$out" = pending ] || fail "real text with a trailing no-break space must stay pending, got '$out'"
  pass "fm_composer_classify_content: no-break-space normalization never hides real typed text"
}

test_bare_shell_prompt_with_nbsp_stays_unknown() {
  local out
  # Safety contract preserved: a bare shell prompt padded with a no-break space
  # is still a dead shell, never a safe injection target.
  out=$(classify 0 "\$$NBSP")
  [ "$out" = unknown ] || fail "a bare '\$<nbsp>' shell prompt must stay unknown, got '$out'"
  pass "fm_composer_classify_content: a no-break-space-padded bare shell prompt stays unknown"
}

# --- Layer 2: the tmux composer reader on the real captured bytes ------------

test_composer_state_reads_real_claude_line_empty() {
  local dir fb out
  dir="$TMP_ROOT/reader"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$CLAUDE_LINE" FM_FAKE_CY=0 \
        fm_tmux_composer_state fakepane)
  [ "$out" = empty ] \
    || fail "fm_tmux_composer_state on the real captured claude working line must read empty, got '$out'"
  pass "fm_tmux_composer_state: claude's real '❯<nbsp>' working composer reads empty"
}

test_composer_state_still_pending_on_real_text_with_nbsp() {
  local dir fb line out
  dir="$TMP_ROOT/reader-pending"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  # A human mid-typing, whose text happens to contain a no-break space, is pending.
  line=$(printf '\033[37m\xe2\x9d\xaf\xc2\xa0ship it now\033[39m')
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$line" FM_FAKE_CY=0 \
        fm_tmux_composer_state fakepane)
  [ "$out" = pending ] \
    || fail "fm_tmux_composer_state on real text containing a no-break space must read pending, got '$out'"
  pass "fm_tmux_composer_state: real typed text with an embedded no-break space stays pending"
}

# --- Layer 3: the submit loop no longer reports a false swallow --------------

test_submit_loop_not_false_pending_on_nbsp_composer() {
  local dir fb out
  dir="$TMP_ROOT/submit"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  # The composer has already cleared to claude's '❯<nbsp>' idle line: the submit
  # landed. The verify loop must read that as `empty`, not the false `pending`
  # that fm-send turns into exit 1 ("Enter swallowed").
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$CLAUDE_LINE" FM_FAKE_CY=0 \
        fm_tmux_submit_enter_core fakepane 3 0)
  [ "$out" = empty ] \
    || fail "fm_tmux_submit_enter_core against a cleared '❯<nbsp>' composer must return empty, got '$out'"
  pass "fm_tmux_submit_enter_core: a cleared no-break-space composer is not a false swallow"
}

# --- Layer 4: the full fm-send exit code the incident surfaced through -------

test_fm_send_succeeds_when_composer_clears_to_nbsp() {
  local dir fb home err rc
  dir="$TMP_ROOT/fmsend"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  home="$dir/home"; mkdir -p "$home/state"; err="$dir/send.err"
  fm_write_meta "$home/state/lane-nbsp.meta" "window=sess:fm-lane-nbsp" "kind=ship" "harness=claude"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_STYLED="$CLAUDE_LINE" FM_FAKE_CY=0 FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$SEND" fm-lane-nbsp "steer the crewmate" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "fm-send must succeed when the claude composer cleared to '❯<nbsp>'"
  assert_not_contains "$(cat "$err")" "Enter swallowed" "fm-send must not report a false Enter swallow"
  pass "fm-send: a genuinely-submitted steer to a claude composer no longer exits 1"
}

test_classify_nbsp_padded_agent_glyph_is_empty
test_classify_narrow_nbsp_padded_glyph_is_empty
test_classify_nbsp_only_is_empty
test_classify_nbsp_with_real_text_stays_pending
test_bare_shell_prompt_with_nbsp_stays_unknown
test_composer_state_reads_real_claude_line_empty
test_composer_state_still_pending_on_real_text_with_nbsp
test_submit_loop_not_false_pending_on_nbsp_composer
test_fm_send_succeeds_when_composer_clears_to_nbsp
