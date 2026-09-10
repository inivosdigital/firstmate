---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap or network-checks section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET, CREW_DISPATCH invalid, FLEET_SYNC, NETWORK_CHECKS, HOME_SUMMARY, BACKLOG_RECONCILE, SECONDMATE_SYNC, SECONDMATE_LIVENESS, SECONDMATE_HANDOFF, NUDGE_SECONDMATES, CONFIG_REREAD, FMX, SERVICE_FAILED, AUTODEPLOY_FAILED, AUTODEPLOY_INERT, TMP_USAGE_HIGH, TMP_USAGE_INERT, or UPSTREAM_DRIFT - or reports that an interrupted backlog cleanup may have left an endpoint or local copy, or when a standalone bin/fm-bootstrap.sh or bin/fm-startup-network.sh run prints one of those lines.
  A silent bootstrap section, or any other BOOTSTRAP_INFO fact, means no skill load.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Handle each printed line as below, before dispatching work that depends on it.
The line formats themselves are owned by `bin/fm-bootstrap.sh`'s header; this playbook owns the response to actionable lines.
The inline rules in `AGENTS.md` section 3 still bind: detect, then consent, then install - never install anything the captain has not approved in this session - and no work is dispatched until the tools it needs are present and GitHub auth is good.
When any diagnostic needs captain attention, report the plain consequence and requested action using `AGENTS.md` section 9's captain-facing translation contract; do not name the diagnostic label unless the captain needs to paste it into a command or issue.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.sh install <approved tools...>`.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request.
  For `no-mistakes`, this also covers an installed version older than 1.46.0, because this repo's PR gate requires structured pipeline attestation that older builds do not write.
  For any axi-family tool - `gh-axi`, `lavish-axi`, `tasks-axi`, `quota-axi` - an installed version below its floor is a plain upgrade request; [`bin/fm-bootstrap.sh`](../../../bin/fm-bootstrap.sh) owns the floor policy, and never argue the floor down to whatever the home happens to have installed.
  For `tasks-axi`, this additionally covers an installed build that fails the separate feature probe (`bin/fm-tasks-axi-lib.sh` owns the definition); `config/backlog-backend=manual` only suppresses the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not this missing-tool report.
  For `quota-axi`, bootstrap requires it because firstmate reads its current output directly before resolving every crew-dispatch profile array; without it, report the missing requirement and do not choose around an unexamined candidate.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `bin/fm-bootstrap.sh install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `FM_BACKEND` or `config/backend` value is corrected to one of the listed backends.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
  This probe now arrives from the deferred network stage, so it is also how an unreachable network shows up: `gh` cannot validate its token offline and reports the same failure. Confirm reachability before asking the captain to re-authenticate a credential that may be fine.
- `NETWORK_CHECKS: <what did not complete>; rerun <command>` - the deferred network stage itself could not finish, so the checks it names are simply unknown, not failed.
  Rerun the printed command; it is idempotent and re-derives every finding.
  A `hit the ...s bound` line means one of those checks is slow or unreachable - most often a remote secondmate host - and the stage stopped rather than letting it wedge; a `lock was no longer held` line means the session that asked for the sweeps no longer owns them, so leave them to the session that does.
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
- `STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>` - the visible startup-memory budget is not a safe one-line positive decimal file; do not infer the default or propagate it.
  Correct the local primary file, then rerun session start so the normal convergence path can deliver the validated value to secondmate homes.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation (malformed schema, unverified harness name, unknown selector, invalid harness/effort pair, non-boolean `ultracode`, or non-string `ultracode_role`); stop profile-based dispatch, report the actionable error, and require correction rather than falling back around it or selecting a bad profile.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `HOME_SUMMARY: this home has never published state/home-summary.json` or `... has not been republished since <stamp>` - this home's structured summary publication has failed repeatedly, and the line carries the failure count and the newest recorded reason from `state/.home-summary-refresh.log`.
  Publication is deliberately best-effort, so it cannot change another session-start, spawn, teardown, or watcher-poll result, and the watcher runs it detached so a slow attempt cannot delay the liveness beacon.
  Read the named record for the recorded reasons, then reproduce with a direct `bin/fm-home-summary-refresh.sh` (no `--best-effort`, which is what keeps the failure quiet) so the refresh error reaches you.
  A recorded deadline means the complete refresh did not finish inside `FM_HOME_SUMMARY_TIMEOUT`, so inspect lock acquisition and producer completion before validation or publication, and fix the blocked phase rather than raising this load-bearing bound.

- `BOOTSTRAP_INFO: closed the backlog item for <id> after interrupted cleanup; its endpoint or local copy may remain and should be reconciled` - replay closed the item, but the durable close says physical cleanup was interrupted.
  Verify process reaping, the local-copy return, and endpoint closure, then reconcile any surviving resource.
- `BACKLOG_RECONCILE: <id>: recorded backlog close could not be replayed: <reason>` - this session start found a pending-close record but could not land it.
  A valid teardown record proves the close was authorized and recorded, but physical cleanup may be partial: verify process reaping, the local-copy return, and endpoint closure before assuming those resources are gone.
  A validation error means the record cannot be trusted, so do not assume cleanup completed or follow any path or argument stored in it.
  Read the named reason, inspect the marker as inert data when validation failed, fix the record or backlog-file problem, and rerun session start so a valid recorded close replays.
  Never hand-close the item by deleting `state/<id>.backlog-close` - that can discard a completion link the cleanup captured, and the surviving marker prevents the record sweep from starting the item meanwhile.
- `BACKLOG_RECONCILE: <id>: worker record exists but its backlog item could not be read: <reason>` - this home could not determine whether the item matches its worker record.
  Resolve the named backlog read problem and rerun session start; never guess by starting or closing an unreadable item.
- `BACKLOG_RECONCILE: <id>: worker record exists but its backlog item could not be moved to In flight: <reason>` - this home owns a worker whose backlog item is still queued, and the reconciliation could not correct it.
  Until it is corrected, the fleet view reads that worker as work no backlog item owns; resolve the named backlog problem and rerun session start.
- `SECONDMATE_SYNC: secondmate <id>: skipped: <reason>` - secondmate convergence left a live home on its existing checkout because the home was dirty, diverged, unsafe, on the wrong branch, missing its placement-specific target commit, unreachable, or otherwise not fast-forwardable, or because inherited local-material propagation failed; bootstrap continued, but inspect the reason because the secondmate's tracked instructions, inherited settings, or shared captain preferences may be stale after a primary update.
- `SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed after <cause>: <reason>` - the session-start liveness sweep could not guarantee that the registered secondmate is running a real agent process.
  Investigate the reason because that secondmate is not guaranteed live.
- `SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)` - queued work has already left the main dispatchable backlog and remains safe in the named remote route's backlog-format outbox, pending backlog receipt or receiver-wake confirmation.
  Preserve that outbox and rerun `bin/fm-backlog-handoff.sh --resume-pending` after the route or endpoint problem is resolved; never re-add or dispatch the items from the main backlog.
  An unsafe-outbox variant requires path and file-type inspection before any retry.
- `NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>` - secondmate convergence changed a running home's loaded instructions or inherited config, but the deterministic `fm-send.sh fm-<id>` re-read nudge failed.
  Inspect the reason, keep the pending marker under `state/.secondmate-nudge-pending/` intact, and rerun session start after the endpoint or metadata issue is fixed so bootstrap can retry the exact same marked send on the same local or remote route.
- `CONFIG_REREAD: secondmate <id>: send failed: <reason>` - the primary already pushed changed inherited config (`config/*`) into a live secondmate's own home, but could not confirm the secondmate was notified to re-read the exact new bytes this cycle.
  The reason names the failed step: preparing the secondmate's state directory or per-home inheritance lock, a full source-side retry queue (`state/.fm-inherited-config-reread-retry/<id>/`, capped at 16 pending entries), or a write, publish, or `fm-send.sh fm-<id>` delivery failure inside `fm-config-inherit-lib.sh`.
  The pushed file is already correct on the secondmate's disk, and a matching pending instruction (staged at the destination under its own `state/`, or retried from the source-side queue here) survives so bootstrap retries the same notification on its next run; investigate only if the same secondmate keeps failing, since until it clears that secondmate may still be acting on the file's prior content.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local Relay poll artifacts (`docs/configuration.md` "Relay (.env)"); the emitted line still carries Relay's former `X mode` wording.
  Only when a running watcher needs the cadence transition applied immediately, restart the home-scoped watcher through the emitted harness supervision protocol; bootstrap deliberately never restarts the watcher itself.
- `SERVICE_FAILED: <unit> - failed since <timestamp>` - a systemd unit named in the optional local `config/critical-services` file is in the failed state (`docs/configuration.md` "Critical service watch"); a pure read-only detection (`systemctl is-failed`, no root), so a read-only session still surfaces it.
  Report it to the captain in plain language; never restart the unit yourself - a unit that failed may be unsafe to restart without knowing why.
  An absent or empty config file, a host without `systemctl`, or no failed unit all print nothing.
- `AUTODEPLOY_FAILED: <label> - <last line>` - the last line of a status log named in the optional local `config/autodeploy-logs` file reports failure (`bin/fm-watch.sh`'s `autodeploy_scan` owns the failure convention; `bin/fm-bootstrap.sh`'s `autodeploy_logs_check` is its session-start counterpart, a pure read-only detection that catches a deploy that failed while no watcher was armed to sweep it).
  Tell the captain plainly that the live deploy for `<label>` is failing, relaying the log line; firstmate never touches the deploy itself.
  An absent or empty config file, a missing or transiently unreadable log (a NAS hiccup), or a healthy last line all print nothing.
- `AUTODEPLOY_INERT: config/autodeploy-logs is set but no timeout mechanism (timeout, gtimeout, or perl) is on PATH; autodeploy-alert checks cannot run` - the host has none of the three mechanisms `fm-autodeploy-lib.sh`'s `fm_autodeploy_read_last_line` needs to bound a log read, so every autodeploy check silently no-ops on both the bootstrap check and the watcher's periodic sweep.
  Tell the captain plainly that autodeploy alerting is disabled on this host until `timeout` (coreutils), `gtimeout` (macOS via Homebrew's coreutils), or `perl` is installed; this is a one-time-per-session capability gap, not a deploy failure.
- `TMP_USAGE_HIGH: /tmp is <pct>% full (threshold <pct>%)` - `/tmp` usage crossed the threshold in the optional local `config/tmp-alert-threshold` file (`docs/configuration.md` "/tmp usage watch"; `bin/fm-watch.sh`'s `tmp_alert_scan` owns the periodic sweep that catches a breach while no session was open, `bin/fm-bootstrap.sh`'s `tmp_alert_check` is its session-start counterpart).
  Tell the captain plainly that `/tmp` is running low on room; firstmate does not remove anything itself in response - a full `--apply` run of `bin/fm-tmp-sweep.sh` is the deliberate remediation, not an automatic bootstrap side effect.
  An absent or empty config file, no `df` on PATH, or usage under threshold all print nothing.
- `TMP_USAGE_INERT: config/tmp-alert-threshold is set but 'df' is not on PATH; /tmp usage checks cannot run` - the host is missing `df`, so the usage check silently no-ops on both the bootstrap check and the watcher's periodic sweep.
  Tell the captain plainly that `/tmp` usage alerting is disabled on this host until `df` (coreutils) is installed; this is a one-time-per-session capability gap, not a usage breach.
- `UPSTREAM_DRIFT: local main is <ahead> ahead / <behind> behind upstream/main, last reconciled <days>d ago (<date>)` - the always-on FYI variant: firstmate's OWN repo tracking how far it has drifted from its read-only upstream template (`kunchenguid/firstmate`, the `upstream` remote after the remote swap).
  It prints every session; record it silently like any capability fact and take no action while the wording stays FYI.
  It only reports - the network fetch that refreshes the ref runs in the locked fleet-sync sweep, and reconciling upstream is never a bootstrap side effect.
- `UPSTREAM_DRIFT: this repo's upstream sync needs attention - ...` - the escalated variant (local main more than ~30 commits behind `upstream/main`, or the merge-base older than 10 days).
  The reconciliation procedure itself is owned by the `upstream-reconciliation` skill; the scheduled sweep in `bin/fm-upstream-sync.sh` raises the same work as an `[upstream-sync:intake]` inbox note.
  Surface it to the captain in plain outcome language and, on their go-ahead, dispatch a deliberately-reviewed firstmate-repo reconciliation ship task - fetch `upstream`, merge it into local `main`, resolve conflicts, and land local-only (`AGENTS.md` section 1) - the same shape that reconciled the divergence before.
  Never automate the merge; keeping the gap small also keeps the pipeline's opportunistic upstream PR's diff clean (`AGENTS.md` section 1).
