import React, { useEffect, useMemo, useState } from 'react';
import { denialWorkflowService } from '../services/denialWorkflowService';
import Pager from '../components/Pager';
import SearchableMultiSelect from '../components/SearchableMultiSelect';

const fmtDate = v => v ? new Date(v).toLocaleDateString() : '-';
const money = v => Number(v || 0).toLocaleString(undefined, { style: 'currency', currency: 'USD' });
const statusOptions = ['Open', 'In Progress', 'Pending Payer', 'Pending Documentation', 'Escalated', 'Closed'];
const claimEscReasons = ['Payer policy conflict across claim — need manager guidance', 'Multiple CPT lines impacted by same denial', 'Timely filing risk at claim level', 'High value claim requires approval', 'Other'];
const lineEscReasons = ['Payer policy unclear — need guidance', 'Appeal requires manager approval', 'Coding / modifier review required', 'ICD coverage rule requires review', 'Other'];

function roleIsReviewerOnly(role) {
  const r = String(role || '').toLowerCase();
  return r.includes('reviewer') && !r.includes('manager') && !r.includes('admin');
}

function groupByClaim(rows) {
  const map = new Map();
  rows.forEach(t => {
    const id = t.claimId || '-';
    if (!map.has(id)) map.set(id, { claimId: id, payerName: t.payerName || t.payerNameNormalized || '-', panelName: t.panelName || '-', patientId: t.patientId || '-', dateOfService: t.dateOfService, clinicName: t.clinicName || '-', referringProvider: t.referringProvider || '-', assignedTo: t.assignedTo || '-', status: t.status || 'Open', balance: 0, lines: [] });
    const c = map.get(id);
    c.balance += Number(t.insuranceBalance || 0);
    c.lines.push(t);
    if (!c.assignedTo || c.assignedTo === '-') c.assignedTo = t.assignedTo || '-';
    if (String(t.status || '').toLowerCase().includes('escal')) c.status = 'Escalated';
  });
  return Array.from(map.values());
}

function Modal({ title, children, onClose }) {
  return <div className="wl-modal-bg"><div className="wl-modal"><div className="wl-modal-hd"><strong>{title}</strong><button className="wl-btn xs" onClick={onClose}>✕</button></div>{children}</div></div>;
}

export default function MyWorklistPage({ labId, user, options, filter, setMessage, onRefreshToken, onSaved, taskView = 'open', setTaskView = () => {} }) {
  const [data, setData] = useState({ items: [], page: 1, pageSize: 100, totalCount: 0, totalPages: 0 });
  const [loading, setLoading] = useState(false);
  const [expanded, setExpanded] = useState('');
  const [page, setPage] = useState(1);
  const [local, setLocal] = useState({ payerName: '', denialClassification: '', actionCategory: '', status: '', searchText: '' });
  const [noteCtx, setNoteCtx] = useState(null);
  const [noteText, setNoteText] = useState('');
  const [noteStatus, setNoteStatus] = useState('In Progress');
  const [notes, setNotes] = useState([]);
  const [docCtx, setDocCtx] = useState(null);
  const [docs, setDocs] = useState([]);
  const [docComment, setDocComment] = useState('');
  const [docFiles, setDocFiles] = useState([]);
  const [escCtx, setEscCtx] = useState(null);
  const [escReason, setEscReason] = useState('');
  const [escComment, setEscComment] = useState('');
  const [escalations, setEscalations] = useState([]);

  const query = useMemo(() => ({
    labId,
    role: user?.role || '',
    userName: user?.userName || '',
    assignedTo: roleIsReviewerOnly(user?.role) ? (user?.userName || '') : (filter?.reviewer || ''),
    reviewer: roleIsReviewerOnly(user?.role) ? (user?.userName || '') : (filter?.reviewer || ''),
    payerName: local.payerName || filter?.payerName || '',
    denialClassification: local.denialClassification || filter?.denialClassification || '',
    actionCategory: local.actionCategory || filter?.actionCategory || '',
    status: local.status || filter?.status || '',
    taskView,
    searchText: local.searchText || filter?.searchText || '',
    page,
    pageSize: 100
  }), [labId, user, filter, local, taskView, page]);

  async function load() {
    if (!labId) return;
    setLoading(true);
    try {
      const result = await denialWorkflowService.getTasks(query);
      setData({ items: result?.items || [], page: result?.page || page, pageSize: result?.pageSize || 100, totalCount: result?.totalCount || 0, totalPages: result?.totalPages || 0 });
    } catch (e) { setMessage?.({ type: 'danger', text: e.message }); }
    finally { setLoading(false); }
  }
  useEffect(() => { load(); }, [query, onRefreshToken]);

  const rows = data.items || [];
  function changePage(nextPage) { setExpanded(''); setPage(nextPage); }

  useEffect(() => { setPage(1); setExpanded(''); }, [local, taskView]);

  const claims = useMemo(() => groupByClaim(rows), [rows]);
  const kpi = useMemo(() => ({ claims: claims.length, tasks: rows.length, balance: rows.reduce((a, b) => a + Number(b.insuranceBalance || 0), 0), escalated: rows.filter(x => String(x.status || '').toLowerCase().includes('escal')).length }), [claims, rows]);
  const myTabs = useMemo(() => [
    { key: 'open', label: 'New', hint: 'Assigned active work' },
    { key: 'assigned', label: 'Assigned', hint: 'All assigned active items' },
    { key: 'escalations', label: 'Escalate', hint: 'Escalated work items' },
    { key: 'closed', label: 'Closed', hint: 'Completed by reviewer' }
  ], []);

  async function openNote(level, claim, task) {
    const ctx = { level, claim, task };
    setNoteCtx(ctx); setNoteText(''); setNoteStatus(task?.status || claim?.status || 'In Progress');
    const data = await denialWorkflowService.getNotes({ labId, claimId: claim.claimId, taskId: task?.taskId || '', cptCode: task?.cptCode || '', noteLevel: level });
    setNotes(data || []);
  }
  async function saveNote() {
    if (!noteText.trim()) return setMessage?.({ type: 'warning', text: 'Please enter comments.' });
    const claim = noteCtx.claim, task = noteCtx.task;
    await denialWorkflowService.saveNote({ labId, claimId: claim.claimId, taskId: task?.taskId || '', cptCode: task?.cptCode || '', noteLevel: noteCtx.level, noteText, createdBy: user?.userName || 'ReactWorkflow' });
    if (task?.taskId && noteStatus) await denialWorkflowService.updateTask({ labId, taskId: task.taskId, status: noteStatus, comments: noteText, actionBy: user?.userName || 'ReactWorkflow' });
    if (!task?.taskId && noteStatus) {
      for (const l of claim.lines) await denialWorkflowService.updateTask({ labId, taskId: l.taskId, status: noteStatus, comments: noteText, actionBy: user?.userName || 'ReactWorkflow' });
    }
    setMessage?.({ type: 'success', text: 'Comment and status saved.' });
    onSaved?.();
    setNoteCtx(null); await load();
  }

  async function openDocs(claim) {
    setDocCtx(claim); setDocComment(''); setDocFiles([]);
    setDocs(await denialWorkflowService.getClaimDocuments(labId, claim.claimId));
  }
  async function uploadDocs() {
    if (!docFiles?.length) return setMessage?.({ type: 'warning', text: 'Select at least one document.' });
    await denialWorkflowService.uploadClaimDocuments(labId, docCtx.claimId, docComment, user?.userName || 'ReactWorkflow', docFiles);
    setMessage?.({ type: 'success', text: 'Document uploaded.' });
    onSaved?.();
    setDocs(await denialWorkflowService.getClaimDocuments(labId, docCtx.claimId));
    setDocFiles([]); setDocComment('');
  }

  async function openEsc(level, claim, task) {
    setEscCtx({ level, claim, task }); setEscReason(level === 'Claim' ? claimEscReasons[0] : lineEscReasons[0]); setEscComment('');
    const data = await denialWorkflowService.getEscalations({ labId, claimId: claim.claimId, taskId: task?.taskId || '', cptCode: task?.cptCode || '', escalationLevel: level });
    setEscalations(data || []);
  }
  async function saveEscalation() {
    const { level, claim, task } = escCtx;
    await denialWorkflowService.saveEscalation({ labId, claimId: claim.claimId, taskId: task?.taskId || '', cptCode: task?.cptCode || '', escalationLevel: level, escalationReason: escReason, comments: escComment, status: 'Open', createdBy: user?.userName || 'ReactWorkflow' });
    const affected = task ? [task] : claim.lines;
    for (const l of affected) await denialWorkflowService.updateTask({ labId, taskId: l.taskId, status: 'Escalated', comments: `${escReason}${escComment ? ' - ' + escComment : ''}`, actionBy: user?.userName || 'ReactWorkflow' });
    setMessage?.({ type: 'success', text: `${level} escalation saved.` });
    onSaved?.();
    setEscCtx(null); await load();
  }

  return <div className="wl-page">
    <div className="wl-kpis"><div><b>{kpi.claims}</b><span>Assigned claims</span></div><div><b>{kpi.tasks}</b><span>Open tasks</span></div><div><b>{money(kpi.balance)}</b><span>Ins. balance</span></div><div><b>{kpi.escalated}</b><span>Escalated</span></div></div>
    <div className="wl-card wl-filters"><div className="wl-card-hd"><b>My Worklist Filters</b><button className="wl-btn xs" onClick={() => setLocal({ payerName: '', denialClassification: '', actionCategory: '', status: '', searchText: '' })}>Clear all</button></div><div className="wl-filter-grid">
      <SearchableMultiSelect label="Payer" value={local.payerName} onChange={v => setLocal(x => ({ ...x, payerName: v }))} options={options?.payerNames || []} placeholder="All payers" />
      <SearchableMultiSelect label="Classification" value={local.denialClassification} onChange={v => setLocal(x => ({ ...x, denialClassification: v }))} options={options?.denialClassifications || []} placeholder="All classifications" />
      <SearchableMultiSelect label="Action / Task" value={local.actionCategory} onChange={v => setLocal(x => ({ ...x, actionCategory: v }))} options={options?.actionCategories || []} placeholder="All actions" />
      <SearchableMultiSelect label="Status" value={local.status} onChange={v => setLocal(x => ({ ...x, status: v }))} options={statusOptions} placeholder="All statuses" />
      <label className="span2">Search<input value={local.searchText} onChange={e => setLocal(x => ({ ...x, searchText: e.target.value }))} placeholder="Claim, payer, CPT, task..." /></label>
    </div></div>
    <div className="wl-card"><div className="wl-card-hd"><b>AR Reviewer · My Worklist · {myTabs.find(x => x.key === taskView)?.label}</b><span>{loading ? 'Loading...' : `${data.totalCount || rows.length} task(s)`}</span></div><div className="wl-table-scroll"><table className="wl-main-table"><thead><tr><th></th><th>Claim ID</th><th>Payer</th><th>Panel</th><th>Patient ID</th><th>DOS</th><th>Clinic</th><th>Provider</th><th>Assigned To</th><th>Balance</th><th>Claim Notes</th><th>Docs</th><th>Escalate</th><th>Status</th></tr></thead><tbody>{claims.map(c => <React.Fragment key={c.claimId}><tr className={expanded === c.claimId ? 'open' : ''} onClick={() => setExpanded(expanded === c.claimId ? '' : c.claimId)}><td>{expanded === c.claimId ? '▼' : '▶'}</td><td className="linkish">{c.claimId}</td><td>{c.payerName}</td><td>{c.panelName}</td><td>{c.patientId}</td><td>{fmtDate(c.dateOfService)}</td><td>{c.clinicName}</td><td>{c.referringProvider}</td><td>{c.assignedTo || '-'}</td><td className="money">{money(c.balance)}</td><td><button className="wl-icon" onClick={e => { e.stopPropagation(); openNote('Claim', c); }}>📝</button></td><td><button className="wl-icon" onClick={e => { e.stopPropagation(); openDocs(c); }}>📎</button></td><td><button className="wl-btn red xs" onClick={e => { e.stopPropagation(); openEsc('Claim', c); }}>Escalate</button></td><td><span className={`wl-badge ${String(c.status).toLowerCase().replaceAll(' ', '-')}`}>{c.status}</span></td></tr>{expanded === c.claimId && <tr><td colSpan="14" className="wl-detail-cell"><div className="wl-detail-title">CPT / line-level task details</div><div className="wl-line-scroll"><table className="wl-line-table"><thead><tr><th>Task ID</th><th>CPT</th><th>Units</th><th>Modifier</th><th>Denial</th><th>Coverage</th><th>ICD Status</th><th>Classification</th><th>Validity</th><th>Balance</th><th>Action / Task</th><th>SLA</th><th>Assigned To</th><th>Status</th><th>Notes</th><th>Escalate</th></tr></thead><tbody>{c.lines.map(l => <tr key={l.taskId}><td><b>{l.taskId}</b></td><td>{l.cptCode}</td><td>{l.units ?? '-'}</td><td>{l.modifier || '-'}</td><td>{l.denialCode}</td><td>{l.coverageStatus || '-'}</td><td>{l.icdComplianceStatus || '-'}</td><td>{l.denialClassification}</td><td>{l.denialValidity || '-'}</td><td className="money">{money(l.insuranceBalance)}</td><td>{l.task || l.recommendedAction}</td><td>{l.daysRemaining ?? '-'}</td><td>{l.assignedTo || '-'}</td><td><span className={`wl-badge ${String(l.status).toLowerCase().replaceAll(' ', '-')}`}>{l.status || 'Open'}</span></td><td><button className="wl-icon" onClick={() => openNote('Line', c, l)}>📝</button></td><td><button className="wl-btn red xs" onClick={() => openEsc('Line', c, l)}>Escalate</button></td></tr>)}</tbody></table></div></td></tr>}</React.Fragment>)}</tbody></table></div></div>
    <Pager data={data} changePage={changePage} />

    {noteCtx && <Modal title={`${noteCtx.level} Comments · ${noteCtx.claim.claimId}${noteCtx.task ? ' / ' + noteCtx.task.cptCode : ''}`} onClose={() => setNoteCtx(null)}><div className="wl-modal-body"><label>Status<select className="wl-full" value={noteStatus} onChange={e => setNoteStatus(e.target.value)}>{statusOptions.map(x => <option key={x}>{x}</option>)}</select></label><label>Comments<textarea className="wl-textarea" value={noteText} onChange={e => setNoteText(e.target.value)} placeholder="Enter comments..." /></label><button className="wl-btn teal" onClick={saveNote}>Save comments</button><h4>History</h4>{notes.map(n => <div className="wl-history" key={n.noteId}><div>{n.noteText}</div><small>{n.createdBy} · {fmtDate(n.createdOn)}</small></div>)}</div></Modal>}
    {docCtx && <Modal title={`Claim Documents · ${docCtx.claimId}`} onClose={() => setDocCtx(null)}><div className="wl-modal-body"><input type="file" multiple onChange={e => setDocFiles(e.target.files)} /><textarea className="wl-textarea" value={docComment} onChange={e => setDocComment(e.target.value)} placeholder="Document comment..." /><button className="wl-btn teal" onClick={uploadDocs}>Upload documents</button><h4>Uploaded documents</h4>{docs.map(d => <div className="wl-history" key={d.documentId}><b>{d.originalFileName}</b><div>{d.comment}</div><small>{d.uploadedBy} · {fmtDate(d.uploadedOn)} · {Math.round(Number(d.fileSizeBytes || 0) / 1024)} KB</small></div>)}</div></Modal>}
    {escCtx && <Modal title={`${escCtx.level} Escalation · ${escCtx.claim.claimId}${escCtx.task ? ' / ' + escCtx.task.cptCode : ''}`} onClose={() => setEscCtx(null)}><div className="wl-modal-body"><label>Escalation reason<select className="wl-full" value={escReason} onChange={e => setEscReason(e.target.value)}>{(escCtx.level === 'Claim' ? claimEscReasons : lineEscReasons).map(x => <option key={x}>{x}</option>)}</select></label><label>Escalation comments<textarea className="wl-textarea" value={escComment} onChange={e => setEscComment(e.target.value)} placeholder="Explain what manager has to review..." /></label><button className="wl-btn red" onClick={saveEscalation}>Submit escalation</button><h4>Escalation history</h4>{escalations.map(x => <div className="wl-history" key={x.escalationId}><b>{x.escalationReason}</b><div>{x.comments}</div><small>{x.status} · {x.createdBy} · {fmtDate(x.createdOn)}</small></div>)}</div></Modal>}
  </div>;
}
