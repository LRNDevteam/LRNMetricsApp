import React from 'react';
import { money, initials, isAccountManagerRole, isArReviewerRole, isClientManagerRole } from '../utils/formatters';

function n(value) { return Number(value || 0).toLocaleString(); }
function riskClass(value) {
  const s = String(value || '').toLowerCase();
  if (s.includes('high') || s.includes('over') || s.includes('breach')) return 'flag-red';
  if (s.includes('medium') || s.includes('risk') || s.includes('warn')) return 'flag-amber';
  if (s.includes('low') || s.includes('ok') || s.includes('track')) return 'flag-green';
  return 'flag-blue';
}

// The queue counts App.jsx already fetches for the sidebar badges ARE the workflow status
// breakdown — one row per workflow state a claim can sit in. Rendering them as a table here needs
// no new endpoint and cannot drift from the badges, because it is the same object.
//
// Order is the operational lifecycle, not alphabetical: a manager reads this top-to-bottom to see
// where work is piling up.
const WORKFLOW_STATUS_ROWS = [
  { key: 'new', label: 'New', taskView: 'new', tone: 'flag-blue' },
  { key: 'unassigned', label: 'Unassigned', taskView: 'unassigned', tone: 'flag-amber' },
  { key: 'assigned', label: 'Assigned To AR Reviewer', taskView: 'assigned', tone: 'flag-green' },
  { key: 'payerFollowup', label: 'Payer Follow-up Required', taskView: 'payerFollowup', tone: 'flag-amber' },
  { key: 'pendingDocumentation', label: 'Pending Documentation', taskView: 'pendingDocumentation', tone: 'flag-amber' },
  { key: 'pendingPayerResponse', label: 'Pending Payer Response', taskView: 'pendingPayerResponse', tone: 'flag-blue' },
  { key: 'writeOffApproval', label: 'Write-Off Pending Approval', taskView: 'writeOffApproval', tone: 'flag-amber' },
  { key: 'internalEscalation', label: 'Internal Escalation', taskView: 'internalEscalation', tone: 'flag-red' },
  { key: 'externalEscalation', label: 'External Escalation', taskView: 'externalEscalation', tone: 'flag-red' },
  { key: 'escalationResponse', label: 'Escalation Response', taskView: 'escalationResponse', tone: 'flag-blue' },
  { key: 'externalResponse', label: 'External Response', taskView: 'externalResponse', tone: 'flag-blue' },
  { key: 'verification', label: 'Verification Pending', taskView: 'verification', tone: 'flag-amber' },
  { key: 'closed', label: 'Closed', taskView: 'closed', tone: 'flag-green' }
];

function WorkflowStatusSummary({ counts = {}, onKpiClick }) {
  const rows = WORKFLOW_STATUS_ROWS
    .map(r => ({ ...r, count: Number(counts?.[r.key] ?? 0) }))
    // A null count means the badge request has not returned yet; a zero means the queue really is
    // empty. Both render, so the table never silently loses a lifecycle stage.
    .filter(r => counts?.[r.key] !== undefined);

  const total = rows.reduce((sum, r) => sum + r.count, 0);

  return <RoleCard
    title="Workflow Status Summary"
    subtitle="Claims by workflow state. A claim sits in exactly one queue — the counts are the same ones behind the sidebar badges.">
    <div className="role-table-wrap">
      <table className="role-table wide">
        <thead><tr><th>Workflow Status</th><th>Claims</th><th>% of Total</th><th>State</th></tr></thead>
        <tbody>
          {rows.length ? rows.map(r => <tr key={r.key}>
            <td>
              <button type="button" className="role-table-link" onClick={() => onKpiClick?.({ taskView: r.taskView })}>{r.label}</button>
            </td>
            <td>
              <button type="button" className="role-table-link numeric" onClick={() => onKpiClick?.({ taskView: r.taskView })}>{n(r.count)}</button>
            </td>
            <td>{total > 0 ? `${((r.count / total) * 100).toFixed(1)}%` : '0.0%'}</td>
            <td><span className={`role-flag ${r.tone}`}>{r.count > 0 ? 'Active' : 'Empty'}</span></td>
          </tr>) : <EmptyRow colSpan={4} />}
        </tbody>
      </table>
    </div>
  </RoleCard>;
}

export default function DashboardPage({ data, user = {}, labName = '', onKpiClick, workflowStatusCounts }) {
  const role = user?.role || '';
  if (isArReviewerRole(role)) return <AnalystDashboard data={data} user={user} labName={labName} onKpiClick={onKpiClick} workflowStatusCounts={workflowStatusCounts} />;
  if (isClientManagerRole(role)) return <SingleAccountDashboard data={data} user={user} labName={labName} mode="client" />;
  if (isAccountManagerRole(role)) return <SingleAccountDashboard data={data} user={user} labName={labName} mode="account" />;
  return <ManagerDashboard data={data} user={user} labName={labName} onKpiClick={onKpiClick} workflowStatusCounts={workflowStatusCounts} />;
}

function ManagerDashboard({ data, onKpiClick, workflowStatusCounts }) {
  const classifications = data.denialClassifications || [];
  const workload = data.analystWorkload || [];
  const assignedClaims = data.assignedClaims ?? data.assigned ?? 0;
  const openClaims = data.openClaims ?? Math.max(Number(data.totalClaims || 0) - Number(data.closedClaims || 0), 0);
  const unassignedClaims = data.pendingClaims ?? data.unassignedClaims ?? 0;
  const escalated = data.escalatedClaims ?? data.escalationCount ?? data.escalatedCount ?? 0;
  const totalTasks = data.openInProgressCount ?? data.totalOpenTasks ?? data.totalTasks ?? data.totalDenials ?? 0;
  const slaBreached = data.slaBreachedClaims ?? data.slaBreached ?? data.slaBreachedCount ?? (data.slaTiles || []).find(x => String(x.label || '').toLowerCase().includes('breach'))?.count ?? 0;
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
    <div className="dashboard-overview-grid dashboard-overview-grid-full">
      <RoleCard title="Denial Classification Summary" subtitle="Claims are counted once per classification they carry. A claim with more than one denial classification appears in more than one row, so column totals can exceed Total Open Claims.">
        <div className="role-table-wrap"><table className="role-table wide"><thead><tr><th>Classification</th><th>Claims</th><th>Balance</th><th>Assigned</th><th>In Progress</th><th>Closed</th><th>SLA Risk</th></tr></thead><tbody>
          {classifications.length ? classifications.map((r, i) => <tr key={i}><td><button type="button" className="role-table-link" onClick={() => onKpiClick?.({ taskView: 'all', denialClassification: r.classification || '' })}>{r.classification || 'Unclassified'}</button></td><td><button type="button" className="role-table-link numeric" onClick={() => onKpiClick?.({ taskView: 'all', denialClassification: r.classification || '' })}>{n(r.count)}</button></td><td>{money(r.outstanding)}</td><td><button type="button" className="role-table-link numeric" onClick={() => onKpiClick?.({ taskView: 'assigned', denialClassification: r.classification || '' })}>{n(r.assigned ?? r.assignedCount ?? 0)}</button></td><td>{n(r.inProgress ?? r.inProgressCount ?? 0)}</td><td>{n(r.closed ?? r.closedCount ?? 0)}</td><td><RiskPill value={r.slaRisk || r.risk || (Number(r.percentageOfTotal || 0) > 25 ? 'High' : 'Medium')} /></td></tr>) : <EmptyRow colSpan={7} />}
        </tbody></table></div>
      </RoleCard>
    </div>
    <div className="dashboard-overview-grid dashboard-overview-grid-full">
      <WorkflowStatusSummary counts={workflowStatusCounts} onKpiClick={onKpiClick} />
    </div>
    <ReviewerAgingTable rows={workload} title="Analyst Workload" onReviewerClick={(reviewer, taskView) => onKpiClick?.({ taskView, reviewer })} />
  </div>;
}

function AnalystDashboard({ data, user, labName, onKpiClick, workflowStatusCounts }) {
  const workload = data.analystWorkload || [];
  const mine = workload.find(x => String(x.reviewerName || '').toLowerCase() === String(user?.displayName || user?.userName || '').toLowerCase()) || workload[0] || {};
  // Use the same per-reviewer workload row that renders the "My Aging View" table above, so the
  // tile always matches it. data.assignedClaims is the queue-PRECEDENCE count (a claim in payer
  // follow-up / documentation / escalation leaves the "Assigned" bucket), which read 91 while the
  // aging table showed all 100 actively-assigned claims.
  const assignedClaims = mine.assigned ?? mine.totalClaims ?? data.assignedClaims ?? data.totalClaims ?? 0;
  const pendingTasks = mine.pendingTasks ?? mine.pending ?? data.openInProgressCount ?? 0;
  const closedTasks = mine.closedTasks ?? mine.closed ?? data.closedCount ?? 0;
  const openBalance = data.outstandingAmount || 0;

  return <div className="role-dashboard analyst-dashboard">
    <RoleHeader title="AR Analyst Dashboard" subtitle="My work queue" tag="Analyst view" user={user} labName={labName} />
    <ReviewerAgingTable rows={workload} title="My Aging View" onReviewerClick={(reviewer, taskView) => onKpiClick?.({ taskView, reviewer })} />
    <div className="role-kpi-row">
      <RoleKpi label="Assigned Claims" value={n(assignedClaims)} tone="blue" />
      <RoleKpi label="Open Tasks" value={n(pendingTasks)} tone="amber" />
      <RoleKpi label="Completed Tasks" value={n(closedTasks)} tone="green" />
      <RoleKpi label="Open Balance" value={money(openBalance)} tone="teal" />
    </div>
    <WorkflowStatusSummary counts={workflowStatusCounts} onKpiClick={onKpiClick} />
    <div className="role-grid two analyst-layout">
      <RoleCard title="Priority Work Queue" subtitle="A claim is listed under every denial classification it carries, so queue claim counts can add up to more than your assigned total.">
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

function ReviewerAgingTable({ rows = [], title = 'Aging View by AR Reviewer', onReviewerClick }) {
  return <RoleCard title={title}>
    <div className="role-table-wrap"><table className="role-table reviewer-aging-table"><thead><tr><th>AR Reviewer</th><th>0-30</th><th>31-60</th><th>61-90</th><th>91-120</th><th>120+</th><th>Assigned</th><th>In Progress</th><th>Pending</th><th>Closed</th></tr></thead><tbody>
      {rows.length ? rows.map((r, i) => <tr key={`${r.reviewerName || 'reviewer'}-${i}`}><td><button type="button" className="role-table-link reviewer-link" onClick={() => onReviewerClick?.(r.reviewerName || '', 'all')}><span className="avatar-sm">{initials(r.reviewerName)}</span>{r.reviewerName || 'Unassigned'}</button></td><td>{n(r.aging0To30 ?? 0)}</td><td>{n(r.aging31To60 ?? 0)}</td><td>{n(r.aging61To90 ?? 0)}</td><td>{n(r.aging91To120 ?? 0)}</td><td>{n(r.agingOver120 ?? 0)}</td><td><button type="button" className="role-table-link numeric" onClick={() => onReviewerClick?.(r.reviewerName || '', 'assigned')}>{n(r.assigned ?? r.totalClaims ?? 0)}</button></td><td>{n(r.inProgress ?? 0)}</td><td>{n(r.pending ?? 0)}</td><td>{n(r.closed ?? 0)}</td></tr>) : <EmptyRow colSpan={10} />}
    </tbody></table></div>
  </RoleCard>;
}

function RoleHeader({ title, subtitle, tag, user, labName }) { return <div className="role-page-head"><div><h2>{title}</h2><p>DenialFlow / <b>{subtitle}</b>{labName ? ` - ${labName}` : ''}</p></div><div className="role-head-right"><span className="role-tag">{tag}</span><span className="role-user"><span className="avatar-sm">{initials(user?.displayName || user?.userName)}</span>{user?.displayName || user?.userName || 'Workflow User'}</span></div></div>; }
function RoleKpi({ label, value, tone }) { return <div className={`role-kpi ${tone || ''}`}><div className="role-kpi-value">{value}</div><div className="role-kpi-label">{label}</div></div>; }
function DashboardKpi({ label, value, icon, tone, onClick }) { return <button type="button" className={`modern-kpi ${tone || ''}`} onClick={onClick}><span className="modern-kpi-icon"><i className={`bi ${icon}`} /></span><span><small>{label}</small><b>{value}</b><em>Click to view filtered claims</em></span></button>; }
function RoleCard({ title, subtitle, children }) { return <div className="role-card"><div className="role-card-hd"><div><div className="role-card-title">{title}</div>{subtitle && <div className="role-card-subtitle">{subtitle}</div>}</div></div><div className="role-card-body">{children}</div></div>; }
function RiskPill({ value }) { return <span className={`role-flag ${riskClass(value)}`}>{value || 'Medium'}</span>; }
function EmptyRow({ colSpan }) { return <tr><td colSpan={colSpan} className="empty-cell">No dashboard data found.</td></tr>; }
