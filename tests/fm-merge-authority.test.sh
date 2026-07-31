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
#   (l) an unreadable task meta refuses instead of reading as "no constraint"
#   (m) a metadata read error refuses instead of reading as "no constraint"
#   (n) a valueless merge= field refuses instead of reading as an absent field
#   (o) a metadata rewrite carries a recorded constraint forward, and only an
#       explicit lift on that invocation clears it
#   (p) a recovery respawn that omits --no-merge keeps the block, an explicit
#       fm-spawn --captain-authorized lifts it, and an unreadable existing
#       record refuses the respawn outright
#   (q) a recovery that continues the lane under a SUCCESSOR task id carries the
#       predecessor's block through --carry-merge-from, refuses when that record
#       cannot be read, and never doubles as a lift
#   (r) the launch meta is published atomically, so a torn rewrite cannot leave a
#       record whose missing merge= line reads as permission
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_POLL="$ROOT/bin/fm-pr-poll.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-authority-tests)

# The respawn cases below drive fm-spawn with an explicit pi harness, and a Pi
# crewmate launch refuses before the missing-brief check when the installed
# pi-dynamic-workflows extension is absent. Pin it to a sandbox fixture so the
# refusal these cases decide on is the merge one on every machine.
PI_WORKFLOW_FIXTURE="$TMP_ROOT/pi-dynamic-workflows/extensions/workflow.ts"
mkdir -p "$(dirname "$PI_WORKFLOW_FIXTURE")"
: > "$PI_WORKFLOW_FIXTURE"

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

# --- (l)(m) an unreadable record is not permission ---------------------------

# The dangerous shape is a meta the invoking user cannot read: the recorded value
# might be blocked, and "I could not look" must never resolve to "allowed".
test_unreadable_meta_refuses() {
  local case_dir rc
  case_dir=$(make_case unreadable-meta)
  if [ "$(id -u)" -eq 0 ]; then
    pass "unreadable-meta: skipped, root bypasses file permissions"
    return 0
  fi
  # No merge= line at all, so an unreadable record that fell back to the absent
  # default would merge; only a read-failure refusal keeps this task unmerged.
  chmod 000 "$case_dir/state/task-nm.meta"

  set +e
  run_pr_merge "$case_dir" task-nm https://github.com/example/repo/pull/167 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 600 "$case_dir/state/task-nm.meta"

  expect_code 1 "$rc" "unreadable-meta: an unreadable task meta must refuse to merge"
  assert_grep 'merge authority for task task-nm could not be read' "$case_dir/stderr" \
    "unreadable-meta: refusal did not name the unreadable authority"
  assert_no_merge_attempted "$case_dir" unreadable-meta
  pass "an unreadable task meta refuses instead of defaulting to permission"
}

# A transient read error reaches the library as grep status 2. It is provoked with
# a grep shim because a real I/O error is not reproducible, and it is the same
# status a root-owned or failing-disk meta produces.
test_meta_read_error_refuses() {
  local case_dir rc fakebin
  case_dir=$(make_case read-error "merge=blocked")
  fakebin="$case_dir/readfail"
  mkdir -p "$fakebin"
  cat > "$fakebin/grep" <<'SH'
#!/usr/bin/env bash
exit 2
SH
  chmod +x "$fakebin/grep"

  set +e
  PATH="$fakebin:$PATH" bash -c '
    set -u
    . "$1"
    fm_merge_authority_check "$2" task-nm 0
  ' bash "$ROOT/bin/fm-merge-authority-lib.sh" "$case_dir/state/task-nm.meta" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "read-error: a metadata read error must refuse to merge"
  assert_grep 'merge authority for task task-nm could not be read' "$case_dir/stderr" \
    "read-error: a failed read was reported as something other than unreadable"
  pass "a metadata read error refuses instead of reading as an absent constraint"
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

# --- (n) a truncated field is corruption, not absence ------------------------

# The meta is written with a plain redirect, so a full disk or a crash can leave
# the line as a bare "merge=". No writer produces that, and reading it as the
# absent-field default would merge a task whose recorded value was blocked.
test_valueless_authority_refuses() {
  local case_dir rc
  case_dir=$(make_case valueless "merge=")

  set +e
  run_pr_merge "$case_dir" task-nm https://github.com/example/repo/pull/167 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "valueless: a merge= line with no value must refuse"
  assert_grep 'merge authority for task task-nm could not be read' "$case_dir/stderr" \
    "valueless: a truncated field was not reported as unreadable"
  assert_no_merge_attempted "$case_dir" valueless
  pass "a valueless merge= field refuses instead of reading as an absent field"
}

# --- (o) what one metadata rewrite must record ------------------------------

run_resolve() {
  bash -c '
    set -u
    . "$1"
    fm_merge_authority_resolve "$2" "$3" "$4"
  ' bash "$ROOT/bin/fm-merge-authority-lib.sh" "$1" "$2" "$3"
}

# Every launch rewrites the whole meta, so the rewrite rule - not the caller's
# flags - is what makes the constraint durable. Each row:
#   <label>|<recorded merge line or "-">|<requested>|<lift 0|1>|<expected exit>|<expected value>
test_rewrite_carries_constraint_forward() {
  local label recorded requested lift code expected dir meta out rc
  while IFS='|' read -r label recorded requested lift code expected; do
    [ -n "$label" ] || continue
    dir="$TMP_ROOT/resolve-$label"
    mkdir -p "$dir"
    meta="$dir/task-nm.meta"
    if [ "$recorded" = - ]; then
      rm -f "$meta"
    else
      fm_write_meta "$meta" "kind=ship" "$recorded"
    fi
    set +e
    out=$(run_resolve "$meta" "$requested" "$lift")
    rc=$?
    set -e
    expect_code "$code" "$rc" "resolve-$label"
    [ "$code" != 0 ] || [ "$out" = "$expected" ] \
      || fail "resolve-$label: expected '$expected', got '$out'"
  done <<'ROWS'
respawn-without-flag-keeps-block|merge=blocked||0|0|blocked
respawn-with-flag-keeps-block|merge=blocked|blocked|0|0|blocked
explicit-lift-clears-block|merge=blocked||1|0|allowed
unrecognized-value-carried|merge=probably-fine||0|0|probably-fine
recorded-allowed-needs-no-line|merge=allowed||0|0|
fresh-spawn-records-nothing|-||0|0|
fresh-spawn-records-request|-|blocked|0|0|blocked
valueless-record-refuses|merge=||0|1|
ROWS

  # A carried value must still be the value the merge actions refuse on, and a
  # lifted one must be the value they accept.
  local blocked_dir allowed_dir
  blocked_dir=$(make_case resolve-carried "merge=blocked")
  set +e
  run_pr_merge "$blocked_dir" task-nm https://github.com/example/repo/pull/167 \
    > "$blocked_dir/stdout" 2> "$blocked_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "resolve-carried: a carried-forward block must still refuse"
  allowed_dir=$(make_case resolve-lifted "merge=allowed")
  set +e
  run_pr_merge "$allowed_dir" task-nm https://github.com/example/repo/pull/167 \
    > "$allowed_dir/stdout" 2> "$allowed_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "resolve-lifted: a recorded lift must merge normally"
  pass "a metadata rewrite carries a recorded constraint forward and only an explicit lift clears it"
}

# --- (p) the respawn path is wired to that rule -----------------------------

# fm-spawn is driven for real here, but stops at its missing-brief check, which
# is reached after the merge authority is resolved and before any backend,
# worktree, or meta write. So the resolution the respawn would publish is
# decidable from stderr without creating a window.
run_spawn_respawn() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    FM_BACKEND=tmux \
    FM_PI_DYNAMIC_WORKFLOWS_EXTENSION="${FM_TEST_PI_WORKFLOW_EXTENSION:-$PI_WORKFLOW_FIXTURE}" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

test_respawn_keeps_block_until_explicitly_lifted() {
  local home meta out rc
  home="$TMP_ROOT/respawn-home"
  mkdir -p "$home/state" "$home/data" "$home/projects/alpha"
  meta="$home/state/task-respawn-r7.meta"
  fm_write_meta "$meta" \
    "window=fm-task-respawn-r7" \
    "worktree=$home/projects/alpha" \
    "project=$home/projects/alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "merge=blocked"

  # The stuck-crewmate recovery shape: the same id relaunched with a different
  # harness and no --no-merge. Omitting the flag is not a captain decision.
  set +e
  out=$(run_spawn_respawn "$home" task-respawn-r7 projects/alpha pi)
  rc=$?
  set -e
  expect_code 1 "$rc" "respawn: the spawn should still stop at the missing brief"
  assert_contains "$out" 'already records merge=blocked; carrying that constraint onto this launch' \
    "respawn: a recovery respawn without --no-merge dropped the recorded merge block"

  # Only the explicit lift clears it.
  set +e
  out=$(run_spawn_respawn "$home" task-respawn-r7 projects/alpha pi --captain-authorized)
  rc=$?
  set -e
  expect_code 1 "$rc" "respawn-lift: the spawn should still stop at the missing brief"
  assert_contains "$out" 'lifted by explicit captain authorization' \
    "respawn-lift: --captain-authorized did not lift the recorded block"

  # Contradictory intents are refused rather than silently ordered.
  set +e
  out=$(run_spawn_respawn "$home" task-respawn-r7 projects/alpha pi --no-merge --captain-authorized)
  rc=$?
  set -e
  expect_code 1 "$rc" "respawn-both: passing both merge flags must be refused"
  assert_contains "$out" '--no-merge and --captain-authorized contradict each other' \
    "respawn-both: contradictory merge flags were accepted"

  # An existing record that cannot be read refuses the respawn instead of being
  # rewritten as permission.
  fm_write_meta "$meta" "kind=ship" "merge="
  set +e
  out=$(run_spawn_respawn "$home" task-respawn-r7 projects/alpha pi)
  rc=$?
  set -e
  expect_code 1 "$rc" "respawn-unreadable: an unreadable merge record must refuse the respawn"
  assert_contains "$out" 'records a merge authority that cannot be read' \
    "respawn-unreadable: an unreadable merge record was rewritten instead of refusing"
  assert_not_contains "$out" 'no brief at' \
    "respawn-unreadable: the refusal came after the spawn had already proceeded"
  pass "a recovery respawn keeps merge=blocked, only an explicit lift clears it, and an unreadable record refuses"
}

# --- (q)(r) the successor-id recovery shape and atomic publication ----------

# These two cases need a spawn that runs all the way through metadata
# publication, so the fake tmux from tests/fm-spawn-dispatch-profile.test.sh is
# reused here: it answers the container/window sequence and swallows the typed
# launch command, and the worktree is a real isolated git worktree reported
# through the pane path. Nothing real is launched.
make_full_spawn_case() {  # <name> <task-id>... -> echoes <home>|<proj>|<fakebin>
  local name=$1 case_dir home proj wt fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$home|$proj|$wt|$fakebin"
}

read_full_spawn_case() {
  IFS='|' read -r FULL_HOME FULL_PROJ FULL_WT FULL_FAKEBIN <<EOF
$1
EOF
}

run_full_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$FULL_HOME" \
    FM_STATE_OVERRIDE="$FULL_HOME/state" FM_DATA_OVERRIDE="$FULL_HOME/data" \
    FM_PROJECTS_OVERRIDE="$FULL_HOME/projects" FM_CONFIG_OVERRIDE="$FULL_HOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$FULL_WT" TMUX="fake,1,0" \
    FM_BACKEND=tmux CLAUDE_CONFIG_DIR='' PATH="$FULL_FAKEBIN:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

# The refusal both merge actions apply, asked directly of one published meta.
assert_meta_refuses_merge() {
  local meta=$1 id=$2 label=$3 rc=0 err
  err="$meta.refusal"
  set +e
  bash -c '
    set -u
    . "$1"
    fm_merge_authority_check "$2" "$3" 0
  ' bash "$ROOT/bin/fm-merge-authority-lib.sh" "$meta" "$id" > /dev/null 2> "$err"
  rc=$?
  set -e
  expect_code 1 "$rc" "$label: the published meta did not refuse a merge"
  assert_grep "REFUSED: task $id was dispatched with merge=blocked" "$err" \
    "$label: the refusal did not name the carried constraint"
}

test_successor_task_id_carries_predecessor_block() {
  local rec out rc pred succ pred_meta succ_meta
  pred='pred-lane-a1'
  succ='succ-lane-b2'
  rec=$(make_full_spawn_case successor-carry "$pred" "$succ")
  read_full_spawn_case "$rec"
  pred_meta="$FULL_HOME/state/$pred.meta"
  succ_meta="$FULL_HOME/state/$succ.meta"

  out=$(run_full_spawn "$pred" "$FULL_PROJ" --no-merge)
  rc=$?
  expect_code 0 "$rc" "successor-carry: the predecessor spawn should succeed"$'\n'"$out"
  assert_grep 'merge=blocked' "$pred_meta" \
    "successor-carry: the predecessor spawn did not record the block"

  # The shape bin/fm-x-link.sh documents: the SAME request continues on a new
  # task id. The successor's meta is fresh, so without an explicit carry the
  # captain's constraint would simply be gone.
  out=$(run_full_spawn "$succ" "$FULL_PROJ" --carry-merge-from "$pred")
  rc=$?
  expect_code 0 "$rc" "successor-carry: the successor spawn should succeed"$'\n'"$out"
  assert_contains "$out" "carrying merge=blocked from predecessor task $pred onto $succ" \
    "successor-carry: the carried constraint was not reported"
  assert_grep 'merge=blocked' "$succ_meta" \
    "successor-carry: the successor's published meta dropped the predecessor's block"
  assert_meta_refuses_merge "$succ_meta" "$succ" successor-carry
  pass "a recovery successor task id carries the predecessor's merge block onto its own meta"
}

test_successor_carry_of_unconstrained_lane_records_nothing() {
  local rec out rc pred succ
  pred='open-lane-c3'
  succ='open-succ-d4'
  rec=$(make_full_spawn_case successor-carry-open "$pred" "$succ")
  read_full_spawn_case "$rec"

  out=$(run_full_spawn "$pred" "$FULL_PROJ")
  rc=$?
  expect_code 0 "$rc" "successor-carry-open: the predecessor spawn should succeed"$'\n'"$out"

  # Carrying from an unconstrained lane must stay byte-identical to an ordinary
  # spawn: the carry moves a recorded constraint, it does not invent one.
  out=$(run_full_spawn "$succ" "$FULL_PROJ" --carry-merge-from "$pred")
  rc=$?
  expect_code 0 "$rc" "successor-carry-open: the successor spawn should succeed"$'\n'"$out"
  assert_not_contains "$out" 'carrying merge=' \
    "successor-carry-open: an unconstrained predecessor reported a carried constraint"
  assert_no_grep 'merge=' "$FULL_HOME/state/$succ.meta" \
    "successor-carry-open: carrying from an unconstrained lane wrote a merge= field"
  pass "carrying from a lane with no recorded constraint records no merge= field"
}

# The dangerous rewrite is the one that never finishes: a plain redirect
# truncates the live meta first, so a crash or a full disk between the first line
# and merge= leaves a record that parses cleanly and, with merge= gone, reads as
# permission. Publication is therefore staged and renamed. A hard link taken
# before the respawn still names the OLD inode afterwards, which is only true if
# the record was replaced rather than rewritten in place.
test_launch_meta_is_published_atomically() {
  local rec out rc id meta snapshot before leftover
  id='atomic-meta-e5'
  rec=$(make_full_spawn_case atomic-meta "$id")
  read_full_spawn_case "$rec"
  meta="$FULL_HOME/state/$id.meta"

  out=$(run_full_spawn "$id" "$FULL_PROJ" --no-merge)
  rc=$?
  expect_code 0 "$rc" "atomic-meta: the first spawn should succeed"$'\n'"$out"
  assert_grep 'merge=blocked' "$meta" "atomic-meta: the first spawn did not record the block"
  snapshot="$FULL_HOME/state/link-snapshot"
  ln "$meta" "$snapshot"
  before=$(cat "$snapshot")

  out=$(run_full_spawn "$id" "$FULL_PROJ")
  rc=$?
  expect_code 0 "$rc" "atomic-meta: the respawn should succeed"$'\n'"$out"

  [ ! "$meta" -ef "$snapshot" ] \
    || fail "atomic-meta: the respawn rewrote the live meta in place instead of renaming a staged record over it"
  [ "$(cat "$snapshot")" = "$before" ] \
    || fail "atomic-meta: the previous record was mutated by the respawn"
  assert_grep 'merge=blocked' "$meta" "atomic-meta: the republished meta dropped the carried block"
  leftover=$(find "$FULL_HOME/state" -maxdepth 1 -name '.*.meta.fm-spawn.*' | wc -l | tr -d ' ')
  [ "$leftover" = 0 ] \
    || fail "atomic-meta: publication left $leftover staged meta file(s) behind in state/"
  pass "the launch meta is published by rename, so a torn rewrite cannot drop the recorded block"
}

test_successor_carry_fails_closed_and_never_lifts() {
  local home meta out rc
  home="$TMP_ROOT/carry-guards"
  mkdir -p "$home/state" "$home/data" "$home/projects/alpha"
  meta="$home/state/task-pred-f6.meta"

  # A predecessor whose record cannot be read must refuse the successor launch
  # rather than start the lane unconstrained.
  fm_write_meta "$meta" "kind=ship" "merge="
  set +e
  out=$(run_spawn_respawn "$home" task-succ-g7 projects/alpha pi --carry-merge-from task-pred-f6)
  rc=$?
  set -e
  expect_code 1 "$rc" "carry-unreadable: an unreadable predecessor record must refuse the successor"
  assert_contains "$out" 'records a merge authority that cannot be read; refusing to launch task-succ-g7 unconstrained' \
    "carry-unreadable: an unreadable predecessor record did not refuse the successor launch"
  assert_not_contains "$out" 'no brief at' \
    "carry-unreadable: the refusal came after the spawn had already proceeded"

  # A predecessor with no record at all is the same fail-closed case: the caller
  # named a lane whose constraint cannot be established.
  rm -f "$meta"
  set +e
  out=$(run_spawn_respawn "$home" task-succ-g7 projects/alpha pi --carry-merge-from task-pred-f6)
  rc=$?
  set -e
  expect_code 1 "$rc" "carry-missing: a missing predecessor record must refuse the successor"
  assert_contains "$out" 'records a merge authority that cannot be read' \
    "carry-missing: a missing predecessor record did not refuse the successor launch"

  # The carry is not a second lift channel.
  fm_write_meta "$meta" "kind=ship" "merge=blocked"
  set +e
  out=$(run_spawn_respawn "$home" task-succ-g7 projects/alpha pi --carry-merge-from task-pred-f6 --captain-authorized)
  rc=$?
  set -e
  expect_code 1 "$rc" "carry-lift: carrying and lifting on one invocation must be refused"
  assert_contains "$out" '--carry-merge-from and --captain-authorized contradict each other' \
    "carry-lift: the carry doubled as a lift"

  # An unsafe or self-referential predecessor id is refused before anything runs.
  set +e
  out=$(run_spawn_respawn "$home" task-succ-g7 projects/alpha pi --carry-merge-from ../escape)
  rc=$?
  set -e
  expect_code 1 "$rc" "carry-unsafe: an unsafe predecessor id must be refused"
  assert_contains "$out" '--carry-merge-from needs a valid predecessor task id' \
    "carry-unsafe: an unsafe predecessor id was accepted"

  set +e
  out=$(run_spawn_respawn "$home" task-succ-g7 projects/alpha pi --carry-merge-from task-succ-g7)
  rc=$?
  set -e
  expect_code 1 "$rc" "carry-self: naming this same task id must be refused"
  assert_contains "$out" 'names this same task id' \
    "carry-self: a self-referential carry was accepted"

  # One predecessor lane is never a shared batch axis.
  set +e
  out=$(run_spawn_respawn "$home" a-one-h8=projects/alpha b-two-j9=projects/alpha --carry-merge-from task-pred-f6)
  rc=$?
  set -e
  expect_code 1 "$rc" "carry-batch: --carry-merge-from must be refused for a batch"
  assert_contains "$out" 'cannot be a shared batch axis' \
    "carry-batch: --carry-merge-from was accepted as a batch axis"
  pass "the successor carry fails closed on an unreadable predecessor and never lifts or fans out"
}

test_spawn_flag_records_blocked
test_ordinary_spawn_records_no_merge_field
test_successor_task_id_carries_predecessor_block
test_successor_carry_of_unconstrained_lane_records_nothing
test_successor_carry_fails_closed_and_never_lifts
test_launch_meta_is_published_atomically
test_valueless_authority_refuses
test_rewrite_carries_constraint_forward
test_respawn_keeps_block_until_explicitly_lifted
test_blocked_task_refuses_before_recording
test_validation_completion_and_yolo_do_not_lift_block
test_observed_merged_state_does_not_lift_block
test_merge_poll_never_merges
test_pr_check_preserves_merge_block
test_captain_authorized_merge_lands
test_unrecognized_authority_refuses
test_absent_authority_still_merges
test_unreadable_meta_refuses
test_meta_read_error_refuses
test_merge_local_refuses_blocked_task
