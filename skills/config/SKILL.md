---
description: View and set per-repository overrides for orca runs — which Claude model and reasoning effort each stage agent (spec, plan, implement, review, fix, commit, merge, integrate for feature runs; reproduce, hypothesize, verify, diagnose for debug runs) runs with, which independent reviewer (codex or claude) the work loop uses, and how orca:review hands deliverables to the human (`editor`, `terminal`). Writes `.orca/config.json` at the repo root; orca:feature and orca:debug read it at launch and thread the overrides into every stage agent they spawn, orca:review reads it per invocation. Use when the user wants runs cheaper (smaller models, lower effort), stronger (bigger models, higher effort), wants to pin or switch the reviewer, wants to pin or opt out of the editor hand-off, or wants to see the current configuration. Does not start a run and never edits the plugin's own agent definitions.
args: <assignments like plan.model=sonnet review.effort=high reviewer=claude editor=none, or "reset"; optional>
user-invocable: true
disable-model-invocation: true
---

# Orca: config

Tune orca runs per repository: which model and reasoning effort each stage agent runs with, and which independent reviewer the work loop uses. Every stage agent ships a default in its own definition — the frontmatter of `agents/<stage>.md` inside the plugin — and this skill never touches those files: it writes overrides to `<repo-root>/.orca/config.json`, which orca:feature and orca:debug read at launch and apply on top of the defaults. An override file survives plugin updates; deleting an override returns that stage to whatever the plugin's current default is.

The config has three surfaces:

- **`reviewer`** — a top-level key, `"codex"` or `"claude"`, selecting the work loop's independent reviewer — for feature runs and for the fix tail of diagnose-and-fix debug runs alike. When the key is **absent**, the run detects at launch: codex binary on PATH at the minimum version → codex, else claude. A written key **pins** the choice against detection.
- **`editor`** and **`terminal`** — flat top-level keys beside `reviewer`, read by **orca:review** (the human walk-through of a deliverable branch, not the runs' adversarial review stage). Same three-state contract as `reviewer`: **absent → detect** (`editor`: nvim on PATH with orca.nvim installed; `terminal`: `$TMUX` set), **pinned → loud fail** when the pinned thing is missing (never a silent fallback), **`none` → opt out** (orca:review prints the command instead of opening anything). Valid values today: `editor: nvim|none`, `terminal: tmux|none` — one working value per key, the enum grows when real support does. These are machine preferences living in a repo file — accepted trade-off: `.orca/` sits outside the worktrees (effectively personal), and detection means most users never set them.
- **`agents`** — per-stage `{model, effort}` overrides. One block serves both verbs: the feature stages (`spec` through `integrate`) and the debug stages (`reproduce`, `hypothesize`, `verify`, `diagnose`) live side by side, and each run applies its own verb's keys — plus, for a debug run's nested fix tail, the feature stages except `spec` (the fix contract is written by the diagnose agent, so a `spec` override never applies to debug runs) — ignoring the rest.

Two stages come with caveats worth stating whenever they are configured:

- **spec** is spawned conversationally by orca:feature before the workflow starts, through a tool that can override model but not effort — so `spec` takes a `model` override only. Reject `spec.effort` with this explanation.
- **review** tunes whichever reviewer agent is active, and what that means depends on the reviewer. With reviewer **codex**, the review stage is a courier that drives Codex: configuring it changes the courier's cost and care, never the quality of Codex's review. With reviewer **claude**, the review stage IS the reviewer (`orca:review-claude`, default opus/high): configuring it changes actual review quality.

The workflow's internal helper agents — the shell relay, reconciliation, escalation — are not configurable: their cost/judgment profile is part of the loop's design, not a per-repo preference.

## Step 1: Read the current state

Resolve `<repo-root>` as the parent of `git rev-parse --path-format=absolute --git-common-dir`. If not inside a git repository, explain that the config is per-repository and stop.

Defaults live in the plugin and may change across plugin versions — read them fresh rather than reciting remembered values:

```bash
grep -H -E '^(model|effort):' ${CLAUDE_PLUGIN_ROOT}/agents/*.md
```

Then read `<repo-root>/.orca/config.json` if it exists: its top-level `reviewer` key holds the pinned reviewer, its top-level `editor`/`terminal` keys the orca:review pins, its `agents` block the current stage overrides. To resolve the **effective** reviewer when the key is absent, apply the run's own detection rule — codex binary on PATH at the minimum version → codex, else claude; the bundled preflight (`bash ${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh`) prints it as the `REVIEWER:` line if you'd rather not probe by hand.

## Step 2: Show the state

Always show the effective configuration before changing anything — with no arguments, showing it may be the whole job.

First the reviewer, with provenance — e.g. `Reviewer: codex (pinned)` or `Reviewer: claude (detected — codex not on PATH)` — then `editor` and `terminal` in the same shape when set (e.g. `Editor: none (pinned — orca:review prints instead of opening)`); when absent, one line noting both detect at orca:review time, without probing here. Then the stage table:

| Stage | Role | Model | Effort |
|-------|------|-------|--------|
| spec | explores the codebase, writes the spec and work breakdown | opus | xhigh |
| plan | … | … | … |

One line per stage, role in a few words (spec: writes the spec and breakdown; plan: plans one item; implement: builds one item; review: drives the Codex review *or* performs the Claude review, per the effective reviewer — say which; fix: applies review findings; commit: commits one item; merge: merges into the integration branch; integrate: verifies the assembled feature; reproduce: turns a bug case into a deterministic repro script; hypothesize: writes ranked root-cause candidates; verify: adversarially tests one hypothesis; diagnose: judges the verdicts into a diagnosis and fix contract). Group the table by verb — the first eight stages run in feature runs (and, `spec` excepted, in a debug run's fix tail — debug runs never spawn a spec agent), the last four in debug runs. Show the effective value, marking overrides — e.g. `sonnet (override; default opus)` — so defaults and overrides are distinguishable at a glance. With reviewer claude, the review row's defaults are `orca:review-claude`'s (opus / high), not the courier's.

## Step 3: Apply changes

Arguments like `plan.model=sonnet review.effort=high reviewer=claude editor=none` apply directly. `reset` clears every override — the reviewer, editor, and terminal keys included; `reset <stage>` clears one stage; the value `default` clears a single field (`plan.model=default`, `reviewer=default`, `editor=default`, `terminal=default` — for the top-level keys, back to detection). With no arguments, show the state and ask what to change in plain conversation — do not march through all twelve stages unless asked.

Validate every assignment before writing, and reject bad ones naming the allowed values:

- stage ∈ `spec`, `plan`, `implement`, `review`, `fix`, `commit`, `merge`, `integrate`, `reproduce`, `hypothesize`, `verify`, `diagnose`
- model ∈ `haiku`, `sonnet`, `opus`, `fable` — harness model aliases; warn that `fable` only works on plans whose harness offers it
- effort ∈ `low`, `medium`, `high`, `xhigh`, `max`
- `spec.effort` is rejected with the explanation above
- `reviewer` ∈ `codex`, `claude` (or `default` to clear)
- `editor` ∈ `nvim`, `none` (or `default` to clear) · `terminal` ∈ `tmux`, `none` (or `default` to clear) — read only by orca:review, so run launches never validate them; still reject unknown values here, since orca:review fails loudly on one

These lists must match the `STAGES`/`MODELS`/`EFFORTS` constants and the reviewer check in `${CLAUDE_PLUGIN_ROOT}/scripts/work-loop.workflow.js` **and** `${CLAUDE_PLUGIN_ROOT}/scripts/debug-loop.workflow.js` — the launch-time validators that reject anything written here that they do not accept; the stage vocabulary is one shared 12-key list, and a key accepted at write time but rejected by either script bricks that verb's launches. If there is any doubt this prose is current (a plugin update may have changed the scripts), read the constants from the scripts and validate against those.

On `reviewer=claude`, state the trade-off in one sentence: the Claude reviewer keeps fresh-context independence (a separate agent, only the artifacts and the diff, an adversarial contract) but is same-model — cross-model codex review does not share the implementer's blind spots. On `reviewer=codex`, note that the codex machine gates (binary, auth, `MCP_TOOL_TIMEOUT`) must pass at run time — run the preflight to check, and point at orca:doctor if they currently fail.

An override equal to today's default is still meaningful — it pins the stage against future plugin-default changes — so keep it if the user asked for it explicitly, and say that is what it does. The same holds for pinning `reviewer=codex` on a machine where codex would be detected anyway: the pin protects the choice from a future broken PATH turning into a silent claude run (it turns into a loud preflight FAIL instead). Likewise `editor=nvim`: a later broken orca.nvim install becomes a loud orca:review FAIL instead of a silent fall-through to the printed command.

## Step 4: Write and confirm

Merge into any existing `<repo-root>/.orca/config.json` rather than overwriting unrelated keys, creating `.orca/` if needed. In the bare-repo layout orca:init creates, `.orca/` sits outside every worktree and cannot be committed; in a conventional checkout, `<repo-root>` **is** the working tree, so when creating `.orca/` there, also append `.orca/` to `<git-common-dir>/info/exclude` (if not already present) — the per-clone ignore file — so a stray `git add -A` never commits per-machine model preferences; the repo's tracked `.gitignore` stays untouched. Store only the overridden fields:

```json
{
  "reviewer": "claude",
  "editor": "none",
  "agents": {
    "plan": { "effort": "high" },
    "implement": { "model": "opus" }
  }
}
```

Cleared fields are removed, an empty stage object is removed, an empty `agents` block is removed, a cleared top-level key (`reviewer`, `editor`, `terminal`) is removed entirely (never written as `null` or `"default"`), and a file left `{}` is deleted.

Then show the resulting state once more and state when it takes effect: the **next orca run launch** (feature or debug) — except `editor`/`terminal`, which orca:review reads fresh on every invocation. A run already in flight keeps the configuration it launched with, and a resume (`resumeFromRunId`) does too — orca:feature records the launch-time agents block and reviewer in the run's `spec.md`, orca:debug in the case's `case.md`, and resumes replay that record, never this file — so editing overrides here affects only future launches.

## Guidelines

- Never edit `${CLAUDE_PLUGIN_ROOT}/agents/*.md` — plugin files are replaced on update, and the defaults are the plugin's to set. Overrides live only in the repo's `.orca/config.json`.
- This skill configures the reviewer choice, the orca:review `editor`/`terminal` keys, and models/effort only. The codex machine setup (binary, auth, MCP timeout) and the orca.nvim install belong to orca:doctor; repository layout belongs to orca:init; run behavior belongs to orca:feature and orca:debug; opening the review itself belongs to orca:review.
- Advise, don't moralize: if an override looks self-defeating (haiku for plan or merge, where judgment failures cost whole items; max effort on commit, which formats a message), say so in one sentence and write what the user chose.
