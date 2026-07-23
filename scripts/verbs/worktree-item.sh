# shellcheck shell=bash disable=SC2154
#
# orca worktree-item — one relay call for the whole worktree-arrival
# ritual. Sourced by orca.sh with the verb arguments in place; lib.sh
# is already loaded.
#
# Usage:
#   orca.sh worktree-item <context-dir> <worktree> <branch> <base-ref>
#
# The three arrivals, in order:
#   - the directory survives from a previous run  -> reused (resume in place)
#   - the directory is gone but its branch survived a half-finished
#     cleanup -> worktree prune (drops a stale registration whose
#     directory was deleted by hand, which would otherwise fail the add
#     as "already checked out"), then re-add on that branch
#     -> branch_resumed
#   - a fresh item -> add with -b off <base-ref> -> created
#
# Idempotent by design: a re-run of any arrival lands in `reused`.
# Parallel items share one git dir, and a sibling's ref update can hold
# index.lock at exactly the wrong moment — one bounded retry on a
# lock-shaped failure, then a typed WORKTREE_FAILED.
#
# Every arrival chains secrets placement (idempotent — a resumed
# worktree's existing links are all-OK output); placement's typed lines
# pass through for the caller to log. The frame reports the worktree's
# head sha, which the caller holds as commit-verify's <base-sha> —
# valid only because implement/fix agents are forbidden to commit or
# stage, so HEAD cannot move between here and the commit stage.
#
# Frame keys: rc, arrival=reused|branch_resumed|created, head=<40-hex>

[ $# -eq 4 ] || fail BAD_ARGS "usage: orca.sh worktree-item <context-dir> <worktree> <branch> <base-ref>"
wti_ctx="$1"
wti_wt="$2"
wti_branch="$3"
wti_base="$4"
[ -d "$wti_ctx" ] || fail BAD_ARGS "context dir is not a directory: $wti_ctx"

wti_arrival=""
wti_arrive() {
  if [ -d "$wti_wt" ]; then
    wti_arrival=reused
    return 0
  fi
  if git -C "$wti_ctx" rev-parse -q --verify "refs/heads/$wti_branch" >/dev/null 2>&1; then
    git -C "$wti_ctx" worktree prune \
      && git -C "$wti_ctx" worktree add "$wti_wt" "$wti_branch" \
      || return 1
    wti_arrival=branch_resumed
    return 0
  fi
  git -C "$wti_ctx" worktree add "$wti_wt" -b "$wti_branch" "$wti_base" || return 1
  wti_arrival=created
}

wti_errlog="$(mktemp "${TMPDIR:-/tmp}/orca-wt.XXXXXX")" \
  || fail WORKTREE_FAILED "could not create a scratch file for git output"
if ! wti_arrive >"$wti_errlog" 2>&1; then
  if grep -qiE '\.lock|another git process' "$wti_errlog"; then
    sleep 1
    if ! wti_arrive >"$wti_errlog" 2>&1; then
      wti_detail="$(tr '\n' ' ' <"$wti_errlog" | tail -c 300)"
      rm -f "$wti_errlog"
      fail WORKTREE_FAILED "worktree arrival failed after a lock retry: $wti_detail"
    fi
  else
    wti_detail="$(tr '\n' ' ' <"$wti_errlog" | tail -c 300)"
    rm -f "$wti_errlog"
    fail WORKTREE_FAILED "worktree arrival failed: $wti_detail"
  fi
fi
rm -f "$wti_errlog"

# Placement's typed lines (LINKED/UNIGNORED/SKIPPED_*) pass through;
# its own misuse FAIL line is the typed failure, so no re-wrapping.
bash "$orca_scripts_dir/secrets.sh" place "$wti_wt" || exit 1

wti_head="$(git -C "$wti_wt" rev-parse HEAD)" \
  || fail GIT_ERROR "could not read HEAD in $wti_wt"
[[ $wti_head =~ ^[0-9a-f]{40}$ ]] \
  || fail GIT_ERROR "HEAD of $wti_wt is not a commit sha: $wti_head"

emit_frame rc=0 "arrival=$wti_arrival" "head=$wti_head"
