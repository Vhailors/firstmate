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
# future field can never be read as permission. A merge= line with no value at
# all is corruption rather than a recorded decision - no writer produces it - so
# it is reported as an unreadable record, not as absence. Whole-meta rewrites
# publish atomically (bin/fm-spawn.sh stages a sibling file and renames it), so
# no reader observes a half-written record in the first place; this branch is the
# backstop for a record damaged some other way, since absent merge= legitimately
# means "allowed" and a tear that removed the line would otherwise read as one.
#
# The block cannot be lifted by a merge or spawn command. It is deliberately NOT
# lifted by yolo, validation completing, CI turning green, or observing that the
# pull request merged elsewhere: those are observations about the work, not the
# captain's decision to land it. A changed captain decision is a new lane-level
# instruction, not a command-line escape hatch on the blocked lane.
#
# bin/fm-spawn.sh --no-merge is the only writer of merge=blocked, and
# fm_merge_authority_resolve below is the one rule every rewrite of an existing
# task's meta follows, so a recorded block survives a respawn that simply did
# not repeat the flag. A recovery that continues one lane under a SUCCESSOR task
# id reads the predecessor's value through this library too, via fm-spawn's
# explicit --carry-merge-from, so the new id starts constrained rather than with
# an empty record.

# Echo the task's recorded merge authority, defaulting to "allowed" when the
# field is absent. Returns 1 when the record cannot be read at all or carries a
# valueless merge= field, so neither an unreadable nor a truncated record can
# resolve to permission. A successful read always echoes a non-empty value.
fm_merge_authority_value() {
  local meta=$1 raw lines status=0
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || return 1
  lines=$(grep '^merge=' "$meta") || status=$?
  [ "$status" -le 1 ] || return 1
  if [ "$status" -eq 1 ]; then
    printf '%s\n' allowed
    return 0
  fi
  raw=$(printf '%s\n' "$lines" | tail -1 | cut -d= -f2-)
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw"
}

# Decide which merge authority a metadata rewrite must record for one task.
# Usage: fm_merge_authority_resolve <meta-path> <requested value|"">
# Echoes the value to write, empty when no merge= line is needed, and returns 1
# when an existing record cannot be read.
#
# Every launch rewrites the whole meta, so a respawn that omits --no-merge would
# otherwise erase the captain's constraint and the task would read as permitted.
# A recorded constraint therefore wins over whatever this invocation asked for,
# and no caller flag clears it: neither omitting a flag nor a recovery respawn
# is a captain decision. An unrecognized recorded value is carried forward
# verbatim so it keeps refusing.
fm_merge_authority_resolve() {
  local meta=$1 requested=${2:-} recorded=
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    recorded=$(fm_merge_authority_value "$meta") || return 1
  fi
  if [ -n "$recorded" ] && [ "$recorded" != allowed ]; then
    printf '%s\n' "$recorded"
    return 0
  fi
  printf '%s\n' "$requested"
}

# Decide whether a merge action may proceed for one task.
# Usage: fm_merge_authority_check <meta-path> <task-id>
# Silent and returns 0 when the merge may proceed; otherwise explains the
# refusal on stderr and returns 1.
fm_merge_authority_check() {
  local meta=$1 id=$2 value
  value=$(fm_merge_authority_value "$meta") || {
    echo "error: merge authority for task $id could not be read; refusing to merge" >&2
    return 1
  }
  case "$value" in
    allowed)
      return 0
      ;;
    blocked)
      echo "REFUSED: task $id was dispatched with merge=blocked; the captain has not authorized landing it." >&2
      echo "Green checks, a completed validation run, and an already-merged pull request do not lift this." >&2
      echo "No merge-command flag lifts this lane-level block." >&2
      return 1
      ;;
    *)
      echo "error: task $id records an unrecognized merge authority; refusing rather than assuming it may land" >&2
      return 1
      ;;
  esac
}
