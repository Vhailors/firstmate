#!/usr/bin/env bash
# Single owner of a task's durable merge authority: the merge= field in
# state/<id>.meta, and the one refusal both of firstmate's merge actions apply.
#
# It exists because a "do not merge" constraint used to live only as prose in
# the crewmate brief, which no script could read. bin/fm-pr-merge.sh would merge
# any task/PR pair it was handed, so an explicit captain constraint was
# enforceable only by an agent remembering it, and one invocation from any shell
# holding the forge credential could land a lane the captain had forbidden.
#
# Field values:
#   (absent)  no recorded constraint; merging is allowed, so every task
#             dispatched before this field existed keeps working unchanged
#   allowed   explicitly unconstrained
#   blocked   both firstmate merge actions refuse this task
# Any other value is unrecognized and refuses, so a corrupted, truncated, or
# future field can never be read as permission.
#
# The block is lifted only by an explicit per-merge --captain-authorized on the
# invocation. It is deliberately NOT lifted by yolo, by validation completing,
# by CI turning green, or by observing that the pull request merged elsewhere:
# those are observations about the work, not the captain's decision to land it.
#
# bin/fm-spawn.sh --no-merge is the only writer of merge=blocked.

# Echo the task's recorded merge authority, defaulting to "allowed" when the
# field is absent. Returns 1 when the metadata itself cannot be read, so an
# unreadable record refuses instead of defaulting to permission.
fm_merge_authority_value() {
  local meta=$1 raw
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  raw=$(grep '^merge=' "$meta" | tail -1 | cut -d= -f2- || true)
  [ -n "$raw" ] || raw=allowed
  printf '%s\n' "$raw"
}

# Strip a leading --captain-authorized from the argument list.
# Sets FM_MERGE_AUTHORIZED to 0 or 1 and FM_MERGE_ARGS to the remaining args.
# Only the first position is recognized, so the flag can never be confused with
# an argument being forwarded to the forge CLI after the -- separator.
# Both outputs are consumed by the sourcing script, not by this library.
# shellcheck disable=SC2034
fm_merge_authority_parse_leading() {
  FM_MERGE_AUTHORIZED=0
  if [ "${1:-}" = --captain-authorized ]; then
    FM_MERGE_AUTHORIZED=1
    shift
  fi
  FM_MERGE_ARGS=("$@")
}

# Decide whether a merge action may proceed for one task.
# Usage: fm_merge_authority_check <meta-path> <task-id> <authorized 0|1>
# Silent and returns 0 when the merge may proceed; otherwise explains the
# refusal on stderr and returns 1.
fm_merge_authority_check() {
  local meta=$1 id=$2 authorized=$3 value
  value=$(fm_merge_authority_value "$meta") || {
    echo "error: merge authority for task $id could not be read; refusing to merge" >&2
    return 1
  }
  case "$value" in
    allowed)
      return 0
      ;;
    blocked)
      if [ "$authorized" = 1 ]; then
        echo "note: merge block on task $id lifted by explicit captain authorization" >&2
        return 0
      fi
      echo "REFUSED: task $id was dispatched with merge=blocked; the captain has not authorized landing it." >&2
      echo "Green checks, a completed validation run, and an already-merged pull request do not lift this." >&2
      echo "Re-run with --captain-authorized as the first argument only after the captain explicitly approves this merge." >&2
      return 1
      ;;
    *)
      echo "error: task $id records an unrecognized merge authority; refusing rather than assuming it may land" >&2
      return 1
      ;;
  esac
}
