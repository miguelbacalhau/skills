#!/usr/bin/env bash
#
# orchestrify pre-flight — read-only environment validation, run once during
# Step 1 before the brief is confirmed. Run from the project root.
#
# Checks the three mechanical gates and prints one machine-readable line each:
#   <KEY>: PASS
#   <KEY>: FAIL: <terse remediation>
# plus an informational TRUNK_CANDIDATE line and a final RESULT line.
#
# Does NOT check bypassPermissions mode — that is not observable from a shell
# and stays a conversational gate in SKILL.md.
#
# Exit 0 iff every gate passes; non-zero if any gate fails. No side effects.

set -uo pipefail

fail=0

# --- BARE_REPO: the run requires a bare repo with worktrees, no main checkout ---
common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [[ -z "$common_dir" ]]; then
  echo "BARE_REPO: FAIL: not inside a git repository"
  fail=1
else
  is_bare="$(git --git-dir="$common_dir" rev-parse --is-bare-repository 2>/dev/null || true)"
  if [[ "$is_bare" == "true" ]]; then
    echo "BARE_REPO: PASS"
  else
    echo "BARE_REPO: FAIL: conventional checkout, not bare-with-worktrees (see SKILL.md conversion recipe)"
    fail=1
  fi

  # Informational: the bare repo's HEAD names the default branch — a trunk candidate.
  trunk="$(git --git-dir="$common_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  echo "TRUNK_CANDIDATE: ${trunk:-unknown}"
fi

# --- CODEX: the cross-model reviewer used by stage 4c runs on the Codex SDK ---
# The script is documented as "run from the project root", so it locates its own
# scripts/ directory from $BASH_SOURCE (pwd -P resolves the install symlink),
# never from the cwd. The SDK vendors a codex binary into node_modules, so auth
# is checked against that one; a global codex is only a fallback.
scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
node_major=""
if command -v node >/dev/null 2>&1; then
  node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
fi
if [[ -z "$node_major" || "$node_major" -lt 18 ]]; then
  echo "CODEX: FAIL: node >= 18 required for the Codex SDK review runner"
  fail=1
elif [[ ! -d "$scripts_dir/node_modules/@openai/codex-sdk" ]]; then
  echo "CODEX: FAIL: Codex SDK not installed — run 'npm install' in $scripts_dir (or rerun initify)"
  fail=1
else
  codex_bin="$scripts_dir/node_modules/.bin/codex"
  [[ -x "$codex_bin" ]] || codex_bin="$(command -v codex || true)"
  if [[ -z "$codex_bin" ]] || ! "$codex_bin" login status >/dev/null 2>&1 </dev/null; then
    echo "CODEX: FAIL: not authenticated — run '$scripts_dir/node_modules/.bin/codex login'"
    fail=1
  else
    echo "CODEX: PASS"
  fi
fi

# --- AGENTS: every subagent definition bundled with this skill must be installed ---
# Enumerate the skill's own agents/ directory rather than a hardcoded name
# list: a list here goes stale the moment an agent is added or renamed, and a
# stale PASS fails deep inside the work loop instead of at the gate.
agents_src="$scripts_dir/../agents"
missing=""
found_any=0
for def in "$agents_src"/*.md; do
  [[ -e "$def" ]] || continue
  found_any=1
  agent_md="$(basename "$def")"
  if [[ ! -e "$HOME/.claude/agents/$agent_md" && ! -e "./.claude/agents/$agent_md" ]]; then
    missing="$missing ${agent_md%.md}"
  fi
done
if [[ "$found_any" -eq 0 ]]; then
  echo "AGENTS: FAIL: no agent definitions found at $agents_src — reinstall the skill"
  fail=1
elif [[ -n "$missing" ]]; then
  echo "AGENTS: FAIL: missing definitions:$missing — re-run install-claude-skills.sh"
  fail=1
else
  echo "AGENTS: PASS"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
fi
exit "$fail"
