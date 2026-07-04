---
name: briefify
description: Discuss a feature idea until the intent is sharp, then capture it as a durable brief file that a later orchestrify run discovers and consumes automatically. Orchestrify runs only from a brief, so this is the mandatory first step of every run. Use when the user wants to define outcome, features, non-goals, inputs/outputs, constraints, and the doubt rule before authorizing an autonomous orchestrify run, or wants to queue briefs ahead of time. Writes `.orchestrify/briefs/<timestamp>-<slug>.md` only; does not write a spec, plan, or code, and does not start a run.
---

# Briefify

Capture the intent for a future orchestrify run as a file. Orchestrify does not interview: every run starts from a brief written here, discovered on disk, and confirmed once. This skill is where intent gets captured — unhurried, adversarial about scope, spanning as many rounds as the idea needs, precisely because it is not sitting at the top of an expensive autonomous run. The product is a brief in exactly the shape orchestrify's opening confirmation restates, so the run starts with a single yes.

The brief is *what and why* — human intent. Interfaces, work breakdown, and file ownership belong to orchestrify's spec stage, which grounds them in real codebase exploration; a breakdown written here would be an ungrounded guess.

## 1. Discuss

If no idea was provided, ask what to build. Then interview, in as many rounds as it takes. The brief is the run's entire intent — orchestrify asks nothing beyond one confirmation — so cover:

- The outcome: what exists when this is done that does not exist now.
- Required features, and explicitly which are excluded.
- Inputs, outputs, side effects, and integration points.
- Constraints: compatibility, performance, scope, delivery.
- The doubt rule: prefer smaller scope or prefer completeness. Default to smaller.
- The breakdown checkpoint: one review of the spec and breakdown before code, or straight through. Default to straight through.

Push back: play devil's advocate on scope, hunt for unstated non-goals, surface ambiguities and make the user choose. Every ambiguity resolved here is one the autonomous run will not guess at.

Stay at intent level. Recording files or integration points the user names is fine; deep codebase exploration is the spec stage's job. If the conversation turns into reading source at length, steer it back from *how* to *what*.

## 2. Early pre-flight (optional, never blocking)

If the orchestrify skill is installed, run its pre-flight from the project root:

```bash
bash <orchestrify-skill-dir>/scripts/preflight.sh
```

A `FAIL` is an early warning to fix before the run — report it, point at the initify skill (which fixes the layout and tooling gates interactively), and continue; it never blocks the brief. Skip silently if orchestrify is not installed.

## 3. Write the brief

Resolve `<repo-root>` as the parent of `git rev-parse --path-format=absolute --git-common-dir`, create `.orchestrify/briefs/` there if needed, and write:

```text
<repo-root>/.orchestrify/briefs/<YYYYMMDD-HHMM>-<slug>.md
```

Generate the timestamp with `date +%Y%m%d-%H%M`; make `<slug>` a short kebab-case phrase, 3-5 words. The filename is what orchestrify lists during discovery, so the name alone must identify the brief.

```markdown
# Brief: <title>

**Created:** <YYYY-MM-DD HH:MM>

## Outcome
<What exists when this is done.>

## Features
- <Required capability>

## Non-goals
- <Excluded scope>

## Inputs & Outputs
- **In:** <data, events, or actions>
- **Out:** <results, side effects, or artifacts>

## Constraints
- <Integration point, compatibility expectation, or scope bound>

## Doubt Rule
<prefer-smaller-scope or prefer-complete>

## Breakdown Checkpoint
<review-once or straight-through>
```

Use `date +"%Y-%m-%d %H:%M"` for the `Created` line — it survives the file's later move into a run directory, and orchestrify uses it to warn when a brief has gone stale.

Read the brief back in summary and incorporate corrections until the user approves. Approval makes the file authoritative — a later run treats it as the whole of their intent.

There is no status field. Location is status: everything at the top level of `.orchestrify/briefs/` is ready and unconsumed; orchestrify moves a brief into its run directory when a run starts from it. Park unfinished briefs in `.orchestrify/briefs/drafts/` and move them up when done — orchestrify only discovers the top level.

## 4. Hand off

Tell the user the brief is ready and that any later orchestrify invocation in this repository discovers it automatically — no path needed. Orchestrify restates the brief, warns if it has aged, and asks for one confirmation before running.

Do not start the run yourself, even if asked in the same breath — end here and let orchestrify's own pre-flight and confirmation gates do their job.

## Invariants

- One brief is one run's scope; two independent efforts get two briefs.
- Never write Interfaces, a Work Breakdown, or file ownership into a brief.
- Briefs may pile up; each is consumed by the run it starts and archived in that run's directory.
- The brief format is shared with the Claude variant: a brief written here can be consumed by either orchestrator.
