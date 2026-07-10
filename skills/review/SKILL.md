---
description: Open a finished orca deliverable branch (`feature/<slug>` or `fix/<slug>`) for human review in the user's own editor — orca.nvim's `:OrcaReview` in a new tmux window (quickfix file list, native side-by-side merge-base diffs, the user's LSP and colors), or orca.vscode's review session in a VS Code window opened on the worktree via `code --open-url`. Use after a run's report, before landing with `git merge --no-ff`. Reads the `editor` and `terminal` keys from `.orca/config.json` — absent → detect (nvim first, then vscode), pinned → loud fail, `none` → opt out to a printed command. Not the automated review stage (that runs inside orca:feature and orca:debug runs), and never merges anything itself.
args: <optional deliverable branch, e.g. feature/rate-limiting>
user-invocable: true
disable-model-invocation: true
---

# Orca: review

Hand a run's deliverable to the human, in their editor. A finished run leaves a branch — `feature/<slug>` or `fix/<slug>` — checked out in an integration worktree; this skill opens that worktree in the user's editor running an orca review session — orca.nvim's `:OrcaReview` in a new tmux window, or orca.vscode's review session via `code --open-url` — so the user walks the merge-base diff with their own file list, LSP, and colors, then lands the branch with `git merge --no-ff`.

The deterministic spine — deliverable discovery, editor/terminal resolution, probes, launch — lives in the bundled script; its header comment documents the full output contract. This skill is the conversational shell around it: triage, failure translation, and the parting message.

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
  ```

  then re-run `discover` to pick up the path.

Carry the selected deliverable forward as the pair `<branch>` + `<worktree>`, exactly as emitted.

## Step 2: Open

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/review.sh open <worktree>
```

The script resolves the `editor` and `terminal` keys from `.orca/config.json` (each with the same three-state contract as `reviewer` — absent → detect, nvim probed before vscode; pinned → loud fail; `none` → opt out), runs the plugin probes, and launches: a focused tmux window named `review` running `:OrcaReview` for nvim, or orca.vscode's URI handler for vscode. Act on the exit code:

- **0** — launched; the `OPEN:` line says which path. Go to Step 3.
- **1** — a typed `FAIL:`; nothing was launched. Translate it and stop: a failed probe on a pinned editor (`PINNED_PROBE_FAILED`) → `/orca:doctor` prescribes the fix; `PINNED_TERMINAL_UNSET` → start claude inside tmux, or unpin `terminal`; `UNKNOWN_VALUE` → name the allowed values and point at `/orca:config`. Never work around a loud fail by downgrading to the print-only path.
- **2** — `PRINT_ONLY:` plus a `COMMAND:` line; nothing was launched, and that is a clean outcome, not an error. Print the command for the user to run themselves, with any `PROBE_FAILED:` context summarized once — a single `/orca:doctor` pointer covers every failed tier. Then close with Step 3's landing command. Do not guess at detached tmux sessions, terminal emulators, or other editors — hard-coded implementations behind config gates, on purpose.

## Step 3: Leave the message behind

The user's focus just moved, so the skill's last output is what they read when they return. State, in order: where the review is open — tmux window `review` for nvim (quit with `:qa` to land back here), a VS Code window on `<worktree>` for vscode (close the review window when done; there is no window-lifetime tie to preserve — GUI) — and, when satisfied, land the branch from your own worktree:

```bash
git merge --no-ff <branch>
```

Fire-and-forget — do not wait on, poll, or watch the window; the run ends here.

## Guidelines

- Never merge, commit, or write anything in any worktree — the script's launch is the one sanctioned side effect; the deliverable is landed by the user's own hand. The one exception is the consented `git worktree add` in Step 1, which touches no worktree that exists.
- Never edit `.orca/config.json` — pinning or clearing `editor`/`terminal` belongs to orca:config; a failed probe's install belongs to orca:doctor. Recommend both by name.
- This is the *human* half of review. The automated adversarial review stage lives inside runs (`agents.review`, the `reviewer` key) and is not touched, configured, or replaced here.
