import React, { useEffect, useMemo, useState } from 'react';
import { denialWorkflowService } from '../services/denialWorkflowService';

const statuses = ['Pending', 'Confirmed', 'Ignored'];
const blankQuery = { search: '', batchId: '', denialCode: '', icdComplianceStatus: '', coverageStatus: '', assignedTo: '', status: 'Pending', page: 1, pageSize: 50 };
const columns = [
  ['claimID', 'ClaimID'], ['taskID', 'TaskID'], ['patientId', 'PatientId'], ['payerName', 'PayerName'], ['assignedTo', 'AssignedTo'],
  ['claimStatus', 'ClaimStatus'], ['denialCode', 'DenialCode'], ['icdComplianceStatus', 'ICDComplianceStatus'], ['coverageStatus', 'CoverageStatus'],
  ['oldActionCode', 'OldActionCode'], ['newActionCode', 'NewActionCode'], ['oldActionCategory', 'OldActionCategory'], ['newActionCategory', 'NewActionCategory'],
  ['oldTask', 'OldTask'], ['newTask', 'NewTask'], ['oldShortCategory', 'OldShortCategory'], ['newShortCategory', 'NewShortCategory'],
  ['verificationStatus', 'VerificationStatus'], ['createdOn', 'CreatedOn']
];

function val(row, key) {
  return row?.[key] ?? row?.[key[0].toUpperCase() + key.slice(1)] ?? '';
}

function date(value) {
  if (!value) return '-';
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? String(value) : d.toLocaleString();
}

function changed(row, oldKey, newKey) {
  return String(val(row, oldKey) || '').trim() !== String(val(row, newKey) || '').trim();
}

function ConfirmActionModal({ count, onCancel, onConfirm }) {
  return <div className="modal-backdrop">
    <div className="action-confirm-modal">
      <div className="claim-modal-header">
        <div><div className="claim-modal-title">Confirm Action Change</div></div>
        <button type="button" className="modal-close" onClick={onCancel}><i className="bi bi-x-lg" /></button>
      </div>
      <div className="action-confirm-body">
        <p>You are about to apply new action details to <strong>{count}</strong> assigned open tasks.</p>
        <p>This will update:</p>
        <ul>
          <li>Action Code</li>
          <li>Action Category</li>
          <li>Task</li>
          <li>Short Category</li>
        </ul>
        <p>Closed claims will be skipped automatically.</p>
        <p>Do you want to continue?</p>
      </div>
      <div className="dcm-modal-actions">
        <button type="button" className="wl-btn" onClick={onCancel}>Cancel</button>
        <button type="button" className="wl-btn teal" onClick={onConfirm}>Confirm Update</button>
      </div>
    </div>
  </div>;
}

export default function DenialActionVerificationPage({ labId, setMessage, initialBatchId = '' }) {
  const [query, setQuery] = useState(() => ({ ...blankQuery, batchId: initialBatchId || '' }));
  const [draft, setDraft] = useState(() => ({ ...blankQuery, batchId: initialBatchId || '' }));
  const [data, setData] = useState({ items: [], totalCount: 0, totalPages: 0, page: 1 });
  const [lookups, setLookups] = useState({});
  const [batch, setBatch] = useState(null);
  const [selected, setSelected] = useState({});
  const [loading, setLoading] = useState(false);
  const [confirmPlan, setConfirmPlan] = useState(null);

  const items = data.items || [];
  const totalPages = Number(data.totalPages || 0);
  const selectedIds = useMemo(() => Object.keys(selected).filter(id => selected[id]).map(Number), [selected]);
  const pendingCount = Number(batch?.pendingCount ?? batch?.PendingCount ?? items.filter(x => val(x, 'verificationStatus') === 'Pending').length);

  async function load(next = query) {
    if (!labId) return;
    setLoading(true);
    try {
      const [grid, lookupData] = await Promise.all([
        denialWorkflowService.getDenialActionVerification({ ...next, labId }),
        denialWorkflowService.getDenialActionVerificationLookups(labId)
      ]);
      setData(grid);
      setLookups(lookupData || {});
      setSelected({});
      const batchId = next.batchId || '';
      setBatch(batchId ? await denialWorkflowService.getDenialActionVerificationBatch(labId, batchId) : (lookupData?.batches?.[0] || lookupData?.Batches?.[0] || null));
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Unable to load action change verification.' });
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { load(query); }, [labId, query.page, query.batchId, query.status, query.search, query.denialCode, query.icdComplianceStatus, query.coverageStatus, query.assignedTo]);

  function applyFilters() {
    setQuery({ ...draft, page: 1 });
  }

  function clearFilters() {
    const next = { ...blankQuery, batchId: '' };
    setDraft(next);
    setQuery(next);
  }

  async function runAction(action) {
    try {
      const result = await action();
      setMessage({ type: result?.success === false ? 'warning' : 'success', text: result?.message || 'Verification updated.' });
      await load(query);
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Verification action failed.' });
    }
  }

  function requestConfirm(plan) {
    setConfirmPlan(plan);
  }

  async function executeConfirmPlan() {
    const plan = confirmPlan;
    setConfirmPlan(null);
    if (!plan) return;
    await runAction(plan.action);
  }

  function exportRows() {
    window.location.href = denialWorkflowService.getDenialActionVerificationExportUrl({ ...query, labId });
  }

  return <section className="dcm-page action-verification-page">
    <div className="claim-view-top">
      <div><div className="claim-view-title">Denial Action Change Verification</div><div className="claim-view-subtitle">Review assigned open claims affected by Denial Code Master action changes</div></div>
      <div className="action-top-actions">
        <button className="wl-btn xs" onClick={exportRows}><i className="bi bi-file-earmark-excel" /> Export</button>
        <button className="wl-btn teal xs" disabled={!query.batchId || !pendingCount} onClick={() => requestConfirm({ count: pendingCount, action: () => denialWorkflowService.confirmAllDenialActionVerification(labId, query.batchId) })}>Confirm All</button>
      </div>
    </div>

    <div className="action-summary-grid">
      {[
        ['Source File', batch?.sourceFileName ?? batch?.SourceFileName ?? '-'],
        ['Affected Claims', batch?.totalAffectedClaims ?? batch?.TotalAffectedClaims ?? 0],
        ['Affected Tasks', batch?.totalAffectedTasks ?? batch?.TotalAffectedTasks ?? 0],
        ['Pending', batch?.pendingCount ?? batch?.PendingCount ?? 0],
        ['Confirmed', batch?.confirmedCount ?? batch?.ConfirmedCount ?? 0],
        ['Ignored', batch?.ignoredCount ?? batch?.IgnoredCount ?? 0]
      ].map(([label, value]) => <div className="action-summary-card" key={label}><span>{label}</span><strong>{value}</strong></div>)}
    </div>

    <div className="action-filter-grid">
      <label><span>Search</span><input value={draft.search} onChange={e => setDraft(x => ({ ...x, search: e.target.value }))} placeholder="ClaimID, TaskID, PatientId, PayerName, DenialCode" /></label>
      <label><span>Batch</span><select value={draft.batchId} onChange={e => setDraft(x => ({ ...x, batchId: e.target.value }))}><option value="">All batches</option>{(lookups.batches || lookups.Batches || []).map(b => <option key={b.batchId ?? b.BatchId} value={b.batchId ?? b.BatchId}>{b.batchId ?? b.BatchId} - {b.sourceFileName ?? b.SourceFileName}</option>)}</select></label>
      <label><span>DenialCode</span><select value={draft.denialCode} onChange={e => setDraft(x => ({ ...x, denialCode: e.target.value }))}><option value="">All</option>{(lookups.denialCodes || lookups.DenialCodes || []).map(x => <option key={x}>{x}</option>)}</select></label>
      <label><span>ICDComplianceStatus</span><select value={draft.icdComplianceStatus} onChange={e => setDraft(x => ({ ...x, icdComplianceStatus: e.target.value }))}><option value="">All</option>{(lookups.icdComplianceStatuses || lookups.ICDComplianceStatuses || []).map(x => <option key={x}>{x}</option>)}</select></label>
      <label><span>CoverageStatus</span><select value={draft.coverageStatus} onChange={e => setDraft(x => ({ ...x, coverageStatus: e.target.value }))}><option value="">All</option>{(lookups.coverageStatuses || lookups.CoverageStatuses || []).map(x => <option key={x}>{x}</option>)}</select></label>
      <label><span>AssignedTo</span><select value={draft.assignedTo} onChange={e => setDraft(x => ({ ...x, assignedTo: e.target.value }))}><option value="">All</option>{(lookups.assignedUsers || lookups.AssignedUsers || []).map(x => <option key={x}>{x}</option>)}</select></label>
      <label><span>Status</span><select value={draft.status} onChange={e => setDraft(x => ({ ...x, status: e.target.value }))}><option value="">All</option>{statuses.map(x => <option key={x}>{x}</option>)}</select></label>
      <button className="wl-btn xs teal" onClick={applyFilters}>Search</button>
      <button className="wl-btn xs" onClick={clearFilters}>Clear</button>
    </div>

    <div className="action-bulk-row">
      <button className="wl-btn xs" disabled={!selectedIds.length} onClick={() => requestConfirm({ count: selectedIds.length, action: () => denialWorkflowService.confirmSelectedDenialActionVerification(labId, selectedIds) })}>Confirm Selected</button>
      <span>{data.totalCount || 0} records</span>
    </div>

    {loading && <div className="loading-line" />}
    <div className="claim-assign-scroll action-table-wrap">
      <table className="lrn-table workflow-table action-verification-table">
        <thead><tr><th><input type="checkbox" checked={items.length > 0 && selectedIds.length === items.filter(x => val(x, 'verificationStatus') === 'Pending').length} onChange={e => {
          const next = {};
          if (e.target.checked) items.filter(x => val(x, 'verificationStatus') === 'Pending').forEach(x => { next[val(x, 'verificationId')] = true; });
          setSelected(next);
        }} /></th>{columns.map(([, label]) => <th key={label}>{label}</th>)}<th>Actions</th></tr></thead>
        <tbody>
          {items.length ? items.map(row => {
            const id = val(row, 'verificationId');
            const pending = val(row, 'verificationStatus') === 'Pending';
            return <tr key={id}>
              <td><input type="checkbox" disabled={!pending} checked={!!selected[id]} onChange={e => setSelected(s => ({ ...s, [id]: e.target.checked }))} /></td>
              {columns.map(([key]) => {
                let cls = '';
                if (key.startsWith('old') && changed(row, key, key.replace('old', 'new'))) cls = 'old-change';
                if (key.startsWith('new') && changed(row, key.replace('new', 'old'), key)) cls = 'new-change';
                return <td key={key} className={cls}>{key === 'createdOn' ? date(val(row, key)) : (val(row, key) || '-')}</td>;
              })}
              <td className="dcm-row-actions">
                <button className="wl-btn xs teal" disabled={!pending} onClick={() => requestConfirm({ count: 1, action: () => denialWorkflowService.confirmDenialActionVerification(labId, id) })}>Confirm</button>
                <button className="wl-btn xs" disabled={!pending} onClick={() => runAction(() => denialWorkflowService.ignoreDenialActionVerification(labId, id))}>Ignore</button>
              </td>
            </tr>;
          }) : <tr><td colSpan={columns.length + 2} className="empty-cell">No action change verification rows found.</td></tr>}
        </tbody>
      </table>
    </div>

    <div className="pager">
      <button className="wl-btn xs" disabled={(data.page || 1) <= 1} onClick={() => setQuery(q => ({ ...q, page: Math.max(1, (q.page || 1) - 1) }))}>Previous</button>
      <span>Page {data.page || 1} of {Math.max(1, totalPages)}</span>
      <button className="wl-btn xs" disabled={(data.page || 1) >= Math.max(1, totalPages)} onClick={() => setQuery(q => ({ ...q, page: (q.page || 1) + 1 }))}>Next</button>
    </div>
    {confirmPlan && <ConfirmActionModal count={confirmPlan.count} onCancel={() => setConfirmPlan(null)} onConfirm={executeConfirmPlan} />}
  </section>;
}
