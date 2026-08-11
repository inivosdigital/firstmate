#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2088
# Behavior tests for the watcher-arm PreToolUse seatbelt (docs/arm-pretool-check.md).
#
# bin/fm-arm-command-policy.mjs is the single owner of command classification.
# This suite drives the stable shell transport through all five harness entry
# forms and asserts the per-harness wiring contract without spawning a harness.
# Empirical harness evidence lives in docs/arm-pretool-check.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-arm-pretool-check.sh"
POLICY="$ROOT/bin/fm-arm-command-policy.mjs"

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
}

matrix_case A01 allow 'bin/fm-watch-arm.sh'
matrix_case A02 allow './bin/fm-watch-arm.sh --restart'
matrix_case A03 allow 'exec bin/fm-watch-arm.sh'
matrix_case A04 allow 'bin/fm-watch-checkpoint.sh --seconds 180'
matrix_case A05 allow 'exec bin/fm-watch-checkpoint.sh --seconds 180'
matrix_case A06 allow "$ROOT/bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A07 allow "cd '$ROOT'; exec bin/fm-watch-arm.sh"
matrix_case A08 allow "cd '../firstmate'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A09 allow "export FM_HOME='$ROOT'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A10 allow 'source config/x-mode.env; bin/fm-watch-checkpoint.sh --seconds 180'
matrix_case A11 allow "source 'config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A12 allow "source './config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A13 allow "source '$ROOT/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A14 allow "[ -f 'config/x-mode.env' ] && source 'config/x-mode.env'; exec bin/fm-watch-arm.sh"
matrix_case A15 allow "cd $ROOT && exec bin/fm-watch-arm.sh"
matrix_case A16 allow "export FM_HOME=$ROOT && bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A17 allow $'source "config/x-mode.env"\nbin/fm-watch-checkpoint.sh --seconds 180'

matrix_case R01 allow "pgrep -fl '/bin/fm-watch.sh' || true"
matrix_case R02 allow "ps aux | rg '/bin/fm-watch.sh'"
matrix_case R03 allow "rg -n 'fm-watch-arm.sh &' docs tests"
matrix_case R04 allow "rg -n 'bin/fm-watch-arm.sh; echo bad' docs"
matrix_case R05 allow "git grep 'fm-watch-checkpoint.sh && echo bad'"
matrix_case R06 allow "sed -n '/fm-watch-checkpoint.sh/p' docs/arm-pretool-check.md"
matrix_case R07 allow 'assert_contains "$content" '\''fm-watch-arm.sh &'\'''
matrix_case R08 allow "printf '%s\\n' 'bin/fm-watch-checkpoint.sh --seconds 180 >/tmp/out'"
matrix_case R09 allow "tmux send-keys -t isolated-pi-lab 'bin/fm-watch-arm.sh &' Enter"
matrix_case R10 allow "tmux send-keys -t isolated-pi-lab \"printf '%s\\n' 'bin/fm-watch-arm.sh &'\"; tmux send-keys -t isolated-pi-lab Enter"
matrix_case R11 allow "python3 -c 'print(\"bin/fm-watch-arm.sh; echo data\")'"
matrix_case R12 allow "bash -lc \"rg -n 'fm-watch-arm.sh &' docs\""
matrix_case R13 allow "echo 'pkill -f fm-watch'"
matrix_case R14 allow "rg -n 'pkill -f fm-watch' docs tests"
matrix_case R15 allow "echo ok # bin/fm-watch-arm.sh &"
matrix_case R16 allow $'# bin/fm-watch-arm.sh &\necho ok'
matrix_case R17 allow "printf '%s\\n' 'fm-watch.sh; a && b || c > out' | sed -n '1p'"
matrix_case R18 allow "sh -c 'tmux send-keys -t lab \"bin/fm-watch-arm.sh &\" Enter'"
matrix_case R19 allow "eval 'printf \"%s\\n\" \"bin/fm-watch-arm.sh &\"'"
matrix_case R20 allow $'until [ -f /tmp/fm-none ]; do\ncat <<\'EOF\'\npkill -f fm-watch\nEOF\ndone'

matrix_case D01 deny 'bin/fm-watch-arm.sh &'
matrix_case D02 deny 'nohup bin/fm-watch-arm.sh'
matrix_case D03 deny 'bin/fm-watch-arm.sh & disown'
matrix_case D04 deny '(bin/fm-watch-arm.sh) &'
matrix_case D05 deny "bash -lc 'bin/fm-watch-arm.sh &'"
matrix_case D06 deny '$(bin/fm-watch-arm.sh)'
matrix_case D07 deny 'echo "$(bin/fm-watch-checkpoint.sh --seconds 180)"'
matrix_case D08 deny 'cat <(bin/fm-watch-arm.sh)'
matrix_case D09 deny 'bin/fm-watch-arm.sh >/tmp/out'
matrix_case D10 deny 'bin/fm-watch-checkpoint.sh --seconds 180 </dev/null'
matrix_case D11 deny 'bin/fm-watch-arm.sh 2>&1 | head -2'
matrix_case D12 deny 'bin/fm-watch-arm.sh | cat'
matrix_case D13 deny 'bin/fm-watch-checkpoint.sh --seconds 180 | timeout 1 cat'
matrix_case D14 deny 'echo before; bin/fm-watch-arm.sh'
matrix_case D15 deny 'bin/fm-watch-checkpoint.sh --seconds 180; echo after'
matrix_case D16 deny 'true && bin/fm-watch-arm.sh'
matrix_case D17 deny 'bin/fm-watch-checkpoint.sh --seconds 180 || true'
matrix_case D18 deny $'bin/fm-watch-arm.sh\nbin/fm-watch-checkpoint.sh --seconds 180'
matrix_case D19 deny "pkill -f '/bin/fm-watch.sh'"
matrix_case D20 deny "command pkill -f '/bin/fm-watch.sh'"
matrix_case D21 deny "/usr/bin/pkill -f '/bin/fm-watch.sh'"
matrix_case D22 deny "sudo pkill -f '/bin/fm-watch.sh'"
matrix_case D23 deny 'kill "$(pgrep -f '\''/bin/fm-watch.sh'\'')"'
matrix_case D24 deny $'bin/fm-watc\\\nh-arm.sh &'
matrix_case D25 deny 'sudo -u root bin/fm-watch-arm.sh &'
matrix_case D26 deny 'env -u PATH bin/fm-watch-arm.sh &'
matrix_case D27 deny "bash -c \$'bin/fm-watch-arm.sh &'"
matrix_case D28 deny $'bash <<\'EOF\'\nbin/fm-watch-arm.sh &\nEOF'
matrix_case D29 deny "WATCHER='bin/fm-watch-arm.sh &' bash -c 'eval \"\$WATCHER\"'"
matrix_case D30 deny "p=\$(pgrep -f '/bin/fm-watch.sh'); kill \"\$p\""
matrix_case D31 deny "env -S 'bin/fm-watch-arm.sh &'"
matrix_case D32 deny "env --split-string='$ROOT/bin/fm-watch-arm.sh &'"
matrix_case D33 deny 'bin/fm-"watch-arm.sh" &'
matrix_case D34 deny "WATCHER='bin/fm-watch-arm.sh'; \"\$WATCHER\" &"
matrix_case D35 deny "bash -c -- 'bin/fm-watch-arm.sh &'"
matrix_case D36 deny 'bash bin/fm-watch-arm.sh &'
matrix_case D37 deny '. bin/fm-watch-arm.sh &'
matrix_case D38 deny "bash <<< 'bin/fm-watch-arm.sh &'"
matrix_case D39 deny "eval 'true;' 'bin/fm-watch-arm.sh &'"
matrix_case D40 deny 'timeout 30 bin/fm-watch-arm.sh &'
matrix_case D41 deny 'gtimeout 30 bin/fm-watch-arm.sh &'
matrix_case D42 deny 'bin/fm-watch-{arm,checkpoint}.sh &'
matrix_case D43 deny 'bin/fm-watch-arm.sh* &'
matrix_case D44 deny "pattern='fm-watch'; pkill -f \"\$pattern\""
matrix_case D45 deny "p=\$(pgrep -f '/bin/fm-watch.sh'); q=\$p; kill \$q"
matrix_case D46 deny '$FM_HOME/bin/fm-watch-arm.sh &'
matrix_case D47 deny '$HOME/firstmate/bin/fm-watch-arm.sh | cat'
matrix_case D48 deny '~/firstmate/bin/fm-watch-arm.sh &'
matrix_case D49 deny 'bin/fm-watch.sh'
matrix_case D50 deny '$FM_HOME/bin/fm-watch.sh'
matrix_case D51 deny '~/firstmate/bin/fm-watch.sh --restart'
matrix_case D52 deny "bin/fm-\$'\x77'atch-arm.sh &"
matrix_case D53 deny 'bin/fm-$"watch"-arm.sh &'
matrix_case D54 deny 'bin/fm-watch-$"arm".sh &'
matrix_case D55 deny 'while true; do pkill -f fm-watch; done'
matrix_case D56 deny 'for x in 1; do pkill -f fm-watch; done'
matrix_case D57 deny 'case x in x) pkill -f fm-watch ;; esac'
matrix_case D58 deny 'until false; do kill $(pgrep -f fm-watch); done'
matrix_case D59 deny 'if true; then pkill -f fm-watch; fi'
matrix_case D60 deny $'until false; do\nbash <<\'EOF\'\npkill -f fm-watch\nEOF\ndone'

matrix_case E01 allow "bin/fm-watch-checkpoint.sh --seconds '180;still-one-arg'"
matrix_case E02 allow "bin/fm-watch-checkpoint.sh --label 'fm-watch-arm.sh; literal argument'"
matrix_case E03 allow 'bin/fm-watch-arm.sh # output > file &'
matrix_case E04 allow $'# setup comment with fm-watch.sh; && >\nsource "config/x-mode.env"\nbin/fm-watch-checkpoint.sh --seconds 180'
matrix_case E05 deny "FM_HOME=$ROOT bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case E06 deny "env FM_HOME=$ROOT bin/fm-watch-arm.sh"
matrix_case E07 deny "source '/tmp/not-firstmate/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case E08 deny "bash -lc 'bin/fm-watch-checkpoint.sh --seconds 180'"
matrix_case E09 deny '(bin/fm-watch-checkpoint.sh --seconds 180)'
matrix_case E10 deny "eval 'bin/fm-watch-arm.sh &'"
matrix_case E11 deny "exec bash -lc 'bin/fm-watch-arm.sh &'"
matrix_case E12 allow 'bash -lc "$WATCHER_COMMAND" # fm-watch-arm.sh'
matrix_case E13 allow "printf '%s\\n' 'argument has ; and fm-watch-arm.sh and &&'"
matrix_case E14 allow '$FM_HOME/bin/fm-teardown.sh &'
matrix_case E15 allow '$FM_HOME/bin/fm-watch-arm.sh'
matrix_case E16 allow '~/firstmate/bin/fm-watch-checkpoint.sh --seconds 180'
matrix_case E17 allow 'for f in 1; do echo fm-watch; done'

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-arm-policy-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")
trap fm_test_cleanup EXIT

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi)
      "$CHECK" --command "$cmd" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[(watcher-(background|pipeline|redirection|bundled|nested|direct)|broad-watcher-kill|unclassifiable-protected-command)\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry a stable reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
    pass "matrix ${MATRIX_IDS[$i]}: ${MATRIX_EXPECTED[$i]} through all five entry forms"
  done
}

assert_policy() {
  local id=$1 expected=$2 command=$3 output
  output=$(node "$POLICY" --root "$ROOT" --home "$ROOT" --command "$command") \
    || fail "$id direct policy invocation failed"
  case "$output" in
    "$expected"|"$expected"$'\t'*) : ;;
    *) fail "$id direct policy expected $expected, got: $output" ;;
  esac
  pass "direct policy $id: $expected"
}

test_direct_policy_contract() {
  local heredoc_data heredoc_watcher
  assert_policy direct-data-pkill allow "echo 'pkill -f fm-watch'"
  assert_policy direct-broad-pkill $'deny\tbroad-watcher-kill' "pkill -f '/bin/fm-watch.sh'"
  assert_policy direct-loop-broad-pkill $'deny\tbroad-watcher-kill' 'while true; do pkill -f fm-watch; done'
  assert_policy direct-loop-broad-kill-pgrep $'deny\tbroad-watcher-kill' 'until false; do kill $(pgrep -f fm-watch); done'
  assert_policy direct-loop-no-kill-allowed allow 'for f in 1; do echo fm-watch; done'
  assert_policy direct-pipeline $'deny\twatcher-pipeline' 'bin/fm-watch-arm.sh | cat'
  assert_policy direct-leading-redirection $'deny\twatcher-redirection' '>/tmp/out bin/fm-watch-arm.sh'
  assert_policy direct-unclassifiable $'deny\tunclassifiable-protected-command' "bin/fm-watch-arm.sh 'unterminated"
  assert_policy direct-unsupported $'deny\tunclassifiable-protected-command' 'if true; then bin/fm-watch-arm.sh; fi'
  assert_policy direct-constructed-payload $'deny\twatcher-nested' "WATCHER='bin/fm-watch-arm.sh &'; bash -lc \"\$WATCHER\""
  assert_policy direct-parameter-export allow 'export FM_HOME=${HOME}; bin/fm-watch-checkpoint.sh --seconds 180'
  assert_policy direct-expanded-arm-blessed allow '$FM_HOME/bin/fm-watch-arm.sh'
  assert_policy direct-expanded-arm-background $'deny\twatcher-background' '$FM_HOME/bin/fm-watch-arm.sh &'
  assert_policy direct-expanded-arm-pipeline $'deny\twatcher-pipeline' '$HOME/firstmate/bin/fm-watch-arm.sh | cat'
  assert_policy direct-watch-not-blessed $'deny\twatcher-direct' 'bin/fm-watch.sh'
  assert_policy direct-watch-expanded $'deny\twatcher-direct' '$FM_HOME/bin/fm-watch.sh'
  assert_policy direct-watch-safe-shape $'deny\twatcher-direct' 'cd /tmp; bin/fm-watch.sh'
  heredoc_data=$'cat <<\'EOF\'\nbin/fm-watch-arm.sh &\nEOF'
  heredoc_watcher=$'bin/fm-watch-arm.sh <<\'EOF\'\ndata only\nEOF'
  assert_policy direct-heredoc-data allow "$heredoc_data"
  assert_policy direct-heredoc-watcher $'deny\twatcher-redirection' "$heredoc_watcher"
}

# --- block constructs --------------------------------------------------------
#
# The classifier models `if`, `for`, `while`, `until`, and `case`, so inside one
# the same command-position analysis applies as outside it: a forbidden pattern
# that is only inert heredoc data is allowed, and every executed broad kill is
# denied. Block syntax the classifier cannot fit into a well-formed construct
# stays on the conservative raw-match path instead.

BLOCK_SHAPES=(until while for if case)

block_wrap() {
  local shape=$1 body=$2
  case "$shape" in
    until) printf 'until false; do\n%s\ndone' "$body" ;;
    while) printf 'while false; do\n%s\ndone' "$body" ;;
    for) printf 'for x in 1; do\n%s\ndone' "$body" ;;
    if) printf 'if true; then\n%s\nfi' "$body" ;;
    case) printf 'case x in\nx)\n%s\n;;\nesac' "$body" ;;
    *) fail "unknown block shape: $shape" ;;
  esac
}

test_block_construct_inert_data_allowed() {
  local shape data
  data=$'cat <<\'EOF\'\npkill -f fm-watch\nEOF'
  assert_policy block-none-cat-heredoc allow "$data"
  for shape in "${BLOCK_SHAPES[@]}"; do
    assert_policy "block-$shape-cat-heredoc" allow "$(block_wrap "$shape" "$data")"
  done
  assert_policy block-until-python-heredoc allow "$(block_wrap until $'python3 <<\'EOF\'\npkill -f fm-watch\nEOF')"
  # A here-document body is data only when the command consuming it can be named
  # and does nothing else with it. Piping it into a shell or storing it in a file
  # both put the body back in play, so both stay refused.
  assert_policy block-until-heredoc-into-shell $'deny\tbroad-watcher-kill' "$(block_wrap until $'cat <<\'EOF\' | bash\npkill -f fm-watch\nEOF')"
  assert_policy block-until-heredoc-to-file $'deny\tbroad-watcher-kill' "$(block_wrap until $'cat <<\'EOF\' > /tmp/o\npkill -f fm-watch\nEOF')"
  # Quoted text is an argument to a command that runs, not a body the parser has
  # identified as data, so it keeps the verdict it has always had inside a block.
  assert_policy block-until-quoted-data $'deny\tbroad-watcher-kill' "$(block_wrap until "echo 'pkill -f fm-watch'")"
}

# The defect this suite missed in its first round: a name bound in one part of a
# construct and used in another. Wrapping a whole body in one construct cannot
# reach it, because the binding and the use travel together.
test_block_construct_binding_outlives_its_branch() {
  # A sibling branch does not clear a binding the taken branch made.
  assert_policy dataflow-if-else-pid $'deny\tbroad-watcher-kill' 'if true; then P=$(pgrep -f fm-watch); else P=1; fi; kill $P'
  assert_policy dataflow-if-else-pattern $'deny\tbroad-watcher-kill' 'if [ -n "$X" ]; then Q=fm-watch; else Q=none; fi; pkill -f $Q'
  assert_policy dataflow-elif-pattern $'deny\tbroad-watcher-kill' 'if false; then Q=none; elif true; then Q=fm-watch; else Q=none; fi; pkill -f $Q'
  assert_policy dataflow-case-pattern $'deny\tbroad-watcher-kill' 'case x in a) Q=fm-watch ;; *) Q=none ;; esac; pkill -f $Q'
  assert_policy dataflow-if-else-protected $'deny\tunclassifiable-protected-command' 'if true; then A=bin/fm-watch.sh; else A=x; fi; $A'
  assert_policy dataflow-if-else-protected-background $'deny\tunclassifiable-protected-command' 'if true; then A=bin/fm-watch.sh; else A=x; fi; $A &'
  assert_policy dataflow-if-else-protected-redirect $'deny\tunclassifiable-protected-command' 'if true; then A=bin/fm-watch-arm.sh; else A=x; fi; $A > /tmp/o'
  assert_policy dataflow-case-protected $'deny\tunclassifiable-protected-command' 'case x in a) S=bin/fm-watch.sh ;; *) S=true ;; esac; bash $S'
  # A later assignment does not clear an earlier one either.
  assert_policy dataflow-reassigned-pattern $'deny\tbroad-watcher-kill' 'if true; then Q=fm-watch; fi; Q=none; pkill -f $Q'
  # Inside a loop body the last line has already run by the time the first line
  # runs again, so a use that textually precedes its definition still sees it.
  assert_policy dataflow-loop-carried-pid $'deny\tbroad-watcher-kill' 'while true; do kill $P; P=$(pgrep -f fm-watch); done'
  assert_policy dataflow-loop-carried-pattern $'deny\tbroad-watcher-kill' 'while true; do pkill -f $Q; Q=fm-watch; done'
  assert_policy dataflow-loop-carried-protected $'deny\tunclassifiable-protected-command' 'while true; do $A; A=bin/fm-watch.sh; done'
  # A value routed through a second name carries the binding with it.
  assert_policy dataflow-indirect $'deny\tbroad-watcher-kill' 'if true; then Q=fm-watch; else Q=none; fi; R=$Q; pkill -f $R'
}

# Values arriving from input the parser does not follow. Unknown has to count as
# a watcher value whenever the program names a watcher, never as a safe one.
test_block_construct_unmodelled_input_is_tainted() {
  assert_policy dataflow-pgrep-into-while $'deny\tbroad-watcher-kill' 'pgrep -f fm-watch | while read -r p; do kill $p; done'
  assert_policy dataflow-process-substitution $'deny\tbroad-watcher-kill' 'while read -r p; do kill $p; done < <(pgrep -f fm-watch)'
  assert_policy dataflow-here-string $'deny\tbroad-watcher-kill' 'while read -r p; do kill $p; done <<< $(pgrep -f fm-watch)'
  assert_policy dataflow-heredoc-on-done $'deny\tbroad-watcher-kill' $'while read -r l; do bash -c "$l"; done <<EOF\npkill -f fm-watch\nEOF'
  assert_policy dataflow-eval-from-branch $'deny\tbroad-watcher-kill' 'if true; then C="pkill -f fm-watch"; else C=true; fi; eval $C'
  # A read loop over unrelated process ids names no watcher, so it stays allowed:
  # the taint follows the watcher mention, not the shape.
  assert_policy dataflow-read-loop-unrelated allow 'while read -r p; do kill $p; done < /tmp/pids'
}

test_block_construct_executed_kill_denied() {
  local shape
  for shape in "${BLOCK_SHAPES[@]}"; do
    assert_policy "block-$shape-pkill" $'deny\tbroad-watcher-kill' "$(block_wrap "$shape" 'pkill -f fm-watch')"
    assert_policy "block-$shape-kill-pgrep" $'deny\tbroad-watcher-kill' "$(block_wrap "$shape" 'kill $(pgrep -f fm-watch)')"
  done
  assert_policy block-nested-while-if $'deny\tbroad-watcher-kill' "$(block_wrap while "$(block_wrap if 'pkill -f fm-watch')")"
  assert_policy block-nested-for-case $'deny\tbroad-watcher-kill' "$(block_wrap for "$(block_wrap case 'pkill -f fm-watch')")"
  assert_policy block-elif-branch $'deny\tbroad-watcher-kill' 'if false; then echo a; elif true; then pkill -f fm-watch; fi'
  assert_policy block-else-branch $'deny\tbroad-watcher-kill' 'if false; then echo a; else pkill -f fm-watch; fi'
  assert_policy block-case-alternation $'deny\tbroad-watcher-kill' 'case x in a|b) pkill -f fm-watch ;; esac'
  assert_policy block-case-second-arm $'deny\tbroad-watcher-kill' 'case x in a) echo a ;; b) pkill -f fm-watch ;; esac'
  # A loop variable inherits the watcher bindings of the list it iterates.
  assert_policy block-for-variable-pid $'deny\tbroad-watcher-kill' 'for p in $(pgrep -f fm-watch); do kill $p; done'
  assert_policy block-for-variable-pattern $'deny\tbroad-watcher-kill' 'for p in fm-watch; do pkill -f $p; done'
}

test_block_construct_shell_heredoc_denied() {
  local shape
  assert_policy block-none-bash-heredoc $'deny\tbroad-watcher-kill' $'bash <<\'EOF\'\npkill -f fm-watch\nEOF'
  for shape in "${BLOCK_SHAPES[@]}"; do
    assert_policy "block-$shape-bash-heredoc" $'deny\tbroad-watcher-kill' \
      "$(block_wrap "$shape" $'bash <<\'EOF\'\npkill -f fm-watch\nEOF')"
  done
  assert_policy block-until-sh-heredoc $'deny\tbroad-watcher-kill' "$(block_wrap until $'sh <<\'EOF\'\npkill -f fm-watch\nEOF')"
}

test_block_construct_protected_execution_unclassifiable() {
  local shape
  for shape in "${BLOCK_SHAPES[@]}"; do
    assert_policy "block-$shape-arm" $'deny\tunclassifiable-protected-command' "$(block_wrap "$shape" 'bin/fm-watch-arm.sh')"
  done
  assert_policy block-after-if $'deny\tunclassifiable-protected-command' 'if true; then echo hi; fi; bin/fm-watch-arm.sh'
  assert_policy block-for-list-arm $'deny\tunclassifiable-protected-command' 'for x in $(bin/fm-watch-arm.sh); do echo x; done'
}

test_block_construct_malformed_falls_back() {
  assert_policy block-unclosed-loop $'deny\tbroad-watcher-kill' 'while true; do pkill -f fm-watch'
  assert_policy block-stray-done $'deny\tbroad-watcher-kill' 'done; pkill -f fm-watch'
  assert_policy block-stray-esac $'deny\tbroad-watcher-kill' 'esac; pkill -f fm-watch'
  assert_policy block-missing-arm-terminator $'deny\tbroad-watcher-kill' 'case x in x) pkill -f fm-watch esac'
  assert_policy block-arithmetic-for $'deny\tbroad-watcher-kill' 'for ((i=0;i<3;i++)); do pkill -f fm-watch; done'
  assert_policy block-quoted-keyword $'deny\tbroad-watcher-kill' "'while' true; do pkill -f fm-watch; done"
  assert_policy block-unterminated-quote $'deny\tbroad-watcher-kill' "while true; do pkill -f fm-watch 'unterminated"
  assert_policy block-case-subject-substitution $'deny\tbroad-watcher-kill' 'case $(echo x) in x) pkill -f fm-watch ;; esac'
  assert_policy block-case-pattern-substitution $'deny\tbroad-watcher-kill' 'case x in $(echo x)) pkill -f fm-watch ;; esac'
  # An arm terminator or pattern close with no `case` around it is malformed, so
  # it is refused rather than treated as an ordinary list separator.
  assert_policy block-stray-arm-terminator $'deny\tunclassifiable-protected-command' 'bin/fm-watch-arm.sh ;;'
  assert_policy block-stray-pattern-close $'deny\tunclassifiable-protected-command' 'bin/fm-watch-arm.sh )'
  assert_policy block-stray-terminator-kill $'deny\tbroad-watcher-kill' ';; pkill -f fm-watch'
}

# Wrapping a body in a block construct must never be more permissive than the
# same body at top level. This is the guarantee that replaces the raw
# whole-string fallback these constructs used to reach unconditionally.
test_block_construct_never_more_permissive() {
  local body shape bare wrapped
  local bodies=(
    'pkill -f fm-watch'
    'kill $(pgrep -f fm-watch)'
    'sudo pkill -f fm-watch'
    'command pkill -f fm-watch'
    '/usr/bin/pkill -f fm-watch'
    'p=$(pgrep -f fm-watch); kill "$p"'
    'pattern=fm-watch; pkill -f "$pattern"'
    'bin/fm-watch.sh'
    'bin/fm-watch-arm.sh | cat'
    'nohup bin/fm-watch-arm.sh'
  )
  for body in "${bodies[@]}"; do
    bare=$(node "$POLICY" --root "$ROOT" --home "$ROOT" --command "$body") \
      || fail "symmetry corpus body failed to classify: $body"
    case "$bare" in
      deny*) : ;;
      # Guards the corpus itself: a body that stopped denying at top level would
      # make every wrapped assertion below pass without testing anything.
      *) fail "symmetry corpus body must deny at top level, got '$bare': $body" ;;
    esac
    for shape in "${BLOCK_SHAPES[@]}"; do
      wrapped=$(node "$POLICY" --root "$ROOT" --home "$ROOT" --command "$(block_wrap "$shape" "$body")") \
        || fail "symmetry wrapped body failed to classify: $shape / $body"
      case "$wrapped" in
        deny*) : ;;
        *) fail "$shape wrapping made '$body' more permissive: $wrapped" ;;
      esac
    done
  done
  pass "block constructs are never more permissive than the same body at top level"
}

# Splits a two-part body so the binding and the use sit in different parts of the
# construct: sibling arms, before and after it, or reversed inside a loop. The
# whole-body wrapper above keeps them together and so cannot reach this class.
block_split_wrap() {
  local shape=$1 bind=$2 use=$3
  case "$shape" in
    if-else) printf 'if true; then\n%s\nelse\nZ=none\nfi\n%s' "$bind" "$use" ;;
    if-else-other) printf 'if true; then\nZ=none\nelse\n%s\nfi\n%s' "$bind" "$use" ;;
    case-arm) printf 'case x in\na)\n%s\n;;\n*)\nZ=none\n;;\nesac\n%s' "$bind" "$use" ;;
    then-reassign) printf 'if true; then\n%s\nfi\nZ=none\n%s' "$bind" "$use" ;;
    loop-reversed) printf 'while true; do\n%s\n%s\ndone' "$use" "$bind" ;;
    loop-forward) printf 'while true; do\n%s\n%s\ndone' "$bind" "$use" ;;
    *) fail "unknown split shape: $shape" ;;
  esac
}

# The same never-more-permissive guarantee for split bodies. Each pair denies at
# top level as a plain sequence, so every distribution of it must deny too.
test_block_construct_split_binding_never_more_permissive() {
  local pair bind use shape bare wrapped
  local -a splits=(
    'Z=fm-watch|pkill -f $Z'
    'Z=$(pgrep -f fm-watch)|kill $Z'
    'Z="fm-watch"|pkill -f "$Z"'
    'Z=bin/fm-watch.sh|$Z'
    'Z=bin/fm-watch-arm.sh|bash $Z'
    'Z=bin/fm-watch.sh|exec $Z'
  )
  local -a shapes=(if-else if-else-other case-arm then-reassign loop-reversed loop-forward)
  for pair in "${splits[@]}"; do
    bind=${pair%%|*}
    use=${pair#*|}
    bare=$(node "$POLICY" --root "$ROOT" --home "$ROOT" --command "$bind; $use") \
      || fail "split corpus pair failed to classify: $bind; $use"
    case "$bare" in
      deny*) : ;;
      # Guards the corpus: a pair that stopped denying as a plain sequence would
      # make every distribution below pass without testing anything.
      *) fail "split corpus pair must deny as a sequence, got '$bare': $bind; $use" ;;
    esac
    for shape in "${shapes[@]}"; do
      wrapped=$(node "$POLICY" --root "$ROOT" --home "$ROOT" --command "$(block_split_wrap "$shape" "$bind" "$use")") \
        || fail "split wrapped pair failed to classify: $shape / $bind; $use"
      case "$wrapped" in
        deny*) : ;;
        *) fail "$shape split made '$bind; $use' more permissive: $wrapped" ;;
      esac
    done
  done
  pass "splitting a binding from its use across a construct is never more permissive"
}

# --- CLI parsing -------------------------------------------------------------

test_command_equals_form() {
  "$CHECK" --command='bin/fm-watch-arm.sh &' >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "--command=<val> form must parse the same as --command <val>"
  pass "--command=<val> equals-form parses correctly"
}

test_background_flag_accepted_and_non_gating() {
  local rc_bg rc_nobg
  "$CHECK" --command 'exec bin/fm-watch-arm.sh' --background true >/dev/null 2>&1
  rc_bg=$?
  "$CHECK" --command 'exec bin/fm-watch-arm.sh' >/dev/null 2>&1
  rc_nobg=$?
  [ "$rc_bg" -eq 0 ] || fail "--background true must not change the allow decision on its own, got exit $rc_bg"
  [ "$rc_bg" -eq "$rc_nobg" ] || fail "--background flag must be accepted without altering the decision"
  pass "--background is accepted for interface parity and is never itself a deny signal"
}

test_unknown_flag_errors() {
  "$CHECK" --bogus-flag >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "an unrecognized flag must exit non-zero, not silently allow"
  pass "unknown CLI flag is rejected"
}

# --- stdin JSON mode ----------------------------------------------------------

test_stdin_grok_schema_deny() {
  local out rc
  out=$(printf '%s' '{"toolInput":{"command":"bin/fm-watch-arm.sh &","background":false},"toolName":"run_terminal_command"}' | "$CHECK" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "grok toolInput.command schema must be read and denied, got exit $rc"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1 || fail "stdout must carry Grok's {\"decision\":\"deny\",...} shape: $out"
  pass "stdin grok schema (toolInput.command): denied with Grok-shaped stdout JSON"
}

test_stdin_claude_codex_schema_allow() {
  local rc
  printf '%s' '{"tool_input":{"command":"exec bin/fm-watch-arm.sh"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "claude/codex tool_input.command schema must be read and allowed for the blessed shape, got exit $rc"
  pass "stdin claude/codex schema (tool_input.command): blessed shape allowed"
}

test_stdin_claude_codex_schema_deny() {
  local rc
  printf '%s' '{"tool_input":{"command":"bin/fm-watch-arm.sh &"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "claude/codex tool_input.command schema must be denied for the backgrounded shape, got exit $rc"
  pass "stdin claude/codex schema (tool_input.command): backgrounded shape denied"
}

test_stdin_unrelated_command_allowed() {
  local rc
  printf '%s' '{"tool_input":{"command":"ls -la"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "an unrelated command must pass through allowed, got exit $rc"
  pass "stdin: unrelated command is a fast allow"
}

test_prefilter_is_strict_superset() {
  local rc
  # A command with no fm-watch substring is fast-allowed by the transport
  # prefilter without ever invoking the classifier.
  "$CHECK" --command 'ls -la /bin && echo done' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a command with no fm-watch substring must be fast-allowed, got exit $rc"
  # A deniable protected execution carries the fm-watch bytes, so the prefilter
  # must delegate to the classifier and the deny must survive.
  "$CHECK" --command 'bin/fm-watch-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a deniable fm-watch command, not fast-allow it, got exit $rc"
  # A broad watcher kill also contains the fm-watch bytes and must still deny.
  "$CHECK" --command "pkill -f '/bin/fm-watch.sh'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a broad watcher kill, not fast-allow it, got exit $rc"
  # Obfuscated protected paths lose the literal fm-watch bytes (a line
  # continuation or a quote splits them), yet the classifier reconstructs them.
  # The prefilter normalizes those bytes first, so both must still delegate and
  # deny rather than slip through as a fast allow.
  "$CHECK" --command "$(printf 'bin/fm-watc\\\nh-arm.sh &')" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a line-continuation-split protected path, not fast-allow it, got exit $rc"
  "$CHECK" --command 'bin/fm-"watch-arm.sh" &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a quote-split protected path, not fast-allow it, got exit $rc"
  # A quoting-decoder marker ($' ANSI-C or $" locale) hides the fm-watch bytes
  # from the cheap byte strip but the classifier reconstructs them, so the
  # prefilter must delegate on the marker rather than fast-allow. Without this
  # the byte strip loses the encoded character and slips the command through.
  "$CHECK" --command "bin/fm-\$'\x77'atch-arm.sh &" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate an ANSI-C-encoded protected path, not fast-allow it, got exit $rc"
  "$CHECK" --command 'bin/fm-$"watch"-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a locale-string-encoded protected path, not fast-allow it, got exit $rc"
  # The marker is specifically $ followed by a quote, not any $ expansion: an
  # ordinary $VAR that is not a watcher reference still takes the fast path.
  "$CHECK" --command '$FM_HOME/bin/fm-teardown.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign \$VAR non-watcher command must still fast-allow, got exit $rc"
  "$CHECK" --command 'echo "$HOME/scratch" && ls -la' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign \$HOME command must still fast-allow, got exit $rc"
  # A benign command that only mentions fm-watch as data still reaches the
  # classifier and is allowed there, proving the prefilter owns no verdict.
  "$CHECK" --command "echo 'pkill -f fm-watch'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign fm-watch-substring command must be classified and allowed, got exit $rc"
  pass "transport prefilter is a strict superset: non-fm-watch fast-allows, every fm-watch and quoting-decoder-marker command reaches the classifier"
}

# --- fail-open ----------------------------------------------------------------

test_failopen_empty_stdin() {
  local rc
  printf '' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "empty stdin must fail open (exit 0), got exit $rc"
  pass "fail-open: empty stdin"
}

test_failopen_garbage_stdin() {
  local rc
  printf 'not json at all {{{' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "unparseable stdin must fail open (exit 0), got exit $rc"
  pass "fail-open: unparseable JSON on stdin"
}

test_failopen_missing_jq() {
  local dir fakebin rc real
  dir=$(fm_test_tmproot fm-arm-pretool-check)
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  local tool
  for tool in bash grep sed tr; do
    real=$(command -v "$tool")
    ln -sf "$real" "$fakebin/$tool"
  done
  PATH="$fakebin" bash -c "printf '%s' '{\"tool_input\":{\"command\":\"bin/fm-watch-arm.sh &\"}}' | '$CHECK'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq must fail open (exit 0) rather than crash-deny, got exit $rc"
  pass "fail-open: missing jq on stdin path"
}

test_failopen_missing_node() {
  local dir fakebin rc real tool
  dir=$(fm_test_tmproot fm-arm-pretool-node)
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  for tool in bash dirname; do
    real=$(command -v "$tool")
    ln -sf "$real" "$fakebin/$tool"
  done
  PATH="$fakebin" "$CHECK" --command 'bin/fm-watch-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "missing node must fail open (exit 0), got exit $rc"
  pass "fail-open: missing classifier runtime"
}

# --- --claude output shaping ---------------------------------------------------

test_claude_mode_stdout_empty_on_deny() {
  local out err rc stderr_file
  # Keep stderr capture under TMPDIR so concurrent isolation-proof workers do
  # not share a fixed global /tmp path.
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/fm-arm-pretool-check-claude-stderr.XXXXXX")
  out=$("$CHECK" --claude --command 'bin/fm-watch-arm.sh &' 2>"$stderr_file")
  rc=$?
  err=$(cat "$stderr_file" 2>/dev/null)
  rm -f "$stderr_file"
  [ "$rc" -eq 2 ] || fail "--claude deny must still exit 2, got $rc"
  [ -z "$out" ] || fail "--claude deny must leave stdout EMPTY (Claude Code only honors a stderr-only deny), got: $out"
  printf '%s' "$err" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || fail "--claude deny must put hookSpecificOutput.permissionDecision=deny on stderr: $err"
  pass "--claude: stdout empty, stderr carries hookSpecificOutput deny JSON"
}

test_default_mode_stdout_has_grok_json_on_deny() {
  local out rc
  out=$("$CHECK" --command 'bin/fm-watch-arm.sh &' 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "default deny must exit 2, got $rc"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1 \
    || fail "default (non-claude) deny must put Grok's decision JSON on stdout: $out"
  pass "default mode: stdout carries Grok-shaped decision JSON on deny"
}

test_allow_is_silent_both_modes() {
  local out1 out2
  out1=$("$CHECK" --command 'exec bin/fm-watch-arm.sh' 2>&1)
  out2=$("$CHECK" --claude --command 'exec bin/fm-watch-arm.sh' 2>&1)
  [ -z "$out1" ] || fail "default allow must be silent, got: $out1"
  [ -z "$out2" ] || fail "--claude allow must be silent, got: $out2"
  pass "allow is silent on both stdout and stderr in default and --claude mode"
}

# --- harness wiring: each adapter invokes the shared checker -----------------

# --- shellcheck (belt-and-suspenders; CI/CONTRIBUTING.md also runs this) -----

test_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  shellcheck "$CHECK" >/dev/null 2>&1 || fail "bin/fm-arm-pretool-check.sh is not shellcheck-clean"
  pass "bin/fm-arm-pretool-check.sh is shellcheck-clean"
}

test_full_acceptance_matrix
test_direct_policy_contract
test_block_construct_inert_data_allowed
test_block_construct_binding_outlives_its_branch
test_block_construct_unmodelled_input_is_tainted
test_block_construct_executed_kill_denied
test_block_construct_shell_heredoc_denied
test_block_construct_protected_execution_unclassifiable
test_block_construct_malformed_falls_back
test_block_construct_never_more_permissive
test_block_construct_split_binding_never_more_permissive
test_command_equals_form
test_background_flag_accepted_and_non_gating
test_unknown_flag_errors
test_stdin_grok_schema_deny
test_stdin_claude_codex_schema_allow
test_stdin_claude_codex_schema_deny
test_stdin_unrelated_command_allowed
test_prefilter_is_strict_superset
test_failopen_empty_stdin
test_failopen_garbage_stdin
test_failopen_missing_jq
test_failopen_missing_node
test_claude_mode_stdout_empty_on_deny
test_default_mode_stdout_has_grok_json_on_deny
test_allow_is_silent_both_modes
test_shellcheck_clean
