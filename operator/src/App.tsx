import {
  Badge,
  Button,
  Field,
  FluentProvider,
  Input,
  Switch,
  Textarea,
  Tooltip,
  webDarkTheme,
  webLightTheme,
} from '@fluentui/react-components'
import {
  AppsListDetail24Regular,
  ArrowSync24Regular,
  BookOpen24Regular,
  CheckmarkCircle20Filled,
  ClipboardTaskListLtr24Regular,
  CloudDismiss24Regular,
  Code24Regular,
  DarkTheme24Regular,
  DesktopPulse24Regular,
  DocumentEdit24Regular,
  ErrorCircle20Filled,
  LockClosed24Regular,
  Navigation24Regular,
  Send24Regular,
  ShieldCheckmark24Regular,
  Warning20Filled,
} from '@fluentui/react-icons'
import { useEffect, useMemo, useState } from 'react'
import {
  confirmInstruction as defaultConfirmInstruction,
  loadSnapshot as defaultLoader,
  requestInstructionPreview as defaultRequestInstructionPreview,
} from './api'
import { previewInstruction, previewPlan } from './domain'
import type {
  FleetSnapshot,
  FleetState,
  InstructionDelivery,
  InstructionPreview,
  InstructionPreviewEnvelope,
  PlanDraft,
  PlanPreview,
} from './model'
import './App.css'

type View = 'fleet' | 'plan' | 'observe' | 'documents' | 'skills' | 'access'

type AppProps = {
  initialSnapshot?: FleetSnapshot
  loadSnapshot?: () => Promise<FleetSnapshot>
  requestInstructionPreview?: (workerId: string, instruction: string) => Promise<InstructionPreviewEnvelope>
  confirmInstruction?: (previewId: string) => Promise<InstructionDelivery>
}

const NAVIGATION: Array<{ id: View; label: string; icon: typeof AppsListDetail24Regular }> = [
  { id: 'fleet', label: 'Fleet', icon: AppsListDetail24Regular },
  { id: 'plan', label: 'Plan', icon: ClipboardTaskListLtr24Regular },
  { id: 'observe', label: 'Observe', icon: DesktopPulse24Regular },
  { id: 'documents', label: 'Documents', icon: BookOpen24Regular },
  { id: 'skills', label: 'Skills', icon: Code24Regular },
  { id: 'access', label: 'Access', icon: LockClosed24Regular },
]

const STATE_LABELS: Record<FleetState, string> = {
  working: 'Working', parked: 'Parked', done: 'Done', blocked: 'Blocked', paused: 'Paused', failed: 'Failed', unknown: 'Unknown',
}

function StateMark({ state }: { state: FleetState }) {
  const icon = state === 'blocked' || state === 'failed'
    ? <ErrorCircle20Filled />
    : state === 'unknown' || state === 'paused'
      ? <Warning20Filled />
      : <CheckmarkCircle20Filled />
  return <span className={`state-mark state-${state}`}>{icon}{STATE_LABELS[state]}</span>
}

function SectionHeading({ title, summary }: { title: string; summary: string }) {
  return <header className="section-heading"><h1>{title}</h1><p>{summary}</p></header>
}

function EmptyState({ title, message }: { title: string; message: string }) {
  return <div className="empty-state"><ShieldCheckmark24Regular /><h2>{title}</h2><p>{message}</p></div>
}

function FleetView({ snapshot }: { snapshot: FleetSnapshot }) {
  const working = snapshot.workers.filter((worker) => worker.state === 'working').length
  return <div className="view-stack">
    <SectionHeading title="Fleet at a glance" summary="Current state is rendered from durable identities, never inferred from a pane label." />
    <section className="metric-ribbon" aria-label="Fleet summary">
      <div><strong>{working}</strong><span>working</span></div>
      <div><strong>{snapshot.secondmates.length}</strong><span>secondmates</span></div>
      <div><strong>{snapshot.decisions.length}</strong><span>open decisions</span></div>
      <div><strong>{snapshot.blockers.length}</strong><span>blockers</span></div>
    </section>

    <section className="content-section">
      <div className="title-row"><h2>Missions and workers</h2><Badge appearance="outline">{snapshot.workers.length} recorded</Badge></div>
      <div className="worker-list">
        {snapshot.workers.map((worker) => <article className="worker-row" key={worker.id}>
          <div className="worker-primary"><StateMark state={worker.state} /><h3>{worker.title}</h3><p>{worker.id}</p></div>
          <dl className="worker-facts"><div><dt>Project</dt><dd>{worker.project}</dd></div><div><dt>Runtime</dt><dd>{worker.harness} on {worker.backend}</dd></div></dl>
          <div className="worker-endpoint"><span>Exact endpoint</span><code>{worker.endpoint ?? 'unavailable'}</code>{worker.blocker && <p>{worker.blocker}</p>}</div>
        </article>)}
      </div>
    </section>

    <div className="split-layout">
      <section className="content-section">
        <div className="title-row"><h2>Secondmates</h2><span className="muted">Registered homes</span></div>
        <div className="secondmate-grid">
          {snapshot.secondmates.map((secondmate) => <article className="secondmate-panel" key={secondmate.id}>
            <div className="title-row"><h3>{secondmate.id}</h3><StateMark state={secondmate.state} /></div>
            <p>{secondmate.scope}</p>
            <div className="mini-stats"><span>{secondmate.activeChildren} active</span><span>{secondmate.queued} queued</span><span>{secondmate.decisions} decisions</span></div>
            {secondmate.reason && <div className="inline-warning"><CloudDismiss24Regular />{secondmate.reason}</div>}
          </article>)}
        </div>
      </section>
      <section className="content-section decision-section">
        <div className="title-row"><h2>Open decisions</h2><Badge color="warning">Captain</Badge></div>
        {snapshot.decisions.length === 0
          ? <EmptyState title="No decisions waiting" message="The durable decision inventory is clear." />
          : snapshot.decisions.map((decision) => <article className="decision-row" key={decision.key}><span>{decision.origin}</span><h3>{decision.title}</h3><p>{decision.reason}</p><code>{decision.key}</code></article>)}
      </section>
    </div>
  </div>
}

function PlanView({ snapshot }: { snapshot: FleetSnapshot }) {
  const firstSecondmate = snapshot.secondmates[0]?.id ?? ''
  const [draft, setDraft] = useState<PlanDraft>({ secondmateId: firstSecondmate, project: '', title: '', objective: '', authority: 'implementation' })
  const [preview, setPreview] = useState<PlanPreview | null>(null)
  const [error, setError] = useState('')
  const [confirmed, setConfirmed] = useState(false)

  function review() {
    try {
      setPreview(previewPlan(snapshot, draft)); setError(''); setConfirmed(false)
    } catch (reason) { setPreview(null); setError(reason instanceof Error ? reason.message : 'Draft could not be reviewed.') }
  }

  return <div className="view-stack">
    <SectionHeading title="Plan with clear authority" summary="Draft one secondmate-scoped task, then inspect the exact owner and intended mutation." />
    <div className="form-layout">
      <section className="form-surface" aria-label="Task draft">
        <Field label="Secondmate" hint="The selection must resolve to one registered durable identity.">
          <select aria-label="Secondmate" value={draft.secondmateId} onChange={(event) => setDraft({ ...draft, secondmateId: event.target.value })}>
            {snapshot.secondmates.map((secondmate) => <option key={secondmate.id} value={secondmate.id}>{secondmate.id} - {secondmate.summary}</option>)}
          </select>
        </Field>
        <Field label="Project"><Input value={draft.project} onChange={(_, data) => setDraft({ ...draft, project: data.value })} /></Field>
        <Field label="Task title"><Input value={draft.title} onChange={(_, data) => setDraft({ ...draft, title: data.value })} /></Field>
        <Field label="Objective" hint="Describe the outcome and the boundaries that must remain intact."><Textarea resize="vertical" value={draft.objective} onChange={(_, data) => setDraft({ ...draft, objective: data.value })} /></Field>
        <Field label="Authority">
          <select aria-label="Authority" value={draft.authority} onChange={(event) => setDraft({ ...draft, authority: event.target.value as PlanDraft['authority'] })}>
            <option value="implementation">Implementation through normal delivery</option>
            <option value="read-only">Read-only investigation</option>
          </select>
        </Field>
        {error && <p className="form-error" role="alert">{error}</p>}
        <Button appearance="primary" onClick={review}>Review draft</Button>
      </section>
      <aside className="authority-panel">
        <ShieldCheckmark24Regular />
        <h2>Authority before action</h2>
        <p>The UI never writes a parallel task record. A confirmed request must return to Firstmate's existing intake and dispatch lifecycle.</p>
        <ul><li>No implicit project expansion</li><li>No worker spawn from the browser</li><li>No confirmation inferred from navigation</li></ul>
      </aside>
    </div>
    {preview && <section className="review-surface" aria-label="Authority summary">
      <div className="title-row"><h2>Mutation and authority summary</h2><Badge appearance="tint" color="important">Confirmation required</Badge></div>
      <dl className="review-grid">
        <div><dt>Durable secondmate</dt><dd>{preview.secondmate.id}</dd></div><div><dt>Scope</dt><dd>{preview.secondmate.scope}</dd></div>
        <div><dt>Project</dt><dd>{preview.project}</dd></div><div><dt>Authority</dt><dd>{preview.authority}</dd></div>
        <div className="wide"><dt>Intended mutation</dt><dd>{preview.intendedMutation}</dd></div><div className="wide"><dt>Objective</dt><dd>{preview.objective}</dd></div>
      </dl>
      {preview.warnings.map((warning) => <p className="inline-warning" key={warning}><Warning20Filled />{warning}</p>)}
      <Switch checked={confirmed} onChange={(_, data) => setConfirmed(data.checked)} label="I reviewed the scope and authority summary" />
      <Tooltip content={snapshot.trust.capabilities.planMutation ? 'Ready for the audited mutation adapter.' : 'Task mutation is unavailable in this vertical slice.'} relationship="description">
        <Button appearance="primary" disabled={!confirmed || !snapshot.trust.capabilities.planMutation}>Create task</Button>
      </Tooltip>
      {!snapshot.trust.capabilities.planMutation && <p className="capability-note">Dry-run complete. No task or backlog record was changed.</p>}
    </section>}
  </div>
}

function ObserveView({
  snapshot,
  requestPreview,
  confirm,
}: {
  snapshot: FleetSnapshot
  requestPreview: (workerId: string, instruction: string) => Promise<InstructionPreviewEnvelope>
  confirm: (previewId: string) => Promise<InstructionDelivery>
}) {
  const [workerId, setWorkerId] = useState(snapshot.workers[0]?.id ?? '')
  const [instruction, setInstruction] = useState('')
  const [preview, setPreview] = useState<InstructionPreview | null>(null)
  const [previewId, setPreviewId] = useState('')
  const [error, setError] = useState('')
  const [confirmed, setConfirmed] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [delivery, setDelivery] = useState<InstructionDelivery | null>(null)
  const [unconfirmed, setUnconfirmed] = useState(false)
  const worker = snapshot.workers.find((candidate) => candidate.id === workerId)

  function resetOutcome() { setPreview(null); setPreviewId(''); setConfirmed(false); setDelivery(null); setUnconfirmed(false) }

  async function review() {
    try {
      const envelope = snapshot.provenance.mode === 'fixture'
        ? { previewId: '', expiresAt: '', preview: previewInstruction(snapshot, workerId, instruction) }
        : await requestPreview(workerId, instruction)
      resetOutcome(); setPreview(envelope.preview); setPreviewId(envelope.previewId); setError('')
    } catch (reason) { resetOutcome(); setError(reason instanceof Error ? reason.message : 'Instruction could not be prepared.') }
  }

  // A non-zero fm-send exit does not mean nothing was delivered: fm-send refuses
  // with the text already submitted when its pending-reply commit fails. The
  // consumed preview is torn down so no confirmation surface can claim the send
  // never happened and no resend is possible without a fresh preview.
  async function send() {
    if (!previewId) return
    setSubmitting(true); setError('')
    try { const accepted = await confirm(previewId); resetOutcome(); setDelivery(accepted) }
    catch (reason) { resetOutcome(); setUnconfirmed(true); setError(reason instanceof Error ? reason.message : 'Instruction could not be sent.') }
    finally { setSubmitting(false) }
  }

  return <div className="view-stack">
    <SectionHeading title="Observe, then steer" summary="Resolve an exact recorded worker or visible pane before composing any instruction." />
    <div className="observation-layout">
      <section className="content-section">
        <Field label="Recorded worker"><select aria-label="Recorded worker" value={workerId} onChange={(event) => { setWorkerId(event.target.value); resetOutcome() }}>{snapshot.workers.map((item) => <option value={item.id} key={item.id}>{item.title}</option>)}</select></Field>
        {worker && <div className="identity-card"><div className="title-row"><h2>{worker.title}</h2><StateMark state={worker.state} /></div><dl>
          <div><dt>Durable id</dt><dd><code>{worker.id}</code></dd></div><div><dt>Backend</dt><dd>{worker.backend}</dd></div><div><dt>Endpoint</dt><dd><code>{worker.endpoint ?? 'unavailable'}</code></dd></div><div><dt>State source</dt><dd>{worker.stateSource}</dd></div>
        </dl>{worker.remote?.host === 'fm-thinkpad' && worker.remote.visibility !== 'visible-herdr' && <div className="refusal"><CloudDismiss24Regular /><div><strong>Visible remote unavailable</strong><p>No fallback to fm-remote, hidden SSH, or a detached terminal is permitted.</p></div></div>}</div>}
      </section>
      <section className="form-surface">
        <Field label="Instruction" hint="The existing fm-send composer, busy, and submit guards remain authoritative."><Textarea resize="vertical" value={instruction} onChange={(_, data) => { setInstruction(data.value); resetOutcome() }} /></Field>
        {error && <p className="form-error" role="alert">{error}</p>}
        <Button appearance="primary" icon={<Send24Regular />} onClick={() => void review()}>Prepare instruction</Button>
      </section>
    </div>
    {preview && <section className="review-surface" aria-label="Instruction confirmation preview">
      <div className="title-row"><h2>Confirmation preview</h2><Badge appearance="outline">No send performed</Badge></div>
      <dl className="review-grid"><div><dt>Durable id</dt><dd>{preview.resolution.durableId}</dd></div><div><dt>Backend endpoint</dt><dd>{preview.resolution.backend}: {preview.resolution.endpoint}</dd></div><div className="wide"><dt>Approved executable</dt><dd><code>{preview.command.executable}</code></dd></div><div className="wide"><dt>Arguments</dt><dd><code>{JSON.stringify(preview.command.args)}</code></dd></div></dl>
      <p>{preview.auditSummary}</p>
      <Switch checked={confirmed} onChange={(_, data) => setConfirmed(data.checked)} label="I reviewed the exact target and instruction" />
      <Button appearance="primary" disabled={!confirmed || !previewId || !snapshot.trust.capabilities.sendInstruction || submitting} onClick={() => void send()}>{submitting ? 'Sending…' : 'Send instruction'}</Button>
      {!snapshot.trust.capabilities.sendInstruction && <p className="capability-note">Fixture mode is read-only. Live sessions enable confirmed sends.</p>}
    </section>}
    {delivery && <section className="review-surface" aria-label="Instruction delivery result">
      <div className="title-row"><h2>Instruction sent</h2><Badge appearance="filled" color="success">Send performed</Badge></div>
      <p className="success-note" role="status">Instruction accepted by {delivery.owner} for {delivery.durableId}.</p>
    </section>}
    {unconfirmed && <section className="review-surface" aria-label="Instruction outcome unknown">
      <div className="title-row"><h2>Delivery outcome unknown</h2><Badge appearance="filled" color="warning">May already be delivered</Badge></div>
      <p>fm-send did not confirm this instruction, and several of its refusals happen after the text has already been submitted to the worker. Read <code>state/operator.log</code> for the exact fm-send exit status and check the worker before preparing anything new. Do not resend on the assumption that nothing arrived.</p>
    </section>}
  </div>
}

function DocumentsView({ snapshot }: { snapshot: FleetSnapshot }) {
  const [selectedId, setSelectedId] = useState(snapshot.documents[0]?.id ?? '')
  const [mode, setMode] = useState<'read' | 'edit'>('read')
  const [draft, setDraft] = useState('')
  const selected = snapshot.documents.find((document) => document.id === selectedId)
  useEffect(() => setDraft(selected?.content ?? ''), [selected])
  return <div className="view-stack">
    <SectionHeading title="Documents with provenance" summary="Only bounded report pointers and tracked documentation are readable. Secret-shaped content is redacted before display." />
    <div className="document-layout">
      <nav className="document-list" aria-label="Documents">{snapshot.documents.map((document) => <button className={document.id === selectedId ? 'selected' : ''} key={document.id} onClick={() => setSelectedId(document.id)}><DocumentEdit24Regular /><span><strong>{document.title}</strong><small>{document.kind} - {document.redactions} redactions</small></span></button>)}</nav>
      {selected ? <article className="document-reader">
        <header><div><h2>{selected.title}</h2><p>{selected.path}</p></div><div className="segmented"><button className={mode === 'read' ? 'active' : ''} onClick={() => setMode('read')}>Read</button><button className={mode === 'edit' ? 'active' : ''} onClick={() => setMode('edit')}>Edit</button></div></header>
        <div className="provenance-strip"><ShieldCheckmark24Regular /><span>{selected.provenance}</span>{selected.redactions > 0 && <Badge color="warning">{selected.redactions} redacted</Badge>}</div>
        {mode === 'read' ? <pre>{selected.content}</pre> : <div className="document-editor"><Field label="Document draft" hint={selected.writeReason}><Textarea resize="vertical" value={draft} onChange={(_, data) => setDraft(data.value)} /></Field><Button disabled={!selected.writable || !snapshot.trust.capabilities.documentWrite}>Review write</Button><p className="capability-note">Edits stay local to this form. No file was changed.</p></div>}
      </article> : <EmptyState title="No safe documents" message="The bounded adapter returned no readable report or tracked document." />}
    </div>
  </div>
}

function SkillsView({ snapshot }: { snapshot: FleetSnapshot }) {
  const [query, setQuery] = useState('')
  const skills = useMemo(() => snapshot.skills.filter((skill) => `${skill.name} ${skill.description} ${skill.appliesTo}`.toLowerCase().includes(query.toLowerCase())), [query, snapshot.skills])
  return <div className="view-stack">
    <SectionHeading title="Installed skills, exact paths" summary="Discovery is read-only. Invocation is explicit, audited, and never converted into arbitrary shell execution." />
    <Field label="Search skill catalog"><Input value={query} onChange={(_, data) => setQuery(data.value)} placeholder="Search by purpose or name" /></Field>
    <div className="skill-grid">{skills.map((skill) => <article className="skill-item" key={skill.id}><div className="title-row"><h2>{skill.name}</h2><Badge appearance="outline">{skill.source}</Badge></div><p>{skill.description}</p><dl><div><dt>Applies to</dt><dd>{skill.appliesTo}</dd></div><div><dt>Catalog path</dt><dd><code>{skill.path}</code></dd></div><div><dt>Supported invocation</dt><dd>{skill.invocation ? <code>{skill.invocation}</code> : 'Not directly invocable'}</dd></div></dl><p className="invocation-note">{skill.invocationNote}</p></article>)}</div>
    {skills.length === 0 && <EmptyState title="No matching skills" message="Try a broader purpose or skill name." />}
  </div>
}

function AccessView({ snapshot }: { snapshot: FleetSnapshot }) {
  return <div className="view-stack">
    <SectionHeading title="Private access boundary" summary="The initial URL stays local or Tailnet-private. Public ingress remains absent until authorization is designed and approved." />
    <div className="access-map">
      <article className="access-primary"><ShieldCheckmark24Regular /><h2>Local and Tailscale first</h2><p>The app binds to <code>{snapshot.trust.bind}</code>. Tailscale Serve is the intended HTTPS entry point for phone and Windows clients.</p><Badge color="success">Preferred boundary</Badge></article>
      <article><CloudDismiss24Regular /><h2>Cloudflare later</h2><p>Cloudflare Access can sit in front only after identity policy, origin authentication, session expiry, and audit ownership are approved.</p><Badge appearance="outline">{snapshot.trust.cloudflare}</Badge></article>
      <article className={snapshot.trust.thinkpad === 'unavailable' ? 'unavailable' : ''}><DesktopPulse24Regular /><h2>ThinkPad visibility</h2><p>Actions require alias <code>fm-thinkpad</code>, its own visible Herdr session, and one exact focused or selected workspace and pane.</p><Badge color={snapshot.trust.thinkpad === 'visible' ? 'success' : 'danger'}>{snapshot.trust.thinkpad}</Badge></article>
    </div>
    <section className="refusal-boundary"><LockClosed24Regular /><div><h2>Fail-closed conditions</h2><p>No visible ThinkPad Herdr means no remote action. There is no fallback to the VPS fm-remote session, hidden SSH, public tunnel, browser automation, or detached process.</p></div></section>
  </div>
}

export default function App({
  initialSnapshot,
  loadSnapshot = defaultLoader,
  requestInstructionPreview = defaultRequestInstructionPreview,
  confirmInstruction = defaultConfirmInstruction,
}: AppProps) {
  const [snapshot, setSnapshot] = useState<FleetSnapshot | null>(initialSnapshot ?? null)
  const [view, setView] = useState<View>('fleet')
  const [loading, setLoading] = useState(!initialSnapshot)
  const [error, setError] = useState('')
  const [dark, setDark] = useState(() => window.matchMedia?.('(prefers-color-scheme: dark)').matches ?? false)
  const [railOpen, setRailOpen] = useState(false)
  const [sessionToken, setSessionToken] = useState('')

  async function refresh() {
    setLoading(true); setError('')
    try { setSnapshot(await loadSnapshot()) }
    catch (reason) { setError(reason instanceof Error ? reason.message : 'Operator data unavailable.') }
    finally { setLoading(false) }
  }

  function connectPrivateSession() {
    window.sessionStorage.setItem('fm-operator-token', sessionToken)
    setSessionToken('')
    void refresh()
  }

  useEffect(() => {
    if (initialSnapshot) return
    let cancelled = false
    setLoading(true)
    setError('')
    void loadSnapshot()
      .then((result) => { if (!cancelled) setSnapshot(result) })
      .catch((reason: unknown) => { if (!cancelled) setError(reason instanceof Error ? reason.message : 'Operator data unavailable.') })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [initialSnapshot, loadSnapshot])

  const content = snapshot && ({
    fleet: <FleetView snapshot={snapshot} />,
    plan: <PlanView snapshot={snapshot} />,
    observe: <ObserveView snapshot={snapshot} requestPreview={requestInstructionPreview} confirm={confirmInstruction} />,
    documents: <DocumentsView snapshot={snapshot} />,
    skills: <SkillsView snapshot={snapshot} />,
    access: <AccessView snapshot={snapshot} />,
  } satisfies Record<View, React.ReactNode>)[view]

  // `app-provider` must stay off FluentProvider's own root: Fluent copies that root class list onto the
  // body-level portal mount node, where the app background and 100dvh turn it into a click-eating overlay.
  return <FluentProvider theme={dark ? webDarkTheme : webLightTheme}>
    <div className="app-provider app-shell" data-theme={dark ? 'dark' : 'light'}>
      <header className="topbar">
        <div className="brand"><Button className="rail-toggle" appearance="subtle" icon={<Navigation24Regular />} aria-label="Toggle navigation" onClick={() => setRailOpen(!railOpen)} /><div className="brand-mark">FM</div><div><strong>Firstmate Operator</strong><span>Authority stays visible</span></div></div>
        <div className="topbar-actions">{snapshot && <Tooltip content={snapshot.provenance.sourceContract} relationship="description"><Badge appearance="outline" color={snapshot.provenance.mode === 'fixture' ? 'warning' : 'success'}>{snapshot.provenance.mode === 'fixture' ? 'Fixture data' : 'Live data'}</Badge></Tooltip>}<Button appearance="subtle" icon={<ArrowSync24Regular />} aria-label="Refresh fleet" onClick={refresh} /><Button appearance="subtle" icon={<DarkTheme24Regular />} aria-label="Toggle color theme" onClick={() => setDark(!dark)} /></div>
      </header>
      <aside className={`rail ${railOpen ? 'rail-open' : ''}`}><nav aria-label="Primary navigation">{NAVIGATION.map((item) => <button aria-label={item.label} key={item.id} className={view === item.id ? 'active' : ''} onClick={() => { setView(item.id); setRailOpen(false) }}><item.icon /><span>{item.label}</span></button>)}</nav><div className="rail-foot"><ShieldCheckmark24Regular /><span>Private boundary</span></div></aside>
      <main>
        {loading && <div className="loading-state" aria-label="Loading fleet"><div /><div /><div /></div>}
        {!loading && error && <div className="error-state" role="alert"><ErrorCircle20Filled /><h1>Operator data unavailable</h1><p>{error}</p><div className="session-connect"><Field label="Private session token"><Input type="password" value={sessionToken} onChange={(_, data) => setSessionToken(data.value)} /></Field><Button appearance="primary" disabled={!sessionToken} onClick={connectPrivateSession}>Connect session</Button><Button onClick={refresh}>Retry</Button></div></div>}
        {!loading && !error && content}
      </main>
      <nav className="mobile-nav" aria-label="Mobile navigation">{NAVIGATION.map((item) => <button aria-label={item.label} key={item.id} className={view === item.id ? 'active' : ''} onClick={() => setView(item.id)}><item.icon /><span>{item.label}</span></button>)}</nav>
    </div>
  </FluentProvider>
}
