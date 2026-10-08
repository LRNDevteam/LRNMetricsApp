import { useCallback, useEffect, useState } from 'react';
import Icon from '../components/Icon';
import Modal from '../components/Modal';
import useTableSort from '../components/useTableSort';
import { ErrorBox, Loading, Notice, PageHeader } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

// Timely-filing limits per financial class (dbo.ARWB_TflThreshold), the default for classes with
// no row (AppSetting TflDefaultDays) and the at-risk window (TflRiskWindowDays). Every save
// re-derives each claim's TFL deadline and risk flag on the server.

export default function TflSettingsPage() {
  const { labId, lab } = useWorkbench();
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState(null);
  const [editor, setEditor] = useState(null);           // { original, financialClass, thresholdDays }
  const [confirmDelete, setConfirmDelete] = useState(null);
  const [defaults, setDefaults] = useState({ defaultDays: '', riskWindowDays: '' });
  const [busy, setBusy] = useState(false);
  const [dialogError, setDialogError] = useState('');

  const load = useCallback(async () => {
    setError('');
    try {
      const d = await arWorkbenchService.tflSettings(labId);
      setData(d);
      setDefaults({ defaultDays: String(d.defaultDays), riskWindowDays: String(d.riskWindowDays) });
    } catch (e) {
      setError(e.message || 'Timely-filing limits could not be loaded.');
    }
  }, [labId]);

  useEffect(() => { load(); }, [load]);
  const limits = useTableSort(data?.thresholds || [], { cls: (t) => t.financialClass, days: (t) => t.thresholdDays, claims: (t) => t.claimCount });
  const unmapped = useTableSort(data?.unmappedClasses || [], { cls: (u) => u.financialClass, claims: (u) => u.claimCount });

  async function run(action, fallback) {
    setBusy(true);
    setDialogError('');
    try {
      const r = await action();
      setEditor(null);
      setConfirmDelete(null);
      setNotice({ kind: 'good', text: r?.message || fallback });
      await load();
    } catch (e) {
      if (editor || confirmDelete) setDialogError(e.message); else setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  function saveThreshold() {
    const days = Number(editor.thresholdDays);
    if (!editor.financialClass.trim()) { setDialogError('Financial class is required.'); return; }
    if (!Number.isInteger(days) || days < 1 || days > 3650) { setDialogError('Days must be a whole number from 1 to 3,650.'); return; }
    const body = { originalFinancialClass: editor.original, financialClass: editor.financialClass.trim(), thresholdDays: days };
    run(() => (editor.original ? arWorkbenchService.updateTflThreshold(labId, body) : arWorkbenchService.addTflThreshold(labId, body)), 'Saved.');
  }

  function saveDefaults() {
    const d = Number(defaults.defaultDays);
    const w = Number(defaults.riskWindowDays);
    if (!Number.isInteger(d) || d < 1 || d > 3650) { setError('Default limit must be a whole number from 1 to 3,650 days.'); return; }
    if (!Number.isInteger(w) || w < 0 || w > 365) { setError('Risk window must be a whole number from 0 to 365 days.'); return; }
    run(() => arWorkbenchService.saveTflDefaults(labId, { defaultDays: d, riskWindowDays: w }), 'Saved.');
  }

  if (!data && !error) return <Loading text="Loading timely-filing limits…" />;

  return (
    <>
      <PageHeader note={`Timely-filing limits for ${lab?.labName || 'this lab'}. A claim's TFL deadline is its date of service plus its financial class's limit; open claims inside the risk window are flagged TFL at risk.`}>
        <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={busy}
          onClick={() => { setDialogError(''); setEditor({ original: null, financialClass: '', thresholdDays: '' }); }}>
          <Icon name="plus" size={15} /> Add limit
        </button>
      </PageHeader>
      <Notice notice={notice} onClose={() => setNotice(null)} />
      <ErrorBox message={error} />

      {data && (
        <>
          <div className="arwb-card arwb-section">
            <div className="arwb-form-grid" style={{ maxWidth: 640 }}>
              <div className="arwb-field">
                <label htmlFor="tfl-default">Default limit (days)</label>
                <input id="tfl-default" type="number" min="1" max="3650" className="arwb-input" value={defaults.defaultDays}
                  onChange={(e) => setDefaults((x) => ({ ...x, defaultDays: e.target.value }))} />
                <div className="arwb-field-note">For financial classes with no row below.</div>
              </div>
              <div className="arwb-field">
                <label htmlFor="tfl-window">TFL risk window (days)</label>
                <input id="tfl-window" type="number" min="0" max="365" className="arwb-input" value={defaults.riskWindowDays}
                  onChange={(e) => setDefaults((x) => ({ ...x, riskWindowDays: e.target.value }))} />
                <div className="arwb-field-note">Open claims this close to their deadline are TFL at risk.</div>
              </div>
            </div>
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" style={{ marginTop: 10 }} disabled={busy} onClick={saveDefaults}>
              {busy ? <span className="arwb-spinner" /> : null} Save defaults
            </button>
          </div>

          <div className="arwb-table-card arwb-section">
            <div className="arwb-panel-head"><h3>Limits by financial class</h3><span className="arwb-card-sub">matched to the claim's financial class (payer type) exactly</span></div>
            <div className="arwb-table-wrap">
              <table className="arwb-data-table">
                <thead><tr>{limits.th('cls', 'Financial Class')}{limits.th('days', 'Limit (days)', { className: 'num' })}{limits.th('claims', 'Claims', { className: 'num' })}<th /></tr></thead>
                <tbody>
                  {limits.rows.map((t) => (
                    <tr key={t.financialClass}>
                      <td>{t.financialClass}</td>
                      <td className="num">{fmt.count(t.thresholdDays)}</td>
                      <td className="num">{fmt.count(t.claimCount)}</td>
                      <td>
                        <div className="arwb-row-actions">
                          <button type="button" className="arwb-icon-btn" title="Edit" disabled={busy}
                            onClick={() => { setDialogError(''); setEditor({ original: t.financialClass, financialClass: t.financialClass, thresholdDays: String(t.thresholdDays) }); }}>
                            <Icon name="edit" size={15} />
                          </button>
                          <button type="button" className="arwb-icon-btn danger" title="Delete" disabled={busy}
                            onClick={() => { setDialogError(''); setConfirmDelete(t); }}>
                            <Icon name="trash" size={15} />
                          </button>
                        </div>
                      </td>
                    </tr>
                  ))}
                  {!data.thresholds.length && <tr><td colSpan={4}><div className="arwb-empty-state">No limits yet — every claim uses the default.</div></td></tr>}
                </tbody>
              </table>
            </div>
          </div>

          {data.unmappedClasses.length > 0 && (
            <div className="arwb-table-card">
              <div className="arwb-panel-head"><h3>Financial classes using the default</h3><span className="arwb-card-sub">on synced claims, with no limit of their own</span></div>
              <div className="arwb-table-wrap">
                <table className="arwb-data-table">
                  <thead><tr>{unmapped.th('cls', 'Financial Class')}{unmapped.th('claims', 'Claims', { className: 'num' })}<th /></tr></thead>
                  <tbody>
                    {unmapped.rows.map((u) => (
                      <tr key={u.financialClass}>
                        <td>{u.financialClass}</td>
                        <td className="num">{fmt.count(u.claimCount)}</td>
                        <td><button type="button" className="arwb-btn arwb-btn-sm" disabled={busy}
                          onClick={() => { setDialogError(''); setEditor({ original: null, financialClass: u.financialClass, thresholdDays: String(data.defaultDays) }); }}>
                          <Icon name="plus" size={14} /> Set limit
                        </button></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </>
      )}

      {editor && (
        <Modal title={editor.original ? `Edit ${editor.original}` : 'Add timely-filing limit'} submitLabel="Save" busy={busy}
          onClose={() => setEditor(null)} onSubmit={saveThreshold}>
          <ErrorBox message={dialogError} />
          <div className="arwb-field">
            <label htmlFor="tfl-class">Financial class *</label>
            <input id="tfl-class" className="arwb-input" maxLength={200} value={editor.financialClass}
              onChange={(e) => setEditor((x) => ({ ...x, financialClass: e.target.value }))} />
            <div className="arwb-field-note">Must match the claim's financial class (payer type) exactly, e.g. "MC - MEDICARE".</div>
          </div>
          <div className="arwb-field">
            <label htmlFor="tfl-days">Limit (days) *</label>
            <input id="tfl-days" type="number" min="1" max="3650" className="arwb-input" value={editor.thresholdDays}
              onChange={(e) => setEditor((x) => ({ ...x, thresholdDays: e.target.value }))} />
          </div>
        </Modal>
      )}

      {confirmDelete && (
        <Modal title={`Remove the limit for ${confirmDelete.financialClass}?`} submitLabel="Remove" submitClass="arwb-btn-danger" busy={busy}
          onClose={() => setConfirmDelete(null)} onSubmit={() => run(() => arWorkbenchService.deleteTflThreshold(labId, confirmDelete.financialClass), 'Removed.')}>
          <ErrorBox message={dialogError} />
          <p>Its {fmt.count(confirmDelete.claimCount)} claims will use the default limit of {fmt.count(data.defaultDays)} days. TFL deadlines are recalculated straight away.</p>
        </Modal>
      )}
    </>
  );
}
