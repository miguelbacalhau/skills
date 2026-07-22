---
description: Open a finished orca deliverable branch (`feature/<slug>` or `fix/<slug>`) for human review in the user's own editor — orca.nvim's `:OrcaReview` in a new tmux window (quickfix file list, native side-by-side merge-base diffs, the user's LSP and colors), or orca.vscode's review session in a VS Code window opened on the worktree via `code --open-url` — then close the loop on the comments the review leaves behind: `:OrcaComment` notes persist to `.orca/review-notes/<key>.json`, a background waiter picks them up when nvim closes, and — on the user's say-so, never on its own — a dedicated agent addresses them and writes resolutions back for the next `:OrcaReview` to render inline. Use after a run's report, before landing with `git merge --no-ff`. Reads the `editor` and `terminal` keys from `.orca/config.json` — absent → detect (nvim first, then vscode), pinned → loud fail, `none` → opt out to a printed command. Not the automated review stage (that runs inside orca:feature and orca:debug runs), and never merges anything itself.
args: <optional deliverable branch, e.g. feature/rate-limiting>
user-invocable: true
disable-model-invocation: true
---

# Orca: review

Hand a run's deliverable to the human, in their editor — and take their comments back. A finished run leaves a branch — `feature/<slug>` or `fix/<slug>` — checked out in an integration worktree; this skill opens that worktree in the user's editor running an orca review session — orca.nvim's `:OrcaReview` in a new tmux window, or orca.vscode's review session via `code --open-url` — so the user walks the merge-base diff with their own file list, LSP, and colors. Comments they leave with `:OrcaComment` persist to `.orca/review-notes/<key>.json`; when the review session ends, this skill reads them, lays out a per-comment plan, and — only with the user's consent to that plan — converts them into fixes and answers, writing each resolution back into the same file, where the next `:OrcaReview` renders it inline under its anchor. When the review comes back clean, the user lands the branch with `git merge --no-ff`.

The deterministic spine — deliverable discovery, editor/terminal resolution, probes, the launch, the window wait, and the validated notes read — lives in the bundled script; its header comment documents the full output contract. This skill is the conversational shell around it: triage, failure translation, the per-comment plan, the consent gate, and the parting message.

**The notes file is the source of truth; window-exit is only the wake signal.** The plugin creates the file lazily on the first comment and deletes it with the last — no file and no comments mean the same thing. Every mutation is a whole-file snapshot, the workflow is one-writer-at-a-time by design, and both sides fail loud on a schema version they don't speak. Unconsumed comments are discoverable state, like queued briefs: whatever kills the wake signal (session death, the vscode tier, a multi-sitting review), the next triage finds them.

## Step 1: Discover deliverables

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/review.sh discover
```

Exit 1 with a typed `FAIL:` (`NOT_GIT`, `NOT_BARE`) means there is nothing to review outside the bare-repo layout — say so and point at `/orca:init`. Otherwise read the `DELIVERABLE:` lines — tab-separated `branch`, `worktree`, `ok`/`missing` — and triage in the house style, offering the first match, never forcing it:

- **None** → say so plainly: nothing to review; runs produce deliverables, so point at `/orca:feature` and `/orca:debug`.
- **One** → open it (Step 2 onward).
- **Several** → ask which. An `<args>` branch that names one skips the ask; an `<args>` branch that names nothing discovered is a loud miss — list what was found, never guess.
- **`missing`** → the branch is unmerged but its worktree is gone; still reviewable. Offer to add the worktree back on the existing branch, and on consent run — both values verbatim from the `DELIVERABLE:` line, never rebuilt by guessing —

  ```bash
  git worktree add <worktree> <branch>
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/secrets.sh place <worktree>
  ```

  then re-run `discover` to pick up the path. The `place` call links the user's secrets (`.orca/secrets/`, the mirror-tree convention) into the fresh worktree as relative symlinks — part of the same consent as the add, and best-effort: typed skips (`UNIGNORED:`, `SKIPPED_EXISTS:`) are worth a mention, never a stop.

**Unconsumed comments.** A `DELIVERABLE:` followed by a `NOTES:` line (path, then `open,addressed,answered` counts) has review comments waiting from an earlier session — the decoupled pick-up that covers the vscode tier and any session where the waiter died. When the open count is nonzero, offer the choice before the plain open: "the review of `<branch>` has N unaddressed comments — address them, or open the review again?" Addressing goes to Step 4's gate (lay out the per-comment plan first, then ask — the same three-way gate); re-opening proceeds to Step 2 with the comments intact. A `NOTES_VERSION:` line after a deliverable is a version skew — surface it as Step 4 describes before anything else touches that deliverable.

Carry the selected deliverable forward as the pair `<branch>` + `<worktree>`, exactly as emitted.

## Step 2: Open

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/review.sh open <worktree>
```

The script resolves the `editor` and `terminal` keys from `.orca/config.json` (each with the same three-state contract as `reviewer` — absent → detect, nvim probed before vscode; pinned → loud fail; `none` → opt out), runs the plugin probes, and launches: a focused tmux window named `review` running `:OrcaReview` for nvim, or orca.vscode's URI handler for vscode. Every outcome first emits a `NOTES:` line — the absolute path where `:OrcaComment` notes will land for this deliverable; hold onto it. Act on the exit code:

- **0** — launched; the `OPEN:` line says which path. Go to Step 3.
- **1** — a typed `FAIL:`; nothing was launched. Translate it and stop: a failed probe on a pinned editor (`PINNED_PROBE_FAILED`) → `/orca:doctor` prescribes the fix; `PINNED_TERMINAL_UNSET` → start claude inside tmux, or unpin `terminal`; `UNKNOWN_VALUE` → name the allowed values and point at `/orca:config`. Never work around a loud fail by downgrading to the print-only path.
- **2** — `PRINT_ONLY:` plus a `COMMAND:` line; nothing was launched, and that is a clean outcome, not an error. Print the command for the user to run themselves, with any `PROBE_FAILED:` context summarized once — a single `/orca:doctor` pointer covers every failed tier. Then close with Step 3's parting message (no waiter — there is no window to wait on). Do not guess at detached tmux sessions, terminal emulators, or other editors — hard-coded implementations behind config gates, on purpose.

## Step 3: Launch the waiter, leave the message behind

**nvim tier (`OPEN: nvim-tmux <window-id>`):** launch the waiter with `run_in_background` — never foreground; the turn must end cleanly while the user reviews:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/review.sh wait <window-id>
```

It polls until the window is gone, then completes — re-invoking this session with the wake signal. Then end the turn with the parting message. The user's focus just moved, so this output is what they read when they return. State, in order: the review is open in tmux window `review`; `:OrcaComment` leaves line-anchored notes; `:qa` hands them back — orca picks the comments up automatically when nvim closes; and, when satisfied, land the branch from their own worktree:

```bash
git merge --no-ff <branch>
```

**vscode tier and every `PRINT_ONLY` path:** no window-lifetime handle, no waiter. The parting message names where the review is (a VS Code window on `<worktree>` — close it when done; or the printed command), that comments left with the editor's orca comment command are picked up by the next `/orca:review`, and the same landing command.

The *skill turn* still ends cleanly after launching the waiter — never wait on, poll, or watch the window in the foreground — but the session now has a standing background task; window death is what brings the flow back as Step 4.

## Step 4: The wake — read, summarize, and gate

On the wake (the background `wait` task completes with `CLOSED:`), run the validated read:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/review.sh notes <worktree>
```

- **`NOTES_NONE`** → no comments: say "no comments — ready to land" and print the `git merge --no-ff <branch>` command. Done.
- **`NOTES_VERSION:` `<found>` `<spoken>`** → loud stop, touch nothing. Name both versions and which side to update: the file is newer than orca speaks → update the orca plugin; older/other → update orca.nvim. This mirrors orca.nvim's own refusal behavior — either side clobbering the other's format is the one unrecoverable failure.
- **`NOTES:` with open comments** → Read the file (the script only counts; the text is the skill's job) and lay out, per open comment, both what the user wrote and what orca would do about it. Lead with `#N` — the id the editor showed the user, the name they know the comment by — then file:line, the comment text, and the quoted anchor line; follow with the intended handling: which of the address agent's four buckets it lands in (fix / answer / decline-as-answered / too-big-for-review) and, for a fix, a one-line approach. A comment whose intent is genuinely open gets a direct question here instead of a guess — the user is present, and this substitutes for a plan stage. Then **stop and ask — addressing never starts on its own.** Window death means "nvim closed," not "review finished"; this gate is what distinguishes done from paused. Consent is to the stated plan, not a blank check: a misread caught at the gate costs one correction in conversation; caught at re-review it costs a full round. The ask is three-way:
  - **Address now** → Step 5. The plan as consented — buckets, approaches, and any corrections or answers from the conversation — rides along in the agent's task message.
  - **Resume the review** → re-run Step 2's `open` on the same deliverable and relaunch the waiter — the wait-and-collect loop restarts as if the window had never closed, existing comments intact. Multi-sitting reviews and an accidental `:qa` cost nothing.
  - **Leave for later** → end the turn; everything stays in place. The file persists, and the next `/orca:review` triage rediscovers it.

  However many times the loop comes back around, the same gate applies.
- **`NOTES:` with zero open** (all `addressed`/`answered` — the user was re-reviewing resolutions) → say so and print the landing command.

## Step 5: Address — consented, one agent, one snapshot

Only ever entered through Step 4's gate (or the identical gate offered from Step 1's pick-up). Around the agent, in order:

1. **Archive first.** Find the run directory by grepping `.orca/*/report.md` for the `` **Deliverable:** `<branch>` `` line. Found → copy the pre-addressing notes file to `<run-dir>/reviews/comments-<timestamp>.json` (timestamp via `date +%Y%m%d-%H%M%S`). No run dir — orca.nvim works in any orca-managed repo, so a notes file can exist for a branch no run produced — archive beside it as `.orca/review-notes/<key>.<timestamp>.json`.
2. **Spawn the `orca:address` agent** (synchronous — interactive skill; waiting is fine). Its task message carries: the integration worktree path, the notes file path, the run directory when one exists (no run dir → say so: there is no spec; the comments themselves are the intent), and the per-comment plan as consented at the gate — bucket and approach per `#N`, with any corrections or answers from the conversation folded in. The agent classifies, fixes change requests, answers questions, and writes the notes file back as one whole-file snapshot with statuses and human-readable resolutions.
3. **Commit** the fixes on the deliverable branch in the integration worktree — same attribution rules as every run commit: a subject shaped like an ordinary review-feedback commit, never mentioning Claude, AI, agents, or orca, no Co-Authored-By or Generated-with trailers. Read the message back from `git log` to check before moving on. Nothing to commit (answers only) → skip, and say so.
4. **Verify the write-back:** re-run `review.sh notes <worktree>` — zero `open` remaining, version still 1. Anything else → report what the agent left undone rather than papering over it.
5. **Parting message:** what was addressed vs answered (per `#N`, with each resolution), the commit hash, that re-running `/orca:review` shows each resolution inline under its anchor — editing a comment there re-opens it for the next round; that loop is the convergence mechanism — and the `git merge --no-ff <branch>` landing command for when they're satisfied.

There is deliberately no machine re-review after addressing: the human re-running `:OrcaReview` and seeing resolutions at their anchors *is* the review.

## Guidelines

- Never merge anything, and never write in a worktree or in `.orca/review-notes/` outside two sanctioned paths: the consented `git worktree add` in Step 1 (which touches no worktree that exists — the secrets placement that follows it, writing only symlinks into that fresh worktree, is part of the same consent), and the consented addressing flow of Step 5 (the agent's fixes and notes snapshot, and the commit that follows). The deliverable is landed by the user's own hand.
- One writer at a time: never write the notes file — and never start addressing — while an editor session may be live. The gate right after window death is the sequencing; the residual race (the user reopens nvim mid-addressing) is accepted, per the contract's sequential-workflow assumption.
- Never edit `.orca/config.json` — pinning or clearing `editor`/`terminal` belongs to orca:config; a failed probe's install belongs to orca:doctor. Recommend both by name.
- This is the *human* half of review. The automated adversarial review stage lives inside runs (`agents.review`, the `reviewer` key) and is not touched, configured, or replaced here — and addressing comments must stay convergent (small deltas the user re-reads inline at their anchors), never become an unplanned work loop.
