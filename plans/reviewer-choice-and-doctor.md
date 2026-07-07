# Plan: Configurable reviewer (codex | claude) and the `orca:doctor` skill

Two coupled changes:

1. A per-repo **reviewer choice** — the work loop's independent review runs either
   through Codex (cross-model, today's behavior) or through a new dedicated Claude
   review agent. Chosen via `.orca/config.json`; when unset, resolved by detecting
   whether codex is usable on the machine.
2. A new **`orca:doctor` skill** that owns machine/session tooling (codex
   presence/version/auth guidance, the `MCP_TOOL_TIMEOUT` settings write, the
   `bypassPermissions` offer), slimming `orca:init` down to its real job: the
   bare-repo-with-worktrees layout.

## Decisions (settled)

- **Config key:** top-level `"reviewer": "codex" | "claude"` in
  `.orca/config.json` — *not* inside the `agents` block, because it selects a
  different agent entirely rather than tuning model/effort on an existing one.
- **No install-time hook.** Verified against current plugin docs: plugins have no
  onInstall/postInstall event; SessionStart is the closest and is wrong for this
  (fires every session in every project, non-interactive, and `codex login` is
  inherently the user's interactive action). Nothing happens "at install".
  Instead, an **absent key is resolved at run launch**: codex binary on PATH at
  the minimum version → `codex`, else `claude`. A written key pins the choice.
- **Detection boundary:** detection means *binary present at ≥ min version* only.
  If codex is detected (or pinned) and then auth or `MCP_TOOL_TIMEOUT` fail,
  that is a `FAIL` with remediation via doctor — never a silent downgrade to
  claude. Silent downgrades would swap the reviewer out from under a codex user.
- **Agent naming:** `agents/review.md` (`orca:review`) keeps its name and stays
  the Codex courier; the new agent is `agents/review-claude.md`
  (`orca:review-claude`). No rename to `review-codex` — it would break resume of
  in-flight runs (agentType is a journal key) for zero functional gain.
- **Config stage name:** `review` remains the single tunable stage key; its
  overrides apply to whichever reviewer agent is active. With codex it tunes the
  courier (cost only, as today); with claude it tunes the actual reviewer
  (quality) — the orca:config caveat becomes conditional.
- **Claude reviewer defaults:** `model: opus`, `effort: high`. It performs real
  review judgment (unlike the sonnet/medium courier), but `xhigh` would make
  review the most expensive stage per item — it runs up to 3× per item across
  fix rounds. Tunable per repo anyway.
- **Artifact names:** `<run-dir>/reviews/<ID>-codex.json` becomes
  `<ID>-<reviewer>.json` (`-codex` / `-claude`), same for the per-round
  archives — provenance stays visible in the archived rounds.
- **Review throttle:** the 2-slot throttle exists only because Codex reviews
  contend for one codex auth. It applies **only when the reviewer is codex**;
  claude reviews ride the workflow's normal concurrency cap.
- **The independence trade-off is documented, not hidden.** Cross-model review
  is the stronger design (a different model family does not share the
  implementer's blind spots). The claude reviewer keeps fresh-context
  independence — separate agent, only the artifacts and the diff, adversarial
  framing — but is same-model. Stated wherever the choice is made: doctor's
  report, orca:config's confirmation, the README.
- **Doctor's temperament:** like init — interactive, consent per mutating step,
  diagnosis free. "Doctor" over "setup" because it mostly *prescribes*: codex
  installs come from brew/release binaries by the user's hand, auth is
  interactive; the only things it writes are settings blocks, each confirmed.
- **`bypassPermissions` offer moves to doctor** — it is run-environment tooling,
  not repository layout.
- **Skill split:** init = layout only (destructive, heavily confirmed,
  quarantined); doctor = everything machine/session. Init ends by running the
  read-only preflight and pointing at doctor if machine gates fail — free
  information, no scope creep.

## Naming / surface map

| Surface | Value |
|---|---|
| Config key | `.orca/config.json` → `"reviewer": "codex" \| "claude"` |
| New agent | `agents/review-claude.md` → `orca:review-claude` (opus / high) |
| Existing agent | `agents/review.md` → `orca:review`, unchanged name, Codex courier |
| New skill | `skills/doctor/SKILL.md` → `/orca:doctor` |
| Review artifacts | `<run-dir>/reviews/<ID>-<reviewer>.json` (+ `.round<N>` archives) |
| Preflight output | new `REVIEWER: codex \| claude (pinned \| detected)` line; `CODEX` gate becomes conditional |
| Workflow args | new `reviewer` field, validated ∈ {`codex`, `claude`} |
| spec.md record | `**Workflow reviewer:** <value>` line beside the runId, for resume |

## Steps

### 1. New agent: `agents/review-claude.md`

The fundamental difference from the courier: this agent **is** the reviewer, not
a transport for one. It carries the adversarial review stance as its own
marching orders and reads the materials itself.

- Frontmatter: `name: review-claude`, `model: opus`, `effort: high`,
  `tools: Read, Grep, Glob, Bash, Write, TaskUpdate`. Bash is needed for
  `git diff`/`git log` in the worktree; the body states the read-only
  discipline explicitly (inspect, never mutate — no file edits, no git writes,
  no test runs that write artifacts), backed by a **mechanical self-check**:
  as its first Bash action the agent captures the worktree state
  (`git status --porcelain` plus a hash of `git diff`), and re-captures both
  immediately before writing the artifact. A mismatch means the review
  contaminated the diff it was reviewing — return `written: false` with a
  reason naming the contamination, write nothing. Detection, not prevention,
  but it catches the actual harm regardless of which command caused it.
- Body, adapted from `agents/review.md`'s template so the two reviewers hunt
  for the same things under the same contract:
  - Same task-message inputs: worktree, run dir, item ID, mode
    (`item` | `integration`), artifact path, round-archive path, owned files;
    same optional `Status task:` line handling.
  - Same adversarial stance, translated from prompt-for-codex to
    self-instruction: assume at least one real defect; an approval that finds
    nothing is the failure mode; the spec's **Interfaces** section (read fresh
    from `<run-dir>/spec.md`) is the hard contract; attack the tests
    specifically — the same model family wrote the code and the tests, so name
    the edge cases, error paths, and interface boundaries the suite does NOT
    exercise. Item mode adds the plan/Deviations reading and the
    ownership-violation hunt; integration mode scopes to the whole Interfaces
    section, exactly as the courier's template does.
  - Same findings schema, byte-compatible with the codex artifacts so
    `orca:fix` reads both without caring which reviewer ran:
    `{"findings": [{"severity", "file", "line", "title", "body", "fix_location"}]}` —
    an empty array is a legitimate clean pass.
  - Same write/count/return contract: compose the JSON itself, `Write` it to
    the artifact path and the round archive (with the same
    read-before-overwrite handling for re-review rounds), count `total` and
    `criticalHigh` from the array it wrote (unrecognized severity counts as
    criticalHigh), return `{written, total, criticalHigh, reason}`.
  - Same failure discipline: on any failure, write nothing and return
    `written: false` with the reason.
- What does *not* carry over: everything MCP — ToolSearch loading, the codex
  call, retry-by-failure-class, envelope/payload parsing. This agent has no
  external call to fail; its failure modes are its own (can't read the spec,
  can't produce the diff) and are reported as `written: false`.

### 2. Workflow script: `skills/run/scripts/work-loop.workflow.js`

- Accept `args.reviewer`, validate ∈ {`codex`, `claude`} at launch alongside
  the existing args validation. The value is **required** in args (the SKILL
  resolves defaulting before launch; the script never detects — it cannot run
  shell commands and must stay deterministic for resume).
- `review()`: resolve `agentType` (`'orca:review'` vs `'orca:review-claude'`)
  and the artifact suffix (`-codex.json` / `-claude.json` and round archives)
  from the reviewer. The `REVIEW` return schema, retry loop, and both call
  sites (per-item, integration) are unchanged.
- `withReviewSlot` wraps the review call **only when reviewer === 'codex'**;
  claude reviews call `agent()` directly.
- The `review` stage stays in `TUNABLE`; `tuned('review', …)` applies to either
  agent unchanged.
- Sweep comments and `meta.phases` detail text: "Codex review" → reviewer-aware
  wording ("independent review (codex or claude per config)"), the throttle
  comment notes it is codex-only.

### 3. Preflight: `skills/run/scripts/preflight.sh`

- Resolve the reviewer first: read `"reviewer"` from `./.orca/config.json` when
  the file exists — grep-based extraction, no jq or python dependency
  (`grep -o '"reviewer"[[:space:]]*:[[:space:]]*"[a-z]*"'` style). Extraction
  rule: collect all matches, dedupe; **zero** matches → key absent, fall
  through to detection; **exactly one** value and it is `codex`/`claude` → use
  it as pinned; **anything else** (multiple distinct values, an unrecognized
  value) → `REVIEWER: FAIL: invalid reviewer in .orca/config.json — fix with
  orca:config`, counted toward the exit code. Safe because orca:config is the
  only writer and emits compact well-formed JSON in which `reviewer` cannot
  appear as a nested key; a hand-mangled file fails loudly, never guesses.
  Absent → detect: codex on PATH at ≥ `codex_min_version` → `codex`, else
  `claude`.
- Print `REVIEWER: <value> (pinned)` or `REVIEWER: <value> (detected)` as a new
  informational line, like `TRUNK_CANDIDATE`.
- The `CODEX` gate runs only when the resolved reviewer is codex; with claude it
  prints `CODEX: SKIPPED: reviewer is claude` (not PASS — it was not checked).
  The third state is safe: nothing parses gate lines mechanically — the only
  machine-read outputs are `RESULT:` and the exit code; every other consumer
  (run/init/doctor SKILL.md prose) is model-read and gets updated in steps 4,
  6, and 7 to enumerate `PASS | FAIL | SKIPPED` for this gate. Remediation
  text in the gate messages re-points from orca:init to **orca:doctor** for
  the machine checks.
- `BARE_REPO` and `TRUNK_CANDIDATE` unchanged. Header comment updated: the
  script now reads one config key; still no side effects, still exit-0 iff all
  gates pass.

### 4. Run skill: `skills/run/SKILL.md`

- **Config read (Step 2):** validate the new top-level `reviewer` key with the
  same fail-fast posture as the `agents` block. Hold the *resolved* reviewer for
  the run: pinned value if present, else the preflight's detected value — the
  `REVIEWER:` line from Step 1's preflight output is the source, so no second
  probe.
- **Live MCP gate (Step 1):** conditional — the
  `select:mcp__plugin_orca_codex__codex` check runs only when the resolved
  reviewer is codex.
- **Launch (Step 4):** pass `reviewer` in the Workflow args always (the
  resolved value, never absent). Persist it beside the runId:
  `**Workflow reviewer:** <value>` in `spec.md` — same rationale as the agents
  line: resume must use the launch-time value, and the config file may have
  changed since.
- **Resume instructions:** rebuild args including `reviewer` from the spec.md
  line; a missing line (pre-feature run) means codex, the only reviewer that
  existed.
- **Prose sweep:** the description and body currently say "Codex" wherever they
  mean "the independent reviewer" — reword to reviewer-neutral with the codex
  case called out as the cross-model default (description, requirement gates
  Step 1, the work-loop narration, the Guidelines' review paragraphs).
  Remediation pointers split: layout gate → orca:init, machine gates →
  orca:doctor.

### 5. Config skill: `skills/config/SKILL.md`

- New assignment form: `reviewer=codex` / `reviewer=claude`; `reviewer=default`
  clears the key (back to detection). Validate the value; on `reviewer=claude`
  state the independence trade-off in one sentence; on `reviewer=codex` note
  the codex machine gates must pass (point at orca:doctor if they currently
  don't — preflight tells).
- Show the reviewer above the stage table: effective value with provenance —
  `codex (pinned)` / `claude (detected — codex not on PATH)`.
- The `review` stage caveat becomes conditional: with codex, tuning `review`
  changes the courier's cost, never review quality; with claude, it tunes the
  actual reviewer. Table role text for `review` reflects the active reviewer.
- `reset` clears the reviewer key too; document that. File-hygiene rules
  (merge, remove-when-empty) already handle a top-level key — extend the
  examples to show one.

### 6. New skill: `skills/doctor/SKILL.md`

Frontmatter: user-invocable, `disable-model-invocation: true`, args optional.
Description triggers on: machine/tooling setup for orca, codex install/auth
problems, `MCP_TOOL_TIMEOUT`, preflight machine-gate failures, choosing or
checking the reviewer. Explicitly *not* for repository layout (that is
orca:init) and does not start runs.

Body:

1. **Diagnose** — inside a git repository, run
   `bash ${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/preflight.sh` from the
   project root and report every gate plus the `REVIEWER:` line in plain
   language (`PASS | FAIL | SKIPPED` for the codex gate). **Outside a
   repository**, machine-only mode: say the layout gate and reviewer pinning
   are per-repo and unchecked here, probe codex directly (PATH, version, auth)
   with the same checks the preflight runs, treat the resolved reviewer as
   detected-only, offer the `MCP_TOOL_TIMEOUT` write to `~/.claude/settings.json`
   only (there is no project settings file to offer), and skip the
   `bypassPermissions` offer (also per-repo).
2. **Route layout failures away** — `BARE_REPO: FAIL` → point at orca:init;
   never restructure anything here.
3. **Fix machine gates, consent per step, reviewer-aware:**
   - Reviewer **codex** (pinned or detected): codex missing/stale → surface the
     official non-npm install (`brew install codex` or release binaries; never
     npm — the hard rule stands); unauthenticated → suggest `! codex login`,
     verify with `! codex login status`; `MCP_TOOL_TIMEOUT` unset → write
     `"MCP_TOOL_TIMEOUT": "1200000"` into the `env` block of
     `.claude/settings.local.json` or `~/.claude/settings.json` (user's
     choice), merged not overwritten, with the session-restart caveat and the
     "why ~20 minutes" rationale carried over from init verbatim.
   - Reviewer **claude** (detected, codex absent): nothing to fix — state that
     runs will use the Claude reviewer, and that installing codex enables
     cross-model review (stronger: a different model family does not share the
     implementer's blind spots). Offer to pin either choice via orca:config;
     the write itself belongs to orca:config, not here.
   - Reviewer **claude (pinned)** with codex present: note the codex gates were
     skipped by choice; nothing to do.
4. **Optional, offered never defaulted:** the `bypassPermissions` default-mode
   write for always-unattended repos, moved here from init, tradeoff stated
   verbatim (disables the approval gate for every session in that worktree).
5. **Verify** — re-run the preflight; report gate by gate, name what remains on
   the user (a login not yet done, a session restart pending), close by
   pointing at `/orca:brief` → `/orca:run`.

### 7. Slim `orca:init`: `skills/init/SKILL.md`

- Remove Step 3 (machine tooling) entirely — codex guidance, the
  `MCP_TOOL_TIMEOUT` write, and the `bypassPermissions` offer all move to
  doctor.
- Description updated: layout only; drop "plus the Codex CLI checks".
- Step 4 (verify) becomes: re-run the preflight; the layout gate must pass;
  machine-gate failures are reported with a pointer at `/orca:doctor` rather
  than fixed here. Closing pointer: `/orca:doctor` (if machine gates fail) →
  `/orca:brief` → `/orca:run`.
- Guidelines keep the layout-only hard lines; drop the tooling ones.

### 8. README

Where each change lands:

- **Intro command block & Quick start:** add `/orca:doctor` (machine tooling,
  one-time per machine); init's comment narrows to layout. Quick-start step 1
  splits: `/orca:init` (layout, per repo) and `/orca:doctor` (tooling, per
  machine — needed only if the preflight flags it).
- **How it works → "Cross-model review":** retitle to **"Independent review"**;
  codex stays the featured default with the cross-model rationale, plus one
  honest paragraph: with `reviewer=claude` (default wherever codex isn't
  installed) review keeps fresh-context independence but is same-model.
- **Requirements table:** Codex CLI row becomes conditional — "required when
  the reviewer is codex (the default when installed); with `reviewer=claude`
  the codex rows don't apply". Same for the `MCP_TOOL_TIMEOUT` row, whose
  writer changes from `/orca:init` to `/orca:doctor`.
- **Commands:** `/orca:init` section drops its machine-gates paragraph; new
  `/orca:doctor` section (diagnose, guided fixes, reviewer awareness, the
  bypassPermissions offer); `/orca:config` section adds the `reviewer=` form,
  its `default`/detection semantics, and the conditional `review`-stage caveat.
- **Anatomy of a run:** the loop line "codex review" → "review (codex or
  claude)"; the pre-flight paragraph gains the `REVIEWER` line and the
  conditional `CODEX` gate; throttle sentence marked codex-only; remediation
  split init/doctor.
- **Stage agents table:** add `review-claude` (opus / high) beside `review`;
  one sentence on which one a run uses.
- **Configuration:** the `.orca/config.json` example gains the top-level
  `"reviewer"` key with the pin-vs-detect explanation; the `MCP_TOOL_TIMEOUT`
  block re-attributes the write to `/orca:doctor` and notes it is codex-only.
- **Repository layout:** `reviews/` comment → "raw findings JSON per review
  round (codex or claude)".
- **Troubleshooting:** `CODEX: FAIL` rows re-point at `/orca:doctor`; new rows:
  "run used the Claude reviewer unexpectedly" (codex missing/stale → doctor;
  or pin `reviewer=codex`) and "REVIEWER: FAIL: invalid value" (→ orca:config).
- **Repository contents:** add `skills/doctor/`, note the ninth agent file.

### 9. Verify

In a scratch bare-repo project with `claude --plugin-dir /Users/miguel/development/skills`:

- `preflight.sh` matrix: no config + codex present → `REVIEWER: codex (detected)`,
  CODEX gate runs; no config + codex hidden from PATH → `REVIEWER: claude (detected)`,
  `CODEX: SKIPPED`, `RESULT: PASS` on layout alone; pinned `claude` with codex
  present → skipped; pinned `codex` with codex broken → FAIL; invalid value →
  FAIL naming orca:config.
- `orca:review-claude` resolves as an agent type; a live run (or a one-item
  smoke run) with `reviewer=claude` produces `reviews/<ID>-claude.json` in the
  courier-identical schema, and `orca:fix` consumes it unchanged.
- With `reviewer=claude` in a session with no codex MCP tool, `/orca:run`
  launches without the live MCP gate tripping.
- `/orca:doctor` on a machine with codex: full gate walk. Without codex:
  reports the claude fallback and offers the pin, fixes nothing.
- `/orca:init` no longer mentions codex/timeout/permissions; its closing
  preflight correctly routes machine failures to doctor.
- `/orca:config reviewer=claude` writes the top-level key, shows provenance in
  the table, states the trade-off; `reviewer=default` removes it; `reset`
  clears it.
- README renders with all cross-references (anchors, command names) intact.

## Consequences / non-goals

- **Resume across this change:** an in-flight pre-change run resumes fine for
  codex (agentType `orca:review` unchanged) **except** that review-stage prompts
  now carry `-<reviewer>.json` artifact paths — a changed prompt re-runs that
  call instead of replaying it. Acceptable: reviews are re-runnable and the
  workflow already treats them as retryable. Runs from before the plugin
  migration were already unresumable.
- **Old repos, no key:** behavior is unchanged wherever codex is installed
  (detected → codex). Machines without codex go from hard `CODEX: FAIL` to a
  working claude-reviewed run — the intended widening.
- **Non-goal:** any third reviewer, a per-run reviewer flag, or mixing
  reviewers within one run. One reviewer per run, chosen at launch.
- **Non-goal:** hooks of any kind. Detection is a preflight concern.
- **Non-goal:** doctor installing anything. It writes settings blocks with
  consent; binaries and auth remain the user's actions.

## Open items — all resolved (pre-execution)

- **Claude reviewer's Bash read-only discipline — resolved: instructions plus
  a mechanical self-check; no hook enforcement.** Verified against current
  docs: subagent `tools:` frontmatter is a flat list with no argument scoping
  (no `Bash(git diff:*)` form), and there is no `permissions`/sandbox
  frontmatter. The one mechanical option — a per-agent `PreToolUse` hook
  running an allowlist script — is rejected: an allowlist of "read-only
  commands" is brittle (a legitimate read the script didn't anticipate blocks
  mid-review and fails the item), it adds a bundled-script dependency, and
  `${CLAUDE_PLUGIN_ROOT}` substitution inside agent-frontmatter hook commands
  is unverified. The diff-hash self-check (step 1) catches the harm that
  actually matters — a contaminated worktree — regardless of which command
  caused it, and reports it loudly as `written: false`.
- **Preflight JSON extraction — resolved: grep-only, no python/jq fallback.**
  orca:config is the sole writer and emits compact well-formed JSON in which
  `reviewer` cannot occur as a nested key (the `agents` block's keys are stage
  names with `model`/`effort` fields). The zero/one/other extraction rule in
  step 3 makes every degenerate case — hand-edited file, duplicate keys,
  unknown value — a loud `REVIEWER: FAIL` pointing at orca:config, never a
  guess.
- **`CODEX: SKIPPED` line format — resolved: safe, kept.** Nothing
  pattern-matches gate lines mechanically; the machine-read surface is
  `RESULT:` plus the exit code, and the model-read consumers (run, init,
  doctor SKILL.md prose) are all updated by this plan to enumerate the
  three-state gate.
- **Doctor outside a git repo — resolved: machine-only mode**, specified in
  step 6: probe codex directly with the preflight's own checks, reviewer is
  detected-only (pinning is per-repo), the timeout write is offered at user
  level (`~/.claude/settings.json`) only, and the per-repo offers
  (`bypassPermissions`) are skipped, each with one line saying why.
- **Claude reviewer effort — resolved: `high`** (settled at plan-writing time):
  review runs up to 3× per item across fix rounds, so `xhigh` would make it
  the most expensive stage per item; per-repo tunable via
  `review.effort=xhigh` for anyone who wants more.
