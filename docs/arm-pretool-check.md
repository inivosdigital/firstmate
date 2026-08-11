# Watcher arm PreToolUse seatbelt

This document is the authoritative human-readable contract for the watcher arm PreToolUse seatbelt.
`bin/fm-arm-command-policy.mjs` is the single semantic owner.
`bin/fm-arm-pretool-check.sh` is only the stable harness transport and output renderer.
The tracked harness adapters forward command text without classifying it.
`bin/fm-arm-command-policy.mjs` is also the sole owner of firstmate's shell classification: it exports the tokenizer and command-position analysis, which the sibling cd-guard seatbelt (`bin/fm-cd-pretool-check.sh`, `docs/cd-guard.md`) reuses instead of duplicating shell lexing.

## Purpose and boundary

A firstmate primary must arm `bin/fm-watch-arm.sh` or run `bin/fm-watch-checkpoint.sh` through an observable harness call.
A shell background operator, pipeline, redirection, wrapper, or unrelated command list can hide failure or let the watcher child die with the tool call.
The seatbelt rejects those command shapes before execution.

This policy is not a post-arm liveness guarantee.
`bin/fm-guard.sh` and `bin/fm-turnend-guard.sh` apply their respective post-arm supervision predicates to the watcher lock and beacon after an allowed call.

The classifier never executes, sources, evaluates, or expands any part of the submitted command.
It tokenizes the bytes and classifies lexical execution positions only.

## Transport and fail-open behavior

`bin/fm-arm-pretool-check.sh` supports these entry forms:

- Stdin JSON at `.tool_input.command` for Claude and Codex.
- Stdin JSON at `.toolInput.command` for Grok.
- `--command <exact string>` for OpenCode, Pi, and pi-signed.
- `--background` as a compatibility-only field that never changes the decision.
- `--claude` to preserve Claude's stderr-only deny requirement.

The wrapper discovers the code root from its own location.
The active firstmate home is `${FM_HOME:-<code-root>}`.
It passes both roots and the exact command string to the Node policy owner.

The wrapper fast-allows a command without invoking the Node policy owner only when the command cannot contain the `fm-watch` byte sequence even after the classifier's decoders run.
The fast path may allow only when both of these hold:

1. The stripped text lacks the `fm-watch` watcher substring, after mirroring the classifier's cheapest byte normalizations - dropping line-continuation and escape backslashes, quotes, and newlines.
2. The raw command carries no quoting-decoder marker: a `$` immediately followed by a single quote (ANSI-C `$'...'`) or a double quote (bash locale `$"..."`).

Any `fm-watch` match or any quoting-decoder marker delegates to the classifier.
Normalizing first keeps this a strict superset: a protected watcher path obfuscated as `fm-watc\<newline>h-arm.sh` or `fm-"watch"-arm.sh` still delegates, and stripping only those non-alphanumeric bytes can never destroy an existing `fm-watch` run.
The quoting-decoder marker closes the case the byte strip cannot: `bin/fm-$'\x77'atch-arm.sh` and `bin/fm-$"watch"-arm.sh` both resolve to `bin/fm-watch-arm.sh` only after the classifier decodes the encoded character, so a cheap byte strip would otherwise lose the `fm-watch` bytes and fast-allow them.
This marker set is coupled to the classifier's decoder set in `bin/fm-arm-command-policy.mjs`: adding any new quote or expansion form the classifier decodes requires extending this marker set in the same change, or the prefilter stops being a strict superset.
The prefilter owns no semantic exception: it can only ever fast-allow a command that is definitely not a watcher command, so it never flips a classification and the classifier remains the single owner of every decision.

The seatbelt's threat model is agent mistakes: no one accidentally writes an ANSI-C- or locale-obfuscated watcher path, and deliberate obfuscation is the post-arm liveness guard's territory.
The marker guard closes the static gap anyway because it is cheap and provable per encoding class.
Tripwire: if a third strict-superset gap is ever found after this marker generalization, that falsifies the "provable per encoding class" claim and the decision flips to Option B - drop the prefilter and always invoke the classifier.
Deeper decode-required obfuscation beyond the coupled marker set stays the classifier's and the post-arm liveness guards' responsibility.

Malformed or empty stdin, invalid JSON, missing `jq` for stdin transport, missing Node, a missing classifier, or an invalid classifier response fail open with exit 0 and no output.
This transport behavior prevents a broken hook from denying every shell tool call.
Malformed or unsupported shell syntax that contains a protected command is a semantic classification result and fails closed.

## Command-position classification

The tokenizer recognizes cooked words with quote provenance, comments, heredoc bodies, shell list operators, pipelines, redirections, command and process substitutions, parenthesized subshells, brace groups, and literal nested execution payloads.
Quoted text, comments, heredoc bodies, and later argument words are data positions unless a recognized execution sink recursively executes them.

A command word in executed position is a protected execution when its normalized path suffix matches one of the protected watcher scripts:

```text
bin/fm-watch-arm.sh          (arm; blessed entry point)
bin/fm-watch-checkpoint.sh   (checkpoint; blessed entry point)
bin/fm-watch.sh              (watch; protected but never blessed)
```

The relative form, the `<code-root>`-anchored absolute form, and any word ending in `/bin/<script>` all resolve to that identity.
Suffix matching recognizes an expanded-path prefix statically, so `$FM_HOME/bin/fm-watch-arm.sh`, `$HOME/firstmate/bin/fm-watch-arm.sh`, and `~/firstmate/bin/fm-watch-arm.sh` are the arm identity.
The classifier never expands the variable or tilde; it matches the literal bytes only.
Static quote forms are cooked before the suffix match, so a command word split by ordinary quotes (`fm-"watch"-arm.sh`), ANSI-C quoting (`fm-$'\x77'atch-arm.sh`), or a bash locale string (`fm-$"watch"-arm.sh`) all resolve to the same identity; this reads the fixed literal bytes as the shell would cook them and never runs an expansion or a command.
This covers statically-visible literal words in command position; opaque dynamic dataflow such as `bash -lc "$WHOLE_COMMAND"` remains out of scope.

`bin/fm-watch.sh` is protected but is not a blessed entry point.
A direct `bin/fm-watch.sh` execution - relative, `<code-root>`-anchored, `$VAR`-prefixed, or `~`-prefixed - always denies with `watcher-direct`, whose reason points the caller at `bin/fm-watch-arm.sh` and `bin/fm-watch-checkpoint.sh`.

The same bytes in an argument, comment, assertion, documentation query, Python string, `printf`, or `tmux send-keys` payload are data and do not make the outer command relevant.

Literal `sh`, `bash`, or `zsh` `-c` payloads and literal `eval` payloads are recursively classified.
A literal nested payload that only runs a data-bearing command is allowed.
A literal nested payload that executes a protected command is denied as `watcher-nested`, even when that inner protected call would be allowed at top level.

Dynamic payloads such as `bash -lc "$WATCHER_COMMAND"` cannot be proven statically and remain the post-arm guard's responsibility.
If the submitted command first constructs a protected literal assignment and then feeds a dynamic value to a recognized shell or `eval` sink, the classifier denies conservatively as `watcher-nested`.

Comments and heredoc bodies are ignored as execution syntax.
An actual protected command with a heredoc still has a redirection and is denied.

## Blessed syntax tree

An allowed watcher program is one linear outer command list with zero or more approved setup nodes followed by exactly one direct protected node.
`bin/fm-watch-arm.sh` and `bin/fm-watch-checkpoint.sh` are the only blessed final nodes, including their expanded-path forms; a `bin/fm-watch.sh` final node is never blessed and denies with `watcher-direct`.

Approved setup nodes are:

- `cd <one path word>`.
- `export NAME=<one shell word>` with no command substitution, process substitution, or redirection.
- `source <x-mode path>` or `. <x-mode path>`.
- `[ -f <x-mode path> ] && source <x-mode path>` and the equivalent dot form.

The allowed x-mode paths are `config/x-mode.env`, `./config/x-mode.env`, and an absolute path that normalizes to `<active-firstmate-home>/config/x-mode.env`.
An absolute x-mode path outside the active home is not an approved setup node.

Approved nodes may be separated by `;`, a real newline, or `&&`.
`&&` is accepted after setup so a failed `cd`, `export`, or source prevents the protected call from running under the wrong setup.

The final protected node may have one immediate `exec` wrapper.
Its arguments are ordinary shell words and may contain quoted semicolons or watcher names.
No other wrapper is approved.

Inline environment assignments, `env`, `sudo`, `nohup`, nested shells, `eval`, subshell groups, substitutions, redirections, pipelines, asynchronous lists, `disown`, unrelated list nodes, block constructs, and unsupported compound syntax are not blessed.
A protected execution reached through an `if` condition or branch, a loop body, or a `case` arm is denied with `unclassifiable-protected-command`, because arming is only ever a standalone final command after approved setup nodes.
That covers a protected path routed through a variable one of those parts binds, such as `if true; then A=bin/fm-watch.sh; else A=x; fi; $A`.

## Broad watcher kills

An actually executed `pkill` command is denied when its parsed pattern arguments target `fm-watch`.
Path-qualified `pkill`, `command pkill`, and `sudo pkill` are recognized.

`kill "$(pgrep -f '/bin/fm-watch.sh')"` is also denied because the executed `kill` consumes an executed watcher-wide `pgrep` substitution.
A standalone read-only `pgrep` is allowed.
Quoted text such as `echo 'pkill -f fm-watch'` is data and is allowed.

Unsupported compound grammar - a construct the classifier does not model - is failed closed for broad kills the same way it is for protected executions.
When the command carries such grammar and its raw bytes reference both a `fm-watch` target and a `pkill` or `kill` verb, the classifier cannot prove which command position the kill occupies, so it denies with `broad-watcher-kill` rather than allowing.
In straight-line grammar the classifier models, command-position analysis is authoritative, so data mentions such as `echo 'pkill -f fm-watch'` remain allowed.
Programs containing block constructs are the exception: they re-run this same check over their executable portion even when the grammar was modelled, which the block-construct section below describes.

### Block constructs

The classifier models `if/then/elif/else/fi`, `for`, `while`, and `until` loops, and `case`, including nesting.
Their conditions, bodies, and arms are analyzed as ordinary commands, so the same command-position rules apply inside a construct as outside it.
An executed kill is denied wherever it sits: `while true; do pkill -f fm-watch; done`, `for x in 1; do pkill -f fm-watch; done`, `case x in x) pkill -f fm-watch ;; esac`, and `until false; do kill $(pgrep -f fm-watch); done` all deny with `broad-watcher-kill`.

Once a program branches or loops, the variable model becomes a may-analysis: it may conclude that a name is possibly dangerous, never that it is safe.
Inside a program containing blocks, a watcher binding accumulates and is never removed, so a sibling `else` or `case` arm cannot clear what another arm bound and a later assignment cannot clear an earlier one.
Every binding the program can make is also in force from its first line, because a loop body's last line has already run by the time its first line runs again.
So `if true; then P=$(pgrep -f fm-watch); else P=1; fi; kill $P` and `while true; do kill $P; P=$(pgrep -f fm-watch); done` both deny, as do their `pkill` and protected-path equivalents.
A `for` loop variable inherits the watcher bindings of the list it iterates, so `for p in $(pgrep -f fm-watch); do kill $p; done` denies through the same executed-`pgrep` rule as its one-line form.
A name read from input the parser does not follow - `read`, a pipeline into a loop, a redirection or process substitution attached to `done`, a here-string - holds an unknown value, and unknown counts as a watcher value whenever the program names a watcher anywhere, which is what denies `pgrep -f fm-watch | while read -r p; do kill $p; done`.
A read loop that names no watcher is unaffected.

Parsing a construct is not the same as understanding it, so a second layer runs behind the analysis.
When a program contains blocks and the analysis has produced no refusal, the unchanged raw check of the conservative path above is re-run over the part of the program that actually runs: the whole command with the text the parser positively identified as data cut out.
That text is here-document bodies whose consuming command reads them, quoted runs handed to a data sink, and comments, which run nowhere at all.
The check itself is not quote-aware or here-document-aware, which would be a cleverer version of the thing it is backing up; the lexer already established which bytes are quoted, which are commented, and which body belongs to which command, and the check reads what is left.

Inert data is allowed on that basis: a forbidden pattern that only ever reaches a `cat` or `python3` here-document body, a comment, or a quoted argument to `echo` is allowed inside a construct exactly as it is outside one, while a `bash` here-document carrying the same bytes is denied in both places.
This matters for the `until` wait idiom, which is the supported way to poll for a condition where chained `sleep` waits are unavailable, and for writing a dangerous command as an example in a comment or a quoted string.

The boundary is what consumes the text.
A here-document body counts as data only when the command consuming it can be named and does nothing else with it, so `cat <<EOF | bash` and `cat <<EOF > /tmp/o` keep their bodies in view.
A quoted run counts as data only when it is an argument, never the command word or a prefix assignment, and only when its command is a bare name from a small allowlist of builtins that print their arguments or ignore them: `echo`, `:`, `true`, and `false`.
That list is an allowlist of data sinks rather than a list of consumers that execute what they are handed, because the executing ones are unbounded, and a name missing from a list of those would be a permit while a name missing from this one is only friction.
`printf` is absent from it: `printf -v NAME` assigns its result instead of printing it, and a list whose entry needs an exception has the wrong membership rule.
The command must be a bare name because the list describes builtins, so `/bin/echo '...'` and `./echo '...'` are whatever sits at those paths and keep their text in view.
So `eval '...'`, `bash -c '...'`, `sh -c '...'`, `sh '...'`, `'pkill' -f fm-watch`, `echo '...' | bash`, `echo '...' > /tmp/o`, `xargs -I{} sh -c '...'`, and any command the parser cannot vouch for all keep their quoted text in view and stay denied.

The word holding a quoted run must itself be literal, not merely unchanged across the run, because a word can assign while it is expanded.
`echo ${P:="fm-watch"}` and `echo $X"fm-watch"` both contain a literal-looking run inside a word that is not literal text, and the command in front of such a word says nothing about that, so neither is cut and `echo "$(pkill -f fm-watch)"` stays denied on the same rule.

A name is the builtin it spells only while nothing has rebound it, so the allowlist is withdrawn from the whole program when the program contains a function definition, `alias`, `unalias`, `enable`, `hash`, `eval`, `source`, `.`, `trap`, an assignment to `PATH` wherever it sits, or a command word the parser cannot read.
Groups are read with the same lexer rather than assumed either way, so `{ alias echo=eval; }` counts and an ordinary `(date)` does not.
A subshell is treated the same as a brace group even though its bindings die with it, because reading it costs one pass and refusing `(alias echo=eval)` costs nothing anyone writes.
Membership follows that rule alone: `export`, `declare`, `set`, and `shopt` are absent because none of them can give a name a new meaning, and a program that sets a variable or a shell option keeps reading its quoted text as text.
This cannot see a definition made before the command runs - a shell that already has `echo` defined as a function will run that function - which is outside what a classifier reading one command string can establish.

Block syntax the scanner cannot fit into a well-formed construct - an unclosed loop, a stray `done` or `esac`, an arithmetic `for`, a substitution in a `case` subject or pattern - keeps the whole command on the conservative path above.
The regression suite pins two guarantees.
Wrapping a body in any of these constructs never produces a more permissive verdict than the same body at top level, and neither does splitting a binding from its use across the construct - into sibling arms, across the construct's end, or reversed inside a loop body.
The second is the one that matters: the first cannot reach a defect that needs the binding and the use in different places.

## Stable reason codes

Every semantic deny includes one stable code in square brackets before its prose reason.

| Code | Meaning |
| --- | --- |
| `watcher-background` | A protected execution is in an asynchronous list or uses `nohup` or `disown`. |
| `watcher-pipeline` | A protected execution participates in any pipeline. |
| `watcher-redirection` | A protected execution uses shell redirection. |
| `watcher-bundled` | The outer command list is not the blessed setup-plus-final tree. |
| `watcher-nested` | A wrapper, group, substitution, nested shell, `eval`, or constructed dynamic payload executes the protected command. |
| `broad-watcher-kill` | An actual broad process kill targets the watcher. |
| `unclassifiable-protected-command` | Malformed or unsupported syntax contains a protected command and cannot be safely classified. |
| `watcher-direct` | A direct `bin/fm-watch.sh` execution; the watcher must be reached through `bin/fm-watch-arm.sh` or `bin/fm-watch-checkpoint.sh`. |

Reason codes are the stable contract for tests and adapters.
Prose may improve without changing adapter behavior.

## Output contract

- Allow returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[code] reason"}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[code] reason"}` to stdout for Grok.
- `--claude` suppresses stdout completely because Claude ignores a PreToolUse deny when stdout is nonempty.
- Codex blocks on exit 2 and displays stderr.
- OpenCode throws only when the checker exits 2.
- Pi and pi-signed return `{block: true}` only when the checker exits 2.

## Harness wiring

| Harness | Exact command field | Adapter behavior on checker exit 2 |
| --- | --- | --- |
| Codex | `.tool_input.command` | The `.codex/hooks.json` command forwards the complete stdin payload and Codex blocks on exit 2. |
| Claude | `.tool_input.command` | `.claude/settings.json` forwards stdin with `--claude`, leaving stdout empty and returning the stderr deny object. |
| Grok | `.toolInput.command` | `.grok/hooks/fm-primary-pretool-check.json` forwards stdin and Grok consumes the stdout `decision=deny` object. |
| OpenCode | `output.args.command` | `.opencode/plugins/fm-primary-pretool-check.js` passes one `--command` argument and throws only for exit 2. |
| Pi / pi-signed | `event.input.command` | `.pi/extensions/fm-primary-turnend-guard.ts` passes one `--command` argument and returns `{block: true}` only for exit 2. |

Grok project hooks require folder trust.
Every shell variable reference in a Grok hook command must carry an inline default such as `${GROK_WORKSPACE_ROOT:-}` because Grok expands the raw hook command before `bash -lc` runs it.
The tracked Grok adapter therefore references `${GROK_WORKSPACE_ROOT:-}` directly instead of assigning and later reading a shell-local `$root` variable.

## Live validation record, 2026-07-09

Validation ran in a git-initialized scratch firstmate-shaped project under this task worktree.
The scratch project contained copies of the modified checker and policy, unchanged tracked adapters, a dummy checkpoint, a dummy arm script, a harmless `tmux` argument-capture fixture, and a private sentinel path.
No modified file was installed into the primary checkout or a live harness configuration.
No live watcher, fleet state, or herdr lifecycle command was used.
The OpenCode interactive check used the dedicated tmux socket `fm-pretool-smoke`.

Harness versions were:

```text
Claude Code 2.1.206
codex-cli 0.144.0
grok 0.2.93 (f00f96316d4b)
OpenCode 1.17.15
Pi 0.80.5
```

Every harness was instructed to issue these exact shell command strings as separate tool calls:

```sh
printf 'UNRELATED_EXECUTED\n'
pgrep -fl '/bin/fm-watch.sh' || true
source '<scratch-project>/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180
tmux send-keys -t isolated-pi-lab "printf '%s\n' 'bin/fm-watch-arm.sh &'"; tmux send-keys -t isolated-pi-lab Enter
bin/fm-watch-arm.sh &
```

The real harness launch commands were:

```sh
claude -p "$PROMPT" --dangerously-skip-permissions --output-format text
codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"
GROK_HOME="$SCRATCH_GROK_HOME" RUST_LOG=xai_grok_hooks=debug GROK_LOG_FILE="$SCRATCH_LOG" grok --trust -p "$PROMPT" --permission-mode bypassPermissions --output-format plain
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode run --print-logs --log-level INFO "$PROMPT"
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts --no-context-files --no-session "$PROMPT"
```

Observed output for the four allowed calls was `UNRELATED_EXECUTED`, a successful read-only `pgrep`, `CHECKPOINT_EXECUTED`, and two `TMUX_ARGS:` lines that preserved the watcher text as data.
Each harness blocked the final command with exit 2 mapped through its native adapter behavior.
The stable reason was `[watcher-background] a protected watcher command cannot run in an asynchronous shell list or through nohup/disown`.
The dummy arm body would have created `<harness>.sentinel` if the denied command executed.
All five sentinel files remained absent.

The Codex transcript showed `PreToolUse Completed` for all three originally reported false-positive shapes and `PreToolUse Blocked` only for the backgrounded arm.
The Grok debug transcript showed four exit-0 results from `project/fm-primary-pretool-check`, then exit 2 with 145 stdout bytes, 214 stderr bytes, and `hook denied` for the backgrounded arm.
OpenCode displayed the four allowed command outputs and then `bin/fm-watch-arm.sh & failed` with the stderr deny object.
Claude and Pi both reported that calls one through four ran and the final call was blocked.

Native supervision paths were also validated in the same scratch project:

- Claude ran `bin/fm-watch-arm.sh --restart` with its native tracked background option and produced `watcher: started pid=<scratch> (scratch)`.
- Grok ran the same exact command with `background: true`, its hook returned exit 0, and the dummy arm produced the same started line.
- Codex ran the foreground checkpoint above and produced `CHECKPOINT_EXECUTED`.
- OpenCode ran in an interactive TUI on `tmux -L fm-pretool-smoke`, reached `session.idle`, and its unchanged watch-arm plugin created the scratch automatic-arm marker.
- Pi loaded both primary extensions, called `fm_watch_arm_pi`, and created the scratch automatic-arm marker.

Every native-path automatic marker was present and every deny sentinel remained absent.

## Automated validation

`tests/fm-arm-pretool-check.test.sh` owns the adversarial acceptance matrix.
Every row runs through Codex-shaped stdin, Claude-shaped stdin, Grok-shaped stdin, OpenCode-shaped CLI, and Pi-shaped CLI entry forms.
The suite also verifies real newline bytes, direct classifier reason codes, comments, heredoc data, block constructs and both their never-more-permissive-than-top-level guarantees, bindings that outlive a branch or travel backwards around a loop, values arriving from unmodelled loop input, inert comments and quoted data against the consumers that execute what they are handed, malformed and unsupported protected syntax, constructed dynamic payloads, malformed transport fail-open behavior, missing runtime fail-open behavior, output shapes, and exact adapter field forwarding plus exit-2 mapping.

Run:

```sh
bash -n bin/fm-arm-pretool-check.sh
shellcheck bin/fm-arm-pretool-check.sh tests/fm-arm-pretool-check.test.sh
node --check bin/fm-arm-command-policy.mjs
tests/fm-arm-pretool-check.test.sh
bin/fm-test-run.sh --all
```
