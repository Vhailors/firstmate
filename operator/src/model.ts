export type Provenance = {
  mode: 'live' | 'fixture'
  label: string
  observedAt: string
  sourceContract: string
}

export type FleetState = 'working' | 'parked' | 'done' | 'blocked' | 'paused' | 'failed' | 'unknown'

export type Worker = {
  id: string
  title: string
  project: string
  kind: 'ship' | 'scout' | 'secondmate'
  state: FleetState
  stateSource: string
  backend: string
  endpoint: string | null
  harness: string
  blocker?: string
  lastEvent?: string
  remote?: {
    host: string
    visibility: 'visible-herdr' | 'unavailable'
    workspace?: string
    pane?: string
  }
}

export type Secondmate = {
  id: string
  summary: string
  scope: string
  projects: string[]
  state: FleetState
  remote: boolean
  host?: string
  home: string
  activeChildren: number
  queued: number
  decisions: number
  availability: 'ready' | 'unavailable' | 'unknown'
  reason?: string
}

export type Decision = {
  key: string
  title: string
  origin: string
  reason: string
  blockedWork: string[]
}

export type DocumentRecord = {
  id: string
  title: string
  path: string
  kind: 'report' | 'architecture' | 'verification'
  updatedAt: string
  provenance: string
  content: string
  redactions: number
  writable: boolean
  writeReason: string
}

export type SkillRecord = {
  id: string
  name: string
  description: string
  appliesTo: string
  source: string
  path: string
  invocation: string | null
  invocationNote: string
  userInvocable: boolean
}

export type TrustBoundary = {
  bind: string
  transport: 'local' | 'tailscale-private' | 'cloudflare-access'
  authentication: string
  cloudflare: 'not-configured' | 'configured'
  tailscale: 'available' | 'unavailable' | 'unknown'
  thinkpad: 'visible' | 'unavailable' | 'unknown'
  capabilities: {
    planMutation: boolean
    sendInstruction: boolean
    documentWrite: boolean
  }
}

export type FleetSnapshot = {
  provenance: Provenance
  trust: TrustBoundary
  workers: Worker[]
  secondmates: Secondmate[]
  decisions: Decision[]
  documents: DocumentRecord[]
  skills: SkillRecord[]
  blockers: string[]
}

export type PlanDraft = {
  secondmateId: string
  project: string
  title: string
  objective: string
  authority: 'read-only' | 'implementation'
}

export type PlanPreview = PlanDraft & {
  secondmate: Secondmate
  mutationOwner: 'Firstmate task lifecycle'
  intendedMutation: string
  confirmationRequired: true
  warnings: string[]
}

export type InstructionPreview = {
  worker: Worker
  instruction: string
  resolution: {
    durableId: string
    backend: string
    endpoint: string
    remoteHost?: string
  }
  command: {
    executable: 'bin/fm-send.sh'
    args: [string, string]
    environment: { FM_HOME: '<server-configured-home>' }
  }
  confirmationRequired: true
  auditSummary: string
}

export type InstructionPreviewEnvelope = {
  previewId: string
  expiresAt: string
  preview: InstructionPreview
}

export type InstructionDelivery = {
  status: 'accepted'
  durableId: string
  owner: 'bin/fm-send.sh'
}
