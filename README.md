# orca

A [Claude Code](https://claude.com/claude-code) plugin for autonomous, multi-agent feature development. Capture intent as a brief, set the repository up once, then let a deterministic workflow drive the feature from idea to a committed integration branch — planned, implemented, cross-model reviewed, fixed, committed, merged, and verified, with the user interacting exactly once (or twice, by opt-in).

```text
/orca:brief <idea>     # interview → durable brief file        (interactive)
/orca:init             # one-time repository & tooling setup   (interactive, consent per step)
/orca:run              # brief → spec → work loop → report     (autonomous after one confirmation)
/orca:config           # optional per-repo model/effort tuning
```

The deliverable of a run is a `feature/<slug>` branch on an integration worktree, which you land yourself with `git merge --no-ff feature/<slug>`. The run never touches your own worktree, and no commit it produces mentions Claude, AI, agents, or orca.

## Table of contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Anatomy of a run](#anatomy-of-a-run)
- [Repository layout](#repository-layout)
- [Stage agents](#stage-agents)
- [Configuration](#configuration)
- [Permissions and autonomy](#permissions-and-autonomy)
- [Interruption, resume, and cleanup](#interruption-resume-and-cleanup)
- [Troubleshooting](#troubleshooting)
- [Migrating from the pre-plugin skills](#migrating-from-the-pre-plugin-skills)
- [Repository contents](#repository-contents)

## How it works

Three design choices carry the whole system:

**Double isolation.** Every stage (spec, plan, implement, review, fix, commit, merge, integrate) runs in a dedicated subagent with its own context window, and every work item gets its own git worktree off a shared bare repository. Heavy context — codebase exploration, diffs, test output — lives and dies inside subagents; the main conversation only reads artifact files and the workflow's structured result. Parallel items can never corrupt each other's files: overlap surfaces as an explicit merge conflict, resolved by a merge agent holding both items' plans.

**Cross-model review.** Claude implements; [Codex](https://openai.com/codex/) reviews. The plugin bundles an MCP registration for the global `codex` binary (`codex mcp-server`), and a dedicated review agent drives it adversarially over each item's diff before anything is committed — an independent second opinion from a different model family, one that does not share the implementer's blind spots. The review prompt explicitly attacks the tests, since the same model family wrote the code and the tests.

**A deterministic work loop.** The long autonomous middle of a run is one bundled script executed through Claude Code's Workflow tool, not conversational orchestration. Scheduling, retry bounds, review throttling, merge serialization, and the commit-attribution check are code, so the guarantees are structural rather than model discipline that decays over a long context. Judgment calls (plan reconciliation, escalation, review verdicts) stay in agents, but as schema'd calls whose reasons land in the run's artifacts. Every agent call is journaled, so an interrupted run resumes where it stopped.

State lives in files, never in conversation memory: the brief, the spec with its work breakdown and decision log, one plan per item, the raw Codex findings per review round, and a final report — all under a per-run directory in `.orca/`.

## Requirements

| Requirement | Detail |
|---|---|
| Claude Code | A harness with the **Workflow tool** (the work loop runs through it). `/orca:run` checks and refuses without it. |
| Codex CLI | The **global `codex` binary on PATH**, version **≥ 0.142.5**, authenticated via `codex login`. **Never install codex via npm** — use `brew install codex` or the official release binaries. |
| Repository layout | Bare-repo-with-worktrees (`.bare/` + peer worktrees). `/orca:init` sets this up, including converting an existing conventional checkout in place. |
| git | ≥ 2.5 (worktrees); ≥ 2.42 for `worktree add --orphan` when `/orca:init` creates a brand-new repository. |
| `MCP_TOOL_TIMEOUT` | Set to `1200000` (~20 min) in a Claude Code settings `env` block, so Codex reviews are not killed at the default MCP tool timeout. A plugin cannot ship session env, so `/orca:init` writes it for you. |
| Permission mode | Runs need `bypassPermissions` for the session — see [Permissions and autonomy](#permissions-and-autonomy). |

Everything else — the eight stage agents and the codex MCP server registration — ships inside the plugin itself; there is nothing to install per repository beyond the layout.

## Installation

For local development, load the checkout directly:

```bash
claude --plugin-dir /path/to/this/repo
```

Distribution through a plugin marketplace is the eventual install story; it is not set up yet.

MCP servers load at session start, so after installing or enabling the plugin, **start a fresh session** before running — `/orca:run` verifies live that the codex MCP tool resolves and stops if it does not.

## Quick start

```bash
# 1. One-time: make the repository pass pre-flight (layout + Codex tooling).
#    Interactive, consent per step. Converting an existing checkout preserves
#    untracked files (.env, caches) but changes every path — see /orca:init.
/orca:init

# 2. Capture intent. An interview: outcome, features, non-goals, constraints,
#    doubt rule. Takes as many rounds as the idea needs; writes a brief file.
/orca:brief add rate limiting to the public API

# 3. Run. Discovers the brief, restates it, asks for ONE confirmation,
#    then runs autonomously to a final report and a feature/<slug> branch.
/orca:run

# 4. Land the deliverable from your own worktree.
git merge --no-ff feature/<slug>
```

Briefs can be queued ahead of time — everything at the top level of `.orca/briefs/` is ready and unconsumed, and a run consumes exactly one.

## Commands

### `/orca:brief <idea>`

An interactive interview that sharpens a rough idea into a durable brief at `.orca/briefs/<timestamp>-<slug>.md`. The brief is the *entire* intent a later run acts on — the run asks nothing beyond one confirmation — so the interview is deliberately adversarial about scope: it pushes back, hunts for unstated non-goals, and makes you resolve ambiguities now rather than leaving them for an autonomous run to guess at.

A brief records: **outcome**, **features**, **non-goals**, **inputs & outputs**, **constraints**, plus two run-controlling choices:

- **Doubt rule** — when the run hits an ambiguity, does it prefer the smaller interpretation and cut scope (`prefer-smaller-scope`, the default) or the more complete one (`prefer-complete`)?
- **Breakdown checkpoint** — review the spec and work breakdown once before any code (`review-once`), or run straight through (`straight-through`, the default)?

The brief is *what and why*, never *how*: no work breakdown, no interfaces, no file ownership — those come from the run's spec stage, grounded in real codebase exploration. Location is status: top-level briefs are ready; park unfinished ones in `.orca/briefs/drafts/`. One brief is one run's scope — two independent efforts get two briefs.

### `/orca:init [path or clone URL]`

One-time, consent-per-step setup that makes a repository pass `/orca:run`'s pre-flight. Handles three cases:

- **New repository** — bare-init plus a default-branch worktree.
- **Clone a URL** — bare clone, fetch refspec fix (bare clones silently fetch nothing without it), default-branch worktree.
- **Convert an existing checkout** — restructures in place: `.git` becomes `.bare`, tracked files move into a `<branch>/` worktree, and **untracked files (including ignored ones — `.env`s, caches) are carried over** via a manifest before anything is deleted. Every path changes, so editors and terminals need re-pointing; the conversion is layout-only (no history, refs, or remotes touched) and reversible until the final cleanup step, which is confirmed separately.

Preconditions for conversion — it stops rather than improvising: a clean tree, no existing linked worktrees, no submodules.

It also fixes the machine gates the pre-flight flags: Codex CLI presence/version/auth (pointing you at the official non-npm install and `codex login` — installing and authenticating are your actions), and the `MCP_TOOL_TIMEOUT` settings write. Optionally — offered, never defaulted — it can write `bypassPermissions` as the default mode for a repo where runs are always unattended.

### `/orca:run`

The autonomous run. See [Anatomy of a run](#anatomy-of-a-run) for the full lifecycle. Interaction surface, in total:

1. **One confirmation** of the restated brief (plus trunk-branch confirmation) — this authorizes everything that follows.
2. **One optional checkpoint** — only if the brief opted in: review the spec and work breakdown before any code.

After that, nothing asks you anything. Ambiguities resolve against the spec and the doubt rule; what cannot be resolved that way becomes a `blocked` item in the final report, with the options you must choose between recorded. Mid-run, live per-item status shows on the session task list; the outcome lands in `report.md`.

Without a brief, `/orca:run` stops and points you at `/orca:brief` — it never interviews as a substitute. (This is orca's feature run, not Claude Code's built-in `/run` skill that launches the project's app; the namespace keeps them apart.)

### `/orca:config [assignments | reset]`

Optional per-repository overrides for which Claude model and reasoning effort each stage agent runs with, written to the `agents` block of `.orca/config.json` and applied by the **next** run launch (a run in flight, or a resume of one, keeps its launch-time config).

```bash
/orca:config                                # show the effective table
/orca:config plan.model=sonnet review.effort=high
/orca:config plan.model=default             # clear one field
/orca:config reset plan                     # clear one stage
/orca:config reset                          # clear everything
```

Valid values — models `haiku` | `sonnet` | `opus` | `fable`, efforts `low` | `medium` | `high` | `xhigh` | `max`. Two caveats: `spec` accepts a model override only (it is spawned conversationally, where effort cannot be set), and configuring `review` changes the cost of the *courier* that drives Codex, never the quality of Codex's review itself. Overrides survive plugin updates; the plugin's own agent definitions are never edited.

## Anatomy of a run

```text
/orca:run
   │
   ├─ 0. Discover the brief         .orca/briefs/*.md — exactly one, or ask which
   ├─ 1. Pre-flight + confirm       preflight.sh gates, Workflow tool, live MCP
   │                                check, bypassPermissions; ONE user confirmation
   ├─ 2. Spec (orca:spec)           read-only codebase exploration → spec.md with
   │                                Interfaces + a 2–8 item dependency-ordered
   │                                Work Breakdown with file ownership
   ├─ 3. Announce / checkpoint      status update, or the one opt-in approval;
   │                                create integration worktree on feature/<slug>
   ├─ 4. Work loop (Workflow tool)  deterministic script, per readiness wave:
   │       plan ∥ ──► reconcile ──► [escalate/amend once] ──► per item:
   │       worktree ► implement ► codex review ► fix ► re-review ► commit ► merge
   │       …then, after the loop drains: integrate (verify the assembled feature)
   └─ 5. Report                     report.md: shipped/cut/blocked, deviations,
                                    integration verification, follow-ups, landing
```

**Pre-flight** (`skills/run/scripts/preflight.sh`, read-only, also runnable early from `/orca:brief`) prints one machine-readable line per gate: `BARE_REPO`, `CODEX` (binary ≥ 0.142.5, authenticated, `MCP_TOOL_TIMEOUT` set), an informational `TRUNK_CANDIDATE`, and a final `RESULT` mirrored by the exit code. On any `FAIL` the run does not start; remediation goes through `/orca:init`.

**Spec** is written once, by a dedicated read-only agent, from the confirmed brief. Its two load-bearing sections: **Interfaces Between Work Items** — the contracts (type shapes, signatures, file ownership, naming) that let items build in parallel without inventing incompatible seams — and the **Work Breakdown**, which becomes the workflow's item list verbatim. If the requested scope cannot be split cleanly against the codebase, the run surfaces that and stops rather than launching against a spec known to be wrong.

**The work loop** is completion-driven: an item launches the moment its dependencies merge and advances the moment its previous stage finishes. The only synchronization points are deliberate — a per-wave plan-reconciliation barrier (an opus agent checks the wave's plans against the spec Interfaces before anything builds) and the serialized merge queue. Bounded loops keep it from thrashing: max 2 fix rounds gated on Critical/High Codex findings; a deterministic commit-attribution check against the actual `git log` (two attempts, then a forced rewrite); one amendment round per reconciliation failure; at most one escalation-backed replan-and-rebuild per item. Codex reviews are throttled to 2 concurrent slots (one Codex auth) while everything else parallelizes freely.

**Escalation** applies one rule: **amend and continue** when a fix preserves the brief's outcome, features, and non-goals (the change touches only *how*) — recorded in the spec's `## Decisions` log with the doubt rule cited; **block and route around** when every fix would change *what* was agreed. A blocked item keeps its worktree and branch for a follow-up run and never stalls unaffected work. Under `prefer-smaller-scope`, cleanly cutting a feature counts as an amendment.

**Integration verification** runs after the loop drains: a dedicated agent builds, tests, and exercises each spec feature end to end in the integration worktree, judging against the spec's Outcome and Features — looking specifically at the seams where items compose. Small integration bugs are fixed, review-checked, and committed; larger mismatches are reported as gaps.

**The report** (`report.md`) is the durable record: shipped items with commit hashes, deviations mirroring the spec's Decisions log, blocked items with the decision each waits on, per-feature integration results, follow-ups sourced from the plans' Deviations sections, and the landing command.

## Repository layout

What a repository looks like mid-run (`/orca:init` creates the top three entries; the run creates the rest and cleans up its item worktrees after merge):

```text
<repo-root>/
├── .bare/                        # the bare repository (shared object store)
├── .git                          # one line: gitdir: ./.bare
├── main/                         # your worktree(s) — never touched by the run
├── orca-<slug>/                  # integration worktree (branch feature/<slug>)
├── orca-<slug>-W1/               # one worktree per in-flight item (branch feature/<slug>-W1)
└── .orca/
    ├── config.json               # optional per-repo model/effort overrides
    ├── briefs/                   # unconsumed briefs (drafts/ for parked ones)
    └── YYYYMMDD-HHMMSS-<slug>/   # one directory per run
        ├── brief.md              # the consumed brief — moved here when the run starts
        ├── spec.md               # spec, work breakdown, Decisions log, workflow runId
        ├── report.md             # final run report
        ├── plans/                # one plan per item, with its Deviations section
        └── reviews/              # raw Codex findings JSON, archived per review round
```

Two naming namespaces, deliberately different: `orca-*` **directory** names are local scratch — the cleanup and discovery story via `git worktree list` — and never enter git; `feature/<slug>[-<ID>]` **branch** names are what lands in history and on GitHub, and carry no orca trace. `.orca/` sits outside every worktree, so its contents cannot be committed by accident.

## Stage agents

Eight agents ship in the plugin (`agents/<stage>.md`, loaded as `orca:<stage>`). Each runs with its own context window and only the per-item values it needs; context passes between stages through artifact files, never relayed summaries.

| Stage | Role | Default model | Default effort |
|---|---|---|---|
| `spec` | Explores the codebase; writes the spec and work breakdown (once, at the start) | opus | xhigh |
| `plan` | Read-only planner for one item; writes a plan a cheaper implementer can follow | opus | xhigh |
| `implement` | Builds one item in its worktree, checking off and amending its plan | sonnet | high |
| `review` | Courier that drives the Codex review via MCP and files the findings verbatim | sonnet | medium |
| `fix` | Applies Codex findings; escalates findings rooted in the plan, spec, or other items | opus | high |
| `commit` | One Conventional Commit per item, staged by name, no attribution | haiku | low |
| `merge` | Serialized merge into the integration branch; resolves conflicts with both plans in hand; verifies the merged result | opus | high |
| `integrate` | Verifies the assembled feature end to end against the spec | opus | high |

Override any of these per repository with [`/orca:config`](#orcaconfig-assignments--reset). The workflow's internal helper agents (reconciliation, escalation) are not configurable — their cost/judgment profile is part of the loop's design.

## Configuration

**`.orca/config.json`** (repo root, written by `/orca:config`) — per-stage model/effort overrides, applied on top of the agent defaults at the next run launch:

```json
{
  "agents": {
    "plan": { "effort": "high" },
    "implement": { "model": "opus" }
  }
}
```

**`MCP_TOOL_TIMEOUT`** — client-side session env governing MCP tool-call timeouts; a plugin cannot ship it, so `/orca:init` writes it into the `env` block of `.claude/settings.local.json` (or `~/.claude/settings.json`):

```json
{ "env": { "MCP_TOOL_TIMEOUT": "1200000" } }
```

~20 minutes is deliberate: the workflow retries reviews at two levels, so this value multiplies into the per-item worst case (~80 minutes at this setting; an hour would balloon it to several). Settings env loads at **session start** — restart the session after writing it.

**Bundled `.mcp.json`** — registers the codex MCP server as the global PATH binary, nothing else:

```json
{ "mcpServers": { "codex": { "command": "codex", "args": ["mcp-server"] } } }
```

## Permissions and autonomy

A run only stays autonomous if the harness never raises a permission prompt: every workflow-spawned subagent inherits the session's permission mode, a single foreground prompt breaks autonomy mid-run, and an auto-denied call makes an agent fail confusingly instead.

**This requires `bypassPermissions` mode — an allow-list is not sufficient.** The subagents decide commands at runtime (dependency installs, build/test variants, assorted git invocations), so the command set is open-ended; and Bash permission rules match as prefix globs against the literal command string, so listed commands still slip through when they contain `$(…)`, lead with flags, or are compound. A leaked prompt is a question of *when*, not *whether*.

Enable it one of three ways: Shift+Tab in-session until the footer shows "bypass permissions" (easiest, right before the run); `claude --dangerously-skip-permissions` at launch; or `"permissions": { "defaultMode": "bypassPermissions" }` in `.claude/settings.local.json` for always-unattended repos (offered by `/orca:init`, never defaulted).

The tradeoff is real and `/orca:run` states it before starting: bypass mode disables the approval gate for the **whole session**, not just the run — a dedicated session for the run is the clean choice. If you won't enable it, the run does not start; it would only pause partway.

## Interruption, resume, and cleanup

Every agent call in the work loop is journaled, and the workflow `runId` is persisted to the end of `spec.md` (as `**Workflow run:** <runId>`, alongside the launch-time `agents` block when one was passed) the moment the workflow launches — precisely because the interruption that needs it, session death, also erases the conversation.

- **Interrupted run** (session death, kill, harness restart): re-invoke `/orca:run`'s workflow with the same script and args plus `resumeFromRunId`, rebuilt from `spec.md` — the skill knows this procedure; you just ask it to resume. Completed agent calls replay instantly from the journal; only in-flight and remaining work runs live. Never re-run stages conversationally.
- **Blocked items** keep their worktree and branch deliberately — the report lists them for a follow-up run.
- **Abandoned run**: `git worktree list`, remove leftover `orca-*` worktrees and their `feature/<slug>*` branches. Prefer resuming.
- **Pre-plugin runs cannot resume** under the plugin (agent types, worktree names, and journal keys all changed) — clean up their leftovers and start fresh from a new brief.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `BARE_REPO: FAIL: conventional checkout` | The repo isn't in the bare-with-worktrees layout. Run `/orca:init` — it converts interactively, preserving untracked files. |
| `CODEX: FAIL: codex not on PATH` / version too old | Install or upgrade the Codex CLI from the official non-npm distribution (`brew install codex` or the release binaries). **Never `npm i -g @openai/codex`.** |
| `CODEX: FAIL: not authenticated` | Run `codex login` (interactive; your action, not the agent's). Verify with `codex login status`. |
| `CODEX: FAIL: MCP_TOOL_TIMEOUT not set` | Run `/orca:init` to write it into a settings env block, then start a fresh session. |
| `/orca:run` says the codex MCP tool doesn't resolve | MCP servers load at session start. Check the plugin is installed and enabled, then start a fresh session in the project. |
| `/orca:run` says the harness has no Workflow tool | The work loop needs a Claude Code harness with workflows; there is no conversational fallback. |
| Run pauses on a permission prompt | The session wasn't in `bypassPermissions` mode. Enable it (Shift+Tab) and resume via the journal rather than restarting. |
| `/orca:run` finds no brief | Runs start only from a brief. Run `/orca:brief <idea>` first; `/orca:run` discovers it automatically. |
| `git fetch` does nothing in a bare clone made by hand | Bare clones get no fetch refspec. `/orca:init`'s clone path sets `remote.origin.fetch` — do the same, or re-clone through it. |

## Migrating from the pre-plugin skills

This repository previously shipped the same workflow as symlink-installed skills named `briefify`/`initify`/`orchestrify` (plus a Codex CLI variant, now scrapped). If you used those:

- Remove the old symlinks from `~/.claude/skills` and `~/.claude/agents`.
- Queued briefs migrate with `mv .orchestrify .orca` at the repo root.
- In-flight pre-migration runs cannot resume under the plugin — clean up any leftover `orchestrify-*` worktrees and start fresh from a new brief.

## Repository contents

| Path | Contents |
|---|---|
| `.claude-plugin/plugin.json` | The plugin manifest (`orca`). |
| `.mcp.json` | Bundled codex MCP server registration — the global PATH `codex` binary, never npm. |
| `skills/brief/`, `skills/init/`, `skills/run/`, `skills/config/` | The four skills. |
| `skills/run/scripts/preflight.sh` | Read-only environment validation — the gate lines above. |
| `skills/run/scripts/work-loop.workflow.js` | The deterministic work loop, run through the Workflow tool. |
| `agents/` | The eight stage agents, loaded as `orca:<stage>`. |
| `plans/` | Design documents (e.g. the plugin migration plan). Not part of the plugin surface. |
