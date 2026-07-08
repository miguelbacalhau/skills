---
description: Set up a repository's layout for orca runs — the bare-repo-with-worktrees structure with a default-branch worktree that orca:feature's pre-flight requires. Use when the user wants to prepare a new repository, an existing conventional checkout, or a fresh clone for orca runs, or when the pre-flight's layout gate (BARE_REPO) failed. Layout only: machine and session tooling (Codex CLI, MCP timeout, permissions) is orca:doctor's job. Interactive and consent-per-step — it restructures repositories, so every mutating action is confirmed first. Do not use to write a brief or run a feature.
args: <path or clone URL, optional>
user-invocable: true
disable-model-invocation: true
---

# Orca: init

Give a repository the layout orca:feature's pre-flight requires — fixed once per repo. The feature skill itself refuses to do this autonomously — converting a repo is the user's decision — and this skill is where that decision gets made: invoking it is the consent, and each mutating step confirms once more before acting.

The temperament is the opposite of an orca:feature run's: interactive throughout, consent per step, no autonomy. It runs once, so there is nothing to gain by not asking.

Layout only: machine and session tooling — the Codex CLI, the MCP tool timeout, permission modes — belongs to **orca:doctor**, and the subagent definitions and codex MCP server registration ship inside the orca plugin itself, so any session with the plugin has them.

## Step 1: Diagnose

If inside a git repository, run orca:feature's pre-flight first — it is read-only:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh
```

The layout gate — `BARE_REPO` — is this skill's work list; fix it with Step 2 below. The machine lines (`REVIEWER`, `CODEX` — `PASS | FAIL | SKIPPED`) are reported but not fixed here: on a machine-gate `FAIL`, point at **orca:doctor**. If `BARE_REPO` already passes, say so and stop — anything else the pre-flight flagged is doctor's, not this skill's.

If not inside a repository, ask which case applies: initialize a new repository here, convert an existing checkout elsewhere, or clone a remote URL into the layout. A URL or path argument answers this without asking.

## Step 2: Repository layout

The target, in every case — including the **default worktree**, named after the default branch, which every case must end with:

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

`worktree add --orphan` needs git ≥ 2.42; on older git, create the worktree after an empty initial commit instead (`git -C <repo-root> commit --allow-empty -m "initial commit"` via a temporary worktree is not possible on a bare repo — upgrade git or use `git -C <repo-root>/.bare commit-tree` plumbing only if the user insists; upgrading is the sane path).

### Clone from a URL

```bash
git clone --bare <url> <repo-root>/.bare
printf 'gitdir: ./.bare\n' > <repo-root>/.git
git -C <repo-root> config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
git -C <repo-root> fetch origin
```

The fetch-refspec line matters: bare clones get none, so `git fetch` silently updates nothing until it is set. Then resolve the default branch and create its worktree:

```bash
branch=$(git -C <repo-root> symbolic-ref --short HEAD)
git -C <repo-root> worktree add <repo-root>/$branch $branch
```

### Convert an existing conventional checkout

The delicate case: it restructures the repository in place, and **every path changes** — the working files move from `<repo-root>/` into `<repo-root>/<branch>/`, so open editors, terminal cwds, and IDE project configs all need re-pointing. Present the before/after layout and get explicit confirmation before touching anything.

Preconditions — stop and tell the user how to clear them, never work around:

- A clean tree: `git status --porcelain` shows no staged or unstaged changes (untracked files are fine — they are preserved below). Commit or stash first.
- No existing linked worktrees (`git worktree list` shows only the main checkout).
- No submodules (`.gitmodules` absent) — worktrees and submodules interact badly; a submodule repo needs a manual plan, not this recipe.

Procedure, from the checkout root:

1. Record the current branch and the untracked files (ignored ones included — these are the `.env`s and caches a fresh checkout would lose):

   ```bash
   branch=$(git symbolic-ref --short HEAD)
   git ls-files --others > /tmp/untracked-manifest
   ```

2. Convert the repository object store:

   ```bash
   mv .git .bare
   git --git-dir=.bare config core.bare true
   printf 'gitdir: ./.bare\n' > .git
   ```

3. Create the default worktree — a fresh checkout of the tracked files:

   ```bash
   git worktree add ./<branch> <branch>
   ```

4. Move every file in the untracked manifest into the worktree, preserving relative paths (`mkdir -p` the parents). This carries `.env` files, local caches, and anything else git never tracked.

5. Only now delete what remains at the top level besides `.bare`, `.git`, `<branch>`, and `.orca` (if present) — it is exactly the old tracked content, which the worktree now owns. Confirm with the user once more before this deletion, and verify first that `git -C <branch> status` looks sane and the untracked files arrived.

Nothing in this touches history, refs, remotes, or config beyond `core.bare` — the conversion is layout-only and reversible until step 5.

## Step 3: Verify

Re-run the pre-flight. `BARE_REPO` must now pass — that is this skill's deliverable. Report the machine lines too (`REVIEWER`, and `CODEX` as `PASS | FAIL | SKIPPED`): they cost nothing to relay, but a failing machine gate is fixed by **orca:doctor**, not here. Close by pointing at what comes next: `/orca:doctor` if a machine gate failed, then `/orca:feature` to capture a feature's intent and run it.

## Guidelines

- Every mutating action is announced and confirmed first; diagnosis is free.
- Never touch history, refs, or remotes. The conversion changes layout, not content.
- Layout only: never install tooling, write settings blocks, or change permission modes from here — that is orca:doctor's job, where each write has its own consent step.
- Stop rather than improvise on: a dirty tree, existing worktrees, submodules, or a repo whose layout is already bare-with-worktrees but differs from the target shape (report the difference instead).
- The default worktree is not optional: a bare store with no worktree strands the user, and orca:feature's deliverable — a branch to land — assumes they have a working copy to land it from.
