---
description: Discuss a feature idea until the intent is sharp, then capture it as a durable brief file that a later orca run discovers and consumes automatically. Orca runs only from a brief, so this is the mandatory first step of every run. Use when the user wants to think through what should be built — outcome, features, non-goals, inputs/outputs, constraints, doubt rule — before authorizing an autonomous orca:run, or wants to queue briefs up ahead of time. Writes `.orca/briefs/<timestamp>-<slug>.md` only; does not write a spec, plan, or code, and does not start a run.
args: <idea>
user-invocable: true
disable-model-invocation: true
---

# Orca: brief

Capture the intent for a future orca run as a file. The orca:run skill does not interview: every run starts from a brief written here, discovered on disk, and confirmed once. This skill is where intent gets captured — unhurried, adversarial about scope, and free to span as many rounds as the idea needs, precisely because it is not sitting at the top of an expensive autonomous run. The product is a brief in exactly the shape orca:run's opening confirmation restates, so the run starts with a single yes.

The brief is *what and why* — human intent. It is not *how it maps onto the codebase*: interfaces, work breakdown, and file ownership belong to the run's spec stage, which grounds them in real codebase exploration. A breakdown written here would be a guess, and a guessed decomposition is where parallel-agent runs go wrong.

## Input

The user provides a rough idea, usually by invoking `/orca:brief` with a short objective. If no idea is provided, ask what they want to build.

## Step 1: Discuss

Interview the user, in as many rounds as it takes. The brief is the run's entire intent — orca:run asks nothing beyond one confirmation — so cover:

- The desired outcome: what exists when this is done that does not exist now.
- The features it must have, and explicitly which it must not.
- Inputs and outputs: what data, events, or user actions go in; what results, side effects, or artifacts come out.
- Constraints: existing code it must integrate with, performance or compatibility expectations, deadlines on scope.
- The doubt rule: when the run hits an ambiguity, should it prefer the smaller interpretation and cut scope, or the more complete one? Default to smaller if the user has no preference.
- The breakdown checkpoint: when the run's spec and work breakdown are written — before any code — do they want to review it once, or go straight through autonomously? Default to straight through.

Push back. Play devil's advocate on scope, hunt for unstated non-goals, name the ambiguities the user has not noticed and make them choose. Every ambiguity resolved here is one the autonomous run will not have to guess at against the doubt rule.

Stay at intent level. Do not explore the codebase deeply — recording the files or integration points the user names is fine, but grounding the intent in code is the spec stage's job, with fresh context and real exploration. If the discussion turns into reading source at length, the conversation has drifted from *what* into *how*; steer it back.

## Step 2: Early pre-flight (optional, never blocking)

Run orca:run's environment pre-flight now, from the project root — it ships in this plugin:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/preflight.sh
```

This is an early warning, not a gate: a `FAIL` here is something to fix before the *run*, at leisure — it never blocks writing the brief. Report any failing gate and point at the right fixer — orca:init for the layout gate (`BARE_REPO`), orca:doctor for the machine gates (`CODEX`, an invalid `REVIEWER`) — then continue. A `CODEX: SKIPPED` line just means the run will use the Claude reviewer; nothing to fix.

## Step 3: Write the brief

Resolve `<repo-root>` as the parent of `git rev-parse --path-format=absolute --git-common-dir`, create `.orca/briefs/` there if needed, and write the brief to:

```text
<repo-root>/.orca/briefs/<YYYYMMDD-HHMM>-<slug>.md
```

Generate the timestamp with `date +%Y%m%d-%H%M`; make `<slug>` a short kebab-case description, 3-5 words max. The timestamped filename is what orca:run lists during discovery, so the name alone must identify the brief.

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

Use `date +"%Y-%m-%d %H:%M"` for the `Created` line — it survives the file's later move into a run directory, and orca:run uses it to warn when a brief has gone stale.

Read the written brief back to the user in summary and incorporate corrections until they approve it. Their approval is what makes the file authoritative — a later orca run treats it as the whole of their intent.

There is no status field. Location is status: everything at the top level of `.orca/briefs/` is ready and unconsumed, and orca:run moves a brief into its run directory when a run starts from it. If the discussion needs another sitting, park the file in `.orca/briefs/drafts/` instead and move it up one level when it is done — orca:run only discovers the top level.

## Step 4: Hand off

Tell the user the brief is ready and where it lives, and that any later `/orca:run` invocation in this repository will discover it automatically — no path or link needed. Orca:run will restate the brief, warn if it has aged, and ask for one confirmation before running.

Do not start the run yourself, even if asked in the same breath — end the skill, let the user invoke `/orca:run`, and let its own pre-flight and confirmation gates do their job.

## Guidelines

- One brief is one run's scope. If the discussion uncovers two independent efforts, write two briefs.
- Never write Interfaces, a Work Breakdown, or file ownership into a brief — that is the spec stage's job, and it needs codebase exploration this skill deliberately avoids.
- Briefs may pile up; that is the point. Each is consumed by the run it starts and archived in that run's directory.
