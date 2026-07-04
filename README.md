# Agent Skills

Skills for running autonomous, multi-agent feature development with AI coding
agents. The same workflow ships in two implementations — one for
[Claude Code](https://claude.com/claude-code) (`claude/`) and one for
[Codex](https://openai.com/codex/) (`codex/`) — so either CLI can drive it.

## The workflow

Three skills take a feature from rough idea to a committed integration branch:

1. **briefify** — an interactive interview that sharpens a feature idea into a
   durable brief file (`.orchestrify/briefs/<timestamp>-<slug>.md`): outcome,
   features, non-goals, constraints. Capturing intent is deliberately split
   from execution, so the conversation can take as many rounds as it needs.
2. **initify** — one-time, consent-per-step setup that makes a repository pass
   orchestrify's pre-flight: the bare-repo-with-worktrees layout, the
   cross-model reviewer CLI, GNU timeout, and the bundled subagent
   definitions.
3. **orchestrify** — the autonomous run. It discovers the brief, confirms it
   once, writes a spec with a dependency-ordered work breakdown, then executes
   a deterministic work loop: each item is planned and implemented in its own
   git worktree, reviewed, fixed, committed, and serially merged into an
   integration branch that is finally verified against the spec. The
   deliverable is a branch the user lands themselves.

Two design choices do most of the work:

- **Double isolation.** Every stage (spec, plan, implement, fix, commit,
  merge, integrate) runs in a dedicated subagent with its own context window,
  and every work item gets its own worktree off a shared bare repository.
  Parallel items can never corrupt each other's files — overlap surfaces as an
  explicit merge conflict, resolved by a merge agent holding both plans.
- **Cross-model review.** Each implementation is reviewed by the *other*
  model: Claude Code runs use Codex as the independent reviewer, and Codex
  runs use Claude — an unbiased second opinion before anything is committed.

## Repository layout

| Path | Contents |
|------|----------|
| `claude/` | Claude Code skills. `orchestrify/` bundles subagent definitions (`agents/*.md`) and scripts (pre-flight, Codex review, the Workflow-tool work loop). |
| `codex/` | Codex skills. `orchestrify/` bundles agent config (`agents/openai.yaml`) and per-stage reference prompts (`references/*.md`). |
| `install-*.sh` / `uninstall-*.sh` | Symlink installers for each implementation. |

## Install

Skills are installed as symlinks, so the checkout stays the source of truth
and edits take effect immediately.

### Claude Code

```bash
./install-claude-skills.sh
```

Links `claude/*` into `$HOME/.claude/skills`, and each skill's bundled
`agents/*.md` into `$HOME/.claude/agents` so the harness can load the
subagents. Use `--dry-run` to preview, `--target DIR` / `--agents-target DIR`
to install elsewhere, and `--force` to replace existing targets. Remove with:

```bash
./uninstall-claude-skills.sh
```

### Codex

```bash
./install-codex-skills.sh
```

Links `codex/*` into `${CODEX_HOME:-$HOME/.codex}/skills`. Same
`--dry-run` / `--target DIR` / `--force` options. Remove with:

```bash
./uninstall-codex-skills.sh
```

## Usage

In either CLI, from a repository you want to work on:

```
/briefify <idea>      # interview → brief file
/initify              # first time only: repo layout + tooling
/orchestrify          # autonomous run from the waiting brief
```

Orchestrify refuses to start without a brief and validates the repository
layout up front, so the skills naturally enforce their own ordering.
