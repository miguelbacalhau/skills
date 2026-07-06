---
description: View and set per-repository overrides for which Claude model and reasoning effort each orca stage agent (spec, plan, implement, review, fix, commit, merge, integrate) runs with during an orca:run. Writes the `agents` block of `.orca/config.json` at the repo root; orca:run reads it at launch and threads the overrides into every stage agent it spawns. Use when the user wants runs cheaper (smaller models, lower effort), stronger (bigger models, higher effort), or wants to see what each stage currently runs with. Does not start a run and never edits the plugin's own agent definitions.
args: <assignments like plan.model=sonnet review.effort=high, or "reset"; optional>
user-invocable: true
disable-model-invocation: true
---

# Orca: config

Tune which model and reasoning effort each orca stage agent runs with, per repository. Every stage agent ships a default in its own definition — the frontmatter of `agents/<stage>.md` inside the plugin — and this skill never touches those files: it writes overrides to `<repo-root>/.orca/config.json`, which orca:run reads at launch and applies on top of the defaults. An override file survives plugin updates; deleting an override returns that stage to whatever the plugin's current default is.

Two stages come with caveats worth stating whenever they are configured:

- **spec** is spawned conversationally by orca:run before the workflow starts, through a tool that can override model but not effort — so `spec` takes a `model` override only. Reject `spec.effort` with this explanation.
- **review** is the courier that drives Codex, not the reviewer itself: it fills in the review template, calls the codex MCP tool, and files the findings verbatim. Configuring it changes the courier's cost and care, never the quality of Codex's review.

The workflow's internal helper agents — the shell relay, reconciliation, escalation — are not configurable: their cost/judgment profile is part of the loop's design, not a per-repo preference.

## Step 1: Read the current state

Resolve `<repo-root>` as the parent of `git rev-parse --path-format=absolute --git-common-dir`. If not inside a git repository, explain that the config is per-repository and stop.

Defaults live in the plugin and may change across plugin versions — read them fresh rather than reciting remembered values:

```bash
grep -H -E '^(model|effort):' ${CLAUDE_PLUGIN_ROOT}/agents/*.md
```

Then read `<repo-root>/.orca/config.json` if it exists; its `agents` block holds the current overrides.

## Step 2: Show the table

Always show the effective configuration before changing anything — with no arguments, showing it may be the whole job:

| Stage | Role | Model | Effort |
|-------|------|-------|--------|
| spec | explores the codebase, writes the spec and work breakdown | opus | xhigh |
| plan | … | … | … |

One line per stage, role in a few words (spec: writes the spec and breakdown; plan: plans one item; implement: builds one item; review: drives the Codex review; fix: applies review findings; commit: commits one item; merge: merges into the integration branch; integrate: verifies the assembled feature). Show the effective value, marking overrides — e.g. `sonnet (override; default opus)` — so defaults and overrides are distinguishable at a glance.

## Step 3: Apply changes

Arguments like `plan.model=sonnet review.effort=high` apply directly. `reset` clears every override; `reset <stage>` clears one; the value `default` clears a single field (`plan.model=default`). With no arguments, show the table and ask what to change in plain conversation — do not march through all eight stages unless asked.

Validate every assignment before writing, and reject bad ones naming the allowed values:

- stage ∈ `spec`, `plan`, `implement`, `review`, `fix`, `commit`, `merge`, `integrate`
- model ∈ `haiku`, `sonnet`, `opus`, `fable` — harness model aliases; warn that `fable` only works on plans whose harness offers it
- effort ∈ `low`, `medium`, `high`, `xhigh`, `max`
- `spec.effort` is rejected with the explanation above

These lists must match the `STAGES`/`MODELS`/`EFFORTS` constants in `${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/work-loop.workflow.js` — the launch-time validator that rejects anything written here that it does not accept. If there is any doubt this prose is current (a plugin update may have changed the script), read the constants from the script and validate against those.

An override equal to today's default is still meaningful — it pins the stage against future plugin-default changes — so keep it if the user asked for it explicitly, and say that is what it does.

## Step 4: Write and confirm

Merge into any existing `<repo-root>/.orca/config.json` rather than overwriting unrelated keys, creating `.orca/` if needed. In the bare-repo layout orca:init creates, `.orca/` sits outside every worktree and cannot be committed; in a conventional checkout, `<repo-root>` **is** the working tree, so when creating `.orca/` there, also append `.orca/` to `<git-common-dir>/info/exclude` (if not already present) — the per-clone ignore file — so a stray `git add -A` never commits per-machine model preferences; the repo's tracked `.gitignore` stays untouched. Store only the overridden fields:

```json
{
  "agents": {
    "plan": { "effort": "high" },
    "implement": { "model": "opus" }
  }
}
```

Cleared fields are removed, an empty stage object is removed, an empty `agents` block is removed, and a file left `{}` is deleted.

Then show the resulting table once more and state when it takes effect: the **next orca:run launch**. A run already in flight keeps the configuration it launched with, and a resume (`resumeFromRunId`) does too — orca:run records the launch-time block in the run's `spec.md` and resumes from that record, never from this file — so editing overrides here affects only future launches.

## Guidelines

- Never edit `${CLAUDE_PLUGIN_ROOT}/agents/*.md` — plugin files are replaced on update, and the defaults are the plugin's to set. Overrides live only in the repo's `.orca/config.json`.
- This skill configures models and effort only. The Codex reviewer's setup (binary, auth, MCP timeout) belongs to orca:init; run behavior belongs to orca:run.
- Advise, don't moralize: if an override looks self-defeating (haiku for plan or merge, where judgment failures cost whole items; max effort on commit, which formats a message), say so in one sentence and write what the user chose.
