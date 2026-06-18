#!/usr/bin/env bash
#
# Run one independent Claude Code review and require a non-empty artifact.
#
# Usage: claude-review.sh <worktree> <output-file> <prompt-file>

set -uo pipefail

worktree="${1:-}"
output="${2:-}"
prompt_file="${3:-}"
timeout_secs="${CLAUDE_REVIEW_TIMEOUT:-900}"
run_dir="$(dirname "$(dirname "$output")")"

die() {
  echo "CLAUDE_REVIEW: FAILED $*"
  exit 1
}

[[ -n "$worktree" && -n "$output" && -n "$prompt_file" ]] \
  || die "usage: claude-review.sh <worktree> <output-file> <prompt-file>"
[[ -d "$worktree" ]] || die "worktree not found: $worktree"
[[ -s "$prompt_file" ]] || die "prompt file missing or empty: $prompt_file"
command -v claude >/dev/null 2>&1 || die "claude CLI not found"

tmo="$(command -v timeout || command -v gtimeout || true)"
[[ -n "$tmo" ]] || die "no timeout/gtimeout on PATH"

mkdir -p "$(dirname "$output")"

attempt() {
  : > "$output"
  (
    cd "$worktree" &&
      "$tmo" "$timeout_secs" claude \
        --print \
        --no-session-persistence \
        --permission-mode plan \
        --add-dir "$run_dir" \
        --tools "Bash,Read,Grep,Glob" \
        "$(cat "$prompt_file")" \
        > "$output" < /dev/null
  )
}

last_reason=""
review_ok() {
  attempt
  local rc=$?
  if [[ "$rc" -eq 0 && -s "$output" ]]; then
    return 0
  fi
  if [[ "$rc" -eq 124 ]]; then
    last_reason="timeout after ${timeout_secs}s"
  elif [[ "$rc" -ne 0 ]]; then
    last_reason="claude exited $rc"
  else
    last_reason="claude exited 0 but the review artifact is empty"
  fi
  return 1
}

if review_ok; then
  echo "CLAUDE_REVIEW: COMPLETED $output"
  exit 0
fi

echo "first review attempt failed: $last_reason — retrying once" >&2
if review_ok; then
  echo "CLAUDE_REVIEW: COMPLETED $output"
  exit 0
fi

die "Claude review did not complete after one retry ($last_reason)"
