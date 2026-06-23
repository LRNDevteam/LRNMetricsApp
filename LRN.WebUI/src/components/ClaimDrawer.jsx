import React from 'react';
import { date, money } from '../utils/formatters';
import StatusBadge from './StatusBadge';

export default function ClaimDrawer({ claim, title = 'Claim Details', activeTab, tabs = [], onTabChange, onClose, children }) {
  if (!claim) return null;
  const claimId = claim.claimId || claim.claimID || claim.claimUid || claim.claimUID || '-';
  const payer = claim.payerName || claim.PayerName || '-';
  const patient = claim.patientName || claim.PatientName || '-';
  const balance = claim.insuranceBalance ?? claim.balance ?? claim.InsuranceBalance ?? 0;
  const sla = claim.slaStatus || claim.SlaStatus || claim.status || claim.Status || 'New';

  return <section className="claim-drawer open reusable-claim-drawer">
    <div className="claim-drawer-header">
      <div>
        <div className="claim-drawer-kicker">{title}</div>
        <h3>{claimId}</h3>
        <p>{patient} / {payer} / {money(balance)}</p>
      </div>
      <button className="wl-icon" title="Close claim drawer" type="button" onClick={onClose}><i className="bi bi-x-lg" /></button>
    </div>
    <div className="claim-drawer-meta compact">
      <span><b>Patient</b>{patient}</span>
      <span><b>Payer</b>{payer}</span>
      <span><b>DOS</b>{date(claim.dateOfService || claim.DOS || claim.dos)}</span>
      <span><b>Balance</b>{money(balance)}</span>
      <span><b>SLA</b><StatusBadge value={sla} /></span>
    </div>
    {tabs.length ? <div className="claim-drawer-tabs">
      {tabs.map(tab => <button key={tab.key} className={activeTab === tab.key ? 'active' : ''} type="button" onClick={() => onTabChange?.(tab.key)}>{tab.label}</button>)}
    </div> : null}
    <div className="claim-drawer-body">{children}</div>
  </section>;
}
