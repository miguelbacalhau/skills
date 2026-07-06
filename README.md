# orca

A [Claude Code](https://claude.com/claude-code) plugin for autonomous,
multi-agent feature development: capture intent as a brief, set the repository
up once, then let a deterministic workflow drive the feature from idea to a
committed integration branch.

## The workflow

Three skills take a feature from rough idea to a branch you land yourself:

1. **`/orca:brief <idea>`** — an interactive interview that sharpens a feature
   idea into a durable brief file (`.orca/briefs/<timestamp>-<slug>.md`):
   outcome, features, non-goals, constraints, doubt rule. Capturing intent is
   deliberately split from execution, so the conversation can take as many
   rounds as it needs.
2. **`/orca:init`** — one-time, consent-per-step setup that makes a repository
   pass the run's pre-flight: the bare-repo-with-worktrees layout (converting
   an existing checkout while preserving untracked files), plus the Codex CLI
   checks for the cross-model reviewer.
3. **`/orca:run`** — the autonomous run. It discovers the brief, confirms it
   once, writes a spec with a dependency-ordered work breakdown, then executes
   a deterministic work loop: each item is planned and implemented in its own
   git worktree, reviewed, fixed, committed, and serially merged into an
   integration branch that is finally verified against the spec. The
   deliverable is a `feature/<slug>` branch the user lands themselves.

(`/orca:run` is orca's feature run — not Claude Code's built-in `/run` skill,
which launches the project's app; the namespace keeps them apart.)

A fourth skill, **`/orca:config`**, is optional tuning: per-repository
overrides for which Claude model and reasoning effort each stage agent runs
with, written to `.orca/config.json` and picked up by the next run. Without
it, every stage uses the defaults from its agent definition.

Two design choices do most of the work:

- **Double isolation.** Every stage (spec, plan, implement, review, fix,
  commit, merge, integrate) runs in a dedicated subagent with its own context
  window, and every work item gets its own worktree off a shared bare
  repository. Parallel items can never corrupt each other's files — overlap
  surfaces as an explicit merge conflict, resolved by a merge agent holding
  both plans.
- **Cross-model review.** Claude implements; [Codex](https://openai.com/codex/)
  reviews. The plugin bundles an MCP registration for the global `codex`
  binary (`codex mcp-server`), and a dedicated review agent drives it
  adversarially over each item's diff before anything is committed — an
  independent second opinion from a different model family.

## Layout

| Path | Contents |
|------|----------|
| `.claude-plugin/plugin.json` | The plugin manifest (`orca`). |
| `.mcp.json` | Bundled codex MCP server — the global PATH `codex` binary, never npm. |
| `skills/brief/`, `skills/init/`, `skills/run/`, `skills/config/` | The four skills. `run/scripts/` holds the pre-flight and the Workflow-tool work loop. |
| `agents/` | The eight stage agents (`spec`, `plan`, `implement`, `review`, `fix`, `commit`, `merge`, `integrate`), namespaced as `orca:<stage>` when the plugin is loaded. |

## Install

For local development, load the checkout directly:

```bash
claude --plugin-dir /path/to/this/repo
```

Distribution through a plugin marketplace is the eventual install story; it is
not set up yet.

Requirements: the Codex CLI installed globally (never via npm — use
`brew install codex` or the release binaries) and authenticated
(`codex login`); a repository in the bare-with-worktrees layout, which
`/orca:init` sets up.

## Migrating from the pre-plugin skills

This repository previously shipped the same workflow as symlink-installed
skills named `briefify`/`initify`/`orchestrify` (plus a Codex CLI variant,
now scrapped). If you used those:

- Remove the old symlinks from `~/.claude/skills` and `~/.claude/agents`.
- Queued briefs migrate with `mv .orchestrify .orca` at the repo root.
- In-flight pre-migration runs cannot resume under the plugin — clean up any
  leftover `orchestrify-*` worktrees and start fresh from a new brief.
