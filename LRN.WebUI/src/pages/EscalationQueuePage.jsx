import React, { useEffect, useMemo, useState } from 'react';
import { denialWorkflowService } from '../services/denialWorkflowService';
import Pager from '../components/Pager';
import ClaimHistoryModal from '../components/ClaimHistoryModal';
import { money, date, initials, statusClass } from '../utils/formatters';
import { canDeleteClaimDocument } from '../utils/documentPermissions';
import { MAX_TEXT_LENGTH, limitText, textCountLabel } from '../utils/textLimits';
import { getQueuesForRole } from '../config/workflowRoleQueues';

const resolutionActions = [
  { value: '', label: '— Select resolution action —' },
  { value: 'approve', label: 'Approve & close escalation' },
  { value: 'rework', label: 'Return for rework' },
  { value: 'writeoff', label: 'Approve write-off' },
  { value: 'others', label: 'Others' }
];
const writeOffDecisionActions = [
  { value: '', label: 'Select write-off decision' },
  { value: 'approveWriteOff', label: 'Approve Write Off' },
  { value: 'rejectWriteOff', label: 'Reject Write Off' }
];

const recommendedNextActions = ['Proceed with Appeal', 'Proceed with Rebill', 'Proceed with Write-Off Request', 'Perform Payer Follow-up', 'Request Documentation', 'Additional Information Needed', 'No Further Action Required', 'Close Claim / Line', 'Other'];

function normalizeRole(value) {
  return String(value || '').replace(/[^a-z0-9]/gi, '').toLowerCase();
}

function isArReviewerOption(r) {
  const role = normalizeRole(r?.role || r?.Role);
  return !role || role.includes('arreviewer') || role.includes('analyst') || role.includes('analyser') || (role.includes('reviewer') && !role.includes('manager'));
}

function isManagerOption(r) {
  const role = normalizeRole(r?.role || r?.Role);
  return role.includes('clientmanager') || role.includes('accountmanager');
}

function canAssignFromRole(role) {
  const normalized = normalizeRole(role);
  return normalized.includes('admin') || normalized.includes('armanager');
}


function distinctHistoryRows(rows = []) {
  const seen = new Set();
  return (rows || []).filter((x) => {
    const type = String(x.historyType || x.HistoryType || '').trim().toLowerCase();
    const action = String(x.actionType || x.ActionType || '').trim().toLowerCase();
    const title = String(x.title || x.Title || '').trim().toLowerCase();
    const desc = String(x.description || x.Description || '').trim().toLowerCase();
    const status = String(x.newStatus || x.NewStatus || '').trim().toLowerCase();
    const assigned = String(x.newAssignedTo || x.NewAssignedTo || '').trim().toLowerCase();
    const by = String(x.actionBy || x.ActionBy || x.createdBy || x.CreatedBy || '').trim().toLowerCase();
    const rawDate = x.actionDate || x.ActionDate || x.createdOn || x.CreatedOn || '';
    const dateKey = rawDate ? new Date(rawDate).toISOString().slice(0, 19) : '';
    const key = [type, action, title, desc, status, assigned, by, dateKey].join('|');
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function ageText(value) {
  if (!value) return '-';
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return date(value);
  const days = Math.floor((Date.now() - d.getTime()) / 86400000);
  if (days <= 0) return 'Today';
  if (days === 1) return '1 day ago';
  return `${days} days ago`;
}

function slaBadge(row) {
  const status = String(row.slaStatus || '').trim();
  const days = row.daysRemaining;
  const over = status.toLowerCase().includes('over') || Number(days) < 0;
  const warn = status.toLowerCase().includes('risk') || Number(days) <= 2;
  const label = over ? `${Math.abs(Number(days || 0)) || 1}d over SLA` : warn ? `${days ?? 0}d left` : (status || 'On track');
  return <span className={`badge ${over ? 'badge-escalated' : warn ? 'badge-med' : 'badge-closed'}`}>{label}</span>;
}

export default function EscalationQueuePage({ labId, user, reviewers = [], taskView = 'claim', responseOnly = false, setTaskView = () => {}, tabCounts = {}, onClaimTabChange = () => {}, canAssign = false, assignClaims = () => {}, setMessage = () => {} }) {
  const [data, setData] = useState({ items: [], page: 1, pageSize: 100, totalCount: 0, totalPages: 0 });
  const [page, setPage] = useState(1);
  const [status, setStatus] = useState('');
  const [searchText, setSearchText] = useState('');
  const [activeRow, setActiveRow] = useState(null);
  const [drawerRow, setDrawerRow] = useState(null);
  const [modalError, setModalError] = useState('');
  const [lineTasks, setLineTasks] = useState([]);
  const [lineTasksBusy, setLineTasksBusy] = useState(false);
  const [historyCtx, setHistoryCtx] = useState(null);
  const [historyRows, setHistoryRows] = useState([]);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [drafts, setDrafts] = useState({});
  const [busy, setBusy] = useState(false);
  const [responseFiles, setResponseFiles] = useState([]);
  const [responseDocs, setResponseDocs] = useState([]);
  const [selectedClaims, setSelectedClaims] = useState({});
  const [bulkReviewer, setBulkReviewer] = useState('');
  const level = taskView === 'line' ? 'Line' : 'Claim';
  const claimTabs = [...getQueuesForRole(user?.role).map(t => t.key === 'escalationResponse' ? { ...t, countKey: 'escalationResponse' } : t), { key: 'verification', label: 'Verification Claim' }];
  const tabCountText = value => {
    if (value === null || value === undefined) return '...';
    const n = Number(value || 0);
    return n > 99999 ? `${Math.round(n / 1000)}k` : n.toLocaleString();
  };

  const query = useMemo(() => ({
    labId,
    role: user?.role || '',
    userName: user?.userName || '',
    status,
    searchText,
    taskView: responseOnly ? 'response' : '',
    page,
    pageSize: 100
  }), [labId, user, status, searchText, responseOnly, page]);

  async function load() {
    if (!labId) return;
    setBusy(true);
    try {
      const result = await denialWorkflowService.getEscalationQueue(query, level);
      setData({ items: result?.items || [], page: result?.page || page, pageSize: result?.pageSize || 100, totalCount: result?.totalCount || 0, totalPages: result?.totalPages || 0 });
    } catch (e) {
      setMessage({ type: 'danger', text: e.message || 'Escalation queue load failed.' });
    } finally {
      setBusy(false);
    }
  }

  useEffect(() => { load(); }, [query, level]);
  useEffect(() => { setPage(1); closeModal(); }, [level, status, searchText]);

  const rows = data.items || [];
  const arReviewers = useMemo(() => (reviewers || []).filter(isArReviewerOption), [reviewers]);
  const selectedClaimIds = useMemo(() => rows.filter((_, i) => selectedClaims[i]).map(r => String(r.claimId || '').trim()).filter(Boolean), [rows, selectedClaims]);
  const allSelected = canAssign && rows.length > 0 && rows.every((_, i) => selectedClaims[i]);
  const kpi = useMemo(() => ({
    total: data.totalCount || rows.length,
    pending: rows.filter(x => !['resolved', 'closed', 'returned for rework'].includes(String(x.status || '').toLowerCase())).length,
    breached: rows.filter(x => String(x.slaStatus || '').toLowerCase().includes('over') || Number(x.daysRemaining) < 0).length,
    amount: rows.reduce((a, b) => a + Number(b.insuranceBalance || 0), 0)
  }), [rows, data.totalCount]);

  function setDraft(id, patch) {
    setDrafts(prev => ({ ...prev, [id]: { responseNote: '', resolutionAction: '', reassignTo: '', otherReason: '', ...(prev[id] || {}), ...patch } }));
  }

  function closeModal() {
    setActiveRow(null);
    setModalError('');
    setResponseDocs([]);
    setResponseFiles([]);
  }

  function clearRowContext() {
    setLineTasks([]);
    setResponseFiles([]);
    setLineTasksBusy(false);
  }

  async function loadRowContext(row) {
    setModalError('');
    setLineTasks([]);
    setResponseDocs([]);
    if (!row?.claimId) return;
    setLineTasksBusy(true);
    try {
      const [taskRows, docs] = await Promise.all([
        denialWorkflowService.getClaimTasks(labId, row.claimId, level === 'Line' ? 'assigned' : ''),
        denialWorkflowService.getClaimDocuments(labId, row.claimId)
      ]);
      setLineTasks(taskRows || []);
      setResponseDocs(docs || []);
    } catch (e) {
      setLineTasks([]);
      setMessage({ type: 'warning', text: e.message || 'Unable to load claim line tasks.' });
    } finally {
      setLineTasksBusy(false);
    }
  }

  async function openDrawer(row) {
    setDrawerRow(row);
    await loadRowContext(row);
  }

  async function openModal(row) {
    setActiveRow(row);
    await loadRowContext(row);
  }

  async function openHistory(row, task) {
    const claimId = row?.claimId || task?.claimId || '';
    if (!claimId) return;
    const lineMode = !!task || level === 'Line';
    const taskId = task?.taskId || (lineMode ? row?.taskId : '') || '';
    const cptCode = task?.cptCode || (lineMode ? row?.cptCode : '') || '';
    setHistoryCtx({ title: `${lineMode ? 'Line' : 'Claim'} History — ${claimId}${cptCode ? ' / CPT ' + cptCode : ''}`, subtitle: 'Complete history visible to all workflow users.' });
    setHistoryRows([]);
    setHistoryLoading(true);
    try {
      const rows = await denialWorkflowService.getClaimHistory({ labId, claimId, taskId, cptCode, historyLevel: lineMode ? 'Line' : 'Claim' });
      setHistoryRows(distinctHistoryRows(rows || []));
    } catch (e) {
      setMessage({ type: 'warning', text: e.message || 'Unable to load claim history.' });
    } finally {
      setHistoryLoading(false);
    }
  }

  async function resolve(row, forcedAction = '', setInlineError = null) {
    const draft = drafts[row.escalationId] || {};
    const action = forcedAction || draft.resolutionAction || '';
    const canReassign = canAssignFromRole(user?.role);
    const writeOffDecision = ['approveWriteOff', 'rejectWriteOff'].includes(action);
    const shouldReassign = canReassign && !['approve', 'writeoff', 'approveWriteOff'].includes(action);
    const fail = (text) => { if (setInlineError) setInlineError(text); else setModalError(text); return false; };
    if (!action) return fail('Please select resolution action.');
    if (action === 'others' && !String(draft.otherReason || '').trim()) return fail('Please enter other response reason.');
    if (!writeOffDecision && !String(draft.recommendedNextAction || '').trim()) return fail('Please select recommended next action.');
    if (!String(draft.responseNote || '').trim()) return fail('Please add manager response note.');

    if (setInlineError) setInlineError('');
    setModalError('');
    setBusy(true);
    try {
      if (responseFiles?.length) {
        await denialWorkflowService.uploadClaimDocuments(labId, row.claimId, `Escalation response upload: ${draft.responseNote || ''}`, user?.userName || 'ReactWorkflow', responseFiles);
        setResponseDocs(await denialWorkflowService.getClaimDocuments(labId, row.claimId) || []);
        setResponseFiles([]);
      }
      const finalResponseNote = action === 'others' ? `Other Reason: ${String(draft.otherReason || '').trim()}\n${draft.responseNote}` : draft.responseNote;
      const result = await denialWorkflowService.resolveEscalation({
        labId,
        escalationId: row.escalationId,
        claimId: row.claimId,
        taskId: row.taskId || '',
        cptCode: row.cptCode || '',
        escalationLevel: row.escalationLevel || level,
        resolutionAction: action,
        recommendedNextAction: draft.recommendedNextAction || (action === 'approveWriteOff' ? 'Write-off approved' : action === 'rejectWriteOff' ? 'Write-off rejected' : action === 'approve' || action === 'writeoff' ? 'Close Claim / Line' : 'Additional Information Needed'),
        responseNote: finalResponseNote,
        reassignTo: shouldReassign ? (draft.reassignTo || '') : '',
        actionBy: user?.userName || 'ReactWorkflow'
      });
      setMessage({ type: result?.success ? 'success' : 'warning', text: result?.message || 'Escalation response saved.' });
      closeModal();
      await load();
    } catch (e) {
      fail(e.message || 'Escalation response failed.');
    } finally {
      setBusy(false);
    }
  }

  async function openDocument(documentId) {
    const url = await denialWorkflowService.getClaimDocumentDownloadUrl(labId, documentId);
    window.open(url, '_blank', 'noopener,noreferrer');
  }

  async function deleteDocument(documentId, row = activeRow || drawerRow) {
    if (!documentId || !row?.claimId) return;
    if (!canDeleteClaimDocument(row, { busy, taskView: responseOnly ? 'response' : taskView })) return setMessage({ type: 'warning', text: 'Documents can be deleted only while the claim is still in the active editable stage.' });
    if (!window.confirm('Delete this uploaded document?')) return;
    setBusy(true);
    try {
      await denialWorkflowService.deleteClaimDocument(labId, documentId);
      const docs = await denialWorkflowService.getClaimDocuments(labId, row.claimId);
      setResponseDocs(docs || []);
      setMessage({ type: 'success', text: 'Document deleted.' });
    } catch (e) {
      setMessage({ type: 'danger', text: e.message || 'Unable to delete document.' });
    } finally {
      setBusy(false);
    }
  }

  function renderEscalationClaimSplit() {
    return <>
      <div className={`claim-split-shell ${drawerRow ? 'drawer-open' : ''}`}>
        <section className={`claim-list-pane ${drawerRow ? 'narrow' : 'full'}`}>
          <div className="claim-view-top">
            <div>
              <div className="claim-view-title">Escalation queue - {level} level</div>
              <div className="claim-view-subtitle">Click a claim to view line-level tasks.</div>
            </div>
            <span className="table-count">{busy ? 'Loading...' : `Showing ${rows.length} of ${data.totalCount || 0}`}</span>
          </div>
          <div className="claim-list-head claim-list-head-wide"><span>Claim</span><span>Source</span><span>Payer Name</span><span>Patient Name</span><span>Patient ID</span><span>Subscriber ID</span><span>DOS</span><span>Balance</span><span>Status</span></div>
          <div className="claim-rows-scroll">{rows.length ? rows.map(row => {
            const isOpen = drawerRow?.escalationId === row.escalationId;
            return <div key={row.escalationId} className={`claim-list-row claim-list-row-wide ${isOpen ? 'active' : ''}`}>
              <span className="claim-row-check my-worklist-spacer" aria-hidden="true" />
              <span className="claim-expand-dot"><i className={`bi ${isOpen ? 'bi-chevron-down' : 'bi-chevron-right'}`} /></span>
              <span className="claim-list-id"><button className="claim-id-link" type="button" onClick={() => openDrawer(row)}>{row.claimId || '-'}</button><small>{row.analyst || row.createdBy || '-'} - {row.escalationReason || '-'}</small><button type="button" className="wl-btn xs teal esc-review-inline" onClick={() => openModal(row)}>Review</button></span>
              <span className="claim-list-payer" title={row.source || ''}>{row.source || '-'}</span>
              <span className="claim-list-payer" title={row.payerName || ''}>{row.payerName || '-'}</span>
              <span className="claim-list-payer" title={row.patientName || ''}>{row.patientName || '-'}</span>
              <span className="claim-list-payer" title={row.patientId || ''}>{row.patientId || '-'}</span>
              <span className="claim-list-payer" title={row.subscriberId || ''}>{row.subscriberId || '-'}</span>
              <span className="claim-list-payer">{date(row.dateOfService) || '-'}</span>
              <span className="claim-list-amt">{money(row.insuranceBalance)}</span>
              <span className="claim-list-status"><span className={`badge ${statusClass(row.status)}`}>{row.status || 'Open'}</span></span>
            </div>;
          }) : <div className="claim-empty-panel">No escalations found.</div>}</div>
        </section>
        {drawerRow && <section className="claim-drawer open">
          <div className="claim-drawer-header"><div><div className="claim-drawer-kicker">Escalation Queue / Task View</div><h3>{drawerRow.claimId || '-'}</h3><p>{drawerRow.payerName || '-'} - {drawerRow.patientName || '-'} - {money(drawerRow.insuranceBalance)}</p></div><button className="wl-icon" title="Close claim drawer" type="button" onClick={() => { setDrawerRow(null); clearRowContext(); }}><i className="bi bi-x-lg" /></button></div>
          <div className="claim-drawer-meta"><span><b>Source</b>{drawerRow.source || '-'}</span><span><b>Reason</b>{drawerRow.escalationReason || '-'}</span><span><b>Analyst</b>{drawerRow.analyst || drawerRow.createdBy || '-'}</span><span><b>DOS</b>{date(drawerRow.dateOfService)}</span><span><b>Follow-up</b>{date(drawerRow.nextFollowUpDate)}</span><span><b>Status</b>{drawerRow.status || 'Open'}</span></div>
          <div className="claim-drawer-actions"><button className="wl-btn teal xs" type="button" onClick={() => openModal(drawerRow)}>Review</button></div>
          <div className="claim-drawer-tabs"><button className="active" type="button">Tasks ({lineTasks.length})</button></div>
          <div className="claim-drawer-body"><LineTasksTable row={drawerRow} tasks={lineTasks} busy={lineTasksBusy} compact hideHistory /></div>
        </section>}
      </div>
      <Pager data={data} changePage={next => { closeModal(); setDrawerRow(null); clearRowContext(); setPage(next); }} />
    </>;
  }

  if (responseOnly) {
    return <div className="esc-page">
      <div className={`claim-split-shell ${drawerRow ? 'drawer-open' : ''}`}>
        <section className={`claim-list-pane thin-list-border ${drawerRow ? 'narrow' : 'full'}`}>
          <div className="claim-view-top">
            <div>
              <div className="claim-view-title">Claim Level Assignment</div>
              <div className="claim-view-subtitle">Escalation Response claims - {rows.length} of {data.totalCount || 0}</div>
            </div>
            <span className="table-count">{busy ? 'Loading...' : 'Escalation Response'}</span>
          </div>
          <div className="claim-list-toolbar">
            <label className="claim-search-wrap"><i className="bi bi-search" /><input value={searchText} onChange={e => setSearchText(e.target.value)} placeholder="Search claim, payer, patient" /></label>
            <div className="claim-tab-row">{claimTabs.map(t => <button key={t.key} type="button" className={`claim-tab ${responseOnly && t.key === 'escalationResponse' ? 'active' : ''}`} onClick={() => onClaimTabChange(t.key)}><span>{t.label}</span><b>{tabCountText(tabCounts?.[t.countKey || t.key])}</b></button>)}</div>
          </div>
          {canAssign && <div className="claim-assign-bar2"><label><input type="checkbox" checked={allSelected} onChange={e => { const next = {}; if (e.target.checked) rows.forEach((_, i) => next[i] = true); setSelectedClaims(next); }} /> Select page</label><strong>{selectedClaimIds.length} selected</strong><select value={bulkReviewer} onChange={e => setBulkReviewer(e.target.value)}><option value="">Select AR Reviewer</option>{arReviewers.map(r => <option key={r.userName || r.UserName} value={r.userName || r.UserName}>{r.displayName || r.DisplayName || r.userName || r.UserName}</option>)}</select><button className="wl-btn teal xs" type="button" disabled={!selectedClaimIds.length} onClick={() => assignClaims(selectedClaimIds, bulkReviewer)}>Assign</button></div>}
          <div className="claim-list-head claim-list-head-wide"><span>Claim</span><span>Source</span><span>Payer Name</span><span>Patient Name</span><span>Patient ID</span><span>Subscriber ID</span><span>DOS</span><span>Balance</span><span>Status</span></div>
          <div className="claim-rows-scroll">{rows.length ? rows.map((row, index) => {
            const isOpen = drawerRow?.escalationId === row.escalationId;
            return <div key={row.escalationId} className={`claim-list-row claim-list-row-wide ${isOpen ? 'active' : ''}`}>
              {canAssign && <span className="claim-row-check"><input type="checkbox" checked={!!selectedClaims[index]} onChange={e => setSelectedClaims({ ...selectedClaims, [index]: e.target.checked })} /></span>}
              <span className="claim-expand-dot"><i className={`bi ${isOpen ? 'bi-chevron-down' : 'bi-chevron-right'}`} /></span>
              <span className="claim-list-id"><button className="claim-id-link" type="button" onClick={() => openDrawer(row)}>{row.claimId || '-'}</button><small>{row.escalationReason || 'Manager response required'}</small><button type="button" className="wl-btn xs teal esc-review-inline" onClick={() => openModal(row)}>Review Response</button></span>
              <span className="claim-list-payer" title={row.source || ''}>{row.source || '-'}</span>
              <span className="claim-list-payer" title={row.payerName || ''}>{row.payerName || '-'}</span>
              <span className="claim-list-payer" title={row.patientName || ''}>{row.patientName || '-'}</span>
              <span className="claim-list-payer" title={row.patientId || ''}>{row.patientId || '-'}</span>
              <span className="claim-list-payer" title={row.subscriberId || ''}>{row.subscriberId || '-'}</span>
              <span className="claim-list-payer">{date(row.dateOfService) || '-'}</span>
              <span className="claim-list-amt">{money(row.insuranceBalance)}</span>
              <span className="claim-list-status"><span className={`badge ${statusClass(row.status)}`}>{row.status || 'Open'}</span></span>
            </div>;
          }) : <div className="claim-empty-panel">No escalated responses found.</div>}</div>
        </section>
        {drawerRow && <section className="claim-drawer open">
          <div className="claim-drawer-header"><div><div className="claim-drawer-kicker">Claims / Escalated Response / Review</div><h3>{drawerRow.claimId || '-'}</h3><p>{drawerRow.payerName || '-'} - {money(drawerRow.insuranceBalance)}</p></div><button className="wl-icon" title="Close claim drawer" type="button" onClick={() => { setDrawerRow(null); clearRowContext(); }}><i className="bi bi-x-lg" /></button></div>
          <div className="claim-drawer-meta"><span><b>Reason</b>{drawerRow.escalationReason || '-'}</span><span><b>Analyst</b>{drawerRow.analyst || drawerRow.createdBy || '-'}</span><span><b>Created</b>{date(drawerRow.createdOn)}</span><span><b>Follow-up</b>{date(drawerRow.nextFollowUpDate)}</span><span><b>SLA</b>{drawerRow.slaStatus || '-'}</span><span><b>Status</b>{drawerRow.status || 'Open'}</span></div>
          <div className="claim-drawer-actions"><button className="wl-btn teal xs" type="button" onClick={() => openModal(drawerRow)}>Review Response</button></div>
          <div className="claim-drawer-tabs"><button className="active" type="button">Line Tasks</button></div>
          <div className="claim-drawer-body">
            <LineTasksTable row={drawerRow} tasks={lineTasks} busy={lineTasksBusy} compact hideHistory onHistory={openHistory} />
          </div>
        </section>}
      </div>
      <Pager data={data} changePage={next => { closeModal(); setDrawerRow(null); clearRowContext(); setPage(next); }} />
      {historyCtx && <ClaimHistoryModal open={!!historyCtx} title={historyCtx.title} subtitle={historyCtx.subtitle} rows={historyRows} loading={historyLoading} onClose={() => setHistoryCtx(null)} />}
      {activeRow && <EscalationModal row={activeRow} level={level} draft={drafts[activeRow.escalationId] || {}} setDraft={patch => setDraft(activeRow.escalationId, patch)} reviewers={reviewers} canReassign={canAssignFromRole(user?.role)} resolve={resolve} responseFiles={responseFiles} setResponseFiles={setResponseFiles} responseDocs={responseDocs} openDocument={openDocument} deleteDocument={deleteDocument} busy={busy} close={closeModal} tasks={lineTasks} tasksBusy={lineTasksBusy} onHistory={openHistory} modalError={modalError} setModalError={setModalError} />}
    </div>;
  }

  return <div className="esc-page">
    <div className="wl-kpis esc-kpis"><div><b>{Number(kpi.total || 0).toLocaleString()}</b><span>{level} escalations</span></div><div><b>{Number(kpi.pending || 0).toLocaleString()}</b><span>Pending manager</span></div><div><b>{Number(kpi.breached || 0).toLocaleString()}</b><span>SLA breached</span></div><div><b>{money(kpi.amount)}</b><span>Visible balance</span></div></div>

    {renderEscalationClaimSplit()}
    {false && <>
    <div className="lrn-card">
      <div className="lrn-card-header"><div className="lrn-card-title">Escalation queue · {level} level</div><span className="table-count">Showing {rows.length} of {data.totalCount || 0}</span></div>
      <div className="dt-wrap workflow-scroll escalation-table-wrap">
        <table className="lrn-table workflow-table thin-bordered esc-table">
          <thead><tr><th style={{ minWidth: 128 }}>Action</th><th style={{ minWidth: 130 }}>Claim</th>{level === 'Line' && <th style={{ minWidth: 90 }}>CPT</th>}<th style={{ minWidth: 110 }}>Source</th><th style={{ minWidth: 180 }}>Payer Name</th><th style={{ minWidth: 160 }}>Patient Name</th><th style={{ minWidth: 120 }}>Patient ID</th><th style={{ minWidth: 130 }}>Subscriber ID</th><th style={{ minWidth: 115 }}>DOS</th><th style={{ minWidth: 150 }}>Analyst</th><th style={{ minWidth: 280 }}>Reason</th><th style={{ minWidth: 130 }}>Follow-up Date</th><th style={{ minWidth: 130 }}>Created On</th><th style={{ minWidth: 115 }}>SLA</th><th style={{ minWidth: 105 }}>Balance</th><th style={{ minWidth: 130 }}>Status</th></tr></thead>
          <tbody>{rows.length ? rows.map(row => <EscalationRow key={row.escalationId} row={row} level={level} onOpen={() => openModal(row)} onSelect={() => openDrawer(row)} />) : <tr><td colSpan={level === 'Line' ? 16 : 15} className="empty-cell">No escalations found.</td></tr>}</tbody>
        </table>
      </div>
    </div>
    <Pager data={data} changePage={next => { closeModal(); clearRowContext(); setPage(next); }} />

    {drawerRow && <LineTasksPanel row={drawerRow} tasks={lineTasks} busy={lineTasksBusy} />}
    </>}

    {historyCtx && <ClaimHistoryModal open={!!historyCtx} title={historyCtx.title} subtitle={historyCtx.subtitle} rows={historyRows} loading={historyLoading} onClose={() => setHistoryCtx(null)} />}

    {activeRow && <EscalationModal row={activeRow} level={level} draft={drafts[activeRow.escalationId] || {}} setDraft={patch => setDraft(activeRow.escalationId, patch)} reviewers={reviewers} canReassign={canAssignFromRole(user?.role)} resolve={resolve} responseFiles={responseFiles} setResponseFiles={setResponseFiles} responseDocs={responseDocs} openDocument={openDocument} deleteDocument={deleteDocument} busy={busy} close={closeModal} tasks={lineTasks} tasksBusy={lineTasksBusy} onHistory={openHistory} modalError={modalError} setModalError={setModalError} />}
  </div>;
}

function EscalationRow({ row, level, onOpen, onSelect }) {
  return <tr className="esc-row">
    <td><div className="esc-action-buttons"><button type="button" className="wl-btn xs teal" onClick={onOpen}>Review</button></div></td>
    <td className="claim-link"><button type="button" className="claim-id-link" onClick={onSelect}>{row.claimId}</button></td>
    {level === 'Line' && <td><code>{row.cptCode || '-'}</code></td>}
    <td>{row.source || '-'}</td>
    <td className="wrap-cell">{row.payerName || '-'}</td>
    <td>{row.patientName || '-'}</td>
    <td>{row.patientId || '-'}</td>
    <td>{row.subscriberId || '-'}</td>
    <td>{date(row.dateOfService) || '-'}</td>
    <td><span className="avatar-sm">{initials(row.analyst || row.createdBy)}</span> {row.analyst || row.createdBy || '-'}</td>
    <td className="wrap-cell"><b>{row.escalationReason}</b></td>
    <td>{date(row.nextFollowUpDate)}</td>
    <td>{date(row.createdOn)}</td>
    <td>{slaBadge(row)}</td>
    <td className="money">{money(row.insuranceBalance)}</td>
    <td><span className={`badge ${statusClass(row.status)}`}>{row.status || 'Open'}</span></td>
  </tr>;
}

function EscalationModal({ row, level, draft, setDraft, reviewers, canReassign, resolve, busy, close, tasks, tasksBusy, onHistory, modalError, setModalError, responseFiles, setResponseFiles, responseDocs, openDocument, deleteDocument }) {
  return <div className="esc-modal-backdrop" onMouseDown={busy ? undefined : close}>
    <div className="esc-modal" role="dialog" aria-modal="true" onMouseDown={e => e.stopPropagation()}>
      <div className="esc-modal-hd">
        <div><h3>Esclation Response</h3><p>{row.escalationReason || 'Manager response required'}</p></div>
        <button type="button" className="esc-modal-close" disabled={busy} onClick={close}>×</button>
      </div>
      <div className="esc-modal-body">
        <EscalationDetail row={row} level={level} draft={draft} setDraft={setDraft} reviewers={reviewers} canReassign={canReassign} resolve={resolve} busy={busy} modalError={modalError} setModalError={setModalError} responseFiles={responseFiles} setResponseFiles={setResponseFiles} responseDocs={responseDocs} openDocument={openDocument} deleteDocument={deleteDocument} />
        <LineTasksTable title={level === 'Line' ? 'Task list for this claim' : 'Related task list'} row={row} tasks={tasks} busy={tasksBusy} compact hideHistory onHistory={onHistory} />
      </div>
    </div>
  </div>;
}

function EscalationDetail({ row, draft, setDraft, reviewers, canReassign, resolve, busy, modalError, setModalError, responseFiles, setResponseFiles, responseDocs = [], openDocument, deleteDocument }) {
  const arReviewers = (reviewers || []).filter(isArReviewerOption);
  const action = draft.resolutionAction || '';
  const writeOffDecision = String(row.escalationReason || '').toLowerCase().includes('write-off decision required') || String(row.escalationReason || '').toLowerCase().includes('writeoff decision required');
  const actionOptions = writeOffDecision ? writeOffDecisionActions : resolutionActions;
  const showReassign = canReassign && !!action && !['approve', 'writeoff', 'approveWriteOff'].includes(action);
  const clearAndSetDraft = (patch) => { setModalError(''); setDraft(patch); };
  return <div className="esc-detail-wrap popup-mode">
    <div className="esc-detail-grid">
      <div>
        <div className="esc-section-title esc-title-row"><span>Escalation details</span><span className="esc-title-meta">Claim {row.claimId || '-'} - {row.payerName || 'Payer not available'}</span></div>
        <div className="esc-info-grid">
          <Info label="Action required" value={row.actionCategory || row.escalationReason || '-'} />
          <Info label="Balance" value={money(row.insuranceBalance)} />
          <Info label="SLA status" value={row.slaStatus || '-'} />
          <Info label="Escalation status" value={row.status || 'Open'} />
          <Info label="Next follow-up" value={date(row.nextFollowUpDate)} />
        </div>
        <div className="esc-note-card">
          <div className="esc-note-label">Escalation note from {row.analyst || row.createdBy || 'analyst'}</div>
          <span className="esc-reason-pill">{row.escalationReason}</span>
          <div className="esc-note-text">{row.comments || 'No escalation comment entered.'}</div>
          <div className="esc-note-meta">{row.createdBy || row.analyst || '-'} - {date(row.createdOn)}</div>
        </div>
      </div>
      <div>
        <div className="esc-section-title">Manager response</div>
        {modalError ? <div className="esc-inline-error"><i className="bi bi-exclamation-circle" /> {modalError}</div> : null}
        {writeOffDecision ? <div className="esc-help">Write-off Decision Required: choose Approve Write Off or Reject Write Off and enter comments before submitting.</div> : null}
        <label className="esc-label">Response action<select className="wl-full" value={action} disabled={busy} onChange={e => clearAndSetDraft({ resolutionAction: e.target.value, reassignTo: '', otherReason: '', recommendedNextAction: writeOffDecision ? (e.target.value === 'approveWriteOff' ? 'Write-off approved' : e.target.value === 'rejectWriteOff' ? 'Write-off rejected' : '') : (draft.recommendedNextAction || '') })}>{actionOptions.map(x => <option key={x.value} value={x.value}>{x.label}</option>)}</select></label>
        {!writeOffDecision && <label className="esc-label">Recommended Next Action <span>*</span><select className="wl-full" value={draft.recommendedNextAction || ''} disabled={busy} onChange={e => clearAndSetDraft({ recommendedNextAction: e.target.value })}><option value="">Select recommended next action</option>{recommendedNextActions.map(x => <option key={x}>{x}</option>)}</select></label>}
        {action === 'rework' && <div className="esc-help">Choose an AR Reviewer to reassign the claim, or leave it blank to move it back to the unassigned queue.</div>}
        {action === 'others' && <label className="esc-label">Other reason <span>*</span><input className="wl-full" value={draft.otherReason || ''} disabled={busy} onChange={e => clearAndSetDraft({ otherReason: e.target.value })} placeholder="Enter other response reason..." /></label>}
        <label className="esc-label">Add / update response note to {row.analyst || row.createdBy || 'analyst'} <span>*</span><textarea className="wl-textarea esc-response" maxLength={MAX_TEXT_LENGTH} value={draft.responseNote || ''} disabled={busy} onChange={e => clearAndSetDraft({ responseNote: limitText(e.target.value) })} placeholder="Add clarification, decision, or instructions for the analyst - this will be visible in their work list..." /><div className="text-count">{textCountLabel(draft.responseNote)}</div></label>
        {showReassign && <label className="esc-label">Reassign claim to AR Reviewer<select className="wl-full" value={draft.reassignTo || ''} disabled={busy} onChange={e => clearAndSetDraft({ reassignTo: e.target.value })}><option value="">{action === 'rework' ? 'Move to unassigned' : 'Keep current reviewer'}</option>{arReviewers.map(r => <option key={r.userName || r.UserName} value={r.userName || r.UserName}>{r.displayName || r.DisplayName || r.userName || r.UserName}</option>)}</select></label>}
        <label className="esc-label">Optional document upload<input type="file" multiple disabled={busy} onChange={e => { setModalError(''); setResponseFiles(Array.from(e.target.files || [])); }} /></label>{responseFiles?.length ? <div className="esc-help">{responseFiles.length} file(s) selected.</div> : null}
        {responseDocs?.length ? <div className="esc-doc-list">{responseDocs.map(d => <div className="esc-doc-row" key={d.documentId}><span>{d.originalFileName}</span><div className="doc-row-actions"><button className="wl-btn xs" type="button" onClick={() => openDocument?.(d.documentId)}>View / Download</button>{canDeleteClaimDocument(row, { busy }) && <button className="wl-btn red xs" type="button" onClick={() => deleteDocument?.(d.documentId, row)}>Delete</button>}</div></div>)}</div> : null}
        <div className="esc-help">Submit will send the response back for AR Manager verification.</div>
      </div>
    </div>
    <div className="esc-action-bar">
      <button className="wl-btn teal" disabled={busy || !action || (action === 'others' && !String(draft.otherReason || '').trim())} onClick={() => resolve(row, action, setModalError)}>{busy ? 'Submitting response...' : 'Submit'}</button>
    </div>
  </div>;
}
function LineTasksPanel({ row, tasks, busy }) {
  return <div className="lrn-card esc-line-panel"><div className="lrn-card-header"><div className="lrn-card-title">Task view - Claim {row.claimId}</div><span className="table-count">{busy ? 'Loading...' : `${tasks.length} task(s)`}</span></div><LineTasksTable row={row} tasks={tasks} busy={busy} hideHistory /></div>;
}

function LineTasksTable({ title, row, tasks, busy }) {
  return <div className="esc-modal-task-section">
    {title && <div className="esc-section-title">{title}</div>}
    <div className="cpt-scroll">
      <table className="claim-task-table full-task-columns thin-bordered">
        <thead><tr><th>TaskID</th><th>CPTCode</th><th>Units</th><th>Modifier</th><th>DenialCode</th><th>DenialDescription</th><th>DenialClassification</th><th>ActionCode</th><th>ActionCategory</th><th>RecommendedAction</th><th>Priority</th><th className="r">InsuranceBalance</th><th>SLADays</th><th>Status</th><th>DateOpened</th><th>DueDate</th><th>SLAStatus</th><th>FirstBilledDate</th><th>ChargeEnteredDate</th><th>Assigned To</th></tr></thead>
        <tbody>{busy ? <tr><td colSpan={20} className="empty-cell">Loading task list...</td></tr> : tasks?.length ? tasks.map((t, i) => <tr key={`${t.taskId || 'task'}-${i}`}><td><strong>{t.taskId || '-'}</strong></td><td><code className="code">{t.cptCode || '-'}</code></td><td>{t.units ?? '-'}</td><td>{t.modifier || '-'}</td><td><code className="code">{t.denialCode || '-'}</code></td><td className="wrap-wide">{t.denialDescription || '-'}</td><td>{t.denialClassification || '-'}</td><td>{t.actionCode || '-'}</td><td>{t.actionCategory || '-'}</td><td className="wrap-wide">{t.recommendedAction || '-'}</td><td>{t.priority || '-'}</td><td className="r">{money(t.insuranceBalance)}</td><td>{t.slaDays ?? '-'}</td><td><span className={`badge ${statusClass(t.status || '')}`}>{t.status || '-'}</span></td><td>{date(t.dateOpened)}</td><td>{date(t.dueDate)}</td><td><span className={`badge ${statusClass(t.slaStatus || '')}`}>{t.slaStatus || '-'}</span></td><td>{date(t.firstBilledDate)}</td><td>{date(t.chargeEnteredDate)}</td><td>{t.assignedTo || '-'}</td></tr>) : <tr><td colSpan={20} className="empty-cell">No task lines found for claim {row?.claimId || '-'}.</td></tr>}</tbody>
      </table>
    </div>
  </div>;
}

function Info({ label, value }) {
  return <div className="esc-info"><label>{label}</label><div>{value}</div></div>;
}


