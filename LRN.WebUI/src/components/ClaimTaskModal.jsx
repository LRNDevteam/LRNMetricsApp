import React from 'react';
import { money, date, statusClass } from '../utils/formatters';
export default function ClaimTaskModal({ open, claimId, tasks, onClose }) {
  if (!open) return null;
  return <div className="modal-backdrop" onClick={onClose}>
    <div className="claim-modal" onClick={e => e.stopPropagation()}>
      <div className="claim-modal-header">
        <div><div className="claim-modal-title">Claim CPT Details</div><small>Claim ID: {claimId || '-'}</small></div>
        <button type="button" className="modal-close" onClick={onClose}><i className="bi bi-x-lg" /></button>
      </div>
      <div className="claim-modal-body"><ClaimTaskDrill tasks={tasks} /></div>
    </div>
  </div>;
}

function ClaimTaskDrill({ tasks }) {
  return <div className="drill-panel"><div className="drill-title">Claim task drill-down</div><table className="lrn-table drill-table"><thead><tr><th>Task ID</th><th>CPT</th><th>Denial Code</th><th>Description</th><th>Balance</th><th>Classification</th><th>Action Code</th><th>Recommended Action</th><th>Action Category</th><th>SLA Days</th><th>Status</th><th>Coverage</th><th>ICD Codes</th><th>ICD Compliance</th><th>Denial Validity</th><th>Assigned To</th></tr></thead><tbody>{tasks.length ? tasks.map((t, i) => <tr key={t.taskId || i}><td>{t.taskId}</td><td>{t.cptCode}</td><td>{t.denialCode}</td><td className="wrap-cell">{t.denialDescription}</td><td>{money(t.insuranceBalance)}</td><td>{t.denialClassification}</td><td>{t.actionCode}</td><td className="wrap-cell">{t.recommendedAction}</td><td>{t.actionCategory}</td><td>{t.slaDays}</td><td><span className={`badge ${statusClass(t.status)}`}>{t.status || 'New'}</span></td><td>{t.coverageStatus}</td><td className="wrap-cell">{t.icdCodes}</td><td>{t.icdComplianceStatus}</td><td className="wrap-cell">{t.denialValidity}</td><td>{t.assignedTo}</td></tr>) : <tr><td colSpan="16" className="empty-cell">No tasks found for this claim.</td></tr>}</tbody></table></div>;
}
