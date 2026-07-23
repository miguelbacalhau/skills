# shellcheck shell=bash
#
# orca merge-finalize — one relay call for the whole post-merge-agent
# block: first-parent span attribution check, amend-vs-squash decision,
# `merge <ID>:` prefix enforcement, and the worktree/branch cleanup.
# Sourced by orca.sh; lib.sh is already loaded. Runs inside the
# caller's serialized merge section — an amend must never rewrite a
# commit a later merge builds on.
#
# Usage:
#   orca.sh merge-finalize <integration-wt> <tip-before> <id> \
#       --title-b64 <b64> --wt <worktree> --branch <branch>
#
# <tip-before> is the integration head read after the merge mutex was
# taken and before the merge agent ran — the caller captures it (that
# ordering is why this verb can never read it itself).
#
# Converge, don't replay: every decision observes current repo state.
#
#   attribution (only commits this merge created — first-parent, so the
#   item-branch commits merged in were already checked by commit-verify
#   and cannot be rewritten from here):
#     tip unmoved:                      attribution=unchanged
#     span clean:                       attribution=clean
#     banned on the tip only:           attribution=amended  (amend keeps
#                                       the merge parents intact)
#     banned below the tip (a post-merge fix commit sits on top): the
#       marker cannot be amended away — attribution=squashed (reset
#       --soft to <tip-before>, one clean commit: content and the
#       attribution guarantee kept, only the merge topology given up)
#
#   subject (the structural join key: audit finds an item's merge by the
#   `merge <ID>:` first-parent subject prefix — guaranteed here by the
#   deterministic layer, never by prompt compliance):
#     tip unmoved:                              subject=unchanged
#     merge subject carries the prefix:         subject=ok
#     tip IS the merge commit, same subject:    subject=amended (prefix
#       prepended, agent's wording and body kept)
#     otherwise (wrong-subject merge below later commits):
#       subject=squashed (same trade as the attribution fallback)
#
#   cleanup (idempotent, and NON-FATAL by contract: the item is already
#   merged, so a stray build artifact must never demote it to blocked —
#   a failure is reported in the frame with rc=0 intact):
#     remove the item worktree if present, prune stale registrations,
#     delete the item branch if present -> cleanup=done|failed
#
# The safe subject is composed HERE from the title and id (single-holder
# rule: it needs the banned regex, and lib.sh is the regex's one home):
# `merge <id>: <title>`, or `merge <id>: work item <id>` when the title
# trips the regex.
#
# Frame keys: rc, tip, attribution, subject, cleanup

mf_iwt=""
mf_tip_before=""
mf_id=""
mf_title_b64=""
mf_wt=""
mf_branch=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title-b64) mf_title_b64="${2:-}"; shift 2 || break ;;
    --wt)        mf_wt="${2:-}"; shift 2 || break ;;
    --branch)    mf_branch="${2:-}"; shift 2 || break ;;
    -*)          fail BAD_ARGS "unknown merge-finalize flag: $1" ;;
    *)
      if   [ -z "$mf_iwt" ];        then mf_iwt="$1"
      elif [ -z "$mf_tip_before" ]; then mf_tip_before="$1"
      elif [ -z "$mf_id" ];         then mf_id="$1"
      else fail BAD_ARGS "unexpected merge-finalize argument: $1"
      fi
      shift ;;
  esac
done
usage="usage: orca.sh merge-finalize <integration-wt> <tip-before> <id> --title-b64 <b64> --wt <worktree> --branch <branch>"
if [ -z "$mf_iwt" ] || [ -z "$mf_tip_before" ] || [ -z "$mf_id" ] || [ -z "$mf_title_b64" ] || [ -z "$mf_wt" ] || [ -z "$mf_branch" ]; then
  fail BAD_ARGS "$usage"
fi
[ -d "$mf_iwt" ] || fail BAD_ARGS "integration worktree is not a directory: $mf_iwt"
[[ $mf_tip_before =~ ^[0-9a-f]{40}$ ]] || fail BAD_ARGS "tip-before is not a 40-hex commit sha: $mf_tip_before"

mf_title="$(printf '%s' "$mf_title_b64" | tr -d '[:space:]' | b64_decode 2>/dev/null)" \
  || fail BAD_ARGS "--title-b64 does not decode as base64"

# The rewrite subject keeps the structural `merge <ID>:` prefix — the
# audit join key — even on the attribution fallback path.
mf_prefix="merge $mf_id:"
if is_banned "$mf_title"; then
  mf_safe="$mf_prefix work item $mf_id"
else
  mf_safe="$mf_prefix $mf_title"
fi

mf_head() {
  local sha
  sha="$(git -C "$mf_iwt" rev-parse HEAD)" || fail GIT_ERROR "could not read HEAD in $mf_iwt"
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || fail GIT_ERROR "HEAD of $mf_iwt is not a commit sha: $sha"
  printf '%s' "$sha"
}

mf_squash() { # <why> — reset the span behind the guaranteed safe subject
  if ! git -C "$mf_iwt" reset --soft "$mf_tip_before" \
    || ! git -C "$mf_iwt" commit -m "$mf_safe" >/dev/null; then
    fail GIT_ERROR "$1 squash failed in $mf_iwt"
  fi
}

mf_attribution=unchanged
mf_subject=unchanged
mf_now="$(mf_head)"

if [ "$mf_now" != "$mf_tip_before" ]; then
  mf_span="$(git -C "$mf_iwt" log --first-parent --format=%B "$mf_tip_before..HEAD")" \
    || fail GIT_ERROR "git log failed in $mf_iwt"
  if is_banned "$mf_span"; then
    mf_below="$(git -C "$mf_iwt" log --first-parent --skip=1 --format=%B "$mf_tip_before..HEAD")" \
      || fail GIT_ERROR "git log failed in $mf_iwt"
    if ! is_banned "$mf_below"; then
      git -C "$mf_iwt" commit --amend -m "$mf_safe" >/dev/null \
        || fail GIT_ERROR "attribution amend failed in $mf_iwt"
      mf_attribution=amended
    else
      mf_squash attribution
      mf_attribution=squashed
    fi
  else
    mf_attribution=clean
  fi

  # Read the tip fresh — the attribution backstop may just have
  # rewritten it. %P\t%s: everything up to the first tab is the parent
  # list, the rest the subject.
  mf_tip_line="$(git -C "$mf_iwt" log -1 --format='%P%x09%s')" \
    || fail GIT_ERROR "git log failed in $mf_iwt"
  mf_tab="$(printf '\t')"
  mf_tip_parents="${mf_tip_line%%"$mf_tab"*}"
  mf_tip_subj="${mf_tip_line#*"$mf_tab"}"
  mf_merge_subj="$(git -C "$mf_iwt" log --first-parent --merges --format=%s "$mf_tip_before..HEAD" | tail -1)" \
    || fail GIT_ERROR "git log failed in $mf_iwt"
  [ -z "$mf_merge_subj" ] && mf_merge_subj="$mf_tip_subj"
  case "$mf_merge_subj" in
    "$mf_prefix"*)
      mf_subject=ok
      ;;
    *)
      if [[ "$mf_tip_parents" == *" "* && "$mf_tip_subj" == "$mf_merge_subj" ]]; then
        # The merge commit is the tip: prepend the prefix, keep the
        # agent's wording and the body's run-level decision bullets.
        mf_tip_body="$(git -C "$mf_iwt" log -1 --format=%b)" \
          || fail GIT_ERROR "git log failed in $mf_iwt"
        if [ -n "$mf_tip_body" ]; then
          git -C "$mf_iwt" commit --amend -m "$mf_prefix $mf_merge_subj" -m "$mf_tip_body" >/dev/null \
            || fail GIT_ERROR "subject amend failed in $mf_iwt"
        else
          git -C "$mf_iwt" commit --amend -m "$mf_prefix $mf_merge_subj" >/dev/null \
            || fail GIT_ERROR "subject amend failed in $mf_iwt"
        fi
        mf_subject=amended
      else
        mf_squash subject
        mf_subject=squashed
      fi
      ;;
  esac
fi

# Cleanup — idempotent and best-effort: a retry after a completed
# cleanup finds nothing to remove and reports done.
mf_cleanup='done'
if [ -d "$mf_wt" ]; then
  git -C "$mf_iwt" worktree remove --force "$mf_wt" >/dev/null 2>&1 || mf_cleanup=failed
fi
git -C "$mf_iwt" worktree prune >/dev/null 2>&1 || true
if git -C "$mf_iwt" rev-parse -q --verify "refs/heads/$mf_branch" >/dev/null 2>&1; then
  git -C "$mf_iwt" branch -D "$mf_branch" >/dev/null 2>&1 || mf_cleanup=failed
fi

emit_frame rc=0 "tip=$(mf_head)" "attribution=$mf_attribution" "subject=$mf_subject" "cleanup=$mf_cleanup"
