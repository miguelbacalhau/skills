#!/usr/bin/env bats
# secrets.sh — placement gates, idempotency, dangling-link sweep boundaries.

load helpers

# Every invocation runs with python3 poisoned: symlink-ownership
# resolution is the lib's pure-bash canonicalizer now, and any python3
# call is an envelope regression — the stub makes it a loud failure
# instead of a silent dependency.
secrets() {
  local stub="$BATS_TEST_TMPDIR/no-python-bin"
  if [ ! -x "$stub/python3" ]; then
    mkdir -p "$stub"
    printf '#!/bin/sh\necho "python3 called — the orca envelope forbids it" >&2\nexit 127\n' >"$stub/python3"
    chmod +x "$stub/python3"
  fi
  PATH="$stub:$PATH" bash "$SCRIPTS/secrets.sh" "$@"
}

# make_bare_layout comes from helpers.bash; these tests add the secrets
# tree on top.
make_secrets_layout() { # <dir>
  make_bare_layout "$1"
  mkdir -p "$1/.orca/secrets"
}

@test "no secrets dir is a clean no-op" {
  make_repo "$BATS_TEST_TMPDIR/r"
  run secrets place "$BATS_TEST_TMPDIR/r"
  [ "$status" -eq 0 ]
  has_line $'OK:\tno secrets'
}

@test "places a relative symlink for an ignored destination" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'LINKED:\t.env'
  [ -L "$BATS_TEST_TMPDIR/r/main/.env" ]
  [ "$(readlink "$BATS_TEST_TMPDIR/r/main/.env")" = "../.orca/secrets/.env" ]
  [ "$(cat "$BATS_TEST_TMPDIR/r/main/.env")" = "SECRET=1" ]
}

@test "nested secret gets a depth-correct relative link" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  ( cd "$BATS_TEST_TMPDIR/r/main" &&
    mkdir -p apps/api && echo '.env' >apps/api/.gitignore &&
    git add apps/api/.gitignore && git commit -qm nested )
  mkdir -p "$BATS_TEST_TMPDIR/r/.orca/secrets/apps/api"
  echo 'K=v' >"$BATS_TEST_TMPDIR/r/.orca/secrets/apps/api/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'LINKED:\tapps/api/.env'
  [ "$(readlink "$BATS_TEST_TMPDIR/r/main/apps/api/.env")" = "../../../.orca/secrets/apps/api/.env" ]
  [ "$(cat "$BATS_TEST_TMPDIR/r/main/apps/api/.env")" = "K=v" ]
}

@test "unignored destination never receives a secret" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'x' >"$BATS_TEST_TMPDIR/r/.orca/secrets/not-ignored.txt"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'UNIGNORED:\tnot-ignored.txt'
  [ ! -e "$BATS_TEST_TMPDIR/r/main/not-ignored.txt" ]
}

@test "re-run over a placed worktree is idempotent OK" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  secrets place "$BATS_TEST_TMPDIR/r/main" >/dev/null
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'OK:\t.env'
  refute_line 'LINKED:'
  refute_line 'RELINKED:'
}

@test "a real file at the destination is never overwritten" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  echo 'mine' >"$BATS_TEST_TMPDIR/r/main/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_EXISTS:\t.env'
  [ "$(cat "$BATS_TEST_TMPDIR/r/main/.env")" = "mine" ]
}

@test "a symlink inside secrets/ is skipped as irregular" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  ln -s /etc/hostname "$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_IRREGULAR:\t.env'
  [ ! -e "$BATS_TEST_TMPDIR/r/main/.env" ]
}

@test "dangling secrets link whose source is gone is swept" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  secrets place "$BATS_TEST_TMPDIR/r/main" >/dev/null
  rm "$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_GONE:\t.env'
  [ ! -L "$BATS_TEST_TMPDIR/r/main/.env" ]
}

@test "sweep leaves dangling links that are not secrets placements alone" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  ln -s /nonexistent-target "$BATS_TEST_TMPDIR/r/main/dead-link"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  [ -L "$BATS_TEST_TMPDIR/r/main/dead-link" ]
}

@test "sweep does not descend into .git or .orca" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  # a conventional-layout repo whose root holds .orca — the prune must
  # protect links under it
  make_repo "$BATS_TEST_TMPDIR/c"
  mkdir -p "$BATS_TEST_TMPDIR/c/.orca/secrets"
  ln -s /gone "$BATS_TEST_TMPDIR/c/.orca/keep-me"
  ln -s /gone "$BATS_TEST_TMPDIR/c/.git/keep-me-too"
  run secrets place "$BATS_TEST_TMPDIR/c"
  [ "$status" -eq 0 ]
  [ -L "$BATS_TEST_TMPDIR/c/.orca/keep-me" ]
  [ -L "$BATS_TEST_TMPDIR/c/.git/keep-me-too" ]
}

@test "a link into another repo's secrets tree is never repaired or replaced" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  make_secrets_layout "$BATS_TEST_TMPDIR/other"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  echo 'FOREIGN=1' >"$BATS_TEST_TMPDIR/other/.orca/secrets/.env"
  ln -s "$BATS_TEST_TMPDIR/other/.orca/secrets/.env" "$BATS_TEST_TMPDIR/r/main/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_EXISTS:\t.env'
  [ "$(readlink "$BATS_TEST_TMPDIR/r/main/.env")" = "$BATS_TEST_TMPDIR/other/.orca/secrets/.env" ]
}

@test "sweep leaves a dangling link into another repo's secrets alone" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  ln -s "$BATS_TEST_TMPDIR/gone-repo/.orca/secrets/.env" "$BATS_TEST_TMPDIR/r/main/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  refute_line 'SKIPPED_GONE:'
  [ -L "$BATS_TEST_TMPDIR/r/main/.env" ]
}

@test "sweep leaves a backup.orca look-alike path alone" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  # the old substring test (*.orca/secrets/*) matched this and deleted it
  ln -s "$BATS_TEST_TMPDIR/backup.orca/secrets/x" "$BATS_TEST_TMPDIR/r/main/x"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  refute_line 'SKIPPED_GONE:'
  [ -L "$BATS_TEST_TMPDIR/r/main/x" ]
}

@test "an absolute link to the exact right secret is normalized, not skipped" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  ln -s "$BATS_TEST_TMPDIR/r/.orca/secrets/.env" "$BATS_TEST_TMPDIR/r/main/.env"
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'RELINKED:\t.env'
  [ "$(readlink "$BATS_TEST_TMPDIR/r/main/.env")" = "../.orca/secrets/.env" ]
}

@test "a repo path containing glob metacharacters still sweeps correctly" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r[1]"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r[1]/.orca/secrets/.env"
  secrets place "$BATS_TEST_TMPDIR/r[1]/main" >/dev/null
  rm "$BATS_TEST_TMPDIR/r[1]/.orca/secrets/.env"
  # a protected link under .orca must survive the sweep despite the [ in
  # the -path pattern; the placed dangling link must still be swept
  mkdir -p "$BATS_TEST_TMPDIR/r[1]/main/.orca"
  ln -s /gone "$BATS_TEST_TMPDIR/r[1]/main/.orca/keep"
  run secrets place "$BATS_TEST_TMPDIR/r[1]/main"
  [ "$status" -eq 0 ]
  has_line $'SKIPPED_GONE:\t.env'
  [ ! -L "$BATS_TEST_TMPDIR/r[1]/main/.env" ]
  [ -L "$BATS_TEST_TMPDIR/r[1]/main/.orca/keep" ]
}

@test "place git-excludes the secrets tree in a conventional checkout" {
  make_repo "$BATS_TEST_TMPDIR/c"
  mkdir -p "$BATS_TEST_TMPDIR/c/.orca/secrets"
  echo 'x' >"$BATS_TEST_TMPDIR/c/.orca/secrets/x"
  cd "$BATS_TEST_TMPDIR/c"
  run secrets place "$BATS_TEST_TMPDIR/c"
  [ "$status" -eq 0 ]
  git check-ignore -q .orca/secrets/x
}

@test "remove strips only our placement links" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  secrets place "$BATS_TEST_TMPDIR/r/main" >/dev/null
  ln -s /somewhere-else "$BATS_TEST_TMPDIR/r/main/foreign-link"
  run secrets remove "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'UNPLACED:\t.env'
  has_line $'UNPLACED_TOTAL:\t1'
  [ ! -L "$BATS_TEST_TMPDIR/r/main/.env" ]
  [ -L "$BATS_TEST_TMPDIR/r/main/foreign-link" ]
  # the canonical secret survives; a later place restores the link
  [ -f "$BATS_TEST_TMPDIR/r/.orca/secrets/.env" ]
  run secrets place "$BATS_TEST_TMPDIR/r/main"
  has_line $'LINKED:\t.env'
}

@test "remove sweeps our dangling links too" {
  make_secrets_layout "$BATS_TEST_TMPDIR/r"
  echo 'SECRET=1' >"$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  secrets place "$BATS_TEST_TMPDIR/r/main" >/dev/null
  rm "$BATS_TEST_TMPDIR/r/.orca/secrets/.env"
  run secrets remove "$BATS_TEST_TMPDIR/r/main"
  [ "$status" -eq 0 ]
  has_line $'UNPLACED:\t.env'
  [ ! -L "$BATS_TEST_TMPDIR/r/main/.env" ]
}

@test "misuse fails typed: bad args and non-worktree" {
  run secrets place
  assert_fail_reason BAD_ARGS
  mkdir "$BATS_TEST_TMPDIR/plain"
  run secrets place "$BATS_TEST_TMPDIR/plain"
  assert_fail_reason NOT_GIT
}
