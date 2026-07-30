# ADR 0001: Keep local workflow customizations rebasable on upstream

- Status: accepted
- Date: 2026-07-27
- Supersedes: nothing

## Context

This checkout follows a public upstream Firstmate that releases frequently and reworks shared surfaces such as `bin/fm-spawn.sh`, `bin/fm-watch.sh`, and `docs/configuration.md` whenever a harness, backend, or supervision mechanism is added.
The same checkout also carries a small number of local workflow customizations that upstream has not adopted, because one captain's fleet sometimes needs a boundary before upstream is ready to generalize it.

Two failure modes are available, and both have already been observed here.
A local feature can grow across many commits inside upstream files until it is cheaper to abandon than to rebase: an earlier local Pi fleet-footer extension reached that state and was dropped wholesale at an upstream realignment instead of carried forward.
A local change can also be avoided entirely, at the cost of running the fleet without a boundary the captain actually needs.

The current local delta is the shape this document wants to make routine.
Scoping Pi primary and crewmate launches to Firstmate's own extensions is one thematic commit: it adds a new launcher script that upstream does not have, changes a handful of lines inside existing upstream files, and updates the tests and prose that own those lines.
When upstream then added a new crewmate adapter, rebasing that delta produced only adjacency conflicts in `bin/fm-spawn.sh` and `docs/configuration.md`, where upstream inserted new adapter material next to the locally edited lines.
Both resolutions keep upstream's insertion and the local line side by side; neither is a semantic disagreement.

This document records how that stays true.
It does not restate the delivery, supervision, or configuration contracts owned by [`AGENTS.md`](../../AGENTS.md), [`docs/architecture.md`](../architecture.md), [`docs/configuration.md`](../configuration.md), and [`firstmate-coding-guidelines`](../../.agents/skills/firstmate-coding-guidelines/SKILL.md).

## Decision

**Upstream remains authoritative.**
`upstream/main` owns the product's direction, its mechanisms, and its file layout.
A local change is a temporary deviation that either becomes an upstream contribution or is dropped; it never becomes a competing design that upstream is expected to accommodate.
When upstream ships behavior that overlaps a local change, upstream's version wins by default and the local change is replaced.

**No fork is created.**
This repository is not a divergent product fork of Firstmate and does not maintain a parallel release line, a renamed toolbelt, or independent architecture.
The GitHub fork remote is a contribution mechanism only, used as the no-mistakes push target described in [`CONTRIBUTING.md`](../../CONTRIBUTING.md); it is not a place where local behavior is allowed to accumulate.

**Local changes must stay easy to rebase.**
Ease of rebase is a design constraint on the change itself, not a property discovered at merge time.
A local change that cannot be described in one thematic commit, or that spreads edits across unrelated upstream files, is out of scope for this policy and needs an upstream contribution instead.

**The captain can supersede these defaults by explicit instruction.**
Every default here is a working rule, not a safety boundary.
An explicit captain instruction can preserve a customization upstream would replace, defer a merge, or authorize a larger local delta.
The safety boundaries in `AGENTS.md`, including the project-write boundary, unlanded-work protection, and merge authority, are unchanged by this document and are not superseded by it.

## Preferred customization shape

Prefer the least invasive form that actually solves the problem, in this order.

1. **A reversible local setting outside tracked application logic.**
   A gitignored file under `config/`, or an `.env` value, has no rebase surface at all and is undone by deleting one file.
   The available settings and their schemas are owned by [`docs/configuration.md`](../configuration.md).
2. **A new tracked file upstream does not have.**
   A separate script or document rebases cleanly by construction, because nothing upstream edits it.
   `bin/fm-pi-primary.sh` is the current example: the launch policy lives in its own script rather than as a branch inside an existing launcher.
3. **A minimal edit inside an existing upstream file.**
   This is the only real conflict surface, so keep it to the fewest lines that make options 1 and 2 reachable, and keep the edit adjacent to the upstream code it modifies rather than restructuring around it.

Option 3 legitimately lands in more than one file when the same behavior has several owners, as the Pi launch scope does across spawn, session start, and supervision rendering.
The signal to contribute upstream instead is a customization whose option 3 edits reach unrelated mechanisms, or that has to restructure upstream code before it fits.

## Merge procedure

Run this whenever upstream has moved and before shipping any further local change.

**1. Refresh upstream and preview the boundary.**

```sh
git fetch upstream
git rev-list --left-right --count upstream/main...HEAD          # behind/ahead
git diff --name-only "$(git merge-base HEAD upstream/main)" HEAD  # the local delta
git merge-tree --write-tree --name-only upstream/main HEAD      # conflict preview, no working tree change
```

The conflict preview reports the conflicting paths without touching the working tree, the index, or any branch, so it is safe to run before deciding anything.

**2. Classify every local change as preserve, replace, or drop.**

- **Preserve** when upstream has no equivalent and the captain still relies on the behavior.
- **Replace** when upstream shipped its own version of the same behavior; take upstream's and delete the local variant, even when the local one is more familiar.
- **Drop** when the need has passed, the change was a workaround for a bug upstream has since fixed, or the change can no longer be expressed as a small thematic commit.

Record the classification before rebasing, so a "replace" is a decision rather than an accident of conflict resolution.
Dropping a customization the captain asked for is a captain decision, not a maintainer one.

**3. Rebase in small thematic commits.**

Rebase the local delta onto the refreshed `upstream/main` one theme at a time, keeping each commit's script, test, and prose changes together.
Resolve an adjacency conflict by keeping both sides; a conflict that cannot be resolved that way means upstream changed the mechanism and the change belongs in step 2 as a replace.
Never resolve a conflict by reverting upstream's insertion.

**4. Run the compatibility and documentation checks.**

See [Verification](#verification) below.
Both the upstream behavior suite and the customization's own tests must pass on the rebased result before it is shipped.

**5. Ship through the repo's normal delivery path.**

The rebased branch is an ordinary tracked change to shared material and follows the existing no-mistakes and merge-approval path in [`CONTRIBUTING.md`](../../CONTRIBUTING.md).

## Customization inventory

Current known local customization areas, their authoritative owners, and how exposed each is to upstream churn.

| Area | Where it lives | Authoritative owner | Upstream-overlap risk |
| --- | --- | --- | --- |
| Pi primary launcher | `bin/fm-pi-primary.sh`, a tracked file upstream does not have | the script's own header, with a row in [`docs/scripts.md`](../scripts.md) | low; no upstream commit edits this path |
| Pi launch templates for workers and secondmates | a few lines in `bin/fm-spawn.sh` | the `bin/fm-spawn.sh` header | high; each new upstream adapter inserts material beside these lines |
| Pi supervision protocol and session-start diagnostic | `bin/fm-supervision-instructions.sh`, `bin/fm-session-start.sh`, [`docs/supervision-protocols/pi.md`](../supervision-protocols/pi.md) | `docs/supervision-protocols/` | medium; upstream rewrites protocol text whenever supervision changes |
| Pi launch-scope facts for agents | [`harness-adapters`](../../.agents/skills/harness-adapters/SKILL.md) | that skill | high; upstream rewrites adapter facts on every harness release |
| Pi setup and current-behavior prose | [`README.md`](../../README.md), [`docs/configuration.md`](../configuration.md), [`docs/calm.md`](../calm.md) | README for setup routing, `docs/configuration.md` for the schema | high; these paragraphs are where the observed rebase conflicts landed |
| Pi command shapes inside maintainer verification | [`docs/arm-pretool-check.md`](../arm-pretool-check.md), [`docs/cd-guard.md`](../cd-guard.md), [`docs/verification/supervision.md`](../verification/supervision.md) | each verification document | low to change, but the evidence must be re-run rather than reworded when the launch shape moves |
| Changed-file test routing for the launcher | one pattern in `bin/fm-test-run.sh` | `bin/fm-test-run.sh --help` | medium; upstream edits the same map when it adds scripts |
| Explicit do-not-merge enforcement | `bin/fm-merge-authority-lib.sh` plus narrow call sites in the spawn and merge helpers | the library header and `tests/fm-merge-authority.test.sh` | medium; upstream may change spawn metadata or the guarded merge entry points |
| Local operating choices | gitignored `config/` files and `.env` | [`docs/configuration.md`](../configuration.md) | none; untracked and never rebased |
| Private fleet records | gitignored `data/`, `state/`, `projects/` | `AGENTS.md` section 2 | none; untracked and never rebased |

The tracked rows above are the whole rebase surface.
If a future customization does not fit an existing row, add a row here in the same commit that adds the customization, so the inventory never lags the code.

### Dropped customizations

A customization the captain asked for and then dropped is recorded here, so a missing row reads as a decision rather than as an accidental omission during a merge (step 2 of the merge procedure).

| Area | Dropped on | Why |
| --- | --- | --- |
| Guarded whole-project removal (`bin/fm-project-remove.sh` and its suite, from the `fm/guarded-project-removal-helper-v2` branch) | 2026-07-30, by captain decision during the upstream mix | The deletion-boundary drain refused on every Linux run: it required every same-UID process's `/proc/<pid>` handle roots to be enumerable, which `kernel.yama.ptrace_scope=1` (the default on this host) forbids, so `--confirm` always quarantined the clone and then restored it. Its suite faked `uname` as Darwin and so could not observe the refusal. Excluded rather than weakened, because relaxing the drain would have traded the capability's safety model for its availability; upstream removal behavior is restored and the source branch is left intact for a Linux-correct rework. |

The table is wider than the behavior change that produced it, and that is expected.
One scoped launch decision is a few lines of shell, but this repo requires every owner document, adapter fact, setup instruction, and verification command to stay accurate, so the prose rows fan out from a small code change rather than from a large one.
Judge a customization's rebase cost by its behavior rows, not its prose rows: prose conflicts resolve by keeping both sides, while a behavior row that upstream has reworked is a replace decision.

## Verification

These commands prove that upstream's behavior and the local customizations both still work after a rebase.

```sh
for script in bin/*.sh bin/backends/*.sh; do bash -n "$script"; done  # toolbelt syntax
bin/fm-lint.sh                                                       # single lint owner, same as CI
bin/fm-test-run.sh --changed                                         # changed-file-informed behavior set
bin/fm-doc-audience-check.sh                                         # prose classification and link targets
```

Add the customization's own regression scripts to the same run.
For the Pi launch-scope area those are:

```sh
bin/fm-test-run.sh tests/fm-pi-watch-extension.test.sh
bin/fm-test-run.sh tests/fm-session-start.test.sh
bin/fm-test-run.sh tests/fm-spawn-dispatch-profile.test.sh
bin/fm-test-run.sh tests/fm-supervision-instructions.test.sh
```

Selection rules, lanes, and the deliberate full-regression flag are owned by `bin/fm-test-run.sh --help`; the broad regression matrix is owned by [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml).

## Consequences

Merges stay small and frequent rather than becoming periodic realignment projects, and a customization that has quietly become unrebasable is visible in the inventory before it is expensive.
The cost is discipline at authoring time: a customization must be shaped for rebase up front, and preferring a reversible setting sometimes means a slightly less direct implementation than editing the tracked path would give.
Choosing upstream's version by default also means occasionally losing a local behavior the captain liked, which is why replacing or dropping a captain-requested customization is escalated rather than decided silently.
