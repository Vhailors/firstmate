#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) autonomous merge binds the green run's PR and head through atomic merge
#   (j) autonomous merge refuses unrelated, stale, advanced, red, or blocked work
#   (k) explicit-authority merge remains independent of autonomous prerequisites
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_autonomous_gh_mocks() {
  local case_dir=$1 preflight_head=$2 atomic_head=$3 recorded_head=${4:-$2}
  local forge_url=${5:-https://github.com/example/repo/pull/31}
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_AXI_LOG"
case "\${1:-} \${2:-}" in
  "api GET")
    printf 'head: %s\nurl: "%s"\n' '$preflight_head' '$forge_url'
    exit 0
    ;;
  "api PUT")
    supplied=
    for arg in "\$@"; do
      case "\$arg" in sha=*) supplied=\${arg#sha=} ;; esac
    done
    if [ "\$supplied" != '$atomic_head' ]; then
      echo 'head changed before merge' >&2
      exit 1
    fi
    printf 'merged: true\n'
    exit 0
    ;;
esac
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    if [ -n "\${FM_TEST_GH_VIEW_HOOK:-}" ]; then
      "\$FM_TEST_GH_VIEW_HOOK"
    fi
    printf '%s\n' '$recorded_head'
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_no_mistakes_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "axi status") printf '%s\n' "${FM_TEST_NM_STATUS:-}" ;;
  "axi logs")
    if [ -n "${FM_TEST_NM_CI_LOG_FILE:-}" ]; then
      cat "$FM_TEST_NM_CI_LOG_FILE"
    else
      printf '%s\n' "${FM_TEST_NM_CI_LOG:-}"
    fi
    ;;
  "runs --limit") printf '%s\n' "${FM_TEST_NM_RUNS:-}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/no-mistakes"
}

make_validation_worktree() {
  local case_dir=$1
  mkdir -p "$case_dir/wt"
  git -C "$case_dir/wt" init --quiet --initial-branch=main
  printf 'validated\n' > "$case_dir/wt/work.txt"
  git -C "$case_dir/wt" add work.txt
  git -C "$case_dir/wt" commit --quiet -m validated
  git -C "$case_dir/wt" checkout --quiet -b fm/task-x1
}

green_status() {
  local case_dir=$1 pr=https://github.com/example/repo/pull/31 head
  [ "$#" -lt 2 ] || pr=$2
  head=${3:-$(git -C "$case_dir/wt" rev-parse HEAD)}
  cat <<EOF
id: run-green
branch: fm/task-x1
head: $head
pr: "$pr"
status: ci
steps[1]{step,status,findings}:
  ci,running,0
EOF
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_autonomous_merge_accepts_only_current_green_lane() {
  local case_dir rc head
  case_dir=$(make_case autonomous-green)
  make_validation_worktree "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf 'yolo=on\n' >> "$case_dir/state/task-x1.meta"
  add_autonomous_gh_mocks "$case_dir" "$head" "$head"
  add_no_mistakes_mock "$case_dir"
  : > "$case_dir/gh-axi.log"

  FM_TEST_NM_STATUS=$(green_status "$case_dir") \
  FM_TEST_NM_CI_LOG='all CI checks passed - still monitoring until merged or closed' \
    run_pr_merge "$case_dir" --autonomous task-x1 https://github.com/example/repo/pull/31 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  expect_code 0 "$rc" "autonomous-green: current green no-mistakes yolo lane should merge"
  grep -qxF "api PUT /repos/example/repo/pulls/31/merge --field sha=$head --field merge_method=squash" \
    "$case_dir/gh-axi.log" \
    || fail "autonomous-green: guarded path did not atomically bind the validated head"
  pass "autonomous merge binds the exact green run PR and head atomically"
}

test_autonomous_merge_refuses_unrelated_or_mismatched_identity() {
  local label case_dir rc head observed run_pr requested_url
  for label in unrelated-url mismatched-head missing-run-pr; do
    case_dir=$(make_case "autonomous-$label")
    make_validation_worktree "$case_dir"
    head=$(git -C "$case_dir/wt" rev-parse HEAD)
    observed=$head
    run_pr=https://github.com/example/repo/pull/31
    requested_url=$run_pr
    case "$label" in
      unrelated-url) requested_url=https://github.com/example/repo/pull/99 ;;
      mismatched-head) observed=dddddddddddddddddddddddddddddddddddddddd ;;
      missing-run-pr) run_pr= ;;
    esac
    printf 'yolo=on\n' >> "$case_dir/state/task-x1.meta"
    add_autonomous_gh_mocks "$case_dir" "$observed" "$observed" "$observed" "$requested_url"
    add_no_mistakes_mock "$case_dir"
    : > "$case_dir/gh-axi.log"

    set +e
    FM_TEST_NM_STATUS=$(green_status "$case_dir" "$run_pr") \
    FM_TEST_NM_CI_LOG='all CI checks passed - still monitoring until merged or closed' \
      run_pr_merge "$case_dir" --autonomous task-x1 "$requested_url" \
        > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "autonomous-$label: mismatched identity should refuse"
    assert_no_grep 'api PUT\|pr merge' "$case_dir/gh-axi.log" \
      "autonomous-$label: mismatched identity reached a forge merge"
  done
  pass "autonomous merge refuses unrelated URLs and missing or mismatched run identity"
}

test_autonomous_merge_refuses_post_validation_head_advance() {
  local case_dir rc head advanced
  case_dir=$(make_case autonomous-head-advance)
  make_validation_worktree "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  advanced=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  printf 'yolo=on\n' >> "$case_dir/state/task-x1.meta"
  add_autonomous_gh_mocks "$case_dir" "$head" "$advanced" "$head"
  add_no_mistakes_mock "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_NM_STATUS=$(green_status "$case_dir") \
  FM_TEST_NM_CI_LOG='all CI checks passed - still monitoring until merged or closed' \
    run_pr_merge "$case_dir" --autonomous task-x1 https://github.com/example/repo/pull/31 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "autonomous-head-advance: atomic head mismatch should refuse"
  grep -qxF "api PUT /repos/example/repo/pulls/31/merge --field sha=$head --field merge_method=squash" \
    "$case_dir/gh-axi.log" \
    || fail "autonomous-head-advance: merge did not carry the validated head precondition"
  pass "autonomous merge fails when the PR head advances after validation"
}

test_autonomous_merge_rechecks_block_after_preflight() {
  local case_dir rc head hook
  case_dir=$(make_case autonomous-block-after-preflight)
  make_validation_worktree "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf 'yolo=on\n' >> "$case_dir/state/task-x1.meta"
  add_autonomous_gh_mocks "$case_dir" "$head" "$head"
  add_no_mistakes_mock "$case_dir"
  : > "$case_dir/gh-axi.log"
  hook="$case_dir/block-after-preflight"
  cat > "$hook" <<SH
#!/usr/bin/env bash
set -eu
. "$ROOT/bin/fm-wake-lib.sh"
meta='$case_dir/state/task-x1.meta'
lock=\$(fm_meta_lock_path "\$meta")
fm_lock_acquire_wait "\$lock"
tmp=\$(mktemp '$case_dir/state/.task-x1.meta.XXXXXX')
awk '!/^merge=/' "\$meta" > "\$tmp"
printf 'merge=blocked\n' >> "\$tmp"
chmod 600 "\$tmp"
mv -f "\$tmp" "\$meta"
fm_lock_release "\$lock"
SH
  chmod +x "$hook"

  set +e
  FM_TEST_NM_STATUS=$(green_status "$case_dir") \
  FM_TEST_NM_CI_LOG='all CI checks passed - still monitoring until merged or closed' \
  FM_TEST_GH_VIEW_HOOK="$hook" \
    run_pr_merge "$case_dir" --autonomous task-x1 https://github.com/example/repo/pull/31 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "autonomous-block-after-preflight: newly blocked lane should refuse"
  grep -qxF 'merge=blocked' "$case_dir/state/task-x1.meta" \
    || fail "autonomous-block-after-preflight: concurrent block was not preserved"
  assert_no_grep 'api PUT\|pr merge' "$case_dir/gh-axi.log" \
    "autonomous-block-after-preflight: blocked lane reached a forge merge"
  pass "autonomous merge rechecks authority after preflight"
}

test_autonomous_merge_rechecks_green_state_after_preflight() {
  local case_dir rc head hook ci_log_file
  case_dir=$(make_case autonomous-ci-change-after-preflight)
  make_validation_worktree "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf 'yolo=on\n' >> "$case_dir/state/task-x1.meta"
  add_autonomous_gh_mocks "$case_dir" "$head" "$head"
  add_no_mistakes_mock "$case_dir"
  : > "$case_dir/gh-axi.log"
  ci_log_file="$case_dir/ci.log"
  printf '%s\n' 'all CI checks passed - still monitoring until merged or closed' > "$ci_log_file"
  hook="$case_dir/invalidate-ci-after-preflight"
  cat > "$hook" <<SH
#!/usr/bin/env bash
printf '%s\n' 'CI checks running' > '$ci_log_file'
SH
  chmod +x "$hook"

  set +e
  FM_TEST_NM_STATUS=$(green_status "$case_dir") \
  FM_TEST_NM_CI_LOG_FILE="$ci_log_file" \
  FM_TEST_GH_VIEW_HOOK="$hook" \
    run_pr_merge "$case_dir" --autonomous task-x1 https://github.com/example/repo/pull/31 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "autonomous-ci-change-after-preflight: stale green verdict should refuse"
  grep -qxF 'CI checks running' "$ci_log_file" \
    || fail "autonomous-ci-change-after-preflight: CI state did not change"
  grep -qxF "api GET /repos/example/repo/pulls/31 --jq {url:.html_url,head:.head.sha}" \
    "$case_dir/gh-axi.log" \
    || fail "autonomous-ci-change-after-preflight: CI did not change after forge preflight"
  assert_no_grep 'api PUT\|pr merge' "$case_dir/gh-axi.log" \
    "autonomous-ci-change-after-preflight: stale green verdict reached a forge merge"
  pass "autonomous merge rechecks green state after preflight"
}

test_autonomous_merge_refuses_wrong_authority_or_validation() {
  local label case_dir rc status ci_log
  for label in blocked yolo-off wrong-mode red-current stale-run; do
    case_dir=$(make_case "autonomous-$label")
    make_validation_worktree "$case_dir"
    status=$(green_status "$case_dir")
    ci_log='all CI checks passed - still monitoring until merged or closed'
    case "$label" in
      blocked)
        printf 'yolo=on\nmerge=blocked\n' >> "$case_dir/state/task-x1.meta"
        ;;
      yolo-off)
        printf 'yolo=off\n' >> "$case_dir/state/task-x1.meta"
        ;;
      wrong-mode)
        sed -i 's/^mode=no-mistakes$/mode=direct-PR/' "$case_dir/state/task-x1.meta"
        printf 'yolo=on\n' >> "$case_dir/state/task-x1.meta"
        ;;
      red-current)
        printf 'yolo=on\n' >> "$case_dir/state/task-x1.meta"
        ci_log='CI checks running'
        ;;
      stale-run)
        printf 'yolo=on\n' >> "$case_dir/state/task-x1.meta"
        status=$(printf '%s\n' "$status" | sed 's/^head: .*/head: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/')
        ;;
    esac
    add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
    add_no_mistakes_mock "$case_dir"
    : > "$case_dir/gh-axi.log"

    set +e
    FM_TEST_NM_STATUS="$status" FM_TEST_NM_CI_LOG="$ci_log" \
      run_pr_merge "$case_dir" --autonomous task-x1 https://github.com/example/repo/pull/32 \
        > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "autonomous-$label: unsafe autonomous merge should refuse"
    assert_no_grep 'api PUT\|pr merge' "$case_dir/gh-axi.log" \
      "autonomous-$label: unsafe lane reached the forge merge"
    assert_no_grep '^pr=' "$case_dir/state/task-x1.meta" \
      "autonomous-$label: refusal recorded PR state before satisfying its guard"
  done
  pass "autonomous merge refuses blocked, non-yolo, non-pipeline, red, and stale-run lanes"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_autonomous_merge_accepts_only_current_green_lane
test_autonomous_merge_refuses_unrelated_or_mismatched_identity
test_autonomous_merge_refuses_post_validation_head_advance
test_autonomous_merge_rechecks_block_after_preflight
test_autonomous_merge_rechecks_green_state_after_preflight
test_autonomous_merge_refuses_wrong_authority_or_validation
