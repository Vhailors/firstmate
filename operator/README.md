# Firstmate Operator

This package is the optional responsive operator shell described in [`docs/operator-control-plane.md`](../docs/operator-control-plane.md).
It projects Firstmate's existing state and safety contracts instead of owning a task database or runtime.

## Development

Install and validate from this directory:

```sh
pnpm install
pnpm test
pnpm lint
pnpm build
```

Run the tracked, visibly labeled fixture:

```sh
pnpm dev:fixture
```

Run the loopback live adapter with an explicit operational home and an operator-supplied temporary token:

```sh
FM_HOME=/absolute/path/to/firstmate-home \
FM_OPERATOR_TOKEN='<temporary-random-token>' \
pnpm dev
```

The browser asks for the same token when the live API returns an authorization error.
The token stays in tab-scoped `sessionStorage` and is never written by the package.
This bootstrap is only for local or explicitly approved Tailnet-private development.
It is not approved for public ingress.

`FM_OPERATOR_SKILL_ROOTS` may contain a colon-separated allowlist of installed Codex skill roots.
The adapter reads only bounded `SKILL.md` frontmatter from those roots.

## Current safety boundary

- Fleet data comes from `bin/fm-fleet-snapshot.sh --json` with explicit `FM_HOME` and schema validation.
- Documents are read from bounded snapshot report pointers or tracked architecture files, with path containment and secret redaction.
- Planning, document editing, skill invocation, and worker instructions are preview-only.
- ThinkPad actions refuse when a complete visible Herdr identity cannot be proved.
- No deployment, tunnel, DNS record, credential, or mutation capability is included.
