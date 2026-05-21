import React from 'react';
import { money, initials } from '../utils/formatters';

function n(value) { return Number(value || 0).toLocaleString(); }

export default function DashboardPage({ data }) {
  const classifications = data.denialClassifications || [];
  const workload = data.analystWorkload || [];
  const sla = data.slaTiles || [];
  const assignedClaims = data.assignedClaims ?? data.assigned ?? 0;
  const pendingClaims = data.pendingClaims ?? Math.max(Number(data.totalClaims || 0) - Number(assignedClaims || 0) - Number(data.closedClaims || 0), 0);
  const closedClaims = data.closedClaims ?? 0;
  const totalTasks = data.totalTasks || data.totalDenials || 0;

  return <>
    <div className="kpi-grid four">
      <Kpi title="Total claims" value={n(data.totalClaims)} sub={`${n(totalTasks)} distinct line item task(s)`} color="#1abc9c" />
      <Kpi title="Assigned claims" value={n(assignedClaims)} sub="Distinct VisitNumber assigned" color="#3498db" />
      <Kpi title="Pending claims" value={n(pendingClaims)} sub="Open claims not yet assigned" color="#f39c12" trend="kpi-warn" />
      <Kpi title="Closed claims" value={n(closedClaims)} sub={`${n(data.closedCount)} closed line task(s)`} color="#1abc9c" trend="kpi-up" />
    </div>

    <div className="kpi-grid two dashboard-secondary-kpis">
      <Kpi title="Outstanding amount" value={money(data.outstandingAmount || 0)} sub="InsuranceBalance total" color="#3498db" />
      <Kpi title="Open / in-progress tasks" value={n(data.openInProgressCount)} sub="Line item tasks not closed/completed" color="#e74c3c" trend="kpi-dn" />
    </div>

    <div className="row-2">
      <div className="lrn-card">
        <div className="lrn-card-header"><div className="lrn-card-title">By denial classification</div></div>
        <div className="dt-wrap dashboard-table-wrap">
          <table className="lrn-table dashboard-table">
            <thead><tr><th>Classification</th><th>Count</th><th>Outstanding</th><th>% of Total</th></tr></thead>
            <tbody>{classifications.length ? classifications.map((r, i) => <tr key={i}><td><strong>{r.classification}</strong></td><td>{n(r.count)}</td><td>{money(r.outstanding)}</td><td><div className="progress-bar"><div className="pb-fill" style={{ width: `${Math.min(100, Number(r.percentageOfTotal || 0))}%` }} /></div></td></tr>) : <tr><td colSpan="4" className="empty-cell">No classification data found.</td></tr>}</tbody>
          </table>
        </div>
      </div>
      <div className="lrn-card">
        <div className="lrn-card-header"><div className="lrn-card-title">Analyst workload</div></div>
        <div className="dt-wrap dashboard-table-wrap analyst-workload-wrap">
          <table className="lrn-table dashboard-table analyst-workload-table">
            <thead><tr><th>Analyst</th><th>Total claims</th><th>Total tasks</th><th>Closed tasks</th><th>Pending tasks</th></tr></thead>
            <tbody>{workload.length ? workload.map((r, i) => {
              const totalTasksForReviewer = r.totalTasks ?? r.totalAssigned ?? 0;
              const closedTasks = r.closedTasks ?? r.closed ?? 0;
              const pendingTasks = r.pendingTasks ?? r.pending ?? Math.max(Number(totalTasksForReviewer || 0) - Number(closedTasks || 0), 0);
              return <tr key={i}><td><span className="avatar-sm">{initials(r.reviewerName)}</span> {r.reviewerName}</td><td>{n(r.totalClaims)}</td><td>{n(totalTasksForReviewer)}</td><td><span className="kpi-up"><strong>{n(closedTasks)}</strong></span></td><td><span className="kpi-warn"><strong>{n(pendingTasks)}</strong></span></td></tr>;
            }) : <tr><td colSpan="5" className="empty-cell">No reviewer workload found.</td></tr>}</tbody>
          </table>
        </div>
      </div>
    </div>
    <div className="lrn-card sla-card"><div className="lrn-card-header"><div className="lrn-card-title">SLA & performance metrics</div></div><div className="sla-grid">{sla.length ? sla.map((s, i) => <div className="sla-box" key={i}><div className="lbl">{s.label}</div><div className="val">{n(s.count)}</div><div className={`stat ${String(s.status).toLowerCase().includes('overdue') ? 'kpi-warn' : 'kpi-up'}`}>{s.status}</div></div>) : <div className="empty-cell">No SLA data found.</div>}</div></div>
  </>;
}
function Kpi({ title, value, sub, color, trend }) { return <div className="kpi-card" style={{ '--kpi-color': color }}><div className="kpi-label">{title}</div><div className={`kpi-value ${trend || ''}`}>{value}</div><div className="kpi-sub">{sub}</div></div>; }
