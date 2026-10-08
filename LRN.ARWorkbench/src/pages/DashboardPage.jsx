import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router';
import { BarList, Donut, sequentialRamp } from '../components/Charts';
import Icon from '../components/Icon';
import { Card, GoTo, Kpi } from '../components/Panel';
import useTableSort from '../components/useTableSort';
import { canOpen } from '../config/navigation';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { ErrorBox, Loading, PageHeader } from '../components/Status';
import { fmt } from '../utils/format';

// Theme tokens (styles.css), so the donut follows light / dark like the rest of the page.
const GOOD = 'var(--good)';
const WARNING = 'var(--warning)';
const pct0 = (v) => `${Math.round(Number(v || 0) * 100)}%`;

function Delta({ tone = 'flat', children }) {
  return <span className={`arwb-kpi-delta ${tone}`}>{children}</span>;
}

/**
 * The mockup's System Administrator dashboard (docs/Denial_WorkFlow/LRN_Denial_AR_Workbench_Demo_Account.html):
 * 10 KPI tiles, Latest Denial Analysis Report insights, AR Collections Progress, Claim Queue
 * Volumes, the four distribution charts and Agent Productivity. Every figure comes from
 * /dashboard, already limited to the caller's scope; the role only decides which cards show,
 * exactly as in the mockup.
 */
export default function DashboardPage() {
  const { labId, lab, user } = useWorkbench();
  const navigate = useNavigate();
  const [d, setD] = useState(null);
  const [error, setError] = useState('');
  const [reload, setReload] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    setError('');
    setD(null);
    arWorkbenchService.dashboard(labId, controller.signal)
      .then(setD)
      .catch((e) => { if (e.name !== 'AbortError') setError(e.message); });
    return () => controller.abort();
  }, [labId, reload]);

  if (error) return <ErrorBox message={error} onRetry={() => setReload((n) => n + 1)} />;
  if (!d) return <Loading />;

  const isViewer = user?.roleCode === 'viewer' && !user?.siteAdmin;
  const canSeeAllQueues = user?.siteAdmin || ['admin', 'manager', 'lead'].includes(user?.roleCode);
  const canDrill = canOpen(user, 'workqueue');
  const openQueue = (params) => navigate(`/work-queue?${new URLSearchParams(params)}`);
  const drill = (params) => (canDrill ? () => openQueue(params) : undefined);
  // The Work Queue's AR Queue filter takes "queue" or "queue|sub" (one leaf).
  const queueParams = (key, extra = {}) => {
    const [queue, sub] = String(key || '').split('|');
    return { queue: sub ? `${queue}|${sub}` : queue, ...extra };
  };

  const identDiff = d.identifiedThisWeek - d.identifiedLastWeek;
  const kpis = [
    { label: 'Total Eligible Claims', value: fmt.count(d.totalClaims),
      delta: <Delta tone={identDiff === 0 ? 'flat' : identDiff > 0 ? 'up' : 'down'}>{`${identDiff >= 0 ? '+' : ''}${identDiff} identified this wk`}</Delta> },
    { label: 'Total Outstanding Insurance AR', value: fmt.money(d.totalOutstandingAR),
      delta: d.dataRefreshedOn ? <Delta>as of {fmt.date(d.dataRefreshedOn)}</Delta> : null },
    { label: 'Claims Awaiting Assignment', value: fmt.count(d.unassigned),
      delta: d.unassigned > 0 ? <Delta tone="down">needs manager action</Delta> : <Delta tone="up">queue clear</Delta> },
    { label: 'Claims In Progress', value: fmt.count(d.inProgress) },
    { label: 'Claims Awaiting QA', value: fmt.count(d.awaitingQa) },
    { label: 'QA Rejected', value: fmt.count(d.qaRejected) },
    { label: 'Completed / Closed Claims', value: fmt.count(d.completed) },
    { label: 'Total Recovered Amount', value: fmt.money(d.totalRecovered) },
    { label: 'Potential Recovery Amount', value: fmt.money(d.potentialRecovery) },
    { label: 'Overdue Follow-Ups', value: fmt.count(d.overdueFollowUps),
      delta: d.overdueFollowUps > 0 ? <Delta tone="down">{d.overdueFollowUps} past due</Delta> : <Delta tone="up">on schedule</Delta> }
  ];

  const ramp = sequentialRamp(d.agingBuckets.length);
  const recoveryPct = d.totalInitialAR > 0 ? d.totalRecovered / d.totalInitialAR : 0;
  const arExpectation = d.arProgress.reduce((s, r) => s + r.amount, 0);

  return (
    <>
      <PageHeader note={d.dataRefreshedOn ? `${lab?.labName || ''} · data refreshed ${fmt.date(d.dataRefreshedOn)}` : lab?.labName}>
        <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => setReload((n) => n + 1)}>
          <Icon name="refresh" size={14} />Refresh
        </button>
      </PageHeader>

      <div className="arwb-grid arwb-grid-kpi arwb-section">
        {kpis.map((k) => <Kpi key={k.label} {...k} />)}
      </div>

      {!isViewer && (
        <Card icon="layers" title="Latest Denial Analysis Report insights" sub="from the latest data load" flush
          action={canOpen(user, 'data-processing') && <GoTo onClick={() => navigate('/data-processing')}>Open Data Processing</GoTo>}>
          <DenialHighlights rows={d.denialHighlights} onRoute={canDrill ? (code) => openQueue({ code }) : null} />
        </Card>
      )}

      <Card icon="graph-up-arrow" title="AR Collections Progress" sub="revenue expectation by AR queue"
        action={canOpen(user, 'reports') && <GoTo onClick={() => navigate('/reports?report=ar-collections')}>View Full Report</GoTo>}>
        <BarList wide items={d.arProgress.map((r) => ({
          label: r.label, value: r.amount,
          display: `${fmt.moneyCompact(r.amount)} · ${fmt.count(r.count)}`,
          onClick: drill(queueParams(r.key))
        }))} />
        <div className="arwb-hint mt-2">
          {`Across all ${fmt.count(d.totalClaims)} claims, total revenue expectation stands at ${fmt.money(arExpectation)}, with ${fmt.money(d.totalRecovered)} collected so far — an overall ${pct0(arExpectation > 0 ? d.totalRecovered / arExpectation : 0)} realization rate.`}
        </div>
      </Card>

      {canSeeAllQueues && (
        <Card icon="inbox" title="Claim Queue Volumes" sub="workable AR Queue leaves with an open insurance balance — assign volumes to agents from here"
          action={canDrill && <GoTo onClick={() => navigate('/work-queue')}>Open Work Queue</GoTo>}>
          <BarList wide items={d.queueVolumes.map((q) => ({
            label: q.label, value: q.count, display: fmt.count(q.count),
            onClick: drill(queueParams(q.key, { open: '1' }))
          }))} empty="No open insurance AR in any workable queue." />
        </Card>
      )}

      <div className="arwb-grid arwb-grid-charts arwb-section">
        <Card title="Denial Category Distribution" sub="outstanding balance">
          <BarList items={d.denialCategories.map((c) => ({
            label: c.label, value: c.amount, display: fmt.moneyCompact(c.amount), onClick: drill({ category: c.key })
          }))} />
        </Card>
        <Card title="AR Aging Distribution" sub="claim count by age of service">
          <BarList items={d.agingBuckets.map((b, i) => ({ label: b.label, value: b.count, display: fmt.count(b.count), color: ramp[i] }))} />
        </Card>
        <Card title="Claim Workflow Status" sub="where work currently sits">
          <BarList items={d.workflowStatuses.map((s) => ({
            label: s.label, value: s.count, display: fmt.count(s.count), onClick: s.count ? drill({ status: s.key }) : undefined
          }))} />
        </Card>
        <Card title="Recovery Performance" sub="identified vs. recovered">
          <Donut
            segments={[
              { label: 'Recovered', value: d.totalRecovered, color: GOOD, display: fmt.moneyCompact(d.totalRecovered) },
              { label: 'Outstanding', value: d.totalOutstandingAR, color: WARNING, display: fmt.moneyCompact(d.totalOutstandingAR) }
            ]}
            centerLabel={fmt.pct(recoveryPct)}
            centerSub="recovered" />
        </Card>
      </div>

      {!isViewer && (
        <Card title="Agent Productivity" sub="current portfolio, all statuses" flush>
          <AgentTable agents={d.agents} />
        </Card>
      )}
    </>
  );
}

function AgentTable({ agents }) {
  const { rows, th } = useTableSort(agents, {
    agent: (a) => a.displayName, assigned: (a) => a.assigned, completed: (a) => a.completed, review: (a) => a.awaitingReview, recovery: (a) => a.recovery
  });
  return (
          <div className="arwb-table-wrap">
            <table className="arwb-data-table">
              <thead>
                <tr>
                  {th('agent', 'Agent')}
                  {th('assigned', 'Assigned', { className: 'num' })}
                  {th('completed', 'Completed', { className: 'num' })}
                  {th('review', 'Awaiting Review', { className: 'num' })}
                  {th('recovery', 'Recovery $', { className: 'num' })}
                </tr>
              </thead>
              <tbody>
                {rows.length ? rows.map((a) => (
                  <tr key={a.userName}>
                    <td><span className="arwb-avatar-sm">{initials(a.displayName)}</span>{a.displayName} <span className="arwb-hint">({a.userName})</span></td>
                    <td className="num mono">{fmt.count(a.assigned)}</td>
                    <td className="num mono">{fmt.count(a.completed)}</td>
                    <td className="num mono">{fmt.count(a.awaitingReview)}</td>
                    <td className="num mono">{fmt.money(a.recovery)}</td>
                  </tr>
                )) : (
                  <tr><td colSpan={5}><div className="arwb-empty-state">No claims assigned yet.</div></td></tr>
                )}
              </tbody>
            </table>
          </div>
  );
}

function initials(name) {
  return String(name || '?').split(/\s+/).filter(Boolean).slice(0, 2).map((p) => p[0].toUpperCase()).join('');
}

function DenialHighlights({ rows: all, onRoute }) {
  const { rows, th } = useTableSort(all, {
    code: (h) => h.code, description: (h) => h.description, count: (h) => h.count, balance: (h) => h.balance, payer: (h) => h.topPayer,
    payerBalance: (h) => h.topPayerBalance, impact: (h) => h.impactPct, category: (h) => h.category
  });
  if (!all.length) return <div className="arwb-empty-state">No denial code groups with an open balance in the current scope.</div>;
  return (
    <div className="arwb-table-wrap">
      <table className="arwb-data-table">
        <thead>
          <tr>
            <th scope="col">#</th>
            {th('code', 'Denial Codes')}
            {th('description', 'Description')}
            {th('count', '# of Denial', { className: 'num' })}
            {th('balance', 'Total Balance ($)', { className: 'num' })}
            {th('payer', 'Highest $ Impact — Insurance')}
            {th('payerBalance', 'Ins. Balance ($)', { className: 'num' })}
            {th('impact', '$ Impact (%)', { className: 'num' })}
            <th scope="col">Observation</th>
            {th('category', 'Category')}
            <th scope="col">Recommended Action</th>
            {onRoute && <th scope="col" className="num">Action</th>}
          </tr>
        </thead>
        <tbody>
          {rows.map((h, i) => (
            <tr key={h.code}>
              <td className="mono">{i + 1}</td>
              <td className="mono">{h.code}</td>
              <td className="wrap">{h.description || '—'}</td>
              <td className="num">{fmt.count(h.count)}</td>
              <td className="num mono">{fmt.money(h.balance)}</td>
              <td>{h.topPayer || '—'}</td>
              <td className="num mono">{fmt.money(h.topPayerBalance)}</td>
              <td className="num mono">{pct0(h.impactPct)}</td>
              <td className="wrap">{h.observation}</td>
              <td><span className={`arwb-badge ${h.category === 'Review' ? 'arwb-badge-warning' : 'arwb-badge-info'}`}>{h.category}</span></td>
              <td className="wrap">{h.action}</td>
              {onRoute && (
                <td className="num">
                  <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={() => onRoute(h.code)}>Route to Work Queue</button>
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
