import type {
  FleetSnapshot,
  InstructionPreview,
  PlanDraft,
  PlanPreview,
  Secondmate,
  Worker,
} from './model.ts'

const SECRET_PATTERNS = [
  /\b(?:ghp|github_pat|sk|xox[baprs])-[-_A-Za-z0-9]{8,}\b/g,
  /\b(?:password|passwd|token|secret|api[_-]?key)\s*[:=]\s*[^\s,;]+/gi,
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g,
]

export function redactSecrets(input: string) {
  let redactions = 0
  const content = SECRET_PATTERNS.reduce((current, pattern) => current.replace(pattern, () => {
    redactions += 1
    return '[REDACTED]'
  }), input)
  return { content, redactions }
}

export function resolveWorker(snapshot: FleetSnapshot, selector: string): Worker {
  const matches = snapshot.workers.filter((worker) => worker.id === selector)
  if (matches.length !== 1) {
    throw new Error(matches.length === 0
      ? `No durable worker identity matches "${selector}".`
      : `Worker identity "${selector}" is ambiguous.`)
  }
  const worker = matches[0]
  if (!worker.endpoint) {
    throw new Error(`Worker "${selector}" has no recorded endpoint.`)
  }
  if (worker.remote?.host === 'fm-thinkpad' && worker.remote.visibility !== 'visible-herdr') {
    throw new Error('ThinkPad visible Herdr is unavailable. Refusing VPS, SSH, or detached-terminal fallback.')
  }
  return worker
}

export function resolveSecondmate(snapshot: FleetSnapshot, selector: string): Secondmate {
  const matches = snapshot.secondmates.filter((secondmate) => secondmate.id === selector)
  if (matches.length !== 1) {
    throw new Error(matches.length === 0
      ? `No registered secondmate matches "${selector}".`
      : `Secondmate identity "${selector}" is ambiguous.`)
  }
  return matches[0]
}

export function previewPlan(snapshot: FleetSnapshot, draft: PlanDraft): PlanPreview {
  const secondmate = resolveSecondmate(snapshot, draft.secondmateId)
  const title = draft.title.trim()
  const objective = draft.objective.trim()
  const project = draft.project.trim()
  if (!title || !objective || !project) {
    throw new Error('Project, title, and objective are required before review.')
  }
  if (secondmate.availability === 'unavailable') {
    throw new Error(`Secondmate "${secondmate.id}" is unavailable: ${secondmate.reason ?? 'unknown reason'}`)
  }
  const warnings = secondmate.projects.includes(project)
    ? []
    : [`${project} is outside this secondmate's provisioned project list. Scope review is required.`]
  return {
    ...draft,
    title,
    objective,
    project,
    secondmate,
    mutationOwner: 'Firstmate task lifecycle',
    intendedMutation: `Create one ${draft.authority === 'implementation' ? 'ship' : 'scout'} task routed to ${secondmate.id}; no direct backlog or pane write.`,
    confirmationRequired: true,
    warnings,
  }
}

export function previewInstruction(
  snapshot: FleetSnapshot,
  workerId: string,
  instruction: string,
): InstructionPreview {
  const worker = resolveWorker(snapshot, workerId)
  const trimmed = instruction.trim()
  if (!trimmed) throw new Error('Instruction text is required.')
  if (trimmed.length > 2_000) throw new Error('Instruction exceeds the 2,000 character safety bound.')
  return {
    worker,
    instruction: trimmed,
    resolution: {
      durableId: worker.id,
      backend: worker.backend,
      endpoint: worker.endpoint!,
      remoteHost: worker.remote?.host,
    },
    command: {
      executable: 'bin/fm-send.sh',
      args: [`fm-${worker.id}`, trimmed],
      environment: { FM_HOME: '<server-configured-home>' },
    },
    confirmationRequired: true,
    auditSummary: `No send performed. Confirmation re-resolves ${worker.id} from state/${worker.id}.meta, then delegates composer and submit checks to fm-send.`,
  }
}
