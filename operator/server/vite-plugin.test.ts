// @vitest-environment node
import { randomBytes } from 'node:crypto'
import { mkdir, mkdtemp, realpath, rm, writeFile } from 'node:fs/promises'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { operatorApiPlugin, operatorTokenMatches } from './vite-plugin.ts'

const started: Array<() => Promise<void>> = []

afterAll(async () => { await Promise.all(started.map((close) => close())) })

// Mounts the plugin's real /api middleware on a real loopback server, which is
// the exact surface bin/fm-operator.sh probes for readiness.
async function startBoundedApi(options: { withToken?: boolean } = {}) {
  const home = await realpath(await mkdtemp(join(tmpdir(), 'fm-operator-api-home-')))
  const repoRoot = await realpath(await mkdtemp(join(tmpdir(), 'fm-operator-api-repo-')))
  await mkdir(join(home, 'config'), { recursive: true })
  const tokenFile = join(home, 'config', 'operator-token')
  const token = randomBytes(32).toString('hex')
  if (options.withToken !== false) {
    await writeFile(tokenFile, `fm_home=${home}\ntoken=${token}\n`, { mode: 0o600 })
  }

  let handler: ((request: IncomingMessage, response: ServerResponse) => void) | undefined
  const plugin = operatorApiPlugin({ FM_HOME: home, FM_ROOT_OVERRIDE: repoRoot, FM_OPERATOR_TOKEN_FILE: tokenFile })
  const configure = plugin.configureServer as (server: unknown) => void
  configure({ middlewares: { use: (_route: string, mounted: typeof handler) => { handler = mounted } } })
  if (!handler) throw new Error('The operator plugin registered no /api middleware.')
  const mounted = handler

  const server = createServer((request, response) => mounted(request, response))
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  started.push(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()))
    await rm(home, { recursive: true, force: true })
    await rm(repoRoot, { recursive: true, force: true })
  })
  return { port: (server.address() as AddressInfo).port, token, home, tokenFile }
}

describe('operator API authorization', () => {
  it('requires a non-empty exact token', () => {
    expect(operatorTokenMatches('', '')).toBe(false)
    expect(operatorTokenMatches('', 'expected')).toBe(false)
    expect(operatorTokenMatches('wrong', 'expected')).toBe(false)
    expect(operatorTokenMatches('expected', 'expected')).toBe(true)
  })
})

describe('bounded API readiness contract', () => {
  it('marks every unauthenticated refusal with the wire header the launcher probes', async () => {
    const { port } = await startBoundedApi()
    const refused = await fetch(`http://127.0.0.1:${port}/fleet`)
    expect(refused.status).toBe(401)
    expect(refused.headers.get('x-firstmate-operator')).toBe('bounded-api')
    expect(await refused.json()).toEqual({ error: 'A valid operator session token is required.' })
  })

  it('keeps the credential bootstrap failure opaque to an unauthenticated caller', async () => {
    const { port, home, tokenFile } = await startBoundedApi({ withToken: false })
    const refused = await fetch(`http://127.0.0.1:${port}/fleet`)
    expect(refused.status).toBe(503)
    const body = await refused.text()
    expect(body).toBe(JSON.stringify({ error: 'The operator session credential is unavailable.' }))
    expect(body).not.toContain(home)
    expect(body).not.toContain(tokenFile)
    expect(body).not.toContain('ENOENT')
  })

  it('marks an authenticated bounded refusal with the same header', async () => {
    const { port, token } = await startBoundedApi()
    const unknownRoute = await fetch(`http://127.0.0.1:${port}/not-a-route`, {
      headers: { authorization: `Bearer ${token}` },
    })
    expect(unknownRoute.status).toBe(404)
    expect(unknownRoute.headers.get('x-firstmate-operator')).toBe('bounded-api')
  })
})
