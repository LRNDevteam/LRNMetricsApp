import React, { useState } from 'react';
import Pager from '../components/Pager';
import { money, date } from '../utils/formatters';
import { denialWorkflowService } from '../services/denialWorkflowService';

export default function ClaimAssignmentPage({ data, reviewers, selected, setSelected, bulkReviewer, setBulkReviewer, loadClaimTasks, claimTasks, expandedClaim, assignClaims, changePage, labId, currentUser }) {
  const [notePopup, setNotePopup] = useState(null);
  const [docPopup, setDocPopup] = useState(null);
  const [historyPopup, setHistoryPopup] = useState(null);
  const [noteText, setNoteText] = useState('');
  const [uploadFiles, setUploadFiles] = useState([]);
  const [uploadComment, setUploadComment] = useState('');
  const [noteHistory, setNoteHistory] = useState([]);
  const [documents, setDocuments] = useState([]);
  const [busy, setBusy] = useState(false);
  const items = data.items || [];
  const getClaimId = (r) => String(r?.claimId ?? r?.claimID ?? r?.ClaimId ?? r?.ClaimID ?? '').trim();
  const all = items.length > 0 && items.every((_, i) => selected[i]);
  const selectedClaimIds = items.filter((_, i) => selected[i]).map(getClaimId).filter(Boolean);

  async function loadNotes(info) {
    const rows = await denialWorkflowService.getNotes({ labId, claimId: info.claimId, taskId: info.taskId, cptCode: info.cptCode, noteLevel: info.type });
    setNoteHistory(rows || []);
  }

  async function openClaimNotes(row) {
    const claimId = getClaimId(row);
    const info = { type: 'Claim', claimId, title: `Claim Notes — ${claimId}`, meta: `${row.payerName || '-'} · ${row.patientName || '-'} · DOS ${date(row.dateOfService)}` };
    setNotePopup(info); setNoteText(''); setNoteHistory([]);
    try { await loadNotes(info); } catch { }
  }

  async function openLineNotes(task, claimId) {
    const info = { type: 'Line', claimId, taskId: task.taskId || '', cptCode: task.cptCode || '', title: `Line Notes — ${claimId} / CPT ${task.cptCode || '-'}`, meta: `${task.taskId || '-'} · ${task.denialCode || '-'} · ${task.denialClassification || '-'}` };
    setNotePopup(info); setNoteText(''); setNoteHistory([]);
    try { await loadNotes(info); } catch { }
  }

  async function saveNote() {
    if (!notePopup || !noteText.trim()) return;
    setBusy(true);
    try {
      await denialWorkflowService.saveNote({ labId, claimId: notePopup.claimId, taskId: notePopup.taskId, cptCode: notePopup.cptCode, noteLevel: notePopup.type, noteText, createdBy: currentUser });
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
    if (!docPopup || !uploadFiles.length) return;
    setBusy(true);
    try {
      await denialWorkflowService.uploadClaimDocuments(labId, docPopup.claimId, uploadComment, currentUser, uploadFiles);
      setUploadFiles([]); setUploadComment('');
      setDocuments(await denialWorkflowService.getClaimDocuments(labId, docPopup.claimId) || []);
    } finally { setBusy(false); }
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

  return <>
    <div className="lrn-card assignment-toolbar claim-assign-toolbar">
      <div className="assign-left"><strong>Selected claims:</strong> <span>{selectedClaimIds.length}</span><small>Assigning a claim assigns all matching DenialTaskBoard task rows for that claim.</small></div>
      <div className="assign-right"><select value={bulkReviewer} onChange={e => setBulkReviewer(e.target.value)}><option value="">Select AR Reviewer</option>{reviewers.map(r => <option key={r.userName} value={r.userName}>{r.displayName || r.userName}</option>)}</select><button className="topbar-btn teal" onClick={() => assignClaims(selectedClaimIds, bulkReviewer)}><i className="bi bi-person-check" />Assign Selected Claims</button></div>
    </div>

    <div className="lrn-card claim-card">
      <div className="lrn-card-header claim-card-hd"><div><div className="lrn-card-title">Claim Level Assignment</div><small className="claim-subtitle">VisitNumber grouped claim rows. Click a claim to expand task details under the row.</small></div><span className="table-count">Showing {items.length} of {data.totalCount || items.length} claim(s)</span></div>
      <div className="dt-wrap claim-assign-scroll">
        <table className="lrn-table workflow-table claim-assign-table"><thead><tr><th className="sticky-col select-col"><input type="checkbox" checked={all} onChange={e => { const next = {}; if (e.target.checked) items.forEach((_, i) => next[i] = true); setSelected(next); }} /></th><th>Claim ID</th><th>Payer Name</th><th>Panel Name</th><th>Patient Name</th><th>Patient DOB</th><th>Date Of Service</th><th>Clinic Name</th><th>Referring Provider</th><th className="text-right">Insurance Balance</th><th>Claim Note</th><th>Assign</th></tr></thead>
          <tbody>{items.length ? items.map((r, i) => { const claimId = getClaimId(r); const isOpen = expandedClaim === claimId; const tasks = claimTasks?.[claimId] || []; return <React.Fragment key={`${claimId || 'claim'}-${i}`}><tr className={`claim-row-ui ${isOpen ? 'open' : ''}`}><td className="sticky-col select-col"><input type="checkbox" checked={!!selected[i]} onChange={e => setSelected({ ...selected, [i]: e.target.checked })} /></td><td><button className="claim-id-link" type="button" disabled={!claimId} onClick={() => loadClaimTasks(claimId)}>{isOpen ? '▼ ' : '▶ '}{claimId || '-'}</button></td><td>{r.payerName || '-'}</td><td>{r.panelName || '-'}</td><td>{r.patientName || '-'}</td><td>{date(r.patientDOB)}</td><td>{date(r.dateOfService)}</td><td>{r.clinicName || '-'}</td><td>{r.referringProvider || '-'}</td><td className="text-right claim-money">{money(r.insuranceBalance)}</td><td><button className="note-btn-ui" type="button" onClick={() => openClaimNotes(r)}><i className="bi bi-journal-text" /><span>+</span></button></td><td><button className="mini-btn" type="button" onClick={() => assignClaims([claimId], bulkReviewer)} disabled={!claimId}>Assign</button></td></tr>{isOpen && <tr className="claim-task-expanded-row"><td colSpan="12"><InlineClaimTaskDrill claimId={claimId} tasks={tasks} openClaimNotes={() => openClaimNotes(r)} openLineNotes={openLineNotes} openClaimDocuments={openClaimDocuments} openAssignmentHistory={openAssignmentHistory} /></td></tr>}</React.Fragment>; }) : <tr><td colSpan="12" className="empty-cell">No claim records found.</td></tr>}</tbody></table>
      </div>
    </div>
    <Pager data={data} changePage={changePage} />

    {notePopup && <div className="modal-backdrop"><div className="note-modal"><div className="note-modal-hd"><div><strong>{notePopup.title}</strong><small>{notePopup.meta}</small></div><button className="modal-close" onClick={() => setNotePopup(null)}>×</button></div><div className="note-modal-body"><div className="info-strip">{notePopup.type === 'Claim' ? 'Claim note applies to the entire claim, all CPT lines and all tasks.' : 'Line note applies only to this CPT/task row.'}</div><textarea value={noteText} onChange={e => setNoteText(e.target.value)} placeholder={`Add ${notePopup.type.toLowerCase()} note...`} /><div className="note-actions"><button className="topbar-btn teal" type="button" disabled={busy || !noteText.trim()} onClick={saveNote}>Save note</button></div><div className="modal-list">{noteHistory.length ? noteHistory.map(n => <div className="modal-row" key={n.noteId}><div className="modal-row-title">{n.noteText}</div><div className="modal-row-meta">{n.createdBy || '-'} · {date(n.createdOn)}</div></div>) : <div className="modal-row"><div className="modal-row-title">No previous notes found</div><div className="modal-row-meta">Saved claim and line notes will show here.</div></div>}</div></div><div className="note-modal-ft"><button className="topbar-btn" onClick={() => setNotePopup(null)}>Close</button></div></div></div>}

    {docPopup && <div className="modal-backdrop"><div className="note-modal doc-modal"><div className="note-modal-hd"><div><strong>{docPopup.title}</strong><small>Upload multiple supporting documents for this claim with a comment.</small></div><button className="modal-close" onClick={() => setDocPopup(null)}>×</button></div><div className="note-modal-body"><textarea className="upload-comment" value={uploadComment} onChange={e => setUploadComment(e.target.value)} placeholder="Document comment..." /><div className="upload-drop"><i className="bi bi-cloud-arrow-up" /><strong>Upload claim document</strong><span>PDF, image, Excel, Word or EOB/supporting files</span><input type="file" multiple onChange={e => setUploadFiles(Array.from(e.target.files || []))} /></div><div className="note-actions"><button className="topbar-btn teal" type="button" disabled={busy || !uploadFiles.length} onClick={uploadDocuments}>Upload document</button></div><div className="modal-list upload-file-list">{uploadFiles.map((f, i) => <div className="modal-row" key={`${f.name}-${i}`}><div className="modal-row-title">{f.name}</div><div className="modal-row-meta">{Math.ceil(f.size / 1024)} KB · Ready to upload</div></div>)}{documents.length ? documents.map(d => <div className="modal-row" key={d.documentId}><div className="modal-row-title">{d.originalFileName}</div><div className="modal-row-meta">{Math.ceil((d.fileSizeBytes || 0) / 1024)} KB · {d.uploadedBy || '-'} · {date(d.uploadedOn)} {d.comment ? `· ${d.comment}` : ''}</div></div>) : !uploadFiles.length && <div className="modal-row"><div className="modal-row-title">No document uploaded</div><div className="modal-row-meta">Choose files above to attach them to claim {docPopup.claimId}.</div></div>}</div></div><div className="note-modal-ft"><button className="topbar-btn" onClick={() => setDocPopup(null)}>Close</button></div></div></div>}

    {historyPopup && <div className="modal-backdrop"><div className="note-modal"><div className="note-modal-hd"><div><strong>{historyPopup.title}</strong><small>Claim note and document history.</small></div><button className="modal-close" onClick={() => setHistoryPopup(null)}>×</button></div><div className="note-modal-body"><div className="modal-list"><div className="modal-row"><div className="modal-row-title">Claim notes</div><div className="modal-row-meta">{noteHistory.length} note(s)</div></div>{noteHistory.map(n => <div className="modal-row" key={n.noteId}><div className="modal-row-title">{n.noteText}</div><div className="modal-row-meta">{n.createdBy || '-'} · {date(n.createdOn)}</div></div>)}<div className="modal-row"><div className="modal-row-title">Documents</div><div className="modal-row-meta">{documents.length} document(s)</div></div>{documents.map(d => <div className="modal-row" key={d.documentId}><div className="modal-row-title">{d.originalFileName}</div><div className="modal-row-meta">{d.uploadedBy || '-'} · {date(d.uploadedOn)} {d.comment ? `· ${d.comment}` : ''}</div></div>)}</div></div><div className="note-modal-ft"><button className="topbar-btn" onClick={() => setHistoryPopup(null)}>Close</button></div></div></div>}
  </>;
}

function InlineClaimTaskDrill({ claimId, tasks, openClaimNotes, openLineNotes, openClaimDocuments, openAssignmentHistory }) {
  return <div className="cpt-wrap"><div className="claim-drill-header claim-drill-header-compact"><div className="claim-level-actions-left"><button className="claim-action-icon" title="Claim notes" type="button" onClick={openClaimNotes}><i className="bi bi-journal-text" /></button><button className="claim-action-icon" title="Upload claim documents" type="button" onClick={() => openClaimDocuments(claimId)}><i className="bi bi-cloud-arrow-up" /></button><button className="claim-action-icon" title="Claim history" type="button" onClick={() => openAssignmentHistory(claimId)}><i className="bi bi-clock-history" /></button></div><div className="claim-drill-title-block"><div className="cpt-title" style={{ marginBottom: 0 }}>Line-level task view</div><div className="line-note-hint">Claim-level icons are on the left. Line notes are saved per task/CPT row.</div></div></div><div className="cpt-scroll"><table className="cpt-tbl line-task-grid"><thead><tr><th className="task-sticky task-id-col">Task ID</th><th className="task-sticky claim-id-col">Claim ID</th><th>CPT Code</th><th>Units</th><th>Modifier</th><th>Denial Code</th><th>Denial Classification</th><th>ICD Codes</th><th>ICD Status</th><th>Coverage</th><th>Validity</th><th>SLA Days</th><th>SLA Status</th><th>Assigned To</th><th className="r">Insurance Balance</th><th>Action Category</th><th>Action Code</th><th>Date Of Service</th><th>Recommended Action</th><th>Task</th><th>Days Remaining</th><th>Line Notes</th></tr></thead><tbody>{tasks.length ? tasks.map((t, i) => <tr key={t.taskId || i}><td className="task-sticky task-id-col"><strong>{t.taskId || '-'}</strong></td><td className="task-sticky claim-id-col"><strong>{t.claimId || claimId || '-'}</strong></td><td><code className="code">{t.cptCode || '-'}</code></td><td>{t.units ?? '-'}</td><td>{t.modifier || '-'}</td><td><code className="code">{t.denialCode || '-'}</code></td><td>{t.denialClassification || '-'}</td><td><code className="code">{t.icdCodes || '-'}</code></td><td>{t.icdComplianceStatus || '-'}</td><td>{t.coverageStatus || '-'}</td><td>{t.denialValidity || '-'}</td><td>{t.slaDays ?? '-'}</td><td>{t.slaStatus || '-'}</td><td>{t.assignedTo || '-'}</td><td className="r">{money(t.insuranceBalance)}</td><td>{t.actionCategory || '-'}</td><td>{t.actionCode || '-'}</td><td>{date(t.dateOfService)}</td><td className="task-action-cell">{t.recommendedAction || '-'}</td><td className="task-action-cell">{t.task || '-'}</td><td className="days-cell">{t.daysRemaining ?? '-'}</td><td><button className="note-btn-ui" type="button" onClick={() => openLineNotes(t, claimId)}><i className="bi bi-chat-left-text" /><span>+</span></button></td></tr>) : <tr><td colSpan="22" className="empty-cell">No tasks found for this claim.</td></tr>}</tbody></table></div></div>;
}
