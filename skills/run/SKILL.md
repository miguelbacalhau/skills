---
description: Drive a feature from idea to committed code using a deterministic workflow over dedicated subagents — an autonomous orca feature run, NOT the built-in /run skill that launches or screenshots the project's app. Use when Claude should run fully autonomously from a confirmed brief — discover the brief file the orca:brief skill wrote in `.orca/briefs/`, restate and confirm it once, write a spec with a dependency-ordered work breakdown, then execute the work loop as a single Workflow-tool run that, per unblocked item, plans and implements in its own git worktree branched off a shared bare repository, reviews with an independent reviewer — cross-model Codex where it is installed or pinned, a dedicated fresh-context Claude reviewer otherwise — plus a Claude fix agent, commits, and serially merges into an integration worktree. Requires a brief (without one, the skill only points the user at orca:brief and stops), a bare-repo-with-worktrees layout (validated up front), and a harness with the Workflow tool; there is no privileged main checkout, and the run's deliverable is a branch the user lands themselves. After the opening confirmation — plus one optional breakdown checkpoint the brief opts into — nothing else asks the user anything; undecidable issues are reported at the end. Do not use for small single-file changes or when the user only wants a spec or a plan.
args: <idea>
user-invocable: true
disable-model-invocation: true
---

# Orca: run

Coordinate a full implementation through isolated subagents. The main conversation handles everything interactive and cheap — the brief, the pre-flights, the spec, the checkpoint, and the final report — and delegates the long autonomous middle to **one deterministic workflow**: a bundled script, run through the Workflow tool, that spawns every stage agent with code-enforced control flow. All heavy context — codebase exploration, diffs, test output — lives and dies inside subagents; the main conversation only reads artifact files and the workflow's structured result.

Isolation is double: each subagent has its own context window, and each work item has its own git worktree. The repository is a bare repo, and every working copy — the user's, the run's integration tree, and each item — is a peer worktree off that one shared object store. There is no privileged main checkout: the run never reads or writes the user's worktree, and the deliverable is a branch the user lands themselves. Parallel items can never corrupt each other's files — overlap surfaces as an explicit merge conflict, resolved by a dedicated merge agent with both items' plans in hand.

The brief is where the user sets intent — written earlier with the orca:brief skill, discovered on disk, and confirmed once at the start of the run. It may also opt into a single checkpoint: a one-time review of the spec and work breakdown before any code is written. Apart from the opening confirmation and that opt-in checkpoint, never ask the user anything — no mid-run clarifications, no approval gates, no AskUserQuestion. The workflow runs autonomously in the background and could not pause for a question even if one arose; anything it cannot decide within the brief's stated intent becomes a `blocked` item surfaced in the final report.

## Input

The run starts from a brief — a captured interview, written earlier by the orca:brief skill. This skill does not interview: capturing intent well takes an unhurried conversation, and that conversation is orca:brief's whole job.

Check for a waiting brief: list `.orca/briefs/*.md` at the repo root — one `ls`, filenames only, never reading files to decide. The directory's top level holds only unconsumed briefs (its `drafts/` subdirectory does not count), so presence is status.

- **Exactly one brief:** read it and proceed to Step 1.
- **Several briefs:** present the filenames — the timestamped names identify them — and ask which one this run is for. Read only the chosen one.
- **None:** stop. Tell the user orca runs from a brief and to run `/orca:brief` first — suggesting it with any idea they gave, e.g. `/orca:brief <their idea>` — then invoke `/orca:run` again. Do not interview as a substitute, and do not run orca:brief for them: the discussion is theirs to have.
- **An idea argument alongside a brief:** if it names the same work, fold it into the brief as an amendment at the Step 1 confirmation; if it is unrelated, ask whether to run the brief anyway or take the new idea to orca:brief first.

## Step 1: Confirm the brief

The brief is the only place intent was captured — once this step ends, the run is autonomous and every later ambiguity gets resolved against what the brief says. Restate it to the user: outcome, features, non-goals, inputs/outputs, constraints, doubt rule, and breakdown-checkpoint choice, plus any amendments folded in from an idea argument. Note the brief's age from its `Created` line and warn when it is more than a few days old — the codebase and the user's intent may have moved since it was written.

If the brief is missing the doubt rule or the checkpoint choice (orca:brief always writes them; a hand-written brief may not), apply the defaults — prefer-smaller-scope, straight-through — and state them in the restatement rather than asking. The breakdown checkpoint, when the brief opts in, is a one-time review of the spec and work breakdown before any worktree or code: the decomposition is where parallel-agent mistakes originate, and it is the only optional pause in the run.

The user's confirmation of the restated brief authorizes the run. If the brief opted into the breakdown checkpoint, the only remaining interaction is that one approval in Step 3; otherwise there is no later gate at all. From this point on, never ask the user anything else; proceed on recorded assumptions.

### Environment pre-flight (script)

The run's mechanical prerequisites — the bare-repo layout and, when the reviewer is codex, the Codex tooling — are validated by one bundled script, which also resolves **which independent reviewer this run uses**. Run it during this step, before the confirmation, from the project root:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/preflight.sh
```

`${CLAUDE_PLUGIN_ROOT}` substitutes to this plugin's installed root, so the resulting path is already absolute. The script is read-only and prints one line per gate plus a final result:

- `BARE_REPO: PASS|FAIL` — the project is a bare repository with worktrees.
- `TRUNK_CANDIDATE: <branch>` — informational, not a gate: the bare repo's default branch, the run's likely trunk. Confirm the trunk with the user; the integration branch is created from its tip.
- `REVIEWER: codex|claude (pinned|detected)` — informational, but load-bearing for this run: the resolved reviewer. `pinned` means the `reviewer` key in `.orca/config.json` chose it; `detected` means the key is absent and the machine decided (codex binary on PATH at the minimum version → codex, else claude). A `REVIEWER: FAIL` line means the config key is invalid — point the user at orca:config and stop.
- `CODEX: PASS|FAIL|SKIPPED` — checked only when the resolved reviewer is codex: the global `codex` binary is on PATH at or above the minimum version, authenticated, and `MCP_TOOL_TIMEOUT` is set in a settings env block. With reviewer claude it prints `SKIPPED` — not checked, deliberately.
- `RESULT: PASS|FAIL` — mirrored by the exit code, which is 0 iff every gate passed.

There is no agents gate and no MCP-registration gate: the stage agents and the codex MCP server registration ship inside this plugin, so a session that can run this skill has them by construction.

On `RESULT: PASS`, proceed. On any `FAIL`, do not start — relay the failing gate's remediation below and stop. These are pre-flight gates, not mid-run questions. In particular, a pinned or detected codex whose auth or timeout check fails is a `FAIL` to fix via orca:doctor — never a reason to silently run with the claude reviewer instead.

One gate the script cannot check: the harness must expose the **Workflow tool** (Step 4 runs through it). If this session has no Workflow tool, stop and tell the user this skill requires a Claude Code harness with workflows.

A second gate only the session can check, **and only when the resolved reviewer is codex** — the **live MCP gate**: MCP servers load at session start, so the plugin's bundled registration is only useful if this session actually loaded it (a plugin installed or enabled minutes ago has not). Before launching the workflow, confirm the tool actually resolves: call ToolSearch with `select:mcp__plugin_orca_orca-codex__codex`. If it does not resolve, diagnose which of the two causes this is before stopping. A known harness bug (present as of Claude Code 2.1.202) loads none of a plugin's bundled MCP servers when the project carries any MCP config of its own — a `.mcp.json` at the repo root, or local-scope servers (`claude mcp list` shows both, or read the file). If such config exists, that is the cause: a leftover `codex` registration is redundant — the plugin bundles the server — and the user should remove it; a project that genuinely needs its own MCP servers can pin `reviewer=claude` via orca:config until the harness bug is fixed, with the cross-model trade-off stated. If no such config exists, the session simply predates the plugin's install or enablement. Either way, the user fixes the cause and starts a fresh session in this project — the brief is untouched — and you stop. With reviewer claude there is no MCP dependency and this check is skipped.

**Why each gate, and how to fix a `FAIL`:**

- **Bare repo** is the substrate the entire run depends on: every working copy — the user's, the integration tree, each item — is a peer worktree off one shared bare object store, so there is no privileged main checkout to corrupt. A `FAIL` means the repo is a conventional checkout. Converting it is the user's decision — never convert autonomously. Point them at the **orca:init skill**, which performs the conversion interactively with consent per step (and also sets up new repositories and bare clones); it preserves untracked files like `.env` that a naive re-checkout would lose.
- **Reviewer** is the work loop's independent review. **Codex** — the default wherever the binary is installed — is the cross-model choice: a different model family from the Claude implementer, so it does not share the implementer's blind spots. **Claude** (the `orca:review-claude` agent) keeps fresh-context independence — a separate agent seeing only the artifacts and the diff, with an adversarial contract — but is same-model; it is the detected fallback where codex is not installed, and a legitimate pin either way via orca:config.
- **Codex**, when it is the reviewer: a missing, stale, or unauthenticated reviewer would fail every item at review time, deep into an autonomous run. The reviewer is the **global codex binary's MCP server** (`codex mcp-server`), registered by this plugin's bundled `.mcp.json` wherever the plugin is active — codex is **never installed via npm**: the only supported install is the system one on PATH, from the official non-npm distribution (e.g. `brew install codex`, or the release binaries). Whatever the failing check — install, upgrade, `codex login`, or the `MCP_TOOL_TIMEOUT` settings write — point the user at the **orca:doctor skill**, which walks the machine gates interactively (a plugin cannot set the session env that governs MCP tool-call timeouts, so that knob stays a per-repo or per-user settings write). Installing, authenticating, and settings writes are the user's actions — surface the fix, do not do it autonomously.

### Permissions pre-flight

The run only stays autonomous if the harness will not raise permission prompts: subagents — including every agent the workflow spawns — inherit this session's permission mode, and the skill's own frontmatter does not propagate to them. A single foreground prompt mid-run breaks autonomy, and an auto-denied call makes an agent fail confusingly instead.

**This requires `bypassPermissions` mode — an allow-list is not sufficient.** The subagents are themselves models that decide commands at runtime (dependency installs, build and test variants, git invocations with assorted flags, `find`, `sed`, and so on), so the command set is open-ended and no static `permissions.allow` list can anticipate it. Beyond that, the harness matches Bash rules as prefix globs against the literal command string, so even listed commands slip through when they contain `$(…)` substitutions, lead with flags like `git --git-dir=…`, or are compound (`cd foo && …`). A leaked prompt is therefore a question of *when*, not *whether* — which is why the fix is the session mode, not the rules.

The skill cannot flip the mode itself, so confirm it during this step, before the confirmation: the session must be in `bypassPermissions` mode for the run. Enable it one of three ways:

- **In-session toggle** — press Shift+Tab to cycle the permission mode until the footer shows "bypass permissions". Easiest; do it right before the run.
- **Launch flag** — start the CLI with `claude --dangerously-skip-permissions`.
- **Settings** — `"permissions": { "defaultMode": "bypassPermissions" }` in `.claude/settings.local.json`, for a repo where runs are always unattended.

Make the tradeoff explicit to the user: bypass mode disables the approval gate for the *whole* session, not just this run's commands. That is the point — the run is designed to be unattended — but any other work in the same session loses the gate too, so a dedicated session for the run is the clean choice. If the user will not enable bypass mode, do not start: the run cannot be autonomous, and an allow-list will only let it pause partway.

## Step 2: Write the spec and work breakdown

Create the run directory at the project root — the directory that holds the bare repo and its worktrees. It holds only run metadata. Every worktree lives at the **top level of the repo**, as a sibling of the bare repo and the user's own worktrees — never inside `.orca/`:

```text
<repo-root>/
├── .bare/                              # the bare repository (shared object store)
├── <user worktrees…>                   # e.g. main/ — untouched by the run
├── orca-<slug>/                        # integration worktree (branch feature/<slug>)
├── orca-<slug>-<ID>/                   # one worktree per in-flight item (e.g. orca-<slug>-W1, branch feature/<slug>-W1)
└── .orca/YYYYMMDD-HHMMSS-<slug>/
    ├── brief.md    # the consumed brief — the run's confirmed intent
    ├── spec.md     # requirements, interfaces, work breakdown, workflow runId
    ├── report.md   # final run report, written at the end
    ├── plans/      # one plan file per work item, written by plan agents
    └── reviews/    # review findings artifacts (codex or claude), archived per round
```

- `<repo-root>` is the directory containing the bare repo — resolve it as the parent of `git rev-parse --path-format=absolute --git-common-dir`.
- Generate the timestamp by running `date +%Y%m%d-%H%M%S`.
- Make `<slug>` a short kebab-case description of the idea, 3-5 words max.
- Worktree directories sit at `<repo-root>` and are named after the run — `orca-<slug>` for integration, `orca-<slug>-<ID>` for each item — while their branches use the neutral `feature/<slug>[-<ID>]` namespace. The difference is deliberate: the `orca-*` directory names are local scratch and the run's cleanup/discovery story (`git worktree list`), and never enter git; the `feature/*` branch names are what lands in git and shows on GitHub, so they carry no orca trace. The `.orca/` metadata is scratch space on disk, outside every worktree, so nothing in it can be committed by accident.

Consume the brief now: `mv` it to `<run-dir>/brief.md`. The move is what marks it used — the briefs directory only ever holds unconsumed briefs — and it archives the confirmed intent with the run that acted on it.

With the run directory scaffolded, **delegate the spec — do not explore the codebase in the main context.** Heavy exploration lives and dies in a subagent, and the main conversation only reads the artifact that comes back. Spawn one `orca:spec` subagent, passing only:

- the run directory
- the repository root (`<repo-root>`)
- the current timestamp, from `date +"%Y-%m-%d %H:%M"` — the agent has no shell, so it cannot generate one for the spec's `Created` line
- the **brief**: the outcome, features, non-goals, inputs/outputs, constraints, and doubt rule from the confirmed brief, plus any amendments confirmed with it

**Read the model config once, before the spec spawn.** If `<repo-root>/.orca/config.json` exists, read its `agents` block (written by the orca:config skill) and validate it now, while nothing has been spent: stage keys ∈ `spec`/`plan`/`implement`/`review`/`fix`/`commit`/`merge`/`integrate`, fields `model`/`effort` only, model ∈ `haiku`/`sonnet`/`opus`/`fable`, effort ∈ `low`/`medium`/`high`/`xhigh`/`max`, and `spec` takes `model` only — the same rules the workflow script re-checks at launch, but a failure there would land only after the whole spec stage has run. Validate the top-level `reviewer` key with the same fail-fast posture: when present it must be exactly `"codex"` or `"claude"`. On a bad block or a bad reviewer, stop before spawning anything, name the bad field, and point the user at orca:config — never author or repair the file here. Hold the validated block for the rest of the run: Step 4 passes this held copy into the Workflow args, and no step re-reads the file — a config edited mid-run must not change a run already in flight.

**Hold the resolved reviewer alongside it.** The run's reviewer is the config's pinned value when the key is present, else the detected value from Step 1's `REVIEWER:` preflight line — that line is the source; do not probe the machine a second time. The held value goes into the Workflow args and the spec.md record below; like the agents block, it is fixed at launch.

If the held block sets `agents.spec.model`, spawn the spec agent with that model override — on every spec spawn, including a Step 3 checkpoint re-spawn; effort has no conversational override — the Agent tool has no effort parameter — so the spec agent's effort always comes from its own definition.

Pass the brief faithfully — it is the whole of the user's intent, and every later autonomous decision cites the spec it produces. The agent explores the codebase, defines the shared **Interfaces Between Work Items**, and writes the full spec — outcome, features, non-goals, inputs/outputs, interfaces, a 2-8 item dependency-ordered **Work Breakdown** with file ownership, assumptions, the doubt rule, and risks — to `<run-dir>/spec.md`, returning a short summary. Its exploration dies with its context; only `spec.md` and the summary return. If the agent reports that the requested scope cannot be split cleanly against the codebase — a feature the existing code fights, an interface it forces — surface that to the user and stop rather than launching a run against a spec known to be wrong.

The spec agent authors `spec.md` **once**. During the run, mid-loop amendments — interface revisions, breakdown changes, the `## Decisions` log — are made by the workflow's escalation agent (Step 4), never by a re-spawn; the sole exception is a structural revision requested at the Step 3 checkpoint, which re-spawns the spec agent (see Step 3).

Read the returned `spec.md` — an artifact, not source. Its Work Breakdown is the run's item list; there is no separate status file to maintain. Mid-run, the live status is the workflow's own progress display and journal — do not poll files during the run — and the final outcome lands in `report.md`.

## Step 3: Announce and proceed

Report the spec to the user — outcome, work items, dependency order, what will run in parallel, key assumptions. How this lands depends on the breakdown-checkpoint choice recorded in the brief:

- **Opted out (the default):** this is a one-way status update. Proceed immediately; do not wait for or request approval — the Step 1 confirmation already authorized the run. If the user interjects on their own, incorporate it; never solicit it.
- **Opted in:** this is the one authorized pause. Present the spec and breakdown and ask once for approval. Incorporate any changes they request: a **structural** revision — re-splitting items, reordering dependencies, reworking an interface — re-spawns the `orca:spec` agent with the current `spec.md` plus the requested changes (and the held `agents.spec.model` override from Step 2, when set), because it may need fresh codebase exploration; a **trivial** revision — wording, a renamed item, a tweaked assumption — edit inline. Then proceed. This is the final interactive moment of the run; after it, the run is autonomous and never waits on the user again.

Set the spec status to `approved`. Create the integration worktree at the repo root, on a fresh branch based on the trunk tip:

```bash
git worktree add <repo-root>/orca-<slug> -b feature/<slug> <trunk-branch>
```

The branch is `feature/<slug>` — a neutral namespace that reads as ordinary dev work on GitHub and leaves no orca trace in git history; the slug keeps it collision-unlikely. `worktree add -b` fails loudly if `feature/<slug>` already exists, never silently reusing it — if it does, pick a different slug and retry rather than reusing the existing branch.

Completed items are merged into this branch, and `feature/<slug>` is the run's deliverable — the user lands it onto trunk themselves at the end. The run never checks out or writes the user's own worktree.

The spec must also record the **doubt rule** from the brief — every later autonomous decision cites it.

## Step 4: Run the work loop (workflow)

The work loop runs as **one deterministic workflow**, not as conversational orchestration. The bundled script `scripts/work-loop.workflow.js` encodes the loop's every rule as code, so the guarantees the run depends on are structural, not model discipline that decays over a long context:

- **Completion-driven scheduling** — an item launches the moment its own dependencies merge and advances the moment its previous stage finishes; it never waits for an unrelated sibling. The only synchronization points are the ones that should exist: the per-wave plan-reconciliation barrier (items that become ready at the same moment plan together, and waves take the spec-editing reconcile/escalate section one at a time) and the serialized merge queue.
- **Bounded loops** — max 2 fix rounds gated on Critical/High findings; the commit-attribution check runs against the actual `git log` message (never the agent's self-report), with two attempts and then a deterministic message rewrite, and merge commits get the same read-back check; one amendment round per reconciliation failure, always re-reconciled before building; at most one escalation-backed replan-and-rebuild per item after a spec-rooted mid-build failure.
- **Review throttling** — Codex reviews contend for one Codex auth; the script holds them to 2 concurrent slots while everything else parallelizes freely. Codex-only: claude reviews have no shared auth and ride the workflow's normal concurrency cap.
- **Judgment stays in agents, now explicit** — reconciliation, escalation (amend-vs-block per the rules below), and review verdicts are schema'd agent calls whose reasons land in the result, not discretion buried in a long context.
- **Resume and budget for free** — every agent call is journaled; an interrupted run resumes from where it stopped, and a session token target becomes a hard ceiling the loop respects.

### Before invoking

Review prompts need no preparation: the reviewer agent — `orca:review-codex` (the Codex courier) or `orca:review-claude`, per the held reviewer — carries the adversarial review contract in its own definition and assembles each review itself, substituting only the run directory, the artifact paths, and the item's owned files from the Work Breakdown. The contract names `spec.md` and the plan by **path** — never pasting their text — because the workflow's escalation agents amend `spec.md` mid-run, and a pasted copy would freeze the pre-run contract while the code under review correctly follows the amended one.

**Pass the model config.** If the `agents` block held since Step 2 is non-empty, pass it verbatim into the Workflow args as `agents` — per-stage `{model, effort}` overrides that the script applies on top of each stage agent's own defaults. Otherwise omit the key entirely. Do not re-read `.orca/config.json` here: the held block is the run's config generation, validated in Step 2, and a file edited since then must not change this run. The script re-validates at launch as a backstop; a failure there means the block was not passed verbatim — fix this call, and point the user at orca:config only if the file itself was bad.

**Pass the reviewer — always.** The `reviewer` arg is required and carries the resolved value held since Step 2 (`"codex"` or `"claude"`), never absent: the script cannot run shell commands, so all detection happened in the preflight, and a resume must replay the launch-time reviewer rather than re-detect.

**Create the status tasks.** Once the breakdown is final, create one session task per work item — the live per-item surface the user watches during the run: `TaskCreate` with subject `Wn — <title>` for each item, then `TaskUpdate` with `addBlockedBy` mirroring each item's `deps` onto the created task ids. Put each item's task id into its `taskId` field in the Workflow args below; the script threads a `Status task:` line into every stage prompt, and the stage agents tick their own item's task as they run. A dependency-blocked item needs no updates from anyone — it truthfully sits `pending` with its blockers named on the task. This layer is display-only and fail-soft: if task creation fails, launch anyway — an item without a `taskId` simply gets no live row. The `integration` pseudo-item never gets a task.

**Invoke the Workflow tool** with the bundled script and the run's values (this skill instructing the call is the user's consent for workflow orchestration). The script lives at `${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/work-loop.workflow.js` — the substituted value is already absolute; never pass `~` or an unsubstituted variable. `runDir` and `repoRoot` must be absolute too — the script rejects relative paths at launch:

```
Workflow({
  scriptPath: "${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/work-loop.workflow.js",
  args: {
    runDir: "<run-dir>",
    repoRoot: "<repo-root>",
    slug: "<slug>",
    integrationBranch: "feature/<slug>",
    items: [ { id: "W1", title: "…", deps: [], files: ["…"], taskId: "…" }, … ],  // verbatim from the spec's Work Breakdown, plus each item's status-task id
    reviewer: "<codex|claude>",  // the resolved reviewer held since Step 2 — always present
    agents: { … }   // only when the block held since Step 2 is non-empty — passed verbatim
  }
})
```

Pass `args` — and `items` inside it — as real JSON values, never stringified. The script recovers a stringified `args` or `items` by parsing it, and otherwise fails fast at launch naming the bad field; on such a failure, fix this Workflow call and relaunch — do not wrap the script in another workflow. Persist the resume handle from the tool result immediately: append a `**Workflow run:** <runId>` line to the end of `spec.md`, a `**Workflow reviewer:** <codex|claude>` line beside it, and — when the launch passed an `agents` block — a `**Workflow agents:** <the block as one-line JSON>` line too. The interruption that needs them — session death — also erases the conversation, the only other place the launch-time values exist, and `.orca/config.json` may have been edited or reset since launch, so the config file can never stand in for these lines.

### What the workflow does

Per readiness wave (the items whose dependencies have all merged at that moment): plan agents in parallel → an opus reconciliation agent reads all of the wave's plans against the spec Interfaces → on issues, an escalation agent applies the **amend-vs-block** rule (below), edits `spec.md` itself for amendments, the affected plans are regenerated once, and the wave is re-reconciled before anything builds. A dependency an amendment adds between items is reported structurally and applied to the scheduler itself — a wave item whose new dependency has not merged yet is deferred and relaunched when it has. Then each ready item pipelines independently: worktree off the integration tip (a worktree left by a previous run's blocked item is resumed, not a collision) → `orca:implement` → independent review (with reviewer codex, an `orca:review-codex` agent drives Codex through the plugin's bundled codex MCP server, read-only in the item's worktree, parses the result before writing, and writes the findings JSON verbatim; with reviewer claude, an `orca:review-claude` agent performs the review itself under the same adversarial contract and writes findings in the identical schema — either way the artifact plus a per-round archive land in `reviews/`, and a dead tool call, unparseable payload, or tripped self-check comes back as a failure the workflow retries, never as a clean pass) → `orca:fix` → re-review, gating commit on zero Critical/High (Medium/Low ride along only when recorded in the plan's Deviations; a first review with no findings at all skips the fix round) → `orca:commit` with the attribution check → serialized `orca:merge` in the integration worktree, self-healing any half-finished merge state first → best-effort worktree cleanup that can never demote a merged item. A mid-build failure that smells spec-rooted — an implementation reported infeasible, fix rounds exhausted on Critical/High findings, a semantically aborted merge — goes to the escalation agent once: an amendment replans and rebuilds the item once in its kept worktree; otherwise the item is cut (under prefer-smaller-scope) or blocked. After the loop drains, `orca:integrate` verifies the assembled feature; if it applied fixes, they get one review-fix pass and are always committed (attribution-checked) — a failed review is recorded as a gap, never a reason to leave fixes uncommitted.

The escalation rule the workflow's agent applies is unchanged from the conversational design: **amend and continue** when a fix preserves the brief's outcome, features, and non-goals — the change touches only *how* — recording the decision in the spec's `## Decisions` log with the doubt rule cited; **block and route around** when every fix would change *what* was agreed, recording the reason and the options the user must choose between. A blocked item keeps its worktree and branch for a follow-up run, and never stalls unaffected work. When the doubt rule is prefer-smaller-scope and a feature can be cleanly cut rather than blocked, cutting it is an amendment.

### While it runs and after

The workflow runs in the background, but its `log()` lines (items merged, items blocked, amendments) are **not visible on any live surface while the run is in flight** ([anthropics/claude-code#74419](https://github.com/anthropics/claude-code/issues/74419)) — they land only in the `logs` array of the completion-time `workflows/<runId>.json`, where notable ones are read back for the report. The live mid-run surface is the **session task list** created above: stage agents advance each item's task through its stages by suffixing the stage onto the subject (`Wn — <title> · implementing`) — the collapsed task panel renders only subjects, so that suffix is what the user actually sees; `activeForm` is mirrored for surfaces that show it. Dependency-blocked items sit `pending` with their blockers named, and only the merge stage completes an item's task — every other stage's status line forbids it, so a task ticking done early is a stage agent violating its line, not the design. When it completes, it returns `{ shipped, cut, blocked, integration, tokensSpent }`:

- Blocked items' worktrees and branches were kept — list them for the follow-up run.
- Proceed to Step 5; the returned values feed the report directly, with no intermediate status file to update.

**If the run is interrupted** — session death, a kill, a harness restart — do not re-run stages conversationally: re-invoke the Workflow tool with the same `scriptPath` and `args` plus `resumeFromRunId: "<runId>"`, reading the runId from the `**Workflow run:**` line at the end of `spec.md` (and rebuilding `args` from the spec's Work Breakdown, with the same `taskId`s the original launch used, the `reviewer` from the `**Workflow reviewer:**` line beside the runId — a spec with no such line predates the reviewer choice, and its run used `codex`, the only reviewer that existed — and the `agents` block from the `**Workflow agents:**` line — never from `.orca/config.json`, which may have changed since launch; no agents line means the launch passed no block, so omit the key. An `agents` or `reviewer` value that differs from the launch one makes every completed call of the affected stages re-run instead of replaying from the journal). Completed agent calls replay instantly from the journal; only in-flight and remaining work runs live. The status-line text embedded in stage prompts is part of the journal key too: a run launched under a plugin version with different status-line wording (e.g. before the stage suffix moved onto the subject) re-runs its taskId-carrying stages instead of replaying them. Before resuming, reconcile leftover git state (`git worktree list`) only if the journal and the worktrees disagree. One hard boundary: a run started before this skill became the orca plugin **cannot resume** under it — agent types, worktree names, and journal keys all changed. Treat such a run as abandoned: clean up its leftovers per the Guidelines and start a fresh run from a new brief.

## Step 5: Report

Reconcile the status tasks first, from the returned values — the stage agents' updates are best-effort, so the terminal states are set here: every `shipped` item's task → `status: "completed"` with the subject restored to the clean `Wn — <title>` (a backstop for a merge agent whose final update was skipped, which would also leave a stale ` · <stage>` suffix on the subject), every `cut` item's task → deleted, every `blocked` item's task → `status: "pending"` with the subject rewritten to `✗ blocked — Wn — <title> — <short reason>`, dropping any stage suffix (the task list has no failed state; a pending row with the marker beats a spinner that never stops). Items without a `taskId` have no task to touch.

Write the run report to `<run-dir>/report.md` **first**, then relay its highlights to the user. The file is the durable record of the run: it outlives the conversation, so anyone resuming, auditing, or picking up a follow-up run reads it instead of scrolling back. Everything needed is at hand — the workflow's returned `shipped`, `cut`, `blocked`, and `integration` values, the spec's `## Decisions` log, and the `## Deviations` sections of the plan files under `<run-dir>/plans/`, where the fix agents record the Medium/Low findings they deferred and the findings rooted outside their item — the Follow-ups section is sourced from those Deviations. Do not re-explore beyond these artifacts. Generate the completion timestamp with `date +"%Y-%m-%d %H:%M"`.

```markdown
# Report: <idea summary>

**Run:** <run-dir>
**Completed:** <YYYY-MM-DD HH:MM>
**Deliverable:** `feature/<slug>`

## Shipped

| ID  | Item    | Commit | Status |
| --- | ------- | ------ | ------ |
| W1  | <title> | <hash> | merged |

## Deviations

- <What changed from the original spec and why, citing the doubt rule where it applied. Mirrors the spec's Decisions log. "None" if the run matched the spec.>

## Blocked

- <Item, the one-line reason, and the decision the user must make between the recorded options. "None" if nothing is blocked.>

## Integration verification

- <Feature>: pass | fail — <detail, per spec feature>

## Follow-ups

- <Deferred work, known gaps, weak spots the reviews flagged but did not block, and any follow-up run needed for blocked items — each with the worktree/branch that still holds its partial work.>

## Landing

The deliverable is the `feature/<slug>` branch, built in the integration worktree. Land it from your own worktree with `git merge --no-ff feature/<slug>`, then optionally push.
```

After writing the file, give the user a short spoken summary — what shipped with commit hashes, anything `blocked` and the decision it waits on, the integration result feature by feature, tokens spent, and the path to the full `report.md` — then the landing command. The report file is the authoritative version; the spoken summary just points at it.

## Guidelines

- Never attribute commits to Claude. No commit produced by any agent in the run — commit agent, merge agent, integration fixes — may mention Claude, AI, agents, this orchestration process, or the user anywhere in the message: not the subject, not the body, not the footers. No `Co-Authored-By: Claude` and no `Generated with` trailers. Commit messages describe only the change itself. The workflow backstops this with a deterministic check of every commit message — including merge commits — read back from `git log`: unambiguous markers (Claude, Anthropic, `Co-Authored-By`, `Generated with`/`Generated by`, `orca`) trigger a rewrite. Keeping "AI" and "agent" out of ordinary prose is the agents' own instruction — those are legitimate domain vocabulary in many repos, so no regex can police them without mangling honest messages.
- The main conversation never implements, reviews, or explores deeply itself. If you catch yourself reading source files at length in the main context, delegate.
- Each stage is a dedicated subagent type (`orca:spec`, `orca:plan`, `orca:implement`, `orca:review-codex` or `orca:review-claude` per the run's reviewer, `orca:fix`, `orca:commit`, `orca:merge`, `orca:integrate`) whose instructions are its definition, loaded as its system prompt. The workflow spawns them by `agentType` and passes only the per-item values — run directory, worktree path, ID and title, owned files, branch names, artifact paths; the spec agent is spawned conversationally in Step 2 with the brief and repo root. The heavy stage instructions never enter the main context. Review runs through the same shape either way: with reviewer codex, the `orca:review-codex` agent carries the static adversarial template, drives Codex through the plugin's bundled codex MCP server (read-only sandbox, the item's worktree as cwd), and writes the findings JSON verbatim; with reviewer claude, the `orca:review-claude` agent performs the review itself under the same adversarial contract. Both write to `<run-dir>/reviews/<ID>-<reviewer>.json` plus a per-round archive in the identical schema and return the counts the merge gate branches on. There is no review script and no shell relay; the counts are the review agent's own count of the findings it wrote — a decided trade, chosen for a review path with no scripts in it.
- State lives in files and the workflow journal, not in conversation memory. `spec.md` holds the breakdown and the `**Workflow run:**` runId line, `report.md` holds the outcome; mid-run state is the journal, and an interrupted run resumes with `resumeFromRunId` — never by re-running stages conversationally.
- Pass context between stages through artifact files, never by relaying summaries — the implement agent reads the plan file itself, the reviewer reads the plan and diff itself and writes findings to its review file, and the fix agent reads that review file itself. Structured agent returns (verdicts, hashes, reconciliation results) exist for the workflow's control flow, not as a substitute for the artifacts.
- One worktree per work item, created by the workflow at the repo root off the shared bare repo, shared by that item's implement, review, fix, and commit stages, removed only after merge. All worktrees — the user's, the integration tree, and each item — are peers off the bare repo; the run never reads or writes the user's worktree. Only the serialized merge agent writes the integration branch, inside the integration worktree.
- If a run is abandoned, clean up with `git worktree list` and remove any leftover `orca-*` worktrees plus their `feature/<slug>*` branches — but prefer resuming via `resumeFromRunId` over abandoning.
- After the Step 1 confirmation — and the optional breakdown checkpoint in Step 3, if the brief opted into it — the run never waits on the user: no approval requests, no clarifying questions, no AskUserQuestion. Ambiguity resolves against the spec and the doubt rule; what cannot be resolved that way becomes a `blocked` item in the final report.
- Keep the user informed at phase transitions with one or two one-way status lines relayed from the workflow's progress: items started, items merged, amendments made, anything blocked. Inform, never ask.
