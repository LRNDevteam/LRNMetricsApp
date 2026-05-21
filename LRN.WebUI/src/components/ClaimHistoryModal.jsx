import React from 'react';

const fmtDateTime = value => {
  if (!value) return '-';
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? String(value) : d.toLocaleString();
};

function badgeClass(type) {
  const t = String(type || '').toLowerCase();
  if (t.includes('escal')) return 'history-badge escalated';
  if (t.includes('note')) return 'history-badge note';
  if (t.includes('current')) return 'history-badge current';
  if (t.includes('document')) return 'history-badge document';
  if (t.includes('closed') || t.includes('resolve')) return 'history-badge closed';
  return 'history-badge';
}

export default function ClaimHistoryModal({ open, title, subtitle, rows = [], loading = false, onClose }) {
  if (!open) return null;
  return <div className="modal-backdrop claim-history-backdrop" onMouseDown={onClose}>
    <div className="note-modal claim-history-modal" role="dialog" aria-modal="true" onMouseDown={e => e.stopPropagation()}>
      <div className="note-modal-hd">
        <div><strong>{title || 'Claim History'}</strong><small>{subtitle || 'All claim activity so far'}</small></div>
        <button className="modal-close" type="button" onClick={onClose}>×</button>
      </div>
      <div className="note-modal-body claim-history-body">
        {loading ? <div className="empty-cell">Loading history...</div> : rows.length ? <div className="claim-history-list">
          {rows.map((r, i) => <div className="claim-history-item" key={`${r.historyType || 'history'}-${r.historyId || i}-${i}`}>
            <div className="claim-history-icon"><i className="bi bi-clock-history" /></div>
            <div className="claim-history-content">
              <div className="claim-history-top"><span className={badgeClass(r.historyType)}>{r.historyType || 'History'}</span><b>{r.title || r.actionType || '-'}</b></div>
              <div className="claim-history-text">{r.description || r.comments || '-'}</div>
              <div className="claim-history-meta">
                {r.taskId ? <span>Task {r.taskId}</span> : null}
                {r.cptCode ? <span>CPT {r.cptCode}</span> : null}
                {r.oldStatus || r.newStatus ? <span><b>Status:</b> {r.oldStatus || '-'} → {r.newStatus || '-'}</span> : null}
                {r.oldAssignedTo || r.newAssignedTo ? <span><b>Assigned:</b> {r.oldAssignedTo || 'Unassigned'} → {r.newAssignedTo || 'Unassigned'}</span> : null}
                <span>{r.actionBy || r.createdBy || '-'}</span>
                <span>{fmtDateTime(r.actionDate || r.createdOn)}</span>
              </div>
            </div>
          </div>)}
        </div> : <div className="modal-row"><div className="modal-row-title">No history found</div><div className="modal-row-meta">Claim notes, escalations, task updates, and documents will show here.</div></div>}
      </div>
      <div className="note-modal-ft"><button className="wl-btn" type="button" onClick={onClose}>Close</button></div>
    </div>
  </div>;
}
