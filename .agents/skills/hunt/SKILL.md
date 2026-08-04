---
name: hunt
description: >-
  Route a captain-authorized bug-bounty hunt to the BB secondmate when the captain
  invokes /hunt or asks to hunt a named program.
  Bind the engagement to live scope, use the BB home's current authorized dispatch
  profiles, and preserve captain-only submission authority.
user-invocable: true
metadata:
  internal: true
---

# hunt

Load when the captain invokes `/hunt`, provides a program URL or handle for hunting, or asks to start an authorized bug-bounty engagement.
This skill owns Firstmate intake and routing only.
The BB secondmate exclusively owns packet verification, staffing, lane execution, evidence, and engagement wrap-up.

## Preconditions

1. Confirm the captain authorized this engagement in the current session.
2. Resolve one exact program URL or handle from the captain's message or from a catalog/API selection the captain explicitly asked Firstmate to make.
3. Ask one concise program-identity question if the target remains ambiguous.
4. Confirm the registered BB secondmate route is available, using `secondmate-provisioning` for recovery when needed.
5. Stop if authorization, target identity, BB ownership, or the route cannot be established.

A historical packet or public policy snapshot is context, never current-session authorization.
Firstmate never invents scope and never runs hunt tools itself.

## Required route contract

Send the BB secondmate one complete marked request rather than drip-feeding safety-critical details.
The request must include every item below.

### Authorization and external-action boundary

- State the exact program URL or handle and that the captain authorized this engagement for the current session.
- Set `auto_submit=false`.
- Forbid vendor contact, uploads, filings, or submissions without separate captain approval.
- Require non-destructive proofs.
- Forbid denial of service, brute force, and customer or staff targeting unless both the live program rules and a separate captain instruction explicitly permit the exact action.

### Scope binding

- Require BB to fetch and verify the live program policy before active testing.
- Require an exact allowlist, denylist, and reproducible scope evidence under a fresh engagement packet.
- Permit reuse of an older signed packet only after BB revalidates it against the live policy in this session.
- Stop on scope ambiguity, missing assets, policy mismatch, or uncertain third-party ownership.
- Keep false or out-of-scope assets denylisted.

### Staffing

- Require BB to resolve every lane from its current `config/crew-dispatch.json` profiles and the captain-authorized Sol, Luna, and Grok pool available in that home.
- Do not name or pin a stale model roster in this skill.
- Require inspectable profile resolution and current quota/headroom handling under the normal dispatch contract.
- Let BB choose the lane count and role mix within current capacity unless the captain supplied a bound such as `--lanes N` or `--xss-only`.
- Reassign a categorically refusing or unavailable slot through the same authorized pool without broadening scope.

### Collaboration and evidence

- Mint a fresh engagement id such as `<program-slug>-bbp-YYYYMMDD`.
- Use one BB-owned engagement workspace containing the verified packet, guard material, policy snapshot, lane evidence, coverage, and shared intelligence.
- Require lanes to read shared intelligence before claiming novelty and to record new leads promptly.
- Prefer evidence-linked chains when the combined impact is stronger than individual observations.
- Preserve disconfirming evidence and distinguish detection, lead, validation, and proven finding states.
- Escalate only true captain decisions, credentials, scope blockers, or structural failures.

### Outcome and wrap-up

- Default to seeking high-severity, reproducible findings suitable for captain review without inflating severity.
- Keep `auto_submit=false` throughout the engagement.
- Return one BB-owned wrap-up artifact with scope evidence, lane coverage, proven findings, rejected hypotheses, and remaining risks.
- Preserve every lane report before BB retires its workers.

## Firstmate procedure

1. Resolve the authorized program identity.
2. Recover the BB secondmate route only through the normal secondmate procedure when necessary.
3. Send one complete marked request containing the required route contract and any captain-supplied lane, authentication, exploit-stage, OOB, or severity constraints.
4. Route marked replies through the normal secondmate pending-reply contract.
5. Ask the captain one focused question when BB returns a genuine authorization, scope, credential, or external-action decision.
6. Relay proven-finding packs and the final wrap-up with their full artifact paths.
7. Never submit, contact the vendor, or dispatch the same engagement to another home.

## Optional captain constraints

- `--lanes N` or an active-lane cap.
- `--xss-only`, no-XSS, or another named class focus.
- Exploit-stage or OOB on/off.
- Authenticated browser or test-account notes without exposing secrets.
- A severity or finding-count goal override.

## Hard stops

- No current-session authorization.
- No exact program identity.
- No verified live scope packet.
- Any requested action outside live program rules.
- Any request for automatic submission or vendor contact without separate captain approval.
- Any attempt to move hunt ownership outside the BB secondmate.
