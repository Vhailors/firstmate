import { describe, expect, it } from 'vitest'
import { previewInstruction, previewPlan, redactSecrets, resolveWorker } from './domain.ts'
import { fixtureSnapshot } from './fixture.ts'

describe('durable identity resolution', () => {
  it('resolves exactly one recorded worker', () => {
    const worker = resolveWorker(fixtureSnapshot, 'firstmate-control-plane-ui-20260810')
    expect(worker.endpoint).toBe('fm-lab:firstmate-control-plane-pane')
  })

  it('refuses missing and ambiguous identities', () => {
    expect(() => resolveWorker(fixtureSnapshot, 'missing')).toThrow('No durable worker identity')
    const duplicate = { ...fixtureSnapshot, workers: [...fixtureSnapshot.workers, fixtureSnapshot.workers[0]] }
    expect(() => resolveWorker(duplicate, 'firstmate-control-plane-ui-20260810')).toThrow('ambiguous')
  })

  it('refuses ThinkPad fallback when visible Herdr is unavailable', () => {
    expect(() => resolveWorker(fixtureSnapshot, 'thinkpad-unity-review')).toThrow(
      'Refusing VPS, SSH, or detached-terminal fallback',
    )
  })
})

describe('authorization and confirmation boundaries', () => {
  it('previews a scoped task without mutating the snapshot', () => {
    const before = JSON.stringify(fixtureSnapshot)
    const preview = previewPlan(fixtureSnapshot, {
      secondmateId: 'product',
      project: 'firstmate',
      title: 'Add a safe view',
      objective: 'Render one bounded status surface.',
      authority: 'implementation',
    })
    expect(preview.confirmationRequired).toBe(true)
    expect(preview.mutationOwner).toBe('Firstmate task lifecycle')
    expect(JSON.stringify(fixtureSnapshot)).toBe(before)
  })

  it('refuses a task for an unavailable secondmate', () => {
    expect(() => previewPlan(fixtureSnapshot, {
      secondmateId: 'thinkpad', project: 'game-prototype', title: 'Inspect build',
      objective: 'Use the visible workstation.', authority: 'read-only',
    })).toThrow('unavailable')
  })

  it('builds an argv-shaped fm-send confirmation preview and never a shell string', () => {
    const preview = previewInstruction(
      fixtureSnapshot,
      'firstmate-control-plane-ui-20260810',
      'Review the failing test; do not change scope.',
    )
    expect(preview.command).toEqual({
      executable: 'bin/fm-send.sh',
      args: ['fm-firstmate-control-plane-ui-20260810', 'Review the failing test; do not change scope.'],
      environment: { FM_HOME: '<server-configured-home>' },
    })
    expect(preview.confirmationRequired).toBe(true)
  })

  it('refuses instruction text that fm-send would read as its --key control path', () => {
    expect(() => previewInstruction(fixtureSnapshot, 'firstmate-control-plane-ui-20260810', ' --key '))
      .toThrow('control selector')
    expect(previewInstruction(fixtureSnapshot, 'firstmate-control-plane-ui-20260810', '--key escape').command.args)
      .toEqual(['fm-firstmate-control-plane-ui-20260810', '--key escape'])
  })
})

describe('secret redaction', () => {
  it('redacts credential-shaped values while preserving ordinary text', () => {
    const result = redactSecrets('status ok\ntoken=super-secret-value\npassword: hunter2\nnext step')
    expect(result.content).toContain('status ok')
    expect(result.content).toContain('[REDACTED]')
    expect(result.content).not.toContain('super-secret-value')
    expect(result.content).not.toContain('hunter2')
    expect(result.redactions).toBe(2)
  })
})
