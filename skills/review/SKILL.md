---
description: Open a finished orca deliverable branch (`feature/<slug>` or `fix/<slug>`) for human review in the user's own editor — a new tmux window in the current session, sitting in the deliverable's integration worktree, running orca.nvim's `:OrcaReview` (quickfix file list, native side-by-side merge-base diffs, the user's LSP and colors). Use after a run's report, before landing with `git merge --no-ff`; quitting nvim (`:qa`) returns to the invoking window. Reads the `editor` and `terminal` keys from `.orca/config.json` — absent → detect, pinned → loud fail, `none` → opt out to a printed command. Not the automated review stage (that runs inside orca:feature and orca:debug runs), and never merges anything itself.
args: <optional deliverable branch, e.g. feature/rate-limiting>
user-invocable: true
disable-model-invocation: true
---

# Orca: review

Hand a run's deliverable to the human, in their editor. A finished run leaves a branch — `feature/<slug>` or `fix/<slug>` — checked out in an integration worktree; this skill opens that worktree in a **new tmux window in the same session**, running orca.nvim's `:OrcaReview`, so the user walks the merge-base diff with their own quickfix list, LSP, and colors, quits nvim, and lands back in the window they came from, ready to `git merge --no-ff`.

The mechanism is tmux because nothing else works: the harness's shell has no TTY, so a skill can never run interactive nvim itself — `tmux new-window` is the one way an agent-side command puts a live editor in front of the user. Detection is free: the shell inherits the launch environment, so `$TMUX` being set means both "tmux is running" and "this socket, this session" — a bare `tmux new-window` lands where the user already is.

The window must open **in the integration worktree**, not the user's own. orca.nvim's diff pairs put the working-tree file on the right side (deliberate — LSP attaches, nits are fixable inline), so `:OrcaReview` is only correct where the deliverable branch is checked out. Opening with cwd = the integration worktree makes the bare command right with zero range plumbing; trunk resolution is the nvim plugin's job.

## Step 1: Discover deliverables

Resolve `<repo-root>` as the parent of `git rev-parse --path-format=absolute --git-common-dir`. Not a git repository, or not the bare-repo layout → say so and point at orca:init; there is nothing to review outside it.

Resolve the trunk from the bare repo — `git symbolic-ref --short HEAD` against the common dir (the same resolution orca.nvim uses) — then list candidate branches and join them with their worktrees:

```bash
git branch --list 'feature/*' 'fix/*' --no-merged <trunk> --format='%(refname:short)'
git worktree list --porcelain
```

A **deliverable** is an unmerged `feature/<slug>` or `fix/<slug>` branch checked out in an integration worktree at the repo root (`orca-<slug>` / `orca-fix-<slug>`) — match branch-to-worktree through the porcelain output, never by guessing paths. Per-item branches (`feature/<slug>-W<n>`, kept by blocked items) are not deliverables; do not offer them.

Triage in the house style — offer the first match, never force it:

- **None** → say so plainly: nothing to review; runs produce deliverables, so point at `/orca:feature` and `/orca:debug`.
- **One** → open it (Step 2 onward).
- **Several** → ask which. An `<args>` branch that names one skips the ask; an `<args>` branch that names nothing discovered is a loud miss — list what was found, never guess.
- **Branch unmerged but its worktree is gone** → the branch is still reviewable; offer to add the worktree back on the existing branch, then proceed. The path comes from the branch's namespace — `feature/<slug>` → `<repo-root>/orca-<slug>`, `fix/<slug>` → `<repo-root>/orca-fix-<slug>`:

  ```bash
  git worktree add <repo-root>/orca-<slug> feature/<slug>       # or
  git worktree add <repo-root>/orca-fix-<slug> fix/<slug>
  ```

Whatever the route, carry the selected deliverable forward as the pair `<branch>` + `<worktree>` — the worktree path taken from the porcelain output (or the re-add above), never rebuilt by guessing.

## Step 2: Resolve editor and terminal

Read `.orca/config.json` at the repo root for the two flat top-level keys, each with the same three-state contract as `reviewer` — **absent → detect, pinned → loud fail, `none` → opt out**:

- **`editor`** (`nvim` | `none`). Detection: `nvim` on PATH **and** the orca.nvim probe passes —

  ```bash
  nvim --headless "+lua io.write(pcall(require,'orca') and 'yes' or 'no')" +qa!
  ```

  Probe says `no` while `editor=nvim` is **pinned** → loud FAIL: name the probe, point at `/orca:doctor`'s orca.nvim prescription, stop. Probe fails while merely **detected** → fall through to the print-only path with the same doctor pointer, stated once. `editor=none` → the user reviews their own way; print-only path.

- **`terminal`** (`tmux` | `none`). Detection: `$TMUX` is set in this session's environment. `terminal=tmux` **pinned** while `$TMUX` is unset → loud stop — "start claude inside tmux, or unpin `terminal`" — never a silent downgrade to printing. `$TMUX` unset and no pin → print-only path. `terminal=none` → print-only path.

An unknown value in either key is a loud pre-flight-style FAIL naming the allowed values — never a guess. Nothing here writes the config; changes go through `/orca:config`.

## Step 3: Open

Both keys resolved to their working values → create the window, focused immediately (the skill is user-invoked; "review now" means take me there), with the deliverable's `<worktree>` from Step 1 as cwd:

```bash
win=$(tmux new-window -P -F '#{window_id}' -n review \
      -c "<worktree>" 'nvim "+OrcaReview"')
tmux set-option -w -t "$win" remain-on-exit off
```

If `tmux` errors as a broken alias or shell function (login profiles that wrap tmux leak aliases into this shell without their definitions), invoke the binary itself — `$(whence -p tmux)` — same arguments; `$TMUX` already picked the socket and session.

No machinery for close-and-return: the window's lifetime is nvim's process lifetime — `:qa` destroys it — and tmux replaces a destroyed active window from its MRU stack, so the user lands back exactly where they invoked the skill. Both are tmux defaults; the per-window `remain-on-exit off` only guards users who set it `on` globally.

## Step 4: Leave the message behind

The user's focus just moved, so the skill's last output is what they read when they return. State, in order: the review is open in tmux window `review`, in `<worktree>`; quit nvim (`:qa`) to land back here; when satisfied, land the branch from your own worktree:

```bash
git merge --no-ff <branch>
```

Fire-and-forget — do not wait on, poll, or watch the window; the run ends here.

## The print-only path

Taken when any of: `terminal=none`, `$TMUX` unset (undetected, not pinned), `editor=none`, or the orca.nvim probe failed undetected. Emit the exact command and stop cleanly:

- **nvim usable, no tmux** — `cd <worktree> && nvim "+OrcaReview"`
- **no usable editor** (`editor=none`, or probe failed) — the no-install fallback, from the integration worktree: `git difftool -d <trunk>...HEAD` (vimdiff via `-t vimdiff` if no difftool is configured)

Either way, close with the landing command as in Step 4. Do not guess at detached tmux sessions, terminal emulators, or other editors — one hard-coded implementation behind two config gates, on purpose.

## Guidelines

- Never merge, commit, or write anything in any worktree — the deliverable is landed by the user's own hand; this skill only opens the view.
- Never edit `.orca/config.json` — pinning or clearing `editor`/`terminal` belongs to orca:config; a failed probe's install belongs to orca:doctor. Recommend both by name.
- This is the *human* half of review. The automated adversarial review stage lives inside runs (`agents.review`, the `reviewer` key) and is not touched, configured, or replaced here.
