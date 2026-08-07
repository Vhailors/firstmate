// @vitest-environment node
import { chmod, mkdir, mkdtemp, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { SafeFirstmateAdapter } from './safe-adapter.ts'

async function fixtureHome() {
  const root = await mkdtemp(join(tmpdir(), 'fm-operator-adapter-'))
  const repo = join(root, 'repo')
  const home = join(root, 'home')
  await mkdir(join(repo, 'bin'), { recursive: true })
  await mkdir(join(repo, 'docs'), { recursive: true })
  await mkdir(join(repo, '.agents', 'skills', 'bearings'), { recursive: true })
  await mkdir(join(home, 'data', 'alpha'), { recursive: true })
  await writeFile(join(repo, 'docs', 'architecture.md'), '# Architecture\n')
  await writeFile(join(repo, 'docs', 'operator-control-plane.md'), '# Operator\n')
  await writeFile(join(home, 'data', 'alpha', 'report.md'), '# Report\ntoken=secret-value\n')
  await writeFile(join(home, 'data', 'secondmates.md'), '- product - Product work (home: /homes/product; scope: Product delivery.; projects: firstmate; added 2026-08-07)\n')
  await writeFile(join(repo, '.agents', 'skills', 'bearings', 'SKILL.md'), '---\nname: bearings\ndescription: >-\n  Fleet digest from\n  bounded state.\nuser-invocable: true\n---\n')
  const snapshot = {
    schema: 'fm-fleet-snapshot.v1', generated: '2026-08-07T10:00:00Z', fm_home: home,
    roots: { fm_root: repo, data: join(home, 'data') },
    tasks: [{
      id: 'worker-a', kind: 'ship', harness: 'codex', project: 'firstmate', backend: 'herdr',
      current_state: { state: 'working', source: 'pane' }, endpoint: { target: 'lab:pane-a' },
      backlog: { title: 'Safe adapter' }, hints: { open_decisions: [] },
    }],
    scout_reports: [{ id: 'alpha', path: join(home, 'data', 'alpha', 'report.md') }],
    secondmate_current: { records: [{ id: 'product', home: '/homes/product', remote: false, current: { state: 'working' }, counts: { active_children: 1, queued: 0, decisions_open: 0 } }] },
  }
  const script = join(repo, 'bin', 'fm-fleet-snapshot.sh')
  await writeFile(script, `#!/usr/bin/env bash\nprintf '%s' '${JSON.stringify(snapshot)}'\n`)
  await chmod(script, 0o755)
  return { repo, home }
}

describe('safe live adapter', () => {
  it('uses the authoritative snapshot, bounded reports, registry scope, and skill frontmatter', async () => {
    const { repo, home } = await fixtureHome()
    const snapshot = await new SafeFirstmateAdapter({ repoRoot: repo, fmHome: home }).read()
    expect(snapshot.provenance.sourceContract).toContain('fm-fleet-snapshot.v1')
    expect(snapshot.workers[0].endpoint).toBe('lab:pane-a')
    expect(snapshot.secondmates[0].scope).toBe('Product delivery.')
    expect(snapshot.documents.find((document) => document.id === 'alpha')?.content).toContain('[REDACTED]')
    expect(snapshot.skills.find((skill) => skill.name === 'bearings')?.invocation).toBe('/bearings')
    expect(snapshot.skills.find((skill) => skill.name === 'bearings')?.description).toBe('Fleet digest from bounded state.')
  })

  it('refuses a snapshot that resolves a different operational home', async () => {
    const { repo, home } = await fixtureHome()
    const script = join(repo, 'bin', 'fm-fleet-snapshot.sh')
    await writeFile(script, `#!/usr/bin/env bash\nprintf '%s' '{"schema":"fm-fleet-snapshot.v1","generated":"now","fm_home":"/wrong","roots":{"fm_root":"${repo}","data":"${home}/data"}}'\n`)
    await expect(new SafeFirstmateAdapter({ repoRoot: repo, fmHome: home }).read()).rejects.toThrow('different FM_HOME')
  })
})
