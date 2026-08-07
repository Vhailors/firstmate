// @vitest-environment node
import { chmod, mkdir, mkdtemp, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { readBoundOperatorToken, resolveOperatorRuntime } from './operator-auth.ts'

describe('operator runtime selection', () => {
  it('defaults to live mode and refuses to invent an FM_HOME', () => {
    expect(() => resolveOperatorRuntime({}, '/repo')).toThrow('FM_HOME is required')
    expect(resolveOperatorRuntime({ FM_HOME: '/home/fleet' }, '/repo')).toEqual({
      mode: 'live',
      fmHome: '/home/fleet',
      repoRoot: '/repo',
      tokenFile: '/home/fleet/config/operator-token',
    })
  })

  it('uses fixture mode only after the explicit test opt-in', () => {
    expect(resolveOperatorRuntime({ VITE_FM_OPERATOR_FIXTURE: '1' }, '/repo')).toEqual({ mode: 'fixture' })
  })
})

describe('home-bound operator token', () => {
  it('accepts only a private token record bound to the configured home', async () => {
    const root = await mkdtemp(join(tmpdir(), 'fm-operator-auth-'))
    const home = join(root, 'home')
    const other = join(root, 'other')
    const tokenFile = join(home, 'config', 'operator-token')
    await mkdir(join(home, 'config'), { recursive: true })
    await mkdir(other)
    const token = 'a'.repeat(64)
    await writeFile(tokenFile, `fm_home=${home}\ntoken=${token}\n`, { mode: 0o600 })
    expect(await readBoundOperatorToken(tokenFile, home)).toBe(token)
    await expect(readBoundOperatorToken(tokenFile, other)).rejects.toThrow('different FM_HOME')
    await chmod(tokenFile, 0o644)
    await expect(readBoundOperatorToken(tokenFile, home)).rejects.toThrow('permissions')
  })
})
