#!/usr/bin/env bash
# Own the home-bound Firstmate Operator lifecycle.
# Usage: fm-operator.sh <start|ensure|status|url|stop>
#
# Every command requires an explicit FM_HOME.
# start and ensure generate or reuse config/operator-token, bind that credential
# to the canonical home, and serve the built operator bundle with `vite preview`
# on loopback. The development server with HMR stays behind `pnpm dev` and is
# never used for session initialization.
# url prints the token-bearing fragment URL used to bootstrap one browser tab;
# the browser immediately moves the token into sessionStorage and clears the
# fragment.
# Set FM_OPERATOR_PORT or config/operator-port to choose a fixed loopback port.
# Set config/operator-autostart to "off" to opt the primary home out of the
# session-start ensure hook.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "fm-operator: FM_HOME is required; refusing an unbound operator runtime" >&2
  exit 1
fi
if [ ! -d "$FM_HOME" ]; then
  echo "fm-operator: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
fi
FM_HOME=$(cd "$FM_HOME" && pwd -P)

# fm-wake-lib.sh reassigns FM_ROOT, FM_HOME, and STATE at source time, so it is
# sourced before this script derives the paths it owns.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
if [ ! -d "$FM_ROOT" ]; then
  echo "fm-operator: Firstmate code root '$FM_ROOT' is not a directory" >&2
  exit 1
fi
FM_ROOT=$(cd "$FM_ROOT" && pwd -P)
CONFIG="$FM_HOME/config"
STATE="$FM_HOME/state"
TOKEN_FILE="$CONFIG/operator-token"
RUNTIME_FILE="$STATE/operator-runtime"
LOG_FILE="$STATE/operator.log"
OPERATOR_DIR=${FM_OPERATOR_DIR:-$FM_ROOT/operator}

operator_record_value() { # <file> <key>
  sed -n "s/^$2=//p" "$1" | sed -n '1p'
}

operator_port() {
  local configured
  configured=${FM_OPERATOR_PORT:-}
  if [ -z "$configured" ] && [ -f "$CONFIG/operator-port" ] && [ ! -L "$CONFIG/operator-port" ]; then
    configured=$(sed -n '1p' "$CONFIG/operator-port")
  fi
  configured=${configured:-4173}
  case "$configured" in
    ''|*[!0-9]*) echo "fm-operator: invalid operator port '$configured'" >&2; return 1 ;;
  esac
  if [ "$configured" -lt 1024 ] || [ "$configured" -gt 65535 ]; then
    echo "fm-operator: operator port must be between 1024 and 65535" >&2
    return 1
  fi
  printf '%s' "$configured"
}

operator_token() {
  local bound token tmp permissions
  mkdir -p "$CONFIG" "$STATE"
  if [ -L "$CONFIG" ] || [ -L "$STATE" ]; then
    echo "fm-operator: refusing symlinked home config or state directory" >&2
    return 1
  fi
  chmod 700 "$CONFIG" "$STATE" 2>/dev/null || true
  if [ -e "$TOKEN_FILE" ]; then
    if [ ! -f "$TOKEN_FILE" ] || [ -L "$TOKEN_FILE" ]; then
      echo "fm-operator: refusing unsafe operator token record $TOKEN_FILE" >&2
      return 1
    fi
    permissions=$(stat -c %a "$TOKEN_FILE" 2>/dev/null || stat -f %Lp "$TOKEN_FILE" 2>/dev/null || true)
    [ "$permissions" = 600 ] || {
      echo "fm-operator: operator token record must have mode 600" >&2
      return 1
    }
    [ "$(wc -l < "$TOKEN_FILE" | tr -d ' ')" = 2 ] \
      && [ "$(grep -c '^fm_home=' "$TOKEN_FILE" 2>/dev/null || true)" = 1 ] \
      && [ "$(grep -c '^token=' "$TOKEN_FILE" 2>/dev/null || true)" = 1 ] || {
      echo "fm-operator: operator token record has an invalid format" >&2
      return 1
    }
    bound=$(operator_record_value "$TOKEN_FILE" fm_home)
    token=$(operator_record_value "$TOKEN_FILE" token)
    [ "$bound" = "$FM_HOME" ] || {
      echo "fm-operator: operator token record is bound to a different FM_HOME" >&2
      return 1
    }
    case "$token" in
      ''|*[!0-9a-f]*) echo "fm-operator: operator token record contains an invalid token" >&2; return 1 ;;
    esac
    [ "${#token}" -eq 64 ] || {
      echo "fm-operator: operator token record contains an invalid token" >&2
      return 1
    }
    printf '%s' "$token"
    return 0
  fi
  command -v node >/dev/null 2>&1 || {
    echo "fm-operator: node is required to generate the home-local operator token" >&2
    return 1
  }
  token=$(node -e 'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))')
  case "$token" in
    ''|*[!0-9a-f]*) echo "fm-operator: node returned an invalid operator token" >&2; return 1 ;;
  esac
  [ "${#token}" -eq 64 ] || {
    echo "fm-operator: node returned an invalid operator token" >&2
    return 1
  }
  tmp=$(mktemp "$CONFIG/.operator-token.XXXXXX")
  chmod 600 "$tmp"
  {
    printf 'fm_home=%s\n' "$FM_HOME"
    printf 'token=%s\n' "$token"
  } > "$tmp"
  mv "$tmp" "$TOKEN_FILE"
  printf '%s' "$token"
}

operator_runtime_matches() {
  local pid port expected_identity current_identity
  [ -f "$RUNTIME_FILE" ] && [ ! -L "$RUNTIME_FILE" ] || return 1
  [ "$(operator_record_value "$RUNTIME_FILE" fm_home)" = "$FM_HOME" ] || return 1
  [ "$(operator_record_value "$RUNTIME_FILE" fm_root)" = "$FM_ROOT" ] || return 1
  port=$(operator_record_value "$RUNTIME_FILE" port)
  [ "$port" = "$(operator_port)" ] || return 1
  pid=$(operator_record_value "$RUNTIME_FILE" pid)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  expected_identity=$(operator_record_value "$RUNTIME_FILE" pid_identity)
  [ -n "$expected_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current_identity" = "$expected_identity" ]
}

# Terminate a recorded operator process that this home still owns. A runtime
# record whose pid identity still resolves is never discarded without stopping
# the process it names, otherwise a port or root change orphans a live server
# that no later stop can reclaim.
operator_terminate_recorded() {
  local pid expected current attempt
  pid=$(operator_record_value "$RUNTIME_FILE" pid)
  expected=$(operator_record_value "$RUNTIME_FILE" pid_identity)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "$expected" ] || return 0
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 0
  [ "$current" = "$expected" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  attempt=0
  while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 50 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "fm-operator: recorded operator process $pid did not stop after SIGTERM" >&2
    return 1
  fi
}

operator_port_open() { # <port>
  ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) >/dev/null 2>&1
}

# `vite preview` serves an existing production build, so the bundle has to exist
# before the loopback server is useful. Build it once here rather than falling
# back to the development server.
operator_build_ready() { # <vite-bin>
  local vite_bin=$1
  [ -d "$OPERATOR_DIR" ] || {
    echo "fm-operator: operator package directory '$OPERATOR_DIR' is not a directory" >&2
    return 1
  }
  if [ -f "$OPERATOR_DIR/dist/index.html" ]; then
    return 0
  fi
  echo "fm-operator: building the operator bundle in $OPERATOR_DIR" >&2
  ( cd "$OPERATOR_DIR" && "$vite_bin" build ) >> "$LOG_FILE" 2>&1 || {
    echo "fm-operator: operator build failed; inspect $LOG_FILE" >&2
    return 1
  }
  [ -f "$OPERATOR_DIR/dist/index.html" ] || {
    echo "fm-operator: operator build produced no $OPERATOR_DIR/dist/index.html" >&2
    return 1
  }
}

operator_start() {
  local port token vite_bin pid pid_identity attempt tmp
  port=$(operator_port)
  token=$(operator_token)
  if operator_runtime_matches; then
    printf 'OPERATOR: live at http://127.0.0.1:%s for %s\n' "$port" "$FM_HOME"
    return 0
  fi
  if [ -e "$RUNTIME_FILE" ]; then
    [ -f "$RUNTIME_FILE" ] && [ ! -L "$RUNTIME_FILE" ] || {
      echo "fm-operator: refusing unsafe runtime record $RUNTIME_FILE" >&2
      return 1
    }
    operator_terminate_recorded || return 1
    rm -f "$RUNTIME_FILE"
  fi
  vite_bin=${FM_OPERATOR_VITE_BIN:-$OPERATOR_DIR/node_modules/.bin/vite}
  [ -x "$vite_bin" ] || {
    echo "fm-operator: operator dependencies are missing; run 'pnpm --dir $OPERATOR_DIR install'" >&2
    return 1
  }
  operator_build_ready "$vite_bin" || return 1
  # Vite resolves its config and root from the working directory, so the server
  # is launched from the operator package and not from the captain's cwd.
  (
    cd "$OPERATOR_DIR" \
      && FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_OPERATOR_TOKEN_FILE="$TOKEN_FILE" \
        exec nohup "$vite_bin" preview --host 127.0.0.1 --port "$port" --strictPort
  ) > "$LOG_FILE" 2>&1 &
  pid=$!
  attempt=0
  until operator_port_open "$port"; do
    kill -0 "$pid" 2>/dev/null || {
      wait "$pid" 2>/dev/null || true
      echo "fm-operator: live server failed to start; inspect $LOG_FILE" >&2
      return 1
    }
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 150 ]; then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "fm-operator: live server never accepted loopback connections on port $port; inspect $LOG_FILE" >&2
      return 1
    fi
    sleep 0.1
  done
  pid_identity=$(fm_pid_identity "$pid" 2>/dev/null) || {
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "fm-operator: live server identity could not be recorded" >&2
    return 1
  }
  tmp=$(mktemp "$STATE/.operator-runtime.XXXXXX")
  chmod 600 "$tmp"
  {
    printf 'fm_home=%s\n' "$FM_HOME"
    printf 'fm_root=%s\n' "$FM_ROOT"
    printf 'port=%s\n' "$port"
    printf 'pid=%s\n' "$pid"
    printf 'pid_identity=%s\n' "$pid_identity"
  } > "$tmp"
  mv "$tmp" "$RUNTIME_FILE"
  : "$token"
  printf 'OPERATOR: live at http://127.0.0.1:%s for %s\n' "$port" "$FM_HOME"
}

operator_stop() {
  operator_runtime_matches || {
    echo "fm-operator: no matching live operator runtime for $FM_HOME" >&2
    return 1
  }
  operator_terminate_recorded || return 1
  rm -f "$RUNTIME_FILE"
  printf 'OPERATOR: stopped for %s\n' "$FM_HOME"
}

case "${1:-}" in
  start|ensure) operator_start ;;
  status)
    if operator_runtime_matches; then
      printf 'OPERATOR: live at http://127.0.0.1:%s for %s\n' "$(operator_port)" "$FM_HOME"
    else
      echo "OPERATOR: not running for $FM_HOME" >&2
      exit 1
    fi
    ;;
  url)
    operator_runtime_matches || {
      echo "fm-operator: start the operator before requesting its session URL" >&2
      exit 1
    }
    printf 'http://127.0.0.1:%s/#token=%s\n' "$(operator_port)" "$(operator_token)"
    ;;
  stop) operator_stop ;;
  *)
    echo "Usage: fm-operator.sh <start|ensure|status|url|stop>" >&2
    exit 2
    ;;
esac
