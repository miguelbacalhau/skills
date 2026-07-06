---
description: Set up a repository to satisfy orca:run's pre-flight — the bare-repo-with-worktrees layout with a default-branch worktree, plus the Codex CLI checks (installed, authenticated, and the MCP tool timeout set) for the cross-model reviewer. Use when the user wants to prepare a new repository, an existing conventional checkout, or a fresh clone for orca runs, or when orca:run's pre-flight failed and they want the gates fixed. Interactive and consent-per-step — it restructures repositories, so every mutating action is confirmed first. Do not use to write a brief or run a feature.
args: <path or clone URL, optional>
user-invocable: true
disable-model-invocation: true
---

# Orca: init

Make orca:run's pre-flight pass. The repository layout is fixed once per repo; the Codex tooling once per machine. The run skill itself refuses to do any of this autonomously — converting a repo and installing tools are the user's decisions — and this skill is where that decision gets made: invoking it is the consent, and each mutating step confirms once more before acting.

The temperament is the opposite of orca:run's: interactive throughout, consent per step, no autonomy. It runs once, so there is nothing to gain by not asking.

The subagent definitions and the codex MCP server registration are **not** this skill's job — both ship inside the orca plugin itself, so any session with the plugin has them.

## Step 1: Diagnose

If inside a git repository, run orca:run's pre-flight first — it is read-only and its gate lines are the work list:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/preflight.sh
```

Report the failing gates, then fix them in the order below. On `RESULT: PASS`, say so and stop — there is nothing to do.

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

## Step 3: Machine tooling

Fix only the gates the pre-flight flagged, each with consent:

- **Codex CLI** — orca's cross-model reviewer is the **global codex binary on PATH**, at or above the minimum version the pre-flight names. Codex is **never installed via npm** — no `npm i -g @openai/codex`, no vendored binary: if it is missing or too old, the user installs or upgrades it from the official non-npm distribution (`brew install codex`, or the GitHub release binaries). Authentication is interactive and must be the user's own action: suggest they run `! codex login` in this session, then re-check with `! codex login status`.
- **MCP tool timeout** — the reviewer runs through the codex MCP server the orca plugin bundles, but the timeout that governs MCP tool calls is a *client-side* env setting a plugin cannot ship: write `"MCP_TOOL_TIMEOUT": "1200000"` (~20 minutes) into the `env` block of `.claude/settings.local.json` (or the user's `~/.claude/settings.json`, their choice), merged into any existing file rather than overwriting. Not larger: the workflow retries reviews at two levels, so this value multiplies into the worst case per item; at ~20 minutes that worst case stays around 80 minutes, where 1 hour would balloon it to several hours. Caveat to state after writing: settings env loads at **session start** — a fresh session is needed before the value takes effect.

Optionally — offer, never default: for a repo where orca runs are always unattended, write `"permissions": { "defaultMode": "bypassPermissions" }` into `<repo-root>/<branch>/.claude/settings.local.json`. State the tradeoff plainly: it disables the approval gate for every session opened in that worktree, not just orca runs. Declining is fine — the mode can be toggled per session with Shift+Tab instead.

## Step 4: Verify

Re-run the pre-flight and require `RESULT: PASS`. Report what was changed, gate by gate, plus anything still pending on the user (a `codex login` not yet done, a session restart for the settings env). Close by pointing at the workflow the repo is now ready for: `/orca:brief` to capture a feature's intent, then `/orca:run` to run it.

## Guidelines

- Every mutating action is announced and confirmed first; diagnosis is free.
- Never touch history, refs, or remotes. The conversion changes layout, not content.
- Stop rather than improvise on: a dirty tree, existing worktrees, submodules, or a repo whose layout is already bare-with-worktrees but differs from the target shape (report the difference instead).
- The default worktree is not optional: a bare store with no worktree strands the user, and orca:run's deliverable — a branch to land — assumes they have a working copy to land it from.
