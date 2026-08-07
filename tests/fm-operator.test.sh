#!/usr/bin/env bash
# Home binding and lifecycle behavior for bin/fm-operator.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OPERATOR="$ROOT/bin/fm-operator.sh"
TMP_ROOT=$(fm_test_tmproot fm-operator)
LIVE_HOMES=()

cleanup_operator() {
  local home
  for home in "${LIVE_HOMES[@]:-}"; do
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_OPERATOR_VITE_BIN="$TMP_ROOT/fake-vite" \
      "$OPERATOR" stop >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup_operator EXIT

cat > "$TMP_ROOT/fake-vite" <<'SH'
#!/usr/bin/env bash
set -u
printf 'home=%s root=%s token_file=%s args=%s\n' \
  "$FM_HOME" "$FM_ROOT_OVERRIDE" "$FM_OPERATOR_TOKEN_FILE" "$*" >> "$FM_OPERATOR_FAKE_LOG"
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH
chmod +x "$TMP_ROOT/fake-vite"

test_refuses_without_home() {
  local err rc
  err="$TMP_ROOT/no-home.err"
  /usr/bin/env -u FM_HOME "$OPERATOR" start >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "operator start accepted a missing FM_HOME"
  assert_contains "$(cat "$err")" "FM_HOME is required" "missing-home refusal was not explicit"
  pass "operator: live commands refuse without an explicit FM_HOME"
}

test_live_start_and_token_bootstrap() {
  local home log out url token mode
  home="$TMP_ROOT/live-home"
  log="$TMP_ROOT/live.log"
  mkdir -p "$home"
  : > "$log"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_OPERATOR_VITE_BIN="$TMP_ROOT/fake-vite" \
    FM_OPERATOR_FAKE_LOG="$log" "$OPERATOR" start)
  LIVE_HOMES+=("$home")
  assert_contains "$out" "OPERATOR: live at http://127.0.0.1:4173" "live start did not report its loopback endpoint"
  assert_present "$home/config/operator-token" "live start did not create a home-local token"
  mode=$(stat -c %a "$home/config/operator-token" 2>/dev/null || stat -f %Lp "$home/config/operator-token")
  [ "$mode" = 600 ] || fail "operator token mode is $mode, expected 600"
  assert_contains "$(cat "$log")" "home=$home" "live server did not receive the exact FM_HOME"
  assert_contains "$(cat "$log")" "--host 127.0.0.1 --port 4173 --strictPort" "live server was not loopback-bound with a strict port"
  url=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$OPERATOR" url)
  token=${url##*#token=}
  [ "${#token}" -eq 64 ] || fail "bootstrap URL did not contain the generated 64-character token"
  assert_not_contains "$(cat "$log")" "$token" "operator token leaked into the server argv log"
  pass "operator: start uses live home state and returns a generated private bootstrap URL"
}

test_token_binding_refuses_cross_home_reuse() {
  local first second err rc
  first="$TMP_ROOT/live-home"
  second="$TMP_ROOT/other-home"
  err="$TMP_ROOT/wrong-home.err"
  mkdir -p "$second/config"
  cp "$first/config/operator-token" "$second/config/operator-token"
  chmod 600 "$second/config/operator-token"
  FM_HOME="$second" FM_ROOT_OVERRIDE="$ROOT" FM_OPERATOR_VITE_BIN="$TMP_ROOT/fake-vite" \
    FM_OPERATOR_FAKE_LOG="$TMP_ROOT/live.log" "$OPERATOR" start >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "operator accepted a token record bound to another home"
  assert_contains "$(cat "$err")" "bound to a different FM_HOME" "cross-home token refusal was not explicit"
  pass "operator: generated credentials are bound to one canonical FM_HOME"
}

test_refuses_without_home
test_live_start_and_token_bootstrap
test_token_binding_refuses_cross_home_reuse

echo "# fm-operator.test.sh: all assertions passed"
