#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./install-claude-skills.sh [options]

Symlink all skills from ./claude into the Claude skills directory.

A skill may bundle subagent definitions in an `agents/` subdirectory
(e.g. claude/orchestrify/agents/*.md). Those files are also symlinked
into the Claude agents directory so the harness can load them.

A skill may also declare script dependencies in `scripts/package.json`
(e.g. claude/orchestrify/scripts). Those are installed with `npm install`
so the linked skill works without a separate setup step; node_modules
lands in the repo, and the directory-level skill symlink means the
installed skill resolves it too.

Options:
  --target DIR          Install skill links into DIR instead of $HOME/.claude/skills
  --agents-target DIR   Install agent links into DIR instead of $HOME/.claude/agents
  --force               Replace existing targets that are not the desired symlink
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
force=false
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
    --force)
      force=true
      shift
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

shopt -s nullglob
skill_dirs=("$source_dir"/*)

if [[ ${#skill_dirs[@]} -eq 0 ]]; then
  echo "error: no skills found in $source_dir" >&2
  exit 1
fi

run mkdir -p "$target_dir"

for skill_dir in "${skill_dirs[@]}"; do
  [[ -d "$skill_dir" ]] || continue

  skill_name="$(basename "$skill_dir")"
  link_path="$target_dir/$skill_name"

  if same_link_target "$link_path" "$skill_dir"; then
    echo "ok: $skill_name already linked"
    continue
  fi

  if [[ -e "$link_path" || -L "$link_path" ]]; then
    if [[ "$force" != true ]]; then
      echo "skip: $link_path already exists; rerun with --force to replace it" >&2
      continue
    fi

    run rm -rf "$link_path"
  fi

  run ln -s "$skill_dir" "$link_path"
  if [[ "$dry_run" == true ]]; then
    echo "would link: $link_path -> $skill_dir"
  else
    echo "linked: $link_path -> $skill_dir"
  fi
done

# Link any bundled subagent definitions (claude/<skill>/agents/*.md) into the
# Claude agents directory. Runs as its own pass so skills that were already
# linked above still get their agents installed.
agent_files=("$source_dir"/*/agents/*.md)

if [[ ${#agent_files[@]} -gt 0 ]]; then
  run mkdir -p "$agents_target_dir"

  for agent_file in "${agent_files[@]}"; do
    [[ -f "$agent_file" ]] || continue

    agent_name="$(basename "$agent_file")"
    agent_link="$agents_target_dir/$agent_name"

    if same_link_target "$agent_link" "$agent_file"; then
      echo "ok: agent $agent_name already linked"
      continue
    fi

    if [[ -e "$agent_link" || -L "$agent_link" ]]; then
      if [[ "$force" != true ]]; then
        echo "skip: $agent_link already exists; rerun with --force to replace it" >&2
        continue
      fi

      run rm -rf "$agent_link"
    fi

    run ln -s "$agent_file" "$agent_link"
    if [[ "$dry_run" == true ]]; then
      echo "would link agent: $agent_link -> $agent_file"
    else
      echo "linked agent: $agent_link -> $agent_file"
    fi
  done
fi

# Install any bundled script dependencies (claude/<skill>/scripts/package.json).
# Runs as its own pass so skills that were already linked above still get their
# dependencies. A failure here must not roll back the linking that already
# happened — it is reported and reflected in the exit code instead.
deps_failed=0
for pkg in "$source_dir"/*/scripts/package.json; do
  [[ -f "$pkg" ]] || continue

  scripts_dir="$(dirname "$pkg")"

  if ! command -v npm >/dev/null 2>&1; then
    echo "warn: npm not found — install Node >= 18, then run: npm install --prefix $scripts_dir" >&2
    deps_failed=1
    continue
  fi

  if [[ "$dry_run" == true ]]; then
    echo "would install dependencies: $scripts_dir"
    continue
  fi

  if (cd "$scripts_dir" && npm install --no-fund --no-audit --loglevel=error); then
    echo "installed dependencies: $scripts_dir"
  else
    echo "warn: npm install failed in $scripts_dir — its skill's scripts will not run until it succeeds" >&2
    deps_failed=1
  fi
done

exit "$deps_failed"
