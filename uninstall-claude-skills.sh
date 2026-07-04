#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./uninstall-claude-skills.sh [options]

Remove symlinks for this repo's ./claude skills from the Claude skills directory,
along with any bundled subagent definitions installed into the Claude agents directory.

Options:
  --target DIR          Remove skill links from DIR instead of $HOME/.claude/skills
  --agents-target DIR   Remove agent links from DIR instead of $HOME/.claude/agents
  --dry-run             Print actions without changing the filesystem
  -h, --help            Show this help
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$script_dir/claude" ]]; then
  repo_root="$script_dir"
elif [[ -d "$script_dir/../claude" ]]; then
  repo_root="$(cd "$script_dir/.." && pwd)"
else
  repo_root="$script_dir"
fi

source_dir="$repo_root/claude"
target_dir="$HOME/.claude/skills"
agents_target_dir="$HOME/.claude/agents"
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      if [[ $# -lt 2 ]]; then
        echo "error: --target requires a directory" >&2
        exit 2
      fi
      target_dir="$2"
      shift 2
      ;;
    --agents-target)
      if [[ $# -lt 2 ]]; then
        echo "error: --agents-target requires a directory" >&2
        exit 2
      fi
      agents_target_dir="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

run() {
  if [[ "$dry_run" == true ]]; then
    printf 'dry-run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

same_link_target() {
  local link_path="$1"
  local expected_target="$2"

  [[ -L "$link_path" ]] || return 1
  [[ "$(readlink "$link_path")" == "$expected_target" ]]
}

if [[ ! -d "$source_dir" ]]; then
  echo "error: source directory not found: $source_dir" >&2
  echo "hint: run this script from the skills repo, or keep it next to the claude/ directory" >&2
  exit 1
fi

if [[ ! -d "$target_dir" && ! -d "$agents_target_dir" ]]; then
  echo "ok: target directories do not exist"
  exit 0
fi

shopt -s nullglob
skill_dirs=("$source_dir"/*)

if [[ ${#skill_dirs[@]} -eq 0 ]]; then
  echo "error: no skills found in $source_dir" >&2
  exit 1
fi

removed_count=0

for skill_dir in "${skill_dirs[@]}"; do
  [[ -d "$skill_dir" ]] || continue

  skill_name="$(basename "$skill_dir")"
  link_path="$target_dir/$skill_name"

  if same_link_target "$link_path" "$skill_dir"; then
    run rm "$link_path"
    removed_count=$((removed_count + 1))
    if [[ "$dry_run" == true ]]; then
      echo "would remove: $link_path"
    else
      echo "removed: $link_path"
    fi
    continue
  fi

  if [[ -e "$link_path" || -L "$link_path" ]]; then
    echo "skip: $link_path does not point to $skill_dir" >&2
  else
    echo "ok: $skill_name is not installed"
  fi
done

# Remove any bundled subagent links this repo installed into the agents directory.
agent_files=("$source_dir"/*/agents/*.md)

for agent_file in "${agent_files[@]}"; do
  [[ -f "$agent_file" ]] || continue

  agent_name="$(basename "$agent_file")"
  agent_link="$agents_target_dir/$agent_name"

  if same_link_target "$agent_link" "$agent_file"; then
    run rm "$agent_link"
    removed_count=$((removed_count + 1))
    if [[ "$dry_run" == true ]]; then
      echo "would remove agent: $agent_link"
    else
      echo "removed agent: $agent_link"
    fi
    continue
  fi

  if [[ -e "$agent_link" || -L "$agent_link" ]]; then
    echo "skip: $agent_link does not point to $agent_file" >&2
  else
    echo "ok: agent $agent_name is not installed"
  fi
done

# Sweep dangling links that still point into this repo: a skill or agent
# removed from the repo is no longer enumerated by the loops above, but its
# leftover symlink still claims the name in the target directory.
sweep_dangling() {
  local dir="$1"
  local kind="$2"
  local link_path link_target

  [[ -d "$dir" ]] || return 0

  for link_path in "$dir"/*; do
    [[ -L "$link_path" ]] || continue
    link_target="$(readlink "$link_path")"
    [[ "$link_target" == "$source_dir"/* ]] || continue
    [[ -e "$link_path" ]] && continue

    run rm "$link_path"
    removed_count=$((removed_count + 1))
    if [[ "$dry_run" == true ]]; then
      echo "would remove dangling $kind: $link_path"
    else
      echo "removed dangling $kind: $link_path"
    fi
  done
}

sweep_dangling "$target_dir" "skill link"
sweep_dangling "$agents_target_dir" "agent link"

if [[ "$removed_count" -eq 0 ]]; then
  echo "ok: no matching links removed"
fi
