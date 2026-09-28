import { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router';
import { canOpen } from '../config/navigation';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { ErrorBox, Loading, PageHeader, QueueBadge } from '../components/Status';
import { fmt } from '../utils/format';

function Kpi({ label, value, hint, tone }) {
  return (
    <div className="col-6 col-md-4 col-xl">
      <div className={`arwb-kpi ${tone ? `arwb-kpi-${tone}` : ''}`}>
        <div className="arwb-kpi-label">{label}</div>
        <div className="arwb-kpi-value">{value}</div>
        {hint && <div className="arwb-kpi-hint">{hint}</div>}
      </div>
    </div>
  );
}

export default function DashboardPage() {
  const { labId, lab, user } = useWorkbench();
  const navigate = useNavigate();
  const [summary, setSummary] = useState(null);
  const [error, setError] = useState('');
  const [reload, setReload] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    setError('');
    arWorkbenchService.queues(labId, controller.signal)
      .then(setSummary)
      .catch((e) => { if (e.name !== 'AbortError') setError(e.message); });
    return () => controller.abort();
  }, [labId, reload]);

  const canDrill = canOpen(user?.roleCode, 'workqueue');
  const openQueue = useCallback((queueId, subQueueId) => {
    if (!canDrill) return;
    const params = new URLSearchParams({ queue: queueId });
    if (subQueueId) params.set('sub', subQueueId);
    navigate(`/work-queue?${params}`);
  }, [canDrill, navigate]);

  if (error) return <ErrorBox message={error} onRetry={() => setReload((n) => n + 1)} />;
  if (!summary) return <Loading />;

  const recoveryRate = summary.totalInitialAR > 0 ? summary.totalRecovered / summary.totalInitialAR : null;

  return (
    <>
      <PageHeader title="Dashboard" subtitle={`${lab?.labName || ''} · denied claims identified from claim-level data`} />

      <div className="row g-3 mb-4">
        <Kpi label="Denied claims" value={fmt.count(summary.totalClaims)} />
        <Kpi label="Initial insurance AR" value={fmt.moneyCompact(summary.totalInitialAR)} hint="At identification" />
        <Kpi label="Recovered" value={fmt.moneyCompact(summary.totalRecovered)} hint={recoveryRate === null ? null : `${fmt.pct(recoveryRate)} of initial AR`} tone="good" />
        <Kpi label="Remaining AR" value={fmt.moneyCompact(summary.totalRemainingAR)} tone="warn" />
        <Kpi label="Unassigned, open balance" value={fmt.count(summary.unassignedOpen)} />
        <Kpi label="Awaiting QA" value={fmt.count(summary.awaitingQa)} />
      </div>

      <div className="arwb-table-card">
        <div className="arwb-table-toolbar">
          <h2 className="h6 mb-0">AR queues</h2>
          <span className="text-secondary small ms-2">Every claim sits in exactly one queue</span>
        </div>
        <div className="table-responsive">
          <table className="table table-sm align-middle mb-0 arwb-table">
            <thead>
              <tr>
                <th scope="col">Queue</th>
                <th scope="col" className="text-end">Claims</th>
                <th scope="col" className="text-end">Remaining AR</th>
                <th scope="col" className="text-center">Priority</th>
              </tr>
            </thead>
            <tbody>
              {summary.queues.map((q) => (
                <QueueRows key={q.queueId} queue={q} onOpen={openQueue} canDrill={canDrill} />
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}

function QueueRows({ queue, onOpen, canDrill }) {
  return (
    <>
      <tr className={canDrill && queue.claimCount ? 'arwb-clickable' : ''} onClick={() => queue.claimCount && onOpen(queue.queueId)}>
        <td><QueueBadge label={queue.label} badge={queue.badgeClass} /></td>
        <td className="text-end fw-semibold">{fmt.count(queue.claimCount)}</td>
        <td className="text-end">{fmt.money(queue.remainingAR)}</td>
        <td className="text-center">{queue.isPriority ? <i className="bi bi-flag-fill text-danger" title="Priority queue" /> : ''}</td>
      </tr>
      {queue.sub.map((s) => (
        <tr key={s.queueId} className={canDrill && s.claimCount ? 'arwb-clickable' : ''} onClick={() => s.claimCount && onOpen(queue.queueId, s.queueId)}>
          <td className="ps-4 text-secondary small"><i className="bi bi-arrow-return-right me-2" />{s.label}</td>
          <td className="text-end">{fmt.count(s.claimCount)}</td>
          <td className="text-end">{fmt.money(s.remainingAR)}</td>
          <td className="text-center">{s.isPriority ? <i className="bi bi-flag text-danger" title="Priority sub-queue" /> : ''}</td>
        </tr>
      ))}
    </>
  );
}
