import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router';
import { ComparisonBars } from '../components/Charts';
import Icon from '../components/Icon';
import { Card, GoTo, Kpi } from '../components/Panel';
import { ErrorBox, Loading, PageHeader } from '../components/Status';
import { canOpen } from '../config/navigation';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { downloadText, fmt, toCsv } from '../utils/format';

// The mockup's FU_BREAKDOWN_DIMS: each a field of the Comments Framework follow-up note; id is the
// /analytics property holding its rows.
const BREAKDOWNS = [
  { id: 'byClaimStatus', label: 'Claim Status' },
  { id: 'byFixResolution', label: 'Fix / Resolution' },
  { id: 'byDenialRootCause', label: 'Denial Root Cause' }
];

/**
 * T072 Recovery & Financial Analytics (mockup App.views.analytics): KPI tiles, recovered vs.
 * outstanding by client, payer, panel type, denial category, agent and AR queue, and the
 * Follow-Up Comments Breakdown. Every figure comes from /analytics, already limited to the
 * caller's scope in SQL; a bar drills into the Work Queue filtered to that value when the role
 * can open it.
 */
export default function AnalyticsPage() {
  const { labId, lab, user } = useWorkbench();
  const navigate = useNavigate();
  const [d, setD] = useState(null);
  const [error, setError] = useState('');
  const [reload, setReload] = useState(0);
  const [dim, setDim] = useState(BREAKDOWNS[0]);

  useEffect(() => {
    const controller = new AbortController();
    setError('');
    setD(null);
    arWorkbenchService.analytics(labId, controller.signal)
      .then(setD)
      .catch((e) => { if (e.name !== 'AbortError') setError(e.message); });
    return () => controller.abort();
  }, [labId, reload]);

  if (error) return <ErrorBox message={error} onRetry={() => setReload((n) => n + 1)} />;
  if (!d) return <Loading />;

  const isViewer = user?.roleCode === 'viewer' && !user?.siteAdmin;
  const canDrill = canOpen(user, 'workqueue');

  // param: the Work Queue's URL filter for this dimension; a row with no key (rolled up) does not drill.
  const bars = (rows, param) => rows.map((r) => ({
    label: r.label,
    a: r.recovered,
    b: r.outstanding,
    display: fmt.moneyCompact(r.recovered + r.outstanding),
    title: `${r.label}: ${fmt.money(r.recovered)} recovered · ${fmt.money(r.outstanding)} outstanding · ${fmt.count(r.count)} claims`,
    onClick: canDrill && param && r.key ? () => navigate(`/work-queue?${new URLSearchParams({ [param]: r.key })}`) : undefined
  }));

  const breakdown = d[dim.id] || [];
  const breakdownColumns = [
    { key: 'label', label: dim.label },
    { key: 'notes', label: '# Follow-Up Notes' },
    { key: 'claims', label: '# Claims' },
    { key: 'balance', label: 'Outstanding Balance', csv: (r) => Number(r.balance).toFixed(2) }
  ];
  const exportBreakdown = () => downloadText(
    `ARWorkbench_FollowUpBreakdown_${dim.label.replace(/[^A-Za-z]+/g, '')}_${new Date().toISOString().slice(0, 10)}.csv`,
    toCsv(breakdownColumns, breakdown));

  return (
    <>
      <PageHeader note={d.dataRefreshedOn ? `${lab?.labName || ''} · data refreshed ${fmt.date(d.dataRefreshedOn)}` : lab?.labName}>
        <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => setReload((n) => n + 1)}>
          <Icon name="refresh" size={14} />Refresh
        </button>
      </PageHeader>

      <div className="arwb-grid arwb-grid-kpi arwb-section">
        <Kpi label="Initial Insurance AR" value={fmt.money(d.initialAR)} />
        <Kpi label="Total Recovered" value={fmt.money(d.recovered)} />
        <Kpi label="Total Outstanding" value={fmt.money(d.outstanding)} />
        <Kpi label="Recovery Rate" value={fmt.pct(d.recoveryRate)} />
      </div>
      <div className="arwb-section-note arwb-section">
        Definitions: <b>Initial Insurance AR</b> is the original insurance balance identified at intake. <b>Recovered</b> is
        additional payments and adjustments booked since intake. <b>Outstanding</b> is the remaining insurance balance today.
        Recovery Rate = Recovered ÷ Initial Insurance AR — claims with a zero initial balance are left out of the rate.
      </div>

      <div className="arwb-grid arwb-grid-charts arwb-section">
        <Card title="Recovery by Client"><ComparisonBars items={bars(d.byClient)} /></Card>
        <Card title="Recovery by Payer" sub={canDrill ? 'click a payer to open its claims' : undefined}><ComparisonBars items={bars(d.byPayer, 'payer')} /></Card>
        <Card title="Recovery by Panel Type"><ComparisonBars items={bars(d.byPanel, 'panel')} /></Card>
        <Card title="Recovery by Denial Category"><ComparisonBars items={bars(d.byCategory, 'category')} /></Card>
        {!isViewer && (
          <Card title="Recovery by Agent"><ComparisonBars items={bars(d.byAgent, 'agent')} empty="No claims assigned yet." /></Card>
        )}
      </div>

      <Card title="Recovery by AR Queue" sub="work-queue rollup — see Reports for the full client-format breakdown"
        action={canOpen(user, 'reports') && <GoTo onClick={() => navigate('/reports')}>Open Reports</GoTo>}>
        <ComparisonBars items={bars(d.byQueue, 'queue')} />
      </Card>

      <Card title="Follow-Up Comments Breakdown" sub="Claim Status, Fix / Resolution & Denial Root Cause, rolled up from every logged follow-up note" flush
        action={(
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={exportBreakdown} disabled={!breakdown.length}>
            <Icon name="doc" size={15} /> Export
          </button>
        )}>
        <div className="arwb-tabs" role="tablist">
          {BREAKDOWNS.map((b) => (
            <button key={b.id} type="button" role="tab" aria-selected={b.id === dim.id}
              className={`arwb-tab-btn ${b.id === dim.id ? 'active' : ''}`} onClick={() => setDim(b)}>By {b.label}</button>
          ))}
        </div>
        {breakdown.length ? (
          <div className="arwb-table-wrap">
            <table className="arwb-data-table">
              <thead>
                <tr>
                  <th scope="col">{dim.label}</th>
                  <th scope="col" className="num"># Follow-Up Notes</th>
                  <th scope="col" className="num"># Claims</th>
                  <th scope="col" className="num">Outstanding Balance</th>
                </tr>
              </thead>
              <tbody>
                {breakdown.map((r) => (
                  <tr key={r.label}>
                    <td className="wrap">{r.label}</td>
                    <td className="num mono">{fmt.count(r.notes)}</td>
                    <td className="num mono">{fmt.count(r.claims)}</td>
                    <td className="num mono">{fmt.money(r.balance)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="arwb-empty-state">No follow-up notes logged with a {dim.label} yet in the current scope.</div>
        )}
      </Card>
    </>
  );
}
