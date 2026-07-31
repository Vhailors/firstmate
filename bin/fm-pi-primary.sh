#!/usr/bin/env bash
# Launch the Firstmate Pi orchestrator with extension discovery disabled and
# only the tracked turn-end guard and watcher extensions restored explicitly.
# The orchestrator intentionally does not load pi-dynamic-workflows: workflow
# fan-out belongs to Pi crewmates, while ordinary captain Pi sessions remain
# outside this launcher and keep their personal package configuration.
# FM_PI_HARNESS selects plain Pi or the verified pi-signed wrapper without
# changing the discovery boundary.
# This keeps user-global extensions available to ordinary `pi` sessions while
# preventing unrelated packages from colliding with Firstmate's Pi extensions.
# Every argument is forwarded to Pi unchanged after the required launch flags.
# FM_PI_EXTENSION_ISOLATION marks the launched session as discovery-scoped so
# bin/fm-session-start.sh can report a Pi primary that was started some other
# way and therefore still has user-global extensions loaded, including any
# orchestrator-inappropriate workflow package.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
WATCH_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
PI_HARNESS="${FM_PI_HARNESS:-pi}"

case "$PI_HARNESS" in
  pi|pi-signed) ;;
  *)
    printf 'fm-pi-primary: unsupported Pi harness: %s\n' "$PI_HARNESS" >&2
    exit 1
    ;;
esac

for extension in "$TURNEND_EXT" "$WATCH_EXT"; do
  if [ ! -f "$extension" ]; then
    printf 'fm-pi-primary: required extension is missing: %s\n' "$extension" >&2
    exit 1
  fi
done

if ! command -v "$PI_HARNESS" >/dev/null 2>&1; then
  printf 'fm-pi-primary: %s is not installed or is not on PATH\n' "$PI_HARNESS" >&2
  exit 1
fi

export FM_PI_EXTENSION_ISOLATION=1
export FM_PI_HARNESS="$PI_HARNESS"
exec "$PI_HARNESS" --no-extensions -e "$TURNEND_EXT" -e "$WATCH_EXT" "$@"
