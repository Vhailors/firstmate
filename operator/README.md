# Firstmate Operator

Firstmate Operator reads the real fleet snapshot for one explicit `FM_HOME` and sends confirmed worker instructions through `bin/fm-send.sh`.
It does not own a task database or a runtime backend.
The full safety and ownership model lives in [`docs/operator-control-plane.md`](../docs/operator-control-plane.md).

## Start the live operator

Install the pinned package once:

```sh
pnpm --dir operator install
```

Start or reuse the loopback server for a Firstmate home:

```sh
FM_HOME=/absolute/path/to/firstmate-home bin/fm-operator.sh start
```

The launcher creates `config/operator-token` inside that home with mode `0600`, or reuses the existing token when its recorded canonical home still matches.
It stores the runtime record and log under the same home's gitignored `state/` directory.
It serves the production build with `vite preview`, building `operator/dist` first when that bundle is missing, and reports success only after the loopback port accepts a connection.
The development server with hot module replacement is never used for a session or an autostart.

Open a private browser session with the generated URL:

```sh
FM_HOME=/absolute/path/to/firstmate-home bin/fm-operator.sh url
```

The token travels in the URL fragment, moves into tab-scoped `sessionStorage`, and disappears from the address bar before the first API request.
Do not publish that URL.

`bin/fm-session-start.sh` runs `fm-operator.sh ensure` after lock acquisition and bootstrap on an ordinary primary home.
A lock-refused session and a marked secondmate home never start it.
Write `off` to `config/operator-autostart` when a primary home should skip the hook; `config/operator-port` or `FM_OPERATOR_PORT` selects a fixed loopback port.
[`docs/configuration.md`](../docs/configuration.md#operator-runtime-configoperator-autostart--configoperator-port--configoperator-token) owns the file schemas and runtime-state locations.

## Direct package commands

`pnpm dev` and `pnpm start` are live-only and expect the launcher to have created the home token first.
Both refuse startup without `FM_HOME`, and both read the home-bound token from `<FM_HOME>/config/operator-token` unless `FM_OPERATOR_TOKEN_FILE` names another bound record.
`pnpm start` serves an existing production build on loopback and is the same startup path `bin/fm-operator.sh` uses; `pnpm dev` is the development server and is for local package work only.

```sh
pnpm --dir operator build
FM_HOME=/absolute/path/to/firstmate-home pnpm --dir operator start
```

The fixture exists only for offline UI tests and CI:

```sh
pnpm --dir operator dev:fixture
```

Fixture mode carries a visible badge and disables mutations.
Never use it as an operator session.

## Validation

Run the package checks from `operator/`:

```sh
pnpm test
pnpm lint
pnpm build
```

The live adapter gets fleet data from `bin/fm-fleet-snapshot.sh --json`, validates the returned home, bounds document reads, and keeps the existing secret redaction.
A send preview records the durable worker id and endpoint for 60 seconds.
Confirmation consumes that preview once, re-reads the fleet snapshot, rejects identity drift, and invokes `fm-send` with fixed argv and explicit `FM_HOME`.
ThinkPad actions still refuse until the complete visible Herdr tuple can be proved.

No command in this package enables a public listener, Tailscale Serve, Cloudflare Funnel, DNS, deployment, or PR merge.
