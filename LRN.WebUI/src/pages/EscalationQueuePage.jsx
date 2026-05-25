import React, { useEffect, useMemo, useState } from 'react';
import { denialWorkflowService } from '../services/denialWorkflowService';
import Pager from '../components/Pager';
import ClaimHistoryModal from '../components/ClaimHistoryModal';
import { money, date, initials, statusClass } from '../utils/formatters';

const resolutionActions = [
  { value: '', label: '— Select resolution action —' },
  { value: 'approve', label: 'Approve & close escalation' },
  { value: 'rework', label: 'Return for rework' },
  { value: 'reassign', label: 'Reassign to different analyst' },
  { value: 'writeoff', label: 'Approve write-off' }
];

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

export default function EscalationQueuePage({ labId, user, reviewers = [], taskView = 'claim', setTaskView = () => {}, setMessage = () => {} }) {
  const [data, setData] = useState({ items: [], page: 1, pageSize: 100, totalCount: 0, totalPages: 0 });
  const [page, setPage] = useState(1);
  const [status, setStatus] = useState('');
  const [searchText, setSearchText] = useState('');
  const [activeRow, setActiveRow] = useState(null);
  const [modalError, setModalError] = useState('');
  const [lineTasks, setLineTasks] = useState([]);
  const [lineTasksBusy, setLineTasksBusy] = useState(false);
  const [historyCtx, setHistoryCtx] = useState(null);
  const [historyRows, setHistoryRows] = useState([]);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [drafts, setDrafts] = useState({});
  const [busy, setBusy] = useState(false);
  const level = taskView === 'line' ? 'Line' : 'Claim';

  const query = useMemo(() => ({
    labId,
    role: user?.role || '',
    userName: user?.userName || '',
    status,
    searchText,
    page,
    pageSize: 100
  }), [labId, user, status, searchText, page]);

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
  const kpi = useMemo(() => ({
    total: data.totalCount || rows.length,
    pending: rows.filter(x => !['resolved', 'closed', 'returned for rework'].includes(String(x.status || '').toLowerCase())).length,
    breached: rows.filter(x => String(x.slaStatus || '').toLowerCase().includes('over') || Number(x.daysRemaining) < 0).length,
    amount: rows.reduce((a, b) => a + Number(b.insuranceBalance || 0), 0)
  }), [rows, data.totalCount]);

  function setDraft(id, patch) {
    setDrafts(prev => ({ ...prev, [id]: { responseNote: '', resolutionAction: '', reassignTo: '', ...(prev[id] || {}), ...patch } }));
  }

  function closeModal() {
    setActiveRow(null);
    setModalError('');
    setLineTasks([]);
    setLineTasksBusy(false);
  }

  async function openModal(row) {
    setActiveRow(row);
    setModalError('');
    setLineTasks([]);
    if (!row?.claimId) return;
    setLineTasksBusy(true);
    try {
      const taskRows = await denialWorkflowService.getClaimTasks(labId, row.claimId, level === 'Line' ? 'assigned' : '');
      setLineTasks(taskRows || []);
    } catch (e) {
      setLineTasks([]);
      setMessage({ type: 'warning', text: e.message || 'Unable to load claim line tasks.' });
    } finally {
      setLineTasksBusy(false);
    }
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
      setHistoryRows(rows || []);
    } catch (e) {
      setMessage({ type: 'warning', text: e.message || 'Unable to load claim history.' });
    } finally {
      setHistoryLoading(false);
    }
  }

  async function resolve(row, forcedAction = '', setInlineError = null) {
    const draft = drafts[row.escalationId] || {};
    const action = forcedAction || draft.resolutionAction;
    const fail = (text) => { if (setInlineError) setInlineError(text); else setModalError(text); return false; };
    if (!String(draft.responseNote || '').trim()) return fail('Please add manager response note.');
    if (!action) return fail('Please select resolution action.');
    if (action === 'reassign' && !draft.reassignTo) return fail('Please select analyst to reassign.');
    if (setInlineError) setInlineError('');
    setModalError('');
    setBusy(true);
    try {
      const result = await denialWorkflowService.resolveEscalation({
        labId,
        escalationId: row.escalationId,
        claimId: row.claimId,
        taskId: row.taskId || '',
        cptCode: row.cptCode || '',
        escalationLevel: row.escalationLevel || level,
        resolutionAction: action,
        responseNote: draft.responseNote,
        reassignTo: draft.reassignTo || '',
        actionBy: user?.userName || 'ReactWorkflow'
      });
      setMessage({ type: result?.success ? 'success' : 'warning', text: result?.message || 'Escalation response saved.' });
      closeModal();
      await load();
    } catch (e) {
      setMessage({ type: 'danger', text: e.message || 'Escalation response failed.' });
    } finally {
      setBusy(false);
    }
  }

  return <div className="esc-page">
    <div className="wl-kpis esc-kpis"><div><b>{Number(kpi.total || 0).toLocaleString()}</b><span>{level} escalations</span></div><div><b>{Number(kpi.pending || 0).toLocaleString()}</b><span>Pending manager</span></div><div><b>{Number(kpi.breached || 0).toLocaleString()}</b><span>SLA breached</span></div><div><b>{money(kpi.amount)}</b><span>Visible balance</span></div></div>

    <div className="lrn-card">
      <div className="lrn-card-header"><div className="lrn-card-title">Escalation queue · {level} level</div><span className="table-count">Showing {rows.length} of {data.totalCount || 0}</span></div>
      <div className="dt-wrap workflow-scroll escalation-table-wrap">
        <table className="lrn-table workflow-table thin-bordered esc-table">
          <thead><tr><th style={{ minWidth: 128 }}>Action</th><th style={{ minWidth: 130 }}>Claim</th>{level === 'Line' && <th style={{ minWidth: 90 }}>CPT</th>}<th style={{ minWidth: 150 }}>Analyst</th><th style={{ minWidth: 280 }}>Reason</th><th style={{ minWidth: 130 }}>Created On</th><th style={{ minWidth: 115 }}>SLA</th><th style={{ minWidth: 105 }}>Balance</th><th style={{ minWidth: 130 }}>Status</th></tr></thead>
          <tbody>{rows.length ? rows.map(row => <EscalationRow key={row.escalationId} row={row} level={level} onOpen={() => openModal(row)} onHistory={() => openHistory(row)} />) : <tr><td colSpan={level === 'Line' ? 9 : 8} className="empty-cell">No escalations found.</td></tr>}</tbody>
        </table>
      </div>
    </div>
    <Pager data={data} changePage={next => { closeModal(); setPage(next); }} />

    {level === 'Line' && activeRow && <LineTasksPanel row={activeRow} tasks={lineTasks} busy={lineTasksBusy} onHistory={openHistory} modalError={modalError} setModalError={setModalError} />}

    {historyCtx && <ClaimHistoryModal open={!!historyCtx} title={historyCtx.title} subtitle={historyCtx.subtitle} rows={historyRows} loading={historyLoading} onClose={() => setHistoryCtx(null)} />}

    {activeRow && <EscalationModal row={activeRow} level={level} draft={drafts[activeRow.escalationId] || {}} setDraft={patch => setDraft(activeRow.escalationId, patch)} reviewers={reviewers} resolve={resolve} busy={busy} close={closeModal} tasks={lineTasks} tasksBusy={lineTasksBusy} onHistory={openHistory} modalError={modalError} setModalError={setModalError} />}
  </div>;
}

function EscalationRow({ row, level, onOpen, onHistory }) {
  return <tr className="esc-row">
    <td><div className="esc-action-buttons"><button type="button" className="wl-btn xs teal" onClick={onOpen}>Review</button><button type="button" className="wl-icon" title="View history" onClick={onHistory}><i className="bi bi-clock-history" /></button></div></td>
    <td className="claim-link">{row.claimId}</td>
    {level === 'Line' && <td><code>{row.cptCode || '-'}</code></td>}
    <td><span className="avatar-sm">{initials(row.analyst || row.createdBy)}</span> {row.analyst || row.createdBy || '-'}</td>
    <td className="wrap-cell"><b>{row.escalationReason}</b></td>
    <td>{date(row.createdOn)}</td>
    <td>{slaBadge(row)}</td>
    <td className="money">{money(row.insuranceBalance)}</td>
    <td><span className={`badge ${statusClass(row.status)}`}>{row.status || 'Open'}</span></td>
  </tr>;
}

function EscalationModal({ row, level, draft, setDraft, reviewers, resolve, busy, close, tasks, tasksBusy, onHistory, modalError, setModalError }) {
  return <div className="esc-modal-backdrop" onMouseDown={close}>
    <div className="esc-modal" role="dialog" aria-modal="true" onMouseDown={e => e.stopPropagation()}>
      <div className="esc-modal-hd">
        <div><h3>Esclation Response</h3><p>{row.escalationReason || 'Manager response required'}</p></div>
        <button type="button" className="esc-modal-close" onClick={close}>×</button>
      </div>
      <div className="esc-modal-body">
        <EscalationDetail row={row} level={level} draft={draft} setDraft={setDraft} reviewers={reviewers} resolve={resolve} busy={busy} modalError={modalError} setModalError={setModalError} />
        <LineTasksTable title={level === 'Line' ? 'Task list for this claim' : 'Related task list'} row={row} tasks={tasks} busy={tasksBusy} compact hideHistory onHistory={onHistory} />
      </div>
    </div>
  </div>;
}

function EscalationDetail({ row, draft, setDraft, reviewers, resolve, busy, modalError, setModalError }) {
  return <div className="esc-detail-wrap popup-mode">
    <div className="esc-detail-grid">
      <div>
        <div className="esc-section-title esc-title-row"><span>Escalation details</span><span className="esc-title-meta">Claim {row.claimId || '-'} · {row.payerName || 'Payer not available'}</span></div>
        <div className="esc-info-grid">
          <Info label="Action required" value={row.actionCategory || row.escalationReason || '-'} />
          <Info label="Balance" value={money(row.insuranceBalance)} />
          <Info label="SLA status" value={row.slaStatus || '-'} />
          <Info label="Escalation status" value={row.status || 'Open'} />
        </div>
        <div className="esc-note-card">
          <div className="esc-note-label">Escalation note from {row.analyst || row.createdBy || 'analyst'}</div>
          <span className="esc-reason-pill">{row.escalationReason}</span>
          <div className="esc-note-text">{row.comments || 'No escalation comment entered.'}</div>
          <div className="esc-note-meta">{row.createdBy || row.analyst || '-'} · {date(row.createdOn)}</div>
        </div>
      </div>
      <div>
        <div className="esc-section-title">Manager response</div>
        {modalError ? <div className="esc-inline-error"><i className="bi bi-exclamation-circle" /> {modalError}</div> : null}
        <label className="esc-label">Add / update response note to {row.analyst || row.createdBy || 'analyst'} <span>*</span><textarea className="wl-textarea esc-response" value={draft.responseNote || ''} onChange={e => setDraft({ responseNote: e.target.value })} placeholder="Add clarification, decision, or instructions for the analyst — this will be visible in their work list..." /></label>
        <label className="esc-label">Resolution action <span>*</span><select className="wl-full" value={draft.resolutionAction || ''} onChange={e => setDraft({ resolutionAction: e.target.value })}>{resolutionActions.map(x => <option key={x.value} value={x.value}>{x.label}</option>)}</select></label>
        {draft.resolutionAction === 'reassign' && <label className="esc-label">Reassign to analyst<select className="wl-full" value={draft.reassignTo || ''} onChange={e => setDraft({ reassignTo: e.target.value })}><option value="">— Select analyst —</option>{reviewers.map(r => <option key={r.userName || r.displayName} value={r.userName || r.displayName}>{r.displayName || r.userName}</option>)}</select></label>}
        <div className="esc-help">The analyst will be notified of your response and resolution action immediately.</div>
      </div>
    </div>
    <div className="esc-action-bar">
      <button className="wl-btn teal" disabled={busy} onClick={() => resolve(row, 'approve', setModalError)}>Approve & close</button>
      <button className="wl-btn amber" disabled={busy} onClick={() => resolve(row, 'rework', setModalError)}>Return for rework</button>
      <button className="wl-btn" disabled={busy} onClick={() => resolve(row, 'reassign', setModalError)}>Reassign</button>
      <button className="wl-btn red" disabled={busy} onClick={() => resolve(row, 'writeoff', setModalError)}>Approve write-off</button>
    </div>
  </div>;
}

function LineTasksPanel({ row, tasks, busy, onHistory }) {
  return <div className="lrn-card esc-line-panel"><div className="lrn-card-header"><div className="lrn-card-title">Line level task list · Claim {row.claimId}</div><span className="table-count">{busy ? 'Loading...' : `${tasks.length} task(s)`}</span></div><LineTasksTable row={row} tasks={tasks} busy={busy} onHistory={onHistory} /></div>;
}

function LineTasksTable({ title, row, tasks, busy, compact, hideHistory = false, onHistory }) {
  const colSpan = hideHistory ? 11 : 12;
  return <div className={compact ? 'esc-modal-task-section' : ''}>{title && <div className="esc-section-title">{title}</div>}<div className="dt-wrap escalation-line-scroll"><table className="lrn-table workflow-table thin-bordered esc-line-task-table"><thead><tr><th>Task ID</th><th>Claim</th><th>CPT</th><th>Denial Code</th><th>Denial Classification</th><th>Task</th><th>Action</th><th>Comment</th><th>Assigned To</th><th>Status</th><th>Created On</th>{!hideHistory && <th>History</th>}</tr></thead><tbody>{busy ? <tr><td colSpan={colSpan} className="empty-cell">Loading task list...</td></tr> : tasks?.length ? tasks.map((t, i) => <tr key={`${t.taskId}-${i}`}><td>{t.taskId || '-'}</td><td>{t.claimId || '-'}</td><td><code>{t.cptCode || '-'}</code></td><td>{t.denialCode || '-'}</td><td className="wrap-cell compact-wrap">{t.denialClassification || '-'}</td><td className="wrap-cell task-text-cell">{t.task || '-'}</td><td className="wrap-cell action-text-cell">{t.recommendedAction || t.actionCategory || t.actionCode || '-'}</td><td className="wrap-cell comment-text-cell">{t.reviewerComments || t.denialDescription || '-'}</td><td>{t.assignedTo || '-'}</td><td><span className={`badge ${statusClass(t.status)}`}>{t.status || '-'}</span></td><td>{date(t.createdOn)}</td>{!hideHistory && <td><button type="button" className="wl-icon" title="View line history" onClick={() => onHistory?.(row, t)}><i className="bi bi-clock-history" /></button></td>}</tr>) : <tr><td colSpan={colSpan} className="empty-cell">No task lines found for this claim.</td></tr>}</tbody></table></div></div>;
}

function Info({ label, value }) {
  return <div className="esc-info"><label>{label}</label><div>{value}</div></div>;
}
