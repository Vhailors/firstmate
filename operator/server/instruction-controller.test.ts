// @vitest-environment node
import { describe, expect, it, vi } from 'vitest'
import { fixtureSnapshot } from '../src/fixture.ts'
import { InstructionController } from './instruction-controller.ts'

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
    await expect(controller.confirm('preview-1')).rejects.toThrow('already consumed')
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
    await expect(controller.confirm('preview-drift')).rejects.toThrow('endpoint changed')
    expect(execute).not.toHaveBeenCalled()
  })
})
