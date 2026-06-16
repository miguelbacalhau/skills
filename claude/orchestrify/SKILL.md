---
name: orchestrify
description: Drive a feature from idea to committed code using dedicated subagents per stage. Use when Claude should interview the user for the desired outcome, then run fully autonomously, write a spec with a dependency-ordered work breakdown, and for each unblocked work item spawn agents to plan and implement, review with an independent cross-model Codex reviewer and a Claude fix agent, and commit in its own git worktree branched off a shared bare repository, with a merge agent integrating completed items into an integration worktree. Requires a bare-repo-with-worktrees layout (validated up front); there is no privileged main checkout, and the run's deliverable is a branch the user lands themselves. After the interview — plus one optional breakdown checkpoint the user opts into during it — nothing else asks the user anything; undecidable issues are reported at the end. Do not use for small single-file changes or when the user only wants a spec or a plan.
args: <idea>
user-invocable: true
---

# Orchestrify

Coordinate a full implementation through isolated subagents. The main conversation acts as the orchestrator: it owns the spec, the work state, and all user interaction. All heavy context — codebase exploration, diffs, test output — lives and dies inside subagents. The orchestrator only reads artifact files and agent summaries.

Isolation is double: each subagent has its own context window, and each work item has its own git worktree. The repository is a bare repo, and every working copy — the user's, the run's integration tree, and each item — is a peer worktree off that one shared object store. There is no privileged main checkout: the orchestrator never reads or writes the user's worktree, and the run's deliverable is a branch the user lands themselves. Parallel items can never corrupt each other's files — overlap surfaces as an explicit merge conflict, resolved by a dedicated merge agent with both items' plans in hand.

The interview is where the user sets intent. They may also opt into a single checkpoint there: a one-time review of the spec and work breakdown before any code is written. Apart from that opt-in checkpoint, never ask the user anything — no mid-run clarifications, no approval gates, no AskUserQuestion. Status updates are one-way reports. Anything the orchestrator cannot decide within the interview's stated intent becomes a `blocked` item surfaced in the final report.

## Input

The user provides a rough idea, usually by invoking `$orchestrify` with a short objective.

If no idea is provided, ask what they want built.

## Step 1: Elicit requirements

Interview the user before writing anything. This is the only chance to capture intent — once it ends, the run is autonomous and every later ambiguity gets resolved against what was said here. Ask about, in one or two compact rounds:

- The desired outcome: what exists when this is done that does not exist now.
- The features it must have, and explicitly which it must not.
- Inputs and outputs: what data, events, or user actions go in; what results, side effects, or artifacts come out.
- Constraints: existing code it must integrate with, performance or compatibility expectations, deadlines on scope.
- The doubt rule: when the run hits an ambiguity, should it prefer the smaller interpretation and cut scope, or the more complete one? Default to smaller if the user has no preference.
- The breakdown checkpoint: after the spec and work breakdown are written — but before any worktree or code — do they want to review and approve it once, or go straight through autonomously? The decomposition (interfaces, work split, dependency order) is where parallel-agent mistakes originate, so this is the highest-value moment to catch a wrong assumption, and it is the only optional pause in the run. Default to going straight through if the user has no preference.

Close the interview by restating the understood outcome, features, non-goals, doubt rule, and breakdown-checkpoint choice, and confirming them. That confirmation authorizes the run. If the user opted into the breakdown checkpoint, the only remaining interaction is that one approval in Step 3; otherwise there is no later gate at all. From this point on, never ask the user anything else; proceed on recorded assumptions.

### Bare-repository pre-flight

Orchestrify requires the project to be a bare repository with worktrees — no privileged main checkout. That layout is the substrate the entire run depends on, so validate it during the interview, before the closing confirmation. This is a pre-flight gate, not a mid-run question.

Resolve the shared git directory and confirm it is bare:

```bash
git --git-dir="$(git rev-parse --path-format=absolute --git-common-dir)" rev-parse --is-bare-repository
```

This works whether the orchestrator is invoked from inside a worktree or at the bare repo itself — it always checks the *shared* repository, not the current working tree.

- `true` → proceed.
- `false` → the repo is a conventional checkout. Do not run. Tell the user orchestrify now requires a bare-central layout and stop. The one-time conversion is roughly: move the existing `.git` into a `.bare/` directory, add a top-level `.git` file containing `gitdir: ./.bare`, run `git --git-dir=.bare config core.bare true`, then recreate working copies as worktrees (`git --git-dir=.bare worktree add <branch>`). Converting the user's repo is their decision — surface the steps, do not do it autonomously.

Also identify the **trunk branch** the run will build on (e.g. `main`) and confirm it exists; the integration branch is created from its tip.

### Permissions pre-flight

The run only stays autonomous if the harness will not raise permission prompts: subagents inherit this session's permission mode, and the skill's own frontmatter does not propagate to them. A single foreground prompt mid-run breaks autonomy, and an auto-denied call makes an agent fail confusingly instead.

**This requires `bypassPermissions` mode — an allow-list is not sufficient.** The subagents are themselves models that decide commands at runtime (dependency installs, build and test variants, git invocations with assorted flags, `find`, `sed`, and so on), so the command set is open-ended and no static `permissions.allow` list can anticipate it. Beyond that, the harness matches Bash rules as prefix globs against the literal command string, so even listed commands slip through when they contain `$(…)` substitutions, lead with flags like `git --git-dir=…`, or are compound (`cd foo && …`). A leaked prompt is therefore a question of *when*, not *whether* — which is why the fix is the session mode, not the rules.

The skill cannot flip the mode itself, so confirm it during the interview before the closing confirmation: the session must be in `bypassPermissions` mode for the run. Enable it one of three ways:

- **In-session toggle** — press Shift+Tab to cycle the permission mode until the footer shows "bypass permissions". Easiest; do it right before the run.
- **Launch flag** — start the CLI with `claude --dangerously-skip-permissions`.
- **Settings** — `"permissions": { "defaultMode": "bypassPermissions" }` in `.claude/settings.local.json`, for a repo where runs are always unattended.

Make the tradeoff explicit to the user: bypass mode disables the approval gate for the *whole* session, not just orchestrify's commands. That is the point — the run is designed to be unattended — but any other work in the same session loses the gate too, so a dedicated session for the run is the clean choice. If the user will not enable bypass mode, do not start: the run cannot be autonomous, and an allow-list will only let it pause partway.

### Codex reviewer pre-flight

The review stage (4c) uses **Codex as an independent, cross-model reviewer** — a different model family from the Claude implementer, so it does not share the implementer's blind spots. The run therefore needs the Codex CLI installed and authenticated before it starts; a missing or unauthenticated `codex` would fail every item at review time, deep into an autonomous run. Validate it during the interview, before the closing confirmation — another pre-flight gate, not a mid-run question:

```bash
command -v codex && codex login status
```

- Both succeed → proceed.
- `codex` not found → tell the user to install the Codex CLI (`npm i -g @openai/codex`) and stop.
- Not logged in → tell the user to run `codex login` (or supply an API key via `codex login --with-api-key`) and stop.

Installing or authenticating Codex is the user's action — surface the command, do not do it autonomously.

## Step 2: Write the spec and work breakdown

Create the run directory at the project root — the directory that holds the bare repo and its worktrees. It holds only run metadata. Every worktree lives at the **top level of the repo**, as a sibling of the bare repo and the user's own worktrees — never inside `.orchestrify/`:

```text
<repo-root>/
├── .bare/                              # the bare repository (shared object store)
├── <user worktrees…>                   # e.g. main/ — untouched by the run
├── orchestrify-<slug>/                 # integration worktree (branch orchestrify/<slug>)
├── orchestrify-<slug>-<ID>/            # one worktree per in-flight item (e.g. orchestrify-<slug>-W1)
└── .orchestrify/YYYYMMDD-HHMMSS-<slug>/
    ├── spec.md     # requirements, interfaces, work breakdown
    ├── state.md    # live work-item status, owned by the orchestrator
    ├── plans/      # one plan file per work item, written by plan agents
    └── reviews/    # one Codex review artifact per item, written by the review stage
```

- `<repo-root>` is the directory containing the bare repo — resolve it as the parent of `git rev-parse --path-format=absolute --git-common-dir`.
- Generate the timestamp by running `date +%Y%m%d-%H%M%S`.
- Make `<slug>` a short kebab-case description of the idea, 3-5 words max.
- Worktree directories sit at `<repo-root>` and are named after their branches: `orchestrify-<slug>` for integration, `orchestrify-<slug>-<ID>` for each item. The `.orchestrify/` metadata is scratch space on disk, outside every worktree, so nothing in it can be committed by accident.

Do light codebase reconnaissance first — enough to split the work along real module boundaries, not enough to design implementations.

Write `spec.md` with this structure:

```markdown
# Spec: <idea summary>

**Created:** <YYYY-MM-DD HH:MM>
**Status:** draft

## Outcome

<What exists when this is done. One to three paragraphs.>

## Features

- <Capability, implementation-agnostic>

## Non-goals

- <Explicitly excluded scope>

## Inputs & Outputs

- **In:** <data, events, or actions the system receives>
- **Out:** <results, side effects, or artifacts it produces>

## Interfaces Between Work Items

<The contracts work items share: type shapes, function signatures,
file ownership, naming. Defined HERE so parallel agents cannot
invent conflicting versions. If two items cannot agree on a
boundary, merge them into one item.>

- **<Boundary>:** <signature or shape both sides code against>

## Work Breakdown

| ID  | Work item                    | Depends on | Files it owns        |
| --- | ---------------------------- | ---------- | -------------------- |
| W1  | <coherent unit of work>      | —          | <paths or globs>     |
| W2  | <coherent unit of work>      | W1         | <paths or globs>     |

## Assumptions

- <Assumption made to proceed>

## Doubt Rule

<From the interview: prefer-smaller-scope or prefer-complete. Every
autonomous decision later in the run cites this.>

## Risks & Open Questions

- <Risk, uncertainty, or decision still needed>
```

Rules for the breakdown:

- Each item must be independently implementable, verifiable, and committable.
- "Files it owns" is a soft signal, not a parallelism gate — worktrees isolate execution, so overlap surfaces as a merge conflict instead of corruption. Still prefer splits along real module boundaries: heavy expected overlap between independent items means the split is wrong.
- Keep it to 2-8 items. More than that means the idea needs a smaller first milestone.

Initialize `state.md`:

```markdown
# State: <idea summary>

| ID  | Item    | Status  | Branch | Commit |
| --- | ------- | ------- | ------ | ------ |
| W1  | <title> | pending | —      | —      |
```

Statuses: `pending` → `planning` → `planned` → `implementing` → `reviewing` → `committed` → `merged`. Failures become `blocked` with a note. An item is only complete — and only unblocks its dependents — when `merged`.

## Step 3: Announce and proceed

Report the spec to the user — outcome, work items, dependency order, what will run in parallel, key assumptions. How this lands depends on the breakdown-checkpoint choice made in the interview:

- **Opted out (the default):** this is a one-way status update. Proceed immediately; do not wait for or request approval — the interview's closing confirmation already authorized the run. If the user interjects on their own, incorporate it; never solicit it.
- **Opted in:** this is the one authorized pause. Present the spec and breakdown and ask once for approval. Incorporate any changes they request — revise `spec.md` and the work breakdown accordingly — then proceed. This is the final interactive moment of the run; after it, the run is autonomous and never waits on the user again.

Set the spec status to `approved`. Create the integration worktree at the repo root, on a fresh branch based on the trunk tip:

```bash
git worktree add <repo-root>/orchestrify-<slug> -b orchestrify/<slug> <trunk-branch>
```

Completed items are merged into this branch, and `orchestrify/<slug>` is the run's deliverable — the user lands it onto trunk themselves at the end. The orchestrator never checks out or writes the user's own worktree.

The spec must also record the **doubt rule** from the interview — every later autonomous decision cites it.

## Step 4: Run the work loop

Each work item gets its own git worktree and branch off the shared bare repo, so independent items run fully in parallel — even when they touch overlapping files. As many worktrees as there are unblocked items can be live at once; create one per item and let them run concurrently. Collisions cannot corrupt anyone's work; they surface later as explicit merge conflicts, which the merge agent resolves.

Repeat until every item is `merged` or `blocked`:

1. Collect items whose dependencies are all `merged`.
2. Spawn plan agents for all of them **in parallel** (planning is read-only and safe to parallelize).
3. **Reconcile the plans before any code is written.** When all of this batch's plans are written, read them together — against each other and against the spec's Interfaces — for what no single plan agent could see, since each one explored only its own item: a dependency one plan reveals that the breakdown never declared (an item that actually needs another's output), two plans assuming different shapes for the same shared contract, or heavy real overlap in files both will edit. This is the only moment cross-item knowledge exists before implementation. On a clean pass, proceed unchanged. On a missed dependency or contract mismatch, handle it under **Escalation** (amend: re-order, re-split, or revise the interface, then regenerate the affected plans) before spawning any implementer — catching it here is a re-order; catching it at merge is a semantic conflict.
4. Create each item's worktree at the repo root, branched off the integration branch tip:

   ```bash
   git worktree add <repo-root>/orchestrify-<slug>-<ID> -b orchestrify/<slug>-<ID> orchestrify/<slug>
   ```

   The item branch is `orchestrify/<slug>-<ID>`, not `orchestrify/<slug>/<ID>`: git stores refs as files, so a branch `orchestrify/<slug>` and a branch `orchestrify/<slug>/<ID>` cannot coexist — the first occupies the path the second would need as a directory, and the worktree add fails with `cannot lock ref … exists; cannot create`. Keeping `<slug>-<ID>` as a single leaf segment sidesteps the directory/file conflict.

   Branching off the integration branch only after dependencies are merged guarantees each item builds on its dependencies' actual code.
5. Run implement → review → commit for each item **inside its worktree**, in parallel across items. The implement, fix, and commit stages are Claude subagents; the review stage runs Codex in the same worktree (4c). Every stage for one item shares that one persistent worktree — each Claude agent gets a fresh context, but they must all see the same files, so pass the worktree path explicitly in every prompt and run Codex from inside the worktree.
6. As items reach `committed`, run the merge agent — merges are **serialized**, in dependency order, completion order for siblings.
7. Update `state.md` after every transition. A merge may unblock dependents — re-run step 1.

### 4a. Plan agent (read-only)

Spawn one subagent per unblocked item with this prompt, filling the placeholders:

```text
You are planning ONE work item of a larger feature. Read-only: do not
modify any source files. You cannot ask the user questions; if something
is ambiguous, choose the option most consistent with the spec and record
it under Decisions.

Spec: <run-dir>/spec.md — read it first. Honor the Interfaces section
exactly; never invent alternatives to the contracts it defines.

Your work item: <ID> — <title>. Files owned: <paths>.

Explore the codebase as much as needed. Your exploration dies with you —
only the plan file survives, so make it self-sufficient for a fresh
implementer with no other context. Write conclusions and pointers, not
transcripts of your exploration.

Write your plan to <run-dir>/plans/<ID>.md:

# Plan: <ID> — <title>

## Approach
<How to implement this item, and why this way. 2-5 sentences.>

## Steps
- [ ] <Concrete step with file path and what changes>

## Read First
- <file:lines> — <why the implementer must read this before coding>

## Gotchas
- <Non-obvious constraint, trap, or interaction discovered while exploring>

## Rejected
- <Approach considered and rejected, one line each, with the reason>

## Decisions
- <Ambiguity found and the choice made>

## Verification
- <Command to run and the expected result>

Return a 3-5 sentence summary: approach, the files you will touch
(confirm they match your declared ownership), and any conflict you
found between the spec and codebase reality. If the item cannot be
implemented as specified, say so plainly and explain why.
```

If the agent reports a spec conflict or infeasibility, go to **Escalation**.

### 4b. Implement agent

```text
You are implementing ONE work item from a plan. You cannot ask the user
questions.

Work EXCLUSIVELY inside this worktree: <repo-root>/orchestrify-<slug>-<ID>. All
reads, edits, and commands run there — never touch another worktree.
If the build needs dependencies installed in the worktree, install them
first.

Read first, in order: <run-dir>/spec.md, then <run-dir>/plans/<ID>.md,
then every file under its Read First section. Honor the spec's
Interfaces section exactly.

Stay within the files this item owns: <paths>, plus its tests. Touching
other files is allowed when the work genuinely requires it, but record
each case under Deviations — overlap with parallel items becomes a
merge conflict someone must resolve.

Execute the plan's steps, checking them off in the plan file as you go.
Follow the codebase's existing conventions. Prefer small, focused
functions, descriptive intermediate variables, and minimal mutable
state. No speculative abstractions.

The plan is a living document, not a frozen spec. If reality diverges
from it — an API behaves differently, a step is wrong or unnecessary,
you must touch an unowned file — do the smallest reasonable deviation
and append it to a "## Deviations" section in the plan file with the
reason. Do not silently skip or silently improvise.

When done, run the plan's Verification commands and fix failures.
Do not commit.

Return: what you implemented, verification results (pass/fail with
detail), every deviation, and anything you had to guess. If you could
not complete the item, state exactly where and why you stopped.
```

If the agent could not complete the item or deviations undermine the spec, go to **Escalation**.

### 4c. Review (independent Codex reviewer) + fix loop

The reviewer is **Codex, not Claude** — a different model family from the implementer. This is the strongest form of the "fresh eyes" this stage needs: the implementer was Claude, so a Claude reviewer still shares its training distribution, priors, and blind spots; Codex does not, so it catches a class of defects a same-family reviewer is systematically blind to. Codex reviews **read-only** and writes its findings to an artifact file; a separate Claude **fix agent** applies the fixes. Reviewer-reports / fixer-fixes stays a hard separation, now across two model families.

**Codex review (read-only, external).** The orchestrator runs this directly — it is a deterministic command like the `git worktree` calls, and Codex's heavy context lives and dies in its own process; only the findings file comes back, so nothing loads into the orchestrator's context. `codex exec review` has no `--cd` flag and review mode never edits source, so run it **from inside the item's worktree**:

```bash
cd <repo-root>/orchestrify-<slug>-<ID>
codex exec review --uncommitted \
  -o <run-dir>/reviews/<ID>-codex.md \
  "You are reviewing the uncommitted changes for ONE work item of a
   larger feature, adversarially: assume at least one real defect and
   that the tests are weaker than they look. An approval that finds
   nothing is the failure mode. Distrust exactly the parts that look
   obviously fine.

   Hard contract — the Interfaces section of <run-dir>/spec.md:
   <paste the Interfaces text relevant to this item>.
   Intent and recorded Deviations: <run-dir>/plans/<ID>.md.
   This item owns: <paths>.

   Hunt for: bugs, broken edge cases, violations of the spec interfaces,
   regressions to surrounding code, missing or weak tests, recorded
   deviations that are actually wrong calls, and files changed outside
   the item's ownership that the plan does not justify. Attack the tests
   specifically — the same model wrote the code and the tests, so a green
   run proves little; name the edge cases, error paths, and interface
   boundaries the suite does NOT exercise.

   For each finding give: severity (Critical/High/Medium/Low), file:line,
   what is wrong, and where the fix belongs — local code, the plan's
   approach, the spec interfaces, or another work item. Do not modify
   files; report only."
```

Findings land in `<run-dir>/reviews/<ID>-codex.md` (add `--json` for machine-readable events). The orchestrator reads only that artifact, never the diff itself — the same file-handoff rule as every other stage.

**Fix agent (Claude).** Spawn a Claude subagent to apply the fixes:

```text
You are fixing review findings for ONE work item. You cannot ask the
user questions.

Work EXCLUSIVELY inside this worktree: <repo-root>/orchestrify-<slug>-<ID>.

Read, in order: <run-dir>/spec.md (the Interfaces section is a hard
contract), <run-dir>/plans/<ID>.md (intent + Deviations), then the
Codex review findings at <run-dir>/reviews/<ID>-codex.md. The changes
under review are the output of `git diff` in the worktree plus its
untracked files.

For each finding rooted in local code, fix it directly in the worktree,
and add the tests the reviewer says are missing rather than trusting the
existing suite. Re-run the plan's Verification commands after fixing and
make them pass.

Do NOT fix — report instead: any finding the reviewer rooted in the
plan's approach, the spec's interfaces, or another work item's files. A
finding you judge incorrect you may decline, but say why.

Return: per finding, fixed / declined (with reason) / out-of-scope
(plan|spec|cross-item); the tests you added; and the final verification
result.
```

The fix loop: after the fix agent finishes, **re-run the Codex reviewer once** over the new state. If it returns no Critical or High findings, proceed to commit. If code-rooted Critical/High findings remain, run one more fix round — **maximum 2 fix rounds** — then go to **Escalation**. Any finding the reviewer roots in the plan, the spec's interfaces, or another work item goes to **Escalation** immediately: the fix agent cannot resolve it inside this one worktree.

### 4d. Commit agent

```text
Create one git commit for completed work item <ID> — <title>, on its
item branch inside this worktree: <repo-root>/orchestrify-<slug>-<ID>. Run all
git commands there.

Inspect with `git status` and `git diff`. Stage only files belonging to
this item — by name, never `git add -A` — plus <run-dir>/plans/<ID>.md
if changed. Never stage secrets (.env, credentials, keys).

Write a Conventional Commits message: `<type>(<scope>): <description>`,
imperative mood, lower-case, no trailing period, under 70 characters.
Add a body if the change needs context; mention significant deviations
from the plan. Do not push, do not amend.

The message must describe only the change itself. Never mention Claude,
AI, agents, this orchestration process, or the user in the subject,
body, or footers — no Co-Authored-By or Generated-with trailers, no
attribution of any kind.

Return the commit hash and the message used.
```

Before recording the hash, check the returned message: if it mentions
Claude, AI, agents, the orchestration process, or the user anywhere —
subject, body, or trailers — treat the step as failed, run
`git reset --soft HEAD~1` in the worktree, and re-run the commit agent
with the violation quoted in its prompt.

Record the hash in `state.md` and mark the item `committed`.

### 4e. Merge agent (serialized)

Run merges one at a time, in dependency order — completion order for siblings. Merging is where deferred collisions become visible, and where they get resolved with full context.

```text
Merge completed work item <ID> — <title> into the integration branch
orchestrify/<slug>. Work EXCLUSIVELY in the integration worktree:
<repo-root>/orchestrify-<slug>. Never touch the user's worktrees.

Run: git merge --no-ff orchestrify/<slug>-<ID>

If there are conflicts, resolve them yourself. Your sources of truth,
in order: the Interfaces section of <run-dir>/spec.md, then the plan
files of BOTH sides of the conflict under <run-dir>/plans/ (the
Deviations sections explain why overlapping changes exist). Preserve
the intent of both work items; when the two sides are genuinely
incompatible — not textually, but in what they mean — abort the merge
and report instead of guessing.

After merging, verify the RESULT, not just the conflict resolution:
run the build, the affected tests, and the merged item's Verification
commands from its plan. A clean textual merge can still be wrong —
both branches may pass alone and break together. Fix small breakage
directly and commit it as part of the merge; report anything larger.

Any commit you create must describe only the change itself. Never
mention Claude, AI, agents, this orchestration process, or the user —
no Co-Authored-By or Generated-with trailers, no attribution of any
kind.

Return: merged or aborted, conflicts encountered and how each was
resolved, verification result, and any fix you applied.
```

After a successful merge, remove the worktree and branch
(`git worktree remove <repo-root>/orchestrify-<slug>-<ID>` and
`git branch -d orchestrify/<slug>-<ID>`), mark the item `merged` in
`state.md`, and re-check for newly unblocked items.

If the merge agent aborts on a semantic conflict, go to **Escalation** — two work items that cannot coexist mean the spec's interfaces or the breakdown need revision, which is a user decision.

### Escalation

When an agent reports that the problem is structural — the spec is wrong, the breakdown missed a dependency, an interface does not survive contact with the codebase, or the fix loop is exhausted — the orchestrator decides autonomously. Never ask the user. Apply this decision rule:

**Amend and continue** when a fix exists that preserves the interview's stated outcome, features, and non-goals — the change only touches *how*, not *what*. Examples: re-split an item, reorder dependencies, revise an interface both sides can adopt, accept an implementation deviation. Then:

1. Update `spec.md` (interfaces, breakdown) and regenerate plans for affected unstarted items.
2. Record the decision in a `## Decisions` log in `spec.md`: what broke, what was changed, and why it preserves the interview's intent, citing the doubt rule where it applied.
3. Resume the loop. Report the amendment to the user as a one-way status line.

**Block and route around** when every fix would alter *what* was agreed — dropping or changing a promised feature, violating a stated constraint, expanding scope past a non-goal. Guessing here would silently ship something the user did not ask for. Then:

1. Mark the item `blocked` in `state.md` with a one-line reason and the options the user will need to choose between. Items depending on it stay `pending`. Keep the item's worktree and branch — partial work resumes there in a follow-up run.
2. Continue all unaffected work to completion. A blocked item never stalls the rest of the run.
3. Surface the blocked item, its reason, and its options in the final report — that is where the user's decision happens, asynchronously.

When the doubt rule is prefer-smaller-scope and a feature can be cleanly cut rather than blocked, cutting it is an amendment: record it in Decisions and in the final report's deviations.

## Step 5: Integration verification

Per-item review catches local bugs; only this phase catches pieces that do not compose. After the loop drains, spawn a final agent:

```text
Verify an assembled multi-part implementation. Work in the integration
worktree: <repo-root>/orchestrify-<slug>. Read <run-dir>/spec.md, then:
run the full build, the full test suite, and exercise each spec feature
end to end the way a user would.

Judge against the spec's Outcome and Features sections — not against
the individual plans. Look especially at the seams: do the work items
actually compose, are the Interfaces contracts honored on both sides,
does anything only work in isolation?

Fix small integration bugs directly and report them. Report larger
mismatches without fixing.

Return: pass/fail per spec feature, fixes applied, and remaining gaps.
```

If it applied fixes, run the review stage (4c) — Codex review plus the Claude fix agent — over them in the integration worktree, then the commit agent. If it found larger mismatches, treat them under **Escalation**.

## Step 6: Report

Tell the user:

- What shipped, item by item, with commit hashes.
- Deviations from the original spec and why.
- Anything `blocked` and the decision it is waiting on.
- The integration verification result, feature by feature.
- Suggested next step: the deliverable is the `orchestrify/<slug>` branch (built in the integration worktree). The user lands it onto trunk from their own worktree — `git merge --no-ff orchestrify/<slug>` — then optionally pushes. Plus any follow-up run for blocked items.

## Guidelines

- Never attribute commits to Claude. No commit produced by any agent in the run — commit agent, merge agent, escalation fixes — may mention Claude, AI, agents, this orchestration process, or the user anywhere in the message: not the subject, not the body, not the footers. No `Co-Authored-By: Claude` and no `Generated with` trailers. Commit messages describe only the change itself.
- The orchestrator never implements, reviews, or explores deeply itself. If you catch yourself reading source files at length in the main context, delegate.
- State lives in files, not in conversation memory. After any interruption, `state.md` plus the plan files are sufficient to resume.
- Pass context between stages through artifact files, never by relaying summaries — the implement agent reads the plan file itself, the Codex reviewer reads the plan and diff itself and writes findings to its review file, and the fix agent reads that review file itself.
- One worktree per work item, created by the orchestrator at the repo root off the shared bare repo, shared by that item's implement, Codex review, fix, and commit stages, removed only after merge. All worktrees — the user's, the integration tree, and each item — are peers off the bare repo; the run never reads or writes the user's worktree. Only the serialized merge agent writes the integration branch, inside the integration worktree.
- If a run is abandoned, clean up with `git worktree list` and remove any `orchestrify/` worktrees and branches left behind.
- After the interview closes — and the optional breakdown checkpoint in Step 3, if the user opted into it — the run never waits on the user: no approval requests, no clarifying questions, no AskUserQuestion. Ambiguity resolves against the spec and the doubt rule; what cannot be resolved that way becomes a `blocked` item in the final report.
- Keep the user informed at phase transitions with one or two one-way status lines: items started, items merged, amendments made, anything blocked. Inform, never ask.
