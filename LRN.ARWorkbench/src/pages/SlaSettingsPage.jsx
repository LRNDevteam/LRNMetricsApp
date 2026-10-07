import { useCallback, useEffect, useState } from 'react';
import { ErrorBox, Loading, Notice, PageHeader } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

// Operational SLA targets (ARWB_AppSetting Sla*Days) that Reports > Operational SLA (RPT-09)
// measures every milestone against. They ship as drafts; ticking "confirmed" drops the DRAFT
// label from the report.

export default function SlaSettingsPage() {
  const { labId, lab } = useWorkbench();
  const [data, setData] = useState(null);
  const [days, setDays] = useState({});
  const [confirmed, setConfirmed] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setError('');
    try {
      const d = await arWorkbenchService.slaSettings(labId);
      setData(d);
      setDays(Object.fromEntries(d.targets.map((t) => [t.key, String(t.days)])));
      setConfirmed(d.confirmed);
    } catch (e) {
      setError(e.message || 'SLA targets could not be loaded.');
    }
  }, [labId]);

  useEffect(() => { load(); }, [load]);

  async function save() {
    const targets = {};
    for (const t of data.targets) {
      const n = Number(days[t.key]);
      if (days[t.key] === '' || !Number.isInteger(n) || n < 0 || n > 365) { setError(`"${t.label}" must be a whole number from 0 to 365 days.`); return; }
      targets[t.key] = n;
    }
    setBusy(true);
    setError('');
    try {
      const r = await arWorkbenchService.saveSlaSettings(labId, { targets, confirmed });
      setNotice({ kind: 'good', text: r?.message || 'Saved.' });
      await load();
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  if (!data && !error) return <Loading text="Loading SLA targets…" />;

  return (
    <>
      <PageHeader note={`Operational SLA targets for ${lab?.labName || 'this lab'}, in calendar days. Reports > Operational SLA (RPT-09) measures each milestone against them.`} />
      <Notice notice={notice} onClose={() => setNotice(null)} />
      <ErrorBox message={error} />

      {data && (
        <div className="arwb-card arwb-section">
          {!data.confirmed && (
            <div className="arwb-section-note" style={{ marginBottom: 12 }}>
              <b>Draft targets.</b> These are placeholders until the team agrees them. The Operational SLA report labels them as drafts until you tick “Targets confirmed”.
            </div>
          )}
          <div className="arwb-table-wrap">
            <table className="arwb-data-table">
              <thead><tr><th scope="col">Milestone</th><th scope="col">Measured as</th><th scope="col" className="num">Target (days)</th></tr></thead>
              <tbody>
                {data.targets.map((t) => (
                  <tr key={t.key}>
                    <td><label htmlFor={`sla-${t.key}`}>{t.label}</label></td>
                    <td className="wrap arwb-hint">{t.description}</td>
                    <td className="num">
                      <input id={`sla-${t.key}`} type="number" min="0" max="365" className="arwb-input" style={{ width: 96, marginLeft: 'auto' }}
                        value={days[t.key] ?? ''} onChange={(e) => setDays((x) => ({ ...x, [t.key]: e.target.value }))} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <label className="arwb-check" style={{ display: 'flex', gap: 8, alignItems: 'center', marginTop: 12 }}>
            <input type="checkbox" checked={confirmed} onChange={(e) => setConfirmed(e.target.checked)} /> Targets confirmed by the team
          </label>
          <div style={{ display: 'flex', gap: 12, alignItems: 'center', marginTop: 10 }}>
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={busy} onClick={save}>
              {busy ? <span className="arwb-spinner" /> : null} Save targets
            </button>
            {data.updatedOn && <span className="arwb-hint">Last saved {fmt.dateTime(data.updatedOn)}{data.updatedBy ? ` by ${data.updatedBy}` : ''}</span>}
          </div>
        </div>
      )}
    </>
  );
}
