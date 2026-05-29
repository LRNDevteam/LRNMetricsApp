import React, { useMemo, useState } from 'react';
import Pager from '../components/Pager';
import { date, money, statusClass } from '../utils/formatters';

function normalizeRole(value) {
  return String(value || '').replace(/[^a-z0-9]/gi, '').toLowerCase();
}

function isArReviewerOption(r) {
  const role = normalizeRole(r?.role || r?.Role);
  return !role || role.includes('arreviewer') || role.includes('analyst') || role.includes('analyser') || (role.includes('reviewer') && !role.includes('manager'));
}

export default function VerificationPage({ data, changePage, tabCounts = {}, onTabChange = () => {}, reviewers = [], canAssign = false, assignClaims = () => {} }) {
  const items = data.items || [];
  const groups = useMemo(() => {
    const map = new Map();
    items.forEach((row, index) => {
      const claimId = String(row.claimId || row.claimID || row.ClaimID || '').trim() || `claim-${index}`;
      if (!map.has(claimId)) {
        map.set(claimId, {
          claimId,
          payerName: row.payerName || '',
          patientId: row.patientId || row.patientID || '',
          assignedTo: row.assignedTo || '',
          status: row.verificationStatus || row.status || 'Verification Pending',
          reason: row.verificationComments || '',
          movedOn: row.movedOn || row.createdOn || '',
          balance: 0,
          rows: []
        });
      }
      const group = map.get(claimId);
      group.balance += Number(row.insuranceBalance || 0);
      group.rows.push(row);
      if (!group.payerName && row.payerName) group.payerName = row.payerName;
      if (!group.assignedTo && row.assignedTo) group.assignedTo = row.assignedTo;
      if (!group.reason && row.verificationComments) group.reason = row.verificationComments;
    });
    return Array.from(map.values());
  }, [items]);

  const [activeClaimId, setActiveClaimId] = useState('');
  const [selectedClaims, setSelectedClaims] = useState({});
  const [bulkReviewer, setBulkReviewer] = useState('');
  const activeClaim = groups.find(x => x.claimId === activeClaimId) || null;
  const arReviewers = useMemo(() => (reviewers || []).filter(isArReviewerOption), [reviewers]);
  const selectedClaimIds = useMemo(() => groups.filter((_, i) => selectedClaims[i]).map(x => x.claimId).filter(Boolean), [groups, selectedClaims]);
  const allSelected = canAssign && groups.length > 0 && groups.every((_, i) => selectedClaims[i]);
  const claimTabs = [
    { key: 'new', label: 'New' },
    { key: 'unassigned', label: 'Unassigned' },
    { key: 'assigned', label: 'Assigned' },
    { key: 'internalEscalation', label: 'Internal Escalation' },
    { key: 'externalEscalation', label: 'External Escalation' },
    { key: 'response', label: 'Escalated Response', countKey: 'escalationResponse' },
    { key: 'verification', label: 'Verification Claim' },
    { key: 'closed', label: 'Closed' }
  ];
  const tabCountText = value => {
    if (value === null || value === undefined) return '...';
    const n = Number(value || 0);
    return n > 99999 ? `${Math.round(n / 1000)}k` : n.toLocaleString();
  };

  return <>
    <div className={`claim-split-shell ${activeClaim ? 'drawer-open' : ''}`}>
      <section className={`claim-list-pane ${activeClaim ? 'narrow' : 'full'}`}>
        <div className="claim-view-top">
          <div>
            <div className="claim-view-title">Verification Claim</div>
            <div className="claim-view-subtitle">Verification claims - {groups.length} claim(s), {data.totalCount || items.length} line(s)</div>
          </div>
          <span className="table-count">Verification</span>
        </div>
        <div className="claim-list-toolbar">
          <label className="claim-search-wrap"><i className="bi bi-search" /><input readOnly value="" placeholder="Search claim, payer, patient" /></label>
          <div className="claim-tab-row">{claimTabs.map(t => <button key={t.key} type="button" className={`claim-tab ${t.key === 'verification' ? 'active' : ''}`} onClick={() => onTabChange(t.key)}><span>{t.label}</span><b>{tabCountText(tabCounts?.[t.countKey || t.key])}</b></button>)}</div>
        </div>
        {canAssign && <div className="claim-assign-bar2"><label><input type="checkbox" checked={allSelected} onChange={e => { const next = {}; if (e.target.checked) groups.forEach((_, i) => next[i] = true); setSelectedClaims(next); }} /> Select page</label><strong>{selectedClaimIds.length} selected</strong><select value={bulkReviewer} onChange={e => setBulkReviewer(e.target.value)}><option value="">Select AR Reviewer</option>{arReviewers.map(r => <option key={r.userName || r.UserName} value={r.userName || r.UserName}>{r.displayName || r.DisplayName || r.userName || r.UserName}</option>)}</select><button className="wl-btn teal xs" type="button" disabled={!selectedClaimIds.length} onClick={() => assignClaims(selectedClaimIds, bulkReviewer)}>Assign</button></div>}
        <div className="claim-list-head"><span>Claim</span><span>Payer</span><span>Balance</span><span>Status</span></div>
        <div className="claim-rows-scroll">{groups.length ? groups.map((group, index) => {
          const isOpen = activeClaimId === group.claimId;
          return <button type="button" key={group.claimId} className={`claim-list-row ${isOpen ? 'active' : ''}`} onClick={() => setActiveClaimId(isOpen ? '' : group.claimId)}>
            {canAssign && <span className="claim-row-check" onClick={e => e.stopPropagation()}><input type="checkbox" checked={!!selectedClaims[index]} onChange={e => setSelectedClaims({ ...selectedClaims, [index]: e.target.checked })} /></span>}
            <span className="claim-expand-dot"><i className={`bi ${isOpen ? 'bi-chevron-down' : 'bi-chevron-right'}`} /></span>
            <span className="claim-list-id"><strong>{group.claimId || '-'}</strong><small>{group.patientId || '-'} - {group.rows.length} verification line(s)</small></span>
            <span className="claim-list-payer" title={group.payerName || ''}>{group.payerName || '-'}</span>
            <span className="claim-list-amt">{money(group.balance)}</span>
            <span className={`badge ${statusClass(group.status)}`}>{group.status}</span>
          </button>;
        }) : <div className="claim-empty-panel">No verification claims found.</div>}</div>
      </section>

      {activeClaim && <section className="claim-drawer open">
        <div className="claim-drawer-header"><div><div className="claim-drawer-kicker">Claims / Verification Claim / Line Level</div><h3>{activeClaim.claimId}</h3><p>{activeClaim.payerName || '-'} - {money(activeClaim.balance)}</p></div><button className="wl-icon" title="Close claim drawer" type="button" onClick={() => setActiveClaimId('')}><i className="bi bi-x-lg" /></button></div>
        <div className="claim-drawer-meta"><span><b>Patient</b>{activeClaim.patientId || '-'}</span><span><b>Assigned</b>{activeClaim.assignedTo || '-'}</span><span><b>Status</b>{activeClaim.status || '-'}</span><span><b>Moved On</b>{date(activeClaim.movedOn)}</span><span><b>Lines</b>{activeClaim.rows.length}</span><span><b>Balance</b>{money(activeClaim.balance)}</span></div>
        <div className="claim-drawer-tabs"><button className="active" type="button">Line Tasks</button></div>
        <div className="claim-drawer-body">
          <table className="claim-task-table">
            <thead><tr><th>Task</th><th>CPT</th><th>Denial</th><th>Description</th><th>Verification</th><th>Assigned</th><th className="r">Balance</th><th>Reason</th></tr></thead>
            <tbody>{activeClaim.rows.map((v, i) => <tr key={v.verificationId || v.taskId || i}>
              <td><strong>{v.taskId || '-'}</strong><small>{date(v.movedOn || v.createdOn)}</small></td>
              <td><code className="code">{v.cptCode || '-'}</code></td>
              <td><code className="code">{v.denialCode || '-'}</code></td>
              <td>{v.denialDescription || '-'}</td>
              <td><span className={`badge ${statusClass(v.verificationStatus || v.status)}`}>{v.verificationStatus || v.status || '-'}</span></td>
              <td>{v.assignedTo || '-'}</td>
              <td className="r">{money(v.insuranceBalance)}</td>
              <td>{v.verificationComments || '-'}</td>
            </tr>)}</tbody>
          </table>
        </div>
      </section>}
    </div>
    <Pager data={data} changePage={changePage} />
  </>;
}
