---
name: briefify
description: Discuss a feature idea until the intent is sharp, then capture it as a durable brief file that a later orchestrify run discovers and consumes automatically. Orchestrify runs only from a brief, so this is the mandatory first step of every run. Use when the user wants to think through what should be built — outcome, features, non-goals, inputs/outputs, constraints, doubt rule — before authorizing an autonomous orchestrify run, or wants to queue briefs up ahead of time. Writes `.orchestrify/briefs/<timestamp>-<slug>.md` only; does not write a spec, plan, or code, and does not start a run.
args: <idea>
user-invocable: true
---

# Briefify

Capture the intent for a future orchestrify run as a file. Orchestrify does not interview: every run starts from a brief written here, discovered on disk, and confirmed once. This skill is where intent gets captured — unhurried, adversarial about scope, and free to span as many rounds as the idea needs, precisely because it is not sitting at the top of an expensive autonomous run. The product is a brief in exactly the shape orchestrify's opening confirmation restates, so the run starts with a single yes.

The brief is *what and why* — human intent. It is not *how it maps onto the codebase*: interfaces, work breakdown, and file ownership belong to orchestrify's spec stage, which grounds them in real codebase exploration. A breakdown written here would be a guess, and a guessed decomposition is where parallel-agent runs go wrong.

## Input

The user provides a rough idea, usually by invoking `$briefify` with a short objective. If no idea is provided, ask what they want to build.

## Step 1: Discuss

Interview the user, in as many rounds as it takes. The brief is the run's entire intent — orchestrify asks nothing beyond one confirmation — so cover:

- The desired outcome: what exists when this is done that does not exist now.
- The features it must have, and explicitly which it must not.
- Inputs and outputs: what data, events, or user actions go in; what results, side effects, or artifacts come out.
- Constraints: existing code it must integrate with, performance or compatibility expectations, deadlines on scope.
- The doubt rule: when the run hits an ambiguity, should it prefer the smaller interpretation and cut scope, or the more complete one? Default to smaller if the user has no preference.
- The breakdown checkpoint: when the run's spec and work breakdown are written — before any code — do they want to review it once, or go straight through autonomously? Default to straight through.

Push back. Play devil's advocate on scope, hunt for unstated non-goals, name the ambiguities the user has not noticed and make them choose. Every ambiguity resolved here is one the autonomous run will not have to guess at against the doubt rule.

Stay at intent level. Do not explore the codebase deeply — recording the files or integration points the user names is fine, but grounding the intent in code is the spec stage's job, with fresh context and real exploration. If the discussion turns into reading source at length, the conversation has drifted from *what* into *how*; steer it back.

## Step 2: Early pre-flight (optional, never blocking)

If the orchestrify skill is installed, run its environment pre-flight now, from the project root:

```bash
bash ~/.claude/skills/orchestrify/scripts/preflight.sh
```

This is an early warning, not a gate: a `FAIL` here (no bare repo, Codex missing, agents not installed) is something to fix before the *run*, at leisure — it never blocks writing the brief. Report any failing gate and point at the initify skill, which fixes the layout and tooling gates interactively, then continue. If the script is not installed, skip this step silently.

## Step 3: Write the brief

Resolve `<repo-root>` as the parent of `git rev-parse --path-format=absolute --git-common-dir`, create `.orchestrify/briefs/` there if needed, and write the brief to:

```text
<repo-root>/.orchestrify/briefs/<YYYYMMDD-HHMM>-<slug>.md
```

Generate the timestamp with `date +%Y%m%d-%H%M`; make `<slug>` a short kebab-case description, 3-5 words max. The timestamped filename is what orchestrify lists during discovery, so the name alone must identify the brief.

```markdown
# Brief: <title>

**Created:** <YYYY-MM-DD HH:MM>

## Outcome

<What exists when this is done. One to three paragraphs.>

## Features

- <Required capability>

## Non-goals

- <Explicitly excluded scope>

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

Read the written brief back to the user in summary and incorporate corrections until they approve it. Their approval is what makes the file authoritative — a later orchestrify run treats it as the whole of their intent.

There is no status field. Location is status: everything at the top level of `.orchestrify/briefs/` is ready and unconsumed, and orchestrify moves a brief into its run directory when a run starts from it. If the discussion needs another sitting, park the file in `.orchestrify/briefs/drafts/` instead and move it up one level when it is done — orchestrify only discovers the top level.

## Step 4: Hand off

Tell the user the brief is ready and where it lives, and that any later `$orchestrify` invocation in this repository will discover it automatically — no path or link needed. Orchestrify will restate the brief, warn if it has aged, and ask for one confirmation before running.

Do not start the run yourself, even if asked in the same breath — end the skill, let the user invoke `$orchestrify`, and let its own pre-flight and confirmation gates do their job.

## Guidelines

- One brief is one run's scope. If the discussion uncovers two independent efforts, write two briefs.
- Never write Interfaces, a Work Breakdown, or file ownership into a brief — that is the spec stage's job, and it needs codebase exploration this skill deliberately avoids.
- Briefs may pile up; that is the point. Each is consumed by the run it starts and archived in that run's directory.
- The brief format is shared with the Codex variant of orchestrify: a brief written here can be consumed by either orchestrator.
