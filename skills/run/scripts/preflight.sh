#!/usr/bin/env bash
#
# orca pre-flight — read-only environment validation, run once during
# Step 1 before the brief is confirmed. Run from the project root.
#
# Checks the two mechanical gates and prints one machine-readable line each:
#   <KEY>: PASS
#   <KEY>: FAIL: <terse remediation>
# plus an informational TRUNK_CANDIDATE line and a final RESULT line.
#
# No AGENTS gate and no MCP-registration checks: the subagent definitions
# and the codex MCP server registration ship inside the orca plugin, so a
# session that can run this skill has them by construction. What only the
# live session can check — the codex MCP tool actually resolving — is
# SKILL.md Step 1's job.
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
    echo "BARE_REPO: FAIL: conventional checkout, not bare-with-worktrees (run orca:init to convert)"
    fail=1
  fi

  # Informational: the bare repo's HEAD names the default branch — a trunk candidate.
  trunk="$(git --git-dir="$common_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  echo "TRUNK_CANDIDATE: ${trunk:-unknown}"
fi

# --- CODEX: the cross-model reviewer is the GLOBAL codex binary's MCP server, ---
# --- registered by the plugin's bundled .mcp.json                             ---
# Codex is never installed via npm — the only supported codex is the system
# install on PATH (official non-npm distribution: Homebrew or the release
# binaries). The gate checks: binary on PATH at >= the minimum version this
# skill's MCP usage was verified against, valid auth, and the MCP_TOOL_TIMEOUT
# env knob. The timeout check survives the plugin migration because it is a
# CLIENT-side setting: the plugin's .mcp.json registers the server, but a
# plugin cannot set the session env that governs MCP tool-call timeouts, so
# it still lives in a settings env block (project or user) that orca:init
# writes. Nothing here can check what is LOADED in the current session —
# the live check (does the codex MCP tool resolve?) is SKILL.md Step 1's
# job, in the session itself.
codex_min_version="0.142.5"
settings_files=("./.claude/settings.local.json" "./.claude/settings.json" "$HOME/.claude/settings.json")
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
  else
    timeout_set=0
    for sf in "${settings_files[@]}"; do
      [[ -f "$sf" ]] || continue
      if grep -q '"MCP_TOOL_TIMEOUT"' "$sf"; then
        timeout_set=1
      fi
    done
    if [[ "$timeout_set" -eq 0 ]]; then
      codex_fail "MCP_TOOL_TIMEOUT not set in a settings env block — orca:init writes it (~20 minutes); reviews would be killed at the default tool timeout"
    else
      echo "CODEX: PASS"
    fi
  fi
fi

if [[ "$fail" -eq 0 ]]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
fi
exit "$fail"
