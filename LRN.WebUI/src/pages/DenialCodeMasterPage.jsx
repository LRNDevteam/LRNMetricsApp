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
  ['actionCode', 'Action Code', 'actionCodes'],
  ['actionCategory', 'Action Category', 'actionCategories'],
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

function EditorModal({ initial, lookups, onClose, onSave }) {
  const [form, setForm] = useState(() => ({ ...blankForm, ...(initial || {}), slaDays: initial?.slaDays ?? initial?.SLADays ?? '' }));
  const isEdit = !!initial;
  const setField = (key, value) => setForm(prev => ({ ...prev, [key]: value }));

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
        <TextField label="Priority" value={form.priority} onChange={v => setField('priority', v)} />
        <TextField label="SLA Days" value={form.slaDays} onChange={v => setField('slaDays', v)} />
        <TextField label="Denial Description" value={form.denialDescription} rows={2} onChange={v => setField('denialDescription', v)} />
        {dropdownFields.map(([key, label, lookupKey]) => <ChoiceField key={key} label={label} value={form[key]} options={lookups?.[lookupKey] || lookups?.[lookupKey[0].toUpperCase() + lookupKey.slice(1)] || []} disabled={isEdit && (key === 'coverageStatus' || key === 'icdComplianceStatus')} onChange={v => setField(key, v)} />)}
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

export default function DenialCodeMasterPage({ labId, setMessage }) {
  const [rows, setRows] = useState([]);
  const [pageInfo, setPageInfo] = useState({ page: 1, totalCount: 0, totalPages: 0 });
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState({ search: '', page: 1, pageSize: 25 });
  const [lookups, setLookups] = useState({});
  const [loading, setLoading] = useState(false);
  const [importing, setImporting] = useState(false);
  const [editor, setEditor] = useState(null);

  const totalPages = useMemo(() => Number(pageInfo.totalPages || pageInfo.TotalPages || 0), [pageInfo]);

  async function load(next = query) {
    if (!labId) return;
    setLoading(true);
    try {
      const [data, lookupData] = await Promise.all([
        denialWorkflowService.getDenialCodeMaster({ ...next, labId }),
        denialWorkflowService.getDenialCodeMasterLookups(labId)
      ]);
      setRows(data.items || []);
      setPageInfo(data);
      setLookups(lookupData || {});
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Unable to load Denial Code Master.' });
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { load(query); }, [labId, query.page, query.search]);

  async function save(payload, isEdit) {
    try {
      if (isEdit) await denialWorkflowService.updateDenialCodeMaster(labId, payload.__key || { denialCode: payload.denialCode, coverageStatus: payload.coverageStatus, icdComplianceStatus: payload.icdComplianceStatus }, payload);
      else await denialWorkflowService.createDenialCodeMaster(labId, payload);
      setEditor(null);
      setMessage({ type: 'success', text: 'Denial Code Master saved and classifier Excel regenerated.' });
      load(query);
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Save failed.' });
    }
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
      load(query);
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Import failed.' });
    } finally {
      setImporting(false);
    }
  }

  async function regenerate() {
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

  return <section className="dcm-page">
    <div className="claim-view-top">
      <div><div className="claim-view-title">Denial Code Master</div><div className="claim-view-subtitle">AR Manager only classifier maintenance</div></div>
      <span className="table-count">{pageInfo.totalCount || 0} records</span>
    </div>
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
    {editor && <EditorModal initial={editor.denialCode ? editor : null} lookups={lookups} onClose={() => setEditor(null)} onSave={save} />}
  </section>;
}
