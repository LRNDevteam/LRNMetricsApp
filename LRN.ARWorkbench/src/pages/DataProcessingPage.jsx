import { useCallback, useEffect, useState } from 'react';
import Icon from '../components/Icon';
import { Badge, ErrorBox, Loading, PageHeader } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt, runStatusBadgeClass } from '../utils/format';

export default function DataProcessingPage() {
  const { labId, lab } = useWorkbench();
  const [runs, setRuns] = useState(null);
  const [error, setError] = useState('');
  const [running, setRunning] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [note, setNote] = useState('');

  const load = useCallback(() => {
    setError('');
    arWorkbenchService.refreshRuns(labId, 15).then(setRuns).catch((e) => setError(e.message));
  }, [labId]);

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

function Stat({ label, value }) {
  return (
    <div className="arwb-kpi arwb-kpi-tile">
      <div className="arwb-kpi-accent-bar" />
      <div className="arwb-kpi-label">{label}</div>
      <div className="arwb-kpi-value arwb-kpi-value-sm">{value}</div>
    </div>
  );
}
