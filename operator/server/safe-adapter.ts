import { execFile } from 'node:child_process'
import { lstat, readFile, readdir, realpath, stat } from 'node:fs/promises'
import { extname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { promisify } from 'node:util'
import { redactSecrets } from '../src/domain.ts'
import type {
  Decision,
  DocumentRecord,
  FleetSnapshot,
  FleetState,
  Secondmate,
  SkillRecord,
  Worker,
} from '../src/model.ts'

const execFileAsync = promisify(execFile)
const MAX_SNAPSHOT_BYTES = 2 * 1024 * 1024
const MAX_DOCUMENT_BYTES = 256 * 1024
const MAX_SKILL_BYTES = 64 * 1024
const SAFE_DOCUMENT_EXTENSIONS = new Set(['.md', '.mdx', '.txt'])
const FORBIDDEN_PATH_PARTS = /(^|[/\\])(?:\.env|config|credentials?|secrets?|state)([/\\]|$)/i

type RawSnapshot = {
  schema: string
  generated: string
  fm_home: string
  roots: { fm_root: string; data: string }
  tasks?: Array<Record<string, unknown>>
  scout_reports?: Array<Record<string, unknown>>
  secondmate_current?: {
    records?: Array<Record<string, unknown>>
    registry?: { records?: Array<Record<string, unknown>> }
  }
}

type RegistryRecord = {
  id: string
  summary: string
  scope: string
  projects: string[]
  home: string
  host?: string
  remote: boolean
}

export type SafeAdapterOptions = {
  repoRoot: string
  fmHome: string
  skillRoots?: string[]
}

function stringValue(value: unknown) {
  return typeof value === 'string' ? value : ''
}

function numberValue(value: unknown) {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

function objectValue(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {}
}

function arrayValue(value: unknown) {
  return Array.isArray(value) ? value : []
}

function fleetState(value: unknown): FleetState {
  const state = stringValue(value)
  return ['working', 'parked', 'done', 'blocked', 'paused', 'failed', 'unknown'].includes(state)
    ? state as FleetState
    : 'unknown'
}

async function boundedRead(path: string, maximum: number) {
  const metadata = await lstat(path)
  if (!metadata.isFile() || metadata.isSymbolicLink()) throw new Error(`Unsafe file type: ${path}`)
  if (metadata.size > maximum) throw new Error(`File exceeds the ${maximum} byte read bound.`)
  return readFile(path, 'utf8')
}

async function assertWithin(root: string, candidate: string) {
  const canonicalRoot = await realpath(root)
  const canonicalCandidate = await realpath(candidate)
  const relation = relative(canonicalRoot, canonicalCandidate)
  if (relation === '..' || relation.startsWith(`..${sep}`) || isAbsolute(relation)) {
    throw new Error('Requested path escapes its configured read root.')
  }
  return canonicalCandidate
}

function parseRegistryLine(line: string): RegistryRecord | null {
  const remote = line.match(/^- ([A-Za-z0-9._-]+) - (.+) \(host:\s*([^;)]+);\s*root:\s*([^;)]+);\s*home:\s*([^;)]+);\s*scope:\s*(.*);\s*projects:\s*([^;)]*);\s*added\s+\d{4}-\d{2}-\d{2}\)\s*$/)
  if (remote) {
    return {
      id: remote[1], summary: remote[2], host: remote[3].trim(), home: remote[5].trim(),
      scope: remote[6].trim(), projects: remote[7].split(',').map((item) => item.trim()).filter(Boolean), remote: true,
    }
  }
  const local = line.match(/^- ([A-Za-z0-9._-]+) - (.+) \(home:\s*([^;)]+);\s*scope:\s*(.*);\s*projects:\s*([^;)]*);\s*added\s+\d{4}-\d{2}-\d{2}\)\s*$/)
  if (!local) return null
  return {
    id: local[1], summary: local[2], home: local[3].trim(), scope: local[4].trim(),
    projects: local[5].split(',').map((item) => item.trim()).filter(Boolean), remote: false,
  }
}

async function readRegistry(dataRoot: string) {
  try {
    const content = await boundedRead(join(dataRoot, 'secondmates.md'), 64 * 1024)
    return content.split('\n').map(parseRegistryLine).filter((record): record is RegistryRecord => record !== null)
  } catch {
    return []
  }
}

function mapWorker(task: Record<string, unknown>): Worker {
  const currentState = objectValue(task.current_state)
  const endpoint = objectValue(task.endpoint)
  const backlog = objectValue(task.backlog)
  const remote = objectValue(task.remote)
  const hints = objectValue(task.hints)
  const lastEvent = stringValue(hints.last_event_text)
  const remoteHost = stringValue(remote.host)
  return {
    id: stringValue(task.id),
    title: stringValue(backlog.title) || stringValue(task.id),
    project: stringValue(backlog.repo) || stringValue(task.project) || 'unassigned',
    kind: stringValue(task.kind) === 'scout' ? 'scout' : stringValue(task.kind) === 'secondmate' ? 'secondmate' : 'ship',
    state: fleetState(currentState.state),
    stateSource: stringValue(currentState.source) || 'none',
    backend: stringValue(task.backend) || 'unknown',
    endpoint: stringValue(endpoint.target) || null,
    harness: stringValue(task.harness) || 'unknown',
    blocker: fleetState(currentState.state) === 'blocked' ? stringValue(currentState.detail) : undefined,
    lastEvent: lastEvent || undefined,
    remote: remoteHost ? {
      host: remoteHost,
      visibility: 'unavailable',
    } : undefined,
  }
}

function mapSecondmate(record: Record<string, unknown>, registry: RegistryRecord[]): Secondmate {
  const id = stringValue(record.id)
  const route = registry.find((candidate) => candidate.id === id)
  const current = objectValue(record.current)
  const counts = objectValue(record.counts)
  const reason = stringValue(current.reason)
  const remote = record.remote === true
  return {
    id,
    summary: route?.summary ?? id,
    scope: route?.scope ?? 'Scope unavailable from the bounded registry read.',
    projects: route?.projects ?? [],
    state: fleetState(current.state),
    remote,
    host: stringValue(record.host) || route?.host,
    home: stringValue(record.home) || route?.home || 'unavailable',
    activeChildren: numberValue(counts.active_children),
    queued: numberValue(counts.queued),
    decisions: numberValue(counts.decisions_open),
    availability: reason ? 'unavailable' : current.state ? 'ready' : 'unknown',
    reason: reason || undefined,
  }
}

function mapDecisions(raw: RawSnapshot): Decision[] {
  const decisions: Decision[] = []
  for (const taskValue of raw.tasks ?? []) {
    const task = objectValue(taskValue)
    const hints = objectValue(task.hints)
    for (const decisionValue of arrayValue(hints.open_decisions)) {
      const decision = objectValue(decisionValue)
      const key = stringValue(decision.key) || stringValue(decisionValue)
      if (!key) continue
      decisions.push({
        key: `${stringValue(task.id)}/${key}`,
        title: stringValue(decision.title) || key.replaceAll('-', ' '),
        origin: stringValue(task.id),
        reason: stringValue(decision.reason) || 'Awaiting an authoritative decision.',
        blockedWork: arrayValue(decision.blocked_work).map(stringValue).filter(Boolean),
      })
    }
  }
  return decisions
}

function parseFrontmatter(content: string) {
  const match = content.match(/^---\n([\s\S]*?)\n---/)
  const fields = new Map<string, string>()
  if (!match) return fields
  const lines = match[1].split('\n')
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]
    const separator = line.indexOf(':')
    if (separator <= 0 || /^\s/.test(line)) continue
    const key = line.slice(0, separator).trim()
    const raw = line.slice(separator + 1).trim()
    if (raw === '>-' || raw === '>' || raw === '|-' || raw === '|') {
      const continuation: string[] = []
      while (index + 1 < lines.length && /^\s+/.test(lines[index + 1])) {
        continuation.push(lines[index + 1].trim())
        index += 1
      }
      fields.set(key, continuation.join(raw.startsWith('|') ? '\n' : ' ').trim())
    } else {
      fields.set(key, raw.replace(/^['"]|['"]$/g, ''))
    }
  }
  return fields
}

async function skillRecords(root: string, repoRoot: string): Promise<SkillRecord[]> {
  let directories
  try {
    directories = await readdir(root, { withFileTypes: true })
  } catch {
    return []
  }
  const results: SkillRecord[] = []
  for (const directory of directories.slice(0, 200)) {
    if (!directory.isDirectory() || directory.isSymbolicLink()) continue
    const file = join(root, directory.name, 'SKILL.md')
    try {
      const content = await boundedRead(file, MAX_SKILL_BYTES)
      const fields = parseFrontmatter(content)
      const name = fields.get('name') || directory.name
      const internal = root.includes(`${sep}.agents${sep}skills`)
      const userInvocable = fields.get('user-invocable') !== 'false'
      results.push({
        id: `${root}:${name}`,
        name,
        description: fields.get('description') || 'No catalog description provided.',
        appliesTo: internal ? 'Firstmate runtime and captain workflows.' : 'Installed skill surface.',
        source: internal ? 'Firstmate built-in' : root.startsWith(repoRoot) ? 'Firstmate public skill' : 'Installed skill root',
        path: relative(repoRoot, file).startsWith('..') ? file : relative(repoRoot, file),
        invocation: userInvocable ? (internal ? `/${name}` : `$${name}`) : null,
        invocationNote: userInvocable
          ? `Explicit invocation only: ${internal ? `/${name}` : `$${name}`}`
          : 'Agent-only. Load through the trigger declared in AGENTS.md.',
        userInvocable,
      })
    } catch {
      continue
    }
  }
  return results
}

export class SafeFirstmateAdapter {
  readonly repoRoot: string
  readonly fmHome: string
  readonly skillRoots: string[]

  constructor(options: SafeAdapterOptions) {
    this.repoRoot = resolve(options.repoRoot)
    this.fmHome = resolve(options.fmHome)
    this.skillRoots = options.skillRoots ?? [join(this.repoRoot, '.agents', 'skills'), join(this.repoRoot, 'skills')]
  }

  private async rawSnapshot(): Promise<RawSnapshot> {
    const executable = join(this.repoRoot, 'bin', 'fm-fleet-snapshot.sh')
    const { stdout } = await execFileAsync(executable, ['--json'], {
      cwd: this.repoRoot,
      env: { ...process.env, FM_HOME: this.fmHome, FM_ROOT_OVERRIDE: this.repoRoot },
      encoding: 'utf8',
      timeout: 20_000,
      maxBuffer: MAX_SNAPSHOT_BYTES,
    })
    const raw = JSON.parse(stdout) as RawSnapshot
    if (raw.schema !== 'fm-fleet-snapshot.v1') throw new Error('Unsupported fleet snapshot schema.')
    if (resolve(raw.fm_home) !== this.fmHome) throw new Error('Fleet snapshot returned a different FM_HOME identity.')
    return raw
  }

  async read(): Promise<FleetSnapshot> {
    const raw = await this.rawSnapshot()
    const registry = await readRegistry(join(this.fmHome, 'data'))
    const workers = (raw.tasks ?? []).map((task) => mapWorker(objectValue(task)))
    const secondmates = (raw.secondmate_current?.records ?? []).map((record) => mapSecondmate(objectValue(record), registry))
    const documents = await this.documents(raw)
    const skills = (await Promise.all(this.skillRoots.map((root) => skillRecords(root, this.repoRoot)))).flat()
    const blockers = [
      ...workers.filter((worker) => worker.blocker).map((worker) => `${worker.id}: ${worker.blocker}`),
      ...secondmates.filter((secondmate) => secondmate.availability === 'unavailable').map((secondmate) => `${secondmate.id}: ${secondmate.reason}`),
    ]
    return {
      provenance: {
        mode: 'live',
        label: 'Live bounded Firstmate adapter',
        observedAt: raw.generated,
        sourceContract: 'bin/fm-fleet-snapshot.sh --json (fm-fleet-snapshot.v1)',
      },
      trust: {
        bind: '127.0.0.1',
        transport: 'local',
        authentication: 'The application server must establish a session before exposing this adapter.',
        cloudflare: 'not-configured',
        tailscale: 'unknown',
        thinkpad: 'unknown',
        capabilities: { planMutation: false, sendInstruction: true, documentWrite: false },
      },
      workers,
      secondmates,
      decisions: mapDecisions(raw),
      documents,
      skills,
      blockers,
    }
  }

  private async documents(raw: RawSnapshot): Promise<DocumentRecord[]> {
    const candidates = [
      { id: 'architecture', path: join(this.repoRoot, 'docs', 'architecture.md'), title: 'Firstmate architecture', kind: 'architecture' as const },
      { id: 'operator-control-plane', path: join(this.repoRoot, 'docs', 'operator-control-plane.md'), title: 'Operator control-plane architecture', kind: 'architecture' as const },
      ...(raw.scout_reports ?? []).map((report) => ({
        id: stringValue(report.id),
        path: stringValue(objectValue(report.path).path) || stringValue(report.path),
        title: `${stringValue(report.id)} report`,
        kind: 'report' as const,
      })),
    ]
    const records: DocumentRecord[] = []
    for (const candidate of candidates) {
      if (!candidate.path || FORBIDDEN_PATH_PARTS.test(candidate.path) || !SAFE_DOCUMENT_EXTENSIONS.has(extname(candidate.path))) continue
      const allowedRoot = candidate.kind === 'report' ? join(this.fmHome, 'data') : join(this.repoRoot, 'docs')
      try {
        const safePath = await assertWithin(allowedRoot, candidate.path)
        const content = await boundedRead(safePath, MAX_DOCUMENT_BYTES)
        const redacted = redactSecrets(content)
        const metadata = await stat(safePath)
        records.push({
          id: candidate.id,
          title: candidate.title,
          path: relative(this.repoRoot, safePath).startsWith('..') ? safePath : relative(this.repoRoot, safePath),
          kind: candidate.kind,
          updatedAt: metadata.mtime.toISOString(),
          provenance: candidate.kind === 'report' ? 'Authoritative snapshot report pointer' : 'Tracked maintainer documentation',
          content: redacted.content,
          redactions: redacted.redactions,
          writable: false,
          writeReason: 'Initial live adapter is read-only. Writes require a contract-owned capability adapter.',
        })
      } catch {
        continue
      }
    }
    return records
  }
}
