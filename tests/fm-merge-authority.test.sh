#!/usr/bin/env bash
# Tests for the durable merge-authority contract owned by
# bin/fm-merge-authority-lib.sh: a task dispatched with fm-spawn.sh --no-merge
# records merge=blocked, and every firstmate merge action refuses it.
#
# The regression this locks down: an explicit "do not merge" constraint used to
# exist only as prose in the crewmate brief. No script could read it, so
# bin/fm-pr-merge.sh would land any task/PR pair it was handed. These cases
# prove the constraint cannot be bypassed by the three things that legitimately
# happen around a finished lane and that all used to look like permission -
# observing the pull request, polling its state, and validation completing green
# - while a captain-authorized merge still works.
#
# Matrix:
#   (a) --no-merge records merge=blocked in the task's meta
#   (b) an ordinary spawn records no merge= field at all (back-compat)
#   (c) fm-pr-merge refuses a merge=blocked task before recording or merging
#   (d) validation completing green + yolo=on does not lift the block
#   (e) observing an already-merged pull request does not lift the block
#   (f) the merge poll only observes: it never invokes any merge command
#   (g) fm-pr-check preserves merge=blocked while arming the poll
#   (h) --captain-authorized lifts the block and merges
#   (i) an unrecognized merge= value refuses rather than defaulting to allowed
#   (j) a task with no merge= field still merges normally
#   (k) fm-merge-local refuses a merge=blocked local-only task before touching git
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_POLL="$ROOT/bin/fm-pr-poll.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-authority-tests)

# One sandbox: a state dir holding a task meta plus a fakebin whose gh-axi and
# gh mocks log every invocation, so "was a merge attempted at all" is decidable
# from the log rather than from the script's exit code.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/wt" "$fakebin"
  shift
  fm_write_meta "$case_dir/state/task-nm.meta" \
    "window=fm-task-nm" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "$@"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *headRefOid*) printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; exit 0 ;;
      *state*) printf '%s\n' "${FM_TEST_PR_STATE:-OPEN}"; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"
  printf '%s\n' "$case_dir"
}

run_pr_merge() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

run_pr_check() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

# Assert that no merge was attempted through either forge CLI in this sandbox.
assert_no_merge_attempted() {
  local case_dir=$1 label=$2
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "$label: gh-axi pr merge was invoked for a blocked task"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "$label: gh pr merge was invoked for a blocked task"
}

# --- (a)(b) fm-spawn records the constraint ---------------------------------

# fm-spawn's meta writer is exercised directly rather than through a real
# backend launch: the contract under test is which lines land in the meta, and a
# full spawn would drag in a terminal backend this suite does not need.
test_spawn_flag_records_blocked() {
  local out
  out=$("$ROOT/bin/fm-spawn.sh" --help)
  assert_contains "$out" "--no-merge records merge=blocked" \
    "spawn-usage: --help does not document --no-merge"
  assert_contains "$out" "bin/fm-merge-authority-lib.sh owns the field" \
    "spawn-usage: --help does not point at the merge-authority owner"
  grep -qF -- '--no-merge) MERGE_AUTHORITY=blocked ;;' "$ROOT/bin/fm-spawn.sh" \
    || fail "spawn-flag: fm-spawn.sh does not map --no-merge to merge=blocked"
  # shellcheck disable=SC2016  # Literal source line being asserted, not an expansion.
  grep -qF -- '[ -z "$MERGE_AUTHORITY" ] || echo "merge=$MERGE_AUTHORITY"' "$ROOT/bin/fm-spawn.sh" \
    || fail "spawn-meta: fm-spawn.sh does not write merge= into the task meta"
  pass "fm-spawn --no-merge records merge=blocked in the task meta"
}

test_ordinary_spawn_records_no_merge_field() {
  # The writer is guarded on a non-empty MERGE_AUTHORITY, which starts empty, so
  # an ordinary spawn's meta is byte-identical to before this field existed and
  # every task dispatched earlier keeps merging normally (case j proves the
  # read side of the same back-compat).
  grep -qF 'MERGE_AUTHORITY=' "$ROOT/bin/fm-spawn.sh" \
    || fail "spawn-default: fm-spawn.sh does not initialize MERGE_AUTHORITY"
  local init
  init=$(grep -c '^MERGE_AUTHORITY=$' "$ROOT/bin/fm-spawn.sh")
  [ "$init" = 1 ] || fail "spawn-default: MERGE_AUTHORITY must default to empty exactly once"
  pass "an ordinary fm-spawn writes no merge= field, so existing tasks are unaffected"
}

# --- (c) the core refusal ---------------------------------------------------

test_blocked_task_refuses_before_recording() {
  local case_dir rc
  case_dir=$(make_case blocked-refuses "merge=blocked")

  set +e
  run_pr_merge "$case_dir" task-nm https://github.com/example/repo/pull/167 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "blocked-refuses: fm-pr-merge should refuse a merge=blocked task"
  assert_grep 'REFUSED: task task-nm was dispatched with merge=blocked' "$case_dir/stderr" \
    "blocked-refuses: refusal did not name the recorded constraint"
  assert_no_merge_attempted "$case_dir" blocked-refuses
  assert_no_grep 'pr=https://github.com/example/repo/pull/167' "$case_dir/state/task-nm.meta" \
    "blocked-refuses: a blocked merge attempt still recorded pr= in the task meta"
  assert_absent "$case_dir/state/task-nm.check.sh" \
    "blocked-refuses: a blocked merge attempt still armed a merge poll"
  pass "fm-pr-merge refuses a merge=blocked task before recording, arming, or merging"
}

# --- (d)(e) the three things that used to look like permission --------------

test_validation_completion_and_yolo_do_not_lift_block() {
  local case_dir rc
  case_dir=$(make_case validation-green "merge=blocked" "yolo=on")
  # The exact shape of a finished no-mistakes lane: standing routine autonomy,
  # a green pipeline, and a done status. None of it is the captain's decision.
  printf 'done: PR https://github.com/example/repo/pull/167 checks green\n' \
    > "$case_dir/state/task-nm.status"

  set +e
  run_pr_merge "$case_dir" task-nm https://github.com/example/repo/pull/167 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "validation-green: yolo=on plus a green done status must not lift the block"
  assert_grep 'Green checks, a completed validation run, and an already-merged pull request do not lift this' \
    "$case_dir/stderr" "validation-green: refusal did not state what does not lift the block"
  assert_no_merge_attempted "$case_dir" validation-green
  pass "validation completing green under yolo=on does not lift a recorded merge block"
}

test_observed_merged_state_does_not_lift_block() {
  local case_dir rc
  case_dir=$(make_case observed-merged "merge=blocked")
  # Everything downstream can now see the pull request as merged. Observation of
  # a merged state is not authority to perform a merge.
  export FM_TEST_PR_STATE=MERGED

  set +e
  run_pr_merge "$case_dir" task-nm https://github.com/example/repo/pull/167 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_PR_STATE

  expect_code 1 "$rc" "observed-merged: an observed merged state must not lift the block"
  assert_no_merge_attempted "$case_dir" observed-merged
  pass "observing an already-merged pull request does not lift a recorded merge block"
}

# --- (f) the polling path is observation only -------------------------------

test_merge_poll_never_merges() {
  local case_dir out rc
  case_dir=$(make_case poll-observes "merge=blocked")
  export FM_TEST_PR_STATE=MERGED

  set +e
  out=$(FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
        FM_TEST_GH_LOG="$case_dir/gh.log" \
        PATH="$case_dir/fakebin:$PATH" \
        "$PR_POLL" --validated github https://github.com/example/repo/pull/167 github.com example/repo 167 2>&1)
  rc=$?
  set -e
  unset FM_TEST_PR_STATE

  expect_code 0 "$rc" "poll-observes: the merge poll should exit cleanly"
  [ "$out" = merged ] || fail "poll-observes: the poll should report exactly 'merged', got '$out'"
  assert_no_merge_attempted "$case_dir" poll-observes
  assert_grep 'pr view' "$case_dir/gh.log" \
    "poll-observes: the poll did not read the pull request state through gh pr view"
  pass "the merge poll reports a merged pull request without ever invoking a merge"
}

# --- (g) arming the poll must not drop the constraint -----------------------

test_pr_check_preserves_merge_block() {
  local case_dir rc
  case_dir=$(make_case check-preserves "merge=blocked")

  set +e
  run_pr_check "$case_dir" task-nm https://github.com/example/repo/pull/167 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "check-preserves: fm-pr-check should arm the poll for a blocked task"
  assert_grep 'merge=blocked' "$case_dir/state/task-nm.meta" \
    "check-preserves: arming the merge poll dropped merge=blocked from the task meta"
  assert_grep 'pr=https://github.com/example/repo/pull/167' "$case_dir/state/task-nm.meta" \
    "check-preserves: fm-pr-check did not record pr="

  # And the still-blocked task remains unmergeable after the poll is armed.
  set +e
  run_pr_merge "$case_dir" task-nm https://github.com/example/repo/pull/167 \
    > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 1 "$rc" "check-preserves: the task should still refuse to merge after arming"
  assert_no_merge_attempted "$case_dir" check-preserves
  pass "arming the merge poll preserves merge=blocked and the task stays unmergeable"
}

# --- (h) the legitimate captain-authorized merge still works ----------------

test_captain_authorized_merge_lands() {
  local case_dir rc
  case_dir=$(make_case captain-authorized "merge=blocked")

  set +e
  run_pr_merge "$case_dir" --captain-authorized task-nm https://github.com/example/repo/pull/167 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "captain-authorized: an authorized merge should succeed"
  assert_grep 'lifted by explicit captain authorization' "$case_dir/stderr" \
    "captain-authorized: the lifted block was not reported"
  grep -qxF 'pr merge 167 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "captain-authorized: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  assert_grep 'pr=https://github.com/example/repo/pull/167' "$case_dir/state/task-nm.meta" \
    "captain-authorized: pr= was not recorded"
  pass "an explicit --captain-authorized merge lifts the block and lands normally"
}

# --- (i)(j) fail closed on garbage, stay open on absence --------------------

test_unrecognized_authority_refuses() {
  local case_dir rc
  case_dir=$(make_case unrecognized "merge=probably-fine")

  set +e
  run_pr_merge "$case_dir" task-nm https://github.com/example/repo/pull/167 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unrecognized: an unknown merge authority should refuse"
  assert_grep 'unrecognized merge authority' "$case_dir/stderr" \
    "unrecognized: refusal did not name the unreadable authority"
  assert_no_merge_attempted "$case_dir" unrecognized
  pass "an unrecognized merge= value refuses instead of defaulting to permission"
}

test_absent_authority_still_merges() {
  local case_dir rc
  case_dir=$(make_case absent-authority)

  set +e
  run_pr_merge "$case_dir" task-nm https://github.com/example/repo/pull/167 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "absent-authority: a task with no merge= field should merge normally"
  grep -qxF 'pr merge 167 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "absent-authority: gh-axi pr merge was not invoked"
  pass "a task with no recorded merge authority merges exactly as before"
}

# --- (k) the local landing path honors the same field -----------------------

test_merge_local_refuses_blocked_task() {
  local case_dir rc proj
  case_dir="$TMP_ROOT/merge-local-blocked"
  proj="$case_dir/project"
  mkdir -p "$case_dir/state" "$proj"
  git -C "$proj" init --quiet --initial-branch=main
  printf 'seed\n' > "$proj/seed.txt"
  git -C "$proj" add seed.txt
  git -C "$proj" commit --quiet -m "seed"
  git -C "$proj" checkout --quiet -b fm/task-nm
  printf 'work\n' > "$proj/work.txt"
  git -C "$proj" add work.txt
  git -C "$proj" commit --quiet -m "work"
  git -C "$proj" checkout --quiet main
  fm_write_meta "$case_dir/state/task-nm.meta" \
    "window=fm-task-nm" \
    "worktree=$proj" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only" \
    "merge=blocked"
  local before
  before=$(git -C "$proj" rev-parse main)

  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-nm > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-local-blocked: fm-merge-local should refuse a merge=blocked task"
  assert_grep 'REFUSED: task task-nm was dispatched with merge=blocked' "$case_dir/stderr" \
    "merge-local-blocked: refusal did not name the recorded constraint"
  [ "$(git -C "$proj" rev-parse main)" = "$before" ] \
    || fail "merge-local-blocked: the default branch advanced despite the refusal"

  # The same task lands once the captain authorizes it.
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" --captain-authorized task-nm > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 0 "$rc" "merge-local-blocked: an authorized local merge should succeed"
  [ "$(git -C "$proj" rev-parse main)" != "$before" ] \
    || fail "merge-local-blocked: the authorized local merge did not advance the default branch"
  pass "fm-merge-local refuses a blocked task before touching git and lands once authorized"
}

test_spawn_flag_records_blocked
test_ordinary_spawn_records_no_merge_field
test_blocked_task_refuses_before_recording
test_validation_completion_and_yolo_do_not_lift_block
test_observed_merged_state_does_not_lift_block
test_merge_poll_never_merges
test_pr_check_preserves_merge_block
test_captain_authorized_merge_lands
test_unrecognized_authority_refuses
test_absent_authority_still_merges
test_merge_local_refuses_blocked_task
