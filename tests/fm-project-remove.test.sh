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
#   (d) dirty/untracked work refuses with a state-scoped discard token; a token
#       issued before the inventory changed refuses; a fresh token discards
#   (e) a discard token minted for another project, or garbage, never
#       authorizes this project
#   (f) unpushed branches and stashes refuse as unlanded work
#   (g) a repository with no remote refuses (all commits local-only) until
#       explicit discard authority is presented
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
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity

REMOVE="$ROOT/bin/fm-project-remove.sh"
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
  pass "clean removal deletes the clone then drops exactly its registry line"
}

test_check_is_read_only_on_clean_clone() {
  local home="$TMP_ROOT/check-clean" out code
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha

  out=$(run_remove "$home" alpha --check)
  code=$?
  expect_code 0 "$code" "clean check"
  assert_contains "$out" "clean: removal of alpha would proceed" "check did not report clean"
  assert_present "$home/projects/alpha" "check removed the clone"
  assert_grep '- alpha ' "$home/data/projects.md" "check mutated the registry"

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
  pass "removal demands an exact --confirm of the project name"
}

test_dirty_refusal_and_scoped_discard_flow() {
  local home="$TMP_ROOT/dirty" out code token stale_token fresh_token
  make_home "$home"
  make_landed_clone "$home" alpha
  add_registry "$home" alpha
  echo extra > "$home/projects/alpha/untracked.txt"
  echo edit >> "$home/projects/alpha/README.md"

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "dirty refusal"
  assert_contains "$out" "dirty or untracked" "dirty work not inventoried"
  assert_contains "$out" "discard-unlanded:alpha:" "no discard token offered for discardable-only refusal"
  assert_present "$home/projects/alpha" "dirty refusal still removed the clone"
  token=$(extract_token "$out")
  [ -n "$token" ] || fail "could not extract discard token"

  # The inventory changes; the old token must refuse.
  echo more > "$home/projects/alpha/second.txt"
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
  pass "discard authority is state-scoped: stale tokens refuse, the exact token discards"
}

test_discard_authority_is_project_scoped() {
  local home="$TMP_ROOT/scope" out code beta_token
  make_home "$home"
  make_landed_clone "$home" alpha
  make_landed_clone "$home" beta
  add_registry "$home" alpha
  add_registry "$home" beta
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
  pass "discard authority never transfers across projects or accepts prose"
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
  local home="$TMP_ROOT/local-only" out code token
  make_home "$home"
  fm_git_init_commit "$home/projects/gamma"
  add_registry "$home" gamma

  out=$(run_remove "$home" gamma --confirm gamma)
  code=$?
  expect_code 1 "$code" "local-only refusal"
  assert_contains "$out" "exists only locally" "local-only commits not inventoried"
  assert_present "$home/projects/gamma" "local-only refusal still removed the clone"

  token=$(extract_token "$out")
  [ -n "$token" ] || fail "no token for local-only inventory"
  out=$(run_remove "$home" gamma --confirm gamma --discard-authority "$token")
  code=$?
  expect_code 0 "$code" "authorized local-only removal"
  assert_absent "$home/projects/gamma" "authorized local-only removal left the clone"
  pass "a repository with no remote refuses until explicit discard authority"
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
- other - Other domain (home: $TMP_ROOT/nonexistent-other-home; scope: other work; projects: beta; added 2026-07-21)
EOF

  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 1 "$code" "secondmate refusal"
  assert_contains "$out" "secondmate design registers a clone of alpha" "secondmate clone not inventoried"
  assert_not_contains "$out" "secondmate other" "unrelated secondmate wrongly blocked removal"
  assert_present "$home/projects/alpha" "secondmate refusal still removed the clone"

  grep -v '^- design ' "$home/data/secondmates.md" > "$home/data/secondmates.md.new"
  mv "$home/data/secondmates.md.new" "$home/data/secondmates.md"
  out=$(run_remove "$home" alpha --confirm alpha)
  code=$?
  expect_code 0 "$code" "removal after secondmate deregistration"
  pass "a secondmate-registered clone blocks removal until deregistered"
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
  local home="$TMP_ROOT/partial" out code
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
  chmod 755 "$home/projects/alpha/sub" 2>/dev/null || true
  expect_code 1 "$code" "partial failure refusal"
  assert_contains "$out" "removal incomplete" "partial removal not reported"
  assert_present "$home/projects/alpha" "partial state unexpectedly fully removed"
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

echo "all fm-project-remove tests passed"
