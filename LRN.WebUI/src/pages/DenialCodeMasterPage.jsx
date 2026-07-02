import React, { useEffect, useMemo, useState } from 'react';
import { denialWorkflowService } from '../services/denialWorkflowService';

const blankForm = {
  denialCode: '',
  denialDescription: '',
  denialClassification: '',
  coverageStatus: '',
  icdComplianceStatus: '',
  denialValidity: '',
  actionCode: '',
  recommendedAction: '',
  actionCategory: '',
  task: '',
  shortCategory: '',
  priority: '',
  slaDays: '',
  notesComments: ''
};

const dropdownFields = [
  ['denialClassification', 'Denial Classification', 'denialClassifications'],
  ['coverageStatus', 'Coverage Status', 'coverageStatuses'],
  ['icdComplianceStatus', 'ICD Compliance Status', 'icdComplianceStatuses'],
  ['denialValidity', 'Denial Validity', 'denialValidities'],
  ['task', 'Task', 'tasks']
];

function valueOf(row, key) {
  if (!row) return '';
  return row[key] ?? row[key[0].toUpperCase() + key.slice(1)] ?? '';
}

function TextField({ label, value, onChange, type = 'text', readOnly = false, rows = 0 }) {
  return <label className="dcm-field">
    <span>{label}</span>
    {rows ? <textarea value={value || ''} rows={rows} readOnly={readOnly} onChange={e => onChange(e.target.value)} />
      : <input type={type} value={value || ''} readOnly={readOnly} onChange={e => onChange(e.target.value)} />}
  </label>;
}

function ChoiceField({ label, value, options = [], onChange, disabled = false }) {
  const listId = `dcm-${label.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}-options`;
  const uniqueOptions = Array.from(new Set((options || []).filter(x => String(x || '').trim()).map(x => String(x).trim())));

  return <label className="dcm-field">
    <span>{label}</span>
    <input
      type="search"
      list={listId}
      value={value || ''}
      disabled={disabled}
      placeholder="Search and select"
      autoComplete="off"
      onChange={e => onChange(e.target.value)}
    />
    <datalist id={listId}>
      {uniqueOptions.map(x => <option key={x} value={x} />)}
    </datalist>
  </label>;
}

function SelectField({ label, value, options = [], onChange, disabled = false, required = false }) {
  const uniqueOptions = Array.from(new Set([value, ...(options || [])].filter(x => String(x || '').trim()).map(x => String(x).trim())));
  return <label className="dcm-field">
    <span>{label}</span>
    <select value={value || ''} disabled={disabled} required={required} onChange={e => onChange(e.target.value)}>
      <option value="">Select {label.replace(' *', '')}</option>
      {uniqueOptions.map(x => <option key={x} value={x}>{x}</option>)}
    </select>
  </label>;
}

function EditorModal({ initial, lookups, masterData, onClose, onSave }) {
  const actionCategories = masterData?.actionCategories || [];
  const actionCodeFor = category => actionCategories.find(x => x.actionCategory === category)?.actionCode || '';
  const actionCategoryFor = code => actionCategories.find(x => x.actionCode === code)?.actionCategory || '';
  const [form, setForm] = useState(() => {
    const base = { ...blankForm, ...(initial || {}), slaDays: initial?.slaDays ?? initial?.SLADays ?? '' };
    if (!base.actionCategory && base.actionCode) base.actionCategory = actionCategoryFor(base.actionCode);
    if (base.actionCategory) base.actionCode = actionCodeFor(base.actionCategory) || base.actionCode;
    return base;
  });
  const isEdit = !!initial;
  const setField = (key, value) => setForm(prev => ({ ...prev, [key]: value }));
  const masterOptions = {
    denialClassification: masterData?.denialClassifications || [],
    coverageStatus: masterData?.coverageStatuses || [],
    icdComplianceStatus: masterData?.icdComplianceStatuses || [],
    denialValidity: masterData?.denialValidities || []
  };

  function submit(e) {
    e.preventDefault();
    if (!String(form.denialCode || '').trim()) return;
    const payload = { ...form, slaDays: String(form.slaDays || '').trim() || null };
    onSave(payload, isEdit);
  }

  return <div className="modal-backdrop">
    <form className="dcm-modal" onSubmit={submit}>
      <div className="claim-modal-header">
        <div><div className="claim-modal-title">{isEdit ? 'Edit Denial Code' : 'Add Denial Code'}</div><small>{isEdit ? 'Primary fields cannot be changed.' : 'Create a new classifier row.'}</small></div>
        <button type="button" className="modal-close" onClick={onClose}><i className="bi bi-x-lg" /></button>
      </div>
      <div className="dcm-form-grid">
        <TextField label="Denial Code *" value={form.denialCode} readOnly={isEdit} onChange={v => setField('denialCode', v)} />
        <SelectField label="Priority" value={form.priority} options={masterData?.priorities || []} onChange={v => setField('priority', v)} />
        <SelectField label="SLA Days" value={form.slaDays} options={masterData?.slaDays || []} onChange={v => setField('slaDays', v)} />
        <TextField label="Denial Description" value={form.denialDescription} rows={2} onChange={v => setField('denialDescription', v)} />
        {dropdownFields.map(([key, label, lookupKey]) => key === 'task'
          ? <ChoiceField key={key} label={label} value={form[key]} options={lookups?.[lookupKey] || lookups?.[lookupKey[0].toUpperCase() + lookupKey.slice(1)] || []} onChange={v => setField(key, v)} />
          : <SelectField key={key} label={label} value={form[key]} options={masterOptions[key]} disabled={isEdit && (key === 'coverageStatus' || key === 'icdComplianceStatus')} onChange={v => setField(key, v)} />)}
        <SelectField label="Action Category *" value={form.actionCategory} options={actionCategories.map(x => x.actionCategory)} required onChange={v => setForm(prev => ({ ...prev, actionCategory: v, actionCode: actionCodeFor(v) }))} />
        <TextField label="Action Code *" value={form.actionCode} readOnly onChange={() => {}} />
        <TextField label="Recommended Action" value={form.recommendedAction} rows={2} onChange={v => setField('recommendedAction', v)} />
        <TextField label="Short Category" value={form.shortCategory} onChange={v => setField('shortCategory', v)} />
        <TextField label="Notes / Comments" value={form.notesComments} rows={3} onChange={v => setField('notesComments', v)} />
      </div>
      <div className="dcm-modal-actions">
        <button type="button" className="wl-btn" onClick={onClose}>Cancel</button>
        <button type="submit" className="wl-btn teal">Save</button>
      </div>
    </form>
  </div>;
}

function ImpactPreviewModal({ impact, saving, onCancel, onConfirm }) {
  const queues = impact?.queues || impact?.Queues || [];
  const affectedClaims = impact?.affectedClaims ?? impact?.AffectedClaims ?? 0;
  const affectedTasks = impact?.affectedTasks ?? impact?.AffectedTasks ?? 0;
  return <div className="modal-backdrop">
    <div className="action-warning-modal">
      <div className="claim-modal-header">
        <div><div className="claim-modal-title">Confirm Denial-Action Mapping Update</div><small>This change will apply to every open claim/task currently matching this denial code.</small></div>
        <button type="button" className="modal-close" onClick={onCancel}><i className="bi bi-x-lg" /></button>
      </div>
      <div className="action-warning-body">
        {affectedTasks > 0
          ? <p>This denial code currently maps <strong>{affectedTasks}</strong> open task(s) across <strong>{affectedClaims}</strong> claim(s). Saving will change how those claims are classified and actioned going forward.</p>
          : <p>No open claims or tasks currently reference this denial code. It is safe to save.</p>}
        <div className="action-warning-counts">
          <div><span>Affected Claims</span><strong>{affectedClaims}</strong></div>
          <div><span>Affected Tasks</span><strong>{affectedTasks}</strong></div>
        </div>
        {queues.length > 0 && <table className="lrn-table workflow-table dcm-table" style={{ marginTop: '12px' }}>
          <thead><tr><th>Queue</th><th>Claims</th><th>Tasks</th></tr></thead>
          <tbody>{queues.map(q => <tr key={q.queueName || q.QueueName}><td>{q.queueName || q.QueueName}</td><td>{q.claimCount ?? q.ClaimCount ?? 0}</td><td>{q.taskCount ?? q.TaskCount ?? 0}</td></tr>)}</tbody>
        </table>}
      </div>
      <div className="dcm-modal-actions">
        <button type="button" className="wl-btn" disabled={saving} onClick={onCancel}>Cancel</button>
        <button type="button" className="wl-btn teal" disabled={saving} onClick={onConfirm}>{saving ? 'Saving...' : 'Confirm and Save'}</button>
      </div>
    </div>
  </div>;
}

function ActionWarningModal({ warning, onLater, onReview }) {
  return <div className="modal-backdrop">
    <div className="action-warning-modal">
      <div className="claim-modal-header">
        <div><div className="claim-modal-title">Assigned Open Claims Affected</div><small>Verification required before assigned task action details are changed.</small></div>
        <button type="button" className="modal-close" onClick={onLater}><i className="bi bi-x-lg" /></button>
      </div>
      <div className="action-warning-body">
        <p>The uploaded Denial Code Master contains action changes for assigned open claims/tasks. Please verify and confirm before applying the new action details.</p>
        <div className="action-warning-counts">
          <div><span>Affected Claims</span><strong>{warning.affectedClaims || warning.AffectedClaims || 0}</strong></div>
          <div><span>Affected Tasks</span><strong>{warning.affectedTasks || warning.AffectedTasks || 0}</strong></div>
        </div>
      </div>
      <div className="dcm-modal-actions">
        <button type="button" className="wl-btn" onClick={onLater}>Later</button>
        <button type="button" className="wl-btn teal" onClick={() => onReview(warning.batchId || warning.BatchId)}>Review Now</button>
      </div>
    </div>
  </div>;
}

function PushReviewEditor({ row, masterData, onClose, onSave }) {
  const actionCategories = masterData?.actionCategories || [];
  const actionCodeFor = category => actionCategories.find(x => x.actionCategory === category)?.actionCode || '';
  const actionCategoryFor = code => actionCategories.find(x => x.actionCode === code)?.actionCategory || '';
  const [form, setForm] = useState({
    actionCode: actionCodeFor(row?.newActionCategory) || row?.newActionCode || '',
    actionCategory: row?.newActionCategory || actionCategoryFor(row?.newActionCode) || '',
    task: row?.newTask || '',
    recommendedAction: row?.newShortCategory || '',
    denialClassification: row?.newDenialClassification || ''
  });
  const setField = (key, value) => setForm(prev => ({ ...prev, [key]: value }));
  return <div className="modal-backdrop">
    <form className="dcm-modal" onSubmit={e => { e.preventDefault(); onSave(form); }}>
      <div className="claim-modal-header">
        <div><div className="claim-modal-title">Review Push · {row?.denialCode}</div><small>These approved values will be written to Denial Action Master.</small></div>
        <button type="button" className="modal-close" onClick={onClose}><i className="bi bi-x-lg" /></button>
      </div>
      <div className="dcm-form-grid">
        <SelectField label="Action Category *" value={form.actionCategory} options={actionCategories.map(x => x.actionCategory)} required onChange={v => setForm(prev => ({ ...prev, actionCategory: v, actionCode: actionCodeFor(v) }))} />
        <TextField label="Action Code *" value={form.actionCode} readOnly onChange={() => {}} />
        <SelectField label="Denial Classification" value={form.denialClassification} options={masterData?.denialClassifications || []} onChange={v => setField('denialClassification', v)} />
        <TextField label="Task *" value={form.task} rows={2} onChange={v => setField('task', v)} />
        <TextField label="Recommended Action *" value={form.recommendedAction} rows={3} onChange={v => setField('recommendedAction', v)} />
      </div>
      <div className="dcm-modal-actions">
        <button type="button" className="wl-btn" onClick={onClose}>Cancel</button>
        <button type="submit" className="wl-btn teal">Save Review</button>
      </div>
    </form>
  </div>;
}

export default function DenialCodeMasterPage({ labId, setMessage, onReviewActionChanges, initialPushAuditId = null, onPushConfirmed }) {
  const [rows, setRows] = useState([]);
  const [pageInfo, setPageInfo] = useState({ page: 1, totalCount: 0, totalPages: 0 });
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState({ search: '', page: 1, pageSize: 25 });
  const [lookups, setLookups] = useState({});
  const [masterData, setMasterData] = useState({ actionCategories: [], denialClassifications: [], coverageStatuses: [], icdComplianceStatuses: [], denialValidities: [], slaDays: [], priorities: [] });
  const [loading, setLoading] = useState(false);
  const [importing, setImporting] = useState(false);
  const [editor, setEditor] = useState(null);
  const [actionWarning, setActionWarning] = useState(null);
  const [impactPreview, setImpactPreview] = useState(null);
  const [impactSaving, setImpactSaving] = useState(false);
  const [activeTab, setActiveTab] = useState(initialPushAuditId ? 'push' : 'master');
  const [pendingPushes, setPendingPushes] = useState([]);
  const [selectedPushId, setSelectedPushId] = useState(initialPushAuditId || null);
  const [pushAudit, setPushAudit] = useState(null);
  const [pushLoading, setPushLoading] = useState(false);
  const [pushConfirming, setPushConfirming] = useState(false);
  const [pushEditor, setPushEditor] = useState(null);

  const totalPages = useMemo(() => Number(pageInfo.totalPages || pageInfo.TotalPages || 0), [pageInfo]);

  async function load(next = query) {
    if (!labId) return;
    setLoading(true);
    try {
      const [data, lookupData, centralMasterData] = await Promise.all([
        denialWorkflowService.getDenialCodeMaster({ ...next, labId }),
        denialWorkflowService.getDenialCodeMasterLookups(labId),
        denialWorkflowService.getDenialMapperMasterData()
      ]);
      setRows(data.items || []);
      setPageInfo(data);
      setLookups(lookupData || {});
      setMasterData(centralMasterData || {});
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Unable to load Denial Code Master.' });
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { load(query); }, [labId, query.page, query.search]);

  async function loadPendingPushes(preferredId = null) {
    if (!labId) return;
    try {
      const items = await denialWorkflowService.getDenialMapperNotifications(labId);
      const pending = Array.isArray(items) ? items : [];
      setPendingPushes(pending);
      const requested = Number(preferredId || selectedPushId || initialPushAuditId || 0);
      const nextId = pending.some(x => Number(x.pushAuditId) === requested) ? requested : Number(pending[0]?.pushAuditId || 0);
      setSelectedPushId(nextId || null);
      if (!nextId) setPushAudit(null);
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Unable to load pending Denial Code pushes.' });
    }
  }

  useEffect(() => {
    setActiveTab(initialPushAuditId ? 'push' : 'master');
    loadPendingPushes(initialPushAuditId);
  }, [labId, initialPushAuditId]);

  useEffect(() => {
    if (activeTab !== 'push' || !selectedPushId) return;
    setPushLoading(true);
    denialWorkflowService.getDenialMapperPushVerification(selectedPushId)
      .then(setPushAudit)
      .catch(err => setMessage({ type: 'danger', text: err.message || 'Unable to load Denial Code Push Verification.' }))
      .finally(() => setPushLoading(false));
  }, [activeTab, selectedPushId]);

  async function save(payload, isEdit) {
    const key = payload.__key || { denialCode: payload.denialCode, coverageStatus: payload.coverageStatus, icdComplianceStatus: payload.icdComplianceStatus };
    if (!isEdit) {
      await commitSave(payload, isEdit, key);
      return;
    }
    try {
      const impact = await denialWorkflowService.getDenialCodeMasterImpact(labId, key.denialCode);
      setImpactPreview({ payload, isEdit, key, impact });
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Unable to calculate the impact of this change.' });
    }
  }

  async function commitSave(payload, isEdit, key) {
    try {
      if (isEdit) await denialWorkflowService.updateDenialCodeMaster(labId, key, payload);
      else await denialWorkflowService.createDenialCodeMaster(labId, payload);
      setEditor(null);
      setImpactPreview(null);
      setMessage({ type: 'success', text: 'Denial Code Master saved and classifier Excel regenerated.' });
      load(query);
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Save failed.' });
    } finally {
      setImpactSaving(false);
    }
  }

  async function confirmImpactSave() {
    if (!impactPreview || impactSaving) return;
    setImpactSaving(true);
    await commitSave(impactPreview.payload, impactPreview.isEdit, impactPreview.key);
  }

  async function remove(row) {
    const key = {
      denialCode: valueOf(row, 'denialCode'),
      coverageStatus: valueOf(row, 'coverageStatus'),
      icdComplianceStatus: valueOf(row, 'icdComplianceStatus')
    };
    if (!window.confirm(`Delete denial code ${key.denialCode} / ${key.coverageStatus} / ${key.icdComplianceStatus}?`)) return;

    try {
      await denialWorkflowService.deleteDenialCodeMaster(labId, key);
      setMessage({ type: 'success', text: 'Denial Code Master row deleted and classifier Excel regenerated.' });
      load(query);
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Delete failed.' });
    }
  }

  async function importFile(file) {
    if (!file || importing) return;
    setImporting(true);
    setMessage?.({ type: 'info', text: `Importing ${file.name}. This may take a few minutes...` });
    try {
      const result = await denialWorkflowService.importDenialCodeMaster(labId, file);
      setMessage({ type: result.failedCount ? 'warning' : 'success', text: `Import complete. Inserted: ${result.insertedCount || 0}, updated/replaced: ${result.updatedCount || 0}, skipped: ${result.skippedCount || 0}, failed: ${result.failedCount || 0}.` });
      if (result.hasActionChangeWarnings || result.HasActionChangeWarnings) setActionWarning(result);
      load(query);
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Import failed.' });
    } finally {
      setImporting(false);
    }
  }

  async function regenerate() {
    if (!window.confirm('This will regenerate the denial classifier export for all records. This action cannot be undone. Continue?')) return;
    try {
      await denialWorkflowService.regenerateDenialCodeMasterExcel(labId);
      setMessage({ type: 'success', text: 'Classifier Excel regenerated.' });
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Regenerate failed.' });
    }
  }

  async function downloadExport() {
    const url = await denialWorkflowService.getDenialCodeMasterExportUrl(labId);
    const a = document.createElement('a');
    a.href = url;
    a.download = '';
    document.body.appendChild(a);
    a.click();
    a.remove();
  }

  async function savePushReview(payload) {
    if (!pushAudit || !pushEditor) return;
    try {
      await denialWorkflowService.updateDenialMapperPushVerificationDetail(pushAudit.pushAuditId, pushEditor.pushAuditDetailId, payload);
      setPushEditor(null);
      setPushAudit(await denialWorkflowService.getDenialMapperPushVerification(pushAudit.pushAuditId));
      setMessage({ type: 'success', text: 'Pending push row updated.' });
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Unable to update the pending push row.' });
    }
  }

  async function confirmPush() {
    if (!pushAudit || pushConfirming) return;
    if (!window.confirm(`Apply this push to the ${pushAudit.targetLabName || 'selected lab'} Denial Action Master?`)) return;
    setPushConfirming(true);
    try {
      const result = await denialWorkflowService.acknowledgeDenialMapperNotification(pushAudit.pushAuditId, labId);
      setMessage({ type: 'success', text: result.message || 'Denial Code push confirmed.' });
      await Promise.all([load(query), loadPendingPushes()]);
      setPushAudit(null);
      setActiveTab('master');
      onPushConfirmed?.();
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Unable to confirm the Denial Code push.' });
    } finally {
      setPushConfirming(false);
    }
  }

  return <section className="dcm-page">
    <div className="claim-view-top">
      <div><div className="claim-view-title">Denial Code Master</div><div className="claim-view-subtitle">AR Manager only classifier maintenance</div></div>
      <span className="table-count">{pageInfo.totalCount || 0} records</span>
    </div>
    <div className="dcm-tabs">
      <button type="button" className={activeTab === 'master' ? 'active' : ''} onClick={() => setActiveTab('master')}>Denial Action Master</button>
      <button type="button" className={`${activeTab === 'push' ? 'active' : ''} ${pendingPushes.length ? 'pending' : ''}`} onClick={() => setActiveTab('push')}>
        Denial Code Push Verification
        {pendingPushes.length > 0 && <span>{pendingPushes.length}</span>}
      </button>
    </div>
    {pendingPushes.length > 0 && activeTab === 'master' && <button type="button" className="dcm-pending-banner" onClick={() => setActiveTab('push')}>
      <i className="bi bi-exclamation-circle-fill" />
      <span><strong>{pendingPushes.length} Denial Code push{pendingPushes.length === 1 ? '' : 'es'} awaiting confirmation</strong>Review and confirm before the codes are applied to Denial Action Master.</span>
      <i className="bi bi-arrow-right" />
    </button>}
    {activeTab === 'master' && <>
    <div className="claim-list-toolbar">
      <label className="claim-search-wrap"><i className="bi bi-search" /><input value={search} onChange={e => setSearch(e.target.value)} onKeyDown={e => { if (e.key === 'Enter') setQuery({ ...query, search, page: 1 }); }} placeholder="Search denial code, classification, action" /></label>
      <button className="wl-btn xs" onClick={() => setQuery({ ...query, search, page: 1 })}>Search</button>
      <button className="wl-btn teal xs" onClick={() => setEditor({})}><i className="bi bi-plus-circle" /> Add</button>
      <label className={`wl-btn xs dcm-upload ${importing ? 'disabled' : ''}`} aria-disabled={importing}><i className={`bi ${importing ? 'bi-hourglass-split' : 'bi-upload'}`} /> {importing ? 'Importing Excel...' : 'Import Excel'}<input type="file" accept=".xlsx,.xlsm,.xltx,.xltm" disabled={importing} onChange={e => { importFile(e.target.files?.[0]); e.target.value = ''; }} /></label>
      <button className="wl-btn xs" onClick={regenerate}><i className="bi bi-arrow-repeat" /> Regenerate</button>
      <button className="wl-btn xs" onClick={downloadExport}><i className="bi bi-download" /> Export Excel</button>
    </div>
    {(loading || importing) && <div className="loading-line" />}
    {importing && <div className="dcm-import-status"><i className="bi bi-hourglass-split" /> Import is running. Please keep this page open while the file is uploaded and processed.</div>}
    <div className="claim-assign-scroll dcm-table-wrap">
      <table className="lrn-table workflow-table dcm-table">
        <thead><tr><th>Denial Code</th><th>Denial Classification</th><th>Coverage Status</th><th>ICD Compliance Status</th><th>Action Code</th><th>Action Category</th><th>Actions</th></tr></thead>
        <tbody>
          {rows.length ? rows.map(row => <tr key={`${valueOf(row, 'denialCode')}|${valueOf(row, 'coverageStatus')}|${valueOf(row, 'icdComplianceStatus')}`}>
            <td><strong>{valueOf(row, 'denialCode')}</strong></td>
            <td>{valueOf(row, 'denialClassification') || '-'}</td>
            <td>{valueOf(row, 'coverageStatus') || '-'}</td>
            <td>{valueOf(row, 'icdComplianceStatus') || '-'}</td>
            <td>{valueOf(row, 'actionCode') || '-'}</td>
            <td>{valueOf(row, 'actionCategory') || '-'}</td>
            <td className="dcm-row-actions">
              <button className="wl-btn xs" onClick={() => setEditor({ ...blankForm, ...Object.fromEntries(Object.keys(blankForm).map(k => [k, valueOf(row, k)])), __key: { denialCode: valueOf(row, 'denialCode'), coverageStatus: valueOf(row, 'coverageStatus'), icdComplianceStatus: valueOf(row, 'icdComplianceStatus') } })}><i className="bi bi-pencil" /> Edit</button>
              <button className="wl-btn xs danger" onClick={() => remove(row)}><i className="bi bi-trash" /> Delete</button>
            </td>
          </tr>) : <tr><td colSpan="7" className="empty-cell">No denial codes found.</td></tr>}
        </tbody>
      </table>
    </div>
    <div className="pager">
      <button className="wl-btn xs" disabled={(pageInfo.page || 1) <= 1} onClick={() => setQuery(q => ({ ...q, page: Math.max(1, (q.page || 1) - 1) }))}>Previous</button>
      <span>Page {pageInfo.page || 1} of {Math.max(1, totalPages)}</span>
      <button className="wl-btn xs" disabled={(pageInfo.page || 1) >= Math.max(1, totalPages)} onClick={() => setQuery(q => ({ ...q, page: (q.page || 1) + 1 }))}>Next</button>
    </div>
    </>}
    {activeTab === 'push' && <div className="dcm-push-review">
      {pendingPushes.length > 1 && <label className="dcm-push-select"><span>Pending push</span><select value={selectedPushId || ''} onChange={e => setSelectedPushId(Number(e.target.value))}>{pendingPushes.map(item => <option key={item.pushAuditId} value={item.pushAuditId}>{item.targetLabName} · {new Date(item.createdOn).toLocaleString()}</option>)}</select></label>}
      {(pushLoading || pushConfirming) && <div className="loading-line" />}
      {!pendingPushes.length && !pushLoading && <div className="dcm-no-push"><i className="bi bi-check-circle" /><strong>No pending push confirmation</strong><span>Approved Denial Code pushes will appear here until confirmed.</span></div>}
      {pushAudit && <div className="dcm-push-panel">
        <div className="dcm-push-summary">
          <div><span>Target Lab</span><strong>{pushAudit.targetLabName}</strong></div>
          <div><span>Codes Compared</span><strong>{pushAudit.totalCompared || 0}</strong></div>
          <div><span>Pending Changes</span><strong>{pushAudit.totalDifferences || 0}</strong></div>
          <div><span>Pushed By</span><strong>{pushAudit.pushedByUserId || '-'}</strong></div>
        </div>
        <div className="dcm-push-note"><i className="bi bi-info-circle" />Confirming applies all active Lab Master mappings to the lab-level <code>DenialCodeMaster</code>. Rows below highlight new or changed codes.</div>
        <div className="claim-assign-scroll dcm-table-wrap">
          <table className="lrn-table workflow-table dcm-table dcm-push-table">
            <thead><tr><th>Denial Code</th><th>Type</th><th>Coverage</th><th>ICD</th><th>Current Action</th><th>New Action</th><th>New Category</th><th>New Task</th><th>New Classification</th><th>Action</th></tr></thead>
            <tbody>{pushAudit.differences?.length ? pushAudit.differences.map(row => <tr className="dcm-pending-row" key={row.pushAuditDetailId}>
              <td><strong>{row.denialCode}</strong></td><td><span className="dcm-change-badge">{row.differenceType}</span></td><td>{row.coverageStatus || 'N/A'}</td><td>{row.icdComplianceStatus || 'N/A'}</td><td>{row.existingActionCode || '-'}</td><td>{row.newActionCode || '-'}</td><td>{row.newActionCategory || '-'}</td><td>{row.newTask || '-'}</td><td>{row.newDenialClassification || '-'}</td>
              <td><button className="wl-btn xs" onClick={() => setPushEditor(row)}><i className="bi bi-pencil-square" /> Review</button></td>
            </tr>) : <tr><td colSpan="10" className="empty-cell">No field differences were detected. Confirm to synchronize the current Lab Master into Denial Action Master.</td></tr>}</tbody>
          </table>
        </div>
        <div className="dcm-push-actions"><button type="button" className="wl-btn teal" disabled={pushConfirming} onClick={confirmPush}><i className="bi bi-check2-circle" />{pushConfirming ? 'Applying Codes...' : 'Confirm and Apply to Denial Action Master'}</button></div>
      </div>}
    </div>}
    {editor && <EditorModal initial={editor.denialCode ? editor : null} lookups={lookups} masterData={masterData} onClose={() => setEditor(null)} onSave={save} />}
    {impactPreview && <ImpactPreviewModal impact={impactPreview.impact} saving={impactSaving} onCancel={() => setImpactPreview(null)} onConfirm={confirmImpactSave} />}
    {pushEditor && <PushReviewEditor row={pushEditor} masterData={masterData} onClose={() => setPushEditor(null)} onSave={savePushReview} />}
    {actionWarning && <ActionWarningModal warning={actionWarning} onLater={() => setActionWarning(null)} onReview={(batchId) => { setActionWarning(null); onReviewActionChanges?.(batchId); }} />}
  </section>;
}
