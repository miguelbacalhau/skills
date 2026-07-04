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

# --- CODEX: the cross-model reviewer runs through the GLOBAL codex binary's ---
# --- MCP server, registered per project (initify writes the registration)  ---
# Codex is never installed via npm — the only supported codex is the system
# install on PATH (official non-npm distribution: Homebrew or the release
# binaries). The gate checks: binary on PATH at >= the minimum version that
# this skill's MCP usage was verified against, valid auth, the codex server
# registered in ./.mcp.json, that server enabled for the project, and the
# MCP_TOOL_TIMEOUT env knob set. The JSON checks are greps — necessary, not
# sufficient — and nothing here can check what is LOADED in the current
# session: MCP servers and settings env load at session start, so settings
# written minutes ago pass these gates while the session still lacks the
# tool. The live check (does the codex MCP tool resolve?) is SKILL.md Step
# 1's job, in the session itself.
scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
codex_min_version="0.142.5"
settings_files=("./.claude/settings.local.json" "./.claude/settings.json")
codex_fail() {
  echo "CODEX: FAIL: $1"
  fail=1
}
if ! command -v codex >/dev/null 2>&1; then
  codex_fail "codex not on PATH — install the Codex CLI from its official non-npm distribution (e.g. 'brew install codex'), never via npm"
else
  codex_version="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  oldest="$(printf '%s\n%s\n' "$codex_min_version" "${codex_version:-0}" | sort -V | head -1)"
  if [[ -z "$codex_version" || "$oldest" != "$codex_min_version" ]]; then
    codex_fail "codex ${codex_version:-unknown} < required $codex_min_version — upgrade the system codex (never via npm)"
  elif ! codex login status >/dev/null 2>&1 </dev/null; then
    codex_fail "not authenticated — run 'codex login'"
  elif [[ ! -f "./.mcp.json" ]] || ! grep -qE '"codex"[[:space:]]*:' "./.mcp.json"; then
    codex_fail "no codex server entry in ./.mcp.json — run initify to register the codex MCP server"
  else
    enabled=0
    timeout_set=0
    for sf in "${settings_files[@]}"; do
      [[ -f "$sf" ]] || continue
      flat="$(tr -d '\n' < "$sf")"
      if grep -qE '"enableAllProjectMcpServers"[[:space:]]*:[[:space:]]*true' <<<"$flat" ||
         grep -qE '"enabledMcpjsonServers"[[:space:]]*:[[:space:]]*\[[^]]*"codex"' <<<"$flat"; then
        enabled=1
      fi
      if grep -q '"MCP_TOOL_TIMEOUT"' <<<"$flat"; then
        timeout_set=1
      fi
    done
    if [[ "$enabled" -eq 0 ]]; then
      codex_fail "codex server not enabled — add \"codex\" to enabledMcpjsonServers in ./.claude/settings.local.json (initify writes this), then start a fresh session"
    elif [[ "$timeout_set" -eq 0 ]]; then
      codex_fail "MCP_TOOL_TIMEOUT not set in the settings env block — initify writes it (~20 minutes); reviews would be killed at the default tool timeout"
    else
      echo "CODEX: PASS"
    fi
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
