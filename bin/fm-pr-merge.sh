#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The default path requires the caller's explicit merge authority. --autonomous
# is the standing-yolo path and additionally requires mode=no-mistakes, yolo=on,
# and fm-crew-state's current-code-matched green run-step verdict before any
# forge merge call.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# A task dispatched with fm-spawn.sh --no-merge records merge=blocked and is
# refused here before anything is recorded or merged; bin/fm-merge-authority-lib.sh
# owns that contract. No merge-command flag lifts the block.
# Usage: fm-pr-merge.sh [--autonomous] <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-merge-authority-lib.sh
. "$SCRIPT_DIR/fm-merge-authority-lib.sh"

AUTONOMOUS=0
if [ "${1:-}" = --autonomous ]; then
  AUTONOMOUS=1
  shift
fi

if [ "${1:-}" = --captain-authorized ]; then
  echo "error: --captain-authorized is not supported; a merge command cannot lift merge=blocked" >&2
  exit 2
fi

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Checked before fm-pr-check.sh so a blocked task records no pr=, arms no merge
# poll, and reaches no forge call: the refusal must leave no trace of an attempt
# to land work the captain forbade.
fm_merge_authority_check "$META" "$ID" || exit 1

metadata_exact_value() {
  local key=$1 count value
  count=$(grep -c "^$key=" "$META" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(grep "^$key=" "$META" | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

if [ "$AUTONOMOUS" -eq 1 ]; then
  MODE=$(metadata_exact_value mode) || {
    echo "error: autonomous merge requires exactly one readable mode=no-mistakes record" >&2
    exit 1
  }
  YOLO=$(metadata_exact_value yolo) || {
    echo "error: autonomous merge requires exactly one readable yolo=on record" >&2
    exit 1
  }
  [ "$MODE" = no-mistakes ] || {
    echo "REFUSED: autonomous merge requires mode=no-mistakes; task $ID records mode=$MODE" >&2
    exit 1
  }
  [ "$YOLO" = on ] || {
    echo "REFUSED: autonomous merge requires yolo=on; task $ID records yolo=$YOLO" >&2
    exit 1
  }
  CREW_STATE=$("$SCRIPT_DIR/fm-crew-state.sh" "$ID") || {
    echo "error: autonomous merge could not determine current validation state for task $ID" >&2
    exit 1
  }
  case "$CREW_STATE" in
    "state: done · source: run-step · checks green: PR ready for review"*) ;;
    *)
      echo "REFUSED: autonomous merge requires a current-code-matched green no-mistakes run for task $ID" >&2
      echo "current state: $CREW_STATE" >&2
      exit 1
      ;;
  esac
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
