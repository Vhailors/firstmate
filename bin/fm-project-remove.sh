#!/usr/bin/env bash
# fm-project-remove.sh - captain-gated guarded removal transaction for one
# project clone under this home's projects/ directory, with or without a
# registry entry.
#
# This is the approved guarded project-removal path referenced by AGENTS.md
# hard rule #1 and the project-management skill: the ONLY way firstmate retires
# a managed clone. It owns the complete transaction and refuses loudly at every
# step; a refusal is a stop-and-report result, never an obstacle to bypass.
#
# Resolution (each of these refuses before any mutation):
#   - The target is a bare project NAME ([A-Za-z0-9._-]+, no leading dash),
#     never a path: the exact names . and .., any name containing /, and any
#     character outside that set are rejected, while interior dots as in
#     "my.project" are valid, so the transaction can only ever reach
#     $FM_HOME/projects/<name> in the ACTIVE home - another home's clone is
#     unreachable by construction.
#   - The projects directory and the clone must be real directories, not
#     symlinks, and the clone's physical path must resolve to exactly
#     <projects-phys>/<name>; a symlinked or relocated clone refuses.
#   - The clone must be a standalone git clone: a .git DIRECTORY whose git
#     common dir resolves inside the clone. A gitfile (the clone is itself a
#     linked worktree of another repository) refuses, because raw removal would
#     corrupt that other repository's worktree registry.
#   - The clone may never be, or contain, this firstmate checkout or the
#     active FM_HOME.
#   - A nested mountpoint under the clone refuses before quarantine and is
#     rechecked at the deletion boundary; deletion is filesystem-bounded.
#
# Blockers - the transaction refuses while any exist.
# STRUCTURAL blockers can never be covered by discard authority; resolve them
# through their own owner paths first (bin/fm-teardown.sh for tasks, the
# backlog backend for queued items, secondmate-provisioning for secondmate
# clones):
#   - live task metadata: any state/<id>.meta whose project=, worktree=, or
#     home= resolves at or under the clone
#   - open backlog items tagged "(repo: <name>)" in data/backlog.md
#   - a data/secondmates.md line whose projects list names <name>, or whose
#     home resolves under the clone
#   - linked worktrees of the clone that still exist on disk; registrations
#     whose directories are already gone are cleaned only through
#     `git worktree prune` (the supported owner tool), never by raw deletion
# DISCARDABLE blockers name work content the captain may explicitly discard:
#   - dirty, untracked, or ignored files and directories
#   - nested repositories: only a marker git itself validates (via
#     `git rev-parse --resolve-git-dir`) counts as one; an entry merely NAMED
#     .git that git cannot resolve (a cache file, an empty or corrupt
#     directory, a fifo, a dangling symlink) stays ordinary discardable
#     payload fingerprinted by the tree inventory. A validated nested
#     repository's worktree, ref, stash, and object state is exact-authority
#     inventory even when the outer tree is clean, INCLUDING one whose gitdir
#     store resolves outside the clone - removal deletes only the in-clone
#     checkout and leaves the external store untouched, with a stale
#     registration to clean through Git tooling afterwards
#   - stash entries
#   - every Git object not reachable from any remote-tracking ref, including
#     commit, tree, blob, and tag objects retained only by a local ref, reflog,
#     or dangling object, plus every local tag, note, and other non-branch ref
#
# Discard authority is object- and state-scoped, never prose: a refusal whose
# blockers are all discardable prints the exact token
#     discard-unlanded:<name>:<fingerprint>
# where <fingerprint> hashes the current unlanded-work inventory. Re-run with
# --discard-authority <token> to proceed. A token minted for another project,
# or minted before the inventory changed, refuses again - vague approval and
# replayed or mismatched tokens can never satisfy the check.
#
# Transaction order (mutations happen strictly in this order, each gated on
# the previous step):
#   1. every check above passes, or every blocker is discardable and exactly
#      covered by the presented discard-authority token; a per-project
#      transaction lock and a shared registry lock are acquired and the
#      complete risk inventory is rechecked unchanged immediately before
#      mutation
#   2. `git worktree prune` inside the clone (supported owner tool, safe:
#      it drops only registrations whose directories are already gone)
#   3. the clone is atomically renamed into a restrictive same-filesystem
#      quarantine and the quarantined payload and external control inventory
#      are reverified
#   4. deletion-boundary drain: after the rename no NEW handle can reach the
#      payload through the canonical clone path, so the transaction refuses
#      (restoring the clone) while any process still holds an open file,
#      map, cwd, or root handle inside the quarantine, re-verifies the
#      payload and external control inventory one final time after the drain,
#      and only then removes the verified quarantine
#   5. both the original clone path and quarantine are verified absent; an
#      incomplete removal stops LOUDLY here and leaves the registry untouched,
#      so the registry never claims a clone is gone while bytes remain
#   6. only then is the data/projects.md line for exactly <name> dropped, via
#      an atomic rewrite that leaves every other line byte-identical
# The transaction never stashes, never resets, never force-deletes branches,
# and never removes anything outside the verified clone path.
#
# Idempotent stale-registry repair: when data/projects.md still lists <name>
# but no clone exists, the same command performs only steps 5-6 and reports the
# repair. A leftover removal quarantine for <name> under projects/ means an
# earlier transaction was interrupted, NOT that the registry is stale: every
# mode refuses loudly before classifying the clone as absent, names the
# quarantine, and explains the restore step, so preserved bytes are never
# orphaned by a registry repair. When neither a clone, nor a registry entry,
# nor a leftover quarantine exists, it fails loudly instead of reporting
# success for a possible typo.
#
# bin/fm-teardown.sh remains the single owner of the task-worktree landed-work
# test; this script owns only the clone-retirement risk inventory above.
#
# Usage:
#   fm-project-remove.sh <name> --check
#       Read-only inventory: report every blocker (and the discard token when
#       only discardable blockers exist) without mutating anything. Exits 0
#       when removal would proceed cleanly, 1 when blocked.
#   fm-project-remove.sh <name> --confirm <name> [--discard-authority <token>]
#       Perform the removal transaction. --confirm must repeat the exact
#       project name; a mismatch refuses before any mutation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTUAL_FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$ACTUAL_FM_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REG="$DATA/projects.md"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: fm-project-remove.sh <name> --check
       fm-project-remove.sh <name> --confirm <name> [--discard-authority <token>]
The header comment of this script owns the full contract; read it before use.
EOF
}

NAME=
MODE_CHECK=0
CONFIRM=
AUTHORITY=
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE_CHECK=1 ;;
    --confirm)
      [ $# -ge 2 ] || { usage >&2; die "--confirm requires the exact project name as its value"; }
      shift
      CONFIRM=$1
      ;;
    --discard-authority)
      [ $# -ge 2 ] || { usage >&2; die "--discard-authority requires a token value"; }
      shift
      AUTHORITY=$1
      ;;
    -h|--help) usage; exit 0 ;;
    --*) usage >&2; die "unknown flag: $1" ;;
    *)
      [ -z "$NAME" ] || { usage >&2; die "exactly one project name is accepted (got '$NAME' and '$1')"; }
      NAME=$1
      ;;
  esac
  shift
done

[ -n "$NAME" ] || { usage >&2; die "a project name is required"; }
case "$NAME" in
  .|..|-*|*/*|*[!A-Za-z0-9._-]*)
    die "invalid project name '$NAME': pass the bare registered name (letters, digits, dot, underscore, dash; never a path, never a leading dash)"
    ;;
esac

if [ "$MODE_CHECK" -eq 1 ]; then
  [ -z "$CONFIRM" ] && [ -z "$AUTHORITY" ] \
    || die "--check is read-only and takes neither --confirm nor --discard-authority"
else
  [ -n "$CONFIRM" ] \
    || die "removal requires --confirm '$NAME' repeating the exact project name (use --check for a read-only inventory)"
  [ "$CONFIRM" = "$NAME" ] \
    || die "confirmation mismatch: --confirm '$CONFIRM' does not name project '$NAME'; nothing was changed"
fi

# Physical path of an EXISTING directory; fails when it does not exist.
canonical_existing_dir() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# Physical path for a path that may not (fully) exist: canonicalize the deepest
# existing ancestor, then re-append the untouched tail. Used only for
# comparisons, never as a deletion target.
canonical_path() {
  local path=$1 tail='' base
  case "$path" in
    /*) : ;;
    *) path="$(pwd -P)/$path" ;;
  esac
  while [ "$path" != / ] && [ "${path%/}" != "$path" ]; do
    path=${path%/}
  done
  while [ ! -d "$path" ] && [ "$path" != / ]; do
    tail="/$(basename "$path")$tail"
    path=$(dirname "$path")
  done
  base=$(cd "$path" && pwd -P)
  if [ "$base" = / ] && [ -n "$tail" ]; then
    printf '%s\n' "$tail"
  else
    printf '%s%s\n' "$base" "$tail"
  fi
}

[ -z "${FM_STATE_OVERRIDE:-}" ] \
  || die "refusing: FM_STATE_OVERRIDE cannot redirect state outside the active FM_HOME"
[ -z "${FM_DATA_OVERRIDE:-}" ] \
  || die "refusing: FM_DATA_OVERRIDE cannot redirect data outside the active FM_HOME"
[ -z "${FM_PROJECTS_OVERRIDE:-}" ] \
  || die "refusing: FM_PROJECTS_OVERRIDE cannot redirect projects outside the active FM_HOME"

FM_HOME_PHYS=$(canonical_existing_dir "$FM_HOME") \
  || die "cannot resolve active FM_HOME $FM_HOME"
EXPECTED_STATE=$(canonical_path "$FM_HOME/state") \
  || die "cannot resolve the active home's state directory"
EXPECTED_DATA=$(canonical_path "$FM_HOME/data") \
  || die "cannot resolve the active home's data directory"
EXPECTED_PROJECTS=$(canonical_path "$FM_HOME/projects") \
  || die "cannot resolve the active home's projects directory"
STATE_PHYS=$(canonical_path "$STATE") \
  || die "cannot resolve state directory $STATE"
DATA_PHYS=$(canonical_path "$DATA") \
  || die "cannot resolve data directory $DATA"
PROJECTS_CONFIG_PHYS=$(canonical_path "$PROJECTS") \
  || die "cannot resolve projects directory $PROJECTS"
[ "$STATE_PHYS" = "$EXPECTED_STATE" ] \
  || die "refusing: state directory $STATE is outside the active FM_HOME $FM_HOME"
[ "$DATA_PHYS" = "$EXPECTED_DATA" ] \
  || die "refusing: data directory $DATA is outside the active FM_HOME $FM_HOME"
[ "$PROJECTS_CONFIG_PHYS" = "$EXPECTED_PROJECTS" ] \
  || die "refusing: projects directory $PROJECTS is outside the active FM_HOME $FM_HOME"

require_control_root_under_home() {
  local label=$1 resolved=$2
  [ "$resolved" != "$FM_HOME_PHYS" ] \
    || die "refusing: $label directory resolves to the active FM_HOME root instead of beneath it"
  case "$resolved/" in
    "$FM_HOME_PHYS"/*) : ;;
    *) die "refusing: $label directory resolves outside the active FM_HOME $FM_HOME" ;;
  esac
}

require_control_root_under_home state "$STATE_PHYS"
require_control_root_under_home data "$DATA_PHYS"
require_control_root_under_home projects "$PROJECTS_CONFIG_PHYS"

if command -v shasum >/dev/null 2>&1; then
  HASH_TOOL=shasum
elif command -v sha256sum >/dev/null 2>&1; then
  HASH_TOOL=sha256sum
else
  die "refusing: SHA-256 is unavailable; discard-authority fingerprints cannot be created safely"
fi

fm_refuse_if_gate_agent
if [ "$MODE_CHECK" -eq 1 ]; then
  FM_GUARD_READ_ONLY=1 "$FM_ROOT/bin/fm-guard.sh" || true
else
  "$FM_ROOT/bin/fm-guard.sh" || true
fi

export GIT_OPTIONAL_LOCKS=0

fingerprint_hash() {
  local digest
  case "$HASH_TOOL" in
    shasum) digest=$(shasum -a 256 | awk '{print $1}') || return 1 ;;
    sha256sum) digest=$(sha256sum | awk '{print $1}') || return 1 ;;
    *) return 1 ;;
  esac
  [ "${#digest}" -eq 64 ] || return 1
  case "$digest" in
    *[!0-9a-f]*) return 1 ;;
  esac
  printf '%s\n' "$digest"
}

path_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

path_device() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%d' "$1" 2>/dev/null
  else
    stat -c '%d' "$1" 2>/dev/null
  fi
}

hash_inventory_entries() {
  local root=$1 rel full path_hash content_hash link_target mode
  while IFS= read -r -d '' rel; do
    case "$rel" in
      "$root"/*) rel=${rel#"$root"/} ;;
    esac
    full="$root/$rel"
    path_hash=$(printf '%s' "$rel" | fingerprint_hash) || return 1
    mode=$(path_mode "$full") || return 1
    if [ -L "$full" ]; then
      link_target=$(readlink "$full") || return 1
      content_hash=$(printf '%s' "$link_target" | fingerprint_hash) || return 1
      printf 'symlink:%s:%s:%s\n' "$mode" "$path_hash" "$content_hash"
    elif [ -f "$full" ]; then
      content_hash=$(fingerprint_hash < "$full") || return 1
      printf 'file:%s:%s:%s\n' "$mode" "$path_hash" "$content_hash"
    elif [ -d "$full" ]; then
      printf 'directory:%s:%s\n' "$mode" "$path_hash"
    elif [ -p "$full" ]; then
      printf 'fifo:%s:%s\n' "$mode" "$path_hash"
    elif [ -S "$full" ]; then
      printf 'socket:%s:%s\n' "$mode" "$path_hash"
    elif [ -b "$full" ]; then
      printf 'block:%s:%s\n' "$mode" "$path_hash"
    elif [ -c "$full" ]; then
      printf 'character:%s:%s\n' "$mode" "$path_hash"
    elif [ ! -e "$full" ]; then
      printf 'missing:%s\n' "$path_hash"
    else
      return 1
    fi
  done
}

repo_inventory_hash() {
  local repo=$1 index_hash files_hash
  index_hash=$(git -C "$repo" ls-files --stage -z | fingerprint_hash) || return 1
  files_hash=$(
    find "$repo" -mindepth 1 -path "$repo/.git" -prune -o -print0 \
      | hash_inventory_entries "$repo" \
      | LC_ALL=C sort \
      | fingerprint_hash
  ) || return 1
  printf 'index:%s\nfiles:%s\n' "$index_hash" "$files_hash" | fingerprint_hash
}

full_tree_inventory_hash() {
  local root=$1 root_mode entries_hash link_hash
  root_mode=$(path_mode "$root") || return 1
  if [ -L "$root" ]; then
    link_hash=$(readlink "$root" | fingerprint_hash) || return 1
    printf 'symlink-root:%s:%s\n' "$root_mode" "$link_hash" | fingerprint_hash
    return
  fi
  [ -d "$root" ] || return 1
  entries_hash=$(
    find "$root" -mindepth 1 -print0 \
      | hash_inventory_entries "$root" \
      | LC_ALL=C sort \
      | fingerprint_hash
  ) || return 1
  printf 'directory-root:%s\nentries:%s\n' "$root_mode" "$entries_hash" | fingerprint_hash
}

nested_mount_records() {
  local repo=$1 root_device path device mountpoint decoded
  root_device=$(path_device "$repo") || return 1
  find "$repo" -xdev -mindepth 1 -print >/dev/null 2>&1 || return 1
  while IFS= read -r -d '' path; do
    device=$(path_device "$path") || return 1
    [ "$device" = "$root_device" ] || printf 'device:%s\n' "$path"
  done < <(find "$repo" -xdev -mindepth 1 -print0 2>/dev/null)
  if [ "$(uname)" = Linux ]; then
    [ -r /proc/self/mountinfo ] || return 1
    while IFS=' ' read -r _ _ _ _ mountpoint _; do
      decoded=$(printf '%b' "$mountpoint") || return 1
      [ "$decoded" != "$repo" ] || continue
      case "$decoded/" in
        "$repo"/*) printf 'mountinfo:%s\n' "$decoded" ;;
      esac
    done < /proc/self/mountinfo
  fi
}

optional_path_hash() {
  local path=$1 link_hash content_hash mode
  if [ -L "$path" ]; then
    mode=$(path_mode "$path") || return 1
    link_hash=$(readlink "$path" | fingerprint_hash) || return 1
    if [ -f "$path" ]; then
      content_hash=$(fingerprint_hash < "$path") || return 1
    else
      content_hash=not-a-file
    fi
    printf 'symlink:%s:%s:%s\n' "$mode" "$link_hash" "$content_hash" | fingerprint_hash
  elif [ -f "$path" ]; then
    mode=$(path_mode "$path") || return 1
    content_hash=$(fingerprint_hash < "$path") || return 1
    printf 'file:%s:%s\n' "$mode" "$content_hash" | fingerprint_hash
  elif [ -e "$path" ]; then
    return 1
  else
    printf 'absent\n' | fingerprint_hash
  fi
}

state_meta_inventory_hash() {
  local entries_hash
  if [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; then
    printf 'absent\n' | fingerprint_hash
    return
  fi
  [ -d "$STATE" ] || return 1
  entries_hash=$(
    find "$STATE" -mindepth 1 -maxdepth 1 -name '*.meta' -print0 \
      | hash_inventory_entries "$STATE" \
      | LC_ALL=C sort \
      | fingerprint_hash
  ) || return 1
  printf 'meta:%s\n' "$entries_hash" | fingerprint_hash
}

git_repository_state_hash() {
  local repo=$1 include_worktrees=${2:-1} worktrees status stashes remotes refs objects head_state index_hash worktrees_hash
  if [ "$include_worktrees" -eq 1 ]; then
    worktrees=$(git -C "$repo" worktree list --porcelain 2>/dev/null) || return 1
    worktrees_hash=$(printf '%s' "$worktrees" | fingerprint_hash) || return 1
  else
    worktrees_hash=omitted
  fi
  status=$(git -C "$repo" status --porcelain=v1 --untracked-files=all --ignored=traditional 2>/dev/null) || return 1
  stashes=$(git -C "$repo" stash list --format='%H' 2>/dev/null) || return 1
  remotes=$(git -C "$repo" remote 2>/dev/null) || return 1
  refs=$(git -C "$repo" for-each-ref --format='%(refname) %(objectname)' 2>/dev/null) || return 1
  index_hash=$(git -C "$repo" ls-files --stage -z | fingerprint_hash) || return 1
  objects=$(
    git -C "$repo" cat-file --batch-all-objects --batch-check='%(objectname) %(objecttype) %(objectsize)' 2>/dev/null \
      | LC_ALL=C sort
  ) || return 1
  if head_state=$(git -C "$repo" rev-parse -q --verify HEAD 2>/dev/null); then
    :
  else
    [ "$?" -eq 1 ] || return 1
    head_state=unborn
  fi
  printf 'worktrees:%s\nstatus:%s\nstashes:%s\nremotes:%s\nrefs:%s\nobjects:%s\nhead:%s\nindex:%s\n' \
    "$worktrees_hash" \
    "$(printf '%s' "$status" | fingerprint_hash)" \
    "$(printf '%s' "$stashes" | fingerprint_hash)" \
    "$(printf '%s' "$remotes" | fingerprint_hash)" \
    "$(printf '%s' "$refs" | fingerprint_hash)" \
    "$(printf '%s' "$objects" | fingerprint_hash)" \
    "$head_state" "$index_hash" \
    | fingerprint_hash
}

root_git_state_hash() {
  git_repository_state_hash "$TARGET" 1
}

nested_git_marker_records() {
  local repo=$1 marker marker_first_line worktree gitdir common gitdir_phys common_phys scope path_hash gitdir_id common_id state_hash gitdir_hash common_hash modules modules_hash marker_records
  marker_records=$(
    find "$repo" -path "$repo/.git" -prune -o -mindepth 2 -name .git -print0 \
      | while IFS= read -r -d '' marker; do
        # Only a marker git itself validates is a nested repository; an entry
        # merely NAMED .git (cache file, empty or corrupt directory, fifo,
        # dangling symlink) stays ordinary discardable payload and is already
        # fingerprinted by the tree inventory. Validation never opens
        # non-regular files, so a fifo cannot stall the inventory.
        if [ -d "$marker" ]; then
          git rev-parse --resolve-git-dir "$marker" >/dev/null 2>&1 || continue
        elif [ -f "$marker" ] && [ ! -L "$marker" ]; then
          marker_first_line=
          IFS= read -r marker_first_line < "$marker" || true
          case "$marker_first_line" in
            "gitdir:"*) : ;;
            *) continue ;;
          esac
          git rev-parse --resolve-git-dir "$marker" >/dev/null 2>&1 || continue
        else
          continue
        fi
        worktree=${marker%/.git}
        gitdir=$(git -C "$worktree" rev-parse --absolute-git-dir 2>/dev/null) || return 1
        common=$(git -C "$worktree" rev-parse --git-common-dir 2>/dev/null) || return 1
        case "$common" in
          /*) : ;;
          *) common="$worktree/$common" ;;
        esac
        gitdir_phys=$(canonical_existing_dir "$gitdir") || return 1
        common_phys=$(canonical_existing_dir "$common") || return 1
        scope=inside
        case "$gitdir_phys/" in "$repo"/*) : ;; *) scope=external ;; esac
        case "$common_phys/" in "$repo"/*) : ;; *) scope=external ;; esac
        path_hash=$(printf '%s' "${marker#"$repo"/}" | fingerprint_hash) || return 1
        case "$gitdir_phys/" in
          "$repo"/*) gitdir_id=${gitdir_phys#"$repo"/} ;;
          *) gitdir_id=$gitdir_phys ;;
        esac
        case "$common_phys/" in
          "$repo"/*) common_id=${common_phys#"$repo"/} ;;
          *) common_id=$common_phys ;;
        esac
        gitdir_id=$(printf '%s' "$gitdir_id" | fingerprint_hash) || return 1
        common_id=$(printf '%s' "$common_id" | fingerprint_hash) || return 1
        state_hash=$(git_repository_state_hash "$worktree" 0) || return 1
        gitdir_hash=$(full_tree_inventory_hash "$gitdir_phys") || return 1
        if [ "$common_phys" = "$gitdir_phys" ]; then
          common_hash=$gitdir_hash
        else
          common_hash=$(full_tree_inventory_hash "$common_phys") || return 1
        fi
        printf 'repo:%s:%s:%s:%s:%s:%s\n' "$path_hash" "$scope" "$gitdir_id" "$common_id" "$state_hash" \
          "$(printf 'gitdir:%s\ncommon:%s\n' "$gitdir_hash" "$common_hash" | fingerprint_hash)"
        done
  ) || return 1
  [ -z "$marker_records" ] || printf '%s\n' "$marker_records"
  modules="$repo/.git/modules"
  if [ -e "$modules" ] || [ -L "$modules" ]; then
    modules_hash=$(full_tree_inventory_hash "$modules") || return 1
    if [ -L "$modules" ]; then
      scope=external
    else
      scope=inside
    fi
    printf 'modules:%s:%s\n' "$scope" "$modules_hash"
  fi
}

nested_git_state_hash() {
  local repo=$1 records
  records=$(nested_git_marker_records "$repo") || return 1
  printf '%s' "$records" | LC_ALL=C sort | fingerprint_hash
}

worktree_presence_hash() {
  local inventory line path path_hash state
  inventory=$(git -C "$TARGET" worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path=${line#worktree }
        path_hash=$(printf '%s' "$path" | fingerprint_hash) || return 1
        if [ -e "$path" ] || [ -L "$path" ]; then
          state=present
        else
          state=absent
        fi
        printf '%s:%s\n' "$path_hash" "$state"
        ;;
    esac
  done <<< "$inventory" | LC_ALL=C sort | fingerprint_hash
}

transaction_inventory_hash() {
  local tree_hash git_hash nested_hash presence_hash meta_hash backlog_hash secondmates_hash registry_hash
  tree_hash=$(repo_inventory_hash "$TARGET") || return 1
  git_hash=$(root_git_state_hash) || return 1
  nested_hash=$(nested_git_state_hash "$TARGET") || return 1
  presence_hash=$(worktree_presence_hash) || return 1
  meta_hash=$(state_meta_inventory_hash) || return 1
  backlog_hash=$(optional_path_hash "$DATA/backlog.md") || return 1
  secondmates_hash=$(optional_path_hash "$DATA/secondmates.md") || return 1
  registry_hash=$(optional_path_hash "$REG") || return 1
  printf 'tree:%s\ngit:%s\nnested:%s\nworktree-presence:%s\nmeta:%s\nbacklog:%s\nsecondmates:%s\nregistry:%s\n' \
    "$tree_hash" "$git_hash" "$nested_hash" "$presence_hash" "$meta_hash" "$backlog_hash" "$secondmates_hash" "$registry_hash" \
    | fingerprint_hash
}

control_inventory_hash() {
  local meta_hash backlog_hash secondmates_hash registry_hash
  meta_hash=$(state_meta_inventory_hash) || return 1
  backlog_hash=$(optional_path_hash "$DATA/backlog.md") || return 1
  secondmates_hash=$(optional_path_hash "$DATA/secondmates.md") || return 1
  registry_hash=$(optional_path_hash "$REG") || return 1
  printf 'meta:%s\nbacklog:%s\nsecondmates:%s\nregistry:%s\n' \
    "$meta_hash" "$backlog_hash" "$secondmates_hash" "$registry_hash" | fingerprint_hash
}

deletion_boundary_hash() {
  local repo=$1 include_full_git=${2:-1} tree_hash git_hash nested_hash gitdir_hash
  tree_hash=$(repo_inventory_hash "$repo") || return 1
  git_hash=$(git_repository_state_hash "$repo" 0) || return 1
  nested_hash=$(nested_git_state_hash "$repo") || return 1
  if [ "$include_full_git" -eq 1 ]; then
    gitdir_hash=$(full_tree_inventory_hash "$repo/.git") || return 1
  else
    gitdir_hash=omitted
  fi
  printf 'tree:%s\ngit:%s\nnested:%s\ngitdir:%s\n' "$tree_hash" "$git_hash" "$nested_hash" "$gitdir_hash" \
    | fingerprint_hash
}

normalized_worktree_state_hash() {
  local repo=$1 inventory line path path_hash state first=1 records=
  inventory=$(git -C "$repo" worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path=${line#worktree }
        if [ "$first" -eq 1 ]; then
          records="${records}primary"$'\n'
          first=0
        else
          path_hash=$(printf '%s' "$path" | fingerprint_hash) || return 1
          if [ -e "$path" ] || [ -L "$path" ]; then state=present; else state=absent; fi
          records="${records}linked:$path_hash:$state"$'\n'
        fi
        ;;
    esac
  done <<< "$inventory"
  [ "$first" -eq 0 ] || return 1
  printf '%s' "$records" | LC_ALL=C sort | fingerprint_hash
}

quarantine_boundary_hash() {
  local repo=$1 deletion_hash worktree_hash
  deletion_hash=$(deletion_boundary_hash "$repo") || return 1
  worktree_hash=$(normalized_worktree_state_hash "$repo") || return 1
  printf 'deletion:%s\nworktrees:%s\n' "$deletion_hash" "$worktree_hash" | fingerprint_hash
}

# Deletion-boundary handle scan: after the quarantine rename no NEW handle can
# be opened through the canonical clone path, so the only writers that could
# still mutate the payload are processes that already hold an open file, map,
# cwd, or root handle inside it. Prints one line per held handle (empty output
# means drained); returns 2 when no scan mechanism exists on this platform, in
# which case the caller must refuse.
quarantine_open_handles() {
  local dir=$1 pid_dir proc_roots=() canary scan_canary output status line scan_verified
  if [ "$(uname)" = Linux ]; then
    [ -d /proc ] || return 2
    [ -r "/proc/$$/fd" ] && [ -x "/proc/$$/fd" ] || return 2
    canary=$(find "/proc/$$/fd" -mindepth 1 -maxdepth 1 -print 2>/dev/null) || return 2
    [ -n "$canary" ] || return 2
    scan_canary="/proc/$$/status"
    [ -r "$scan_canary" ] || return 2
    for pid_dir in /proc/[0-9]*; do
      proc_roots+=("$pid_dir/fd" "$pid_dir/map_files" "$pid_dir/cwd" "$pid_dir/root" "$pid_dir/exe")
    done
    [ "${#proc_roots[@]}" -gt 0 ] || return 2
    output=
    if output=$(find "${proc_roots[@]}" "$scan_canary" -maxdepth 1 \
      \( -path "$scan_canary" -print -o \( -lname "$dir" -o -lname "$dir/*" \) -print \) \
      2>/dev/null); then
      :
    fi
    scan_verified=0
    while IFS= read -r line; do
      if [ "$line" = "$scan_canary" ]; then
        scan_verified=1
      elif [ -n "$line" ]; then
        printf '%s\n' "$line"
      fi
    done <<< "$output"
    [ "$scan_verified" -eq 1 ] || return 2
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 2
  canary=$(lsof -a -p "$$" -d cwd -Fn 2>&1) || return 2
  [ -n "$canary" ] || return 2
  if output=$(lsof +D "$dir" 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -le 1 ] || return 2
  [ "$status" -eq 0 ] || { [ -z "$output" ] || return 2; }
  printf '%s\n' "$output" | awk 'NR > 1 { print $2, $4 }'
}

validate_discard_authority() {
  local current_token=$1
  [ -n "$AUTHORITY" ] || return 0
  case "$AUTHORITY" in
    "discard-unlanded:$NAME:"*)
      if [ -z "$current_token" ] || [ "$AUTHORITY" != "$current_token" ]; then
        die "discard authority does not match the CURRENT unlanded-work inventory of '$NAME' (the work changed after the token was issued, or no current discardable inventory exists); re-run --check and obtain fresh captain authority"
      fi
      ;;
    discard-unlanded:*)
      die "discard authority is scoped to a different project and cannot authorize discarding '$NAME'; nothing was changed"
      ;;
    *)
      die "unrecognized discard-authority token; expected discard-unlanded:$NAME:<fingerprint> from a refusal or --check run"
      ;;
  esac
}

stale_repair_inventory_hash() {
  local registry_hash clone_state
  registry_hash=$(optional_path_hash "$REG") || return 1
  if [ -e "$CLONE" ] || [ -L "$CLONE" ]; then
    clone_state=present
  else
    clone_state=absent
  fi
  printf 'registry:%s\nclone:%s\n' "$registry_hash" "$clone_state" | fingerprint_hash
}

PROJECT_REMOVE_LOCK=
PROJECT_REMOVE_LOCK_OWNER=
PROJECT_REMOVE_LOCK_HELD=0
REGISTRY_REMOVE_LOCK=
REGISTRY_REMOVE_LOCK_OWNER=
REGISTRY_REMOVE_LOCK_HELD=0
REGISTRY_TMP=
QUARANTINE_PARENT=
QUARANTINE=
QUARANTINE_PRESERVE=0

# shellcheck disable=SC2329
release_project_lock() {
  if [ -n "$REGISTRY_TMP" ]; then
    rm -f -- "$REGISTRY_TMP" 2>/dev/null || true
    REGISTRY_TMP=
  fi
  if [ -n "$QUARANTINE_PARENT" ] && [ "$QUARANTINE_PRESERVE" -eq 0 ]; then
    rmdir "$QUARANTINE_PARENT" 2>/dev/null || true
  fi
  if [ "$REGISTRY_REMOVE_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$REGISTRY_REMOVE_LOCK"
    REGISTRY_REMOVE_LOCK_HELD=0
  fi
  if [ "$PROJECT_REMOVE_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$PROJECT_REMOVE_LOCK"
    PROJECT_REMOVE_LOCK_HELD=0
  fi
}

acquire_project_lock() {
  [ -d "$STATE" ] && [ -r "$STATE" ] && [ -w "$STATE" ] \
    || die "refusing: state directory $STATE must be readable and writable to lock project removal"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  PROJECT_REMOVE_LOCK="$STATE/.project-remove-$NAME.lock"
  if ! fm_lock_try_acquire "$PROJECT_REMOVE_LOCK"; then
    die "refusing: another project-removal transaction holds $PROJECT_REMOVE_LOCK"
  fi
  PROJECT_REMOVE_LOCK_OWNER=$FM_LOCK_OWNER_DIR
  PROJECT_REMOVE_LOCK_HELD=1
  trap release_project_lock EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  REGISTRY_REMOVE_LOCK="$STATE/.project-remove-registry.lock"
  if ! fm_lock_try_acquire "$REGISTRY_REMOVE_LOCK"; then
    die "refusing: another project-removal transaction holds the shared registry lock $REGISTRY_REMOVE_LOCK"
  fi
  REGISTRY_REMOVE_LOCK_OWNER=$FM_LOCK_OWNER_DIR
  REGISTRY_REMOVE_LOCK_HELD=1
}

verify_project_lock() {
  if [ "$PROJECT_REMOVE_LOCK_HELD" -ne 1 ] \
    || ! fm_lock_points_to_owner "$PROJECT_REMOVE_LOCK" "$PROJECT_REMOVE_LOCK_OWNER" \
    || [ "$REGISTRY_REMOVE_LOCK_HELD" -ne 1 ] \
    || ! fm_lock_points_to_owner "$REGISTRY_REMOVE_LOCK" "$REGISTRY_REMOVE_LOCK_OWNER"; then
    die "refusing: project-removal transaction lock was lost before mutation"
  fi
}

prepare_project_quarantine() {
  local old_umask mode
  old_umask=$(umask)
  umask 077
  if ! QUARANTINE_PARENT=$(mktemp -d "$PROJECTS/.fm-project-remove-$NAME.XXXXXX"); then
    umask "$old_umask"
    die "refusing: could not create a same-directory project quarantine under $PROJECTS"
  fi
  umask "$old_umask"
  [ -d "$QUARANTINE_PARENT" ] && [ ! -L "$QUARANTINE_PARENT" ] \
    || die "refusing: project quarantine is not an ordinary directory: $QUARANTINE_PARENT"
  chmod 700 "$QUARANTINE_PARENT" \
    || die "refusing: could not restrict project quarantine $QUARANTINE_PARENT"
  mode=$(path_mode "$QUARANTINE_PARENT") || die "refusing: cannot inspect project quarantine $QUARANTINE_PARENT"
  [ "$mode" = 700 ] || die "refusing: project quarantine $QUARANTINE_PARENT has unsafe mode $mode"
  QUARANTINE="$QUARANTINE_PARENT/clone"
}

refuse_quarantined_change() {
  local reason=$1
  if [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ] && [ -d "$QUARANTINE" ] && [ ! -L "$QUARANTINE" ]; then
    if mv "$QUARANTINE" "$TARGET"; then
      rmdir "$QUARANTINE_PARENT" 2>/dev/null || true
      QUARANTINE=
      QUARANTINE_PARENT=
      die "$reason; the quarantined clone was restored to $TARGET"
    fi
  fi
  QUARANTINE_PRESERVE=1
  die "$reason; registry left untouched and quarantined bytes preserved at $QUARANTINE"
}

registry_has_entry() {
  [ ! -L "$REG" ] || die "refusing: project registry $REG is a symlink"
  [ -f "$REG" ] || return 1
  [ -r "$REG" ] || die "cannot read project registry $REG"
  awk -v n="$NAME" '$1 == "-" && $2 == n { found = 1; exit } END { exit found ? 0 : 1 }' "$REG"
}

# Atomic registry rewrite dropping exactly the "- <name> ..." line(s); every
# other line is passed through byte-identical. Verified after the swap.
remove_registry_line() {
  local old_umask tmp_mode reg_mode
  [ -f "$REG" ] && [ ! -L "$REG" ] || die "could not rewrite $REG; registry is not an ordinary file"
  reg_mode=$(path_mode "$REG") || die "could not inspect $REG; registry left untouched"
  old_umask=$(umask)
  umask 077
  if ! REGISTRY_TMP=$(mktemp "$DATA/.projects.md.tmp.XXXXXX"); then
    umask "$old_umask"
    die "could not create a restrictive same-directory temporary registry file; registry left untouched"
  fi
  umask "$old_umask"
  [ -f "$REGISTRY_TMP" ] && [ ! -L "$REGISTRY_TMP" ] \
    || die "could not create an ordinary temporary registry file; registry left untouched"
  tmp_mode=$(path_mode "$REGISTRY_TMP") || die "could not inspect the temporary registry file; registry left untouched"
  [ "$tmp_mode" = 600 ] || die "temporary registry file has unsafe mode $tmp_mode; registry left untouched"
  awk -v n="$NAME" '!($1 == "-" && $2 == n)' "$REG" > "$REGISTRY_TMP" \
    || die "could not rewrite $REG; registry left untouched"
  chmod "$reg_mode" "$REGISTRY_TMP" \
    || die "could not preserve the mode of $REG; registry left untouched"
  mv "$REGISTRY_TMP" "$REG" || die "could not replace $REG; registry left untouched"
  REGISTRY_TMP=
  if registry_has_entry; then
    die "registry rewrite failed to drop the '$NAME' line from $REG"
  fi
}

[ ! -L "$PROJECTS" ] \
  || die "refusing: projects directory $PROJECTS is a symlink; resolve it before any removal"

CLONE="$PROJECTS/$NAME"
clone_present=0
if [ -e "$CLONE" ] || [ -L "$CLONE" ]; then
  [ ! -L "$CLONE" ] \
    || die "refusing: $CLONE is a symlink, not a clone directory; a removable clone must live directly under projects/"
  [ -d "$CLONE" ] \
    || die "refusing: $CLONE exists but is not a directory"
  clone_present=1
fi

reg_present=0
registry_has_entry && reg_present=1

# An earlier removal of this project interrupted between quarantine and
# deletion leaves preserved clone bytes under projects/.fm-project-remove-
# <name>.*; that is recoverable work, never a stale registry. Refuse in every
# mode before any branch below can classify the clone as absent.
if [ -d "$PROJECTS" ]; then
  leftover_quarantines=$(
    find "$PROJECTS" -mindepth 1 -maxdepth 1 -name ".fm-project-remove-$NAME.*" -print \
      | LC_ALL=C sort
  ) || die "refusing: cannot scan $PROJECTS for interrupted-removal quarantines of '$NAME'"
  if [ -n "$leftover_quarantines" ]; then
    leftover_quarantine=${leftover_quarantines%%$'\n'*}
    if [ -d "$leftover_quarantine" ] && [ ! -L "$leftover_quarantine" ]; then
      leftover_probe=$(find "$leftover_quarantine" -mindepth 1 -print -quit 2>/dev/null || printf 'unreadable')
    else
      leftover_probe=non-directory
    fi
    if [ -z "$leftover_probe" ]; then
      die "refusing: leftover removal quarantine $leftover_quarantine from an interrupted removal of '$NAME' is empty residue; inspect and remove that directory, then re-run"
    fi
    if [ -e "$leftover_quarantine/clone" ] || [ -L "$leftover_quarantine/clone" ]; then
      die "refusing: an earlier removal of '$NAME' was interrupted and quarantined clone bytes remain at $leftover_quarantine; this is NOT a stale registry and no repair will run - inspect the quarantine and, when the content should come back, restore it with: mv '$leftover_quarantine/clone' '$CLONE' (then remove the empty quarantine directory and re-run)"
    fi
    die "refusing: an earlier removal of '$NAME' left unexpected content in quarantine $leftover_quarantine; this is NOT a stale registry - inspect and resolve it by hand, then re-run"
  fi
fi

if [ "$clone_present" -eq 0 ]; then
  if [ "$reg_present" -eq 0 ]; then
    die "nothing to remove: project '$NAME' has no clone under $PROJECTS and no data/projects.md entry in this home; check the name and the active home"
  fi
  if [ "$MODE_CHECK" -eq 1 ]; then
    printf 'stale registry: data/projects.md lists %s but no clone exists at %s; a removal run will repair the registry line\n' "$NAME" "$CLONE"
    exit 0
  fi
  validate_discard_authority ""
  stale_snapshot=$(stale_repair_inventory_hash) \
    || die "refusing: cannot snapshot the stale registry repair inventory"
  acquire_project_lock
  locked_stale_snapshot=$(stale_repair_inventory_hash) \
    || die "refusing: cannot recheck the stale registry repair inventory under lock"
  [ "$locked_stale_snapshot" = "$stale_snapshot" ] \
    || die "refusing: project or registry inventory changed before stale-registry repair; re-run the command"
  verify_project_lock
  { [ ! -e "$CLONE" ] && [ ! -L "$CLONE" ]; } \
    || die "refusing: $CLONE appeared during the repair; re-run to take the full removal path"
  remove_registry_line
  printf 'repaired stale registry: removed the %s line from %s (no clone existed at %s)\n' "$NAME" "$REG" "$CLONE"
  exit 0
fi

PROJECTS_PHYS=$(canonical_existing_dir "$PROJECTS") \
  || die "cannot resolve projects directory $PROJECTS"
TARGET=$(canonical_existing_dir "$CLONE") \
  || die "cannot resolve clone directory $CLONE"
[ "$TARGET" = "$PROJECTS_PHYS/$NAME" ] \
  || die "refusing: $CLONE resolves to $TARGET, not $PROJECTS_PHYS/$NAME; wrong home or a relocated clone"
[ "$TARGET" != / ] || die "refusing: resolved target is the filesystem root"
nested_mounts=$(nested_mount_records "$TARGET") \
  || die "refusing: cannot verify that $TARGET contains no nested mountpoints"
[ -z "$nested_mounts" ] \
  || die "refusing: nested mountpoint exists under $TARGET: ${nested_mounts%%$'\n'*}"

ACTUAL_FM_ROOT_PHYS=$(canonical_existing_dir "$ACTUAL_FM_ROOT") \
  || die "cannot resolve the running firstmate checkout $ACTUAL_FM_ROOT"
case "$ACTUAL_FM_ROOT_PHYS/" in
  "$TARGET"/*) die "refusing: this firstmate checkout ($ACTUAL_FM_ROOT_PHYS) is at or under the removal target" ;;
esac
FM_ROOT_PHYS=$(canonical_existing_dir "$FM_ROOT" || printf '%s' "$FM_ROOT")
case "$FM_ROOT_PHYS/" in
  "$TARGET"/*) die "refusing: configured firstmate root ($FM_ROOT_PHYS) is at or under the removal target" ;;
esac
case "$FM_HOME_PHYS/" in
  "$TARGET"/*) die "refusing: the active FM_HOME ($FM_HOME_PHYS) is at or under the removal target" ;;
esac

[ -e "$TARGET/.git" ] \
  || die "refusing: $TARGET has no .git, so this transaction cannot verify it as a managed clone and will not remove it"
[ ! -f "$TARGET/.git" ] \
  || die "refusing: $TARGET/.git is a gitfile - the clone is itself a linked worktree of another repository; removing it here would corrupt that repository's worktree registry"
common=$(git -C "$TARGET" rev-parse --git-common-dir 2>/dev/null) \
  || die "refusing: git cannot read $TARGET; will not remove what it cannot verify"
case "$common" in
  /*) : ;;
  *) common="$TARGET/$common" ;;
esac
common=$(canonical_path "$common")
case "$common/" in
  "$TARGET"/*) : ;;
  *) die "refusing: the git common dir of $TARGET resolves to $common, outside the clone; this is not a standalone clone" ;;
esac

initial_transaction_snapshot=$(transaction_inventory_hash) \
  || die "refusing: cannot capture the complete project-removal inventory"

STRUCTURAL=
DISCARDABLE=
INFO=
FPRINT=
add_structural() { STRUCTURAL="${STRUCTURAL}  - $1"$'\n'; }
add_discardable() { DISCARDABLE="${DISCARDABLE}  - $1"$'\n'; }
add_info() { INFO="${INFO}  - $1"$'\n'; }
add_fprint() { FPRINT="${FPRINT}$1"$'\n'; }

[ "$reg_present" -eq 1 ] \
  || add_info "not listed in data/projects.md; removing an unregistered clone (no registry line to drop)"

# Linked-worktree inventory. Registrations whose directories still exist are
# structural blockers; registrations whose directories are gone are noted and
# cleaned later (step 2) only through `git worktree prune`, after every check
# has passed.
worktree_inventory=$(git -C "$TARGET" worktree list --porcelain 2>/dev/null) \
  || die "refusing: cannot inventory linked worktrees of $TARGET"
primary_wt=$(printf '%s\n' "$worktree_inventory" | awk '/^worktree / { sub(/^worktree /, ""); print; exit }') \
  || die "refusing: cannot parse linked worktrees of $TARGET"
[ -n "$primary_wt" ] \
  || die "refusing: linked-worktree inventory for $TARGET did not identify the primary worktree"
primary_wt_phys=$(canonical_existing_dir "$primary_wt") \
  || die "refusing: cannot resolve primary worktree $primary_wt"
[ "$primary_wt_phys" = "$TARGET" ] \
  || die "refusing: linked-worktree inventory identifies $primary_wt_phys as primary instead of $TARGET"
first_wt=1
while IFS= read -r line; do
  case "$line" in
    "worktree "*)
      wt=${line#worktree }
      if [ "$first_wt" -eq 1 ]; then
        first_wt=0
        continue
      fi
      if [ -e "$wt" ]; then
        add_structural "linked worktree $wt still exists; tear its task down through bin/fm-teardown.sh first"
      else
        add_info "stale worktree registration for missing $wt; the removal run cleans it via git worktree prune"
      fi
      ;;
  esac
done <<< "$worktree_inventory"

nested_git_records=$(nested_git_marker_records "$TARGET") \
  || die "refusing: cannot completely inventory nested repository state in $TARGET"
if [ -n "$nested_git_records" ]; then
  nested_git_count=$(printf '%s\n' "$nested_git_records" | awk '/^repo:/ { count++ } END { print count + 0 }')
  nested_modules_count=$(printf '%s\n' "$nested_git_records" | awk '/^modules:/ { count++ } END { print count + 0 }')
  nested_external_count=$(printf '%s\n' "$nested_git_records" | awk -F: '$1 == "repo" && $3 == "external" { count++ } $1 == "modules" && $2 == "external" { count++ } END { print count + 0 }')
  [ "$nested_external_count" -eq 0 ] \
    || add_info "$nested_external_count nested repository gitdir store(s) resolve outside the clone; removal deletes only the in-clone checkout(s) and leaves each external store untouched, with a stale registration to clean through Git tooling afterwards"
  add_discardable "$nested_git_count nested repository worktree(s) and $nested_modules_count submodule gitdir store(s)"
  nested_git_inventory_hash=$(printf '%s\n' "$nested_git_records" | LC_ALL=C sort | fingerprint_hash) \
    || die "refusing: cannot fingerprint nested repository state in $TARGET"
  add_fprint "nested:$nested_git_inventory_hash"
fi

dirty=$(git -C "$TARGET" status --porcelain=v1 --untracked-files=all --ignored=traditional 2>/dev/null) \
  || die "refusing: cannot inventory the working tree of $TARGET"
if [ -n "$dirty" ]; then
  dirty_count=$(printf '%s\n' "$dirty" | grep -c .)
  add_discardable "$dirty_count dirty or untracked or ignored path report(s) (git status --porcelain)"
  dirty_inventory_hash=$(repo_inventory_hash "$TARGET") \
    || die "refusing: cannot hash the index and complete deletion payload of $TARGET"
  add_fprint "dirty:$dirty_inventory_hash"
fi

stashes=$(git -C "$TARGET" stash list --format='%H' 2>/dev/null) \
  || die "refusing: cannot inventory stashes of $TARGET"
if [ -n "$stashes" ]; then
  stash_count=$(printf '%s\n' "$stashes" | grep -c .)
  add_discardable "$stash_count stash entry(ies)"
  while IFS= read -r line; do
    [ -n "$line" ] && add_fprint "stash:$line"
  done <<EOF_STASH
$stashes
EOF_STASH
fi

remotes=$(git -C "$TARGET" remote 2>/dev/null) \
  || die "refusing: cannot inventory remotes of $TARGET"
[ -n "$remotes" ] || add_fprint "remote:none"

git_objects=$(
  git -C "$TARGET" cat-file --batch-all-objects --batch-check='%(objectname) %(objecttype)' 2>/dev/null \
    | LC_ALL=C sort -k1,1 -u
) || die "refusing: cannot inventory Git objects of $TARGET"
if [ -n "$remotes" ]; then
  remote_objects=$(git -C "$TARGET" rev-list --objects --remotes 2>/dev/null \
    | awk '{ print $1 }' \
    | LC_ALL=C sort -u) \
    || die "refusing: cannot inspect remote-tracking object reachability in $TARGET"
  unlanded_objects=$(LC_ALL=C join -v 1 -1 1 -2 1 \
    <(printf '%s\n' "$git_objects") \
    <(printf '%s' "$remote_objects")) \
    || die "refusing: cannot compare local and remote-tracking object inventories"
else
  unlanded_objects=$git_objects
fi
commit_count=0
noncommit_count=0
if [ -n "$unlanded_objects" ]; then
  commit_count=$(printf '%s\n' "$unlanded_objects" | awk '$2 == "commit" { count++ } END { print count + 0 }')
  noncommit_count=$(printf '%s\n' "$unlanded_objects" | awk '$2 != "commit" { count++ } END { print count + 0 }')
fi
if [ "$commit_count" -gt 0 ]; then
  if [ -n "$remotes" ]; then
    add_discardable "$commit_count commit object(s) are not reachable from any remote-tracking ref"
  else
    add_discardable "$commit_count commit object(s) exist only locally (the repository has no remote)"
  fi
fi
if [ "$noncommit_count" -gt 0 ]; then
  if [ -n "$remotes" ]; then
    add_discardable "$noncommit_count non-commit Git object(s) are not reachable from any remote-tracking ref"
  else
    add_discardable "$noncommit_count non-commit Git object(s) exist only locally (the repository has no remote)"
  fi
fi
if [ -n "$unlanded_objects" ]; then
  while IFS=' ' read -r object_sha object_type; do
    [ -n "$object_sha" ] && [ -n "$object_type" ] && add_fprint "object:$object_type:$object_sha"
  done <<< "$unlanded_objects"
fi

local_refs=$(git -C "$TARGET" for-each-ref --format='%(refname) %(objectname)' 2>/dev/null) \
  || die "refusing: cannot inventory local refs of $TARGET"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  refname=${line% *}
  refsha=${line##* }
  case "$refname" in
    refs/remotes/*|refs/heads/*|refs/stash) continue ;;
  esac
  add_discardable "local ref $refname ($refsha) is not a remote-tracking ref"
  add_fprint "ref:$refname:$refsha"
done <<< "$local_refs"

if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  [ -d "$STATE" ] || die "refusing: state path $STATE is not a directory"
  find "$STATE" -mindepth 1 -maxdepth 1 -name '*.meta' -print >/dev/null 2>&1 \
    || die "refusing: cannot completely enumerate live task metadata in $STATE"
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    task_id=$(basename "$meta" .meta)
    for field in project worktree home; do
      [ -r "$meta" ] || die "refusing: cannot read live task metadata $meta"
      val=$(awk -v key="$field=" 'index($0, key) == 1 { sub(key, ""); print; exit }' "$meta") \
        || die "refusing: cannot inspect live task metadata $meta"
      [ -n "$val" ] || continue
      vp=$(canonical_path "$val") \
        || die "refusing: cannot resolve $field=$val from $meta"
      case "$vp/" in
        "$TARGET"/*)
          add_structural "live task $task_id references the clone ($field=$val); tear it down through bin/fm-teardown.sh first"
          break
          ;;
      esac
    done
  done
fi

if [ -f "$DATA/backlog.md" ]; then
  [ -r "$DATA/backlog.md" ] || die "refusing: cannot read backlog $DATA/backlog.md"
  open_items=$(awk -v repo="$NAME" '
    /^- \[ \]/ {
      rest = $0
      while (match(rest, /\(repo:[[:space:]]*/)) {
        rest = substr(rest, RSTART + RLENGTH)
        end = match(rest, /[),]/)
        if (!end) break
        value = substr(rest, 1, end - 1)
        sub(/^[[:space:]]*/, "", value)
        sub(/[[:space:]]*$/, "", value)
        if (value == repo) {
          print $4
          break
        }
        rest = substr(rest, end + 1)
      }
    }
  ' "$DATA/backlog.md" | tr '\n' ' ') \
    || die "refusing: cannot inspect backlog $DATA/backlog.md"
  open_items=${open_items% }
  [ -z "$open_items" ] \
    || add_structural "open backlog item(s) tagged (repo: $NAME): $open_items; complete, re-home, or drop them in the backlog first"
fi

if [ -f "$DATA/secondmates.md" ]; then
  [ -r "$DATA/secondmates.md" ] || die "refusing: cannot read secondmate registry $DATA/secondmates.md"
  while IFS= read -r line; do
    case "$line" in
      "- "*) : ;;
      *) continue ;;
    esac
    sid=${line#- }
    sid=${sid%% *}
    csv=$(printf '%s\n' "$line" | sed -n 's/.*; projects:[[:space:]]*\([^;)]*\)[;)].*/\1/p') \
      || die "refusing: cannot inspect secondmate registry $DATA/secondmates.md"
    if [ -n "$csv" ]; then
      rest="$csv,"
      while [ -n "$rest" ]; do
        tok=${rest%%,*}
        rest=${rest#*,}
        tok=${tok# }
        tok=${tok% }
        if [ "$tok" = "$NAME" ]; then
          add_structural "secondmate $sid registers a clone of $NAME; reconcile it through secondmate-provisioning first"
          break
        fi
      done
    fi
    shome=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;)]*\);.*/\1/p') \
      || die "refusing: cannot inspect secondmate registry $DATA/secondmates.md"
    if [ -n "$shome" ]; then
      sp=$(canonical_path "$shome") \
        || die "refusing: cannot resolve secondmate home $shome"
      case "$sp/" in
        "$TARGET"/*) add_structural "secondmate $sid home $shome resolves under the clone; retire it through secondmate-provisioning first" ;;
      esac
    fi
  done < "$DATA/secondmates.md"
fi

expected_token=
if [ -n "$DISCARDABLE" ]; then
  fp=$(printf 'project:%s\n%s' "$NAME" "$FPRINT" | LC_ALL=C sort | fingerprint_hash)
  expected_token="discard-unlanded:$NAME:$fp"
fi

checked_transaction_snapshot=$(transaction_inventory_hash) \
  || die "refusing: cannot recheck the complete project-removal inventory"
[ "$checked_transaction_snapshot" = "$initial_transaction_snapshot" ] \
  || die "refusing: project-removal inventory changed while it was being checked; re-run --check"

report() {
  printf 'project-remove inventory for %s (%s):\n' "$NAME" "$TARGET"
  [ -z "$INFO" ] || printf 'notes:\n%s' "$INFO"
  [ -z "$STRUCTURAL" ] || printf 'structural blockers (never coverable by discard authority; resolve through their owner paths):\n%s' "$STRUCTURAL"
  [ -z "$DISCARDABLE" ] || printf 'unlanded work (discardable only with exact captain authority):\n%s' "$DISCARDABLE"
}

if [ "$MODE_CHECK" -eq 1 ]; then
  report
  if [ -n "$STRUCTURAL" ]; then
    echo "BLOCKED: structural blockers exist; removal will refuse until they are resolved through their owner paths." >&2
    exit 1
  fi
  if [ -n "$DISCARDABLE" ]; then
    printf 'discard token for exactly this inventory: %s\n' "$expected_token"
    printf 'authorized re-run: fm-project-remove.sh %s --confirm %s --discard-authority %s\n' "$NAME" "$NAME" "$expected_token"
    echo "BLOCKED: unlanded work exists; removal requires explicit captain discard authority for this exact inventory." >&2
    exit 1
  fi
  echo "clean: removal of $NAME would proceed with no blockers."
  exit 0
fi

if [ -n "$STRUCTURAL" ]; then
  report
  [ -z "$AUTHORITY" ] \
    || echo "note: discard authority can never cover structural blockers; it was ignored." >&2
  echo "REFUSED: structural blockers exist; resolve them through their owner paths, then re-run." >&2
  exit 1
fi

if [ -n "$DISCARDABLE" ] && [ -z "$AUTHORITY" ]; then
    report
    printf 'discard token for exactly this inventory: %s\n' "$expected_token"
    printf 'authorized re-run: fm-project-remove.sh %s --confirm %s --discard-authority %s\n' "$NAME" "$NAME" "$expected_token"
    echo "REFUSED: unlanded work exists; removal requires the captain's explicit discard authority for this exact inventory." >&2
    exit 1
fi
validate_discard_authority "$expected_token"

acquire_project_lock
locked_transaction_snapshot=$(transaction_inventory_hash) \
  || die "refusing: cannot recheck the complete project-removal inventory under lock"
[ "$locked_transaction_snapshot" = "$checked_transaction_snapshot" ] \
  || die "refusing: project-removal inventory changed before mutation; re-run --check and obtain fresh authority if required"
authorized_deletion_snapshot=$(deletion_boundary_hash "$TARGET" 0) \
  || die "refusing: cannot capture the authorized deletion payload under lock"
authorized_control_snapshot=$(control_inventory_hash) \
  || die "refusing: cannot capture the authorized external control inventory under lock"
prepared_transaction_snapshot=$(transaction_inventory_hash) \
  || die "refusing: cannot complete the final project-removal inventory check under lock"
[ "$prepared_transaction_snapshot" = "$locked_transaction_snapshot" ] \
  || die "refusing: project-removal inventory changed while preparing the deletion boundary; re-run --check"
verify_project_lock

# Step 2: prune stale worktree registrations through the supported owner tool,
# then refuse if any linked registration survives (locked or unprunable) - the
# clone and registry stay untouched in that case.
git -C "$TARGET" worktree prune 2>/dev/null \
  || die "refusing: git worktree prune failed for $TARGET; clone and registry left untouched"
post_prune_inventory=$(git -C "$TARGET" worktree list --porcelain 2>/dev/null) \
  || die "refusing: cannot verify linked worktrees after git worktree prune; clone and registry left untouched"
post_prune_primary=$(printf '%s\n' "$post_prune_inventory" | awk '/^worktree / { sub(/^worktree /, ""); print; exit }') \
  || die "refusing: cannot parse post-prune linked-worktree inventory"
[ -n "$post_prune_primary" ] \
  || die "refusing: post-prune inventory did not identify the primary worktree; clone and registry left untouched"
post_prune_primary_phys=$(canonical_existing_dir "$post_prune_primary") \
  || die "refusing: cannot resolve post-prune primary worktree $post_prune_primary"
[ "$post_prune_primary_phys" = "$TARGET" ] \
  || die "refusing: post-prune inventory identifies $post_prune_primary_phys as primary instead of $TARGET"
leftover_wt=$(printf '%s\n' "$post_prune_inventory" | awk '/^worktree / { count++ } END { print (count > 0 ? count - 1 : 0) }') \
  || die "refusing: cannot count linked worktrees after git worktree prune"
if [ "$leftover_wt" -gt 0 ]; then
  die "refusing: $leftover_wt linked worktree registration(s) survived git worktree prune (locked or unprunable); resolve them through git worktree tooling first - clone and registry left untouched"
fi

post_prune_deletion_snapshot=$(deletion_boundary_hash "$TARGET" 0) \
  || die "refusing: cannot revalidate the deletion payload after git worktree prune"
[ "$post_prune_deletion_snapshot" = "$authorized_deletion_snapshot" ] \
  || die "refusing: project payload changed during git worktree prune; clone and registry left untouched"
post_prune_control_snapshot=$(control_inventory_hash) \
  || die "refusing: cannot revalidate external control inventory after git worktree prune"
[ "$post_prune_control_snapshot" = "$authorized_control_snapshot" ] \
  || die "refusing: external control inventory changed during git worktree prune; clone and registry left untouched"
pre_quarantine_snapshot=$(quarantine_boundary_hash "$TARGET") \
  || die "refusing: cannot capture the post-prune quarantine boundary"
pre_rename_inventory=$(git -C "$TARGET" worktree list --porcelain 2>/dev/null) \
  || die "refusing: cannot perform the deletion-boundary worktree recheck"
pre_rename_worktree_count=$(printf '%s\n' "$pre_rename_inventory" | awk '/^worktree / { count++ } END { print count + 0 }') \
  || die "refusing: cannot count deletion-boundary worktrees"
[ "$pre_rename_worktree_count" -eq 1 ] \
  || die "refusing: a linked worktree appeared at the deletion boundary; clone and registry left untouched"
pre_rename_mounts=$(nested_mount_records "$TARGET") \
  || die "refusing: cannot recheck nested mountpoints at the deletion boundary"
[ -z "$pre_rename_mounts" ] \
  || die "refusing: a nested mountpoint appeared at the deletion boundary: ${pre_rename_mounts%%$'\n'*}"
verify_project_lock

prepare_project_quarantine
mv "$TARGET" "$QUARANTINE" \
  || die "refusing: could not atomically move $TARGET into same-directory quarantine; clone and registry left untouched"
if [ -e "$TARGET" ] || [ -L "$TARGET" ] || [ ! -d "$QUARANTINE" ] || [ -L "$QUARANTINE" ]; then
  QUARANTINE_PRESERVE=1
  die "refusing: the clone quarantine boundary is ambiguous; registry left untouched and bytes preserved at $QUARANTINE"
fi
quarantined_snapshot=$(quarantine_boundary_hash "$QUARANTINE") \
  || refuse_quarantined_change "refusing: cannot verify the quarantined project payload"
[ "$quarantined_snapshot" = "$pre_quarantine_snapshot" ] \
  || refuse_quarantined_change "refusing: quarantined project payload differs from the authorized deletion boundary"
quarantined_control_snapshot=$(control_inventory_hash) \
  || refuse_quarantined_change "refusing: cannot verify external control inventory after quarantine"
[ "$quarantined_control_snapshot" = "$authorized_control_snapshot" ] \
  || refuse_quarantined_change "refusing: external control inventory changed at the quarantine boundary"
verify_project_lock
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  QUARANTINE_PRESERVE=1
  die "refusing: $TARGET was recreated after quarantine; registry left untouched and quarantined bytes preserved at $QUARANTINE"
fi

# Deletion-boundary drain: refuse while any process still holds a handle into
# the payload, then re-verify the payload after the drain so nothing written
# through a since-closed handle is deleted under stale authority.
if ! deletion_open_handles=$(quarantine_open_handles "$QUARANTINE"); then
  refuse_quarantined_change "refusing: no supported way to verify that every process has released the clone at the deletion boundary on this platform"
fi
if [ -n "$deletion_open_handles" ]; then
  deletion_open_count=$(printf '%s\n' "$deletion_open_handles" | grep -c .)
  refuse_quarantined_change "refusing: $deletion_open_count open handle(s) into the clone are still held by live processes at the deletion boundary"
fi
final_deletion_snapshot=$(quarantine_boundary_hash "$QUARANTINE") \
  || refuse_quarantined_change "refusing: cannot re-verify the quarantined payload at the deletion boundary"
[ "$final_deletion_snapshot" = "$pre_quarantine_snapshot" ] \
  || refuse_quarantined_change "refusing: the quarantined payload changed at the deletion boundary"
final_nested_mounts=$(nested_mount_records "$QUARANTINE") \
  || refuse_quarantined_change "refusing: cannot verify nested mountpoints immediately before deletion"
[ -z "$final_nested_mounts" ] \
  || refuse_quarantined_change "refusing: a nested mountpoint exists at the deletion boundary: ${final_nested_mounts%%$'\n'*}"
final_control_snapshot=$(control_inventory_hash) \
  || refuse_quarantined_change "refusing: cannot re-verify external control inventory immediately before deletion"
[ "$final_control_snapshot" = "$authorized_control_snapshot" ] \
  || refuse_quarantined_change "refusing: external control inventory changed immediately before deletion"
verify_project_lock

if [ "$(uname)" = Darwin ]; then
  rm_err=$(rm -rfx -- "$QUARANTINE" 2>&1 >/dev/null) || true
else
  rm_err=$(rm -rf --one-file-system -- "$QUARANTINE" 2>&1 >/dev/null) || true
fi
if [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ]; then
  QUARANTINE_PRESERVE=1
  [ -z "$rm_err" ] || printf '%s\n' "$rm_err" >&2
  die "removal incomplete: quarantined clone bytes remain at $QUARANTINE; the registry was left untouched"
fi
[ ! -e "$TARGET" ] && [ ! -L "$TARGET" ] \
  || die "removal incomplete: $TARGET reappeared; the registry was left untouched"
rmdir "$QUARANTINE_PARENT" \
  || die "removal incomplete: quarantine parent $QUARANTINE_PARENT is not empty; the registry was left untouched"
QUARANTINE=
QUARANTINE_PARENT=

# Step 5: registry line drop, only now that clone absence is confirmed.
if [ "$reg_present" -eq 1 ]; then
  verify_project_lock
  remove_registry_line
  printf 'removed project %s: clone %s deleted, registry line dropped from %s\n' "$NAME" "$TARGET" "$REG"
else
  printf 'removed project %s: clone %s deleted (no registry line existed)\n' "$NAME" "$TARGET"
fi
[ -z "$INFO" ] || printf 'notes:\n%s' "$INFO"
exit 0
