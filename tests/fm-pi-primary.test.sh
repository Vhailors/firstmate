#!/usr/bin/env bash
# Behavior tests for the scoped Pi primary launcher.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAUNCHER="$ROOT/bin/fm-pi-primary.sh"
TMP_ROOT=$(fm_test_tmproot fm-pi-primary)

make_case() {
  local name=$1 case_dir home fakebin log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  log="$case_dir/pi.log"
  mkdir -p "$home"
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'USER_DATA=%s\n' "${CHROME_DEVTOOLS_AXI_USER_DATA_DIR:-}"
  printf 'HEADED=%s\n' "${CHROME_DEVTOOLS_AXI_HEADED:-}"
  printf 'AUTO_CONNECT=%s\n' "${CHROME_DEVTOOLS_AXI_AUTO_CONNECT:-}"
  printf 'ISOLATION=%s\n' "${FM_PI_EXTENSION_ISOLATION:-}"
  printf 'HARNESS=%s\n' "${FM_PI_HARNESS:-}"
  printf 'ARG=%s\n' "$@"
} > "${FM_TEST_PI_LOG:?}"
SH
  chmod +x "$fakebin/pi"
  printf '%s|%s|%s|%s\n' "$case_dir" "$home" "$fakebin" "$log"
}

run_case() {
  local home=$1 fakebin=$2 log=$3
  shift 3
  env -i HOME="$home" PATH="$fakebin:/usr/bin:/bin" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_PI_LOG="$log" "$@" "$LAUNCHER" --session test
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR FAKEBIN_DIR LOG_FILE <<EOF
$1
EOF
}

assert_base_launch() {
  local log=$1 home=$2
  assert_grep "USER_DATA=$home/.chrome-llm-profile" "$log" \
    "Pi primary did not derive the Chrome profile from the isolated HOME"
  assert_grep 'HEADED=1' "$log" "Pi primary did not default Chrome to headed mode"
  assert_grep 'AUTO_CONNECT=0' "$log" "Pi primary did not disable automatic Chrome attachment"
  assert_grep 'ISOLATION=1' "$log" "Pi primary did not export the extension isolation marker"
  assert_grep 'HARNESS=pi' "$log" "Pi primary did not preserve the selected harness identity"
  assert_grep "ARG=$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$log" \
    "Pi primary did not load the tracked turn-end extension"
  assert_grep "ARG=$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$log" \
    "Pi primary did not load the tracked watcher extension"
}

test_absent_decision_extension_uses_portable_defaults() {
  local rec status
  rec=$(make_case absent)
  read_case "$rec"
  run_case "$HOME_DIR" "$FAKEBIN_DIR" "$LOG_FILE"
  status=$?
  expect_code 0 "$status" "Pi primary should launch when the optional decision extension is absent"
  assert_base_launch "$LOG_FILE" "$HOME_DIR"
  assert_no_grep 'fm-captain-decisions' "$LOG_FILE" \
    "Pi primary loaded an absent decision extension"
  pass "Pi primary uses portable Chrome defaults and skips an absent decision extension"
}

test_present_default_decision_extension_loads() {
  local rec decision status
  rec=$(make_case present)
  read_case "$rec"
  decision="$HOME_DIR/.pi/agent/extensions/fm-captain-decisions/index.ts"
  mkdir -p "$(dirname "$decision")"
  : > "$decision"
  run_case "$HOME_DIR" "$FAKEBIN_DIR" "$LOG_FILE"
  status=$?
  expect_code 0 "$status" "Pi primary should launch with the default decision extension present"
  assert_grep "ARG=$decision" "$LOG_FILE" \
    "Pi primary did not load the decision extension resolved under isolated HOME"
  pass "Pi primary loads the default captain decision extension only when it exists"
}

test_decision_extension_override_is_respected() {
  local rec decision status
  rec=$(make_case decision-override)
  read_case "$rec"
  decision="$CASE_DIR/custom-decisions.ts"
  : > "$decision"
  run_case "$HOME_DIR" "$FAKEBIN_DIR" "$LOG_FILE" FM_CAPTAIN_DECISIONS_EXT="$decision"
  status=$?
  expect_code 0 "$status" "Pi primary should launch with an explicit decision extension override"
  assert_grep "ARG=$decision" "$LOG_FILE" "Pi primary ignored FM_CAPTAIN_DECISIONS_EXT"
  pass "Pi primary respects an existing decision extension override"
}

test_chrome_overrides_are_preserved() {
  local rec profile status
  rec=$(make_case chrome-override)
  read_case "$rec"
  profile="$CASE_DIR/shared-profile"
  run_case "$HOME_DIR" "$FAKEBIN_DIR" "$LOG_FILE" \
    CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$profile" \
    CHROME_DEVTOOLS_AXI_HEADED=0 \
    CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1
  status=$?
  expect_code 0 "$status" "Pi primary should launch with explicit Chrome overrides"
  assert_grep "USER_DATA=$profile" "$LOG_FILE" "Pi primary replaced the caller's Chrome profile"
  assert_grep 'HEADED=0' "$LOG_FILE" "Pi primary replaced the caller's headed override"
  assert_grep 'AUTO_CONNECT=1' "$LOG_FILE" "Pi primary replaced the caller's auto-connect override"
  assert_no_grep "$HOME/.chrome-llm-profile" "$LOG_FILE" \
    "Pi primary test leaked the operator's actual HOME into the isolated launch"
  pass "Pi primary preserves explicit Chrome overrides without reading the operator HOME"
}

test_absent_decision_extension_uses_portable_defaults
test_present_default_decision_extension_loads
test_decision_extension_override_is_respected
test_chrome_overrides_are_preserved

echo "# all fm-pi-primary tests passed"
