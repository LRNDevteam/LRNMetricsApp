import { useCallback, useEffect, useState } from 'react';
import Modal from '../components/Modal';
import { Badge, ErrorBox, Loading, Notice } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

// Client Management (mockup App.views.clients): one card per client (lab) with its eligible claims,
// outstanding AR and recovered amount, and Deactivate / Reactivate. A deactivated client is hidden
// from non-admins and skipped by the nightly snapshot; its claims and history are kept.

export default function ClientsPage() {
  const { labId, user, can } = useWorkbench();
  const canToggle = user?.siteAdmin || can('manageSettings');
  const [cards, setCards] = useState(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState(null);
  const [toggling, setToggling] = useState(null);     // card
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [dialogError, setDialogError] = useState('');

  const load = useCallback(() => {
    setError('');
    return arWorkbenchService.clients(labId).then(setCards).catch((e) => setError(e.message));
  }, [labId]);
  useEffect(() => { load(); }, [load]);

  async function save() {
    const activate = !toggling.isActive;
    if (!activate && !note.trim()) { setDialogError('Add a reason for deactivating the client.'); return; }
    setBusy(true);
    setDialogError('');
    try {
      const r = await arWorkbenchService.setClientActive(labId, toggling.labId, activate, note.trim() || null);
      setNotice({ kind: 'good', text: `${toggling.labName}: ${r.message}` });
      setToggling(null);
      await load();
    } catch (e) {
      setDialogError(e.message);
    } finally {
      setBusy(false);
    }
  }

  if (!cards && !error) return <Loading text="Loading clients…" />;

  return (
    <>
      <Notice notice={notice} onClose={() => setNotice(null)} />
      <ErrorBox message={error} onRetry={load} />
      <div className="arwb-client-grid">
        {(cards || []).map((c) => (
          <div key={c.labId} className={`arwb-card arwb-client-card${c.isActive ? '' : ' inactive'}`}>
            <div className="arwb-flex-between">
              <h3 style={{ margin: 0 }}>{c.labName}</h3>
              <Badge className={c.isActive ? 'arwb-badge-good' : 'arwb-badge-neutral'}>{c.isActive ? 'Active' : 'Inactive'}</Badge>
            </div>
            {c.stats ? (
              <>
                <div className="arwb-hint">{fmt.count(c.stats.eligibleClaims)} eligible claims in the current workflow · {fmt.count(c.stats.claimsInSource)} in the latest source file</div>
                <div className="arwb-client-stats">
                  <div><span className="arwb-kpi-label">Outstanding AR</span><span className="mono">{fmt.money(c.stats.outstandingAR)}</span></div>
                  <div><span className="arwb-kpi-label">Recovered</span><span className="mono">{fmt.money(c.stats.recovered)}</span></div>
                  <div><span className="arwb-kpi-label">Assigned</span><span className="mono">{fmt.count(c.stats.assignedClaims)}</span></div>
                  <div><span className="arwb-kpi-label">Awaiting QA</span><span className="mono">{fmt.count(c.stats.awaitingQa)}</span></div>
                </div>
                <div className="arwb-hint">Last data refresh: {c.stats.lastRefreshOn ? fmt.dateTime(c.stats.lastRefreshOn) : 'never'}</div>
              </>
            ) : <div className="arwb-hint">The AR Workbench is not set up for this lab yet (run the lab setup scripts, then Data Processing).</div>}
            {!c.isActive && c.statusNote && <div className="arwb-hint">Deactivated by {c.changedBy} on {fmt.date(c.changedOn)}: {c.statusNote}</div>}
            {canToggle && (
              <button type="button" className={`arwb-btn arwb-btn-sm${c.isActive ? '' : ' arwb-btn-primary'}`} style={{ marginTop: 'auto' }}
                onClick={() => { setNote(''); setDialogError(''); setToggling(c); }}>
                {c.isActive ? 'Deactivate Client' : 'Reactivate Client'}
              </button>
            )}
          </div>
        ))}
        {cards?.length === 0 && <div className="arwb-empty-state">No AR Workbench clients are assigned to you.</div>}
      </div>

      {toggling && (
        <Modal title={`${toggling.isActive ? 'Deactivate' : 'Reactivate'} ${toggling.labName}`} busy={busy}
          submitLabel={toggling.isActive ? 'Deactivate' : 'Reactivate'} submitClass={toggling.isActive ? 'arwb-btn-danger' : 'arwb-btn-primary'}
          onClose={() => setToggling(null)} onSubmit={save}>
          <ErrorBox message={dialogError} />
          <p>
            {toggling.isActive
              ? 'Agents, leads, QA and client users lose access to this client in the AR Workbench and the nightly snapshot stops. Claims, assignments and history are kept; administrators can still open it and reactivate it.'
              : 'Everyone with access to this client can use it in the AR Workbench again, and the nightly snapshot resumes.'}
          </p>
          <div className="arwb-field">
            <label htmlFor="cl-note">{toggling.isActive ? 'Reason (required)' : 'Note (optional)'}</label>
            <textarea id="cl-note" className="arwb-input" rows={3} maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} />
          </div>
        </Modal>
      )}
    </>
  );
}
