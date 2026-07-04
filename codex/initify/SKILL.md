---
name: initify
description: Set up a repository to satisfy orchestrify's pre-flight — the bare-repo-with-worktrees layout with a default-branch worktree, a capable git, the Claude CLI reviewer, and GNU timeout. Use when the user wants to prepare a new repository, an existing conventional checkout, or a fresh clone for orchestrify runs, or when orchestrify's pre-flight failed and they want the gates fixed. Interactive and consent-per-step — it restructures repositories and installs tools, so every mutating action is confirmed first. Do not use to write a brief or run a feature.
---

# Initify

Make orchestrify's pre-flight pass. The repository layout is fixed once per repo; the tooling gates once per machine. Orchestrify refuses to do any of this autonomously — converting a repo and installing tools are the user's decisions — and this skill is where that decision gets made: invoking it is the consent, and each mutating step confirms once more before acting.

The temperament is the opposite of orchestrify's: interactive throughout, consent per step, no autonomy. It runs once, so there is nothing to gain by not asking.

## 1. Diagnose

If inside a git repository, run orchestrify's pre-flight first — read-only; its gate lines are the work list:

```bash
bash <orchestrify-skill-dir>/scripts/preflight.sh
```

Report the failing gates, then fix them in the order below. On `RESULT: PASS`, say so and stop.

If not inside a repository, ask which case applies: initialize a new repository here, convert an existing checkout elsewhere, or clone a remote URL into the layout. A URL or path in the user's request answers this without asking.

## 2. Repository layout

The target in every case — including the **default worktree**, named after the default branch, which every case must end with:

```text
<repo-root>/
├── .bare/              # the bare repository (shared object store)
├── .git                # one line: gitdir: ./.bare
└── <default-branch>/   # the default worktree, e.g. main/
```

### New repository

Ask for the default branch name (default `main`), then:

```bash
mkdir -p <repo-root>
git init --bare <repo-root>/.bare -b <branch>
printf 'gitdir: ./.bare\n' > <repo-root>/.git
git -C <repo-root> worktree add --orphan -b <branch> <repo-root>/<branch>
```

`worktree add --orphan` needs git ≥ 2.42; on older git, recommend upgrading rather than improvising with plumbing.

### Clone from a URL

```bash
git clone --bare <url> <repo-root>/.bare
printf 'gitdir: ./.bare\n' > <repo-root>/.git
git -C <repo-root> config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git -C <repo-root> fetch origin
```

The fetch-refspec line matters: bare clones get none, so `git fetch` silently updates nothing until it is set. Then create the default worktree:

```bash
branch=$(git -C <repo-root> symbolic-ref --short HEAD)
git -C <repo-root> worktree add <repo-root>/$branch $branch
```

### Convert an existing conventional checkout

This restructures the repository in place, and **every path changes** — the working files move from `<repo-root>/` into `<repo-root>/<branch>/`, so open editors, terminal cwds, and IDE configs all need re-pointing. Present the before/after layout and get explicit confirmation before touching anything.

Preconditions — stop and tell the user how to clear them, never work around:

- A clean tree: `git status --porcelain` shows no staged or unstaged changes (untracked files are fine — they are preserved below).
- No existing linked worktrees (`git worktree list` shows only the main checkout).
- No submodules (`.gitmodules` absent) — worktrees and submodules interact badly.

Procedure, from the checkout root:

1. Record the current branch and the untracked files, ignored ones included — these are the `.env`s and caches a fresh checkout would lose:

   ```bash
   branch=$(git symbolic-ref --short HEAD)
   git ls-files --others > /tmp/untracked-manifest
   ```

2. Convert the object store:

   ```bash
   mv .git .bare
   git --git-dir=.bare config core.bare true
   printf 'gitdir: ./.bare\n' > .git
   ```

3. Create the default worktree — a fresh checkout of the tracked files:

   ```bash
   git worktree add ./<branch> <branch>
   ```

4. Move every file in the untracked manifest into the worktree, preserving relative paths.

5. Only now delete what remains at the top level besides `.bare`, `.git`, `<branch>`, and `.orchestrify` (if present) — it is exactly the old tracked content, now owned by the worktree. Confirm once more before this deletion, and verify first that `git -C <branch> status` looks sane and the untracked files arrived.

Nothing here touches history, refs, remotes, or config beyond `core.bare` — the conversion is layout-only and reversible until step 5.

## 3. Machine tooling

Fix only the gates the pre-flight flagged, each with consent:

- **git** — must support worktree operations; upgrade via the platform package manager if the `GIT` gate failed.
- **Claude CLI** — the independent reviewer. Install: `npm i -g @anthropic-ai/claude-code`. Authentication is interactive and the user's own action; have them run `claude` and complete login, then re-check.
- **GNU timeout** — on macOS: `brew install coreutils` (provides `gtimeout`). Linux ships `timeout` already.

Also remind the user of the two session-level requirements initify cannot fix from here: an orchestrify run needs a Codex session with the multi-agent spawn/wait/message/close tools available, and a permission policy broad enough that routine worktree, build, test, and local-git operations do not prompt mid-run.

## 4. Verify

Re-run the pre-flight and require `RESULT: PASS`. Report what changed, gate by gate, plus anything still pending on the user (a Claude login not yet completed). Close by pointing at the workflow the repo is now ready for: briefify to capture a feature's intent, then orchestrify to run it.

## Invariants

- Every mutating action is announced and confirmed first; diagnosis is free.
- Never touch history, refs, or remotes. The conversion changes layout, not content.
- Stop rather than improvise on: a dirty tree, existing worktrees, submodules, or a bare-with-worktrees repo whose shape differs from the target (report the difference instead).
- The default worktree is not optional: a bare store with no worktree strands the user, and orchestrify's deliverable — a branch to land — assumes a working copy to land it from.
