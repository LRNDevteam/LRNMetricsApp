import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import DataTable from '../components/DataTable';
import { ErrorBox, PageHeader, QueueBadge, StatusBadge } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt, priorityBadgeClass } from '../utils/format';

const PAGE_SIZE = 50;

const COLUMNS = [
  { key: 'claimID', label: 'Claim ID', sortKey: 'claimId', render: (r) => <span className="fw-semibold">{r.claimID}</span> },
  { key: 'patientName', label: 'Patient', defaultHidden: true },
  { key: 'payerName', label: 'Payer', sortKey: 'payerName' },
  { key: 'clinicName', label: 'Clinic', defaultHidden: true },
  { key: 'panelName', label: 'Panel', defaultHidden: true },
  { key: 'dateOfService', label: 'DOS', sortKey: 'dateOfService', render: (r) => fmt.date(r.dateOfService), csv: (r) => fmt.date(r.dateOfService) },
  { key: 'denialCode', label: 'Denial code' },
  { key: 'denialCategory', label: 'Category', sortKey: 'denialCategory' },
  { key: 'queue', label: 'AR queue', render: (r) => <QueueBadge label={r.arQueueLabel} subLabel={r.arSubQueueLabel} badge={r.arQueueBadgeClass} />, csv: (r) => [r.arQueueLabel, r.arSubQueueLabel].filter(Boolean).join(' / ') },
  { key: 'workflowStatus', label: 'Status', sortKey: 'workflowStatus', render: (r) => <StatusBadge status={r.workflowStatus} /> },
  { key: 'priority', label: 'Priority', sortKey: 'priority', render: (r) => r.priority ? <span className={`badge ${priorityBadgeClass(r.priority)}`}>{r.priority}</span> : '—' },
  { key: 'assignedAgentName', label: 'Agent', render: (r) => r.assignedAgentName || r.assignedAgentUser || <span className="text-secondary">Unassigned</span>, csv: (r) => r.assignedAgentName || r.assignedAgentUser || '' },
  { key: 'initialInsuranceAR', label: 'Initial AR', align: 'end', render: (r) => fmt.money(r.initialInsuranceAR), defaultHidden: true },
  { key: 'recoveredAmount', label: 'Recovered', align: 'end', sortKey: 'recoveredAmount', render: (r) => fmt.money(r.recoveredAmount) },
  { key: 'remainingAR', label: 'Remaining AR', align: 'end', sortKey: 'remainingAR', render: (r) => <span className="fw-semibold">{fmt.money(r.remainingAR)}</span> },
  { key: 'agingDays', label: 'Aging', align: 'end', sortKey: 'agingDays', render: (r) => (r.agingDays ?? '—') },
  { key: 'daysSinceLastTouch', label: 'Days untouched', align: 'end', sortKey: 'daysSinceLastTouch', render: (r) => (r.daysSinceLastTouch ?? '—'), defaultHidden: true },
  { key: 'nextFollowUpDate', label: 'Next follow-up', sortKey: 'nextFollowUpDate', render: (r) => fmt.date(r.nextFollowUpDate), csv: (r) => fmt.date(r.nextFollowUpDate), defaultHidden: true },
  { key: 'flags', label: 'Flags', render: (r) => (
    <span className="d-inline-flex gap-1">
      {r.isTflRisk && <span className="badge text-bg-danger" title="Timely filing at risk">TFL</span>}
      {r.isNonCollectible && <span className="badge text-bg-secondary" title="Non-collectible denial code">NC</span>}
      {r.openCipCases > 0 && <span className="badge text-bg-warning" title="Open CIP case">CIP</span>}
      {r.pendingAgentRequests > 0 && <span className="badge text-bg-info" title="Pending agent request">REQ</span>}
    </span>
  ), csv: (r) => [r.isTflRisk && 'TFL', r.isNonCollectible && 'NC', r.openCipCases > 0 && 'CIP', r.pendingAgentRequests > 0 && 'REQ'].filter(Boolean).join(' ') }
];

export default function WorkQueuePage() {
  const { labId, masterData } = useWorkbench();
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const [queues, setQueues] = useState([]);
  const [data, setData] = useState({ items: [], totalCount: 0 });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [searchText, setSearchText] = useState(params.get('q') || '');

  const filter = useMemo(() => ({
    labId,
    queueId: params.get('queue') || '',
    subQueueId: params.get('sub') || '',
    workflowStatus: params.get('status') || '',
    denialCategory: params.get('category') || '',
    search: params.get('q') || '',
    openInsuranceArOnly: params.get('open') === '1',
    sortBy: params.get('sort') || 'remainingAR',
    sortDesc: params.get('dir') !== 'asc',
    page: Number(params.get('page')) || 1,
    pageSize: PAGE_SIZE
  }), [labId, params]);

  function update(changes, resetPage = true) {
    const next = new URLSearchParams(params);
    Object.entries(changes).forEach(([k, v]) => { if (v === '' || v === null || v === undefined) next.delete(k); else next.set(k, v); });
    if (resetPage) next.delete('page');
    setParams(next, { replace: true });
  }

  useEffect(() => {
    const controller = new AbortController();
    arWorkbenchService.queues(labId, controller.signal).then((s) => setQueues(s.queues)).catch(() => {});
    return () => controller.abort();
  }, [labId]);

  useEffect(() => {
    const controller = new AbortController();
    setLoading(true);
    setError('');
    arWorkbenchService.claims(filter, controller.signal)
      .then((result) => { setData(result); setLoading(false); })
      .catch((e) => { if (e.name !== 'AbortError') { setError(e.message); setLoading(false); } });
    return () => controller.abort();
  }, [filter]);

  // Debounced search, so typing does not fire a query per keystroke.
  useEffect(() => {
    const t = setTimeout(() => { if (searchText !== (params.get('q') || '')) update({ q: searchText.trim() }); }, 400);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchText]);

  const selectedQueue = queues.find((q) => q.queueId === filter.queueId);
  const statuses = masterData?.lists?.WORKFLOW_STATUS || [];
  const categories = masterData?.lists?.DENIAL_CATEGORY || [];

  return (
    <>
      <PageHeader title="Work Queue" subtitle="Every denied claim in your scope" />

      <div className="arwb-filters">
        <div>
          <label className="form-label small text-secondary mb-1" htmlFor="f-queue">AR queue</label>
          <select id="f-queue" className="form-select form-select-sm" value={filter.queueId} onChange={(e) => update({ queue: e.target.value, sub: '' })}>
            <option value="">All queues</option>
            {queues.map((q) => <option key={q.queueId} value={q.queueId}>{q.label} ({fmt.count(q.claimCount)})</option>)}
          </select>
        </div>
        {selectedQueue?.sub?.length > 0 && (
          <div>
            <label className="form-label small text-secondary mb-1" htmlFor="f-sub">Sub-queue</label>
            <select id="f-sub" className="form-select form-select-sm" value={filter.subQueueId} onChange={(e) => update({ sub: e.target.value })}>
              <option value="">All</option>
              {selectedQueue.sub.map((s) => <option key={s.queueId} value={s.queueId}>{s.label} ({fmt.count(s.claimCount)})</option>)}
            </select>
          </div>
        )}
        <div>
          <label className="form-label small text-secondary mb-1" htmlFor="f-status">Status</label>
          <select id="f-status" className="form-select form-select-sm" value={filter.workflowStatus} onChange={(e) => update({ status: e.target.value })}>
            <option value="">All statuses</option>
            {statuses.map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
        </div>
        <div>
          <label className="form-label small text-secondary mb-1" htmlFor="f-cat">Denial category</label>
          <select id="f-cat" className="form-select form-select-sm" value={filter.denialCategory} onChange={(e) => update({ category: e.target.value })}>
            <option value="">All categories</option>
            {categories.map((c) => <option key={c} value={c}>{c}</option>)}
          </select>
        </div>
        <div className="arwb-filter-grow">
          <label className="form-label small text-secondary mb-1" htmlFor="f-q">Search</label>
          <input id="f-q" className="form-control form-control-sm" placeholder="Claim ID, patient, accession, denial code" value={searchText} onChange={(e) => setSearchText(e.target.value)} maxLength={200} />
        </div>
        <div className="form-check align-self-end mb-1">
          <input id="f-open" type="checkbox" className="form-check-input" checked={filter.openInsuranceArOnly} onChange={(e) => update({ open: e.target.checked ? '1' : '' })} />
          <label className="form-check-label small" htmlFor="f-open">Open insurance AR only</label>
        </div>
      </div>

      <ErrorBox message={error} />

      <DataTable
        tableId="workqueue"
        exportName="ar_workbench_work_queue"
        columns={COLUMNS}
        rows={data.items}
        totalCount={data.totalCount}
        page={filter.page}
        pageSize={PAGE_SIZE}
        sortBy={filter.sortBy}
        sortDesc={filter.sortDesc}
        loading={loading}
        onSort={(sort, desc) => update({ sort, dir: desc ? '' : 'asc' })}
        onPage={(page) => update({ page: page > 1 ? String(page) : '' }, false)}
        onRowClick={(row) => navigate(`/claims/${row.claimKey}`, { state: { from: `/work-queue?${params}` } })}
      />
    </>
  );
}
