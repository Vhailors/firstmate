#!/usr/bin/env bash
# Launch a Firstmate primary Pi session with extension discovery disabled and
# only the tracked turn-end guard and watcher extensions restored explicitly.
# This keeps user-global extensions available to ordinary `pi` sessions while
# preventing unrelated packages from colliding with Firstmate's Pi extensions.
# Every argument is forwarded to Pi unchanged after the required launch flags.
# FM_PI_EXTENSION_ISOLATION marks the launched session as discovery-scoped so
# bin/fm-session-start.sh can report a Pi primary that was started some other
# way and therefore still has user-global extensions loaded.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
WATCH_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"

for extension in "$TURNEND_EXT" "$WATCH_EXT"; do
  if [ ! -f "$extension" ]; then
    printf 'fm-pi-primary: required extension is missing: %s\n' "$extension" >&2
    exit 1
  fi
done

if ! command -v pi >/dev/null 2>&1; then
  printf 'fm-pi-primary: pi is not installed or is not on PATH\n' >&2
  exit 1
fi

export FM_PI_EXTENSION_ISOLATION=1
exec pi --no-extensions -e "$TURNEND_EXT" -e "$WATCH_EXT" "$@"
