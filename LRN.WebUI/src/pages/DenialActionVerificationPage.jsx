import React, { useEffect, useMemo, useState } from 'react';
import { denialWorkflowService } from '../services/denialWorkflowService';

const statuses = ['Pending', 'Confirmed', 'Ignored'];
const blankQuery = { search: '', batchId: '', denialCode: '', icdComplianceStatus: '', coverageStatus: '', assignedTo: '', status: 'Pending', page: 1, pageSize: 50 };

function val(row, key) {
  return row?.[key] ?? row?.[key[0].toUpperCase() + key.slice(1)] ?? '';
}

function date(value) {
  if (!value) return '-';
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? String(value) : d.toLocaleString();
}

function shortDate(value) {
  if (!value) return '-';
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? String(value) : d.toLocaleDateString();
}

function money(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n.toLocaleString(undefined, { style: 'currency', currency: 'USD' }) : '-';
}

function list(values) {
  return Array.from(values || []).filter(Boolean).join(', ') || '-';
}

function changed(row, oldKey, newKey) {
  return String(val(row, oldKey) || '').trim() !== String(val(row, newKey) || '').trim();
}

function uniqueKey(row) {
  return String(val(row, 'verificationId') || val(row, 'taskID') || val(row, 'taskId') || `${val(row, 'claimID')}-${val(row, 'denialCode')}-${val(row, 'oldActionCode')}-${val(row, 'newActionCode')}`);
}

function ConfirmActionModal({ plan, onCancel, onConfirm }) {
  return <div className="modal-backdrop">
    <div className="action-confirm-modal">
      <div className="claim-modal-header">
        <div>
          <div className="claim-modal-title">{plan?.mode === 'ignore' ? 'Ignore Action Change' : 'Approve Action Change'}</div>
          <div className="claim-view-subtitle">{plan?.scope || 'Selected'} level review</div>
        </div>
        <button type="button" className="modal-close" onClick={onCancel}><i className="bi bi-x-lg" /></button>
      </div>
      <div className="action-confirm-body">
        <p>You are about to {plan?.mode === 'ignore' ? 'ignore' : 'approve'} <strong>{plan?.count || 0}</strong> pending action change row(s).</p>
        {plan?.mode === 'approve' ? <p>Approval applies the new action code, action category, task, and short category to the selected assigned open task rows.</p> : <p>Ignored rows will stay unchanged and will be removed from the pending verification queue.</p>}
        <p>Do you want to continue?</p>
      </div>
      <div className="dcm-modal-actions">
        <button type="button" className="wl-btn" onClick={onCancel}>Cancel</button>
        <button type="button" className={`wl-btn ${plan?.mode === 'ignore' ? 'danger' : 'teal'}`} onClick={onConfirm}>{plan?.mode === 'ignore' ? 'Ignore' : 'Approve'}</button>
      </div>
    </div>
  </div>;
}

function ChangePair({ label, oldValue, newValue }) {
  const isChanged = String(oldValue || '').trim() !== String(newValue || '').trim();
  return <div className={`action-change-pair ${isChanged ? 'changed' : ''}`}>
    <span>{label}</span>
    <div><b>Old</b><strong>{oldValue || '-'}</strong></div>
    <div><b>New</b><strong>{newValue || '-'}</strong></div>
  </div>;
}

function HistoryPanel({ rows, loading }) {
  return <div className="action-history-panel">
    <div className="action-section-title">Claim History</div>
    {loading ? <div className="claim-empty-panel">Loading history...</div> : rows.length ? rows.map((h, index) => <article className="action-history-row" key={`${h.historyType || h.HistoryType}-${h.historyId || h.HistoryId}-${index}`}>
      <time>{date(h.actionDate || h.ActionDate || h.createdOn || h.CreatedOn)}</time>
      <div>
        <strong>{h.title || h.Title || h.actionType || h.ActionType || h.historyType || h.HistoryType || 'Workflow update'}</strong>
        <p>{h.description || h.Description || '-'}</p>
        <small>
          {(h.taskId || h.TaskId) ? `Task ${h.taskId || h.TaskId} · ` : ''}
          {(h.cptCode || h.CptCode) ? `CPT ${h.cptCode || h.CptCode} · ` : ''}
          {(h.oldAssignedTo || h.OldAssignedTo || h.newAssignedTo || h.NewAssignedTo) ? `Assigned: ${h.oldAssignedTo || h.OldAssignedTo || '-'} -> ${h.newAssignedTo || h.NewAssignedTo || '-'} · ` : ''}
          {(h.oldStatus || h.OldStatus || h.newStatus || h.NewStatus) ? `Status: ${h.oldStatus || h.OldStatus || '-'} -> ${h.newStatus || h.NewStatus || '-'} · ` : ''}
          {h.actionBy || h.ActionBy || h.createdBy || h.CreatedBy || '-'}
        </small>
      </div>
    </article>) : <div className="claim-empty-panel">No claim history found.</div>}
  </div>;
}

export default function DenialActionVerificationPage({ labId, setMessage, initialBatchId = '' }) {
  const [query, setQuery] = useState(() => ({ ...blankQuery, batchId: initialBatchId || '' }));
  const [draft, setDraft] = useState(() => ({ ...blankQuery, batchId: initialBatchId || '' }));
  const [data, setData] = useState({ items: [], totalCount: 0, totalPages: 0, page: 1 });
  const [lookups, setLookups] = useState({});
  const [batch, setBatch] = useState(null);
  const [drawerTab, setDrawerTab] = useState('tasks');
  const [claimSearch, setClaimSearch] = useState('');
  const [activeClaimId, setActiveClaimId] = useState('');
  const [activeTaskKey, setActiveTaskKey] = useState('');
  const [historyRows, setHistoryRows] = useState([]);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [loading, setLoading] = useState(false);
  const [confirmPlan, setConfirmPlan] = useState(null);

  const items = data.items || [];
  const totalPages = Number(data.totalPages || 0);
  const pendingItems = items.filter(x => val(x, 'verificationStatus') === 'Pending');
  const pendingCount = Number(batch?.pendingCount ?? batch?.PendingCount ?? pendingItems.length);

  const claimRows = useMemo(() => {
    const map = new Map();
    for (const row of items) {
      const claimId = String(val(row, 'claimID') || val(row, 'claimId') || '-');
      const existing = map.get(claimId) || {
        claimId,
        patientId: val(row, 'patientId'),
        payerName: val(row, 'payerName'),
        assignedTo: val(row, 'assignedTo'),
        claimStatus: val(row, 'claimStatus'),
        createdOn: val(row, 'createdOn'),
        denialCodes: new Set(),
        coverageStatuses: new Set(),
        icdStatuses: new Set(),
        oldActions: new Set(),
        newActions: new Set(),
        oldCategories: new Set(),
        newCategories: new Set(),
        oldTasks: new Set(),
        newTasks: new Set(),
        oldShortCategories: new Set(),
        newShortCategories: new Set(),
        statuses: new Set(),
        rows: []
      };
      existing.rows.push(row);
      if (val(row, 'denialCode')) existing.denialCodes.add(val(row, 'denialCode'));
      if (val(row, 'coverageStatus')) existing.coverageStatuses.add(val(row, 'coverageStatus'));
      if (val(row, 'icdComplianceStatus')) existing.icdStatuses.add(val(row, 'icdComplianceStatus'));
      if (val(row, 'oldActionCode')) existing.oldActions.add(val(row, 'oldActionCode'));
      if (val(row, 'newActionCode')) existing.newActions.add(val(row, 'newActionCode'));
      if (val(row, 'oldActionCategory')) existing.oldCategories.add(val(row, 'oldActionCategory'));
      if (val(row, 'newActionCategory')) existing.newCategories.add(val(row, 'newActionCategory'));
      if (val(row, 'oldTask')) existing.oldTasks.add(val(row, 'oldTask'));
      if (val(row, 'newTask')) existing.newTasks.add(val(row, 'newTask'));
      if (val(row, 'oldShortCategory')) existing.oldShortCategories.add(val(row, 'oldShortCategory'));
      if (val(row, 'newShortCategory')) existing.newShortCategories.add(val(row, 'newShortCategory'));
      if (val(row, 'verificationStatus')) existing.statuses.add(val(row, 'verificationStatus'));
      map.set(claimId, existing);
    }
    return Array.from(map.values()).map(row => ({
      ...row,
      pendingRows: row.rows.filter(x => val(x, 'verificationStatus') === 'Pending'),
      denialCodesText: list(row.denialCodes),
      coverageText: list(row.coverageStatuses),
      icdText: list(row.icdStatuses),
      oldActionsText: list(row.oldActions),
      newActionsText: list(row.newActions),
      oldCategoriesText: list(row.oldCategories),
      newCategoriesText: list(row.newCategories),
      oldTasksText: list(row.oldTasks),
      newTasksText: list(row.newTasks),
      oldShortCategoriesText: list(row.oldShortCategories),
      newShortCategoriesText: list(row.newShortCategories),
      statusText: list(row.statuses)
    }));
  }, [items]);

  const visibleClaimRows = useMemo(() => {
    const q = claimSearch.trim().toLowerCase();
    if (!q) return claimRows;
    return claimRows.filter(row => [
      row.claimId,
      row.patientId,
      row.payerName,
      row.assignedTo,
      row.denialCodesText,
      row.oldActionsText,
      row.newActionsText,
      row.oldTasksText,
      row.newTasksText
    ].some(value => String(value || '').toLowerCase().includes(q)));
  }, [claimRows, claimSearch]);

  const activeClaim = useMemo(() => visibleClaimRows.find(x => x.claimId === activeClaimId) || visibleClaimRows[0] || null, [visibleClaimRows, activeClaimId]);
  const activeTasks = activeClaim?.rows || [];
  const activeTask = useMemo(() => activeTasks.find(x => uniqueKey(x) === activeTaskKey) || activeTasks[0] || null, [activeTasks, activeTaskKey]);

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
      const batchId = next.batchId || '';
      setBatch(batchId ? await denialWorkflowService.getDenialActionVerificationBatch(labId, batchId) : (lookupData?.batches?.[0] || lookupData?.Batches?.[0] || null));
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Unable to load action change verification.' });
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { load(query); }, [labId, query.page, query.batchId, query.status, query.search, query.denialCode, query.icdComplianceStatus, query.coverageStatus, query.assignedTo]);

  useEffect(() => {
    if (!visibleClaimRows.length) {
      setActiveClaimId('');
      setActiveTaskKey('');
      return;
    }
    if (!visibleClaimRows.some(x => x.claimId === activeClaimId)) setActiveClaimId(visibleClaimRows[0].claimId);
  }, [visibleClaimRows, activeClaimId]);

  useEffect(() => {
    if (!activeTasks.length) {
      setActiveTaskKey('');
      return;
    }
    if (!activeTasks.some(x => uniqueKey(x) === activeTaskKey)) setActiveTaskKey(uniqueKey(activeTasks[0]));
  }, [activeTasks, activeTaskKey]);

  useEffect(() => {
    let cancelled = false;
    async function loadHistory() {
      if (!labId || !activeClaim?.claimId) {
        setHistoryRows([]);
        return;
      }
      setHistoryLoading(true);
      try {
        const rows = await denialWorkflowService.getClaimHistory({ labId, claimId: activeClaim.claimId, historyLevel: 'Claim' });
        if (!cancelled) setHistoryRows(rows || []);
      } catch {
        if (!cancelled) setHistoryRows([]);
      } finally {
        if (!cancelled) setHistoryLoading(false);
      }
    }
    loadHistory();
    return () => { cancelled = true; };
  }, [labId, activeClaim?.claimId]);

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

  function requestApproveClaim() {
    const ids = (activeClaim?.pendingRows || []).map(x => Number(val(x, 'verificationId'))).filter(Boolean);
    if (!ids.length) return;
    setConfirmPlan({ mode: 'approve', scope: 'Claim', count: ids.length, action: () => denialWorkflowService.confirmSelectedDenialActionVerification(labId, ids) });
  }

  function requestIgnoreClaim() {
    const ids = (activeClaim?.pendingRows || []).map(x => val(x, 'verificationId')).filter(Boolean);
    if (!ids.length) return;
    setConfirmPlan({ mode: 'ignore', scope: 'Claim', count: ids.length, action: async () => {
      const results = await Promise.all(ids.map(id => denialWorkflowService.ignoreDenialActionVerification(labId, id)));
      return results[results.length - 1] || { success: true, message: 'Claim action changes ignored.' };
    } });
  }

  function requestApproveTask(row = activeTask) {
    const id = val(row, 'verificationId');
    if (!id) return;
    setConfirmPlan({ mode: 'approve', scope: 'Task', count: 1, action: () => denialWorkflowService.confirmDenialActionVerification(labId, id) });
  }

  function requestIgnoreTask(row = activeTask) {
    const id = val(row, 'verificationId');
    if (!id) return;
    setConfirmPlan({ mode: 'ignore', scope: 'Task', count: 1, action: () => denialWorkflowService.ignoreDenialActionVerification(labId, id) });
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

  const activePending = activeClaim?.pendingRows?.length || 0;

  return <section className="dcm-page action-verification-page action-split-page">
    <div className="action-summary-grid">
      {[
        ['Affected Claims', batch?.totalAffectedClaims ?? batch?.TotalAffectedClaims ?? claimRows.length, 'Batch-wide Scope'],
        ['Affected Tasks', batch?.totalAffectedTasks ?? batch?.TotalAffectedTasks ?? items.length, 'Assigned Open Items'],
        ['Pending Review', batch?.pendingCount ?? batch?.PendingCount ?? pendingItems.length, 'Decisions Required'],
        ['Approved', batch?.confirmedCount ?? batch?.ConfirmedCount ?? 0, 'Changes Applied'],
        ['Ignored', batch?.ignoredCount ?? batch?.IgnoredCount ?? 0, 'Tasks Unchanged']
      ].map(([label, value, subtitle]) => <div className={`action-summary-card ${label === 'Pending Review' ? 'pending' : ''}`} key={label}><span>{label}</span><strong>{value}</strong><small>{subtitle}</small></div>)}
    </div>

    <div className="action-filter-grid">
      <label><span>Search Parameters</span><input value={draft.search} onChange={e => setDraft(x => ({ ...x, search: e.target.value }))} onKeyDown={e => { if (e.key === 'Enter') applyFilters(); }} placeholder="Claim ID, Task ID, Patient Name, Denial" /></label>
      <label><span>Batch Assignment</span><select value={draft.batchId} onChange={e => setDraft(x => ({ ...x, batchId: e.target.value }))}><option value="">All batches</option>{(lookups.batches || lookups.Batches || []).map(b => <option key={b.batchId ?? b.BatchId} value={b.batchId ?? b.BatchId}>ACV-{b.batchId ?? b.BatchId}</option>)}</select></label>
      <label><span>Denial Code</span><select value={draft.denialCode} onChange={e => setDraft(x => ({ ...x, denialCode: e.target.value }))}><option value="">All Codes</option>{(lookups.denialCodes || lookups.DenialCodes || []).map(x => <option key={x}>{x}</option>)}</select></label>
      <label><span>ICD Compliance Status</span><select value={draft.icdComplianceStatus} onChange={e => setDraft(x => ({ ...x, icdComplianceStatus: e.target.value }))}><option value="">All Statuses</option>{(lookups.icdComplianceStatuses || lookups.ICDComplianceStatuses || []).map(x => <option key={x}>{x}</option>)}</select></label>
      <label><span>Coverage Status</span><select value={draft.coverageStatus} onChange={e => setDraft(x => ({ ...x, coverageStatus: e.target.value }))}><option value="">All Statuses</option>{(lookups.coverageStatuses || lookups.CoverageStatuses || []).map(x => <option key={x}>{x}</option>)}</select></label>
      <label><span>Assigned To</span><select value={draft.assignedTo} onChange={e => setDraft(x => ({ ...x, assignedTo: e.target.value }))}><option value="">All Reviewers</option>{(lookups.assignedUsers || lookups.AssignedUsers || []).map(x => <option key={x}>{x}</option>)}</select></label>
      <label><span>Verification Status</span><select value={draft.status} onChange={e => setDraft(x => ({ ...x, status: e.target.value }))}><option value="">All</option>{statuses.map(x => <option key={x}>{x}</option>)}</select></label>
      <button className="wl-btn xs teal" onClick={applyFilters}>Search</button>
      <button className="wl-btn xs action-export-btn" onClick={exportRows}><i className="bi bi-file-earmark-arrow-down" /> Export Filtered</button>
      <button className="wl-btn xs" onClick={clearFilters}>Clear</button>
    </div>

    {loading && <div className="loading-line" />}

    <div className={`claim-split-shell drawer-open action-review-shell`}>
      <aside className="action-claim-pane">
        <div className="action-pane-head">Grouped Affected Claims</div>
        <div className="action-pane-search">
          <input value={claimSearch} onChange={e => setClaimSearch(e.target.value)} placeholder="Filter local claim results..." />
        </div>
        <div className="action-claim-list">
          {visibleClaimRows.length ? visibleClaimRows.map(row => <button type="button" key={row.claimId} className={`action-claim-card ${activeClaim?.claimId === row.claimId ? 'active' : ''}`} onClick={() => { setActiveClaimId(row.claimId); setDrawerTab('tasks'); }}>
            <span className="action-claim-card-top">
              <b>{row.claimId}</b>
              <em>{row.pendingRows.length ? `${row.pendingRows.length} Pending` : row.statusText}</em>
            </span>
            <span className="action-claim-card-meta">
              Patient {row.patientId || '-'} | {row.payerName || '-'}<br />
              Assigned: {row.assignedTo || '-'} | Code: {row.denialCodesText}
            </span>
          </button>) : <div className="claim-empty-panel">No action change claims found.</div>}
        </div>
      </aside>

      <section className="action-detail-card">
        {activeClaim ? <>
          <div className="action-detail-head">
            <div>
              <h3>Claim Level Review: <button type="button" className="action-claim-title-link">{activeClaim.claimId}</button></h3>
              <div className="action-info-badges">
                <span className="blue">{activeClaim.payerName || '-'}</span>
                <span>Patient: {activeClaim.patientId || '-'}</span>
                <span className="amber">{activeClaim.rows.length} affected tasks</span>
                <span>User: {activeClaim.assignedTo || '-'}</span>
                <span>Status: {activeClaim.claimStatus || '-'}</span>
                <span>ICD: {activeClaim.icdText}</span>
                <span>Coverage: {activeClaim.coverageText}</span>
              </div>
              <p>{activeClaim.payerName || '-'} · Patient {activeClaim.patientId || '-'} · {activeClaim.rows.length} affected task(s)</p>
            </div>
            <div className="action-review-buttons">
              <button className="wl-btn teal xs" disabled={!activePending} onClick={requestApproveClaim}>Approve Claim</button>
              <button className="wl-btn danger xs" disabled={!activePending} onClick={requestIgnoreClaim}>Ignore Claim</button>
            </div>
          </div>

          <div className="claim-drawer-meta compact">
            <span><b>Assigned</b>{activeClaim.assignedTo || '-'}</span>
            <span><b>Claim Status</b>{activeClaim.claimStatus || '-'}</span>
            <span><b>Denial Codes</b>{activeClaim.denialCodesText}</span>
            <span><b>ICD Status</b>{activeClaim.icdText}</span>
            <span><b>Coverage</b>{activeClaim.coverageText}</span>
          </div>

          <div className="action-change-summary">
            <ChangePair label="Action Code" oldValue={activeClaim.oldActionsText} newValue={activeClaim.newActionsText} />
            <ChangePair label="Action Category" oldValue={activeClaim.oldCategoriesText} newValue={activeClaim.newCategoriesText} />
            <ChangePair label="Task" oldValue={activeClaim.oldTasksText} newValue={activeClaim.newTasksText} />
            <ChangePair label="Short Category" oldValue={activeClaim.oldShortCategoriesText} newValue={activeClaim.newShortCategoriesText} />
          </div>

          <div className="claim-drawer-tabs action-single-tabs">
            <button type="button" className={drawerTab === 'tasks' ? 'active' : ''} onClick={() => setDrawerTab('tasks')}>Tasks ({activeTasks.length})</button>
            <button type="button" className={drawerTab === 'history' ? 'active' : ''} onClick={() => setDrawerTab('history')}>History ({historyRows.length})</button>
          </div>

          <div className="claim-drawer-body">
            {drawerTab === 'tasks' ? <div className="action-task-split">
              <div className="action-section-title">Task Split</div>
              <div className="action-task-scroll">
                <table className="claim-task-table action-task-table full-task-columns thin-bordered">
                  <thead><tr>
                    <th>TaskID</th><th>CPTCode</th><th>Units</th><th>Modifier</th><th>DenialCode</th><th>DenialDescription</th><th>DenialClassification</th>
                    <th>ActionCode</th><th>ActionCategory</th><th>RecommendedAction</th><th>Priority</th><th className="r">InsuranceBalance</th><th>SLADays</th>
                    <th>Status</th><th>DateOpened</th><th>DueDate</th><th>SLAStatus</th><th>FirstBilledDate</th><th>ChargeEnteredDate</th><th>ICDComplianceStatus</th><th>DenialValidity</th>
                    <th>CoverageStatus</th><th>AssignedTo</th><th>ClaimStatus</th>
                    <th>OldActionCode</th><th>NewActionCode</th><th>OldActionCategory</th><th>NewActionCategory</th><th>OldTask</th><th>NewTask</th><th>OldShortCategory</th><th>NewShortCategory</th>
                    <th>VerificationStatus</th><th>Approve / Ignore</th>
                  </tr></thead>
                  <tbody>{activeTasks.map(row => {
                    const rowKey = uniqueKey(row);
                    const pending = val(row, 'verificationStatus') === 'Pending';
                    return <tr key={rowKey} className={activeTask && uniqueKey(activeTask) === rowKey ? 'active-task-row' : ''} onClick={() => { setActiveTaskKey(rowKey); setDrawerTab('tasks'); }}>
                      <td><strong>{val(row, 'taskID') || '-'}</strong></td>
                      <td><code className="code">{val(row, 'cptCode') || val(row, 'CPTCode') || '-'}</code></td>
                      <td>{val(row, 'units') ?? '-'}</td>
                      <td>{val(row, 'modifier') || '-'}</td>
                      <td><code className="code">{val(row, 'denialCode') || '-'}</code></td>
                      <td className="wrap-wide">{val(row, 'denialDescription') || '-'}</td>
                      <td>{val(row, 'denialClassification') || '-'}</td>
                      <td>{val(row, 'actionCode') || val(row, 'oldActionCode') || '-'}</td>
                      <td>{val(row, 'actionCategory') || val(row, 'oldActionCategory') || '-'}</td>
                      <td className="wrap-wide">{val(row, 'recommendedAction') || '-'}</td>
                      <td>{val(row, 'priority') || '-'}</td>
                      <td className="r">{money(val(row, 'insuranceBalance'))}</td>
                      <td>{val(row, 'slaDays') ?? val(row, 'SLADays') ?? '-'}</td>
                      <td><span className="badge badge-verification">{val(row, 'status') || '-'}</span></td>
                      <td>{shortDate(val(row, 'dateOpened'))}</td>
                      <td>{shortDate(val(row, 'dueDate'))}</td>
                      <td><span className="badge badge-verification">{val(row, 'slaStatus') || '-'}</span></td>
                      <td>{shortDate(val(row, 'firstBilledDate'))}</td>
                      <td>{shortDate(val(row, 'chargeEnteredDate'))}</td>
                      <td>{val(row, 'icdComplianceStatus') || '-'}</td>
                      <td>{val(row, 'denialValidity') || '-'}</td>
                      <td>{val(row, 'coverageStatus') || '-'}</td>
                      <td>{val(row, 'assignedTo') || '-'}</td>
                      <td>{val(row, 'claimStatus') || '-'}</td>
                      <td className={changed(row, 'oldActionCode', 'newActionCode') ? 'old-change action-change-cell' : ''}>{val(row, 'oldActionCode') || '-'}</td>
                      <td className={changed(row, 'oldActionCode', 'newActionCode') ? 'new-change action-change-cell' : ''}>{val(row, 'newActionCode') || '-'}</td>
                      <td className={changed(row, 'oldActionCategory', 'newActionCategory') ? 'old-change action-change-cell' : ''}>{val(row, 'oldActionCategory') || '-'}</td>
                      <td className={changed(row, 'oldActionCategory', 'newActionCategory') ? 'new-change action-change-cell' : ''}>{val(row, 'newActionCategory') || '-'}</td>
                      <td className={changed(row, 'oldTask', 'newTask') ? 'old-change action-change-cell' : ''}>{val(row, 'oldTask') || '-'}</td>
                      <td className={changed(row, 'oldTask', 'newTask') ? 'new-change action-change-cell' : ''}>{val(row, 'newTask') || '-'}</td>
                      <td className={changed(row, 'oldShortCategory', 'newShortCategory') ? 'old-change action-change-cell' : ''}>{val(row, 'oldShortCategory') || '-'}</td>
                      <td className={changed(row, 'oldShortCategory', 'newShortCategory') ? 'new-change action-change-cell' : ''}>{val(row, 'newShortCategory') || '-'}</td>
                      <td><span className="badge badge-verification">{val(row, 'verificationStatus') || '-'}</span></td>
                      <td>
                        <div className="dcm-row-actions">
                          <button type="button" className="wl-btn teal xs" disabled={!pending} onClick={e => { e.stopPropagation(); requestApproveTask(row); }}>Approve</button>
                          <button type="button" className="wl-btn danger xs" disabled={!pending} onClick={e => { e.stopPropagation(); requestIgnoreTask(row); }}>Ignore</button>
                        </div>
                      </td>
                    </tr>;
                  })}</tbody>
                </table>
              </div>
            </div> : <HistoryPanel rows={historyRows} loading={historyLoading} />}
          </div>
        </> : <div className="claim-empty-panel">Select a claim to review action changes.</div>}
      </section>
    </div>

    <div className="pager">
      <button className="wl-btn xs" disabled={(data.page || 1) <= 1} onClick={() => setQuery(q => ({ ...q, page: Math.max(1, (q.page || 1) - 1) }))}>Previous</button>
      <span>Page {data.page || 1} of {Math.max(1, totalPages)}</span>
      <button className="wl-btn xs" disabled={(data.page || 1) >= Math.max(1, totalPages)} onClick={() => setQuery(q => ({ ...q, page: (q.page || 1) + 1 }))}>Next</button>
    </div>
    {confirmPlan && <ConfirmActionModal plan={confirmPlan} onCancel={() => setConfirmPlan(null)} onConfirm={executeConfirmPlan} />}
  </section>;
}
