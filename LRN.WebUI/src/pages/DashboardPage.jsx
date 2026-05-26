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

export default function DashboardPage({ data, user = {}, labName = '' }) {
  const role = user?.role || '';
  if (isArReviewerRole(role)) return <AnalystDashboard data={data} user={user} labName={labName} />;
  if (isClientManagerRole(role)) return <SingleAccountDashboard data={data} user={user} labName={labName} mode="client" />;
  if (isAccountManagerRole(role)) return <SingleAccountDashboard data={data} user={user} labName={labName} mode="account" />;
  return <ManagerDashboard data={data} user={user} labName={labName} />;
}

function ManagerDashboard({ data, user, labName }) {
  const classifications = data.denialClassifications || [];
  const workload = data.analystWorkload || [];
  const assignedClaims = data.assignedClaims ?? data.assigned ?? 0;
  const pendingClaims = data.pendingClaims ?? Math.max(Number(data.totalClaims || 0) - Number(assignedClaims || 0) - Number(data.closedClaims || 0), 0);
  const escalated = data.escalatedClaims ?? data.escalationCount ?? data.escalatedCount ?? data.openInProgressCount ?? 0;
  const slaPercent = data.slaCompliancePercent ?? data.slaCompliance ?? 86;

  return <div className="role-dashboard manager-dashboard">
    <div className="role-kpi-row">
      <RoleKpi label="Open Claims" value={n(pendingClaims || data.totalClaims)} tone="blue" />
      <RoleKpi label="Open Balance" value={money(data.outstandingAmount || 0)} tone="teal" />
      <RoleKpi label="Escalated" value={n(escalated)} tone="red" />
      <RoleKpi label="SLA Compliance" value={pct(slaPercent)} tone="green" />
    </div>
    <div className="role-grid two">
      <div>
        <RoleCard title="Denial Classification Summary">
          <div className="role-table-wrap"><table className="role-table wide"><thead><tr><th>Classification</th><th>Claims</th><th>Balance</th><th>Assigned</th><th>In Progress</th><th>Closed</th><th>SLA Risk</th></tr></thead><tbody>
            {classifications.length ? classifications.map((r, i) => <tr key={i}><td>{r.classification || '-'}</td><td>{n(r.count)}</td><td>{money(r.outstanding)}</td><td>{n(r.assigned || Math.round(Number(r.count || 0) * .75))}</td><td>{n(r.inProgress || Math.round(Number(r.count || 0) * .35))}</td><td>{n(r.closed || r.closedCount || 0)}</td><td><RiskPill value={r.slaRisk || r.risk || (Number(r.percentageOfTotal || 0) > 25 ? 'High' : 'Medium')} /></td></tr>) : <EmptyRow colSpan={7} />}
          </tbody></table></div>
        </RoleCard>
        <RoleCard title="Analyst Performance">
          <div className="role-table-wrap"><table className="role-table"><thead><tr><th>Analyst</th><th>Open</th><th>Closed</th><th>Recovery</th><th>SLA</th><th>Escalations</th></tr></thead><tbody>
            {workload.length ? workload.map((r, i) => <tr key={i}><td><span className="avatar-sm">{initials(r.reviewerName)}</span> {r.reviewerName || '-'}</td><td>{n(r.pendingTasks ?? r.pending ?? 0)}</td><td>{n(r.closedTasks ?? r.closed ?? 0)}</td><td>{money(r.recoveryAmount || 0)}</td><td>{pct(r.slaPercent || 85)}</td><td>{n(r.escalations || 0)}</td></tr>) : <EmptyRow colSpan={6} />}
          </tbody></table></div>
        </RoleCard>
      </div>
      <DashboardSidePanels data={data} manager />
    </div>
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
      <div>
        <RoleCard title="My Productivity Today"><div className="role-metrics-list"><Metric name="Tasks worked" value={n(closedTasks)} /><Metric name="Remaining queue" value={n(pendingTasks)} /><Metric name="Escalations created" value={n(data.escalatedCount || 0)} /><Metric name="SLA focus" value={pct(data.slaCompliance || 82)} /></div></RoleCard>
        <DashboardSidePanels data={data} />
      </div>
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
      <div>
        <RoleCard title="Recommended Single-Account Metrics"><div className="role-metrics-list"><Metric name="Payer response exposure" value={money(data.outstandingAmount || 0)} /><Metric name="Client pending requests" value={n(data.escalatedCount || 0)} /><Metric name="Documentation queue" value={n(data.openInProgressCount || 0)} /><Metric name="Closed this cycle" value={n(data.closedCount || 0)} /></div></RoleCard>
        <AgingMix />
      </div>
    </div>
  </div>;
}

function DashboardSidePanels({ data }) {
  return <div>
    <RoleCard title="Recommended Metrics"><div className="role-metrics-list"><Metric name="SLA Compliance" value={pct(data.slaCompliance || 86)} /><Metric name="Recovery Rate" value={pct(data.recoveryRate || 24)} /><Metric name="Aging Exposure" value={money(data.agingExposure || data.outstandingAmount || 0)} /><Metric name="Work Queue Velocity" value={pct(data.velocity || 72)} /></div></RoleCard>
    <AgingMix />
  </div>;
}

function RoleHeader({ title, subtitle, tag, user, labName }) { return <div className="role-page-head"><div><h2>{title}</h2><p>DenialFlow / <b>{subtitle}</b>{labName ? ` · ${labName}` : ''}</p></div><div className="role-head-right"><span className="role-tag">{tag}</span><span className="role-user"><span className="avatar-sm">{initials(user?.displayName || user?.userName)}</span>{user?.displayName || user?.userName || 'Workflow User'}</span></div></div>; }
function RoleKpi({ label, value, tone }) { return <div className={`role-kpi ${tone || ''}`}><div className="role-kpi-value">{value}</div><div className="role-kpi-label">{label}</div></div>; }
function RoleCard({ title, children }) { return <div className="role-card"><div className="role-card-hd"><div className="role-card-title">{title}</div></div><div className="role-card-body">{children}</div></div>; }
function RiskPill({ value }) { return <span className={`role-flag ${riskClass(value)}`}>{value || 'Medium'}</span>; }
function Metric({ name, value }) { return <div className="role-metric"><div><b>{name}</b><span>Workflow metric</span></div><strong>{value}</strong></div>; }
function EmptyRow({ colSpan }) { return <tr><td colSpan={colSpan} className="empty-cell">No dashboard data found.</td></tr>; }
function AgingMix() { return <RoleCard title="Aging Mix"><div className="aging-row"><span>0–30 days</span><div><i style={{ width: '64%' }} /></div></div><div className="aging-row"><span>31–60 days</span><div><i style={{ width: '48%' }} /></div></div><div className="aging-row"><span>61–90 days</span><div><i style={{ width: '36%' }} /></div></div><div className="aging-row"><span>90+ days</span><div><i style={{ width: '28%' }} /></div></div></RoleCard>; }
