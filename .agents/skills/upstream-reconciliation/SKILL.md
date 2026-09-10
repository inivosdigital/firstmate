---
name: upstream-reconciliation
description: >-
  Agent-only procedure for folding read-only upstream-template commits into this fork's local main.
  Use on an `[upstream-sync:intake]` inbox note from the scheduled sweep, when the captain asks to reconcile upstream, and before dispatching or working the `upstream-drift-alert` backlog item.
  Owns the pinned merge in an isolated copy, the recovery ref, the fork-behavior inventory a clean merge hides, the moved-head guard before landing, and the recorded rationale for anything deliberately left out.
user-invocable: false
metadata:
  internal: true
---

# upstream-reconciliation

`upstream` (`kunchenguid/firstmate`) is a read-only parent template.
This fork can never push or merge to it, so reconciliation is one-directional: upstream commits come into local `main`, and fork history and fork behavior both survive intact.

`bin/fm-upstream-sync.sh` only detects drift and queues one request.
This skill is the reconciliation itself, and it drives existing owners rather than adding tools of its own: `bin/fm-brief.sh` for the brief, `bin/fm-spawn.sh` for the worker, `tasks-axi` for the item, `bin/fm-merge-local.sh` for the landing.

## Load this when

- An `[upstream-sync:intake]` note reaches the wake drain.
- The captain asks to reconcile, catch up on, or fold in upstream.
- You are about to dispatch or work the `upstream-drift-alert` backlog item.

## Two things this is not

- **Not a self-update.** `/updatefirstmate` follows `origin` (the captain's fork). It never touches `upstream`.
- **Not automated.** Cron detects. An agent merges, a reviewer checks it, and the captain approves the landing.

## Intake

1. Read the note, then confirm the numbers against the durable record rather than the note's prose:
   ```sh
   bin/fm-upstream-sync.sh status
   ```
2. If the note reports the item as HELD, reconcile that hold before anything else, and load `captain-hold-lifecycle` to do it.
   The sweep reports a hold and never interprets or releases one, because the same id can be held as this home's legacy drift reminder or as a landing or decision gate on a reconciliation already under review, and only the captain's recorded instructions say which.
   Reconcile it in whichever direction the evidence supports; a landing or decision gate stays in force until the captain answers it.
3. Otherwise file or refresh the `upstream-drift-alert` backlog item with `tasks-axi`, repo `firstmate`, kind `ship`, mode `local-only`, `yolo` off.
   A filed and unheld item suppresses further intake for the whole reconciliation, so keep it open until the landing is confirmed.
4. Acknowledge the note so it stops counting as waiting: `bin/fm-inbox.sh drain --ack <id>`.
5. Dispatch one crewmate. This is firstmate-repo tracked material, so the brief must require `firstmate-coding-guidelines`, and it must carry this skill's procedure below.

## The reconciliation procedure (the crewmate's work)

### 1. Pin both heads first

Record the exact SHAs before touching anything, and use these pinned values for every later step:

```sh
git -C <fork> rev-parse refs/heads/main            # LOCAL_SHA
git -C <fork> rev-parse refs/remotes/upstream/main # UPSTREAM_SHA
git -C <fork> merge-base "$LOCAL_SHA" "$UPSTREAM_SHA"
```

A reconciliation validated against one head and landed against another is not the thing that was reviewed.
Put both SHAs in the task report.

### 2. Preserve a recovery ref

```sh
git update-ref refs/fm-upstream-recovery/<date> "$LOCAL_SHA"
```

The fork's history is the thing that cannot be re-derived.
This named ref is what makes an abandoned attempt recoverable without depending on the reflog.

### 3. Branch from local main, in an isolated copy

Work in the task worktree, never the primary checkout, and branch from the pinned `LOCAL_SHA`.

### 4. Merge, and only merge

```sh
git merge --no-ff --no-commit "$UPSTREAM_SHA"
```

Three prohibitions, all of which silently destroy the fork:

- **Never** `git reset --hard upstream/main` or `git rebase` the fork onto upstream. Both discard fork history rather than reconciling it.
- **Never** resolve with a blanket `-X ours` or `-X theirs`, or `git checkout --ours/--theirs` across a set of files. Blanket resolution drops one side's behavior without anyone reading what was dropped.
- **Never** commit the merge before every conflict has been resolved by reading both sides.

Resolve each conflict individually. For each one, state in the report which side won and why.

### 5. Inventory the fork behavior upstream touched

A textually clean merge is not a safe merge.
The dangerous case is a file both sides changed in different regions: git merges it silently and fork behavior changes with no conflict to read.

```sh
BASE=$(git merge-base "$LOCAL_SHA" "$UPSTREAM_SHA")
git diff --name-only "$BASE" "$LOCAL_SHA" | sort > /tmp/fork-changed
git diff --name-only "$BASE" "$UPSTREAM_SHA" | sort > /tmp/upstream-changed
comm -12 /tmp/fork-changed /tmp/upstream-changed
```

Those paths are inspection candidates, not findings and not the whole list.
A path lands there because both sides edited the same file, which says nothing yet about whether a fork contract lives in it.
Read each one and either name the fork contract it carries and how you checked that contract still holds after the merge, or record that it carries none.
[`docs/examples/upstream-semantic-merge-fixture.sh`](../../../docs/examples/upstream-semantic-merge-fixture.sh) builds this exact shape on disposable repositories; run it once if you have not seen the failure mode, because it is the one this step exists for.

The overlap list is also incomplete, because behavior breaks across files that never overlap.
Upstream can change a caller, a shared library, a default, a schema, or an exit code in a file the fork never touched and break a fork-only guarantee that lives somewhere else entirely.
A fork guard whose only caller upstream deleted is still gone after a perfectly clean merge with an empty overlap list.
So sweep outward from the fork's own changes as well:

```sh
comm -23 /tmp/fork-changed /tmp/upstream-changed > /tmp/fork-only
git diff "$BASE" "$UPSTREAM_SHA" > /tmp/upstream.diff

# 1. upstream changes that name a fork-only file (callers, registrations, schedules)
while read -r p; do
  grep -n -- "$(basename "$p")" /tmp/upstream.diff | sed "s|^|$p <- |"
done < /tmp/fork-only

# 2. upstream changes that touch a name the fork-only code defines
git diff "$BASE" "$LOCAL_SHA" -- $(tr '\n' ' ' < /tmp/fork-only) \
  | sed -n 's/^+[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)() *{.*/\1/p' | sort -u > /tmp/fork-symbols
[ -s /tmp/fork-symbols ] && grep -nFf /tmp/fork-symbols /tmp/upstream.diff
```

For every fork-only path, answer both directions from that diff rather than from memory:

- **What does it call?** Did upstream change the signature, contract, default, or exit code of anything this fork-only code invokes?
- **What calls it?** Did upstream change, move, rename, or delete a caller, dispatch table, schedule, or registration that reaches this fork-only code?

The sweep narrows where to look; it never proves safety.
The proof is the named contract plus the check you actually ran for it.

Firstmate asks for the private context a diff cannot show: which of these paths carry captain-specific configuration, local operating decisions, or deliberate divergences from the template.
Ask for it rather than inferring it from file names.

### 6. Automated checks, then human and agent review

Keep these two apart in the report. They fail differently and one never substitutes for the other.

**Automated** (these are pass/fail and prove only that nothing textual broke):

```sh
bin/fm-lint.sh
bin/fm-test-run.sh --changed
bin/fm-doc-audience-check.sh
```

Run the full suite (`bin/fm-test-run.sh --all`) when the overlap list from step 5 touches `bin/` or `tests/`.

**Review** (a person or an independent agent reading the merge, which no check above can do):

- An independent reviewer, dispatched separately, reads the conflict resolutions and the step-5 overlap list against the fork contracts they carry.
- The captain reads the outcome and approves the landing.

An automated green run is a precondition for review, never a replacement for it.

### 7. Guard both heads before landing

Immediately before landing, re-read both SHAs and compare them with the pin from step 1:

```sh
git -C <fork> rev-parse refs/heads/main refs/remotes/upstream/main
```

If either moved, stop.
Do not land a merge validated against a head that no longer exists, and do not rebase the merge branch onto the new head.
Rebase replays the branch commit by commit and can flatten or drop the merge topology this reconciliation exists to preserve, which is the same history loss step 4's prohibitions guard against.
Re-pin both SHAs, redo the merge from step 3 on a fresh branch off the new `LOCAL_SHA`, and re-run steps 4 through 6 against that pin.
The step-2 recovery ref keeps the abandoned attempt readable, and the conflict resolutions already recorded in step 4 make the second pass a re-application rather than a fresh start.

### 8. Record what was left out

Reconciliation is rarely all-or-nothing.
Any upstream commit or hunk deliberately excluded gets an explicit line in the task report and in the backlog item: which change, and why this fork is not taking it.

Never close the item as reconciled while carrying silent exclusions.
"Fully synchronized" and "synchronized except for these three named things" are different outcomes, and only the second one is honest when something was dropped.

## Landing

Local-only, so the captain approves and firstmate lands it through the guarded path:

```sh
bin/fm-merge-local.sh <task-id>
```

That path fast-forwards local `main` and, because the project is firstmate's own repo, pushes `origin` (the captain's fork) itself.
Never push `upstream`, and never hand-compose a merge command around that guard.

## Closing out

Close `upstream-drift-alert` only after the landing is confirmed, and only with the exclusions from step 8 recorded on it.
The sweep resumes normal reporting once the item is done: it stays quiet until upstream moves again.
While the item is open and unheld it suppresses new intake entirely; while it is held it still gets one note per new upstream head, which is the signal that the head this reconciliation pinned has moved and step 7 applies.

## Maintaining this file

Keep the procedure here and the mechanics in `bin/fm-upstream-sync.sh`'s header.
When a step's tool changes, patch the one line that names it rather than restating that tool's contract.
