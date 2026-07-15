---
name: verify-trivial
description: >-
  Agent-only Light verification tier for a task dispatched at the trivial (haiku/low) model/effort tier.
  Use when authoring or filling in a Light-tier brief's Task section (a brief scaffolded with `bin/fm-brief.sh --light-verify`), when working a task whose brief points here, or when reviewing such a task's done report before PR-ready.
  Cites `verify-rigorously` for the AC bar, its 3 verification shapes, its pass/fail matrix, and its "what wasn't verified" footer; layers 3 deltas on top: a cap of 3 acceptance criteria instead of an uncapped set, a 3-attempt cap-out that escalates the task's tier rather than failing it outright, and a mandatory side-effect confidence gate before shipping.
user-invocable: false
metadata:
  internal: true
---

# verify-trivial

Light verification tier for a task dispatched at the trivial (haiku/low) model/effort tier (see `AGENTS.md` section 7's escalation-trigger paragraph).
Such a task is scaffolded with `bin/fm-brief.sh --light-verify`; its brief points here instead of the default, uncapped verification workflow.

## Cite, don't copy

Load `verify-rigorously` and apply it in full: named observable pass/fail acceptance criteria, one of its 3 verification shapes per criterion, the criterion x shape pass/fail matrix, and the closing "what wasn't verified" footer.
This skill does not restate that contract - `verify-rigorously` is its sole owner.
Everything below is a delta on top of it that applies only to a Light-tier task.

## Delta 1: cap acceptance criteria at 3

Name at most 3 acceptance criteria, not verify-rigorously's uncapped set.
A trivial-tier task is scoped small enough by definition (`bin/fm-tier-guard.sh`'s envelope: at most 2 changed files, at most 30 changed lines) that 3 observable criteria should describe "done" completely.
If the task genuinely needs more than 3 to state what done means, that is itself a signal the task has outgrown the trivial tier: report it per Delta 2 instead of naming a 4th criterion.

## Delta 2: a 3-attempt cap-out escalates, it does not fail

verify-rigorously's own 3-attempt cap says: stop and report what's failing, what was tried, and the likely cause.
On the Light tier, that report is not a terminal failure - it is a request to escalate the task off this tier.
Append `needs-decision: {criterion} failed verification after 3 attempts, requesting escalation to a heavier tier` (or `blocked:` if the same obstacle recurred, per the brief's own rule for that case) and stop; do not report `failed:` for a cap-out alone.
Firstmate escalates the task's model/effort in place per `AGENTS.md` section 7's escalation-trigger paragraph, exactly as a `bin/fm-tier-guard.sh` envelope escalation would, and the task continues under the ordinary uncapped `verify-rigorously` workflow from there.
Never drop the task back to the Light tier afterward - this mirrors section 7's "never silently de-escalate for the rest of that task's life."

## Delta 3: mandatory side-effect confidence gate before shipping

Before reporting `done:` (ship tasks) or writing the report (scout tasks), state explicitly, in one line, whether the change has any side effects outside the files it touches - a shared config default, a migration, a public interface, a cross-task or cross-project coupling - and your confidence in that assessment.
An unstated "no side effects" is not the same as a stated one: silence here is exactly the gap verify-rigorously's own footer warns against, so this gate is mandatory even when the answer is "none found."
If confidence is anything less than high, that uncertainty is itself grounds for a Delta 2 escalation rather than shipping on the Light tier.

## Wiring this tier's no-mistakes validation

For a no-mistakes-mode ship task on this tier, firstmate's validation trigger skips the document step (`no-mistakes axi run --skip=document`): the side-effect confidence gate above already covers what that step would otherwise catch at this tier's scale.
This is firstmate's own action at Validate time (`AGENTS.md` section 7), not something the crewmate invokes itself.
