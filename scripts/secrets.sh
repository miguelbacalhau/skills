#!/usr/bin/env bash
#
# orca secrets — the sole writer of the placement symlinks that carry
# <repo-root>/.orca/secrets/ into worktrees. `git worktree add` materializes
# tracked files only, and secrets are by definition untracked, so every
# worktree orca creates is born without its `.env`s; the loops and skills
# invoke this script directly after every `worktree add`, and never
# hand-roll the symlinks themselves.
#
# The tree is the mapping — no manifest, no config: a file's path inside
# .orca/secrets/ IS its destination path inside the worktree
# (.orca/secrets/apps/api/.env → <worktree>/apps/api/.env). Each placement
# is one RELATIVE symlink, depth computed per destination, so links survive
# the repo root moving — worktrees and .orca/ move together.
#
# Usage:
#   secrets.sh place <worktree>
#
# Output contract — one typed TAB-separated line per fact:
#
#   place (idempotent; a re-run over a placed worktree is all OK lines):
#     OK:<TAB>no secrets            no .orca/secrets/ (or nothing in it) — clean no-op
#     LINKED:<TAB><relpath>         new relative symlink created
#     RELINKED:<TAB><relpath>       our symlink was broken or wrong-depth — replaced
#     OK:<TAB><relpath>             already the expected link
#     UNIGNORED:<TAB><relpath>      git would track this path — never placed
#     SKIPPED_EXISTS:<TAB><relpath> a real file (or a foreign symlink) is there — never overwritten
#     SKIPPED_IRREGULAR:<TAB><relpath>  non-regular file inside secrets/ (stray symlink, socket)
#     SKIPPED_GONE:<TAB><relpath>   dangling link whose canonical file is gone — removed
#     SKIPPED_ERROR:<TAB><relpath>  the link could not be written (filesystem error)
#     PLACED:<TAB><n><TAB>SKIPPED:<TAB><m>    summary — n destinations correctly linked, m skipped
#
#   any subcommand:
#     FAIL:<TAB><reason><TAB><detail>    exit 1
#       reasons: BAD_ARGS NOT_GIT OUTSIDE_ROOT NO_PYTHON3
#
# Ownership is by RESOLVED target, never substring: a symlink is ours to
# manage (repair, replace, or sweep) only when resolving it lands on this
# repository's .orca/secrets tree at the same relative destination. A link
# into another repo's .orca/secrets, a backup.orca/secrets/x path, or any
# other look-alike is state — skipped in the walk, left alone by the sweep.
#
# Per-file problems are typed skips on a zero exit — placement is best
# effort and must never fail the caller's compound command; only misuse
# (bad args, not a worktree) exits 1. The UNIGNORED gate is the safety
# property: a path `git check-ignore` does not report ignored (tracked
# paths included — check-ignore consults the index) is a path a commit
# could pick up, so it never receives a secret.

set -uo pipefail

fail() { # <reason> <detail> — typed failure, exit 1
  printf 'FAIL:\t%s\t%s\n' "$1" "$2"
  exit 1
}

[[ "${1:-}" == "place" && $# -eq 2 ]] \
  || fail BAD_ARGS "usage: secrets.sh place <worktree>"
[[ -d "$2" ]] || fail BAD_ARGS "not a directory: $2"

# Normalize to the worktree's top level (a subdirectory argument would
# mis-root every destination) — this also rejects the bare layout's repo
# root, whose .git pointer resolves to the bare repo, not a working tree.
worktree="$(git -C "$2" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$worktree" ]] || fail NOT_GIT "$2 is not inside a git working tree"

# The repo root — the directory that holds .orca/ — is the parent of the
# git common dir in both layouts (bare-with-worktrees and conventional).
common_dir="$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[[ -n "$common_dir" ]] || fail NOT_GIT "$worktree is not inside a git repository"
repo_root="$(dirname "$common_dir")"
secrets_dir="$repo_root/.orca/secrets"

# Relative links are computed from the worktree's position under the repo
# root; a worktree elsewhere on disk has no stable relative path to .orca/.
if [[ "$worktree" == "$repo_root" ]]; then
  wt_rel=""
elif [[ "$worktree" == "$repo_root"/* ]]; then
  wt_rel="${worktree#"$repo_root"/}"
else
  fail OUTSIDE_ROOT "$worktree is not under the repo root $repo_root — relative links cannot be computed"
fi

# Canonical target of a symlink, existence NOT required (dangling links
# must still resolve so the sweep can judge them). python3 because realpath
# -m is not portable to macOS; the plugin already requires python3
# (config.sh's strict JSON handling).
command -v python3 >/dev/null 2>&1 \
  || fail NO_PYTHON3 "python3 not on PATH — required to resolve symlink ownership"
resolve_link() { # <link-path> — canonical absolute target on stdout
  python3 - "$1" <<'PY'
import os, sys
p = sys.argv[1]
t = os.readlink(p)
if not os.path.isabs(t):
    t = os.path.join(os.path.dirname(p), t)
print(os.path.realpath(t))
PY
}
# The canonical secrets root — the right-hand side of every ownership test.
secrets_canon="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$secrets_dir")"

# Escape glob metacharacters so a repo path containing [ ] * ? \ cannot
# corrupt find -path patterns.
escape_glob() { printf '%s' "$1" | sed 's/[][*?\\]/\\&/g'; }

# Component count of a relative path ("" → 0, "a/b/c" → 3).
depth_of() {
  local p="$1"
  [[ -z "$p" ]] && { echo 0; return; }
  local slashes="${p//[^\/]/}"
  echo $(( ${#slashes} + 1 ))
}
wt_depth="$(depth_of "$wt_rel")"

placed=0 skipped=0

# ---- walk the secrets tree: one relative symlink per regular file ----
if [[ -d "$secrets_dir" ]]; then
  while IFS= read -r -d '' src; do
    rel="${src#"$secrets_dir"/}"

    # Directories are traversed by find itself; anything that is not a
    # plain regular file (a symlink inside secrets/, a socket) is skipped.
    if [[ -L "$src" || ! -f "$src" ]]; then
      printf 'SKIPPED_IRREGULAR:\t%s\n' "$rel"
      skipped=$((skipped + 1))
      continue
    fi

    # The gate: a destination git would track must never hold a secret.
    # check-ignore consults the index, so a tracked path fails it too.
    if ! git -C "$worktree" check-ignore -q -- "$rel" 2>/dev/null; then
      printf 'UNIGNORED:\t%s\n' "$rel"
      skipped=$((skipped + 1))
      continue
    fi

    dest="$worktree/$rel"
    ups=""
    for (( i = wt_depth + $(depth_of "$rel") - 1; i > 0; i-- )); do ups+="../"; done
    target="${ups}.orca/secrets/$rel"

    if [[ -L "$dest" ]]; then
      cur="$(readlink "$dest" || true)"
      resolved="$(resolve_link "$dest" 2>/dev/null || true)"
      if [[ "$resolved" == "$secrets_canon/$rel" ]]; then
        # Ours (resolves to this repo's secrets file for this destination):
        # normalize a non-canonical spelling (absolute path, redundant
        # components); an already correct one is the idempotent re-run's OK.
        if [[ "$cur" == "$target" ]]; then
          printf 'OK:\t%s\n' "$rel"
          placed=$((placed + 1))
        elif rm -f "$dest" 2>/dev/null && ln -s "$target" "$dest" 2>/dev/null; then
          printf 'RELINKED:\t%s\n' "$rel"
          placed=$((placed + 1))
        else
          printf 'SKIPPED_ERROR:\t%s\n' "$rel"
          skipped=$((skipped + 1))
        fi
      else
        # A symlink that resolves anywhere else — another repo's secrets, a
        # look-alike path, a wrong destination — is somebody's state,
        # exactly like a real file. Never repaired, never replaced.
        printf 'SKIPPED_EXISTS:\t%s\n' "$rel"
        skipped=$((skipped + 1))
      fi
    elif [[ -e "$dest" ]]; then
      printf 'SKIPPED_EXISTS:\t%s\n' "$rel"
      skipped=$((skipped + 1))
    else
      # A parent holding only ignored files is not tracked, so it may not
      # exist in a fresh worktree.
      if mkdir -p "$(dirname "$dest")" 2>/dev/null && ln -s "$target" "$dest" 2>/dev/null; then
        printf 'LINKED:\t%s\n' "$rel"
        placed=$((placed + 1))
      else
        printf 'SKIPPED_ERROR:\t%s\n' "$rel"
        skipped=$((skipped + 1))
      fi
    fi
  done < <(find "$secrets_dir" -mindepth 1 ! -type d -print0 | LC_ALL=C sort -z)
fi

# ---- sweep: a dangling link whose canonical file is gone is a trap ----
# Runs after the walk, so a broken link whose source still exists was
# already repaired above and resolves here; what remains broken has no
# source to point at — remove it rather than leave a dead .env. Ownership
# is the resolved-target test: the dangling link must resolve to THIS
# repo's secrets tree at its own relative destination, or it is left
# alone (a link into another repo's .orca/secrets, or a backup.orca
# look-alike, is not ours to delete).
wt_glob="$(escape_glob "$worktree")"
while IFS= read -r -d '' lnk; do
  [[ -e "$lnk" ]] && continue
  rel="${lnk#"$worktree"/}"
  resolved="$(resolve_link "$lnk" 2>/dev/null || true)"
  [[ "$resolved" == "$secrets_canon/$rel" ]] || continue
  rm -f "$lnk" 2>/dev/null || true
  printf 'SKIPPED_GONE:\t%s\n' "$rel"
  skipped=$((skipped + 1))
done < <(find "$worktree" \( -name .git -o -path "$wt_glob/.orca" \) -prune -o -type l -print0 2>/dev/null | LC_ALL=C sort -z)

if (( placed == 0 && skipped == 0 )); then
  printf 'OK:\tno secrets\n'
  exit 0
fi
printf 'PLACED:\t%d\tSKIPPED:\t%d\n' "$placed" "$skipped"
exit 0
