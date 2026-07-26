import React from 'react';
import StructuredNoteText from './StructuredNoteText';

function eventDate(event) {
  return event.createdOn || event.uploadedOn || event.date || event.updatedOn || event.createdDate;
}

function timestamp(value) {
  if (!value) return '-';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString(undefined, { month: '2-digit', day: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

// History rows already surfaced by the dedicated notes/documents/escalations props — skip
// them here so those events are not listed twice. "Current Assignment" is a live snapshot of
// the task board (its timestamp is the claim-created time, not an assign time), so it is left
// to the full history modal rather than shown as a point-in-time timeline event.
const DUPLICATE_HISTORY_TYPES = new Set([
  'claim note', 'line note', 'document', 'claim escalation', 'line escalation', 'current assignment'
]);

function isAssignmentRow(row) {
  const type = String(row.historyType || '').toLowerCase();
  const action = String(row.actionType || '').toLowerCase();
  return type.includes('assign') || action.includes('assign');
}

// A task-history row whose action is an escalation/note/document duplicates what the
// escalations/notes/documents props already render — keep only assignment and status-type rows.
function isDuplicateAction(row) {
  const action = String(row.actionType || '').toLowerCase();
  return /escal|note|document|upload/.test(action);
}

// Turns the claim-history rows (dbo.DenialTaskHistory, via /claim-history) into timeline events.
// The assignment rows are the ones the drawer never showed before — an "Assigned to <user>"
// entry with the real assign time and who performed it. Status/other task-audit rows are shown
// too; note/document/escalation rows are dropped because their own props already cover them.
function buildHistoryEvents(history) {
  return (history || [])
    .filter(row => !DUPLICATE_HISTORY_TYPES.has(String(row.historyType || '').toLowerCase()))
    .filter(row => isAssignmentRow(row) || !isDuplicateAction(row))
    .map((row, index) => {
      const date = row.actionDate || row.createdOn;
      const by = row.actionBy || row.createdBy || '-';
      if (isAssignmentRow(row)) {
        const to = row.newAssignedTo && row.newAssignedTo.trim() ? row.newAssignedTo.trim() : 'Unassigned';
        const from = (row.oldAssignedTo || '').trim();
        const reassigned = from && from.toLowerCase() !== to.toLowerCase();
        return {
          key: `history-assign-${row.historyId || index}`,
          date,
          title: to === 'Unassigned' ? 'Claim unassigned' : `${reassigned ? 'Reassigned' : 'Assigned'} to ${to}`,
          by,
          // The backend groups the per-task assign rows and gives a noisy "Bulk assignment/audit
          // grouped from N ..." description; show only the meaningful reassignment context.
          comment: reassigned ? `Previously assigned to ${from}` : '',
          tone: 'amber'
        };
      }
      const newStatus = (row.newStatus || '').trim();
      return {
        key: `history-${row.historyId || index}`,
        date,
        title: newStatus ? `Status updated to ${newStatus}` : (row.title || row.actionType || 'Task updated'),
        by,
        comment: row.description || row.comments || '',
        tone: 'blue'
      };
    });
}

function buildEvents({ claim, notes, documents, escalations, history }) {
  const events = buildHistoryEvents(history);
  (escalations || []).forEach((item, index) => {
    // An escalation to a client/account manager is external; a reviewer -> AR Manager escalation is
    // internal. Show the workflow status ("Internal Escalation" / "External Escalation") as the
    // event title rather than the raw escalation state (e.g. "... - Open").
    const target = `${item.escalatedToRole || ''} ${item.escalatedTo || ''} ${item.escalationScope || ''}`.toLowerCase();
    const escalationType = target.includes('client') || target.includes('account') || target.includes('external')
      ? 'External Escalation'
      : 'Internal Escalation';
    events.push({
      key: `escalation-${item.escalationId || index}`,
      date: eventDate(item),
      title: item.escalationReason ? `${escalationType} — ${item.escalationReason}` : escalationType,
      by: item.createdBy || item.escalatedBy || '-',
      comment: item.comments || (item.escalatedTo ? `To: ${item.escalatedTo}` : ''),
      tone: 'purple'
    });
  });
  (notes || []).forEach((item, index) => events.push({
    key: `note-${item.noteId || index}`,
    date: eventDate(item),
    title: item.status ? `Status updated to ${item.status}` : 'Claim note added',
    by: item.createdBy || '-',
    comment: item.noteText || item.comment || '',
    tone: 'blue'
  }));
  (documents || []).forEach((item, index) => events.push({
    key: `document-${item.documentId || index}`,
    date: eventDate(item),
    title: 'Document uploaded',
    by: item.uploadedBy || '-',
    comment: item.originalFileName || item.fileName || item.comment || '',
    tone: 'green'
  }));
  if (claim?.createdOn) events.push({
    key: 'claim-created',
    date: claim.createdOn,
    title: 'Claim created',
    by: 'System',
    comment: '',
    tone: 'gray'
  });
  return events.sort((a, b) => new Date(b.date || 0) - new Date(a.date || 0));
}

export default function HistoryTimeline({ claim, notes = [], documents = [], escalations = [], history = [], formatDate }) {
  const rows = buildEvents({ claim, notes, documents, escalations, history });
  const fmt = formatDate ? value => timestamp(value) : timestamp;
  return <div className="history-timeline-view">
    <div className="history-timeline-list">
      {rows.length ? rows.map(event => <article className="history-timeline-row" key={event.key}>
        <time>{fmt(event.date)}</time>
        <span className={`history-timeline-track ${event.tone}`} aria-hidden="true"><i /></span>
        <div className="history-timeline-content">
          <h4>{event.title}</h4>
          <p>By: {event.by || '-'}</p>
          {event.comment ? <div className="history-comment"><span>Comment:</span><StructuredNoteText text={event.comment} /></div> : null}
        </div>
      </article>) : <div className="claim-empty-panel">No history found.</div>}
    </div>
  </div>;
}
