import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import App from './App.tsx'
import { previewInstruction } from './domain.ts'
import { fixtureSnapshot } from './fixture.ts'

describe('operator UI core flows', () => {
  it('renders fleet, secondmates, decisions, blockers, and provenance', () => {
    render(<App initialSnapshot={fixtureSnapshot} />)
    expect(screen.getByRole('heading', { name: 'Fleet at a glance' })).toBeInTheDocument()
    expect(screen.getByText('Product features, UI delivery, and release readiness.')).toBeInTheDocument()
    expect(screen.getByText('Choose the first bounded document write owner')).toBeInTheDocument()
    expect(screen.getByText('Fixture data')).toBeInTheDocument()
  })

  it('reviews a secondmate-scoped plan before leaving submission disabled', async () => {
    const user = userEvent.setup()
    render(<App initialSnapshot={fixtureSnapshot} />)
    await user.click(within(screen.getByRole('navigation', { name: 'Primary navigation' })).getByRole('button', { name: 'Plan' }))
    await user.type(screen.getByLabelText('Project'), 'firstmate')
    await user.type(screen.getByLabelText('Task title'), 'Ship the safe reader')
    await user.type(screen.getByLabelText('Objective'), 'Read the authoritative fleet snapshot.')
    await user.click(screen.getByRole('button', { name: 'Review draft' }))
    expect(screen.getByRole('heading', { name: 'Mutation and authority summary' })).toBeInTheDocument()
    expect(screen.getByText(/Create one ship task routed to product/)).toBeInTheDocument()
    await user.click(screen.getByRole('switch', { name: 'I reviewed the scope and authority summary' }))
    expect(screen.getByRole('button', { name: 'Create task' })).toBeDisabled()
    expect(screen.getByText('Dry-run complete. No task or backlog record was changed.')).toBeInTheDocument()
  })

  it('refuses a hidden fallback for the unavailable ThinkPad worker', async () => {
    const user = userEvent.setup()
    render(<App initialSnapshot={fixtureSnapshot} />)
    await user.click(within(screen.getByRole('navigation', { name: 'Primary navigation' })).getByRole('button', { name: 'Observe' }))
    await user.selectOptions(screen.getByLabelText('Recorded worker'), 'thinkpad-unity-review')
    await user.type(screen.getByLabelText('Instruction'), 'Inspect the focused Unity pane.')
    await user.click(screen.getByRole('button', { name: 'Prepare instruction' }))
    expect(screen.getByRole('alert')).toHaveTextContent('Refusing VPS, SSH, or detached-terminal fallback')
    expect(screen.getByText('No fallback to fm-remote, hidden SSH, or a detached terminal is permitted.')).toBeInTheDocument()
  })

  it('executes a live instruction only after preview and explicit confirmation', async () => {
    const user = userEvent.setup()
    const liveSnapshot = {
      ...fixtureSnapshot,
      provenance: { ...fixtureSnapshot.provenance, mode: 'live' as const, label: 'Live fleet' },
      trust: {
        ...fixtureSnapshot.trust,
        capabilities: { ...fixtureSnapshot.trust.capabilities, sendInstruction: true },
      },
    }
    const requestInstructionPreview = vi.fn(async (workerId: string, instruction: string) => ({
      previewId: 'preview-live',
      expiresAt: '2026-08-07T10:01:00Z',
      preview: previewInstruction(liveSnapshot, workerId, instruction),
    }))
    const confirmInstruction = vi.fn(async () => ({
      status: 'accepted' as const,
      durableId: 'firstmate-control-plane-ui-20260810',
      owner: 'bin/fm-send.sh' as const,
    }))
    render(<App
      initialSnapshot={liveSnapshot}
      requestInstructionPreview={requestInstructionPreview}
      confirmInstruction={confirmInstruction}
    />)
    await user.click(within(screen.getByRole('navigation', { name: 'Primary navigation' })).getByRole('button', { name: 'Observe' }))
    await user.type(screen.getByLabelText('Instruction'), 'Review the failing test.')
    await user.click(screen.getByRole('button', { name: 'Prepare instruction' }))
    expect(requestInstructionPreview).toHaveBeenCalledWith('firstmate-control-plane-ui-20260810', 'Review the failing test.')
    expect(confirmInstruction).not.toHaveBeenCalled()
    await user.click(screen.getByRole('switch', { name: 'I reviewed the exact target and instruction' }))
    await user.click(screen.getByRole('button', { name: 'Send instruction' }))
    expect(confirmInstruction).toHaveBeenCalledWith('preview-live')
    expect(await screen.findByRole('status')).toHaveTextContent('accepted by bin/fm-send.sh')
    expect(screen.queryByText('No send performed')).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Instruction confirmation preview')).not.toBeInTheDocument()
    expect(screen.getByLabelText('Instruction delivery result')).toBeInTheDocument()
  })

  it('keeps the refusal reason and forces a fresh preview after a failed confirmation', async () => {
    const user = userEvent.setup()
    const liveSnapshot = {
      ...fixtureSnapshot,
      provenance: { ...fixtureSnapshot.provenance, mode: 'live' as const, label: 'Live fleet' },
      trust: {
        ...fixtureSnapshot.trust,
        capabilities: { ...fixtureSnapshot.trust.capabilities, sendInstruction: true },
      },
    }
    const requestInstructionPreview = vi.fn(async (workerId: string, instruction: string) => ({
      previewId: 'preview-refused',
      expiresAt: '2026-08-07T10:01:00Z',
      preview: previewInstruction(liveSnapshot, workerId, instruction),
    }))
    const confirmInstruction = vi.fn(async () => {
      throw new Error('fm-send refused or could not confirm the instruction delivery.')
    })
    render(<App
      initialSnapshot={liveSnapshot}
      requestInstructionPreview={requestInstructionPreview}
      confirmInstruction={confirmInstruction}
    />)
    await user.click(within(screen.getByRole('navigation', { name: 'Primary navigation' })).getByRole('button', { name: 'Observe' }))
    await user.type(screen.getByLabelText('Instruction'), 'Escalate the stuck lane.')
    await user.click(screen.getByRole('button', { name: 'Prepare instruction' }))
    await user.click(screen.getByRole('switch', { name: 'I reviewed the exact target and instruction' }))
    await user.click(screen.getByRole('button', { name: 'Send instruction' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('fm-send refused or could not confirm')
    expect(screen.queryByLabelText('Instruction delivery result')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Send instruction' })).toBeDisabled()
    await user.click(screen.getByRole('switch', { name: 'I reviewed the exact target and instruction' }))
    expect(screen.getByRole('button', { name: 'Send instruction' })).toBeDisabled()
    expect(confirmInstruction).toHaveBeenCalledOnce()
  })

  it('shows bounded document redaction and an unavailable write state', async () => {
    const user = userEvent.setup()
    render(<App initialSnapshot={fixtureSnapshot} />)
    await user.click(within(screen.getByRole('navigation', { name: 'Primary navigation' })).getByRole('button', { name: 'Documents' }))
    expect(screen.getByText('1 redacted')).toBeInTheDocument()
    expect(screen.getByText(/Token: \[REDACTED\]/)).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Edit' }))
    expect(screen.getByRole('button', { name: 'Review write' })).toBeDisabled()
    expect(screen.getByText('Edits stay local to this form. No file was changed.')).toBeInTheDocument()
  })

  it('makes invocation support explicit in the skill catalog', async () => {
    const user = userEvent.setup()
    render(<App initialSnapshot={fixtureSnapshot} />)
    await user.click(within(screen.getByRole('navigation', { name: 'Primary navigation' })).getByRole('button', { name: 'Skills' }))
    expect(screen.getByText('/bearings')).toBeInTheDocument()
    expect(screen.getByText('$design-taste-frontend')).toBeInTheDocument()
    expect(screen.getByText('Not directly invocable')).toBeInTheDocument()
  })

  it('keeps app paint classes off the body-level portal mount node', () => {
    render(<App initialSnapshot={fixtureSnapshot} />)
    const portal = document.querySelector('[data-portal-node]')
    expect(portal).not.toBeNull()
    // Fluent copies the provider root class list onto this absolutely positioned, z-index 1000000 node.
    // If `app-provider` lands there its background and 100dvh cover the viewport and swallow every click.
    expect(portal).not.toHaveClass('app-provider')
    expect(document.querySelector('.app-provider')).not.toHaveClass('fui-FluentProvider')
  })

  it('renders loading and unavailable states', async () => {
    let resolveSnapshot: (value: typeof fixtureSnapshot) => void = () => undefined
    const load = () => new Promise<typeof fixtureSnapshot>((resolve) => { resolveSnapshot = resolve })
    const first = render(<App loadSnapshot={load} />)
    expect(screen.getByLabelText('Loading fleet')).toBeInTheDocument()
    resolveSnapshot(fixtureSnapshot)
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Fleet at a glance' })).toBeInTheDocument())
    first.unmount()
    render(<App loadSnapshot={async () => { throw new Error('Snapshot contract unavailable.') }} />)
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('Snapshot contract unavailable.'))
  })
})
