import { useCallback, useEffect, useState } from 'react';
import { ErrorBox, Loading, PageHeader } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

function RunStatus({ status }) {
  const cls = { Succeeded: 'text-bg-success', Failed: 'text-bg-danger', Running: 'text-bg-warning' }[status] || 'text-bg-secondary';
  return <span className={`badge ${cls}`}>{status}</span>;
}

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
      <PageHeader note={`Load denied claims for ${lab?.labName || 'this lab'} from claim-level and line-level data`}>
        <button type="button" className="btn btn-primary btn-sm" disabled={running} onClick={() => setConfirming(true)}>
          {running ? <><span className="spinner-border spinner-border-sm me-2" />Processing…</> : <><i className="bi bi-arrow-repeat me-1" />Run data processing</>}
        </button>
      </PageHeader>

      {confirming && (
        <div className="arwb-card mb-3 border-primary">
          <p className="mb-2">
            This copies every claim in <code>dbo.ClaimLevelData</code> with a denial code into the workbench, loads its CPT lines from
            <code> dbo.LineLevelData</code>, and recalculates queues. Workflow state (assignments, follow-ups, QA, CIP) is kept.
            A large lab can take a few minutes.
          </p>
          <input className="form-control form-control-sm mb-2" placeholder="Optional note for the run log" value={note} maxLength={1000} onChange={(e) => setNote(e.target.value)} />
          <div className="d-flex gap-2">
            <button type="button" className="btn btn-primary btn-sm" onClick={run}>Run now</button>
            <button type="button" className="btn btn-outline-secondary btn-sm" onClick={() => setConfirming(false)}>Cancel</button>
          </div>
        </div>
      )}

      <ErrorBox message={error} />

      {last && (
        <div className="row g-3 mb-4">
          <Stat label="Last refresh" value={fmt.dateTime(last.completedOn)} />
          <Stat label="Source period" value={`${fmt.date(last.sourcePeriodStart)} – ${fmt.date(last.sourcePeriodEnd)}`} />
          <Stat label="Denied claims in source" value={fmt.count(last.sourceClaimRows)} />
          <Stat label="CPT lines read" value={fmt.count(last.sourceLineRows)} />
        </div>
      )}

      {!runs ? <Loading /> : (
        <div className="arwb-table-card">
          <div className="arwb-table-toolbar"><h2 className="h6 mb-0">Run history</h2></div>
          <div className="table-responsive">
            <table className="table table-sm align-middle mb-0 arwb-table">
              <thead>
                <tr>
                  <th>#</th><th>Status</th><th>Started</th><th>By</th><th>Source file</th>
                  <th className="text-end">Claims</th><th className="text-end">New</th><th className="text-end">Updated</th>
                  <th className="text-end">Unchanged</th><th className="text-end">Dropped</th><th className="text-end">Lines reloaded</th>
                </tr>
              </thead>
              <tbody>
                {runs.length === 0 && <tr><td colSpan={11} className="text-center text-secondary py-4">No runs yet. Run data processing to load the first set of denied claims.</td></tr>}
                {runs.map((r) => (
                  <tr key={r.refreshRunId} title={r.errorMessage || ''}>
                    <td>{r.refreshRunId}</td>
                    <td><RunStatus status={r.runStatus} /></td>
                    <td className="text-nowrap">{fmt.dateTime(r.startedOn)}</td>
                    <td>{r.runBy}</td>
                    <td className="small">{r.errorMessage ? <span className="text-danger">{r.errorMessage}</span> : (r.sourceFileName || r.sourceRunId || '—')}</td>
                    <td className="text-end">{fmt.count(r.sourceClaimRows)}</td>
                    <td className="text-end">{fmt.count(r.claimsInserted)}</td>
                    <td className="text-end">{fmt.count(r.claimsUpdated)}</td>
                    <td className="text-end">{fmt.count(r.claimsUnchanged)}</td>
                    <td className="text-end">{fmt.count(r.claimsNoLongerInSource)}</td>
                    <td className="text-end">{fmt.count(r.claimsLinesReloaded)}</td>
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
    <div className="col-6 col-lg-3">
      <div className="arwb-kpi">
        <div className="arwb-kpi-label">{label}</div>
        <div className="arwb-kpi-value arwb-kpi-value-sm">{value}</div>
      </div>
    </div>
  );
}
