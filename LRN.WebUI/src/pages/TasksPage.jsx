import React, { useState } from 'react';
import Pager from '../components/Pager';
import { statusOptions } from '../utils/options';
import { money, date, statusClass, priorityClass } from '../utils/formatters';
import { denialWorkflowService } from '../services/denialWorkflowService';

const claimEscReasons = ['Payer policy conflict across claim — need manager guidance', 'Multiple CPT lines impacted by same denial', 'Timely filing risk at claim level', 'High value claim requires approval', 'Other'];
const lineEscReasons = ['Payer policy unclear — need guidance', 'Appeal requires manager approval', 'Coding / modifier review required', 'ICD coverage rule requires review', 'Other'];

function Modal({ title, children, onClose }) {
  return <div className="wl-modal-bg"><div className="wl-modal"><div className="wl-modal-hd"><strong>{title}</strong><button className="wl-btn xs" onClick={onClose}>✕</button></div>{children}</div></div>;
}

export default function TasksPage({ data, saveTask, changePage, labId, currentUser }) {
  const items = data.items || [];
  const [noteCtx, setNoteCtx] = useState(null);
  const [noteText, setNoteText] = useState('');
  const [noteStatus, setNoteStatus] = useState('In Progress');
  const [notes, setNotes] = useState([]);
  const [docCtx, setDocCtx] = useState(null);
  const [docs, setDocs] = useState([]);
  const [docComment, setDocComment] = useState('');
  const [docFiles, setDocFiles] = useState([]);
  const [escCtx, setEscCtx] = useState(null);
  const [escReason, setEscReason] = useState(lineEscReasons[0]);
  const [escComment, setEscComment] = useState('');
  const [escalations, setEscalations] = useState([]);
  const [busy, setBusy] = useState(false);

  async function openNote(task) {
    setBusy(true);
    try {
      setNoteCtx(task);
      setNoteText('');
      setNoteStatus(task.status || 'In Progress');
      const data = await denialWorkflowService.getNotes({ labId, claimId: task.claimId, taskId: task.taskId || '', cptCode: task.cptCode || '', noteLevel: 'Line' });
      setNotes(data || []);
    } finally { setBusy(false); }
  }

  async function saveNote() {
    if (!noteText.trim()) return;
    setBusy(true);
    try {
      await denialWorkflowService.saveNote({ labId, claimId: noteCtx.claimId, taskId: noteCtx.taskId || '', cptCode: noteCtx.cptCode || '', noteLevel: 'Line', noteText, createdBy: currentUser || 'ReactWorkflow' });
      await saveTask(noteCtx, noteStatus, noteText);
      setNoteCtx(null);
    } finally { setBusy(false); }
  }

  async function openDocs(task) {
    setBusy(true);
    try {
      setDocCtx(task);
      setDocComment('');
      setDocFiles([]);
      setDocs(await denialWorkflowService.getClaimDocuments(labId, task.claimId));
    } finally { setBusy(false); }
  }

  async function uploadDocs() {
    if (!docFiles?.length) return;
    setBusy(true);
    try {
      await denialWorkflowService.uploadClaimDocuments(labId, docCtx.claimId, docComment, currentUser || 'ReactWorkflow', docFiles);
      setDocs(await denialWorkflowService.getClaimDocuments(labId, docCtx.claimId));
      setDocFiles([]);
      setDocComment('');
    } finally { setBusy(false); }
  }

  async function openEsc(task) {
    setBusy(true);
    try {
      setEscCtx(task);
      setEscReason(task.taskId ? lineEscReasons[0] : claimEscReasons[0]);
      setEscComment('');
      const data = await denialWorkflowService.getEscalations({ labId, claimId: task.claimId, taskId: task.taskId || '', cptCode: task.cptCode || '', escalationLevel: 'Line' });
      setEscalations(data || []);
    } finally { setBusy(false); }
  }

  async function saveEscalation() {
    setBusy(true);
    try {
      await denialWorkflowService.saveEscalation({ labId, claimId: escCtx.claimId, taskId: escCtx.taskId || '', cptCode: escCtx.cptCode || '', escalationLevel: 'Line', escalationReason: escReason, comments: escComment, status: 'Open', createdBy: currentUser || 'ReactWorkflow' });
      await saveTask(escCtx, 'Escalated', `${escReason}${escComment ? ' - ' + escComment : ''}`);
      setEscCtx(null);
    } finally { setBusy(false); }
  }

  return <>
    <div className="lrn-card">
      <div className="lrn-card-header"><div className="lrn-card-title">Task Board</div><span className="table-count">Showing {items.length} of {data.totalCount || 0}</span></div>
      <div className="dt-wrap workflow-scroll"><table className="lrn-table workflow-table"><thead><tr><th className="sticky-col task-tools-col">Actions</th><th>Task ID</th><th>Claim</th><th>Patient</th><th>CPT</th><th>Units</th><th>Modifier</th><th>Denial</th><th>Description</th><th>Classification</th><th>Action Category</th><th>Priority</th><th>Status</th><th>Assigned To</th><th>Insurance Balance</th><th>Due</th><th>SLA</th><th>Payer</th><th>Comments</th></tr></thead><tbody>{items.map((t, i) => <TaskRow key={t.taskId || i} task={t} openNote={openNote} openDocs={openDocs} openEsc={openEsc} />)}</tbody></table></div>
    </div>
    <Pager data={data} changePage={changePage} />

    {noteCtx && <Modal title={`Task Notes · ${noteCtx.taskId || ''}`} onClose={() => setNoteCtx(null)}><div className="wl-modal-body"><label>Status<select className="wl-full" value={noteStatus} onChange={e => setNoteStatus(e.target.value)}>{statusOptions.filter(Boolean).map(x => <option key={x}>{x}</option>)}</select></label><label>Comments<textarea className="wl-textarea" value={noteText} onChange={e => setNoteText(e.target.value)} placeholder="Enter task note..." /></label><button className="wl-btn teal" disabled={busy} onClick={saveNote}>Save note</button><h4>History</h4>{notes.map(n => <div className="wl-history" key={n.noteId}><div>{n.noteText}</div><small>{n.createdBy} · {date(n.createdOn)}</small></div>)}</div></Modal>}
    {docCtx && <Modal title={`Upload Documents · ${docCtx.claimId || ''}`} onClose={() => setDocCtx(null)}><div className="wl-modal-body"><input type="file" multiple onChange={e => setDocFiles(e.target.files)} /><textarea className="wl-textarea" value={docComment} onChange={e => setDocComment(e.target.value)} placeholder="Document comment..." /><button className="wl-btn teal" disabled={busy} onClick={uploadDocs}>Upload documents</button><h4>Uploaded documents</h4>{docs.map(d => <div className="wl-history" key={d.documentId}><b>{d.originalFileName}</b><div>{d.comment}</div><small>{d.uploadedBy} · {date(d.uploadedOn)} · {Math.round(Number(d.fileSizeBytes || 0) / 1024)} KB</small></div>)}</div></Modal>}
    {escCtx && <Modal title={`Escalation · ${escCtx.taskId || ''}`} onClose={() => setEscCtx(null)}><div className="wl-modal-body"><label>Escalation reason<select className="wl-full" value={escReason} onChange={e => setEscReason(e.target.value)}>{lineEscReasons.map(x => <option key={x}>{x}</option>)}</select></label><label>Escalation comments<textarea className="wl-textarea" value={escComment} onChange={e => setEscComment(e.target.value)} placeholder="Explain what manager has to review..." /></label><button className="wl-btn red" disabled={busy} onClick={saveEscalation}>Submit escalation</button><h4>Escalation history</h4>{escalations.map(x => <div className="wl-history" key={x.escalationId}><b>{x.escalationReason}</b><div>{x.comments}</div><small>{x.status} · {x.createdBy} · {date(x.createdOn)}</small></div>)}</div></Modal>}
  </>;
}

function TaskRow({ task, openNote, openDocs, openEsc }) {
  return <tr>
    <td className="sticky-col task-tools-col"><div className="task-tools"><button className="wl-icon" title="Get notes / update status" onClick={() => openNote(task)}>📝</button><button className="wl-icon" title="Upload document" onClick={() => openDocs(task)}>📎</button><button className="wl-btn red xs" title="Escalate" onClick={() => openEsc(task)}>Escalate</button></div></td>
    <td>{task.taskId}</td><td className="claim-link">{task.claimId}</td><td>{task.patientId}</td><td>{task.cptCode}</td><td>{task.units ?? '-'}</td><td>{task.modifier || '-'}</td><td>{task.denialCode}</td><td className="wrap-cell">{task.denialDescription}</td><td>{task.denialClassification}</td><td>{task.actionCategory}</td><td><span className={`badge ${priorityClass(task.priority)}`}>{task.priority || 'Normal'}</span></td><td><span className={`badge ${statusClass(task.status)}`}>{task.status || 'New'}</span></td><td>{task.assignedTo}</td><td>{money(task.insuranceBalance)}</td><td>{date(task.dueDate)}</td><td>{task.slaStatus}</td><td>{task.payerName}</td><td className="wrap-cell">{task.reviewerComments}</td>
  </tr>;
}
