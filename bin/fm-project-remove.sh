#!/usr/bin/env bash
# fm-project-remove.sh - captain-gated guarded removal transaction for one
# registered project clone under this home's projects/ directory.
#
# This is the approved guarded project-removal path referenced by AGENTS.md
# hard rule #1 and the project-management skill: the ONLY way firstmate retires
# a managed clone. It owns the complete transaction and refuses loudly at every
# step; a refusal is a stop-and-report result, never an obstacle to bypass.
#
# Resolution (each of these refuses before any mutation):
#   - The target is a bare project NAME ([A-Za-z0-9._-]+, no leading dash),
#     never a path: names containing /, ., or .. are rejected, so the
#     transaction can only ever reach $FM_HOME/projects/<name> in the ACTIVE
#     home - another home's clone is unreachable by construction.
#   - The projects directory and the clone must be real directories, not
#     symlinks, and the clone's physical path must resolve to exactly
#     <projects-phys>/<name>; a symlinked or relocated clone refuses.
#   - The clone must be a standalone git clone: a .git DIRECTORY whose git
#     common dir resolves inside the clone. A gitfile (the clone is itself a
#     linked worktree of another repository) refuses, because raw removal would
#     corrupt that other repository's worktree registry.
#   - The clone may never be, or contain, this firstmate checkout or the
#     active FM_HOME.
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
#   - dirty or untracked files
#   - stash entries
#   - branches (and a detached HEAD) not reachable from any remote-tracking
#     branch, including every commit of a repository with no remote at all
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
#      covered by the presented discard-authority token
#   2. `git worktree prune` inside the clone (supported owner tool, safe:
#      it drops only registrations whose directories are already gone)
#   3. the clone directory is removed
#   4. clone absence is verified; an incomplete removal stops LOUDLY here and
#      leaves the registry untouched, so the registry never claims a clone is
#      gone while bytes remain
#   5. only then is the data/projects.md line for exactly <name> dropped, via
#      an atomic rewrite that leaves every other line byte-identical
# The transaction never stashes, never resets, never force-deletes branches,
# and never removes anything outside the verified clone path.
#
# Idempotent stale-registry repair: when data/projects.md still lists <name>
# but no clone exists, the same command performs only steps 4-5 and reports the
# repair. When neither a clone nor a registry entry exists, it fails loudly
# instead of reporting success for a possible typo.
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
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REG="$DATA/projects.md"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# retire a project clone (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
"$FM_ROOT/bin/fm-guard.sh" || true

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

fingerprint_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | awk '{print $1}'
  fi
}

registry_has_entry() {
  [ -f "$REG" ] || return 1
  awk -v n="$NAME" '$1 == "-" && $2 == n { found = 1; exit } END { exit found ? 0 : 1 }' "$REG"
}

# Atomic registry rewrite dropping exactly the "- <name> ..." line(s); every
# other line is passed through byte-identical. Verified after the swap.
remove_registry_line() {
  local tmp="$REG.tmp.$$"
  awk -v n="$NAME" '!($1 == "-" && $2 == n)' "$REG" > "$tmp" \
    || { rm -f "$tmp"; die "could not rewrite $REG; registry left untouched"; }
  mv "$tmp" "$REG" || { rm -f "$tmp"; die "could not replace $REG; registry left untouched"; }
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

if [ "$clone_present" -eq 0 ]; then
  if [ "$reg_present" -eq 0 ]; then
    die "nothing to remove: project '$NAME' has no clone under $PROJECTS and no data/projects.md entry in this home; check the name and the active home"
  fi
  if [ "$MODE_CHECK" -eq 1 ]; then
    printf 'stale registry: data/projects.md lists %s but no clone exists at %s; a removal run will repair the registry line\n' "$NAME" "$CLONE"
    exit 0
  fi
  # Steps 4-5 only: re-verify absence, then drop just this registry line.
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

FM_ROOT_PHYS=$(canonical_existing_dir "$FM_ROOT" || printf '%s' "$FM_ROOT")
FM_HOME_PHYS=$(canonical_existing_dir "$FM_HOME" || printf '%s' "$FM_HOME")
case "$FM_ROOT_PHYS/" in
  "$TARGET"/*) die "refusing: this firstmate checkout ($FM_ROOT_PHYS) is at or under the removal target" ;;
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
done <<EOF_WT
$(git -C "$TARGET" worktree list --porcelain 2>/dev/null || true)
EOF_WT

dirty=$(git -C "$TARGET" status --porcelain 2>/dev/null) \
  || die "refusing: cannot inventory the working tree of $TARGET"
if [ -n "$dirty" ]; then
  dirty_count=$(printf '%s\n' "$dirty" | grep -c .)
  add_discardable "$dirty_count dirty or untracked path(s) (git status --porcelain)"
  while IFS= read -r line; do
    [ -n "$line" ] && add_fprint "dirty:$line"
  done <<EOF_DIRTY
$dirty
EOF_DIRTY
fi

stashes=$(git -C "$TARGET" stash list --format='%H' 2>/dev/null || true)
if [ -n "$stashes" ]; then
  stash_count=$(printf '%s\n' "$stashes" | grep -c .)
  add_discardable "$stash_count stash entry(ies)"
  while IFS= read -r line; do
    [ -n "$line" ] && add_fprint "stash:$line"
  done <<EOF_STASH
$stashes
EOF_STASH
fi

remotes=$(git -C "$TARGET" remote 2>/dev/null || true)
[ -n "$remotes" ] || add_fprint "remote:none"

branch_landed() {
  local sha=$1
  [ -n "$remotes" ] || return 1
  [ -n "$(git -C "$TARGET" branch -r --contains "$sha" 2>/dev/null | head -1)" ]
}

while IFS= read -r line; do
  [ -n "$line" ] || continue
  bname=${line% *}
  bsha=${line##* }
  if ! branch_landed "$bsha"; then
    if [ -n "$remotes" ]; then
      add_discardable "branch $bname ($bsha) is not reachable from any remote-tracking branch"
    else
      add_discardable "branch $bname ($bsha) exists only locally (the repository has no remote)"
    fi
    add_fprint "branch:$bname:$bsha"
  fi
done <<EOF_BRANCH
$(git -C "$TARGET" for-each-ref --format='%(refname:short) %(objectname)' refs/heads 2>/dev/null || true)
EOF_BRANCH

head_sha=$(git -C "$TARGET" rev-parse -q --verify HEAD 2>/dev/null || true)
if [ -n "$head_sha" ] && ! git -C "$TARGET" symbolic-ref -q HEAD >/dev/null 2>&1; then
  if ! branch_landed "$head_sha"; then
    add_discardable "detached HEAD $head_sha is not reachable from any remote-tracking branch"
    add_fprint "head:$head_sha"
  fi
fi

if [ -d "$STATE" ]; then
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    task_id=$(basename "$meta" .meta)
    for field in project worktree home; do
      val=$(grep "^$field=" "$meta" 2>/dev/null | head -1 | cut -d= -f2-) || true
      [ -n "$val" ] || continue
      vp=$(canonical_path "$val")
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
  open_items=$(awk -v tag="(repo: $NAME)" '/^- \[ \]/ && index($0, tag) { print $4 }' "$DATA/backlog.md" | tr '\n' ' ')
  open_items=${open_items% }
  [ -z "$open_items" ] \
    || add_structural "open backlog item(s) tagged (repo: $NAME): $open_items; complete, re-home, or drop them in the backlog first"
fi

if [ -f "$DATA/secondmates.md" ]; then
  while IFS= read -r line; do
    case "$line" in
      "- "*) : ;;
      *) continue ;;
    esac
    sid=${line#- }
    sid=${sid%% *}
    csv=$(printf '%s\n' "$line" | sed -n 's/.*; projects: \([^;)]*\)[;)].*/\1/p')
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
    shome=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p')
    if [ -n "$shome" ]; then
      sp=$(canonical_path "$shome")
      case "$sp/" in
        "$TARGET"/*) add_structural "secondmate $sid home $shome resolves under the clone; retire it through secondmate-provisioning first" ;;
      esac
    fi
  done < "$DATA/secondmates.md"
fi

expected_token=
if [ -n "$DISCARDABLE" ]; then
  fp=$(printf 'project:%s\n%s' "$NAME" "$FPRINT" | LC_ALL=C sort | fingerprint_hash)
  expected_token="discard-unlanded:$NAME:$(printf '%s' "$fp" | cut -c1-12)"
fi

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

if [ -n "$DISCARDABLE" ]; then
  if [ -z "$AUTHORITY" ]; then
    report
    printf 'discard token for exactly this inventory: %s\n' "$expected_token"
    printf 'authorized re-run: fm-project-remove.sh %s --confirm %s --discard-authority %s\n' "$NAME" "$NAME" "$expected_token"
    echo "REFUSED: unlanded work exists; removal requires the captain's explicit discard authority for this exact inventory." >&2
    exit 1
  fi
  case "$AUTHORITY" in
    "discard-unlanded:$NAME:"*)
      if [ "$AUTHORITY" != "$expected_token" ]; then
        report
        die "discard authority does not match the CURRENT unlanded-work inventory of '$NAME' (the work changed after the token was issued); re-run --check and obtain fresh captain authority"
      fi
      ;;
    discard-unlanded:*)
      die "discard authority is scoped to a different project and cannot authorize discarding '$NAME'; nothing was changed"
      ;;
    *)
      die "unrecognized discard-authority token; expected discard-unlanded:$NAME:<fingerprint> from a refusal or --check run"
      ;;
  esac
elif [ -n "$AUTHORITY" ]; then
  add_info "no unlanded work; the presented discard authority was not needed"
fi

# Step 2: prune stale worktree registrations through the supported owner tool,
# then refuse if any linked registration survives (locked or unprunable) - the
# clone and registry stay untouched in that case.
git -C "$TARGET" worktree prune 2>/dev/null || true
leftover_wt=$(git -C "$TARGET" worktree list --porcelain 2>/dev/null | awk 'NR > 1 && /^worktree / { sub(/^worktree /, ""); print }' | grep -c . || true)
if [ "${leftover_wt:-0}" -gt 0 ]; then
  die "refusing: $leftover_wt linked worktree registration(s) survived git worktree prune (locked or unprunable); resolve them through git worktree tooling first - clone and registry left untouched"
fi

# Step 3: remove the verified clone. TARGET is canonical, non-root, and proven
# to be exactly $PROJECTS_PHYS/$NAME above; nothing outside it is touched.
rm_err=$(rm -rf -- "$TARGET" 2>&1 >/dev/null) || true
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  [ -z "$rm_err" ] || printf '%s\n' "$rm_err" >&2
  die "removal incomplete: $TARGET still exists; the registry was left untouched so it never claims a clone is gone while bytes remain"
fi

# Step 5: registry line drop, only now that clone absence is confirmed.
if [ "$reg_present" -eq 1 ]; then
  remove_registry_line
  printf 'removed project %s: clone %s deleted, registry line dropped from %s\n' "$NAME" "$TARGET" "$REG"
else
  printf 'removed project %s: clone %s deleted (no registry line existed)\n' "$NAME" "$TARGET"
fi
[ -z "$INFO" ] || printf 'notes:\n%s' "$INFO"
exit 0
