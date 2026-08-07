import { execFile } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { previewInstruction } from '../src/domain.ts'
import type { FleetSnapshot, InstructionPreview } from '../src/model.ts'

const execFileAsync = promisify(execFile)
const PREVIEW_LIFETIME_MS = 60_000
const MAX_PENDING_PREVIEWS = 100

type PendingPreview = {
  workerId: string
  instruction: string
  resolution: InstructionPreview['resolution']
  expiresAt: number
}

export type InstructionPreviewEnvelope = {
  previewId: string
  expiresAt: string
  preview: InstructionPreview
}

export class InstructionMutationError extends Error {
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

export type InstructionControllerOptions = {
  repoRoot: string
  fmHome: string
  readSnapshot: () => Promise<FleetSnapshot>
  execute?: (target: string, instruction: string) => Promise<void>
  now?: () => number
  createId?: () => string
  logDiagnostic?: (message: string) => void
}

// fm-send distinguishes an unresolvable target, a failed backend send, and a
// typed-but-unsubmitted composer by exit code and stderr. The browser keeps one
// generic refusal, so the detail is written to the server log instead of being
// discarded. The instruction text itself is never included.
function describeExecuteFailure(target: string, error: unknown) {
  const detail = error as { code?: unknown; signal?: unknown; stderr?: unknown }
  const code = typeof detail?.code === 'number' || typeof detail?.code === 'string' ? detail.code : 'unknown'
  const signal = typeof detail?.signal === 'string' ? detail.signal : 'none'
  const stderr = typeof detail?.stderr === 'string' ? detail.stderr.trim().slice(0, 2_000) : ''
  return `fm-operator: fm-send delivery failed for ${target}: exit=${code} signal=${signal} stderr=${stderr || '<empty>'}`
}

export class InstructionController {
  private readonly pending = new Map<string, PendingPreview>()
  private readonly readSnapshot: () => Promise<FleetSnapshot>
  private readonly execute: (target: string, instruction: string) => Promise<void>
  private readonly now: () => number
  private readonly createId: () => string
  private readonly logDiagnostic: (message: string) => void

  constructor(options: InstructionControllerOptions) {
    this.readSnapshot = options.readSnapshot
    this.now = options.now ?? Date.now
    this.createId = options.createId ?? randomUUID
    this.logDiagnostic = options.logDiagnostic ?? ((message) => { process.stderr.write(`${message}\n`) })
    this.execute = options.execute ?? (async (target, instruction) => {
      await execFileAsync(join(options.repoRoot, 'bin', 'fm-send.sh'), [target, instruction], {
        cwd: options.repoRoot,
        env: { ...process.env, FM_HOME: options.fmHome, FM_ROOT_OVERRIDE: options.repoRoot },
        encoding: 'utf8',
        timeout: 30_000,
        maxBuffer: 256 * 1024,
      })
    })
  }

  async preview(workerId: string, instruction: string): Promise<InstructionPreviewEnvelope> {
    this.purgeExpired()
    if (this.pending.size >= MAX_PENDING_PREVIEWS) {
      throw new InstructionMutationError(429, 'Too many instruction previews are awaiting confirmation.')
    }
    let preview: InstructionPreview
    try {
      preview = previewInstruction(await this.readSnapshot(), workerId, instruction)
    } catch (error) {
      throw new InstructionMutationError(400, error instanceof Error ? error.message : 'Instruction preview was refused.')
    }
    const previewId = this.createId()
    const expiresAt = this.now() + PREVIEW_LIFETIME_MS
    this.pending.set(previewId, {
      workerId: preview.worker.id,
      instruction: preview.instruction,
      resolution: preview.resolution,
      expiresAt,
    })
    return { previewId, expiresAt: new Date(expiresAt).toISOString(), preview }
  }

  async confirm(previewId: string) {
    if (!previewId) throw new InstructionMutationError(400, 'A preview id is required.')
    const pending = this.pending.get(previewId)
    this.pending.delete(previewId)
    if (!pending) throw new InstructionMutationError(404, 'Instruction preview is missing, expired, or already consumed.')
    if (pending.expiresAt <= this.now()) throw new InstructionMutationError(410, 'Instruction preview expired before confirmation.')

    let current: InstructionPreview
    try {
      current = previewInstruction(await this.readSnapshot(), pending.workerId, pending.instruction)
    } catch {
      throw new InstructionMutationError(409, 'Worker identity or endpoint changed after preview. Prepare a new instruction.')
    }
    if (JSON.stringify(current.resolution) !== JSON.stringify(pending.resolution)) {
      throw new InstructionMutationError(409, 'Worker identity or endpoint changed after preview. Prepare a new instruction.')
    }
    const target = `fm-${current.worker.id}`
    try {
      await this.execute(target, current.instruction)
    } catch (error) {
      this.logDiagnostic(describeExecuteFailure(target, error))
      throw new InstructionMutationError(409, 'fm-send refused or could not confirm the instruction delivery.')
    }
    return {
      status: 'accepted' as const,
      durableId: current.worker.id,
      owner: 'bin/fm-send.sh' as const,
    }
  }

  private purgeExpired() {
    const now = this.now()
    for (const [id, preview] of this.pending) {
      if (preview.expiresAt <= now) this.pending.delete(id)
    }
  }
}
