import React from 'react';
import Pager from '../components/Pager';
import { money, date, statusClass } from '../utils/formatters';
export default function ClaimAssignmentPage({ data, reviewers, selected, setSelected, bulkReviewer, setBulkReviewer, loadClaimTasks, assignClaims, changePage }) {
  const items = data.items || [];
  const getClaimId = (r) => String(r?.claimId ?? r?.claimID ?? r?.ClaimId ?? r?.ClaimID ?? '').trim();
  const all = items.length > 0 && items.every((_, i) => selected[i]);
  const selectedClaimIds = items
    .filter((_, i) => selected[i])
    .map(getClaimId)
    .filter(Boolean);

  return <>
    <div className="lrn-card assignment-toolbar">
      <div className="assign-left">
        <strong>Selected claims:</strong> <span>{selectedClaimIds.length}</span>
        <small>Assigning a claim assigns all matching DenialTaskBoard task rows for that claim.</small>
      </div>
      <div className="assign-right">
        <select value={bulkReviewer} onChange={e => setBulkReviewer(e.target.value)}>
          <option value="">Select AR Reviewer</option>
          {reviewers.map(r => <option key={r.userName} value={r.userName}>{r.displayName || r.userName}</option>)}
        </select>
        <button className="topbar-btn teal" onClick={() => assignClaims(selectedClaimIds, bulkReviewer)}>
          <i className="bi bi-person-check" />Assign Selected Claims
        </button>
      </div>
    </div>

    <div className="lrn-card">
      <div className="lrn-card-header">
        <div className="lrn-card-title">Claim Level Assignment</div>
        <span className="table-count">Showing {items.length} claim(s)</span>
      </div>
      <div className="dt-wrap workflow-scroll">
        <table className="lrn-table workflow-table">
          <thead>
            <tr>
              <th className="sticky-col select-col">
                <input
                  type="checkbox"
                  checked={all}
                  onChange={e => {
                    const next = {};
                    if (e.target.checked) items.forEach((_, i) => next[i] = true);
                    setSelected(next);
                  }}
                />
              </th>
              <th>Claim ID</th>
              <th>Patient Name</th>
              <th>DOB</th>
              <th>Patient ID</th>
              <th>Clinic</th>
              <th>Sales Rep</th>
              <th>Referring Provider</th>
              <th>Payer</th>
              <th>DOS</th>
              <th>Outstanding</th>
            </tr>
          </thead>
          <tbody>
            {items.length ? items.map((r, i) => {
              const claimId = getClaimId(r);
              return <React.Fragment key={`${claimId || 'claim'}-${i}`}>
                <tr>
                  <td className="sticky-col select-col">
                    <input
                      type="checkbox"
                      checked={!!selected[i]}
                      onChange={e => setSelected({ ...selected, [i]: e.target.checked })}
                    />
                  </td>
                  <td>
                    <button
                      className="link-btn"
                      type="button"
                      disabled={!claimId}
                      onClick={() => loadClaimTasks(claimId)}
                    >
                      {claimId || '-'}
                    </button>
                  </td>
                  <td>{r.patientName}</td>
                  <td>{date(r.patientDOB)}</td>
                  <td>{r.patientId}</td>
                  <td>{r.clinicName}</td>
                  <td>{r.salesRepname}</td>
                  <td>{r.referringProvider}</td>
                  <td>{r.payerName}</td>
                  <td>{date(r.dateOfService)}</td>
                  <td>{money(r.insuranceBalance)}</td>
                </tr>
              </React.Fragment>;
            }) : <tr><td colSpan="11" className="empty-cell">No claim records found.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  </>;
}
