# Operator control-plane architecture

The operator control plane is a web projection over Firstmate's existing contracts.
It is not a second orchestrator, task database, session backend, or authority owner.
The implementation lives in [`operator/`](../operator/) and runs against one explicit live `FM_HOME` by default.

## Authoritative contracts

The web layer consumes stable owners instead of parsing terminal presentation or creating replacement state.

| Concern | Authoritative owner | Web responsibility |
| --- | --- | --- |
| Fleet, backlog, worker, report, and secondmate projection | [`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh) with schema `fm-fleet-snapshot.v1` | Execute the fixed `--json` command with an explicit `FM_HOME`, validate the schema and returned home, and map the result for display. |
| Current worker state | [`bin/fm-crew-state.sh`](../bin/fm-crew-state.sh), reached through the fleet snapshot | Display the returned state, source, freshness, and blocker without substituting a pane-tail guess. |
| Worker and secondmate instruction delivery | [`bin/fm-send.sh`](../bin/fm-send.sh) | Resolve a durable task id, preview the exact argv, execute only that one confirmed preview, and leave composer, busy-state, marker, pending-reply, backend, and submit checks to `fm-send`. |
| Secondmate route and scope | `data/secondmates.md` under the [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md) contract | Read a bounded registry projection and never use a project list as exclusive ownership. |
| Herdr endpoint placement and lifecycle | [`docs/herdr-backend.md`](herdr-backend.md) and [`bin/fm-backend.sh`](../bin/fm-backend.sh) | Display recorded session, workspace, tab, and pane identity and refuse label-only targeting. |
| Remote secondmate placement | [`docs/remote-secondmates.md`](remote-secondmates.md) | Preserve unknown and unreachable routes without local failover. |
| Task intake, delivery, and merge authority | [`AGENTS.md`](../AGENTS.md), the task lifecycle scripts, and project mode | Return confirmed task intent to Firstmate intake instead of writing a task row or merging from the browser. |
| Skill behavior and invocation | Each discovered `SKILL.md` plus its harness surface | Catalog bounded frontmatter and an exact supported invocation, but never interpret a skill name as shell input. |
| Reports and tracked documents | Snapshot report pointers and the tracked documentation tree | Read only allowlisted text formats beneath an approved root, apply byte bounds and redaction, and preserve provenance. |

No operator API may use a terminal label, globally focused pane, free-form path, or browser-supplied command as authority.
Every mutation must re-resolve the durable identity immediately before execution because a previously displayed endpoint can become stale.

## Current vertical slice

The responsive shell includes fleet status, missions, workers, secondmates, open decisions, blockers, planning, worker observation, documents, skills, and access-boundary views.
Fluent UI supplies the accessible component foundation because this is a dense Windows-friendly operator product rather than a marketing page.
The visual system uses one blue accent, a compact 12-pixel radius scale, semantic status color, system light and dark themes, 44-pixel desktop targets, and larger fixed mobile navigation targets.

The tracked fixture is selected only with `VITE_FM_OPERATOR_FIXTURE=1`, exists for offline UI tests and CI, and displays a persistent fixture badge.
It is not an operator mode and never starts during Firstmate session initialization.
The live adapter invokes only `bin/fm-fleet-snapshot.sh --json`, validates `fm-fleet-snapshot.v1`, requires the returned `FM_HOME` to equal the server-configured home, and applies a two-megabyte output bound and a twenty-second timeout.
Report reads are limited to snapshot pointers beneath `<FM_HOME>/data`, tracked architecture reads stay beneath `docs/`, symlinks and path escapes are refused, and each document is limited to 256 KiB.
The skill reader scans only configured roots, reads only `SKILL.md` files up to 64 KiB, and returns frontmatter-derived catalog metadata rather than skill bodies.

Planning remains a preview because task intake still belongs to Firstmate's conversational lifecycle.
Worker instruction delivery is live: the server creates a one-time preview, the UI shows the durable worker id, recorded endpoint, fixed executable and structured argv, and an explicit confirmation sends through `fm-send`.
The fixture keeps every mutation capability false.

The document editor is also a bounded draft surface in this phase.
It keeps changes in browser memory and explains why the source is not writable.
A worker-owned report should be revised through the worker and task lifecycle, while a tracked project document should be changed through the normal ship and review path.
Adding a direct filesystem write would bypass those owners and is out of scope until a specific contract owns it.

## Authentication and session model

[`bin/fm-operator.sh`](../bin/fm-operator.sh) binds the server to loopback and creates or reuses `<FM_HOME>/config/operator-token` with mode `0600`.
The token record includes the canonical home and is rejected when used with another `FM_HOME`.
`fm-operator.sh url` puts the token in a URL fragment; the browser moves it into tab-scoped `sessionStorage` and clears the fragment before loading fleet data.
Every API request presents that token as a bearer credential, and the server compares it with constant-time byte comparison.
This mechanism is acceptable only for loopback or an explicitly approved Tailnet-private route.
It is not the public or Cloudflare session design.

After a primary session acquires its lock and completes bootstrap, [`bin/fm-session-start.sh`](../bin/fm-session-start.sh) runs `fm-operator.sh ensure`.
Read-only lock-refused sessions and marked secondmate homes skip the hook.
The home can opt out with `config/operator-autostart` set to `off`; no public or Tailnet listener appears automatically.

The first hardened private deployment must keep the application listener on loopback and put Tailscale Serve in front of it.
Tailscale Serve strips spoofed Tailscale identity headers and adds identity headers for Tailnet traffic, while Funnel does not provide those identity headers.
The application must accept those headers only from the loopback proxy, map the login to an explicit operator allowlist, and create a short-lived server-side session with an `HttpOnly`, `Secure`, and `SameSite=Strict` cookie.
Mutation requests must also carry a session-bound CSRF value.
The temporary bearer bootstrap can be removed after that session exchange exists.
The current product contract is documented by [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve).

The UI must always show the active transport, authenticated principal, session expiry, source mode, and enabled capabilities.
An absent or unverified identity disables every mutation surface without changing read-only availability.

## Phone and Windows access boundary

The first operator URL is private to the Tailnet and is served through Tailscale Serve to the loopback origin.
This keeps the same responsive application usable from a phone or Windows browser without exposing a public DNS record or listening on the LAN.
No Tailscale Serve configuration is created by this change.
Enabling it is a separate operator-approved deployment action with a recorded hostname, device owner, ACL, identity allowlist, and rollback command.

Cloudflare is a later optional ingress layer rather than a prerequisite or silent fallback.
Before any Cloudflare Tunnel route or public hostname exists, an Access self-hosted application must be created with an explicit allow policy, session duration, and identity provider.
Cloudflare Access applications are deny-by-default, and the origin must validate the Access application token or use a Tunnel configuration that performs that validation.
The Access application must exist before the tunnel route because a published route without Access can be reachable from the Internet.
The current product contract is documented by [Cloudflare's self-hosted application guide](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/) and [application token guide](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/application-token/).

The repository must never contain a Cloudflare token, Tailscale key, DNS credential, application secret, or generated session credential.
The interface must continue to show whether the current request arrived through local, Tailnet-private, or Cloudflare Access transport.

## ThinkPad visible Herdr model

The ThinkPad route is a distinct operator workflow with Tailscale alias `fm-thinkpad`.
It does not reuse the existing whole-home remote secondmate implementation's `fm-remote` Herdr session.

A usable ThinkPad target must prove this complete identity tuple:

- Host alias `fm-thinkpad` resolved through Tailscale.
- The ThinkPad's own named visible Herdr session.
- One exact workspace id.
- One exact tab id.
- One exact pane id.
- The durable Firstmate task or secondmate id bound to that endpoint.
- Current agent, busy, composer, and focus evidence from that same session.

The focused workspace is a useful default for display but is not mutation authority.
An action preview must display the complete tuple, and confirmation must re-read it before delegating to an existing Firstmate or Herdr safety owner.
Creating or resuming work must place it in the visible ThinkPad Herdr session so the operator can attach, observe, and supervise it there.

The initial adapter does not claim that remote visible-session proof exists.
Any `fm-thinkpad` target therefore renders unavailable and refuses action.
It may not fall back to the VPS `fm-remote` session, an ambient Herdr session, raw or hidden SSH execution, a detached terminal, or direct Chrome or Unity automation.
A future implementation remains blocked until a tested existing-helper extension can return the complete tuple and perform session-explicit Herdr calls without becoming a second runtime backend.

## Mutation protocol

Mutation adapters use a two-step protocol.

First, the server re-reads the fleet snapshot and creates a preview with a random one-time id, durable target id, current backend endpoint, exact fixed executable and argv, and a 60-second expiry.
It stores that preview in server memory and returns no general command channel.

Second, the operator confirms that exact preview.
The server consumes the preview once, re-reads the authoritative state, rejects any identity or authority drift, and invokes only the allowlisted contract owner with structured argv and an explicit `FM_HOME`.
Success means the existing owner confirmed submission, not that the requested work completed.

The implemented adapter sends one confirmed instruction through `bin/fm-send.sh` after exact identity and endpoint re-resolution.
It stores previews in server memory for 60 seconds, consumes them once, and returns success only when `fm-send` confirms submission.
Instruction text that `fm-send` would read as its `--key` control selector is refused at preview, so the confirmed argv always means the literal text the operator saw.
Text carrying a newline, carriage return, escape, or any other control character is refused there too: `fm-send` delivers one literal line and the backends type it raw, so an embedded control byte would reach the worker as a keystroke that submits or clears a partial turn.
A refused delivery returns one generic browser error and writes the `fm-send` exit code and stderr to the server log, where `state/operator.log` keeps the distinguishable failure classes.
Because several of those refusals happen after the text was already submitted, the browser reports an explicit unknown outcome pointing at that log rather than claiming no send occurred, and the consumed preview is discarded so no resend is possible without a fresh one.
Every child script the server runs receives an `FM_*`-free environment plus the explicit `FM_HOME` and `FM_ROOT_OVERRIDE` bindings, so the long-lived server's frozen startup environment can never relax a fleet guard or reuse another turn's correlation id.
Composer and busy guards, secondmate markers, pending-reply records, backend checks, and ThinkPad refusal remain inside the existing owners.

Task intake, report revision, and skill invocation remain unavailable until each path has an equally narrow owner adapter.

Arbitrary shell execution, browser-supplied executable paths, direct task database writes, label searches, and generic document writes remain prohibited.

## Skill catalog boundary

The catalog distinguishes Firstmate built-ins, public Firstmate skills, and configured installed skill roots such as a maintained Matt Pocock skills checkout.
The server reads only the declared roots and frontmatter, and the UI shows the name, description, applicability, source, catalog path, and exact supported invocation.

Firstmate user-invocable built-ins use `/<name>` in the Firstmate conversation.
Configured Codex-installed skills use `$<name>` in a compatible Codex surface.
Agent-only skills show no direct invocation and point to their documented trigger.
Other harnesses need an explicit catalog adapter before their invocation syntax can be displayed as supported.

Skill execution is a future mutation capability with the same preview, one-time confirmation, identity, and allowlist requirements as worker instructions.
The catalog never runs a skill merely because its row was opened, copied, or searched.

## Remaining work

### Private deployment hardening

- Replace the loopback `vite preview` host that serves the built assets and bounded API today with a server hardened for a non-loopback route.
- Verify Tailscale Serve identity headers only from the local proxy and issue short-lived server sessions.
- Add operator allowlists, CSRF protection, rate limits, structured audit storage, session revocation, and a visible trust-boundary panel.
- Document an explicit, reversible Tailscale Serve activation without creating it automatically.

### More guarded actions

- Return confirmed secondmate-scoped task intent to Firstmate's intake and backlog contract.
- Request report revisions through their owning worker.
- Keep direct report writes and arbitrary command execution unavailable.

### ThinkPad visible work

- Extend an existing Firstmate or Herdr helper to prove the complete `fm-thinkpad` visible-session tuple.
- Test focus, exact pane selection, busy and composer refusal, reconnect, and unavailable-host behavior against a real disposable ThinkPad session.
- Preserve a loud blocker on every unproved or unavailable state.

### Optional Cloudflare Access

- Obtain explicit operator approval for the hostname, DNS, tunnel, identity provider, allow policy, session duration, origin validation, and rollback.
- Create Access before any published tunnel route and verify origin token validation.
- Keep Tailscale private access available as the simpler recovery path only when the operator approves that dual boundary.

## Verification boundary

The operator package tests live-default selection, FM_HOME refusal, home-bound tokens, exact worker and secondmate resolution, unavailable ThinkPad refusal, one-time confirmation, endpoint-drift rejection, fake-boundary `fm-send` execution, secret redaction, bounded live snapshot identity, report provenance, loading, planning, observation, document, and skill flows.
The [CI workflow](../.github/workflows/ci.yml) installs the pinned operator toolchain and runs its tests, lint, and production build independently from the shell behavior-suite lanes.
Repository documentation checks classify this page as maintainer architecture and validate its local links.
No test or fixture is evidence that a real phone, Windows device, ThinkPad Herdr session, Tailscale Serve endpoint, Cloudflare Access application, tunnel, DNS record, or public deployment exists.
