# Orca: feature — the interview

This file is read by the orca:feature skill when its triage finds no interrupted run and no queued brief: the idea at hand has no captured intent yet, so capture it as a durable brief file. Every run starts from a brief, discovered on disk and confirmed once. The interview is where intent gets captured — unhurried, adversarial about scope, and free to span as many rounds as the idea needs. The product is a brief in exactly the shape the run's opening confirmation (Step 1 of `SKILL.md`) restates, so the run starts with a single yes.

The brief is *what and why* — human intent. It is not *how it maps onto the codebase*: interfaces, work breakdown, and file ownership belong to the run's spec stage, which grounds them in real codebase exploration. A breakdown written here would be a guess, and a guessed decomposition is where parallel-agent runs go wrong.

## Input

The user provides a rough idea, usually as the `<idea>` argument to `/orca:feature`. If no idea was provided, ask what they want to build.

## Step 1: Discuss

Interview the user, in as many rounds as it takes. The brief is the run's entire intent — the run asks nothing beyond one confirmation — so cover:

- The desired outcome: what exists when this is done that does not exist now.
- The features it must have, and explicitly which it must not.
- Inputs and outputs: what data, events, or user actions go in; what results, side effects, or artifacts come out.
- Constraints: existing code it must integrate with, performance or compatibility expectations, deadlines on scope.
- The doubt rule: when the run hits an ambiguity, should it prefer the smaller interpretation and cut scope, or the more complete one? Default to smaller if the user has no preference.
- The breakdown checkpoint: when the run's spec and work breakdown are written — before any code — do they want to review it once, or go straight through autonomously? Default to straight through.

Push back. Play devil's advocate on scope, hunt for unstated non-goals, name the ambiguities the user has not noticed and make them choose. Every ambiguity resolved here is one the autonomous run will not have to guess at against the doubt rule.

If the machine-local project context exists — `<repo-root>/.orca/decisions.md` and `.orca/map.md` — read it before the later rounds and interview decision-aware: a recorded decision the idea seems to touch is worth a direct question ("the decision log says the auth module deliberately has no middleware — is that changing?"). The files are hints from a snapshot, not ground truth; a decision the user overturns here becomes brief content, never an edit to the log.

Stay at intent level. Do not explore the codebase deeply — recording the files or integration points the user names is fine, but grounding the intent in code is the spec stage's job, with fresh context and real exploration. If the discussion turns into reading source at length, the conversation has drifted from *what* into *how*; steer it back.

## Step 2: Early pre-flight (optional, never blocking)

Run the run's environment pre-flight now, from the project root — it ships in this plugin:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh
```

This is an early warning, not a gate: a `FAIL` here is something to fix before the *run*, at leisure — it never blocks writing the brief. It also spares a second run: if the brief runs now, the run's own environment pre-flight reuses this output rather than re-running the script. Report any failing gate and point at the right fixer — orca:init for the layout gate (`BARE_REPO`), orca:doctor for the machine gates (`CODEX`, an invalid `REVIEWER`) — then continue. A `CODEX: SKIPPED` line just means the run will use the Claude reviewer; nothing to fix.

## Step 3: Write the brief

Resolve `<repo-root>` as the parent of `git rev-parse --path-format=absolute --git-common-dir`, create `.orca/feat-briefs/` there if needed, and write the brief to:

```text
<repo-root>/.orca/feat-briefs/<YYYYMMDD-HHMM>-<slug>.md
```

Generate the timestamp with `date +%Y%m%d-%H%M`; make `<slug>` a short kebab-case description, 3-5 words max. The timestamped filename is what triage lists during discovery, so the name alone must identify the brief.

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

Use `date +"%Y-%m-%d %H:%M"` for the `Created` line — it survives the file's later move into a run directory, and the run uses it to warn when a brief has gone stale.

Read the written brief back to the user in summary and incorporate corrections until they approve it. Their approval is what makes the file authoritative — a later orca run treats it as the whole of their intent.

There is no status field. Location is status: everything at the top level of `.orca/feat-briefs/` is ready and unconsumed, and the run moves a brief into its run directory when it starts from it. If the discussion needs another sitting, park the file in `.orca/feat-briefs/drafts/` instead and move it up one level when it is done — triage only discovers the top level.

## Step 4: Hand back

The brief is written and approved. Return to `SKILL.md`'s run-now-or-queue question (the end of Step 0) — whether this brief starts its run now or waits queued is the user's call, made there. The run's own pre-flight and confirmation gates run in the same skill, so there is nothing to hand off.

## Guidelines

- One brief is one run's scope. If the discussion uncovers two independent efforts, write two briefs.
- Never write Interfaces, a Work Breakdown, or file ownership into a brief — that is the spec stage's job, and it needs codebase exploration this skill deliberately avoids.
- Briefs may pile up; that is the point. Each is consumed by the run it starts and archived in that run's directory.
