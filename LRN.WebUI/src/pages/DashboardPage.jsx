import React from 'react';
import { money, initials, isAccountManagerRole, isArReviewerRole, isClientManagerRole } from '../utils/formatters';

function n(value) { return Number(value || 0).toLocaleString(); }
function pct(value, fallback = 0) { return `${Math.max(0, Math.min(100, Number(value || fallback))).toFixed(0)}%`; }
function riskClass(value) {
  const s = String(value || '').toLowerCase();
  if (s.includes('high') || s.includes('over') || s.includes('breach')) return 'flag-red';
  if (s.includes('medium') || s.includes('risk') || s.includes('warn')) return 'flag-amber';
  if (s.includes('low') || s.includes('ok') || s.includes('track')) return 'flag-green';
  return 'flag-blue';
}

export default function DashboardPage({ data, user = {}, labName = '', onKpiClick }) {
  const role = user?.role || '';
  if (isArReviewerRole(role)) return <AnalystDashboard data={data} user={user} labName={labName} />;
  if (isClientManagerRole(role)) return <SingleAccountDashboard data={data} user={user} labName={labName} mode="client" />;
  if (isAccountManagerRole(role)) return <SingleAccountDashboard data={data} user={user} labName={labName} mode="account" />;
  return <ManagerDashboard data={data} user={user} labName={labName} onKpiClick={onKpiClick} />;
}

function ManagerDashboard({ data, onKpiClick }) {
  const classifications = data.denialClassifications || [];
  const workload = data.analystWorkload || [];
  const assignedClaims = data.assignedClaims ?? data.assigned ?? 0;
  const openClaims = data.openClaims ?? Math.max(Number(data.totalClaims || 0) - Number(data.closedClaims || 0), 0);
  const unassignedClaims = data.pendingClaims ?? data.unassignedClaims ?? 0;
  const escalated = data.escalatedClaims ?? data.escalationCount ?? data.escalatedCount ?? 0;
  const slaPercent = data.slaCompliancePercent ?? data.slaCompliance ?? 86;
  const totalTasks = data.openInProgressCount ?? data.totalOpenTasks ?? data.totalTasks ?? data.totalDenials ?? 0;
  const slaBreached = data.slaBreached ?? data.slaBreachedCount ?? (data.slaTiles || []).find(x => String(x.label || '').toLowerCase().includes('breach'))?.count ?? 0;
  const verificationPending = data.verificationPending ?? data.verificationPendingCount ?? 0;
  const balance = data.outstandingAmount || 0;

  return <div className="role-dashboard manager-dashboard">
    <div className="dashboard-hero-row">
      <DashboardKpi label="Total Open Claims" value={n(openClaims)} icon="bi-folder2-open" tone="blue" onClick={() => onKpiClick?.({})} />
      <DashboardKpi label="Total Open Tasks" value={n(totalTasks)} icon="bi-list-task" tone="indigo" onClick={() => onKpiClick?.({ status: '' })} />
      <DashboardKpi label="Assigned Claims" value={n(assignedClaims)} icon="bi-person-check" tone="green" onClick={() => onKpiClick?.({ taskView: 'assigned' })} />
      <DashboardKpi label="Unassigned Claims" value={n(unassignedClaims)} icon="bi-person-dash" tone="amber" onClick={() => onKpiClick?.({ taskView: 'unassigned' })} />
      <DashboardKpi label="SLA Breached" value={n(slaBreached)} icon="bi-alarm" tone="red" onClick={() => onKpiClick?.({ status: 'Breached' })} />
      <DashboardKpi label="Escalated Claims" value={n(escalated)} icon="bi-exclamation-triangle" tone="red" onClick={() => onKpiClick?.({ status: 'Escalated' })} />
      <DashboardKpi label="Verification Pending" value={n(verificationPending)} icon="bi-shield-check" tone="violet" onClick={() => onKpiClick?.({ status: 'Verification Pending' })} />
      <DashboardKpi label="Total Insurance Balance" value={money(balance)} icon="bi-cash-stack" tone="teal balance" onClick={() => onKpiClick?.({})} />
    </div>
    <div className="dashboard-overview-grid">
      <div className="role-kpi-row dashboard-kpi-stack">
        <RoleKpi label="Open Claims" value={n(openClaims)} tone="blue" />
        <RoleKpi label="Open Balance" value={money(balance)} tone="teal" />
        <RoleKpi label="Escalated" value={n(escalated)} tone="red" />
        <RoleKpi label="SLA Compliance" value={pct(slaPercent)} tone="green" />
      </div>
      <RoleCard title="Denial Classification Summary">
        <div className="role-table-wrap"><table className="role-table wide"><thead><tr><th>Classification</th><th>Claims</th><th>Balance</th><th>Assigned</th><th>In Progress</th><th>Closed</th><th>SLA Risk</th></tr></thead><tbody>
          {classifications.length ? classifications.map((r, i) => <tr key={i}><td>{r.classification || '-'}</td><td>{n(r.count)}</td><td>{money(r.outstanding)}</td><td>{n(r.assigned ?? r.assignedCount ?? 0)}</td><td>{n(r.inProgress ?? r.inProgressCount ?? 0)}</td><td>{n(r.closed ?? r.closedCount ?? 0)}</td><td><RiskPill value={r.slaRisk || r.risk || (Number(r.percentageOfTotal || 0) > 25 ? 'High' : 'Medium')} /></td></tr>) : <EmptyRow colSpan={7} />}
        </tbody></table></div>
      </RoleCard>
    </div>
    <ReviewerAgingTable rows={workload} title="Analyst Workload" />
  </div>;
}

function AnalystDashboard({ data, user, labName }) {
  const workload = data.analystWorkload || [];
  const mine = workload.find(x => String(x.reviewerName || '').toLowerCase() === String(user?.displayName || user?.userName || '').toLowerCase()) || workload[0] || {};
  const assignedClaims = data.assignedClaims ?? mine.totalClaims ?? data.totalClaims ?? 0;
  const pendingTasks = mine.pendingTasks ?? mine.pending ?? data.openInProgressCount ?? 0;
  const closedTasks = mine.closedTasks ?? mine.closed ?? data.closedCount ?? 0;
  const openBalance = data.outstandingAmount || 0;

  return <div className="role-dashboard analyst-dashboard">
    <RoleHeader title="AR Analyst Dashboard" subtitle="My work queue" tag="Analyst view" user={user} labName={labName} />
    <ReviewerAgingTable rows={workload} title="My Aging View" />
    <div className="role-kpi-row">
      <RoleKpi label="Assigned Claims" value={n(assignedClaims)} tone="blue" />
      <RoleKpi label="Open Tasks" value={n(pendingTasks)} tone="amber" />
      <RoleKpi label="Completed Tasks" value={n(closedTasks)} tone="green" />
      <RoleKpi label="Open Balance" value={money(openBalance)} tone="teal" />
    </div>
    <div className="role-grid two analyst-layout">
      <RoleCard title="Priority Work Queue">
        <div className="role-table-wrap"><table className="role-table wide"><thead><tr><th>Queue</th><th>Claims</th><th>Tasks</th><th>Balance</th><th>Priority</th></tr></thead><tbody>
          {(data.denialClassifications || []).slice(0, 6).map((r, i) => <tr key={i}><td>{r.classification || 'Unclassified'}</td><td>{n(r.claims || r.count)}</td><td>{n(r.tasks || r.count)}</td><td>{money(r.outstanding)}</td><td><RiskPill value={i < 2 ? 'High' : i < 4 ? 'Medium' : 'Low'} /></td></tr>)}
          {!(data.denialClassifications || []).length && <EmptyRow colSpan={5} />}
        </tbody></table></div>
      </RoleCard>
    </div>
  </div>;
}

function SingleAccountDashboard({ data, user, labName, mode }) {
  const isClient = mode === 'client';
  const title = isClient ? 'Client Manager Dashboard' : 'Account Manager Dashboard';
  const classifications = data.denialClassifications || [];
  const actionCategories = data.actionCategories || [];
  return <div className="role-dashboard single-account-dashboard">
    <RoleHeader title={title} subtitle="Single account operational summary" tag={isClient ? 'Client-facing view' : 'Account view'} user={user} labName={labName} />
    <ReviewerAgingTable rows={data.analystWorkload || []} />
    <div className="role-kpi-row">
      <RoleKpi label="Open Claims" value={n(data.totalClaims)} tone="blue" />
      <RoleKpi label="At-Risk AR" value={money(data.outstandingAmount || 0)} tone="red" />
      <RoleKpi label="Client Info Pending" value={n(data.escalatedCount || data.openInProgressCount || 0)} tone="amber" />
      <RoleKpi label="Closed Tasks" value={n(data.closedCount)} tone="green" />
    </div>
    <div className="role-grid two">
      <div>
        <RoleCard title={isClient ? 'Client-Facing Denial Follow-up Summary' : 'Client-Level Revenue Leakage Drivers'}>
          <div className="role-table-wrap"><table className="role-table wide"><thead><tr><th>Driver</th><th>Claims</th><th>Tasks</th><th>Balance</th><th>Action Needed</th></tr></thead><tbody>
            {classifications.length ? classifications.map((r, i) => <tr key={i}><td>{r.classification || '-'}</td><td>{n(r.claims || r.count)}</td><td>{n(r.tasks || r.count)}</td><td>{money(r.outstanding)}</td><td><RiskPill value={i < 2 ? 'Client Follow-up' : 'Monitor'} /></td></tr>) : <EmptyRow colSpan={5} />}
          </tbody></table></div>
        </RoleCard>
        <RoleCard title={isClient ? 'Revenue Recovery and At-Risk AR' : 'Payer Performance for This Account'}>
          <div className="role-table-wrap"><table className="role-table"><thead><tr><th>Action / Payer</th><th>Count</th><th>Balance</th><th>Status</th></tr></thead><tbody>
            {actionCategories.length ? actionCategories.slice(0, 8).map((r, i) => <tr key={i}><td>{r.actionCategory || r.category || '-'}</td><td>{n(r.count)}</td><td>{money(r.outstanding)}</td><td><RiskPill value={i < 2 ? 'High' : 'Medium'} /></td></tr>) : <EmptyRow colSpan={4} />}
          </tbody></table></div>
        </RoleCard>
      </div>
    </div>
  </div>;
}

function ReviewerAgingTable({ rows = [], title = 'Aging View by AR Reviewer' }) {
  return <RoleCard title={title}>
    <div className="role-table-wrap"><table className="role-table reviewer-aging-table"><thead><tr><th>AR Reviewer</th><th>0-30</th><th>31-60</th><th>61-90</th><th>91-120</th><th>120+</th><th>Assigned</th><th>In Progress</th><th>Pending</th><th>Closed</th></tr></thead><tbody>
      {rows.length ? rows.map((r, i) => <tr key={`${r.reviewerName || 'reviewer'}-${i}`}><td><span className="avatar-sm">{initials(r.reviewerName)}</span> {r.reviewerName || '-'}</td><td>{n(r.aging0To30 ?? 0)}</td><td>{n(r.aging31To60 ?? 0)}</td><td>{n(r.aging61To90 ?? 0)}</td><td>{n(r.aging91To120 ?? 0)}</td><td>{n(r.agingOver120 ?? 0)}</td><td>{n(r.assigned ?? r.totalClaims ?? 0)}</td><td>{n(r.inProgress ?? 0)}</td><td>{n(r.pending ?? 0)}</td><td>{n(r.closed ?? 0)}</td></tr>) : <EmptyRow colSpan={10} />}
    </tbody></table></div>
  </RoleCard>;
}

function RoleHeader({ title, subtitle, tag, user, labName }) { return <div className="role-page-head"><div><h2>{title}</h2><p>DenialFlow / <b>{subtitle}</b>{labName ? ` - ${labName}` : ''}</p></div><div className="role-head-right"><span className="role-tag">{tag}</span><span className="role-user"><span className="avatar-sm">{initials(user?.displayName || user?.userName)}</span>{user?.displayName || user?.userName || 'Workflow User'}</span></div></div>; }
function RoleKpi({ label, value, tone }) { return <div className={`role-kpi ${tone || ''}`}><div className="role-kpi-value">{value}</div><div className="role-kpi-label">{label}</div></div>; }
function DashboardKpi({ label, value, icon, tone, onClick }) { return <button type="button" className={`modern-kpi ${tone || ''}`} onClick={onClick}><span className="modern-kpi-icon"><i className={`bi ${icon}`} /></span><span><small>{label}</small><b>{value}</b><em>Click to view filtered claims</em></span></button>; }
function RoleCard({ title, children }) { return <div className="role-card"><div className="role-card-hd"><div className="role-card-title">{title}</div></div><div className="role-card-body">{children}</div></div>; }
function RiskPill({ value }) { return <span className={`role-flag ${riskClass(value)}`}>{value || 'Medium'}</span>; }
function EmptyRow({ colSpan }) { return <tr><td colSpan={colSpan} className="empty-cell">No dashboard data found.</td></tr>; }
