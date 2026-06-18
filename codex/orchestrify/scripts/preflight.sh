#!/usr/bin/env bash
#
# Read-only mechanical checks for Codex orchestrify.

set -uo pipefail

fail=0

if ! command -v git >/dev/null 2>&1; then
  echo "GIT: FAIL: git is not installed"
  echo "RESULT: FAIL"
  exit 1
fi

if git worktree list >/dev/null 2>&1; then
  echo "GIT: PASS"
else
  echo "GIT: FAIL: current git does not support worktree operations"
  fail=1
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "CLAUDE: FAIL: claude CLI not found"
  fail=1
elif ! claude auth status --text >/dev/null 2>&1 </dev/null; then
  echo "CLAUDE: FAIL: not authenticated — run 'claude auth login'"
  fail=1
else
  echo "CLAUDE: PASS"
fi

if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  echo "TIMEOUT: PASS"
else
  echo "TIMEOUT: FAIL: no timeout/gtimeout — install GNU coreutils"
  fail=1
fi

common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [[ -z "$common_dir" ]]; then
  echo "BARE_REPO: FAIL: not inside a git repository"
  echo "TRUNK_CANDIDATE: unknown"
  fail=1
else
  is_bare="$(git --git-dir="$common_dir" rev-parse --is-bare-repository 2>/dev/null || true)"
  if [[ "$is_bare" == "true" ]]; then
    echo "BARE_REPO: PASS"
  else
    echo "BARE_REPO: FAIL: conventional checkout, not bare-with-worktrees"
    fail=1
  fi

  trunk="$(git --git-dir="$common_dir" symbolic-ref --short HEAD 2>/dev/null || true)"
  echo "TRUNK_CANDIDATE: ${trunk:-unknown}"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
fi

exit "$fail"
