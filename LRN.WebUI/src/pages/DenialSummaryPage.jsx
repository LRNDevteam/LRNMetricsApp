import React from 'react';
import { money, actionBadgeClass } from '../utils/formatters';
function StatusPill({ label, value, cls }) { return <span className={`summary-pill ${cls}`}>{label}</span>; }

export default function DenialSummaryPage({ data, canAssign, onAssign, onClassificationClick }) {
  const classifications = data.denialClassifications || [];
  const actions = data.actionCategories || [];
  return <>
    <div className="lrn-card summary-card">
      <div className="lrn-card-header"><div className="lrn-card-title">Summary by denial classification</div></div>
      <div className="dt-wrap"><table className="lrn-table summary-table"><thead><tr><th>Classification</th><th>Total</th><th>Outstanding</th><th>Open</th><th>In Progress</th><th>Closed</th>{canAssign && <th></th>}</tr></thead><tbody>{classifications.length ? classifications.map((r, i) => <tr key={`${r.classification}-${i}`}><td><button className="link-btn classification-link" type="button" onClick={() => onClassificationClick?.(r.classification || '')}><strong>{r.classification || 'Unclassified'}</strong></button></td><td>{Number(r.count || 0).toLocaleString()}</td><td>{money(r.outstanding)}</td><td><StatusPill label="Open" cls="open" /> <span>{Number(r.open || 0).toLocaleString()}</span></td><td><StatusPill label="In Progress" cls="progress" /> <span>{Number(r.inProgress || 0).toLocaleString()}</span></td><td><StatusPill label="Closed" cls="closed" /> <span>{Number(r.closed || 0).toLocaleString()}</span></td>{canAssign && <td className="summary-action"><button className="mini-btn outline" onClick={onAssign}>Assign</button></td>}</tr>) : <tr><td colSpan={canAssign ? 7 : 6} className="empty-cell">No denial classification summary found.</td></tr>}</tbody></table></div>
    </div>
    <div className="lrn-card summary-card">
      <div className="lrn-card-header"><div className="lrn-card-title">Summary by action category</div></div>
      <div className="dt-wrap"><table className="lrn-table summary-table"><thead><tr><th>Action Category</th><th>Count</th><th>Outstanding</th><th>Share</th></tr></thead><tbody>{actions.length ? actions.map((r, i) => <tr key={`${r.actionCategory}-${i}`}><td><span className={`badge ${actionBadgeClass(r.actionCategory)}`}>{r.actionCategory || 'Unclassified'}</span></td><td>{Number(r.count || 0).toLocaleString()}</td><td>{money(r.outstanding)}</td><td><div className="progress-bar"><div className="pb-fill" style={{ width: `${Math.min(100, Number(r.percentageOfTotal || 0))}%` }} /></div></td></tr>) : <tr><td colSpan="4" className="empty-cell">No action category summary found.</td></tr>}</tbody></table></div>
    </div>
  </>;
}
