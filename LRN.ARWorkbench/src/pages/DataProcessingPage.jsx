import { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router';
import Icon from '../components/Icon';
import { Badge, ErrorBox, Loading, PageHeader } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt, runStatusBadgeClass } from '../utils/format';

export default function DataProcessingPage() {
  const { labId, lab } = useWorkbench();
  const navigate = useNavigate();
  const [runs, setRuns] = useState(null);
  const [insights, setInsights] = useState(null);
  const [week, setWeek] = useState('current');
  const [error, setError] = useState('');
  const [running, setRunning] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [note, setNote] = useState('');

  const load = useCallback(() => {
    setError('');
    arWorkbenchService.refreshRuns(labId, 15).then(setRuns).catch((e) => setError(e.message));
    arWorkbenchService.insights(labId).then((r) => setInsights(r || [])).catch((e) => { setInsights([]); setError(e.message); });
  }, [labId]);

  // "Route to Work Queue": the code's claims that are still unassigned with an open balance.
  const route = (code) => navigate(`/work-queue?${new URLSearchParams({ q: code, status: 'Unassigned', open: '1' })}`);
  const weekRows = (insights || []).filter((i) => (week === 'current' ? i.isCurrentWeek : !i.isCurrentWeek));
  const weekStart = (current) => (insights || []).find((i) => i.isCurrentWeek === current)?.weekStart;

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

  const last = runs?.find((r) => r.runStatus === 'Succeeded');

  return (
    <>
      <PageHeader note={`Sync every claim and line for ${lab?.labName || 'this lab'} from the claim-level and line-level master files`}>
        <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={running} onClick={() => setConfirming(true)}>
          {running ? <><span className="arwb-spinner" /> Processing…</> : <><Icon name="refresh" size={15} /> Run Data Processing</>}
        </button>
      </PageHeader>

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

      {last && (
        <div className="arwb-grid arwb-grid-kpi arwb-section">
          <Stat label="Last refresh" value={fmt.dateTime(last.completedOn)} />
          <Stat label="Source period" value={`${fmt.date(last.sourcePeriodStart)} – ${fmt.date(last.sourcePeriodEnd)}`} />
          <Stat label="Claims in source" value={fmt.count(last.sourceClaimRows)} />
          <Stat label="CPT lines read" value={fmt.count(last.sourceLineRows)} />
        </div>
      )}

      <div className="arwb-table-card arwb-section">
        <div className="arwb-panel-head">
          <h3>Denial Analysis Report</h3>
          <span className="arwb-card-sub">insights from each sync week · counts are what is still unassigned with an open balance</span>
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
        <div className="arwb-table-wrap">
          <table className="arwb-data-table">
            <thead>
              <tr>
                <th>Denial Code</th><th>Description</th><th>Category</th><th className="num">Open Claims</th><th className="num">Open Balance</th>
                <th>Top Payer</th><th className="num">Impact</th><th>Observation</th><th>Recommended Action</th><th />
              </tr>
            </thead>
            <tbody>
              {insights === null && <tr><td colSpan={10}><Loading /></td></tr>}
              {insights !== null && weekRows.length === 0 && (
                <tr><td colSpan={10}><div className="arwb-empty-state">No open insights for this week — every denial in it has been assigned or resolved.</div></td></tr>
              )}
              {weekRows.map((i) => (
                <tr key={i.denialInsightId}>
                  <td><span className="arwb-code-chip">{i.denialCode}</span></td>
                  <td className="wrap">{i.denialDescription || '—'}</td>
                  <td className="wrap">{i.denialCategory || '—'}{i.categoryTag && <div><Badge className="arwb-badge-info">{i.categoryTag}</Badge></div>}</td>
                  <td className="num">{fmt.count(i.outstandingClaims)}<div className="arwb-hint">of {fmt.count(i.claimCountAtBuild)}</div></td>
                  <td className="num mono">{fmt.money(i.outstandingBalance)}</td>
                  <td className="wrap">{i.topPayer || '—'}{i.topPayerBalance ? <div className="arwb-hint">{fmt.money(i.topPayerBalance)}</div> : null}</td>
                  <td className="num">{i.impactPct != null ? fmt.pct(i.impactPct) : '—'}</td>
                  <td className="wrap">{i.observation || '—'}</td>
                  <td className="wrap">{i.recommendedAction || '—'}</td>
                  <td><button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={() => route(i.denialCode)}>Route to Work Queue →</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <SnapshotHistory labId={labId} />

      {!runs ? <Loading /> : (
        <div className="arwb-table-card">
          <div className="arwb-table-toolbar"><h3 className="arwb-section-title" style={{ margin: 0 }}>Run history</h3></div>
          <div className="arwb-table-wrap">
            <table className="arwb-data-table">
              <thead>
                <tr>
                  <th>#</th><th>Status</th><th>Started</th><th>By</th><th>Source file</th>
                  <th className="num">Claims</th><th className="num">New</th><th className="num">Updated</th>
                  <th className="num">Unchanged</th><th className="num">Dropped</th><th className="num">Lines reloaded</th>
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
      )}
    </>
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
          <thead><tr><th>Date</th><th className="num">Claims</th><th className="num">Open (insurance AR)</th><th className="num">Assigned</th><th className="num">Remaining AR</th></tr></thead>
          <tbody>
            {days === null && <tr><td colSpan={5}><Loading /></td></tr>}
            {days?.length === 0 && <tr><td colSpan={5}><div className="arwb-empty-state">No snapshots yet. The first one is taken tonight, or use Take snapshot now.</div></td></tr>}
            {days?.map((d) => (
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
