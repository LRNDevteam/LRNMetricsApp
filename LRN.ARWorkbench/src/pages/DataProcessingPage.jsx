import { useCallback, useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router';
import Icon from '../components/Icon';
import useTableSort from '../components/useTableSort';
import { Badge, ErrorBox, Loading, PageHeader } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt, runStatusBadgeClass } from '../utils/format';

export default function DataProcessingPage() {
  const { labId, lab } = useWorkbench();
  const navigate = useNavigate();
  const [runs, setRuns] = useState(null);
  const [insights, setInsights] = useState(null);
  const [uploaded, setUploaded] = useState(null);
  const [week, setWeek] = useState('current');
  const [error, setError] = useState('');
  const [running, setRunning] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [note, setNote] = useState('');
  // Run Master File Load: queues the Master File Processor for this lab (see MasterFileLoads).
  const [confirmingLoad, setConfirmingLoad] = useState(false);
  const [loadNote, setLoadNote] = useState('');
  const [queueing, setQueueing] = useState(false);
  const [loadMessage, setLoadMessage] = useState('');
  const [loadsVersion, setLoadsVersion] = useState(0);

  const load = useCallback(() => {
    setError('');
    arWorkbenchService.refreshRuns(labId, 15).then(setRuns).catch((e) => setError(e.message));
    arWorkbenchService.insights(labId).then((r) => setInsights(r || [])).catch((e) => { setInsights([]); setError(e.message); });
    arWorkbenchService.uploadedInsights(labId).then(setUploaded).catch(() => setUploaded({ tableInstalled: false, current: [], previous: [] }));
  }, [labId]);

  // A denial code opens the Work Queue on that code (primary or line, any spelling - CO-242, 242).
  // "Route to Work Queue" narrows to what is still unassigned with an open balance.
  const openCode = (code) => navigate(`/work-queue?${new URLSearchParams({ code, open: '1' })}`);
  // primary=1: the insight counts claims by PRIMARY denial, so the routed list must too (OBS-02).
  const route = (code) => navigate(`/work-queue?${new URLSearchParams({ code, primary: '1', status: 'Unassigned', open: '1' })}`);
  const systemRows = (current) => (insights || []).filter((i) => (current ? i.isCurrentWeek : !i.isCurrentWeek));
  const uploadedRows = (current) => (current ? uploaded?.current : uploaded?.previous) || [];
  // A week shows the team's uploaded Key Observations when there are any, else the system insights.
  const weekSource = (current) => (uploadedRows(current).length ? 'uploaded' : 'system');
  const weekStart = (current) => (weekSource(current) === 'uploaded'
    ? uploadedRows(current)[0]?.weekStart
    : systemRows(current)[0]?.weekStart);
  const isCurrent = week === 'current';
  const source = weekSource(isCurrent);
  const weekRows = source === 'uploaded' ? uploadedRows(isCurrent) : systemRows(isCurrent);
  const loadingInsights = insights === null || uploaded === null;

  useEffect(() => { load(); }, [load]);

  async function run() {
    setConfirming(false);
    setRunning(true);
    setError('');
    try {
      await arWorkbenchService.runRefresh(labId, note.trim() || null);
      setNote('');
    } catch (e) {
      setError(e.message);
    } finally {
      setRunning(false);
      load();
    }
  }

  async function queueMasterFileLoad() {
    setConfirmingLoad(false);
    setQueueing(true);
    setError('');
    setLoadMessage('');
    try {
      await arWorkbenchService.runMasterFileLoad(labId, loadNote.trim() || null);
      setLoadNote('');
      setLoadMessage('Master file load queued. The Master File Processor picks it up on its next poll; follow it under Master File Loads below.');
    } catch (e) {
      setError(e.message);
    } finally {
      setQueueing(false);
      setLoadsVersion((v) => v + 1);
    }
  }

  const last = runs?.find((r) => r.runStatus === 'Succeeded');

  return (
    <>
      <PageHeader note={`Sync every claim and line for ${lab?.labName || 'this lab'} from the claim-level and line-level master files`}>
        <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={queueing}
          onClick={() => { setConfirming(false); setConfirmingLoad(true); }}
          title="Run the Master File Processor for this lab: load the latest line-level and claim-level master files from SharePoint, with the denial data, then sync">
          {queueing ? <><span className="arwb-spinner" /> Queuing…</> : <><Icon name="refresh" size={15} /> Run Master File Load</>}
        </button>
        <button type="button" className="arwb-btn arwb-btn-sm" disabled={running}
          onClick={() => { setConfirmingLoad(false); setConfirming(true); }}
          title="Re-sync the AR Workbench from the master data already loaded in this lab's database">
          {running ? <><span className="arwb-spinner" /> Processing…</> : <><Icon name="refresh" size={15} /> Run Data Processing</>}
        </button>
      </PageHeader>

      {confirmingLoad && (
        <div className="arwb-card arwb-confirm">
          <p style={{ marginTop: 0 }}>
            This queues the Master File Processor for {lab?.labName || 'this lab'}. On its next poll it takes the lab’s latest master file from the
            SharePoint master folder, reloads <code>dbo.LineLevelData</code> and <code>dbo.ClaimLevelData</code> with the denial data, then runs
            the AR Workbench sync. The file is processed even if it was processed before. It runs in the background; a large lab can take a while.
          </p>
          <div className="arwb-field" style={{ marginBottom: 10 }}>
            <label htmlFor="dp-load-note">Reason / note (optional)</label>
            <input id="dp-load-note" className="arwb-input" value={loadNote} maxLength={1000} onChange={(e) => setLoadNote(e.target.value)} />
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={queueMasterFileLoad}>Run master file load</button>
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => setConfirmingLoad(false)}>Cancel</button>
          </div>
        </div>
      )}

      {confirming && (
        <div className="arwb-card arwb-confirm">
          <p style={{ marginTop: 0 }}>
            This syncs every claim in <code>dbo.ClaimLevelData</code> and every line in <code>dbo.LineLevelData</code>, applies the weekly
            re-sync rules, and reclassifies every claim into its AR queue. Workflow state (assignments, follow-ups, QA, CIP) is kept.
            A large lab can take a few minutes.
          </p>
          <div className="arwb-field" style={{ marginBottom: 10 }}>
            <label htmlFor="dp-note">Note for the run log (optional)</label>
            <input id="dp-note" className="arwb-input" value={note} maxLength={1000} onChange={(e) => setNote(e.target.value)} />
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={run}>Run now</button>
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => setConfirming(false)}>Cancel</button>
          </div>
        </div>
      )}

      <ErrorBox message={error} />
      {loadMessage && <div className="arwb-hint" style={{ padding: '0 0 12px' }}>{loadMessage}</div>}

      <MasterFileLoads labId={labId} version={loadsVersion} onFinished={load} />

      {last && (
        <div className="arwb-grid arwb-grid-kpi arwb-section">
          {/* OBS-01: a lab whose master file carries no InsertedDateTime has no source load time;
              the sync that read it is the next best answer, and is labelled as such. */}
          <Stat label="Master file loaded"
            value={last.sourceLoadedOn ? fmt.dateTime(last.sourceLoadedOn)
              : last.completedOn ? `${fmt.dateTime(last.completedOn)} (synced)` : '—'} />
          <Stat label="Last refresh" value={fmt.dateTime(last.completedOn)} />
          <Stat label="Source period" value={`${fmt.date(last.sourcePeriodStart)} – ${fmt.date(last.sourcePeriodEnd)}`} />
          <Stat label="Claims in source" value={fmt.count(last.sourceClaimRows)} />
          <Stat label="CPT lines read" value={fmt.count(last.sourceLineRows)} />
        </div>
      )}

      <div className="arwb-table-card arwb-section">
        <div className="arwb-panel-head">
          <h3>Denial Analysis Report</h3>
          <span className="arwb-card-sub">
            {loadingInsights ? 'loading…' : source === 'uploaded'
              ? 'Key Observations uploaded by the team in LRN Metrics · Open is what is still unassigned with an open balance today'
              : 'system-generated insights per denial code · counts are what is still unassigned with an open balance'}
          </span>
          <div className="arwb-panel-head-actions">
            {[['current', 'Current week'], ['previous', 'Previous week']].map(([id, label]) => {
              const ws = weekStart(id === 'current');
              return (
                <button key={id} type="button" className={`arwb-btn arwb-btn-sm ${week === id ? 'arwb-btn-primary' : ''}`} onClick={() => setWeek(id)} disabled={!ws}>
                  {label}{ws ? ` · ${fmt.date(ws)}` : ''}
                </button>
              );
            })}
          </div>
        </div>
        {!loadingInsights && (
          <div className={`arwb-insight-source ${source}`}>
            {source === 'uploaded'
              ? <><Badge className="arwb-badge-good">Uploaded</Badge> {fmt.count(weekRows.length)} denial code{weekRows.length === 1 ? '' : 's'} from the team’s Key Observations{weekRows[0]?.updatedBy ? ` · last updated by ${weekRows[0].updatedBy}` : ''}. Click a denial code to open its claims in the Work Queue.</>
              : <><Badge className="arwb-badge-info">System generated</Badge> No Key Observations have been uploaded in LRN Metrics for this week, so these are built from the synced claims. Click a denial code to open its claims in the Work Queue.</>}
          </div>
        )}
        {source === 'uploaded' && !loadingInsights
          ? <UploadedInsightTable rows={weekRows} onCode={openCode} onRoute={route} />
          : <SystemInsightTable rows={loadingInsights ? null : weekRows} onCode={openCode} onRoute={route} />}
      </div>

      <SnapshotHistory labId={labId} />

      {!runs ? <Loading /> : <RunHistory runs={runs} />}
    </>
  );
}

// The system-generated insights per denial code (dbo.ARWB_vw_DenialInsight). rows null = loading.
function SystemInsightTable({ rows: all, onCode, onRoute }) {
  const { rows, th } = useTableSort(all || [], {
    code: (i) => i.denialCode, description: (i) => i.denialDescription, category: (i) => i.denialCategory, claims: (i) => i.outstandingClaims,
    balance: (i) => i.outstandingBalance, payer: (i) => i.topPayer, impact: (i) => i.impactPct
  });
  return (
    <div className="arwb-table-wrap">
      <table className="arwb-data-table">
        <thead>
          <tr>
            {th('code', 'Denial Code')}{th('description', 'Description')}{th('category', 'Category')}{th('claims', 'Open Claims', { className: 'num' })}
            {th('balance', 'Open Balance', { className: 'num' })}{th('payer', 'Top Payer')}{th('impact', 'Impact', { className: 'num' })}
            <th scope="col">Observation</th><th scope="col">Recommended Action</th><th />
          </tr>
        </thead>
        <tbody>
          {all === null && <tr><td colSpan={10}><Loading /></td></tr>}
          {all !== null && rows.length === 0 && (
            <tr><td colSpan={10}><div className="arwb-empty-state">No open insights for this week — every denial in it has been assigned or resolved.</div></td></tr>
          )}
          {rows.map((i) => (
            <tr key={i.denialInsightId}>
              <td><CodeLink code={i.denialCode} onClick={onCode} /></td>
              <td className="wrap">{i.denialDescription || '—'}</td>
              <td className="wrap">{i.denialCategory || '—'}{i.categoryTag && <div><Badge className="arwb-badge-info">{i.categoryTag}</Badge></div>}</td>
              <td className="num">{fmt.count(i.outstandingClaims)}<div className="arwb-hint">of {fmt.count(i.claimCountAtBuild)}</div></td>
              <td className="num mono">{fmt.money(i.outstandingBalance)}</td>
              <td className="wrap">{i.topPayer || '—'}{i.topPayerBalance ? <div className="arwb-hint">{fmt.money(i.topPayerBalance)}</div> : null}</td>
              <td className="num">{i.impactPct != null ? fmt.pct(i.impactPct) : '—'}</td>
              <td className="wrap">{i.observation || '—'}</td>
              <td className="wrap">{i.recommendedAction || '—'}</td>
              <td><button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={() => onRoute(i.denialCode)}>Route to Work Queue →</button></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// Master File Processor loads queued for the lab (LRNMaster dbo.MasterFileProcessorRerunRequest).
// Pending = queued for the worker's next poll, Claimed = the worker is running it; only the worker
// closes a request (Completed / Failed). Refreshes itself while anything is still in progress.
const LOAD_POLL_MS = 15000;
const isLoadOpen = (r) => r.status === 'Pending' || r.status === 'Claimed';

function loadStatus(r) {
  if (r.status === 'Pending') return ['Queued', 'arwb-badge-warning'];
  if (r.status === 'Claimed') return ['In progress', 'arwb-badge-info'];
  if (r.status === 'Failed' || r.resultStatus === 'FAILED') return ['Failed', 'arwb-badge-critical'];
  if (r.resultStatus === 'SKIPPED') return ['Skipped', 'arwb-badge-neutral'];
  return ['Completed', 'arwb-badge-good'];
}

function MasterFileLoads({ labId, version, onFinished }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [tab, setTab] = useState('progress');
  const openIds = useRef(null);

  const load = useCallback((signal) => {
    arWorkbenchService.masterFileRuns(labId, 25, signal)
      .then((d) => { setData(d); setError(''); })
      .catch((e) => { if (e.name !== 'AbortError') { setData((d) => d || { installed: true, runs: [] }); setError(e.message); } });
  }, [labId]);

  useEffect(() => {
    const ac = new AbortController();
    load(ac.signal);
    return () => ac.abort();
  }, [load, version]);

  const runs = data?.runs || [];
  const open = runs.filter(isLoadOpen);
  const done = runs.filter((r) => !isLoadOpen(r));
  const hasOpen = open.length > 0;

  // Poll only while a load is queued or running.
  useEffect(() => {
    if (!hasOpen) return undefined;
    const id = setInterval(() => load(), LOAD_POLL_MS);
    return () => clearInterval(id);
  }, [hasOpen, load]);

  // A load that just finished changed the lab's data: refresh the rest of the page once.
  useEffect(() => {
    if (!data) return;
    const ids = new Set(open.map((r) => r.requestId));
    const prev = openIds.current;
    openIds.current = ids;
    if (prev && [...prev].some((id) => !ids.has(id))) onFinished?.();
  }, [data]); // eslint-disable-line react-hooks/exhaustive-deps

  const rows = tab === 'progress' ? open : done;

  return (
    <div className="arwb-table-card arwb-section">
      <div className="arwb-panel-head">
        <h3>Master File Loads</h3>
        <span className="arwb-card-sub">
          Master File Processor runs for this lab: latest line-level and claim-level master files from SharePoint, denial data, then the AR Workbench sync
          {hasOpen ? ' · refreshing every 15 seconds' : ''}
        </span>
        <div className="arwb-panel-head-actions">
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => load()} title="Refresh">
            <Icon name="refresh" size={15} />
          </button>
        </div>
      </div>
      <div className="arwb-tabs arwb-tabs-flush" role="tablist">
        {[['progress', 'In Progress', open.length], ['completed', 'Completed', done.length]].map(([id, label, n]) => (
          <button key={id} type="button" role="tab" aria-selected={tab === id} className={`arwb-tab-btn ${tab === id ? 'active' : ''}`} onClick={() => setTab(id)}>
            {label}<Badge className={`arwb-tab-count ${id === 'progress' && n ? 'arwb-badge-info' : 'arwb-badge-neutral'}`}>{n}</Badge>
          </button>
        ))}
      </div>
      <ErrorBox message={error} />
      {data && !data.installed && (
        <div className="arwb-empty-state">
          The master file load queue is not installed in LRNMaster. Run <code>Database/LRN.MasterFileProcessorWorker/Create_RerunRequests.sql</code>.
        </div>
      )}
      {(!data || data.installed) && (
        <div className="arwb-table-wrap">
          <table className="arwb-data-table">
            <thead>
              <tr>
                <th scope="col">#</th><th scope="col">Status</th><th scope="col">Requested</th><th scope="col">By</th>
                <th scope="col">Started</th><th scope="col">{tab === 'progress' ? 'Worker' : 'Finished'}</th>
                <th scope="col">Run ID</th>{tab === 'progress' && <th scope="col">Note</th>}
              </tr>
            </thead>
            <tbody>
              {!data && <tr><td colSpan={tab === 'progress' ? 8 : 7}><Loading /></td></tr>}
              {data && rows.length === 0 && (
                <tr><td colSpan={tab === 'progress' ? 8 : 7}><div className="arwb-empty-state">
                  {tab === 'progress' ? 'No master file load is queued or running. Use Run Master File Load to start one.' : 'No completed master file loads yet.'}
                </div></td></tr>
              )}
              {rows.map((r) => {
                const [label, cls] = loadStatus(r);
                return (
                  <tr key={r.requestId}>
                    <td>{r.requestId}</td>
                    <td>
                      {/* Completed tab has no Result column: a failure's reason and any note stay on the status tooltip. */}
                      <span title={tab === 'progress' ? undefined : [r.resultMessage, r.note && `Note: ${r.note}`].filter(Boolean).join('\n') || undefined}>
                        <Badge className={cls}>{r.status === 'Claimed' && <span className="arwb-spinner" />} {label}</Badge>
                      </span>
                      {r.requestedFromApp && r.requestedFromApp !== 'LRN.ARWorkbench' && <div className="arwb-hint">from {r.requestedFromApp}</div>}
                    </td>
                    <td>{fmt.dateTime(r.requestedOn)}</td>
                    <td>{r.requestedBy || '—'}</td>
                    <td>{r.claimedOn ? fmt.dateTime(r.claimedOn) : <span className="arwb-hint">waiting for the next poll</span>}</td>
                    <td>{tab === 'progress' ? (r.claimedByHost || '—') : fmt.dateTime(r.completedOn)}</td>
                    <td className="mono">{r.runId || '—'}</td>
                    {tab === 'progress' && <td className="wrap">{r.note || '—'}</td>}
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function RunHistory({ runs: all }) {
  const { rows: runs, th } = useTableSort(all, {
    id: (r) => r.refreshRunId, status: (r) => r.runStatus, started: (r) => r.startedOn, by: (r) => r.runBy, file: (r) => r.sourceFileName || r.sourceRunId,
    claims: (r) => r.sourceClaimRows, inserted: (r) => r.claimsInserted, updated: (r) => r.claimsUpdated, unchanged: (r) => r.claimsUnchanged,
    dropped: (r) => r.claimsNoLongerInSource, lines: (r) => r.claimsLinesReloaded
  });
  return (
        <div className="arwb-table-card">
          <div className="arwb-table-toolbar"><h3 className="arwb-section-title" style={{ margin: 0 }}>Run history</h3></div>
          <div className="arwb-table-wrap">
            <table className="arwb-data-table">
              <thead>
                <tr>
                  {th('id', '#')}{th('status', 'Status')}{th('started', 'Started')}{th('by', 'By')}{th('file', 'Source file')}
                  {th('claims', 'Claims', { className: 'num' })}{th('inserted', 'New', { className: 'num' })}{th('updated', 'Updated', { className: 'num' })}
                  {th('unchanged', 'Unchanged', { className: 'num' })}{th('dropped', 'Dropped', { className: 'num' })}{th('lines', 'Lines reloaded', { className: 'num' })}
                </tr>
              </thead>
              <tbody>
                {runs.length === 0 && <tr><td colSpan={11}><div className="arwb-empty-state">No runs yet. Run data processing to load the lab's claims.</div></td></tr>}
                {runs.map((r) => (
                  <tr key={r.refreshRunId} title={r.errorMessage || ''}>
                    <td>{r.refreshRunId}</td>
                    <td><Badge className={runStatusBadgeClass(r.runStatus)}>{r.runStatus}</Badge></td>
                    <td>{fmt.dateTime(r.startedOn)}</td>
                    <td>{r.runBy}</td>
                    <td className="wrap">{r.errorMessage ? <span className="text-critical">{r.errorMessage}</span> : (r.sourceFileName || r.sourceRunId || '—')}</td>
                    <td className="num">{fmt.count(r.sourceClaimRows)}</td>
                    <td className="num">{fmt.count(r.claimsInserted)}</td>
                    <td className="num">{fmt.count(r.claimsUpdated)}</td>
                    <td className="num">{fmt.count(r.claimsUnchanged)}</td>
                    <td className="num">{fmt.count(r.claimsNoLongerInSource)}</td>
                    <td className="num">{fmt.count(r.claimsLinesReloaded)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
  );
}

// A denial code as a link to its claims on the Work Queue.
function CodeLink({ code, onClick }) {
  return (
    <button type="button" className="arwb-code-link" onClick={() => onClick(code)} title={`Open the claims with denial ${code} in the Work Queue`}>
      {code}
    </button>
  );
}

// The team's Key Observations as uploaded in LRN Metrics (Denial Claim Report), in their own order
// and columns, plus a live "still open" count and the Route to Work Queue action.
function UploadedInsightTable({ rows: all, onCode, onRoute }) {
  const impactNumber = (r) => { const n = parseFloat(String(r.impact || '').replace(/[%,]/g, '')); return Number.isNaN(n) ? null : n; };
  const { rows, th } = useTableSort(all, {
    order: (r) => r.sortOrder, code: (r) => r.denialCode, description: (r) => r.description, denials: (r) => r.noOfDenials, total: (r) => r.totalBalance,
    payer: (r) => r.payerName, insDenials: (r) => r.insuranceNoOfDenials, insBalance: (r) => r.insuranceBalance, impact: impactNumber,
    category: (r) => r.actionCategory, open: (r) => r.openClaims
  }, { key: 'order', desc: false });
  return (
    <div className="arwb-table-wrap">
      <table className="arwb-data-table arwb-uploaded-insights">
        <thead>
          <tr>
            {th('order', '#', { className: 'num' })}{th('code', 'Denial Code')}{th('description', 'Description')}
            {th('denials', '# of Denials', { className: 'num' })}{th('total', 'Total Balance', { className: 'num' })}
            {th('payer', 'Highest Impact Insurance')}{th('insDenials', 'Ins. # of Denials', { className: 'num' })}{th('insBalance', 'Ins. Balance', { className: 'num' })}
            {th('impact', '$ Impact', { className: 'num' })}
            <th scope="col">Observation</th>{th('category', 'Category')}<th scope="col">Action</th>
            {th('open', 'Still Open', { className: 'num' })}<th />
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.id}>
              <td className="num">{all.indexOf(r) + 1}</td>
              <td><CodeLink code={r.denialCode} onClick={onCode} /></td>
              <td className="wrap">{r.description || '—'}</td>
              <td className="num">{fmt.count(r.noOfDenials)}</td>
              <td className="num mono">{fmt.money(r.totalBalance)}</td>
              <td className="wrap">{r.payerName || '—'}</td>
              <td className="num">{fmt.count(r.insuranceNoOfDenials)}</td>
              <td className="num mono">{fmt.money(r.insuranceBalance)}</td>
              <td className="num">{r.impact || '—'}</td>
              <td className="wrap arwb-pre-line">{r.observation || '—'}</td>
              <td className="wrap">{r.actionCategory ? <Badge className="arwb-badge-info">{r.actionCategory}</Badge> : '—'}</td>
              <td className="wrap arwb-pre-line">{r.action || '—'}</td>
              <td className="num">
                {fmt.count(r.openClaims)}
                <div className="arwb-hint mono">{fmt.money(r.openBalance)}</div>
              </td>
              <td>
                <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!r.openClaims}
                  title={r.openClaims ? undefined : 'No unassigned claims with an open balance for this code'} onClick={() => onRoute(r.denialCode)}>
                  Route to Work Queue →
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// T038: the nightly queue snapshots (one per day per lab) - the base for trend and movement reports.
function SnapshotHistory({ labId }) {
  const [days, setDays] = useState(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');

  const load = useCallback(() => {
    arWorkbenchService.snapshots(labId, 14).then(setDays).catch((e) => { setDays([]); setError(e.message); });
  }, [labId]);
  useEffect(() => { load(); }, [load]);
  const { rows: sortedDays, th } = useTableSort(days || [], {
    date: (d) => d.snapshotDate, claims: (d) => d.claims, open: (d) => d.openClaims, assigned: (d) => d.assignedClaims, remaining: (d) => d.remainingAR
  });

  async function runNow() {
    setBusy(true);
    setError('');
    setMessage('');
    try {
      const r = await arWorkbenchService.runSnapshot(labId);
      setMessage(r.message);
      load();
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="arwb-table-card arwb-section">
      <div className="arwb-panel-head">
        <h3>Nightly Queue Snapshots</h3>
        <span className="arwb-card-sub">taken automatically every night after aging / TFL / re-follow-up are recalculated · used for trend and movement reporting</span>
        <div className="arwb-panel-head-actions">
          <button type="button" className="arwb-btn arwb-btn-sm" disabled={busy} onClick={runNow} title="Recalculate every claim and take today's snapshot now">
            {busy ? <><span className="arwb-spinner" /> Taking snapshot…</> : <><Icon name="refresh" size={15} /> Take snapshot now</>}
          </button>
        </div>
      </div>
      <ErrorBox message={error} />
      {message && <div className="arwb-hint" style={{ padding: '8px 16px' }}>{message}</div>}
      <div className="arwb-table-wrap">
        <table className="arwb-data-table">
          <thead>
            <tr>
              {th('date', 'Date')}{th('claims', 'Claims', { className: 'num' })}{th('open', 'Open (insurance AR)', { className: 'num' })}
              {th('assigned', 'Assigned', { className: 'num' })}{th('remaining', 'Remaining AR', { className: 'num' })}
            </tr>
          </thead>
          <tbody>
            {days === null && <tr><td colSpan={5}><Loading /></td></tr>}
            {days?.length === 0 && <tr><td colSpan={5}><div className="arwb-empty-state">No snapshots yet. The first one is taken tonight, or use Take snapshot now.</div></td></tr>}
            {sortedDays.map((d) => (
              <tr key={d.snapshotDate}>
                <td>{fmt.date(d.snapshotDate)}</td>
                <td className="num">{fmt.count(d.claims)}</td>
                <td className="num">{fmt.count(d.openClaims)}</td>
                <td className="num">{fmt.count(d.assignedClaims)}</td>
                <td className="num mono">{fmt.money(d.remainingAR)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function Stat({ label, value }) {
  return (
    <div className="arwb-kpi arwb-kpi-tile">
      <div className="arwb-kpi-accent-bar" />
      <div className="arwb-kpi-label">{label}</div>
      <div className="arwb-kpi-value arwb-kpi-value-sm">{value}</div>
    </div>
  );
}
