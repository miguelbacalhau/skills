# Plan: Convert the skills repo into the `orca` Claude Code plugin

Turn this repository from a two-implementation skills collection (symlink-installed
into `~/.claude/skills` and `~/.codex/skills`) into a single Claude Code **plugin**
named `orca`, scrapping the Codex CLI implementation while keeping the Codex-review
Claude agent, and rebranding everything from `orchestrify`/`briefify`/`initify` to
`orca`.

## Decisions (settled)

- **Plugin name:** `orca`.
- **Codex MCP reviewer:** bundled in the plugin's `.mcp.json`, registering the
  **global PATH `codex` binary** (`codex mcp-server`). Never npm — the hard rule
  stands. No more per-project registration by init.
- **Installers:** all four `install-*/uninstall-*` scripts are removed. Local dev
  install is `claude --plugin-dir .`; distribution later via a marketplace (out of
  scope for now).
- **Rename scope:** full rebrand — skills, agents, run-state directory, worktree
  prefixes, and all prose.
- **No compat shims:** no in-flight runs exist. Resume of pre-migration runs is
  explicitly broken; old repos migrate their brief queue with
  `mv .orchestrify .orca`.

## Naming map

| Old | New |
|---|---|
| `briefify` skill | `orca:brief` |
| `initify` skill | `orca:init` |
| `orchestrify` skill | `orca:run` |
| `orchestrify-spec` agent | `orca:spec` |
| `orchestrify-plan` agent | `orca:plan` |
| `orchestrify-implement` agent | `orca:implement` |
| `orchestrify-review` agent | `orca:review` |
| `orchestrify-fix` agent | `orca:fix` |
| `orchestrify-commit` agent | `orca:commit` |
| `orchestrify-merge` agent | `orca:merge` |
| `orchestrify-integrate` agent | `orca:integrate` |
| `.orchestrify/briefs/` run-state dir | `.orca/briefs/` |
| `<repoRoot>/orchestrify-<slug>` integration worktree | `<repoRoot>/orca-<slug>` |
| `<repoRoot>/orchestrify-<slug>-<ID>` item worktrees | `<repoRoot>/orca-<slug>-<ID>` |
| workflow `meta.name: 'orchestrify-work-loop'` | `'orca-work-loop'` |

Branch names are already neutral (`feature/<slug>`, `feature/<slug>-<ID>`) and do
not change.

`orca:run` vs the built-in `/run` skill: namespacing disambiguates the invocation;
the skill description must still make the distinction clear so the model never
confuses "launch the project's app" with "execute an orca run".

## Target layout

```
.claude-plugin/
└── plugin.json            # name: "orca", version, description, author
.mcp.json                  # codex MCP server — global binary, never npm
skills/
├── brief/SKILL.md
├── init/SKILL.md
└── run/
    ├── SKILL.md
    └── scripts/
        ├── preflight.sh
        └── work-loop.workflow.js
agents/
├── spec.md
├── plan.md
├── implement.md
├── review.md              # the kept Codex-review Claude agent
├── fix.md
├── commit.md
├── merge.md
└── integrate.md
README.md
plans/orca-plugin-migration.md   # this file
```

Plugin auto-discovery covers `skills/`, `agents/`, and `.mcp.json` at the plugin
root, so `plugin.json` needs no component-path fields. Only `plugin.json` lives
inside `.claude-plugin/`.

## Steps

### 1. Restructure into plugin form

- `git mv claude/briefify skills/brief`, `git mv claude/initify skills/init`,
  `git mv claude/orchestrify skills/run`.
- `git mv skills/run/agents/orchestrify-<stage>.md agents/<stage>.md` for all
  eight stages; remove the emptied `skills/run/agents/` and `claude/`.
- Update each agent's `name:` frontmatter to the bare stage name (`spec`, `plan`,
  …) — plugin namespacing supplies the `orca:` prefix.
- Update each skill's `name:` frontmatter (`brief`, `init`, `run`).
- Write `.claude-plugin/plugin.json`:
  ```json
  {
    "name": "orca",
    "version": "0.1.0",
    "description": "Autonomous multi-agent feature development: brief → init → run.",
    "author": { "name": "Miguel Bacalhau" }
  }
  ```

### 2. Scrap the Codex CLI implementation and the installers

- `git rm -r codex/`
- `git rm install-claude-skills.sh uninstall-claude-skills.sh install-codex-skills.sh uninstall-codex-skills.sh`
- **Kept:** `agents/review.md` — the Claude agent that drives the external Codex
  reviewer over MCP. It is the only surviving "codex" artifact.

### 3. Bundle the Codex MCP reviewer

New `.mcp.json` at the plugin root:

```json
{
  "mcpServers": {
    "codex": {
      "command": "codex",
      "args": ["mcp-server"]
    }
  }
}
```

- Registers wherever the plugin is active; removes init's per-project
  `.mcp.json` + `settings.local.json` writes.
- Verify during step 9 whether `MCP_TOOL_TIMEOUT` still needs to be set anywhere
  (plugin `settings.json` or an env block in the server entry) for long Codex
  reviews; carry it into the bundle if so.

### 4. Update the workflow script (`skills/run/scripts/work-loop.workflow.js`)

- The 7 `agentType:` strings become plugin-scoped bare names:
  `'orca:review'`, `'orca:plan'`, `'orca:implement'`, `'orca:fix'`,
  `'orca:commit'`, `'orca:merge'`, `'orca:integrate'`.
- `meta.name` → `'orca-work-loop'`.
- Worktree path templates → `${repoRoot}/orca-${slug}` and
  `${repoRoot}/orca-${slug}-${item.id}`.
- Sweep comments and any prompt text embedded in the script for the old names.

### 5. Update bundled-file path references

All `~/.claude/skills/orchestrify/scripts/...` references become
`${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/...` (the variable substitutes in
SKILL.md body text):

- `skills/run/SKILL.md`: the preflight invocation, the Workflow `scriptPath`
  instruction (keep the "resolve to absolute form" guidance — the substituted
  value is already absolute), and the "default install location" prose.
- `skills/init/SKILL.md` and `skills/brief/SKILL.md`: their preflight references.

### 6. Rework preflight (`skills/run/scripts/preflight.sh`)

- **Drop the AGENTS gate** entirely — agents ship inside the plugin; presence is
  guaranteed by installation.
- **Shrink the CODEX gate** to: `codex` on PATH, at/above minimum version,
  authenticated. The registration/enablement checks go away (bundled `.mcp.json`
  handles them). The live in-session check — ToolSearch resolving the codex MCP
  tool before launching the workflow — stays in `skills/run/SKILL.md`, and its
  remediation becomes "install the orca plugin / restart the session", not
  "run init".
- `BARE_REPO` gate and `TRUNK_CANDIDATE` line unchanged.
- Update the gate list and remediation prose in `skills/run/SKILL.md` to match.

### 7. Slim down `orca:init`

Its two removed duties: installing subagent definitions and registering the
per-project codex MCP server. What remains is its real job — the
bare-repo-with-worktrees conversion/setup (preserving untracked files), plus
checking codex is installed and authenticated. Rewrite its SKILL.md description
and steps accordingly.

### 8. Prose sweep — full rebrand

Every occurrence of `orchestrify`, `briefify`, `initify`, `$orchestrify`,
`$briefify`, `$initify`, `.orchestrify/`, and `orchestrify-` across:

- the three SKILL.md files (descriptions, bodies, cross-skill pointers),
- the eight agent files (frontmatter descriptions and bodies),
- the workflow script and preflight comments.

Details that must not be missed:

- `.orchestrify/briefs/` → `.orca/briefs/` everywhere (brief writes it, run
  discovers it).
- The resume/migration notes in `skills/run/SKILL.md` that describe old branch
  namespaces: simplify — pre-migration runs cannot resume under the new plugin;
  state that plainly instead of accreting another migration caveat.
- Skill descriptions keep their trigger quality: `orca:run` explicitly contrasts
  itself with the built-in `/run`.

### 9. Rewrite README

- Single-implementation plugin framing; drop the Codex CLI sections and the
  installer documentation.
- Document: local dev install `claude --plugin-dir .`; the three-skill usage flow
  `/orca:brief <idea>` → `/orca:init` (first time) → `/orca:run`; the cross-model
  review design (Claude implements, Codex reviews over MCP); the layout table.
- Note the marketplace as the future distribution path (not built now).

### 10. Verify

In a scratch bare-repo project with the plugin loaded via
`claude --plugin-dir /Users/miguel/development/skills`:

- All three skills appear, namespaced, and `/orca:brief` runs its interview.
- All eight agents resolve as `orca:<stage>` (spot-check with an Agent-tool call).
- The codex MCP tool resolves from the bundled `.mcp.json`
  (`ToolSearch select:mcp__codex__codex` — confirm the actual tool name a
  plugin-bundled server produces; if it gains a plugin prefix, update
  `agents/review.md` and the SKILL.md live-gate accordingly).
- `preflight.sh` runs from `${CLAUDE_PLUGIN_ROOT}` and its gates pass/fail
  correctly (test both a bare-with-worktrees layout and a conventional checkout).
- `rg -i 'orchestrify|briefify|initify'` over the repo returns nothing
  (except this plan file).

## Consequences / non-goals

- **Breaks resume** of any pre-migration in-flight run (none exist).
- Old repos keep `.orchestrify/` state; migrating queued briefs is a one-line
  `mv .orchestrify .orca` documented in the README.
- No marketplace.json yet; local `--plugin-dir` is the install story for now.

## Open items resolved during execution

- Exact invocation form for cross-skill mentions inside SKILL.md bodies —
  **resolved:** plugin skills register under their namespaced names
  (`orca:brief`, `orca:init`, `orca:run`), so bodies use `$orca:brief` /
  `$orca:run`.
- Plugin-bundled MCP tool naming — **resolved empirically:** the bundled
  server's tool is `mcp__plugin_orca_codex__codex` (pattern
  `mcp__plugin_<plugin>_<server>__<tool>`), confirmed via ToolSearch in a
  live `--plugin-dir` session; `agents/review.md` and the SKILL.md live gate
  use that name.
- Skill `name:` frontmatter — **step 1's instruction was wrong in practice:** a
  plugin skill with a `name:` field registers WITHOUT the plugin prefix
  (claude-code#22063, closed not-planned), which made the skills appear as
  bare `/brief`, `/init`, `/run` and let `/run` shadow the built-in. The
  `name:` fields are removed; the directory names (`brief`, `init`, `run`)
  supply the skill names and the picker shows `/orca:*`. Verified: after
  removal, `/orca:brief` loads and bare `/run` resolves to the built-in again.
- `MCP_TOOL_TIMEOUT` — **resolved: it cannot live in the bundle.** It is a
  client-side env setting read from a settings env block at session start; a
  plugin's `.mcp.json` env only reaches the server process. It therefore
  stays a settings write owned by `orca:init` (project or user settings),
  and the preflight CODEX gate keeps a check for it (the one deviation from
  the "shrink to three checks" wording in step 6).
