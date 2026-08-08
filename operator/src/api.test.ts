import { afterEach, describe, expect, it, vi } from 'vitest'
import { confirmInstruction, OperatorApiError } from './api.ts'

function respondWith(status: number, body: unknown) {
  vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })))
}

afterEach(() => { vi.unstubAllGlobals() })

describe('confirmed mutation delivery outcome', () => {
  it('reports a refusal the server proved happened before any send', async () => {
    respondWith(409, {
      error: 'Worker identity or endpoint changed after preview. Prepare a new instruction.',
      delivered: 'no',
    })
    await expect(confirmInstruction('preview-1')).rejects.toMatchObject({
      message: expect.stringContaining('endpoint changed after preview'),
      delivered: 'no',
    })
  })

  it('keeps an fm-send refusal indeterminate', async () => {
    respondWith(409, {
      error: 'fm-send refused or could not confirm the instruction delivery.',
      delivered: 'unknown',
    })
    await expect(confirmInstruction('preview-2')).rejects.toMatchObject({ delivered: 'unknown' })
  })

  it('assumes possible delivery when the response carries no outcome', async () => {
    respondWith(503, { error: 'Operator API unavailable.' })
    const refusal = await confirmInstruction('preview-3').catch((reason: unknown) => reason)
    expect(refusal).toBeInstanceOf(OperatorApiError)
    expect((refusal as OperatorApiError).delivered).toBe('unknown')
  })

  it('returns the accepted delivery unchanged on success', async () => {
    respondWith(202, { status: 'accepted', durableId: 'worker-1', owner: 'bin/fm-send.sh' })
    await expect(confirmInstruction('preview-4')).resolves.toEqual({
      status: 'accepted',
      durableId: 'worker-1',
      owner: 'bin/fm-send.sh',
    })
  })
})
