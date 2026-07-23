#!/usr/bin/env bats
# The relay verbs — worktree-item arrivals, commit-verify's decision
# table, merge-finalize's attribution/subject/cleanup, and the two
# re-entrancy classes per verb (run-twice after success, and
# mutation-applied-frame-lost-retry).

load helpers

orca() { bash "$SCRIPTS/orca.sh" "$@"; }

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# frame_get <key> — the key's value from the frame in $output.
frame_get() {
  printf '%s\n' "$output" | awk -v k="$1" '
    /^@@ORCA@@$/ { f = 1; next }
    /^@@ORCA_END@@$/ { f = 0 }
    f && index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'
}

frame_msg() { frame_get message.b64 | base64 --decode; }

# make_run_layout <dir> — bare layout plus an integration worktree at
# <dir>/int on feature/x, the shape the work loop runs in.
make_run_layout() {
  make_bare_layout "$1"
  git -C "$1/main" worktree add "$1/int" -b feature/x main >/dev/null 2>&1
}

# add_wt <dir> — item worktree at <dir>/wt1 via the verb itself; sets
# $base to the head sha its frame reported.
add_wt() {
  run orca worktree-item "$1/int" "$1/wt1" feature/x-W1 feature/x
  [ "$status" -eq 0 ]
  base="$(frame_get head)"
  [[ "$base" =~ ^[0-9a-f]{40}$ ]]
}

commit_in() { # <wt> <message>
  echo "change-$RANDOM" >>"$1/work.txt"
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
}

# ---- worktree-item -----------------------------------------------------

@test "worktree-item: fresh arrival creates branch and worktree, reports head" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  run orca worktree-item "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/wt1" feature/x-W1 feature/x
  [ "$status" -eq 0 ]
  has_line 'arrival=created'
  [ -d "$BATS_TEST_TMPDIR/r/wt1" ]
  git -C "$BATS_TEST_TMPDIR/r/int" rev-parse -q --verify refs/heads/feature/x-W1 >/dev/null
  [ "$(frame_get head)" = "$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-parse HEAD)" ]
}

@test "worktree-item: run-twice lands in reused with the same head" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  run orca worktree-item "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/wt1" feature/x-W1 feature/x
  [ "$status" -eq 0 ]
  has_line 'arrival=reused'
  [ "$(frame_get head)" = "$base" ]
}

@test "worktree-item: a hand-deleted directory resumes on its branch via prune" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" 'feat: survives the deletion'
  rm -rf "$BATS_TEST_TMPDIR/r/wt1"
  run orca worktree-item "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/wt1" feature/x-W1 feature/x
  [ "$status" -eq 0 ]
  has_line 'arrival=branch_resumed'
  [ "$(git -C "$BATS_TEST_TMPDIR/r/wt1" log -1 --format=%s)" = 'feat: survives the deletion' ]
}

@test "worktree-item: a persistent ref lock fails typed after the bounded retry" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  mkdir -p "$BATS_TEST_TMPDIR/r/.bare/refs/heads/feature"
  touch "$BATS_TEST_TMPDIR/r/.bare/refs/heads/feature/x-W9.lock"
  run orca worktree-item "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/wt9" feature/x-W9 feature/x
  assert_fail_reason WORKTREE_FAILED
}

@test "worktree-item: secrets placement rides the arrival" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/secrets"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run orca worktree-item "$BATS_TEST_TMPDIR/r/int" "$BATS_TEST_TMPDIR/r/wt1" feature/x-W1 feature/x
  [ "$status" -eq 0 ]
  has_line $'LINKED:\t.env'
  [ -L "$BATS_TEST_TMPDIR/r/wt1/.env" ]
}

# ---- commit-verify -----------------------------------------------------

@test "commit-verify: a clean new commit is accepted with hash and message" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" 'feat: adds a thing'
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'adds a thing')"
  [ "$status" -eq 0 ]
  has_line 'action=accepted'
  [ "$(frame_get hash)" = "$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-parse HEAD)" ]
  [ "$(frame_msg)" = 'feat: adds a thing' ]
}

@test "commit-verify: run-twice after accepted converges on the same verdict" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" 'feat: adds a thing'
  orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'adds a thing')" >/dev/null
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'adds a thing')"
  [ "$status" -eq 0 ]
  has_line 'action=accepted'
  [ "$(frame_msg)" = 'feat: adds a thing' ]
}

@test "commit-verify: a banned span resets soft and reports violation_reset" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" $'fix: a thing\n\nCo-Authored-By: Claude <noreply@example.com>'
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'a thing')"
  [ "$status" -eq 0 ]
  has_line 'action=violation_reset'
  # HEAD is back at base with the changes still staged
  [ "$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-parse HEAD)" = "$base" ]
  [ -n "$(git -C "$BATS_TEST_TMPDIR/r/wt1" status --porcelain)" ]
}

@test "commit-verify: the retry after a half-run violation_reset reports needs_commit" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" $'fix: a thing\n\nCo-Authored-By: Claude <noreply@example.com>'
  orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'a thing')" >/dev/null
  # the frame was lost; the retry observes reset-but-staged state
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'a thing')"
  [ "$status" -eq 0 ]
  has_line 'action=needs_commit'
}

@test "commit-verify: --final rewrites a still-banned span deterministically" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" $'fix: a thing\n\nGenerated with a tool'
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'a thing')" --final
  [ "$status" -eq 0 ]
  has_line 'action=fallback_rewritten'
  [ "$(frame_msg)" = 'chore: a thing' ]
  run git -C "$BATS_TEST_TMPDIR/r/wt1" log --format=%B "feature/x..HEAD"
  [[ "$output" != *Generated* ]]
}

@test "commit-verify: a banned title falls back to the id-based message" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" $'fix: x\n\nCo-Authored-By: Claude <noreply@example.com>'
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'teach Claude a trick')" --final
  [ "$status" -eq 0 ]
  has_line 'action=fallback_rewritten'
  [ "$(frame_msg)" = 'chore: complete work item W1' ]
}

@test "commit-verify: an unmoved wip tip is rewritten by amend" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" 'wip: W1 — blocked, partial work'
  base="$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-parse HEAD)"
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'a thing')"
  [ "$status" -eq 0 ]
  has_line 'action=wip_rewritten'
  [ "$(frame_msg)" = 'chore: a thing' ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/wt1" log -1 --format=%s)" = 'chore: a thing' ]
  # amend, not squash: only the tip was rewritten
  [ "$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-list --count feature/x..HEAD)" = '1' ]
}

@test "commit-verify: a prior-run banned span is squashed behind the fallback" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" 'feat: honest first half'
  commit_in "$BATS_TEST_TMPDIR/r/wt1" $'feat: second half\n\nCo-Authored-By: Claude <noreply@example.com>'
  base="$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-parse HEAD)"
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'a thing')"
  [ "$status" -eq 0 ]
  has_line 'action=prior_squashed'
  [ "$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-list --count feature/x..HEAD)" = '1' ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/wt1" log -1 --format=%s)" = 'chore: a thing' ]
}

@test "commit-verify: an unmoved clean non-wip tip is nothing-new accepted" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" 'feat: already committed last round'
  base="$(git -C "$BATS_TEST_TMPDIR/r/wt1" rev-parse HEAD)"
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'a thing')"
  [ "$status" -eq 0 ]
  has_line 'action=accepted'
  [ "$(frame_get hash)" = "$base" ]
  [ "$(frame_msg)" = 'feat: already committed last round' ]
}

@test "commit-verify: unicode survives the b64 round trip" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  commit_in "$BATS_TEST_TMPDIR/r/wt1" $'fix: café — naïve\n\nCo-Authored-By: Claude <noreply@example.com>'
  run orca commit-verify "$BATS_TEST_TMPDIR/r/wt1" "$base" W1 --branch feature/x --title-b64 "$(b64 'café — naïve')" --final
  [ "$status" -eq 0 ]
  [ "$(frame_msg)" = 'chore: café — naïve' ]
}

# ---- merge-finalize ----------------------------------------------------

# merged_layout <dir> <merge-message> — layout with one committed item
# branch merged --no-ff into feature/x under <merge-message>; sets
# $tip_before to the integration head before the merge.
merged_layout() {
  make_run_layout "$1"
  add_wt "$1"
  commit_in "$1/wt1" 'feat: adds a thing'
  tip_before="$(git -C "$1/int" rev-parse HEAD)"
  git -C "$1/int" merge --no-ff feature/x-W1 -m "$2" -q
}

@test "merge-finalize: a clean prefixed merge passes untouched and cleans up" {
  merged_layout "$BATS_TEST_TMPDIR/r" 'merge W1: adds a thing'
  run orca merge-finalize "$BATS_TEST_TMPDIR/r/int" "$tip_before" W1 \
    --title-b64 "$(b64 'adds a thing')" --wt "$BATS_TEST_TMPDIR/r/wt1" --branch feature/x-W1
  [ "$status" -eq 0 ]
  has_line 'attribution=clean'
  has_line 'subject=ok'
  has_line 'cleanup=done'
  [ ! -d "$BATS_TEST_TMPDIR/r/wt1" ]
  ! git -C "$BATS_TEST_TMPDIR/r/int" rev-parse -q --verify refs/heads/feature/x-W1 >/dev/null
}

@test "merge-finalize: a wrong merge subject gets the prefix prepended by amend" {
  merged_layout "$BATS_TEST_TMPDIR/r" "Merge branch 'feature/x-W1'"
  run orca merge-finalize "$BATS_TEST_TMPDIR/r/int" "$tip_before" W1 \
    --title-b64 "$(b64 'adds a thing')" --wt "$BATS_TEST_TMPDIR/r/wt1" --branch feature/x-W1
  [ "$status" -eq 0 ]
  has_line 'subject=amended'
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" log -1 --format=%s)" = "merge W1: Merge branch 'feature/x-W1'" ]
  # the merge parents survived the amend
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" log -1 --format=%P | wc -w | tr -d ' ')" = '2' ]
}

@test "merge-finalize: a banned tip alone is amended, merge topology kept" {
  merged_layout "$BATS_TEST_TMPDIR/r" $'merge W1: adds a thing\n\nCo-Authored-By: Claude <noreply@example.com>'
  run orca merge-finalize "$BATS_TEST_TMPDIR/r/int" "$tip_before" W1 \
    --title-b64 "$(b64 'adds a thing')" --wt "$BATS_TEST_TMPDIR/r/wt1" --branch feature/x-W1
  [ "$status" -eq 0 ]
  has_line 'attribution=amended'
  has_line 'subject=ok'
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" log -1 --format=%B "$tip_before..HEAD" | grep -c Claude)" = '0' ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" log -1 --format=%P | wc -w | tr -d ' ')" = '2' ]
}

@test "merge-finalize: a banned message below the tip squashes the span" {
  merged_layout "$BATS_TEST_TMPDIR/r" $'Merge item\n\nCo-Authored-By: Claude <noreply@example.com>'
  commit_in "$BATS_TEST_TMPDIR/r/int" 'fix: post-merge touchup'
  run orca merge-finalize "$BATS_TEST_TMPDIR/r/int" "$tip_before" W1 \
    --title-b64 "$(b64 'adds a thing')" --wt "$BATS_TEST_TMPDIR/r/wt1" --branch feature/x-W1
  [ "$status" -eq 0 ]
  has_line 'attribution=squashed'
  has_line 'subject=ok'
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" rev-list --count "$tip_before..HEAD")" = '1' ]
  [ "$(git -C "$BATS_TEST_TMPDIR/r/int" log -1 --format=%s)" = 'merge W1: adds a thing' ]
  run git -C "$BATS_TEST_TMPDIR/r/int" log --format=%B "$tip_before..HEAD"
  [[ "$output" != *Claude* ]]
}

@test "merge-finalize: an unmoved tip is unchanged/unchanged, cleanup still runs" {
  make_run_layout "$BATS_TEST_TMPDIR/r"
  add_wt "$BATS_TEST_TMPDIR/r"
  tip_before="$(git -C "$BATS_TEST_TMPDIR/r/int" rev-parse HEAD)"
  run orca merge-finalize "$BATS_TEST_TMPDIR/r/int" "$tip_before" W1 \
    --title-b64 "$(b64 'adds a thing')" --wt "$BATS_TEST_TMPDIR/r/wt1" --branch feature/x-W1
  [ "$status" -eq 0 ]
  has_line 'attribution=unchanged'
  has_line 'subject=unchanged'
  has_line 'cleanup=done'
  [ ! -d "$BATS_TEST_TMPDIR/r/wt1" ]
}

@test "merge-finalize: run-twice after a squash no-ops with cleanup already done" {
  merged_layout "$BATS_TEST_TMPDIR/r" $'Merge item\n\nCo-Authored-By: Claude <noreply@example.com>'
  commit_in "$BATS_TEST_TMPDIR/r/int" 'fix: post-merge touchup'
  orca merge-finalize "$BATS_TEST_TMPDIR/r/int" "$tip_before" W1 \
    --title-b64 "$(b64 'adds a thing')" --wt "$BATS_TEST_TMPDIR/r/wt1" --branch feature/x-W1 >/dev/null
  # the frame was lost; the retry observes the squashed span and the
  # finished cleanup, and converges instead of replaying
  run orca merge-finalize "$BATS_TEST_TMPDIR/r/int" "$tip_before" W1 \
    --title-b64 "$(b64 'adds a thing')" --wt "$BATS_TEST_TMPDIR/r/wt1" --branch feature/x-W1
  [ "$status" -eq 0 ]
  has_line 'attribution=clean'
  has_line 'subject=ok'
  has_line 'cleanup=done'
}

@test "verbs fail typed on bad arguments" {
  run orca commit-verify
  assert_fail_reason BAD_ARGS
  run orca merge-finalize /nonexistent 0000000000000000000000000000000000000000 W1 \
    --title-b64 "$(b64 t)" --wt /x --branch b
  assert_fail_reason BAD_ARGS
  make_run_layout "$BATS_TEST_TMPDIR/r"
  run orca commit-verify "$BATS_TEST_TMPDIR/r/int" not-a-sha W1 --branch feature/x --title-b64 "$(b64 t)"
  assert_fail_reason BAD_ARGS
}
