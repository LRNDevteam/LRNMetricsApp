import React from 'react';
import { money, initials } from '../utils/formatters';
export default function DashboardPage({ data }) {
  const classifications = data.denialClassifications || [];
  const workload = data.analystWorkload || [];
  const sla = data.slaTiles || [];
  return <>
    <div className="kpi-grid four">
      <Kpi title="Total denials" value={Number(data.totalDenials || 0).toLocaleString()} sub="DenialTaskBoard rows" color="#1abc9c" />
      <Kpi title="Outstanding amount" value={money(data.outstandingAmount || 0)} sub="InsuranceBalance total" color="#3498db" />
      <Kpi title="Open / Inprogress" value={Number(data.openInProgressCount || 0).toLocaleString()} sub="Not closed/completed" color="#e74c3c" trend="kpi-dn" />
      <Kpi title="Closed" value={Number(data.closedCount || 0).toLocaleString()} sub="Completed/closed tasks" color="#1abc9c" trend="kpi-up" />
    </div>
    <div className="row-2">
      <div className="lrn-card"><div className="lrn-card-header"><div className="lrn-card-title">By denial classification</div></div><div className="dt-wrap dashboard-table-wrap"><table className="lrn-table"><thead><tr><th>Classification</th><th>Count</th><th>Outstanding</th><th>% of Total</th></tr></thead><tbody>{classifications.length ? classifications.map((r, i) => <tr key={i}><td><strong>{r.classification}</strong></td><td>{Number(r.count || 0).toLocaleString()}</td><td>{money(r.outstanding)}</td><td><div className="progress-bar"><div className="pb-fill" style={{ width: `${Math.min(100, Number(r.percentageOfTotal || 0))}%` }} /></div></td></tr>) : <tr><td colSpan="4" className="empty-cell">No classification data found.</td></tr>}</tbody></table></div></div>
      <div className="lrn-card"><div className="lrn-card-header"><div className="lrn-card-title">Analyst workload</div></div><div className="dt-wrap dashboard-table-wrap"><table className="lrn-table"><thead><tr><th>Analyst</th><th>Assigned</th><th>Closed</th></tr></thead><tbody>{workload.length ? workload.map((r, i) => <tr key={i}><td><span className="avatar-sm">{initials(r.reviewerName)}</span> {r.reviewerName}</td><td>{Number(r.totalAssigned || 0).toLocaleString()}</td><td><span className="kpi-up"><strong>{Number(r.closed || 0).toLocaleString()}</strong></span></td></tr>) : <tr><td colSpan="3" className="empty-cell">No reviewer workload found.</td></tr>}</tbody></table></div></div>
    </div>
    <div className="lrn-card sla-card"><div className="lrn-card-header"><div className="lrn-card-title">SLA & performance metrics</div></div><div className="sla-grid">{sla.length ? sla.map((s, i) => <div className="sla-box" key={i}><div className="lbl">{s.label}</div><div className="val">{Number(s.count || 0).toLocaleString()}</div><div className={`stat ${String(s.status).toLowerCase().includes('overdue') ? 'kpi-warn' : 'kpi-up'}`}>{s.status}</div></div>) : <div className="empty-cell">No SLA data found.</div>}</div></div>
  </>;
}
function Kpi({ title, value, sub, color, trend }) { return <div className="kpi-card" style={{ '--kpi-color': color }}><div className="kpi-label">{title}</div><div className={`kpi-value ${trend || ''}`}>{value}</div><div className="kpi-sub">{sub}</div></div>; }
