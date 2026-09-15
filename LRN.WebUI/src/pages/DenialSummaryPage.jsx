import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { money, canAssignRole } from '../utils/formatters';
import { denialWorkflowService } from '../services/denialWorkflowService';
import RichTextEditor from '../components/RichTextEditor';

const CLASSIFICATION = 'Classification';
const ACTION_CATEGORY = 'ActionCategory';
const SNAPSHOT_TABS = [
  { key: 'Weekly', label: 'Weekly' },
  { key: 'Monthly', label: 'Monthly' },
  { key: 'OnDemand', label: 'On demand' }
];

function getBilled(row) {
  return Number(row.billed ?? row.billedAmount ?? row.totalBilled ?? row.charges ?? row.outstanding ?? 0);
}

function getInsBalance(row) {
  return Number(row.insuranceBalance ?? row.insBalance ?? row.outstanding ?? 0);
}

const rowName = (value) => String(value || '').trim() || 'Unclassified';
const observationKey = (type, name) => `${type}|${rowName(name).toUpperCase()}`;
const pad = (n) => String(n).padStart(2, '0');

// Dates travel as "yyyy-MM-ddT00:00:00". They are calendar dates, so never pass them through
// new Date(): a UTC parse shows the previous day west of Greenwich.
const isoDate = (v) => (v ? String(v).slice(0, 10) : '');
function displayDate(v) {
  const s = isoDate(v);
  if (!s) return '';
  const [y, m, d] = s.split('-');
  return `${m}/${d}/${y}`;
}
function todayIso() {
  const n = new Date();
  return `${n.getFullYear()}-${pad(n.getMonth() + 1)}-${pad(n.getDate())}`;
}

// Mirrors DenialSummarySchedule.ObservationStatus in the API so the page and the snapshot agree.
export function observationStatus(obs, today = todayIso()) {
  if (!obs) return '';
  if (isoDate(obs.completedDate)) return 'Completed';
  if (isoDate(obs.targetDate) && isoDate(obs.targetDate) < today) return 'Overdue';
  if (isoDate(obs.followUpDate) && isoDate(obs.followUpDate) <= today) return 'Follow-up Due';
  return obs.observationHtml || obs.responsiblePerson || isoDate(obs.targetDate) || isoDate(obs.followUpDate) ? 'Open' : '';
}

const statusClass = (status) => ({
  Completed: 'done',
  Overdue: 'overdue',
  'Follow-up Due': 'due',
  Open: 'open'
}[status] || '');

function SummaryProgress({ value, max }) {
  const width = max > 0 ? Math.min(100, Math.max(3, (Number(value || 0) / max) * 100)) : 0;
  return <span className="summary-mini-progress"><span style={{ width: `${width}%` }} /></span>;
}

function ObservationCell({ observation, canEdit, onOpen }) {
  const status = observationStatus(observation);
  if (!status) {
    return canEdit
      ? <button type="button" className="obs-add" onClick={onOpen}><i className="bi bi-plus-circle" /> Add</button>
      : <span className="obs-empty">—</span>;
  }
  const due = isoDate(observation.completedDate)
    ? `Done ${displayDate(observation.completedDate)}`
    : isoDate(observation.targetDate) ? `Due ${displayDate(observation.targetDate)}` : '';
  return (
    <button type="button" className="obs-cell" onClick={onOpen} title={canEdit ? 'View or edit observation' : 'View observation'}>
      <span className={`obs-pill ${statusClass(status)}`}>{status}</span>
      {observation.responsiblePerson && <span className="obs-person">{observation.responsiblePerson}</span>}
      {due && <span className="obs-due">{due}</span>}
    </button>
  );
}

function ObservationModal({ target, canEdit, saving, onClose, onSave }) {
  const existing = target.observation;
  const [form, setForm] = useState(() => ({
    observationHtml: existing?.observationHtml || '',
    responsiblePerson: existing?.responsiblePerson || '',
    observationDate: isoDate(existing?.observationDate) || (existing ? '' : todayIso()),
    targetDate: isoDate(existing?.targetDate),
    followUpDate: isoDate(existing?.followUpDate),
    completedDate: isoDate(existing?.completedDate)
  }));
  const set = (field) => (e) => setForm(f => ({ ...f, [field]: e.target.value }));
  const dateError = form.observationDate && form.completedDate && form.completedDate < form.observationDate
    ? 'Completed Date cannot be before the Observation Date.' : '';

  function submit(e) {
    e.preventDefault();
    if (!canEdit || dateError) return;
    onSave({
      summaryType: target.summaryType,
      summaryKey: target.name,
      observationHtml: form.observationHtml,
      responsiblePerson: form.responsiblePerson,
      observationDate: form.observationDate || null,
      targetDate: form.targetDate || null,
      followUpDate: form.followUpDate || null,
      completedDate: form.completedDate || null,
      version: existing?.version || null
    });
  }

  const typeLabel = target.summaryType === CLASSIFICATION ? 'Denial classification' : 'Action / task';
  const updated = existing?.updatedOn || existing?.createdOn;

  return (
    <div className="modal-backdrop">
      <form className="dcm-modal obs-modal" onSubmit={submit}>
        <div className="claim-modal-header">
          <div>
            <div className="claim-modal-title">{target.name}</div>
            <small>{typeLabel} observation{updated ? ` · last updated ${displayDate(updated)} by ${existing.updatedBy || existing.createdBy || 'unknown'}` : ''}</small>
          </div>
          <button type="button" className="modal-close" onClick={onClose} disabled={saving}><i className="bi bi-x-lg" /></button>
        </div>
        <div className="obs-form">
          <label className="dcm-field obs-full">
            Observation
            {canEdit
              ? <RichTextEditor value={form.observationHtml} onChange={html => setForm(f => ({ ...f, observationHtml: html }))} placeholder="What is driving this row, and what is being done about it?" />
              // Server-sanitized on save and on read: formatting tags only, no attributes.
              : <div className="rte-readonly" dangerouslySetInnerHTML={{ __html: form.observationHtml || '<span class="obs-empty">No observation recorded.</span>' }} />}
          </label>
          <label className="dcm-field obs-full">
            Responsible Person
            <input type="text" maxLength={200} value={form.responsiblePerson} onChange={set('responsiblePerson')} disabled={!canEdit} placeholder="Name, team or payer contact" />
          </label>
          <label className="dcm-field">Observation Date<input type="date" value={form.observationDate} onChange={set('observationDate')} disabled={!canEdit} /></label>
          <label className="dcm-field">Target Date<input type="date" value={form.targetDate} onChange={set('targetDate')} disabled={!canEdit} /></label>
          <label className="dcm-field">Follow-up Date<input type="date" value={form.followUpDate} onChange={set('followUpDate')} disabled={!canEdit} /></label>
          <label className="dcm-field">Completed Date<input type="date" value={form.completedDate} min={form.observationDate || undefined} onChange={set('completedDate')} disabled={!canEdit} /></label>
          {dateError && <div className="obs-error obs-full">{dateError}</div>}
        </div>
        <div className="dcm-modal-actions">
          <button type="button" className="wl-btn" onClick={onClose} disabled={saving}>{canEdit ? 'Cancel' : 'Close'}</button>
          {canEdit && <button type="submit" className="wl-btn teal" disabled={saving || !!dateError}>{saving ? 'Saving...' : 'Save'}</button>}
        </div>
      </form>
    </div>
  );
}

function periodLabel(s) {
  if (s.periodType === 'Weekly') return `${displayDate(s.periodStart)} – ${displayDate(s.periodEnd)}`;
  if (s.periodType === 'Monthly') {
    const [y, m] = isoDate(s.periodStart).split('-');
    return new Date(Number(y), Number(m) - 1, 1).toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
  }
  return displayDate(s.periodStart);
}

function SnapshotPanel({ labId, canEdit, notify }) {
  const [tab, setTab] = useState('Weekly');
  const [showArchived, setShowArchived] = useState(false);
  const [snapshots, setSnapshots] = useState([]);
  const [loading, setLoading] = useState(false);
  const [taking, setTaking] = useState(false);
  const [downloadingId, setDownloadingId] = useState(null);

  const load = useCallback(async () => {
    if (!labId) return;
    setLoading(true);
    try {
      setSnapshots(await denialWorkflowService.getDenialSummarySnapshots(labId, showArchived) || []);
    } catch (err) {
      notify({ type: 'danger', text: err.message || 'Unable to load Denial Summary snapshots.' });
    } finally {
      setLoading(false);
    }
  }, [labId, showArchived, notify]);

  useEffect(() => { load(); }, [load]);

  async function takeSnapshot() {
    setTaking(true);
    try {
      await denialWorkflowService.takeDenialSummarySnapshot(labId);
      notify({ type: 'success', text: 'Snapshot saved. It captures the whole lab, not the current filters.' });
      setTab('OnDemand');
      await load();
    } catch (err) {
      notify({ type: 'danger', text: err.message || 'Unable to take a snapshot.' });
    } finally {
      setTaking(false);
    }
  }

  async function download(snapshot) {
    setDownloadingId(snapshot.snapshotId);
    try {
      const url = await denialWorkflowService.getDenialSummarySnapshotDownloadUrl(labId, snapshot.snapshotId);
      const a = document.createElement('a');
      a.href = url;
      a.download = snapshot.fileName || 'DenialSummary.xlsx';
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 30000);
    } catch (err) {
      notify({ type: 'danger', text: err.message || 'Unable to download the snapshot.' });
    } finally {
      setDownloadingId(null);
    }
  }

  const rows = snapshots.filter(s => s.periodType === tab);
  const counts = SNAPSHOT_TABS.reduce((acc, t) => ({ ...acc, [t.key]: snapshots.filter(s => s.periodType === t.key && !s.isArchived).length }), {});

  return (
    <div className="summary-style-card snapshot-card">
      <div className="snapshot-head">
        <div>
          <div className="summary-style-title">Summary snapshots</div>
          <div className="summary-style-hint">Excel copies of the whole lab's summary with observations. Weekly and monthly snapshots are taken automatically; the latest 12 of each stay active and older ones are archived.</div>
        </div>
        <div className="snapshot-actions">
          <label className="snapshot-archived-toggle"><input type="checkbox" checked={showArchived} onChange={e => setShowArchived(e.target.checked)} /> Show archived</label>
          {canEdit && <button type="button" className="wl-btn teal" disabled={taking || !labId} onClick={takeSnapshot}><i className="bi bi-camera" /> {taking ? 'Saving...' : 'Take snapshot now'}</button>}
        </div>
      </div>
      <div className="snapshot-tabs" role="tablist">
        {SNAPSHOT_TABS.map(t => (
          <button key={t.key} type="button" role="tab" aria-selected={tab === t.key} className={`snapshot-tab ${tab === t.key ? 'active' : ''}`} onClick={() => setTab(t.key)}>
            {t.label} <span className="snapshot-count">{counts[t.key] || 0}</span>
          </button>
        ))}
      </div>
      <div className="summary-style-table-wrap">
        <table className="summary-style-table snapshot-table">
          <thead>
            <tr>
              <th>Period</th>
              <th>Captured</th>
              <th className="num">Claims</th>
              <th className="num">Ins. Balance</th>
              <th className="snapshot-dl-col" />
            </tr>
          </thead>
          <tbody>
            {loading ? <tr><td colSpan="5" className="empty-cell">Loading snapshots...</td></tr>
              : rows.length ? rows.map(s => (
                <tr key={s.snapshotId} className={s.isArchived ? 'archived' : ''}>
                  <td>{periodLabel(s)}{s.isArchived && <span className="obs-pill archived">Archived</span>}</td>
                  <td>{displayDate(s.createdOn)} <span className="snapshot-by">{s.createdBy}</span></td>
                  <td className="num">{Number(s.totalClaims || 0).toLocaleString()}</td>
                  <td className="num">{money(s.totalInsuranceBalance)}</td>
                  <td className="snapshot-dl-col">
                    <button type="button" className="wl-btn xs" disabled={downloadingId === s.snapshotId} onClick={() => download(s)} title={s.fileName}>
                      <i className="bi bi-download" /> {downloadingId === s.snapshotId ? '...' : 'Excel'}
                    </button>
                  </td>
                </tr>
              )) : <tr><td colSpan="5" className="empty-cell">No {SNAPSHOT_TABS.find(t => t.key === tab)?.label.toLowerCase()} snapshots yet.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function SummaryTable({ title, hint, firstHeader, rows, nameOf, summaryType, observations, canEdit, onNameClick, onOpenObservation }) {
  const totals = useMemo(() => ({
    claims: rows.reduce((s, r) => s + Number(r.count || 0), 0),
    billed: rows.reduce((s, r) => s + getBilled(r), 0),
    ins: rows.reduce((s, r) => s + getInsBalance(r), 0),
    maxIns: Math.max(0, ...rows.map(getInsBalance))
  }), [rows]);

  return (
    <div className="summary-style-card">
      <div className="summary-style-title">{title}</div>
      <div className="summary-style-table-wrap">
        <div className="summary-style-hint">{hint}</div>
        <table className="summary-style-table summary-obs-table">
          <thead>
            <tr>
              <th>{firstHeader}</th>
              <th className="num">Claims</th>
              <th className="num">Billed</th>
              <th className="num">Ins. Balance</th>
              <th className="obs-col">Follow-up</th>
            </tr>
          </thead>
          <tbody>
            {rows.length ? rows.map((r, i) => {
              const name = rowName(nameOf(r));
              const ins = getInsBalance(r);
              const observation = observations[observationKey(summaryType, name)];
              return (
                <tr key={`${name}-${i}`}>
                  <td>
                    <button className="summary-link-text" type="button" onClick={() => onNameClick?.(nameOf(r) || '')}>{name}</button>
                  </td>
                  <td className="num">{Number(r.count || 0).toLocaleString()}</td>
                  <td className="num">{money(getBilled(r))}</td>
                  <td className="num ins-cell"><span>{money(ins)}</span><SummaryProgress value={ins} max={totals.maxIns} /></td>
                  <td className="obs-col">
                    <ObservationCell observation={observation} canEdit={canEdit} onOpen={() => onOpenObservation({ summaryType, name, observation })} />
                  </td>
                </tr>
              );
            }) : <tr><td colSpan="5" className="empty-cell">No {title.toLowerCase()} found.</td></tr>}
            {rows.length > 0 && (
              <tr className="summary-total-row">
                <td>Total</td>
                <td className="num">{totals.claims.toLocaleString()}</td>
                <td className="num">{money(totals.billed)}</td>
                <td className="num total-balance">{money(totals.ins)}</td>
                <td />
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

export default function DenialSummaryPage({ data, labId, role = '', canAssign = false, setMessage, onClassificationClick, onActionCategoryClick }) {
  const classifications = data.denialClassifications || [];
  const actions = data.actionCategories || [];
  const canEdit = canAssignRole(role);
  const [observations, setObservations] = useState({});
  const [editing, setEditing] = useState(null);
  const [saving, setSaving] = useState(false);

  const notify = useCallback((msg) => setMessage?.(msg), [setMessage]);

  const loadObservations = useCallback(async () => {
    if (!labId) { setObservations({}); return {}; }
    try {
      const list = await denialWorkflowService.getDenialSummaryObservations(labId) || [];
      const map = Object.fromEntries(list.map(o => [observationKey(o.summaryType, o.summaryKey), o]));
      setObservations(map);
      return map;
    } catch (err) {
      notify({ type: 'danger', text: err.message || 'Unable to load Denial Summary observations.' });
      return {};
    }
  }, [labId, notify]);

  useEffect(() => { loadObservations(); }, [loadObservations]);

  async function saveObservation(payload) {
    setSaving(true);
    try {
      const result = await denialWorkflowService.saveDenialSummaryObservation(labId, payload);
      const saved = result?.observation;
      if (saved) setObservations(prev => ({ ...prev, [observationKey(saved.summaryType, saved.summaryKey)]: saved }));
      setEditing(null);
      notify({ type: 'success', text: `Observation saved for ${payload.summaryKey}.` });
    } catch (err) {
      // Most likely a concurrent edit (409): show the latest version so the user can reapply.
      notify({ type: 'danger', text: err.message || 'Unable to save the observation.' });
      const latest = await loadObservations();
      const key = observationKey(payload.summaryType, payload.summaryKey);
      setEditing(current => current ? { ...current, observation: latest[key] } : current);
    } finally {
      setSaving(false);
    }
  }

  return (
    <>
      <div className="row-2 summary-style-grid">
        <SummaryTable
          title="Denial classification summary"
          hint={canAssign ? 'Click a classification to view and assign claims' : 'Click a classification to view matching claims'}
          firstHeader="Classification"
          rows={classifications}
          nameOf={r => r.classification}
          summaryType={CLASSIFICATION}
          observations={observations}
          canEdit={canEdit}
          onNameClick={onClassificationClick}
          onOpenObservation={setEditing}
        />
        <SummaryTable
          title="Action / task summary"
          hint={canAssign ? 'Click an action/task to view and assign claims' : 'Click an action/task to view matching claims'}
          firstHeader="Action / Task"
          rows={actions}
          nameOf={r => r.actionCategory}
          summaryType={ACTION_CATEGORY}
          observations={observations}
          canEdit={canEdit}
          onNameClick={onActionCategoryClick}
          onOpenObservation={setEditing}
        />
      </div>

      <SnapshotPanel labId={labId} canEdit={canEdit} notify={notify} />

      {editing && (
        <ObservationModal
          key={`${editing.summaryType}|${editing.name}|${editing.observation?.version || 'new'}`}
          target={editing}
          canEdit={canEdit}
          saving={saving}
          onClose={() => setEditing(null)}
          onSave={saveObservation}
        />
      )}
    </>
  );
}
