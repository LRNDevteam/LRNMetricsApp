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

function buildEvents({ claim, notes, documents, escalations }) {
  const events = [];
  (escalations || []).forEach((item, index) => events.push({
    key: `escalation-${item.escalationId || index}`,
    date: eventDate(item),
    title: item.status ? `${item.escalationReason || 'Escalation'} - ${item.status}` : item.escalationReason || 'Escalation submitted',
    by: item.createdBy || item.escalatedBy || '-',
    comment: item.comments || (item.escalatedTo ? `To: ${item.escalatedTo}` : ''),
    tone: 'purple'
  }));
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

export default function HistoryTimeline({ claim, notes = [], documents = [], escalations = [], formatDate }) {
  const rows = buildEvents({ claim, notes, documents, escalations });
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
