// @vitest-environment node
import { execFile } from 'node:child_process'
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { afterAll, describe, expect, it, vi } from 'vitest'
import { fixtureSnapshot } from '../src/fixture.ts'
import { InstructionController } from './instruction-controller.ts'

const execFileAsync = promisify(execFile)
const WORKER_ID = 'firstmate-control-plane-ui-20260810'
const temporaryRoots: string[] = []

afterAll(async () => {
  await Promise.all(temporaryRoots.map((path) => rm(path, { recursive: true, force: true })))
})

// A real repoRoot with an executable bin/fm-send.sh, so the controller's own
// default execution path - resolved script, argv, cwd, and explicit home env -
// is what the assertions observe.
async function fakeSendRepo(script: string) {
  const repoRoot = await realpath(await mkdtemp(join(tmpdir(), 'fm-operator-repo-')))
  const fmHome = await realpath(await mkdtemp(join(tmpdir(), 'fm-operator-home-')))
  temporaryRoots.push(repoRoot, fmHome)
  const record = join(repoRoot, 'fm-send.record')
  await mkdir(join(repoRoot, 'bin'), { recursive: true })
  await writeFile(
    join(repoRoot, 'bin', 'fm-send.sh'),
    [
      '#!/usr/bin/env bash',
      'set -u',
      '{',
      "  printf 'argc=%s\\n' \"$#\"",
      "  printf 'arg1=%s\\n' \"${1:-}\"",
      "  printf 'arg2=%s\\n' \"${2:-}\"",
      "  printf 'cwd=%s\\n' \"$(pwd -P)\"",
      "  printf 'fm_home=%s\\n' \"${FM_HOME:-}\"",
      "  printf 'fm_root=%s\\n' \"${FM_ROOT_OVERRIDE:-}\"",
      "  printf 'gate_bypass=%s\\n' \"${FM_GATE_REFUSE_BYPASS:-<unset>}\"",
      "  printf 'existing_corr=%s\\n' \"${FM_PENDING_REPLY_EXISTING_CORR:-<unset>}\"",
      "  printf 'state_override=%s\\n' \"${FM_STATE_OVERRIDE:-<unset>}\"",
      "  printf 'path_present=%s\\n' \"$([ -n \"${PATH:-}\" ] && printf yes || printf no)\"",
      `} > '${record}'`,
      script,
      '',
    ].join('\n'),
    { mode: 0o755 },
  )
  return { repoRoot, fmHome, record }
}

async function readRecord(record: string) {
  const lines = (await readFile(record, 'utf8')).trimEnd().split('\n')
  return Object.fromEntries(lines.map((line) => {
    const split = line.indexOf('=')
    return [line.slice(0, split), line.slice(split + 1)]
  }))
}

describe('confirmed instruction mutation', () => {
  it('previews without mutation, re-resolves, and executes fm-send once after confirmation', async () => {
    const execute = vi.fn(async () => undefined)
    const readSnapshot = vi.fn(async () => fixtureSnapshot)
    const controller = new InstructionController({
      repoRoot: '/repo',
      fmHome: '/home/fleet',
      readSnapshot,
      execute,
      now: () => 1_000,
      createId: () => 'preview-1',
    })
    const prepared = await controller.preview('firstmate-control-plane-ui-20260810', 'Review the failing test.')
    expect(prepared.previewId).toBe('preview-1')
    expect(execute).not.toHaveBeenCalled()

    await expect(controller.confirm('preview-1')).resolves.toEqual({
      status: 'accepted',
      durableId: 'firstmate-control-plane-ui-20260810',
      owner: 'bin/fm-send.sh',
    })
    expect(readSnapshot).toHaveBeenCalledTimes(2)
    expect(execute).toHaveBeenCalledOnce()
    expect(execute).toHaveBeenCalledWith('fm-firstmate-control-plane-ui-20260810', 'Review the failing test.')
    await expect(controller.confirm('preview-1')).rejects.toMatchObject({
      status: 404,
      delivered: 'no',
    })
  })

  it('refuses execution when the durable endpoint drifts after preview', async () => {
    const execute = vi.fn(async () => undefined)
    let endpoint = 'fm-lab:firstmate-control-plane-pane'
    const controller = new InstructionController({
      repoRoot: '/repo',
      fmHome: '/home/fleet',
      execute,
      createId: () => 'preview-drift',
      readSnapshot: async () => ({
        ...fixtureSnapshot,
        workers: fixtureSnapshot.workers.map((worker) => worker.id === 'firstmate-control-plane-ui-20260810'
          ? { ...worker, endpoint }
          : worker),
      }),
    })
    await controller.preview('firstmate-control-plane-ui-20260810', 'Check identity.')
    endpoint = 'fm-lab:replacement-pane'
    await expect(controller.confirm('preview-drift')).rejects.toMatchObject({
      status: 409,
      message: expect.stringContaining('endpoint changed'),
      delivered: 'no',
    })
    expect(execute).not.toHaveBeenCalled()
  })
})

describe('fm-send script boundary', () => {
  it('runs the repo fm-send.sh with fixed argv, repo cwd, and an explicit home', async () => {
    const { repoRoot, fmHome, record } = await fakeSendRepo('exit 0')
    const controller = new InstructionController({
      repoRoot,
      fmHome,
      readSnapshot: async () => fixtureSnapshot,
      createId: () => 'preview-boundary',
    })

    await controller.preview(WORKER_ID, '  Restart the failing check.  ')
    await expect(controller.confirm('preview-boundary')).resolves.toEqual({
      status: 'accepted',
      durableId: WORKER_ID,
      owner: 'bin/fm-send.sh',
    })

    expect(await readRecord(record)).toEqual({
      argc: '2',
      arg1: `fm-${WORKER_ID}`,
      arg2: 'Restart the failing check.',
      cwd: repoRoot,
      fm_home: fmHome,
      fm_root: repoRoot,
      gate_bypass: '<unset>',
      existing_corr: '<unset>',
      state_override: '<unset>',
      path_present: 'yes',
    })
  })

  it('never leaks the server process fleet environment into a browser-initiated send', async () => {
    vi.stubEnv('FM_GATE_REFUSE_BYPASS', '1')
    vi.stubEnv('FM_PENDING_REPLY_EXISTING_CORR', 'corr-from-another-turn')
    vi.stubEnv('FM_STATE_OVERRIDE', '/somewhere/else/state')
    try {
      const { repoRoot, fmHome, record } = await fakeSendRepo('exit 0')
      const controller = new InstructionController({
        repoRoot,
        fmHome,
        readSnapshot: async () => fixtureSnapshot,
        createId: () => 'preview-env',
      })

      await controller.preview(WORKER_ID, 'Continue the lane.')
      await expect(controller.confirm('preview-env')).resolves.toMatchObject({ status: 'accepted' })

      const recorded = await readRecord(record)
      expect(recorded.gate_bypass).toBe('<unset>')
      expect(recorded.existing_corr).toBe('<unset>')
      expect(recorded.state_override).toBe('<unset>')
      expect(recorded.fm_home).toBe(fmHome)
      expect(recorded.fm_root).toBe(repoRoot)
      expect(recorded.path_present).toBe('yes')
    } finally {
      vi.unstubAllEnvs()
    }
  })

  it('refuses generically to the browser while logging the fm-send exit detail', async () => {
    const { repoRoot, fmHome, record } = await fakeSendRepo(
      "printf 'error: text typed but not submitted\\n' >&2\nexit 3",
    )
    const logged: string[] = []
    const controller = new InstructionController({
      repoRoot,
      fmHome,
      readSnapshot: async () => fixtureSnapshot,
      createId: () => 'preview-refused',
      logDiagnostic: (message) => logged.push(message),
    })

    await controller.preview(WORKER_ID, 'Escalate the stuck lane.')
    await expect(controller.confirm('preview-refused')).rejects.toMatchObject({
      status: 409,
      message: 'fm-send refused or could not confirm the instruction delivery.',
      delivered: 'unknown',
    })

    expect((await readRecord(record)).arg1).toBe(`fm-${WORKER_ID}`)
    expect(logged).toHaveLength(1)
    expect(logged[0]).toContain(`fm-${WORKER_ID}`)
    expect(logged[0]).toContain('exit=3')
    expect(logged[0]).toContain('text typed but not submitted')
    expect(logged[0]).toContain('refused for')
    expect(logged[0]).not.toContain('Escalate the stuck lane.')
  })

  it('records a send this server killed distinctly from one fm-send refused', async () => {
    const { repoRoot, fmHome } = await fakeSendRepo('sleep 5\nexit 0')
    const logged: string[] = []
    const controller = new InstructionController({
      repoRoot,
      fmHome,
      readSnapshot: async () => fixtureSnapshot,
      createId: () => 'preview-killed',
      logDiagnostic: (message) => logged.push(message),
      execute: async (target, instruction) => {
        await execFileAsync(join(repoRoot, 'bin', 'fm-send.sh'), [target, instruction], {
          cwd: repoRoot,
          encoding: 'utf8',
          timeout: 250,
        })
      },
    })

    await controller.preview(WORKER_ID, 'Take over the wedged lane.')
    await expect(controller.confirm('preview-killed')).rejects.toMatchObject({ delivered: 'unknown' })
    expect(logged).toHaveLength(1)
    expect(logged[0]).toContain('terminated by the operator server')
    expect(logged[0]).toContain('signal=SIGTERM')
  })
})
