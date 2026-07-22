#!/usr/bin/env bash
# Tests for bin/fm-project-remove.sh: the captain-gated guarded removal
# transaction that retires one registered project clone without bypassing the
# project-write boundary or the never-discard-unlanded-work rule.
#
# Matrix:
#   (a) clean removal deletes the clone, then drops exactly its registry line,
#       preserving every other registry line
#   (b) --check is read-only on a clean clone and reports clean
#   (c) removal requires --confirm with the exact name; a mismatch refuses
#       before any mutation
#   (d) dirty/untracked work refuses with a state-scoped discard token; same-path
#       index and worktree content changes invalidate it; a fresh token discards
#   (e) a discard token minted for another project, or garbage, never
#       authorizes this project
#   (f) unpushed branches and stashes refuse as unlanded work
#   (g) a repository with no remote refuses on every commit object, including
#       tag-only history, until explicit discard authority is presented
#   (h) live task metadata referencing the clone refuses structurally with no
#       discard token offered; unrelated task metadata does not block
#   (i) open backlog items tagged (repo: <name>) refuse; done items do not
#   (j) a secondmate registry line listing the project refuses
#   (k) a linked worktree that still exists refuses; a stale registration is
#       untouched by --check and pruned only by the removal run
#   (l) path traversal, absolute paths, and dash-leading names are rejected
#   (m) a symlinked clone and a symlinked projects directory refuse, leaving
#       the symlink target untouched
#   (n) a gitfile clone (itself a linked worktree of another repo) refuses
#   (o) a failed clone deletion stops loudly and leaves the registry untouched
#   (p) stale-registry repair drops the line when no clone exists, and a
#       second run fails loudly instead of reporting success for a typo
#   (q) an unregistered clone is still removed with a notice, with or without
#       a registry file
#   (r) the no-mistakes gate refusal fires before any mutation
#   (s) independent state, data, and projects roots outside the active home
#       refuse before inventory or deletion
#   (t) mandatory Git inventory and post-prune inspection failures refuse closed
#   (u) the prime directive permits discard only through the exact scoped token
#   (v) ignored secrets, generated output, caches, dependency trees, empty
#       directories, and nested repository state require fresh exact authority
#   (w) caller-controlled root overrides cannot hide the running checkout
#   (x) incomplete state metadata enumeration refuses closed
#   (y) a per-project lock serializes removals and a final inventory comparison
#       catches writes that race the transaction
#   (z) clean submodule gitdirs, refs, stashes, and objects require exact
#       authority independently of the outer worktree status
#   (aa) post-prune and post-rename writes refuse without deleting raced bytes
#   (ab) registry rewrites use restrictive unpredictable same-directory temps
#   (ac) discard authority uses full SHA-256 and has no weak fallback
#   (ad) an interrupted quarantined deletion refuses in every mode and is
#        never misclassified as ordinary stale-registry repair
#   (ae) entries merely named .git that git cannot validate stay ordinary
#        discardable payload instead of blocking inspection or masquerading
#        as nested repositories
#   (af) a nested repository whose gitdir store resolves outside the clone
#        remains discardable exact-authority inventory, never an
#        unconditional structural blocker
#   (ag) a process holding an open handle into the clone refuses at the
#        deletion boundary and the clone is restored intact
#   (ah) dotted project names are valid, work end to end, and are documented
#        as valid
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity

REMOVE="$ROOT/bin/fm-project-remove.sh"
REAL_GIT=$(command -v git)
REAL_FIND=$(command -v find)
REAL_MV=$(command -v mv)
REAL_MKTEMP=$(command -v mktemp)
TMP_ROOT=$(fm_test_tmproot fm-project-remove-tests)

make_home() {
  mkdir -p "$1/data" "$1/state" "$1/projects"
}

# Landed clone: src repo -> bare origin -> clone, so every commit is reachable
# from a remote-tracking branch.
make_landed_clone() {
  local home=$1 name=$2
  fm_git_init_commit "$home/src-$name"
  git clone --quiet --bare "$home/src-$name" "$home/origin-$name.git"
  git clone --quiet "file://$home/origin-$name.git" "$home/projects/$name" 2>/dev/null
}

add_registry() {
  printf -- '- %s - fixture project (added 2026-07-21)\n' "$2" >> "$1/data/projects.md"
}

run_remove() {
  local home=$1
  shift
  FM_HOME="$home" "$REMOVE" "$@" 2>&1
}

make_failing_git_wrapper() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_TEST_GIT_FAIL:-}
args=" $*"
case "$mode:$args" in
  worktree-list:*" worktree list --porcelain") exit 86 ;;
  stash:*" stash list --format=%H") exit 86 ;;
  remote:*" remote") exit 86 ;;
  branches:*" for-each-ref "*" refs/heads") exit 86 ;;
  contains:*" branch -r --contains "*) exit 86 ;;
  prune:*" worktree prune") exit 86 ;;
esac
if [ "$mode" = post-prune-list ]; then
  case "$args" in
    *" worktree prune")
      "$FM_REAL_GIT" "$@"
      code=$?
      [ "$code" -ne 0 ] || : > "$FM_TEST_GIT_MARKER"
      exit "$code"
      ;;
    *" worktree list --porcelain")
      [ ! -e "$FM_TEST_GIT_MARKER" ] || exit 86
      ;;
  esac
fi
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  printf '%s\n' "$fakebin"
}

extract_token() {
  printf '%s\n' "$1" | grep -o 'discard-unlanded:[A-Za-z0-9._-]*:[0-9a-f]\{1,\}' | head -1
}

test_clean_removal_and_registry_consistency() {
  local home="$TMP_ROOT/clean" out code
  make_home "$home"
  make_landed_clone "$home" alpha
  printf '# projects\n' > "$home/data/projects.md"
  printf -- '- alpha [local-only +yolo] - fixture project (added 2026-07-21)\n' >> "$home/data/projects.md"
  add_registry "$home" beta
  printf -- '- gamma [direct-PR +yolo] - fixture project (added 2026-07-21)\n' >> "$home/data/projects.md"

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 0 "$code" "clean removal"
  assert_contains "$out" "removed project alpha" "clean removal did not report success"
  assert_absent "$home/projects/alpha" "clone survived clean removal"
  assert_no_grep '- alpha ' "$home/data/projects.md" "registry still lists alpha"
  assert_grep '- beta - fixture project' "$home/data/projects.md" "unrelated registry line was disturbed"
  assert_grep '- gamma [direct-PR +yolo] - fixture project' "$home/data/projects.md" "unrelated mode-bracketed registry line was disturbed"
  assert_grep '# projects' "$home/data/projects.md" "registry header line was disturbed"
  assert_absent "$ROOT/0" "post-prune verification wrote outside the managed clone"
  pass "clean removal deletes the clone then drops exactly its registry line"
}

test_check_is_read_only_on_clean_clone() {
  local home="$TMP_ROOT/check-clean" out code
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  fm_write_meta "$home/state/unrelated.meta" \
    "project=$home/projects/beta" \
    "worktree=$home/worktrees/beta"

  out=$(run_remove "$home" alpha --check)
  code=$?
  expect_code 0 "$code" "clean check"
  assert_contains "$out" "clean: removal of alpha would proceed" "check did not report clean"
  assert_present "$home/projects/alpha" "check removed the clone"
  assert_grep '- alpha ' "$home/data/projects.md" "check mutated the registry"
  assert_absent "$home/state/.guard-watcher-stale-banner" "--check mutated the guard's stale-watcher marker"

  out=$(run_remove "$home" alpha --check --confirm alpha)
  code=$?
  expect_code 1 "$code" "check with confirm"
  assert_contains "$out" "read-only" "check+confirm was not rejected as contradictory"
  pass "--check inventories without mutating"
}

test_confirm_required_and_exact() {
  local home="$TMP_ROOT/confirm" out code
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  fm_write_meta "$home/state/unrelated.meta" \
    "project=$home/projects/beta" \
    "worktree=$home/worktrees/beta"

  out=$(run_remove "$home" alpha)
  code=$?
  expect_code 1 "$code" "missing confirm"
  assert_contains "$out" "requires --confirm" "missing confirm not reported"

  out=$(run_remove "$home" alpha --confirm alhpa)
  code=$?
  expect_code 1 "$code" "mismatched confirm"
  assert_contains "$out" "confirmation mismatch" "confirm mismatch not reported"
  assert_present "$home/projects/alpha" "mismatched confirm still removed the clone"
  assert_grep '- alpha ' "$home/data/projects.md" "mismatched confirm mutated the registry"
  assert_absent "$home/state/.guard-watcher-stale-banner" "invalid confirmation ran the mutating guard"
  pass "removal demands an exact --confirm of the project name"
}

test_dirty_refusal_and_scoped_discard_flow() {
  local home="$TMP_ROOT/dirty" out code token token_fingerprint stale_token fresh_token
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  mkdir -p "$home/projects/alpha/untracked"
  echo extra > "$home/projects/alpha/untracked/item.txt"
  echo edit >> "$home/projects/alpha/README.md"
  git -C "$home/projects/alpha" add README.md

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "dirty refusal"
  assert_contains "$out" "dirty or untracked" "dirty work not inventoried"
  assert_contains "$out" "discard-unlanded:alpha:" "no discard token offered for discardable-only refusal"
  assert_present "$home/projects/alpha" "dirty refusal still removed the clone"
  token=$(extract_token "$out")
  [ -n "$token" ] || fail "could not extract discard token"
  token_fingerprint=${token##*:}
  [ "${#token_fingerprint}" -eq 64 ] || fail "discard token did not use a full SHA-256 fingerprint"

  echo changed >> "$home/projects/alpha/README.md"
  git -C "$home/projects/alpha" add README.md
  echo changed > "$home/projects/alpha/untracked/item.txt"
  stale_token=$token
  out=$(run_remove "$home" alpha --confirm alpha --discard-authority "$stale_token")
  code=$?
  expect_code 1 "$code" "stale token refusal"
  assert_contains "$out" "changed after the token was issued" "stale token was not detected"
  assert_present "$home/projects/alpha" "stale token still removed the clone"

  out=$(run_remove "$home" alpha --check)
  code=$?
  expect_code 1 "$code" "check on dirty clone"
  fresh_token=$(extract_token "$out")
  [ -n "$fresh_token" ] || fail "check did not print a fresh token"
  assert_present "$home/projects/alpha" "check on dirty clone mutated the clone"

  out=$(run_remove "$home" alpha --confirm alpha --discard-authority "$fresh_token")
  code=$?
  expect_code 0 "$code" "authorized discard removal"
  assert_absent "$home/projects/alpha" "authorized discard did not remove the clone"
  assert_no_grep '- alpha ' "$home/data/projects.md" "authorized discard left the registry line"
  pass "discard authority fingerprints current index, worktree, and untracked contents"
}

test_discard_authority_is_project_scoped() {
  local home="$TMP_ROOT/scope" out code beta_token
  make_home "$home"
  make_landed_clone "$home" alpha
  make_landed_clone "$home" beta
  make_landed_clone "$home" gamma
  add_registry "$home" alpha
  add_registry "$home" beta
  add_registry "$home" gamma
  echo x > "$home/projects/alpha/dirty.txt"
  echo y > "$home/projects/beta/dirty.txt"

  out=$(run_remove "$home" beta --check)
  beta_token=$(extract_token "$out")
  [ -n "$beta_token" ] || fail "could not mint beta token"

  out=$(run_remove "$home" alpha --confirm alpha --discard-authority "$beta_token")
  code=$?
  expect_code 1 "$code" "cross-project token refusal"
  assert_contains "$out" "scoped to a different project" "cross-project token not rejected"
  assert_present "$home/projects/alpha" "cross-project token still removed the clone"

  out=$(run_remove "$home" alpha --confirm alpha --discard-authority "yes I am sure")
  code=$?
  expect_code 1 "$code" "prose authority refusal"
  assert_contains "$out" "unrecognized discard-authority" "vague prose token not rejected"
  assert_present "$home/projects/alpha" "prose token still removed the clone"

  out=$(run_remove "$home" gamma --confirm gamma --discard-authority "$beta_token")
  code=$?
  expect_code 1 "$code" "clean cross-project token refusal"
  assert_contains "$out" "scoped to a different project" "clean inventory accepted a cross-project token"

  out=$(run_remove "$home" gamma --confirm gamma --discard-authority "yes I am sure")
  code=$?
  expect_code 1 "$code" "clean prose authority refusal"
  assert_contains "$out" "unrecognized discard-authority" "clean inventory accepted prose authority"

  out=$(run_remove "$home" gamma --confirm gamma --discard-authority "discard-unlanded:gamma:deadbeef0000")
  code=$?
  expect_code 1 "$code" "clean stale token refusal"
  assert_contains "$out" "does not match the CURRENT" "clean inventory accepted a stale same-project token"
  assert_present "$home/projects/gamma" "invalid clean-inventory authority removed the clone"
  pass "discard authority never transfers across projects or accepts prose"
}

test_ignored_and_nested_repository_state_is_scoped() {
  local home="$TMP_ROOT/ignored" nested out code token fresh_token
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  printf '.env\ndist/\n.cache/\nnode_modules/\n' > "$home/projects/alpha/.git/info/exclude"
  mkdir -p "$home/projects/alpha/dist" "$home/projects/alpha/.cache/empty" "$home/projects/alpha/node_modules/pkg"
  printf 'secret\n' > "$home/projects/alpha/.env"
  printf 'bundle\n' > "$home/projects/alpha/dist/app.js"
  printf 'dependency\n' > "$home/projects/alpha/node_modules/pkg/index.js"
  nested="$home/projects/alpha/node_modules/nested"
  fm_git_init_commit "$nested"

  out=$(run_remove "$home" alpha --check)
  code=$?
  expect_code 1 "$code" "ignored inventory refusal"
  assert_contains "$out" "ignored path report" "ignored content was not classified as discardable"
  token=$(extract_token "$out")
  [ -n "$token" ] || fail "ignored inventory did not produce a discard token"

  printf 'changed secret\n' > "$home/projects/alpha/.env"
  printf 'changed bundle\n' > "$home/projects/alpha/dist/app.js"
  printf 'changed dependency\n' > "$home/projects/alpha/node_modules/pkg/index.js"
  printf 'nested commit\n' > "$nested/commit-only.txt"
  git -C "$nested" add commit-only.txt
  git -C "$nested" commit -qm "nested commit"
  git -C "$nested" tag nested-state
  printf 'nested stash\n' >> "$nested/README.md"
  git -C "$nested" stash -q

  out=$(run_remove "$home" alpha --confirm alpha --discard-authority "$token")
  code=$?
  expect_code 1 "$code" "ignored and nested stale token refusal"
  assert_contains "$out" "does not match the CURRENT" "ignored or nested repository changes did not invalidate authority"
  assert_present "$home/projects/alpha" "stale ignored-inventory authority removed the clone"

  out=$(run_remove "$home" alpha --check)
  fresh_token=$(extract_token "$out")
  [ -n "$fresh_token" ] || fail "changed ignored inventory did not produce a fresh token"
  out=$(run_remove "$home" alpha --confirm alpha --discard-authority "$fresh_token")
  code=$?
  expect_code 0 "$code" "fresh ignored inventory authority"
  assert_absent "$home/projects/alpha" "fresh ignored-inventory authority did not remove the clone"
  pass "ignored payloads and nested repository state are exact authority inventory"
}

test_clean_submodule_git_state_is_scoped() {
  local home="$TMP_ROOT/submodule-state" sub_source sub_origin submodule out code token fresh_token base
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  sub_source="$home/sub-source"
  sub_origin="$home/sub-origin.git"
  fm_git_init_commit "$sub_source"
  git clone --quiet --bare "$sub_source" "$sub_origin"
  git -C "$home/projects/alpha" -c protocol.file.allow=always submodule add -q "file://$sub_origin" vendor/sub
  git -C "$home/projects/alpha" commit -qm "add submodule"
  git -C "$home/projects/alpha" push -q origin HEAD
  submodule="$home/projects/alpha/vendor/sub"
  [ -z "$(git -C "$home/projects/alpha" status --porcelain=v1)" ] || fail "submodule fixture left the outer clone dirty"

  out=$(run_remove "$home" alpha --check)
  code=$?
  expect_code 1 "$code" "clean submodule state refusal"
  assert_contains "$out" "nested repository worktree" "clean submodule state was not classified as discardable"
  token=$(extract_token "$out")
  [ -n "$token" ] || fail "clean submodule state did not produce a token"

  base=$(git -C "$submodule" rev-parse HEAD)
  git -C "$submodule" tag nested-ref-only
  printf 'stash-only\n' >> "$submodule/README.md"
  git -C "$submodule" stash -q
  printf 'object-only\n' > "$submodule/object-only.txt"
  git -C "$submodule" add object-only.txt
  git -C "$submodule" commit -qm "nested unreachable object"
  git -C "$submodule" reset -q --hard "$base"
  [ -z "$(git -C "$home/projects/alpha" status --porcelain=v1)" ] || fail "nested metadata mutation changed outer status"

  out=$(run_remove "$home" alpha --confirm alpha --discard-authority "$token")
  code=$?
  expect_code 1 "$code" "stale clean-submodule authority"
  assert_contains "$out" "does not match the CURRENT" "nested refs, stash, and objects did not invalidate authority"
  assert_present "$home/projects/alpha" "stale nested authority removed the clone"

  out=$(run_remove "$home" alpha --check)
  fresh_token=$(extract_token "$out")
  [ -n "$fresh_token" ] || fail "changed clean-submodule state did not produce a fresh token"
  out=$(run_remove "$home" alpha --confirm alpha --discard-authority "$fresh_token")
  code=$?
  expect_code 0 "$code" "fresh clean-submodule authority"
  assert_absent "$home/projects/alpha" "fresh clean-submodule authority did not remove the clone"
  pass "clean submodule refs, stashes, and objects are exact authority inventory"
}

test_unpushed_branch_and_stash_refuse() {
  local home="$TMP_ROOT/unpushed" out code
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  git -C "$home/projects/alpha" checkout -q -b feature
  echo work > "$home/projects/alpha/feature.txt"
  git -C "$home/projects/alpha" add feature.txt
  git -C "$home/projects/alpha" commit -qm "unpushed work"
  echo pending >> "$home/projects/alpha/README.md"
  git -C "$home/projects/alpha" stash -q

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "unpushed refusal"
  assert_contains "$out" "not reachable from any remote-tracking branch" "unpushed branch not inventoried"
  assert_contains "$out" "stash entry" "stash not inventoried"
  assert_present "$home/projects/alpha" "unpushed refusal still removed the clone"
  assert_grep '- alpha ' "$home/data/projects.md" "unpushed refusal mutated the registry"
  pass "unpushed branches and stashes refuse as unlanded work"
}

test_no_remote_repository_refuses_then_discards() {
  local home="$TMP_ROOT/local-only" out code token fresh_token base
  make_home "$home"
  fm_git_init_commit "$home/projects/gamma"
  add_registry "$home" gamma

  out=$(run_remove "$home" gamma --confirm gamma)
  code=$?
  expect_code 1 "$code" "local-only refusal"
  assert_contains "$out" "commit object(s) exist only locally" "local-only commits not inventoried"
  assert_present "$home/projects/gamma" "local-only refusal still removed the clone"

  token=$(extract_token "$out")
  [ -n "$token" ] || fail "no token for local-only inventory"
  base=$(git -C "$home/projects/gamma" rev-parse HEAD)
  echo tag-only > "$home/projects/gamma/tag-only.txt"
  git -C "$home/projects/gamma" add tag-only.txt
  git -C "$home/projects/gamma" commit -qm "tag-only history"
  git -C "$home/projects/gamma" tag retained-only-by-tag
  git -C "$home/projects/gamma" reset -q --hard "$base"

  out=$(run_remove "$home" gamma --confirm gamma --discard-authority "$token")
  code=$?
  expect_code 1 "$code" "stale local-only token refusal"
  assert_contains "$out" "changed after the token was issued" "tag-only commit did not invalidate the token"
  assert_present "$home/projects/gamma" "stale local-only token removed the clone"

  out=$(run_remove "$home" gamma --check)
  code=$?
  expect_code 1 "$code" "fresh local-only inventory"
  assert_contains "$out" "2 commit object(s)" "tag-only commit object was not inventoried"
  fresh_token=$(extract_token "$out")
  [ -n "$fresh_token" ] || fail "no fresh token for tag-only inventory"
  out=$(run_remove "$home" gamma --confirm gamma --discard-authority "$fresh_token")
  code=$?
  expect_code 0 "$code" "authorized local-only removal"
  assert_absent "$home/projects/gamma" "authorized local-only removal left the clone"
  pass "a no-remote repository inventories branch, tag-only, and unreachable commits"
}

test_live_task_metadata_refuses_structurally() {
  local home="$TMP_ROOT/task" out code
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  fm_write_meta "$home/state/t1.meta" \
    "window=fm:1" \
    "worktree=$home/projects/alpha" \
    "project=$home/projects/alpha" \
    "harness=echo" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  fm_write_meta "$home/state/t2.meta" \
    "window=fm:2" \
    "worktree=$home/elsewhere/wt" \
    "project=$home/elsewhere/proj" \
    "harness=echo" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "live task refusal"
  assert_contains "$out" "live task t1" "live task not inventoried"
  assert_not_contains "$out" "live task t2" "unrelated task wrongly blocked removal"
  assert_not_contains "$out" "discard-unlanded:" "structural refusal offered a discard token"
  assert_present "$home/projects/alpha" "live task refusal still removed the clone"

  out=$(run_remove "$home" alpha --confirm alpha --discard-authority "discard-unlanded:alpha:deadbeef0000")
  code=$?
  expect_code 1 "$code" "structural + authority refusal"
  assert_contains "$out" "never cover structural blockers" "authority was not rejected for structural blockers"
  assert_present "$home/projects/alpha" "authority bypassed a structural blocker"

  rm -f "$home/state/t1.meta"
  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 0 "$code" "removal after task teardown"
  assert_absent "$home/projects/alpha" "clone survived after blocker cleared"
  pass "live task metadata refuses structurally and is never discardable"
}

test_open_backlog_items_refuse() {
  local home="$TMP_ROOT/backlog" out code
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] fix-a - Fix the thing (repo: alpha)
- [ ] other-b - Unrelated (repo: beta)
## Done
- [x] old-a - Landed earlier (repo: alpha)
EOF

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "open backlog refusal"
  assert_contains "$out" "open backlog item(s) tagged (repo: alpha): fix-a" "open backlog item not inventoried"
  assert_present "$home/projects/alpha" "backlog refusal still removed the clone"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] other-b - Unrelated (repo: beta)
## Done
- [x] old-a - Landed earlier (repo: alpha)
EOF
  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 0 "$code" "removal with only done backlog references"
  pass "open backlog items block removal; done items do not"
}

test_secondmate_registered_clone_refuses() {
  local home="$TMP_ROOT/secondmate" out code
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  cat > "$home/data/secondmates.md" <<EOF
- design - Designs things (home: $TMP_ROOT/nonexistent-design-home; scope: design work; projects: alpha,beta; added 2026-07-21)
- nested - Release work (with legacy context) (home: $home/projects/alpha/nonexistent-secondmate-home; scope: release work; projects: beta; added 2026-07-21)
- other - Other domain (home: $TMP_ROOT/nonexistent-other-home; scope: other work; projects: beta; added 2026-07-21)
EOF

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "secondmate refusal"
  assert_contains "$out" "secondmate design registers a clone of alpha" "secondmate clone not inventoried"
  assert_contains "$out" "secondmate nested home" "secondmate home after a parenthetical summary was not inventoried"
  assert_not_contains "$out" "secondmate other" "unrelated secondmate wrongly blocked removal"
  assert_present "$home/projects/alpha" "secondmate refusal still removed the clone"

  grep -Ev '^- (design|nested) ' "$home/data/secondmates.md" > "$home/data/secondmates.md.new"
  mv "$home/data/secondmates.md.new" "$home/data/secondmates.md"
  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 0 "$code" "removal after secondmate deregistration"
  pass "a secondmate-registered clone blocks removal until deregistered"
}

test_active_home_roots_cannot_be_overridden() {
  local home="$TMP_ROOT/active-home" other="$TMP_ROOT/other-home" out code spec variable path
  make_home "$home"
  make_home "$other"
  make_landed_clone "$home" alpha
  make_landed_clone "$other" alpha
  add_registry "$home" alpha
  add_registry "$other" alpha

  for spec in \
    "FM_STATE_OVERRIDE:$other/state" \
    "FM_DATA_OVERRIDE:$other/data" \
    "FM_PROJECTS_OVERRIDE:$other/projects"
  do
    variable=${spec%%:*}
    path=${spec#*:}
    out=$(env FM_HOME="$home" "$variable=$path" "$REMOVE" alpha --confirm alpha 2>&1)
    code=$?
    expect_code 1 "$code" "$variable active-home refusal"
    assert_contains "$out" "outside the active FM_HOME" "$variable mismatch was not rejected"
    assert_present "$home/projects/alpha" "$variable mismatch removed the active home's clone"
    assert_present "$other/projects/alpha" "$variable mismatch removed the other home's clone"
    assert_grep '- alpha ' "$home/data/projects.md" "$variable mismatch changed the active registry"
    assert_grep '- alpha ' "$other/data/projects.md" "$variable mismatch changed the other registry"
  done
  pass "state, data, and projects roots remain contained by the active home"
}

test_root_override_cannot_hide_running_checkout() {
  local home="$TMP_ROOT/root-identity" fake_root embedded out code
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  fake_root="$home/fake-root"
  embedded="$home/projects/alpha/embedded-firstmate"
  mkdir -p "$fake_root/bin" "$embedded/bin"
  cp "$REMOVE" "$embedded/bin/fm-project-remove.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$embedded/bin/fm-gate-refuse-lib.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_root/bin/fm-guard.sh"
  chmod +x "$fake_root/bin/fm-guard.sh" "$embedded/bin/fm-project-remove.sh"

  out=$(FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" "$embedded/bin/fm-project-remove.sh" alpha --confirm alpha 2>&1)
  code=$?
  expect_code 1 "$code" "immutable checkout containment"
  assert_contains "$out" "this firstmate checkout" "root override hid the running checkout from containment"
  assert_present "$home/projects/alpha" "root override containment failure removed the running checkout"
  assert_grep '- alpha ' "$home/data/projects.md" "root override containment failure changed the registry"
  pass "checkout containment is independent of caller-controlled root overrides"
}

test_state_enumeration_failure_refuses_closed() {
  local home="$TMP_ROOT/state-enumeration" fakebin out code
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  fm_write_meta "$home/state/unrelated.meta" "project=$home/projects/beta"
  fakebin=$(fm_fakebin "$TMP_ROOT/fake-find-state")
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'if [ "${1:-}" = "${FM_TEST_STATE:-}" ]; then exit 86; fi' \
    'exec "$FM_REAL_FIND" "$@"' > "$fakebin/find"
  chmod +x "$fakebin/find"

  out=$(PATH="$fakebin:$PATH" FM_REAL_FIND="$REAL_FIND" FM_TEST_STATE="$home/state" \
    FM_HOME="$home" "$REMOVE" alpha --confirm alpha 2>&1)
  code=$?
  expect_code 1 "$code" "state enumeration failure"
  assert_contains "$out" "refusing:" "state enumeration failure was not reported"
  assert_present "$home/projects/alpha" "state enumeration failure removed the clone"
  assert_grep '- alpha ' "$home/data/projects.md" "state enumeration failure changed the registry"
  pass "incomplete state metadata enumeration refuses closed"
}

test_transaction_lock_and_final_inventory_recheck() {
  local home="$TMP_ROOT/transaction" prune_home="$TMP_ROOT/prune-race" quarantine_home="$TMP_ROOT/quarantine-race" \
    recreate_home="$TMP_ROOT/quarantine-recreate" fakebin owner lock marker out code preserved
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  lock="$home/state/.project-remove-alpha.lock"
  owner="$home/state/.project-remove-alpha.lock.owner.fixture"
  mkdir "$owner"
  printf '%s\n' "$$" > "$owner/pid"
  ln -s "$owner" "$lock"

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "project removal lock contention"
  assert_contains "$out" "another project-removal transaction" "live transaction lock was not honored"
  assert_present "$home/projects/alpha" "lock contention removed the clone"
  rm "$lock" "$owner/pid"
  rmdir "$owner"

  fakebin=$(fm_fakebin "$TMP_ROOT/fake-find-race")
  marker="$home/race-fired"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'if [ "${1:-}" = "${FM_TEST_RACE_TARGET:-}" ] && [ -L "${FM_TEST_RACE_LOCK:-}" ] && [ ! -e "${FM_TEST_RACE_MARKER:-}" ]; then' \
    '  : > "$FM_TEST_RACE_MARKER"' \
    '  printf "raced\n" > "$FM_TEST_RACE_TARGET/raced.txt"' \
    'fi' \
    'exec "$FM_REAL_FIND" "$@"' > "$fakebin/find"
  chmod +x "$fakebin/find"

  out=$(PATH="$fakebin:$PATH" FM_REAL_FIND="$REAL_FIND" FM_TEST_RACE_TARGET="$home/projects/alpha" \
    FM_TEST_RACE_LOCK="$lock" FM_TEST_RACE_MARKER="$marker" FM_HOME="$home" \
    "$REMOVE" alpha --confirm alpha 2>&1)
  code=$?
  expect_code 1 "$code" "final inventory race refusal"
  assert_contains "$out" "inventory changed before mutation" "final inventory comparison missed a racing write"
  assert_present "$home/projects/alpha/raced.txt" "race fixture did not create the competing work"
  assert_present "$home/projects/alpha" "racing write was deleted"
  assert_grep '- alpha ' "$home/data/projects.md" "racing write refusal changed the registry"
  assert_absent "$lock" "project-removal lock survived transaction refusal"

  make_home "$prune_home"
  make_landed_clone "$prune_home" alpha
  add_registry "$prune_home" alpha
  fakebin=$(fm_fakebin "$TMP_ROOT/fake-git-prune-race")
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'args=" $*"' \
    'if [[ "$args" == *" worktree prune"* ]]; then' \
    '  "$FM_REAL_GIT" "$@" || exit $?' \
    '  printf "post-prune race\n" > "$FM_TEST_RACE_TARGET/post-prune-raced.txt"' \
    '  exit 0' \
    'fi' \
    'exec "$FM_REAL_GIT" "$@"' > "$fakebin/git"
  chmod +x "$fakebin/git"
  out=$(PATH="$fakebin:$PATH" FM_REAL_GIT="$REAL_GIT" FM_TEST_RACE_TARGET="$prune_home/projects/alpha" \
    FM_HOME="$prune_home" "$REMOVE" alpha --confirm alpha 2>&1)
  code=$?
  expect_code 1 "$code" "post-prune payload race refusal"
  assert_contains "$out" "payload changed during git worktree prune" "post-prune payload race was not detected"
  assert_present "$prune_home/projects/alpha/post-prune-raced.txt" "post-prune raced bytes were deleted"
  assert_grep '- alpha ' "$prune_home/data/projects.md" "post-prune race changed the registry"

  make_home "$quarantine_home"
  make_landed_clone "$quarantine_home" alpha
  add_registry "$quarantine_home" alpha
  fakebin=$(fm_fakebin "$TMP_ROOT/fake-mv-quarantine-race")
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'if [ "${1:-}" = "$FM_TEST_RACE_TARGET" ] && [ ! -e "$FM_TEST_RACE_MARKER" ]; then' \
    '  : > "$FM_TEST_RACE_MARKER"' \
    '  "$FM_REAL_MV" "$@" || exit $?' \
    '  printf "post-rename race\n" > "$2/post-rename-raced.txt"' \
    '  exit 0' \
    'fi' \
    'exec "$FM_REAL_MV" "$@"' > "$fakebin/mv"
  chmod +x "$fakebin/mv"
  marker="$quarantine_home/rename-race-fired"
  out=$(PATH="$fakebin:$PATH" FM_REAL_MV="$REAL_MV" FM_TEST_RACE_TARGET="$quarantine_home/projects/alpha" \
    FM_TEST_RACE_MARKER="$marker" FM_HOME="$quarantine_home" "$REMOVE" alpha --confirm alpha 2>&1)
  code=$?
  expect_code 1 "$code" "post-rename payload race refusal"
  assert_contains "$out" "quarantined project payload differs" "post-rename payload race was not detected"
  assert_present "$quarantine_home/projects/alpha/post-rename-raced.txt" "post-rename raced bytes were not restored"
  assert_grep '- alpha ' "$quarantine_home/data/projects.md" "post-rename race changed the registry"
  preserved=$(find "$quarantine_home/projects" -maxdepth 1 -name '.fm-project-remove-alpha.*' -print)
  [ -z "$preserved" ] || fail "restored post-rename race left an unnecessary quarantine"

  make_home "$recreate_home"
  make_landed_clone "$recreate_home" alpha
  add_registry "$recreate_home" alpha
  fakebin=$(fm_fakebin "$TMP_ROOT/fake-mv-target-recreate")
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'if [ "${1:-}" = "$FM_TEST_RACE_TARGET" ]; then' \
    '  "$FM_REAL_MV" "$@" || exit $?' \
    '  mkdir "$FM_TEST_RACE_TARGET"' \
    '  printf "replacement\n" > "$FM_TEST_RACE_TARGET/replacement.txt"' \
    '  exit 0' \
    'fi' \
    'exec "$FM_REAL_MV" "$@"' > "$fakebin/mv"
  chmod +x "$fakebin/mv"
  out=$(PATH="$fakebin:$PATH" FM_REAL_MV="$REAL_MV" FM_TEST_RACE_TARGET="$recreate_home/projects/alpha" \
    FM_HOME="$recreate_home" "$REMOVE" alpha --confirm alpha 2>&1)
  code=$?
  expect_code 1 "$code" "target recreation at quarantine boundary"
  assert_contains "$out" "quarantine boundary is ambiguous" "recreated target was not detected"
  assert_present "$recreate_home/projects/alpha/replacement.txt" "recreated target was deleted"
  preserved=$(find "$recreate_home/projects" -path '*/.fm-project-remove-alpha.*/clone' -type d -print)
  [ -n "$preserved" ] || fail "authorized clone bytes were not preserved after target recreation"
  assert_grep '- alpha ' "$recreate_home/data/projects.md" "target recreation changed the registry"
  pass "project removal holds a lock and rechecks inventory before mutation"
}

test_git_inspection_failures_refuse_closed() {
  local mode home fakebin marker out code
  for mode in worktree-list stash remote branches contains prune post-prune-list; do
    home="$TMP_ROOT/git-failure-$mode"
    marker="$TMP_ROOT/git-failure-$mode.marker"
    make_home "$home"
    make_landed_clone "$home" alpha
    add_registry "$home" alpha
    fakebin=$(make_failing_git_wrapper "$TMP_ROOT/fake-$mode")

    out=$(PATH="$fakebin:$PATH" FM_REAL_GIT="$REAL_GIT" FM_TEST_GIT_FAIL="$mode" \
      FM_TEST_GIT_MARKER="$marker" FM_HOME="$home" "$REMOVE" alpha --confirm alpha 2>&1)
    code=$?
    expect_code 1 "$code" "$mode inspection failure"
    assert_contains "$out" "refusing:" "$mode inspection failure was not reported"
    assert_present "$home/projects/alpha" "$mode inspection failure removed the clone"
    assert_grep '- alpha ' "$home/data/projects.md" "$mode inspection failure changed the registry"
  done
  pass "mandatory Git inspection and prune failures refuse closed"
}

test_sha256_is_required_and_full_length() {
  local home="$TMP_ROOT/sha-required" fakebin marker out code
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  printf 'dirty\n' > "$home/projects/alpha/dirty.txt"
  fakebin=$(fm_fakebin "$TMP_ROOT/fake-sha-failure")
  marker="$home/cksum-used"
  printf '#!/usr/bin/env bash\nexit 86\n' > "$fakebin/shasum"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    ': > "$FM_TEST_CKSUM_MARKER"' \
    'exit 0' > "$fakebin/cksum"
  chmod +x "$fakebin/shasum" "$fakebin/cksum"

  out=$(PATH="$fakebin:$PATH" FM_TEST_CKSUM_MARKER="$marker" FM_HOME="$home" \
    "$REMOVE" alpha --check 2>&1)
  code=$?
  expect_code 1 "$code" "SHA-256 execution failure"
  assert_not_contains "$out" "discard-unlanded:" "failed SHA-256 produced an authority token"
  assert_absent "$marker" "weak cksum fallback was invoked"
  assert_present "$home/projects/alpha" "SHA-256 failure removed the clone"
  pass "discard authority requires a full SHA-256 digest without weak fallback"
}

test_registry_rewrite_uses_secure_temp() {
  local home="$TMP_ROOT/registry-temp" fakebin sentinel candidate out code leftovers
  make_home "$home"
  add_registry "$home" alpha
  add_registry "$home" beta
  sentinel="$home/external-sentinel"
  candidate="$home/data/.projects.md.tmp.attacker"
  printf 'external sentinel\n' > "$sentinel"
  fakebin=$(fm_fakebin "$TMP_ROOT/fake-registry-mktemp")
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'case " $*" in' \
    '  *"/.projects.md.tmp.XXXXXX"*)' \
    '    ln -s "$FM_TEST_SENTINEL" "$FM_TEST_TEMP_CANDIDATE"' \
    '    printf "%s\n" "$FM_TEST_TEMP_CANDIDATE"' \
    '    exit 0' \
    '    ;;' \
    'esac' \
    'exec "$FM_REAL_MKTEMP" "$@"' > "$fakebin/mktemp"
  chmod +x "$fakebin/mktemp"

  out=$(PATH="$fakebin:$PATH" FM_REAL_MKTEMP="$REAL_MKTEMP" FM_TEST_SENTINEL="$sentinel" \
    FM_TEST_TEMP_CANDIDATE="$candidate" FM_HOME="$home" "$REMOVE" alpha --confirm alpha 2>&1)
  code=$?
  expect_code 1 "$code" "symlinked registry temp refusal"
  assert_contains "$out" "ordinary temporary registry file" "symlinked mktemp result was not rejected"
  [ "$(cat "$sentinel")" = "external sentinel" ] || fail "registry rewrite followed the malicious temp symlink"
  assert_grep '- alpha ' "$home/data/projects.md" "failed secure registry rewrite changed alpha"
  assert_grep '- beta ' "$home/data/projects.md" "failed secure registry rewrite changed beta"
  assert_absent "$candidate" "failed registry rewrite leaked its temporary symlink"

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 0 "$code" "secure stale-registry repair"
  assert_no_grep '- alpha ' "$home/data/projects.md" "secure registry rewrite left alpha"
  assert_grep '- beta ' "$home/data/projects.md" "secure registry rewrite disturbed beta"
  leftovers=$(find "$home/data" -maxdepth 1 -name '.projects.md.tmp.*' -print)
  [ -z "$leftovers" ] || fail "secure registry rewrite leaked temporary files"
  pass "registry rewrites reject symlink temps and clean restrictive same-directory files"
}

test_interrupted_quarantine_never_stale_repairs() {
  local home="$TMP_ROOT/interrupted" q out code
  make_home "$home"
  add_registry "$home" alpha
  add_registry "$home" beta
  q="$home/projects/.fm-project-remove-alpha.crashed"
  mkdir -p "$q/clone"
  printf 'unlanded bytes\n' > "$q/clone/precious.txt"

  out=$(run_remove "$home" alpha --check)
  code=$?
  expect_code 1 "$code" "check with interrupted quarantine"
  assert_contains "$out" "NOT a stale registry" "check misclassified an interrupted removal as a stale registry"
  assert_contains "$out" "mv '$q/clone'" "check did not explain the restore step"

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "repair with interrupted quarantine"
  assert_contains "$out" "NOT a stale registry" "repair did not refuse the interrupted quarantine"
  assert_grep '- alpha ' "$home/data/projects.md" "interrupted quarantine still repaired the registry"
  assert_present "$q/clone/precious.txt" "interrupted-removal bytes were touched"

  # A present clone next to a leftover quarantine is equally ambiguous.
  make_landed_clone "$home" alpha
  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "removal with leftover quarantine"
  assert_contains "$out" "NOT a stale registry" "removal ignored the leftover quarantine"
  assert_present "$home/projects/alpha" "removal proceeded despite the leftover quarantine"
  assert_present "$q/clone/precious.txt" "leftover quarantine bytes were touched during refusal"

  # Once the quarantine is resolved by hand, the ordinary paths work again.
  rm -rf "$q"
  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 0 "$code" "removal after quarantine resolution"
  assert_absent "$home/projects/alpha" "clone survived after quarantine resolution"

  # Empty residue (a crash between quarantine creation and the rename)
  # refuses with its own message and never repairs the registry.
  mkdir "$home/projects/.fm-project-remove-beta.residue"
  out=$(run_remove "$home" beta --confirm beta)
  code=$?
  expect_code 1 "$code" "repair with empty quarantine residue"
  assert_contains "$out" "empty residue" "empty quarantine residue was not distinguished"
  assert_grep '- beta ' "$home/data/projects.md" "empty residue still repaired the registry"
  rmdir "$home/projects/.fm-project-remove-beta.residue"
  out=$(run_remove "$home" beta --confirm beta)
  code=$?
  expect_code 0 "$code" "stale repair after residue cleanup"
  assert_contains "$out" "repaired stale registry" "stale repair did not run after residue cleanup"
  pass "an interrupted quarantine refuses loudly and never becomes a stale-registry repair"
}

test_invalid_git_named_entries_stay_discardable() {
  local home="$TMP_ROOT/fake-git-markers" cache out code token fresh_token
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  printf '.cache/\n' > "$home/projects/alpha/.git/info/exclude"
  cache="$home/projects/alpha/.cache"
  mkdir -p "$cache/empty-marker/.git" "$cache/file-marker"
  printf 'not a gitfile\n' > "$cache/file-marker/.git"
  mkfifo "$cache/.git"
  ln -s /nonexistent-target "$cache/dangling.git-link"
  mkdir -p "$cache/link-marker"
  ln -s /nonexistent-target "$cache/link-marker/.git"

  out=$(run_remove "$home" alpha --check)
  code=$?
  expect_code 1 "$code" "fake marker inventory"
  assert_not_contains "$out" "cannot completely inventory nested repository state" "fake .git entries blocked the inventory"
  assert_not_contains "$out" "nested repository worktree" "a fake .git entry was classified as a nested repository"
  token=$(extract_token "$out")
  [ -n "$token" ] || fail "fake .git payload did not mint a discard token"

  printf 'cache contents changed\n' > "$cache/file-marker/.git"
  out=$(run_remove "$home" alpha --confirm alpha --discard-authority "$token")
  code=$?
  expect_code 1 "$code" "stale token over fake-marker change"
  assert_contains "$out" "does not match the CURRENT" "changed fake-marker payload did not invalidate authority"
  assert_present "$home/projects/alpha" "stale fake-marker authority removed the clone"

  out=$(run_remove "$home" alpha --check)
  fresh_token=$(extract_token "$out")
  [ -n "$fresh_token" ] || fail "changed fake-marker payload did not produce a fresh token"
  out=$(run_remove "$home" alpha --confirm alpha --discard-authority "$fresh_token")
  code=$?
  expect_code 0 "$code" "authorized fake-marker removal"
  assert_absent "$home/projects/alpha" "authorized fake-marker removal left the clone"
  pass "entries merely named .git stay ordinary discardable payload"
}

test_external_nested_repository_is_discardable_inventory() {
  local home="$TMP_ROOT/external-nested" out code token fresh_token
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  fm_git_init_commit "$home/external-parent"
  git -C "$home/external-parent" worktree add --quiet --detach "$home/projects/alpha/vendor-checkout"

  out=$(run_remove "$home" alpha --check)
  code=$?
  expect_code 1 "$code" "external nested inventory"
  assert_contains "$out" "nested repository worktree" "external nested checkout was not inventoried as discardable"
  assert_contains "$out" "resolve outside the clone" "external gitdir note is missing"
  assert_not_contains "$out" "structural blockers" "external nested gitdir was promoted to a structural blocker"
  token=$(extract_token "$out")
  [ -n "$token" ] || fail "external nested inventory did not mint a discard token"

  printf 'external work\n' > "$home/external-parent/external.txt"
  git -C "$home/external-parent" add external.txt
  git -C "$home/external-parent" commit -qm "external state change"
  out=$(run_remove "$home" alpha --confirm alpha --discard-authority "$token")
  code=$?
  expect_code 1 "$code" "stale token over external state change"
  assert_contains "$out" "does not match the CURRENT" "external repository state change did not invalidate authority"
  assert_present "$home/projects/alpha" "stale external-state authority removed the clone"

  out=$(run_remove "$home" alpha --check)
  fresh_token=$(extract_token "$out")
  [ -n "$fresh_token" ] || fail "changed external state did not produce a fresh token"
  out=$(run_remove "$home" alpha --confirm alpha --discard-authority "$fresh_token")
  code=$?
  expect_code 0 "$code" "authorized removal with external nested checkout"
  assert_absent "$home/projects/alpha" "authorized removal left the clone"
  assert_present "$home/external-parent/.git" "the external gitdir store was deleted"
  assert_present "$home/external-parent/external.txt" "external repository content was touched"
  pass "an external-gitdir nested repository is exact-authority inventory, never structural"
}

test_open_handle_refuses_at_deletion_boundary() {
  local home="$TMP_ROOT/open-handle" out code
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha

  exec 9< "$home/projects/alpha/README.md"
  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  exec 9<&-
  expect_code 1 "$code" "open handle refusal"
  assert_contains "$out" "open handle" "a held file handle was not detected at the deletion boundary"
  assert_contains "$out" "restored to" "the clone was not restored after the open-handle refusal"
  assert_present "$home/projects/alpha/README.md" "the open-handle refusal lost the clone"
  assert_grep '- alpha ' "$home/data/projects.md" "the open-handle refusal changed the registry"

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 0 "$code" "removal after handle release"
  assert_absent "$home/projects/alpha" "clone survived after the handle was released"
  pass "a live open handle blocks deletion and restores the clone intact"
}

test_dotted_project_names_are_valid() {
  local home="$TMP_ROOT/dotted" out code
  make_home "$home"
  make_landed_clone "$home" my.project
  add_registry "$home" my.project

  out=$(run_remove "$home" my.project --check)
  code=$?
  expect_code 0 "$code" "dotted name check"
  assert_contains "$out" "clean: removal of my.project" "dotted name was not accepted by --check"

  out=$(run_remove "$home" my.project --confirm my.project)
  code=$?
  expect_code 0 "$code" "dotted name removal"
  assert_absent "$home/projects/my.project" "dotted-name clone survived removal"
  assert_no_grep '- my.project ' "$home/data/projects.md" "dotted-name registry line survived"
  assert_no_grep 'names containing /, ., or .. are rejected' "$REMOVE" \
    "the helper header still documents dotted names as invalid"
  pass "dotted project names are valid end to end and documented as such"
}

test_instruction_contract_scopes_discard_authority() {
  assert_grep "discarding unlanded work outside the guarded project-removal path's exact captain-authorized inventory token" \
    "$ROOT/AGENTS.md" "prime directive does not recognize only the scoped project-removal token"
  pass "prime directive permits only exact token-authorized project discard"
}

test_scripts_catalog_allows_optional_registry() {
  assert_grep 'project clone with an optional registry entry' "$ROOT/docs/scripts.md" \
    "scripts catalog incorrectly requires a registry entry"
  assert_grep 'with or without a' "$ROOT/bin/fm-project-remove.sh" \
    "helper header incorrectly requires a registered clone"
  pass "script documentation treats the registry entry as optional"
}

test_linked_worktree_refuses_then_prunes_stale() {
  local home="$TMP_ROOT/worktree" out code wt_dir
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  wt_dir="$home/external-wt"
  git -C "$home/projects/alpha" worktree add --quiet --detach "$wt_dir"

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "linked worktree refusal"
  assert_contains "$out" "linked worktree" "existing linked worktree not inventoried"
  assert_present "$home/projects/alpha" "worktree refusal still removed the clone"
  assert_present "$wt_dir" "refusal touched the linked worktree"

  # The worktree directory disappears (e.g. crashed task cleanup): --check must
  # note the stale registration WITHOUT pruning it.
  rm -rf "$wt_dir"
  out=$(run_remove "$home" alpha --check)
  code=$?
  expect_code 0 "$code" "check with stale registration"
  assert_contains "$out" "stale worktree registration" "stale registration not noted"
  assert_present "$home/projects/alpha/.git/worktrees/external-wt" "--check pruned the stale registration"

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 0 "$code" "removal prunes stale registration"
  assert_absent "$home/projects/alpha" "clone survived removal after stale prune"
  pass "existing linked worktrees refuse; stale registrations are pruned only by the removal run"
}

test_traversal_and_bad_names_rejected() {
  local home="$TMP_ROOT/traversal" bad out code
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha

  for bad in '../evil' 'a/b' '.' '..' '-x' '/abs/path' 'name with space'; do
    out=$(run_remove "$home" "$bad" --check)
    code=$?
    expect_code 1 "$code" "bad name '$bad'"
    assert_contains "$out" "invalid project name" "bad name '$bad' was not rejected"
  done
  assert_present "$home/projects/alpha" "bad-name rejection touched an unrelated clone"
  pass "path traversal and malformed names are rejected before resolution"
}

test_symlinked_clone_and_projects_dir_refuse() {
  local home="$TMP_ROOT/symlink" home2="$TMP_ROOT/symlink2" out code
  make_home "$home"
  fm_git_init_commit "$TMP_ROOT/real-elsewhere"
  ln -s "$TMP_ROOT/real-elsewhere" "$home/projects/alpha"
  add_registry "$home" alpha

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "symlinked clone refusal"
  assert_contains "$out" "is a symlink" "symlinked clone not rejected"
  assert_present "$home/projects/alpha" "the symlink itself was removed"
  assert_present "$TMP_ROOT/real-elsewhere/README.md" "the symlink target was touched"
  assert_grep '- alpha ' "$home/data/projects.md" "symlink refusal mutated the registry"

  mkdir -p "$home2/data" "$home2/state"
  ln -s "$home/projects" "$home2/projects"
  out=$(run_remove "$home2" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "symlinked projects dir refusal"
  assert_contains "$out" "projects directory" "symlinked projects dir not rejected"
  pass "symlinked clones and projects directories refuse untouched"
}

test_gitfile_clone_refuses() {
  local home="$TMP_ROOT/gitfile" out code
  make_home "$home"
  fm_git_init_commit "$TMP_ROOT/parent-repo"
  git -C "$TMP_ROOT/parent-repo" worktree add --quiet --detach "$home/projects/alpha"
  add_registry "$home" alpha

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "gitfile clone refusal"
  assert_contains "$out" "gitfile" "gitfile clone not rejected"
  assert_present "$home/projects/alpha" "gitfile refusal still removed the directory"
  assert_grep '- alpha ' "$home/data/projects.md" "gitfile refusal mutated the registry"
  pass "a clone that is itself a linked worktree of another repository refuses"
}

test_partial_failure_leaves_registry_untouched() {
  local home="$TMP_ROOT/partial" out code preserved
  if [ "$(id -u)" -eq 0 ]; then
    pass "partial-failure refusal (skipped: root can always delete)"
    return 0
  fi
  make_home "$home"
  fm_git_init_commit "$home/src-alpha"
  mkdir -p "$home/src-alpha/sub"
  echo tracked > "$home/src-alpha/sub/f"
  git -C "$home/src-alpha" add sub/f
  git -C "$home/src-alpha" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "add sub"
  git clone --quiet --bare "$home/src-alpha" "$home/origin-alpha.git"
  git clone --quiet "file://$home/origin-alpha.git" "$home/projects/alpha" 2>/dev/null
  add_registry "$home" alpha
  chmod 555 "$home/projects/alpha/sub"

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  preserved=$(find "$home/projects" -path '*/.fm-project-remove-alpha.*/clone' -type d -print | head -1)
  [ -z "$preserved" ] || chmod 755 "$preserved/sub" 2>/dev/null || true
  expect_code 1 "$code" "partial failure refusal"
  assert_contains "$out" "removal incomplete" "partial removal not reported"
  [ -n "$preserved" ] || fail "partial deletion did not preserve the quarantined clone"
  assert_present "$preserved" "partial state unexpectedly fully removed"
  assert_grep '- alpha ' "$home/data/projects.md" "partial failure still mutated the registry"
  pass "a failed deletion stops loudly and never touches the registry"
}

test_stale_registry_repair_is_idempotent_and_loud() {
  local home="$TMP_ROOT/stale" out code
  make_home "$home"
  add_registry "$home" alpha
  add_registry "$home" beta

  out=$(run_remove "$home" alpha --check)
  code=$?
  expect_code 0 "$code" "check on stale registry"
  assert_contains "$out" "stale registry" "stale registry not reported by check"
  assert_grep '- alpha ' "$home/data/projects.md" "check repaired the registry"

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 0 "$code" "stale registry repair"
  assert_contains "$out" "repaired stale registry" "repair not reported"
  assert_no_grep '- alpha ' "$home/data/projects.md" "stale alpha line survived repair"
  assert_grep '- beta ' "$home/data/projects.md" "repair disturbed an unrelated line"

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "second repair run"
  assert_contains "$out" "nothing to remove" "a repeated run reported success for a possible typo"
  pass "stale-registry repair converges and a repeat fails loudly"
}

test_unregistered_clone_removed_with_notice() {
  local home="$TMP_ROOT/unreg" home2="$TMP_ROOT/unreg2" out code
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" beta

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 0 "$code" "unregistered clone removal"
  assert_contains "$out" "no registry line existed" "unregistered removal did not note the registry gap"
  assert_absent "$home/projects/alpha" "unregistered clone survived"
  assert_grep '- beta ' "$home/data/projects.md" "unrelated registry line disturbed"

  make_home "$home2"
  make_landed_clone "$home2" alpha
  out=$(run_remove "$home2" alpha --confirm alpha)
  code=$?
  expect_code 0 "$code" "removal with no registry file"
  assert_absent "$home2/projects/alpha" "clone survived with no registry file"
  pass "an unregistered clone is removed with a notice"
}

test_gate_agent_is_refused() {
  local home="$TMP_ROOT/gate" out code
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha

  out=$(FM_HOME="$home" FM_GATE_REFUSE_BYPASS='' NO_MISTAKES_GATE=1 "$REMOVE" alpha --confirm alpha 2>&1)
  code=$?
  expect_code 3 "$code" "gate refusal"
  assert_contains "$out" "gate agent" "gate refusal message missing"
  assert_present "$home/projects/alpha" "gate agent removed the clone"
  assert_grep '- alpha ' "$home/data/projects.md" "gate agent mutated the registry"
  pass "a no-mistakes gate agent is refused before any mutation"
}

test_clean_removal_and_registry_consistency
test_check_is_read_only_on_clean_clone
test_confirm_required_and_exact
test_dirty_refusal_and_scoped_discard_flow
test_discard_authority_is_project_scoped
test_ignored_and_nested_repository_state_is_scoped
test_clean_submodule_git_state_is_scoped
test_unpushed_branch_and_stash_refuse
test_no_remote_repository_refuses_then_discards
test_live_task_metadata_refuses_structurally
test_open_backlog_items_refuse
test_secondmate_registered_clone_refuses
test_linked_worktree_refuses_then_prunes_stale
test_traversal_and_bad_names_rejected
test_symlinked_clone_and_projects_dir_refuse
test_gitfile_clone_refuses
test_partial_failure_leaves_registry_untouched
test_stale_registry_repair_is_idempotent_and_loud
test_unregistered_clone_removed_with_notice
test_gate_agent_is_refused
test_active_home_roots_cannot_be_overridden
test_root_override_cannot_hide_running_checkout
test_state_enumeration_failure_refuses_closed
test_transaction_lock_and_final_inventory_recheck
test_git_inspection_failures_refuse_closed
test_sha256_is_required_and_full_length
test_registry_rewrite_uses_secure_temp
test_interrupted_quarantine_never_stale_repairs
test_invalid_git_named_entries_stay_discardable
test_external_nested_repository_is_discardable_inventory
test_open_handle_refuses_at_deletion_boundary
test_dotted_project_names_are_valid
test_instruction_contract_scopes_discard_authority
test_scripts_catalog_allows_optional_registry

echo "all fm-project-remove tests passed"
