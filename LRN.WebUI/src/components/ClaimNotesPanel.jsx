import React from 'react';
import StructuredNoteText from './StructuredNoteText';

function timestamp(value) {
  if (!value) return '-';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString(undefined, { month: '2-digit', day: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

export default function ClaimNotesPanel({ notes = [], canAdd = false, onAdd, formatDate }) {
  const rows = notes || [];
  const fmt = formatDate ? value => timestamp(value) : timestamp;
  return <div className="claim-notes-view">
    <div className="claim-notes-header">
      <h3>Claim Notes</h3>
      {canAdd && <button className="claim-add-note-btn" type="button" onClick={onAdd}><i className="bi bi-plus-lg" /> Add Note</button>}
    </div>
    <div className="claim-note-list">
      {rows.length ? rows.map(note => <article className="claim-note-card" key={note.noteId || `${note.createdBy}-${note.createdOn}`}>
        <span className="claim-note-rail" aria-hidden="true"><i /></span>
        <div className="claim-note-content">
          <div className="claim-note-top">
            <strong>{note.createdBy || '-'}</strong>
            <time>{fmt(note.createdOn)}</time>
          </div>
          <StructuredNoteText text={note.noteText || note.comment || '-'} />
        </div>
      </article>) : <div className="claim-empty-panel">No claim notes found.</div>}
    </div>
    <div className="document-pager"><button type="button" disabled><i className="bi bi-chevron-left" /></button><b>1</b><button type="button" disabled><i className="bi bi-chevron-right" /></button></div>
  </div>;
}
