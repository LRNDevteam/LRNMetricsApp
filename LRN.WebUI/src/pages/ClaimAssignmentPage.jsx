import React, { useMemo, useState } from 'react';
import Pager from '../components/Pager';
import { money, date, statusClass } from '../utils/formatters';
import { denialWorkflowService } from '../services/denialWorkflowService';

const noteStatusOptions = ['Open', 'In Progress', 'Pending Payer', 'Pending Documentation', 'Escalated', 'Closed'];
const escalationReasons = ['EOB Pending', 'Client Info Pending', 'Document Required', 'Others'];

export default function ClaimAssignmentPage({ data, reviewers, selected, setSelected, bulkReviewer, setBulkReviewer, loadClaimTasks, claimTasks, expandedClaim, assignClaims, changePage, labId, currentUser, canAssign = false, readOnlyWorkflow = false, taskView = 'unassigned', setTaskView = () => {}, setMessage = () => {} }) {
  const [notePopup, setNotePopup] = useState(null);
  const [docPopup, setDocPopup] = useState(null);
  const [historyPopup, setHistoryPopup] = useState(null);
  const [noteText, setNoteText] = useState('');
  const [noteStatus, setNoteStatus] = useState('In Progress');
  const [noteFollowUpDate, setNoteFollowUpDate] = useState('');
  const [uploadFiles, setUploadFiles] = useState([]);
  const [uploadComment, setUploadComment] = useState('');
  const [noteHistory, setNoteHistory] = useState([]);
  const [documents, setDocuments] = useState([]);
  const [busy, setBusy] = useState(false);
  const [escalationAssignee, setEscalationAssignee] = useState('');
  const [escalationPopup, setEscalationPopup] = useState(null);
  const [escalationReason, setEscalationReason] = useState('Client Info Pending');
  const [escalationComment, setEscalationComment] = useState('');
  const [escalationFollowUpDate, setEscalationFollowUpDate] = useState('');
  const [escalationOtherReason, setEscalationOtherReason] = useState('');
  const items = data.items || [];
  const getClaimId = (r) => String(r?.claimId ?? r?.claimID ?? r?.ClaimId ?? r?.ClaimID ?? '').trim();
  const all = canAssign && items.length > 0 && items.every((_, i) => selected[i]);
  const selectedClaimIds = canAssign ? items.filter((_, i) => selected[i]).map(getClaimId).filter(Boolean) : [];
  const loadedCount = items.length;
  const totalCount = data.totalCount || loadedCount;
  const claimTabs = useMemo(() => [
    { key: 'unassigned', label: 'New / Unassigned', hint: 'Not assigned and not closed' },
    { key: 'assigned', label: 'Assigned', hint: 'Assigned and still active' },
    { key: 'closed', label: 'Closed', hint: 'Completed / closed by reviewer' },
    { key: 'escalations', label: 'Escalated Claims', hint: 'Escalated or SLA risk items' }
  ], []);
  const activeTab = useMemo(() => claimTabs.find(t => t.key === taskView) || claimTabs[0], [claimTabs, taskView]);
  const normalizeRole = value => String(value || '').replace(/[^a-z0-9]/gi, '').toLowerCase();
  const arReviewers = useMemo(() => (reviewers || []).filter(r => {
    const role = normalizeRole(r.role || r.Role);
    return !role || role.includes('arreviewer') || role.includes('analyst') || role.includes('analyser') || (role.includes('reviewer') && !role.includes('manager'));
  }), [reviewers]);
  const escalationAssignees = useMemo(() => (reviewers || []).filter(r => {
    const role = normalizeRole(r.role || r.Role);
    return role.includes('clientmanager') || role.includes('accountmanager');
  }), [reviewers]);
  const escalationAssigneeOption = useMemo(() => escalationAssignees.find(r => (r.userName || r.UserName) === escalationAssignee), [escalationAssignees, escalationAssignee]);

  async function loadNotes(info) {
    const rows = await denialWorkflowService.getNotes({ labId, claimId: info.claimId, taskId: info.taskId, cptCode: info.cptCode, noteLevel: info.type });
    setNoteHistory(rows || []);
  }

  async function openClaimNotes(row) {
    const claimId = getClaimId(row);
    const info = { type: 'Claim', claimId, title: `Claim Notes — ${claimId}`, meta: `${row.payerName || '-'} · ${row.patientName || '-'} · DOS ${date(row.dateOfService)}` };
    setNotePopup(info); setNoteText(''); setNoteStatus(row.status || row.claimStatus || 'In Progress'); setNoteFollowUpDate(''); setNoteHistory([]);
    try { await loadNotes(info); } catch { }
  }

  async function openLineNotes(task, claimId) {
    const info = { type: 'Line', claimId, taskId: task.taskId || '', cptCode: task.cptCode || '', title: `Line Notes — ${claimId} / CPT ${task.cptCode || '-'}`, meta: `${task.taskId || '-'} · ${task.denialCode || '-'} · ${task.denialClassification || '-'}` };
    setNotePopup(info); setNoteText(''); setNoteStatus(task.status || 'In Progress'); setNoteFollowUpDate(''); setNoteHistory([]);
    try { await loadNotes(info); } catch { }
  }

  async function saveNote() {
    if (readOnlyWorkflow) return;
    if (!notePopup || !noteText.trim()) return;
    setBusy(true);
    try {
      await denialWorkflowService.saveNote({ labId, claimId: notePopup.claimId, taskId: notePopup.taskId, cptCode: notePopup.cptCode, noteLevel: notePopup.type, noteText, status: noteStatus, nextFollowUpDate: noteFollowUpDate || null, createdBy: currentUser });
      setNoteText('');
      await loadNotes(notePopup);
    } finally { setBusy(false); }
  }

  async function openClaimDocuments(claimId) {
    setDocPopup({ claimId, title: `Claim Documents — ${claimId}` });
    setUploadFiles([]); setUploadComment(''); setDocuments([]);
    try { setDocuments(await denialWorkflowService.getClaimDocuments(labId, claimId) || []); } catch { }
  }

  async function uploadDocuments() {
    if (readOnlyWorkflow) return;
    if (!docPopup || !uploadFiles.length) return;
    setBusy(true);
    try {
      await denialWorkflowService.uploadClaimDocuments(labId, docPopup.claimId, uploadComment, currentUser, uploadFiles);
      setUploadFiles([]); setUploadComment('');
      setDocuments(await denialWorkflowService.getClaimDocuments(labId, docPopup.claimId) || []);
    } finally { setBusy(false); }
  }

  function openEscalation(target) {
    if (!canAssign) return setMessage({ type: 'warning', text: 'Only Admin and AR Manager users can escalate claims/tasks.' });
    if (!target || !target.claimIds?.length) return setMessage({ type: 'warning', text: 'Please select one or more claim rows.' });
    setEscalationPopup(target);
    setEscalationReason('Client Info Pending');
    setEscalationComment('');
    setEscalationAssignee('');
    setEscalationFollowUpDate('');
    setEscalationOtherReason('');
  }

  async function escalateSelectedClaims() {
    openEscalation({ level: 'Claim', claimIds: selectedClaimIds, title: `Escalate ${selectedClaimIds.length} selected claim(s)` });
  }

  async function submitEscalationPopup() {
    if (!canAssign) return;
    if (!escalationPopup?.claimIds?.length) return setMessage({ type: 'warning', text: 'Please select one or more claims/tasks.' });
    if (!escalationAssignee) return setMessage({ type: 'warning', text: 'Please select Client Manager or Account Manager.' });
    if (escalationReason === 'Others' && !escalationOtherReason.trim()) return setMessage({ type: 'warning', text: 'Please enter other escalation reason.' });
    if (!escalationComment.trim()) return setMessage({ type: 'warning', text: 'Please enter escalation comments.' });

    const finalEscalationReason = escalationReason === 'Others' ? `Others - ${escalationOtherReason.trim()}` : escalationReason;
    const finalEscalationComment = escalationReason === 'Others' ? `Other Reason: ${escalationOtherReason.trim()}${escalationComment ? '\n' + escalationComment : ''}` : escalationComment;
    const assignee = escalationAssigneeOption || {};
    const assigneeName = assignee.userName || assignee.UserName || escalationAssignee;
    const assigneeRole = assignee.role || assignee.Role || '';
    setBusy(true);
    try {
      await Promise.all(escalationPopup.claimIds.map(claimId => denialWorkflowService.saveEscalation({
        labId,
        claimId,
        taskId: escalationPopup.taskId || '',
        cptCode: escalationPopup.cptCode || '',
        escalationLevel: escalationPopup.level || 'Claim',
        escalationReason: finalEscalationReason,
        comments: finalEscalationComment,
        status: 'Open',
        nextFollowUpDate: escalationFollowUpDate || null,
        createdBy: currentUser || 'ReactWorkflow',
        escalatedTo: assigneeName,
        escalatedToRole: assigneeRole
      })));
      setSelected({});
      setEscalationPopup(null);
      setMessage({ type: 'success', text: `Escalated ${escalationPopup.claimIds.length} ${String(escalationPopup.level || 'Claim').toLowerCase()} item(s) to ${assigneeName}.` });
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Escalation failed.' });
    } finally {
      setBusy(false);
    }
  }

  async function openAssignmentHistory(claimId) {
    setHistoryPopup({ claimId, title: `Claim History — ${claimId}` });
    setNoteHistory([]); setDocuments([]);
    try {
      const [claimNotes, docs] = await Promise.all([
        denialWorkflowService.getNotes({ labId, claimId, noteLevel: 'Claim' }),
        denialWorkflowService.getClaimDocuments(labId, claimId)
      ]);
      setNoteHistory(claimNotes || []); setDocuments(docs || []);
    } catch { }
  }

  const statusLabel = useMemo(() => {
    if (taskView === 'assigned') return 'Assigned';
    if (taskView === 'closed') return 'Closed';
    if (taskView === 'escalations') return 'Escalated';
    return 'New';
  }, [taskView]);

  const tableColSpan = canAssign ? 15 : 13;

  return <>
    {canAssign && (
      <div className="lrn-card assignment-toolbar claim-assign-toolbar">
        <div className="assign-left"><strong>Selected claims:</strong> <span>{selectedClaimIds.length}</span><small>Assigning a claim assigns all matching DenialTaskBoard task rows for that claim.</small></div>
        <div className="assign-right"><select value={bulkReviewer} onChange={e => setBulkReviewer(e.target.value)}><option value="">Select AR Reviewer</option>{arReviewers.map(r => <option key={r.userName || r.UserName} value={r.userName || r.UserName}>{r.displayName || r.DisplayName || r.userName || r.UserName}</option>)}</select><button className="wl-btn teal" onClick={() => assignClaims(selectedClaimIds, bulkReviewer)}><i className="bi bi-person-check" />{' '}Assign Selected Claims</button><button className="wl-btn red" type="button" disabled={busy || !selectedClaimIds.length} onClick={escalateSelectedClaims}><i className="bi bi-exclamation-triangle" />{' '}Escalate</button></div>
      </div>
    )}

    <div className="lrn-card claim-card">
      <div className="lrn-card-header claim-card-hd"><div><div className="lrn-card-title">{canAssign ? 'Claim Level Assignment' : 'Claim Level View'} · {activeTab.label}</div><small className="claim-subtitle">VisitNumber grouped claim rows filtered by selected tab. Click a claim to expand task details under the row.</small></div><span className="table-count">Showing {loadedCount} of {totalCount} claim(s)</span></div>
      <div className="dt-wrap claim-assign-scroll">
        <table className={`lrn-table workflow-table claim-assign-table thin-bordered ${canAssign ? '' : 'claim-view-only-table'}`}><thead><tr>{canAssign && <th className="sticky-col select-col"><input type="checkbox" checked={all} onChange={e => { const next = {}; if (e.target.checked) items.forEach((_, i) => next[i] = true); setSelected(next); }} /></th>}<th>Claim ID</th><th>Payer Name</th><th>Panel Name</th><th>Patient Name</th><th>Patient DOB</th><th>Date Of Service</th><th>Created On</th><th>Clinic Name</th><th>Referring Provider</th><th className="text-right">Insurance Balance</th><th>Assigned To</th><th>Status</th>{canAssign && <th>Assign</th>}<th>Actions</th></tr></thead>
          <tbody>{items.length ? items.map((r, i) => { const claimId = getClaimId(r); const isOpen = expandedClaim === claimId; const tasks = claimTasks?.[claimId] || []; const rowStatus = r.status || r.claimStatus || r.taskStatus || statusLabel; return <React.Fragment key={`${claimId || 'claim'}-${i}`}><tr className={`claim-row-ui ${isOpen ? 'open' : ''}`}>{canAssign && <td className="sticky-col select-col"><input type="checkbox" checked={!!selected[i]} onChange={e => setSelected({ ...selected, [i]: e.target.checked })} /></td>}<td><button className="claim-id-link" type="button" disabled={!claimId} onClick={() => loadClaimTasks(claimId)}><i className={`bi ${isOpen ? 'bi-chevron-down' : 'bi-chevron-right'}`} /> {claimId || '-'}</button></td><td className="payer-full-cell" title={r.payerName || ''}>{r.payerName || '-'}</td><td>{r.panelName || '-'}</td><td>{r.patientName || '-'}</td><td>{date(r.patientDOB)}</td><td>{date(r.dateOfService)}</td><td>{date(r.createdOn)}</td><td>{r.clinicName || '-'}</td><td>{r.referringProvider || '-'}</td><td className="text-right claim-money">{money(r.insuranceBalance)}</td><td className="assigned-to-cell" title={r.assignedTo || ''}>{r.assignedTo || '-'}</td><td><span className={`badge ${statusClass(rowStatus)}`}>{rowStatus}</span></td>{canAssign && <td><button className="wl-btn teal xs" type="button" onClick={() => assignClaims([claimId], bulkReviewer)} disabled={!claimId}>Assign</button></td>}<td><div className="claim-row-actions"><button className="wl-icon icon-note" title={readOnlyWorkflow ? 'View claim notes' : 'Claim notes'} type="button" onClick={() => openClaimNotes(r)}><i className="bi bi-pencil-square" /></button><button className="wl-icon icon-doc" title={readOnlyWorkflow ? 'View documents' : 'Upload documents'} type="button" disabled={!claimId} onClick={() => openClaimDocuments(claimId)}><i className="bi bi-paperclip" /></button>{canAssign && <button className="wl-btn red xs" type="button" disabled={!claimId} onClick={() => openEscalation({ level: 'Claim', claimIds: [claimId], title: `Escalate claim ${claimId}` })}>Escalate</button>}</div></td></tr>{isOpen && <tr className="claim-task-expanded-row"><td colSpan={tableColSpan}><InlineClaimTaskDrill claimId={claimId} tasks={tasks} openClaimNotes={() => openClaimNotes(r)} openLineNotes={openLineNotes} openClaimDocuments={openClaimDocuments} openAssignmentHistory={openAssignmentHistory} readOnlyWorkflow={readOnlyWorkflow} canAssign={canAssign} openEscalation={openEscalation} /></td></tr>}</React.Fragment>; }) : <tr><td colSpan={tableColSpan} className="empty-cell">No claim records found.</td></tr>}</tbody></table>
        <div style={{ padding: '10px 12px', textAlign: 'center', fontSize: 11, color: '#64748b' }}>
          {loadedCount ? <span>Showing page {data.page || 1} · {loadedCount} of {totalCount} matching claim(s).</span> : null}
        </div>
      </div>
    </div>
    <Pager data={data} changePage={changePage} />

    {notePopup && <div className="modal-backdrop"><div className="note-modal"><div className="note-modal-hd"><div><strong>{notePopup.title}</strong><small>{notePopup.meta}</small></div><button className="modal-close" onClick={() => setNotePopup(null)}>×</button></div><div className="note-modal-body"><div className="info-strip">{notePopup.type === 'Claim' ? 'Claim note applies to the entire claim, all CPT lines and all tasks.' : 'Line note applies only to this CPT/task row.'}</div>{!readOnlyWorkflow && <><div className="note-form-grid"><label>Status<select className="wl-full" value={noteStatus} onChange={e => setNoteStatus(e.target.value)}>{noteStatusOptions.map(x => <option key={x}>{x}</option>)}</select></label><label>Next follow-up date<input type="date" value={noteFollowUpDate} onChange={e => setNoteFollowUpDate(e.target.value)} /></label></div><textarea value={noteText} onChange={e => setNoteText(e.target.value)} placeholder={`Add ${notePopup.type.toLowerCase()} note...`} /><div className="note-actions"><button className="wl-btn teal" type="button" disabled={busy || !noteText.trim()} onClick={saveNote}>Save note</button></div></>}<div className="modal-list">{noteHistory.length ? noteHistory.map(n => <div className="modal-row" key={n.noteId}><div className="modal-row-title">{n.noteText}</div><div className="modal-row-meta">{n.status ? `Status: ${n.status} · ` : ''}{n.nextFollowUpDate ? `Follow-up: ${date(n.nextFollowUpDate)} · ` : ''}{n.createdBy || '-'} · {date(n.createdOn)}</div></div>) : <div className="modal-row"><div className="modal-row-title">No previous notes found</div><div className="modal-row-meta">Saved claim and line notes will show here.</div></div>}</div></div><div className="note-modal-ft"><button className="wl-btn" onClick={() => setNotePopup(null)}>Close</button></div></div></div>}

    {escalationPopup && <div className="modal-backdrop"><div className="note-modal"><div className="note-modal-hd"><div><strong>{escalationPopup.title || 'Escalate'}</strong><small>Select manager, reason, comments and next follow-up date.</small></div><button className="modal-close" onClick={() => setEscalationPopup(null)}>×</button></div><div className="note-modal-body"><div className="note-form-grid"><label>Escalation value<select className="wl-full" value={escalationReason} onChange={e => setEscalationReason(e.target.value)}>{escalationReasons.map(x => <option key={x}>{x}</option>)}</select></label><label>Client / Account Manager<select className="wl-full" value={escalationAssignee} onChange={e => setEscalationAssignee(e.target.value)}><option value="">Select Client / Account Manager</option>{escalationAssignees.map(r => <option key={r.userName || r.UserName} value={r.userName || r.UserName}>{r.displayName || r.DisplayName || r.userName || r.UserName} — {r.role || r.Role}</option>)}</select></label><label>Next follow-up date<input type="date" value={escalationFollowUpDate} onChange={e => setEscalationFollowUpDate(e.target.value)} /></label>{escalationReason === 'Others' && <label className="span2">Other reason<input value={escalationOtherReason} onChange={e => setEscalationOtherReason(e.target.value)} placeholder="Enter other escalation reason..." /></label>}</div><textarea value={escalationComment} onChange={e => setEscalationComment(e.target.value)} placeholder="Enter escalation comments..." /><div className="note-actions"><button className="wl-btn red" type="button" disabled={busy || !escalationComment.trim() || !escalationAssignee || (escalationReason === 'Others' && !escalationOtherReason.trim())} onClick={submitEscalationPopup}>Submit escalation</button></div></div><div className="note-modal-ft"><button className="wl-btn" onClick={() => setEscalationPopup(null)}>Close</button></div></div></div>}

    {docPopup && <div className="modal-backdrop"><div className="note-modal doc-modal"><div className="note-modal-hd"><div><strong>{docPopup.title}</strong><small>Upload multiple supporting documents for this claim with a comment.</small></div><button className="modal-close" onClick={() => setDocPopup(null)}>×</button></div><div className="note-modal-body">{!readOnlyWorkflow && <><textarea className="upload-comment" value={uploadComment} onChange={e => setUploadComment(e.target.value)} placeholder="Document comment..." /><div className="upload-drop"><i className="bi bi-cloud-arrow-up" /><strong>Upload claim document</strong><span>PDF, image, Excel, Word or EOB/supporting files</span><input type="file" multiple onChange={e => setUploadFiles(Array.from(e.target.files || []))} /></div><div className="note-actions"><button className="wl-btn teal" type="button" disabled={busy || !uploadFiles.length} onClick={uploadDocuments}>Upload document</button></div></>}<div className="modal-list upload-file-list">{uploadFiles.map((f, i) => <div className="modal-row" key={`${f.name}-${i}`}><div className="modal-row-title">{f.name}</div><div className="modal-row-meta">{Math.ceil(f.size / 1024)} KB · Ready to upload</div></div>)}{documents.length ? documents.map(d => <div className="modal-row" key={d.documentId}><div className="modal-row-title">{d.originalFileName}</div><div className="modal-row-meta">{Math.ceil((d.fileSizeBytes || 0) / 1024)} KB · {d.uploadedBy || '-'} · {date(d.uploadedOn)} {d.comment ? `· ${d.comment}` : ''}</div></div>) : !uploadFiles.length && <div className="modal-row"><div className="modal-row-title">No document uploaded</div><div className="modal-row-meta">Choose files above to attach them to claim {docPopup.claimId}.</div></div>}</div></div><div className="note-modal-ft"><button className="wl-btn" onClick={() => setDocPopup(null)}>Close</button></div></div></div>}

    {historyPopup && <div className="modal-backdrop"><div className="note-modal"><div className="note-modal-hd"><div><strong>{historyPopup.title}</strong><small>Claim note and document history.</small></div><button className="modal-close" onClick={() => setHistoryPopup(null)}>×</button></div><div className="note-modal-body"><div className="modal-list"><div className="modal-row"><div className="modal-row-title">Claim notes</div><div className="modal-row-meta">{noteHistory.length} note(s)</div></div>{noteHistory.map(n => <div className="modal-row" key={n.noteId}><div className="modal-row-title">{n.noteText}</div><div className="modal-row-meta">{n.createdBy || '-'} · {date(n.createdOn)}</div></div>)}<div className="modal-row"><div className="modal-row-title">Documents</div><div className="modal-row-meta">{documents.length} document(s)</div></div>{documents.map(d => <div className="modal-row" key={d.documentId}><div className="modal-row-title">{d.originalFileName}</div><div className="modal-row-meta">{d.uploadedBy || '-'} · {date(d.uploadedOn)} {d.comment ? `· ${d.comment}` : ''}</div></div>)}</div></div><div className="note-modal-ft"><button className="wl-btn" onClick={() => setHistoryPopup(null)}>Close</button></div></div></div>}
  </>;
}

function InlineClaimTaskDrill({ claimId, tasks, openClaimNotes, openLineNotes, openClaimDocuments, openAssignmentHistory, readOnlyWorkflow = false, canAssign = false, openEscalation = () => {} }) {
  return <div className="cpt-wrap"><div className="claim-drill-header claim-drill-header-compact"><div className="claim-level-actions-left"><button className="wl-icon icon-note" title="Claim notes" type="button" onClick={openClaimNotes}><i className="bi bi-pencil-square" /></button><button className="wl-icon icon-doc" title="Upload claim documents" type="button" onClick={() => openClaimDocuments(claimId)}><i className="bi bi-paperclip" /></button><button className="wl-icon icon-history" title="Claim history" type="button" onClick={() => openAssignmentHistory(claimId)}><i className="bi bi-clock-history" /></button></div><div className="claim-drill-title-block"><div className="cpt-title" style={{ marginBottom: 0 }}>Line-level task view</div><div className="line-note-hint">Claim-level icons are on the left. Line notes are saved per task/CPT row.</div></div></div><div className="cpt-scroll"><table className="cpt-tbl line-task-grid thin-bordered"><thead><tr><th className="task-sticky task-id-col">Task ID</th><th className="task-sticky claim-id-col">Claim ID</th><th>CPT Code</th><th>Units</th><th>Modifier</th><th>Denial Code</th><th className="denial-desc-col">Denial Description</th><th>Denial Classification</th><th>ICD Codes</th><th>ICD Status</th><th>Coverage</th><th>Validity</th><th>SLA Days</th><th>SLA Status</th><th>Assigned To</th><th className="r">Insurance Balance</th><th>Action Category</th><th>Action Code</th><th>Date Of Service</th><th>Recommended Action</th><th>Task</th><th>Days Remaining</th><th>Created On</th><th>Line Notes</th>{canAssign && <th>Escalate</th>}</tr></thead><tbody>{tasks.length ? tasks.map((t, i) => <tr key={t.taskId || i}><td className="task-sticky task-id-col"><strong>{t.taskId || '-'}</strong></td><td className="task-sticky claim-id-col"><strong>{t.claimId || claimId || '-'}</strong></td><td><code className="code">{t.cptCode || '-'}</code></td><td>{t.units ?? '-'}</td><td>{t.modifier || '-'}</td><td><code className="code">{t.denialCode || '-'}</code></td><td className="wrap-wide denial-desc-cell" title={t.denialDescription || ''}>{t.denialDescription || '-'}</td><td>{t.denialClassification || '-'}</td><td><code className="code">{t.icdCodes || '-'}</code></td><td>{t.icdComplianceStatus || '-'}</td><td>{t.coverageStatus || '-'}</td><td>{t.denialValidity || '-'}</td><td>{t.slaDays ?? '-'}</td><td>{t.slaStatus || '-'}</td><td>{t.assignedTo || '-'}</td><td className="r">{money(t.insuranceBalance)}</td><td>{t.actionCategory || '-'}</td><td>{t.actionCode || '-'}</td><td>{date(t.dateOfService)}</td><td className="task-action-cell">{t.recommendedAction || '-'}</td><td className="task-action-cell">{t.task || '-'}</td><td className="days-cell">{t.daysRemaining ?? '-'}</td><td>{date(t.createdOn)}</td><td><button className="wl-icon icon-note" type="button" title={readOnlyWorkflow ? 'View line notes' : 'Line notes'} onClick={() => openLineNotes(t, claimId)}><i className="bi bi-pencil-square" /></button></td>{canAssign && <td><button className="wl-btn red xs" type="button" onClick={() => openEscalation({ level: 'Line', claimIds: [claimId], taskId: t.taskId || '', cptCode: t.cptCode || '', title: `Escalate task ${t.taskId || ''} / CPT ${t.cptCode || '-'}` })}>Escalate</button></td>}</tr>) : <tr><td colSpan={canAssign ? 25 : 24} className="empty-cell">No tasks found for this claim.</td></tr>}</tbody></table></div></div>;
}
