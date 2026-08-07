import { fixtureSnapshot } from './fixture'
import type {
  FleetSnapshot,
  InstructionDelivery,
  InstructionDeliveryOutcome,
  InstructionPreviewEnvelope,
} from './model'

// A refusal only proves nothing was sent when the server says so. An absent or
// unrecognized outcome - a transport error, a response the API never shaped -
// stays 'unknown' so the UI never invites a duplicate live send.
export class OperatorApiError extends Error {
  readonly delivered: InstructionDeliveryOutcome

  constructor(message: string, delivered: InstructionDeliveryOutcome = 'unknown') {
    super(message)
    this.delivered = delivered
  }
}

function reportedOutcome(body: unknown): InstructionDeliveryOutcome {
  if (typeof body !== 'object' || body === null || !('delivered' in body)) return 'unknown'
  return (body as { delivered: unknown }).delivered === 'no' ? 'no' : 'unknown'
}

function sessionToken() {
  const fragment = new URLSearchParams(window.location.hash.replace(/^#/, ''))
  const bootstrapped = fragment.get('token') ?? ''
  if (bootstrapped) {
    window.sessionStorage.setItem('fm-operator-token', bootstrapped)
    window.history.replaceState(null, '', `${window.location.pathname}${window.location.search}`)
  }
  return bootstrapped || window.sessionStorage.getItem('fm-operator-token') || ''
}

async function api<T>(path: string, init: RequestInit = {}) {
  const token = sessionToken()
  const response = await fetch(path, {
    ...init,
    headers: {
      ...(init.body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...init.headers,
    },
  })
  const body: unknown = await response.json().catch(() => null)
  const reported = typeof body === 'object' && body !== null && 'error' in body
    && typeof (body as { error: unknown }).error === 'string'
    ? (body as { error: string }).error
    : ''
  if (!response.ok) {
    throw new OperatorApiError(
      reported || `Operator API responded with HTTP ${response.status}.`,
      reportedOutcome(body),
    )
  }
  return body as T
}

export async function loadSnapshot() {
  if (import.meta.env.VITE_FM_OPERATOR_FIXTURE === '1') return fixtureSnapshot
  const body = await api<FleetSnapshot>('/api/fleet')
  if (typeof body !== 'object' || body === null || !('workers' in body) || !('provenance' in body)) {
    throw new Error('Operator API returned a response that is not a fleet snapshot.')
  }
  return body
}

export function requestInstructionPreview(workerId: string, instruction: string) {
  return api<InstructionPreviewEnvelope>('/api/instructions/preview', {
    method: 'POST',
    body: JSON.stringify({ workerId, instruction }),
  })
}

export function confirmInstruction(previewId: string) {
  return api<InstructionDelivery>('/api/instructions/confirm', {
    method: 'POST',
    body: JSON.stringify({ previewId }),
  })
}
