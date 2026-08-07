#!/usr/bin/env bash
# Home binding and lifecycle behavior for bin/fm-operator.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OPERATOR="$ROOT/bin/fm-operator.sh"
TMP_ROOT=$(fm_test_tmproot fm-operator)
OPERATOR_DIR="$TMP_ROOT/operator"
FAKE_NODE=$(command -v node || true)
PORT=$((30000 + $$ % 5000))
ALT_PORT=$((PORT + 1))
LIVE_OPERATORS=()

cleanup_operator() {
  local entry home port
  for entry in "${LIVE_OPERATORS[@]:-}"; do
    [ -n "$entry" ] || continue
    home=${entry%%|*}
    port=${entry##*|}
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_OPERATOR_PORT="$port" \
      "$OPERATOR" stop >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup_operator EXIT

[ -n "$FAKE_NODE" ] || fail "node is required to run the operator lifecycle tests"

# Stands in for the operator package: a present production bundle plus a vite
# binary that records how it was launched and then actually binds the loopback
# port, so the launcher's readiness probe observes a serving process.
mkdir -p "$OPERATOR_DIR/dist"
printf '%s\n' '<!doctype html><title>operator</title>' > "$OPERATOR_DIR/dist/index.html"

cat > "$TMP_ROOT/fake-vite" <<'SH'
#!/usr/bin/env bash
set -u
port=
prev=
for arg in "$@"; do
  if [ "$prev" = --port ]; then port=$arg; fi
  prev=$arg
done
printf 'home=%s root=%s token_file=%s cwd=%s args=%s\n' \
  "$FM_HOME" "$FM_ROOT_OVERRIDE" "$FM_OPERATOR_TOKEN_FILE" "$(pwd -P)" "$*" >> "$FM_OPERATOR_FAKE_LOG"
exec "$FM_OPERATOR_FAKE_NODE" \
  -e 'require("node:http").createServer((_q, r) => r.end("ok")).listen(Number(process.argv[1]), "127.0.0.1")' \
  "$port"
SH
chmod +x "$TMP_ROOT/fake-vite"

run_operator() { # <home> <port> <command...>
  local home=$1 port=$2
  shift 2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_OPERATOR_PORT="$port" \
    FM_OPERATOR_DIR="$OPERATOR_DIR" FM_OPERATOR_VITE_BIN="$TMP_ROOT/fake-vite" \
    FM_OPERATOR_FAKE_NODE="$FAKE_NODE" FM_OPERATOR_FAKE_LOG="$TMP_ROOT/live.log" \
    "$OPERATOR" "$@"
}

recorded_pid() { # <home>
  sed -n 's/^pid=//p' "$1/state/operator-runtime"
}

test_refuses_without_home() {
  local err rc
  err="$TMP_ROOT/no-home.err"
  /usr/bin/env -u FM_HOME "$OPERATOR" start >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "operator start accepted a missing FM_HOME"
  assert_contains "$(cat "$err")" "FM_HOME is required" "missing-home refusal was not explicit"
  pass "operator: live commands refuse without an explicit FM_HOME"
}

test_refuses_an_out_of_range_port() {
  local err rc
  err="$TMP_ROOT/bad-port.err"
  FM_HOME="$TMP_ROOT" FM_ROOT_OVERRIDE="$ROOT" FM_OPERATOR_PORT=80 \
    "$OPERATOR" start >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "operator start accepted a privileged port"
  assert_contains "$(cat "$err")" "between 1024 and 65535" "port bound refusal was not explicit"
  pass "operator: the configured loopback port is bounded"
}

test_live_start_and_token_bootstrap() {
  local home log out url token mode
  home="$TMP_ROOT/live-home"
  log="$TMP_ROOT/live.log"
  mkdir -p "$home"
  : > "$log"
  out=$(run_operator "$home" "$PORT" start)
  LIVE_OPERATORS+=("$home|$PORT")
  assert_contains "$out" "OPERATOR: live at http://127.0.0.1:$PORT" "live start did not report its loopback endpoint"
  assert_present "$home/config/operator-token" "live start did not create a home-local token"
  mode=$(stat -c %a "$home/config/operator-token" 2>/dev/null || stat -f %Lp "$home/config/operator-token")
  [ "$mode" = 600 ] || fail "operator token mode is $mode, expected 600"
  assert_contains "$(cat "$log")" "home=$home" "live server did not receive the exact FM_HOME"
  assert_contains "$(cat "$log")" "cwd=$OPERATOR_DIR" "live server did not run from the operator package directory"
  assert_contains "$(cat "$log")" "args=preview --host 127.0.0.1 --port $PORT --strictPort" \
    "live server was not the loopback-bound production preview"
  url=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_OPERATOR_PORT="$PORT" "$OPERATOR" url)
  token=${url##*#token=}
  [ "${#token}" -eq 64 ] || fail "bootstrap URL did not contain the generated 64-character token"
  assert_not_contains "$(cat "$log")" "$token" "operator token leaked into the server argv log"
  pass "operator: start serves the built bundle from live home state and returns a private bootstrap URL"
}

test_start_refuses_without_a_production_build() {
  local home err rc
  home="$TMP_ROOT/unbuilt-home"
  mkdir -p "$home"
  err="$TMP_ROOT/unbuilt.err"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_OPERATOR_PORT="$ALT_PORT" \
    FM_OPERATOR_DIR="$TMP_ROOT/missing-operator" FM_OPERATOR_VITE_BIN="$TMP_ROOT/fake-vite" \
    FM_OPERATOR_FAKE_NODE="$FAKE_NODE" FM_OPERATOR_FAKE_LOG="$TMP_ROOT/live.log" \
    "$OPERATOR" start >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "operator start accepted a missing operator package directory"
  assert_contains "$(cat "$err")" "is not a directory" "missing operator package refusal was not explicit"
  assert_absent "$home/state/operator-runtime" "a refused start still recorded a runtime"
  pass "operator: start refuses instead of serving a missing production bundle"
}

test_port_change_terminates_the_recorded_operator() {
  local home first second out
  home="$TMP_ROOT/live-home"
  first=$(recorded_pid "$home")
  [ -n "$first" ] || fail "the live start recorded no operator pid"
  out=$(run_operator "$home" "$ALT_PORT" start)
  LIVE_OPERATORS+=("$home|$ALT_PORT")
  second=$(recorded_pid "$home")
  assert_contains "$out" "OPERATOR: live at http://127.0.0.1:$ALT_PORT" "the re-port start did not report its new endpoint"
  [ "$second" != "$first" ] || fail "the re-port start reused the previous operator pid"
  kill -0 "$first" 2>/dev/null && fail "the superseded operator process $first was orphaned"
  pass "operator: a changed port stops the recorded process instead of orphaning it"
}

test_token_binding_refuses_cross_home_reuse() {
  local first second err rc
  first="$TMP_ROOT/live-home"
  second="$TMP_ROOT/other-home"
  err="$TMP_ROOT/wrong-home.err"
  mkdir -p "$second/config"
  cp "$first/config/operator-token" "$second/config/operator-token"
  chmod 600 "$second/config/operator-token"
  run_operator "$second" "$PORT" start >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "operator accepted a token record bound to another home"
  assert_contains "$(cat "$err")" "bound to a different FM_HOME" "cross-home token refusal was not explicit"
  pass "operator: generated credentials are bound to one canonical FM_HOME"
}

test_refuses_without_home
test_refuses_an_out_of_range_port
test_live_start_and_token_bootstrap
test_start_refuses_without_a_production_build
test_port_change_terminates_the_recorded_operator
test_token_binding_refuses_cross_home_reuse

echo "# fm-operator.test.sh: all assertions passed"
