# Adversarial review — orca plugin (merged)

**Date:** 2026-07-22 · **Scope:** all tracked lines at commit `e298b40` (v0.9.0)
**Provenance:** merger of two independent adversarial reviews of the same tree:

- **[codex]** — authored by Codex, then curated by Claude (findings `F-01`…`F-12`;
  original IDs kept below for cross-reference).
- **[claude]** — authored by Claude in five independent review passes (shell,
  workflow orchestrators, agent-prompt contracts, security, docs/hygiene), then
  verified by Codex.
- **[both]** — found independently by both reviews; treat as highest-confidence.

During the merge, every Critical/High claim was re-verified by hand against the
source at `e298b40`; verified items are marked ✓. Where the two reviews
disagreed on facts or severity, the disagreement is resolved inline with the
evidence. Neither review launched a workflow or ran a destructive command.

## Verdict

The deterministic layer is unusually well built: typed failure contracts,
refname sanitization, forgery-resistant review-notes counting, bounded retry
loops, worktree-per-item isolation, consent-gated destructive phases, and
workflow scripts whose null-handling and loop termination check out clean.

The risk concentrates in four places:

1. **One deterministic destructive path** — `init-convert.sh cleanup` can
   delete live work that the manifest never covered.
2. **Prompt-contract mismatches** — several agent prompts permit (or instruct)
   behavior that the orchestrator or downstream stages assume cannot happen
   (impossible staging, merge-subject rewording, followup base branches).
3. **The integration-fix review asymmetry** — the change class with the widest
   blast radius passes a weaker gate than every ordinary work item.
4. **Zero executable assurance** — no tests, no shellcheck, no behavior CI,
   for contract-bearing shell and JS whose central pitch is that the
   guarantees are structural.

On the threat model, the two reviews framed injection differently and both
framings are kept: every shell-bound value originates from the user's own
session or the user's own spec agent — there is no *external* untrusted
principal **[codex]** — but spec-agent output downstream of a pasted brief or
bug report is model-generated, so a prompt-injected input turns "an agent
might run it" into "the deterministic loop definitely runs it" **[claude]**.
Conclusion: the cheap input grammars are worth adding regardless; prompt
hygiene is defense in depth, not a security boundary.

---

## Critical / High

### 1. `init-convert.sh cleanup` can `rm -rf` live work — [claude] ✓

`scripts/init-convert.sh:246-267`. The manifest reconciliation only proves the
moved files *arrived in the worktree*; the deletion loop then removes **every**
root entry outside the keep-list (`.bare | .git | .orca | "$branch"`) without
checking that what it deletes is covered by the manifest. If a user runs
`convert`, defers `cleanup`, and in between an orca run creates an
`orca-<slug>` worktree at the root (or they save any new file there), cleanup
destroys it — including uncommitted agent work.

Related **[codex F-06, Medium-Low]**: conversion itself (`.git` move, pointer,
worktree, one-at-a-time file moves, `scripts/init-convert.sh:149-213`) has no
crash-safe recovery — a power loss or signal mid-move leaves a partially
converted repository with only the manifest to reason from. (The codex curation
corrected its own earlier claim: the script does *not* advertise the unsafe
rollback after moves begin; the gap is absent recovery, not a misleading
message.)

**Fix:** delete only entries the manifest names (or cross-check against
`git worktree list`) and refuse anything unrecognized; add signal traps and a
reverse manifest around the move loop.

### 2. Replan + deferral interact to resurrect the exact stall the code guards against — [claude] ✓

`scripts/work-loop.workflow.js:778-781`. The dependency-deferral pass sets
items back to `pending` *before* the replan filter selects on
`state[i.id] === 'active'`. An item that receives both an amended dependency
and a replan order (the natural pairing) is silently excluded from replanning:
its failed plan is never archived, and when it relaunches, the planner finds
the superseded `plans/<ID>.md` on disk with no replan note — the documented
"W3 stall" failure mode. The second reconcile at line 791 can't catch it
either, because the deferred item isn't in `live`.

**Fix:** compute the replan set from `esc.replan` before the deferral pass, or
archive plans for deferred-and-replanned items too.

### 3. The commit prompt instructs staging a file outside the repository — [claude] ✓

`agents/commit.md:17` says to stage "`<run-dir>/plans/<ID>.md` if changed" —
but the architecture deliberately places `.orca/` outside every worktree
(`skills/feature/SKILL.md` states this as a safety property). The plan is
therefore impossible to stage from the item repository. A literal agent may
include it in `git add`, receive `fatal: … is outside repository`, and stop,
blocking the item after the implement→review→fix pipeline. Prompt-contract
risk: not proven to break every item — an agent may recognize the plan is
external and recover.

**Fix:** delete that clause.

### 4. Merge subjects are the audit's join key, but merge.md licenses dropping it — [claude] ✓

`agents/merge.md:17-19` prescribes
`git merge --no-ff … -m "merge <ID>: <title>"`, then says "Your own wording is
fine." `agents/audit.md:18` treats first-parent merge commits "each naming its
item id" as *the verified shipped set*, overriding the report. The prescribed
command is correct, so this is not a deterministic failure — but an agent that
follows the wording license (e.g. `merge: rate limiting for exports`) can make
the audit report the item as never shipped and `/orca:retry` re-implement
already-merged work.

**Fix:** make the `merge <ID>:` prefix mandatory (free wording only after the
colon), and validate or rewrite it after merge in the workflow.

### 5. Followup briefs direct a launch mode the feature skill cannot execute — [claude] ✓

`skills/followup/SKILL.md:85` Direction template: "Build on the existing
integration branch `feature/<slug>`". But `skills/feature/SKILL.md:168`
*unconditionally* creates the integration worktree "on a fresh branch based on
the trunk tip," and on collision (line 175) explicitly says to pick a different
slug "rather than reusing the existing branch" — the exact opposite. A
followup over an unlanded deliverable branches from trunk, and every stage
then works on code that doesn't contain the feature being extended.

**Fix:** teach feature Step 3 to honor a Direction-specified base branch.

### 6. Integration fixes bypass the review gate every ordinary item must pass — [both]

Item reviews re-review after fixes and block after two rounds while Critical
or High findings remain (`scripts/work-loop.workflow.js:559-572`). Integration
fixes use a weaker path: review once, run the fixer when any finding exists,
then commit without re-review (`scripts/work-loop.workflow.js:933-962`). If
the review itself fails, the code explicitly commits the integration fixes
unreviewed, recording only a gap. **[codex F-04, High]**

Compounding it **[claude]**: the integration fixer has no plan file, so its
declines/escalations go only into its return message — which the workflow
never reads (`agents/fix.md:17,21` + `work-loop.workflow.js:939-944`). A
declined High finding vanishes without trace. And after a reviewer switch on
retry, both `integration-codex.json` and `integration-claude.json` can coexist
while fix.md asserts "exactly one exists" — the agent may fix last round's
stale findings.

This is precisely the highest-risk change class: integration verification may
modify cross-item behavior outside any item's owned files or plan. Related
**[codex F-09, Medium-Low]**: after integration fixes are committed there is
no second full-feature verification, and if the integration verifier dies the
run preserves work but the product language still describes the branch as a
completed deliverable.

**Fix:** apply the same Critical/High gate to integration fixes
(review → fix → re-review, bounded); persist fixer declines; delete stale
reviewer artifacts before re-review; and distinguish `built` / `verified` /
`unverified` terminal states instead of describing an unreviewed branch as a
completed deliverable.

### 7. No automated tests, shellcheck, or behavior CI — [both]

**[codex F-07, High]** / **[claude, hygiene]**. The repository contains no
tests, test runner, fixtures, or CI job exercising the plugin — the only
GitHub workflow bumps the version — for ~3,300 lines of contract-bearing
bash/JS. This is the highest-leverage item in either review:
`init-convert.sh`, `secrets.sh`, `config.sh`, `triage.sh`, and `review.sh` are
pure shell over git repositories, testable today with Bats and temporary
repos, and `init-convert.sh cleanup` does `rm -rf` over top-level entries.
`config.sh:130-133` even documents the exact fragility (vocabulary
hand-duplicated across three files) that a lockstep test would catch.

Untested behaviors include: conversion/rollback with spaces, newlines,
symlinks, failures, and signals; concurrent launch/resume and stale worktrees;
config parsing and malformed JSON; triage joining for ambiguous slugs;
secret-link ownership and path containment; version-bump sizing edge cases.

**Fix:** hermetic Bats/ShellSpec harness over temporary git repos (start with
`init-convert.sh` and `secrets.sh`, with failure injection), plus CI running
shellcheck, tests, and JSON/manifest validation on Linux and macOS.
Workflow-script logic (scheduler, state transitions) is harder to extract from
the sandboxed scripts and can come later.

### 8. No injection hygiene in a system designed to run untrusted text with the gate off — [claude, design risk]

Design-level; spans all 17 agents and 9 skills. The runs *require*
`bypassPermissions` (`skills/feature/SKILL.md`, `skills/debug/SKILL.md`),
`secrets.sh` symlinks real `.env`s into worktrees, and the pipeline consumes
external text: pasted bug reports, third-party repository code, and
cross-model review findings written to disk "verbatim, byte for byte"
(`agents/review-codex.md`) that a Bash-armed fix agent then acts on. No prompt
says finding bodies, issue text, and evidence files are data rather than
instructions. A hostile "to reproduce, run `curl -d @.env …`" could influence
an agent to execute an unsafe reproducer — a plausible threat scenario, not
deterministic source behavior.

**Fix:** add a standing data-not-instructions rule to Bash-armed agents, and
reduce blast radius structurally: place secrets only in stages that need them,
prefer least-privilege credentials and network/container isolation for
unattended reproduction. Treat prompt text as defense in depth, not
containment.

---

## Medium

### Input validation at the deterministic boundary — [both]

**[codex F-01]** / **[claude]**. The workflow validates `slug`,
`integrationBranch`, item IDs, and paths only as non-empty strings, then
interpolates them into double-quoted shell fragments, worktree paths, `-b`
branch args, and a single-quoted `wip:` commit message
(`scripts/work-loop.workflow.js:94-108,123,437-440,458,515-539,635,825`; same
pattern in `debug-loop.workflow.js:86-106,151-155,293-305,329`). The reviews
disagreed on severity — "no untrusted principal, defense-in-depth" [codex] vs
"ids come from spec-agent output, so a prompt-injected brief makes the
deterministic loop run it, including path traversal into
`worktree remove --force`" [claude] — but converge on the same fix.

**Fix:** at the existing launch-validation block
(`work-loop.workflow.js:94-122`), add narrow grammars — roughly five lines:
`slug: /^[a-z0-9]+(?:-[a-z0-9]+)*$/`, item IDs `/^W[1-9][0-9]*$/` (plus the
debug loop's `F/H` variants), a conservative class for `integrationBranch`
(mirroring `review.sh:165`), and validate `items[].files` as strings (an
object renders `Owned files: [object Object]` in prompts today).

### Concurrency — [both, complementary]

- **No repository/run lock prevents concurrent writers** **[codex F-03]** —
  the design resolves cross-session collision conversationally ("ask rather
  than assume": `skills/debug/SKILL.md:30`, `skills/feature/SKILL.md:34`,
  `work-loop.workflow.js:312-324`), but two sessions can resume the same
  journal or launch colliding slugs, and one can force-remove a worktree the
  other is using. **Fix:** an atomic `mkdir <run-dir>/.lock` lease with owner
  metadata, refusal on a live lease, and user-confirmed stale-lock recovery.
- **Concurrent `git worktree add` across a wave can collide on repo locks**
  **[claude]** — `work-loop.workflow.js:534-539` (up to 8 concurrent in
  debug-loop). A transient `index.lock` failure isn't escalatable, so the item
  and its dependents block permanently on a retryable error. **Fix:** one
  retry on lock-shaped failures.

### Secrets — [both, reconciled]

- **Ownership by substring, not resolution** **[codex F-05]** ✓ —
  `secrets.sh:115-137` treats any symlink whose target matches the glob
  `*.orca/secrets/*` as "ours" to replace, and the dangling-link sweep
  (`secrets.sh:159-170`) deletes broken links matching the same pattern. The
  claude review had marked the sweep "cleared" — true for the common case, but
  the merge verification confirms the glob also claims links into a
  *different* repository's `.orca/secrets` tree, or a path like
  `backup.orca/secrets/x`, violating the script's own never-touch-foreign
  promise. **Fix:** only manage a symlink whose *resolved* target lands inside
  this repository's `$repo_root/.orca/secrets` and maps to the same relative
  destination; never delete ambiguous links.
- **Secrets source tree is only git-excluded on config writes** **[claude]** —
  (`config.sh` `ensure_exclude`): in a conventional non-bare checkout, a user
  following the README's mirror-tree convention who never runs
  `orca:config set` has real credentials in an unignored `.orca/secrets/` —
  `git add -A` commits them. The README's "structurally uncommittable" claim
  holds only for the bare layout. **Fix:** run the same exclude-ensure from
  `secrets.sh place`.
- **`skills/doctor/SKILL.md:46` prescribes a *persistent*
  `bypassPermissions` default** **[claude]** in `settings.local.json` —
  converting a per-session decision into a durable gate-off for every future
  session in that worktree.

### Orchestration correctness — [claude]

- **Relay-derived SHAs flow into `git reset --soft ${base}` unvalidated** —
  `work-loop.workflow.js:463,583-585`, while `debug-loop.workflow.js:431`
  validates the identical read with `/^[0-9a-f]{40}$/` and a comment
  explaining why. Copy the debug-loop guard.
- **The merge gate keys on `total`, not `criticalHigh`** —
  `work-loop.workflow.js:561-562`; the schema doesn't constrain
  `criticalHigh <= total`, so `{total: 0, criticalHigh: 2}` skips the fix
  loop. Gate on `total > 0 || criticalHigh > 0` and reject impossible
  combinations.
- **The NOTHING_NEW salvage path mislabels a real state** —
  `work-loop.workflow.js:483-496`: prior commits containing a banned marker
  fall through to `throw new Error('commit agent made no commit')` — blocking
  a fully built item with an error asserting the opposite of the truth.
- **A run can vanish from all discovery** — `skills/feature/SKILL.md` consumes
  the brief (`mv`) *before* spawning the long spec exploration, but
  `triage.sh` detects runs only via `spec.md`. A session death in that window
  loses the confirmed brief with no `BRIEF:` or `RUN:` line anywhere. Write
  the brief into the run dir first, or key triage on `brief.md` too.
- **`agents/review-claude.md:24` hard-codes `shasum`** (a perl tool) as the
  mandatory first Bash action; on minimal Linux (coreutils only), every
  claude-reviewed item blocks permanently. Use `sha256sum` or allow either.
- **`agents/audit.md:15` reads a field no artifact records** — the integration
  worktree path is in neither the spec nor report template; the audit must
  guess the `orca-<slug>` convention, feeding retry's worktree-reuse decision.
- **`agents/diagnose.md`'s fix contract omits `## Decisions`**, which the
  nested work loop's escalation prompt and `agents/plan.md` both assume
  exists — an escalation during the fix tail appends the amendment somewhere
  the planner isn't contractually bound to look.

### Deterministic layer — [claude]

- **`preflight.sh:78,116` uses CWD-relative config/settings paths** while
  everything else resolves the root via git. Run from a subdirectory, a pinned
  `reviewer=codex` silently falls back to detection — the precise "silent
  downgrade" the script's own comment forbids — and `MCP_TOOL_TIMEOUT` checks
  produce false FAILs.
- **`config.sh` `set` lacks the shape guards `clear`/`reset` have** (~line
  285): a hand-mangled `{"agents":[]}` yields a raw Python traceback with no
  typed `FAIL:` line. The canonical write is also not atomic (no temp+rename),
  so concurrent preflight reads can see a truncated file and silently ignore
  pinned values.

### Hygiene — [claude]

- **No LICENSE anywhere** — publicly marketed for install but legally
  all-rights-reserved; nobody has a grant to copy, modify, or contribute.
- **`python3` is a hard, undocumented prerequisite** — `config.sh:83-84` fails
  without it, on the launch path of every run; absent from the README
  Requirements table.

---

## Low

- **`actions/checkout@v4` is tag-pinned in a job with `contents: write` to
  main** **[both: codex F-11 / claude]** — SHA-pin it and minimize token
  permissions.
- **Naming collisions** **[both: codex F-12 / claude]** — brief filenames use
  minute precision (`skills/feature/interview.md:75-78`); `review.sh`
  `notes_key` is lossy many-to-one (`feature/a+b` and `feature/a-b` collide,
  line 165-169). Fail on pre-existence or add a short hash of the source name.
- The banned-attribution regex includes `\borca\b`
  (`work-loop.workflow.js:451`) — dogfooding orca on the orca repo rewrites
  every honest `feat: orca:status …` commit into a `chore:` fallback. [claude]
- Escalation `cut` skips worktree salvage (`work-loop.workflow.js:856`) —
  leaks the worktree + branch; a later same-slug run hits `WORKTREE_REUSED`
  for an item the spec no longer contains. [claude]
- One unresolved reconcile issue after amendment blocks the *entire* wave, not
  the offending item (`work-loop.workflow.js:794`). [claude]
- `archivePlan` silently no-ops once all four `round0-3` slots exist;
  escalation rebuilds reuse the same review-archive paths, clobbering the
  evidence the escalation judgment was based on. [claude]
- Debug repro exit codes >127 (OOM-kill 137, timeout 124) classify as "bug
  present" instead of "cannot test" — can revert a correct fix
  (`debug-loop.workflow.js:218-221`). [claude]
- Hypothesis ids case-normalized in prompts/paths but not in the file the
  verify agent reads (`debug-loop.workflow.js:365-371`); a round-2
  `undiagnosed` return drops the round-1 diagnosis string. [claude]
- `review.sh` branch↔worktree join breaks on paths containing tabs (lines
  235-248). [claude]
- `triage.sh`: feat fallback glob can cross-join a pre-plugin dir
  (`20240101-my-auth` matches slug `auth`, lines 231-237); `merge-base`
  failures read as `unmerged` instead of `unknown` (243-250); worktree-derived
  slugs flow unquoted into glob patterns (229, 296-300); `RUNID:` has no
  `absent` fallback (167-169). [claude]
- `secrets.sh` uses the worktree path as a `find -path` *pattern* (glob
  metachars in the repo path break the `.orca` prune, line 170), and its
  "check-ignore consults the index" comment is wrong — a tracked-but-ignored
  path deleted from the worktree can get a symlink onto a tracked name (line
  104). [claude]
- `version-bump.sh` sizes bumps from *all* commits, not just SHIPPED-touching
  ones, and a body merely *quoting* `BREAKING CHANGE:` forces a major (lines
  54-62). [claude]
- `agents/hypothesize.md` mandates "3 to 8 candidates" but the schema accepts
  `minItems: 1`; the hypothesis statement is interpolated raw into the quoted
  `Status task:` instruction (`debug-loop.workflow.js:321`) where work-loop
  correctly `JSON.stringify`s; `agents/address.md` declares a `<trunk>`
  parameter it never uses; skills say to "delete" cut items' tasks but no
  delete verb exists in the task vocabulary. [claude]
- README: "fourteen stage agents" vs seventeen (line 67 vs 389); the
  `MCP_TOOL_TIMEOUT` row's "like the row above" points at git after a
  reordering (64); the Repository-contents table omits `config.sh`,
  `triage.sh`, `init-convert.sh` (525-541); "hypothesize (3–8 ranked)"
  presents prompt guidance as a structural guarantee (298). [claude]
- `plugin.json` lacks `repository`/`homepage`/`license`; repo `.gitignore`
  covers neither `.claude/settings.local.json` nor `.orca/` (contributors
  aren't protected by the maintainer's global ignore), and the unanchored
  `plans/` pattern would swallow a future `docs/plans/`; no CHANGELOG; all
  scripts require git ≥ 2.31 (`--path-format=absolute`) but misdiagnose older
  git as `NOT_GIT`; `.mcp.json` launches whatever `codex` is first on
  `$PATH`, auto-enabled. [claude]

---

## Platform constraints, not plugin defects — [codex, dropped findings]

Kept for the record; both trace to the Workflow host sandbox (no shell, no
filesystem, no process API), which the code comments state explicitly.

- **F-02** — shell commands executed through an LLM relay: the haiku relay is
  the only execution primitive available; the `SH_RC`/`@@OUT@@` marker scheme
  is a reasonable mitigation. Worth one line of documentation: guarantees
  through the relay are probabilistic.
- **F-08** — review counts are model-reported, not artifact-derived: the
  sandbox has no file API to parse the review artifact independently; the
  trade is consciously recorded at `work-loop.workflow.js:229-238`.
- **F-10** — contract vocabulary duplicated across three validators: a
  documented sandbox consequence, flagged in comments at every site; a CI
  regeneration check becomes meaningful once CI exists (finding 7).

Revisit all three if the Workflow host ever grows a process/file API.

---

## What checked out clean — [both]

Adversarially probed and cleared (claude's five passes, plus codex's positive
practices; the secrets-sweep entry is amended per finding F-05 above):

- Worktree-per-item isolation and serialized integration merges; dependency
  existence, duplicate-ID, and cycle validation before scheduling
  (`work-loop.workflow.js:899-911`).
- Bounded retry counts and review loops; commit attribution checked against
  git history rather than agent self-report, including multi-commit spans.
- Resume arguments persisted and replayed, not reconstructed from mutable
  config; the debug repro's deterministic git-bisect exit contract
  distinguishing "cannot test" from "bug present".
- `review.sh`'s forgery defense (raw `"status":"open"` counting vs
  `vim.json.encode` escaping) and refname sanitization; `orca:status`
  genuinely read-only by contract.
- The version-bump loop structurally cannot self-retrigger; no injection
  surface in its commit-message handling.
- Every artifact path/schema contract between the 17 agents and both workflow
  loops except those listed above; all four README model/effort tables match
  agent frontmatter exactly.
- Both workflow scripts: no sandbox-constraint violations, null-filtering at
  every `parallel()` use site, the review-slot semaphore correct; `workflow()`
  in debug-loop is a real harness global, so the nested-fix path is sound.
- Secrets placement is symlink-only (content can never enter history),
  fail-safe on `check-ignore` errors; destructive initialization is
  consent-gated, NUL-delimited, and reconciles its manifest before deleting
  (subject to findings 1 and F-05).
- `plans/` never ships; marketplace/plugin manifests consistent at 0.9.0;
  codex reviewer containment (`sandbox: read-only`, `approval-policy: never`)
  correct.

---

## Priority order, if you fix ten things

1. Guard `init-convert cleanup` deletions against the manifest (data loss) —
   finding 1.
2. Add the executable safety net: Bats tests over temporary git repos for
   `init-convert.sh` and `secrets.sh` first, then shellcheck + contract tests
   in CI — finding 7.
3. Fix the replan/deferral ordering in `runWave` — finding 2.
4. Re-review integration fixes under the same Critical/High gate, persist
   fixer declines, and add an `unverified` terminal state — finding 6.
5. Grammar-validate every slug, item id, dependency, file entry, branch, and
   relay SHA before it reaches paths, refs, prompts, or shell — Medium §1.
6. Delete commit.md's impossible stage-the-plan-file clause — finding 3.
7. Make `merge <ID>:` structural (validate or rewrite after merge) and gate on
   both review counts — finding 4.
8. Teach feature Step 3 to honor a follow-up base branch — finding 5.
9. Exact-target ownership in `secrets.sh`, `ensure_exclude` from `place`,
   git-root paths in `preflight.sh`, and a `mkdir` lease per run directory —
   Medium §§2-3.
10. Injection hygiene + blast-radius reduction for Bash-armed agents, and
    project hygiene: LICENSE, `python3` and git ≥ 2.31 documented,
    `sha256sum`, SHA-pinned actions — findings 8 and Low.

---

## Review limitations

Both inputs were static reviews of the checked-in tree; no workflow was
launched. ShellCheck was unavailable in the codex environment; `bash -n`
passed for all shell scripts. The merge pass re-verified each Critical/High
claim's cited lines against `e298b40` by hand (marked ✓); Medium/Low items
retain the confidence of their originating review, upgraded where both reviews
found them independently.
