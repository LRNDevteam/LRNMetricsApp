import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import AssignModal from '../components/AssignModal';
import DataTable from '../components/DataTable';
import MultiSelect from '../components/MultiSelect';
import { AgentName, ErrorBox, Notice, PriorityText, QueueBadge, StatusBadge, TflBadge } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

const DEFAULT_PAGE_SIZE = 25;

// Multi-select filters: URL key -> API filter key, label, filter-options list. Each value is its
// own URL entry (?payer=A&payer=B), so a filtered view can be bookmarked or shared.
const LIST_FILTERS = [
  { param: 'clinic', api: 'clinic', label: 'Clinic', options: 'clinics' },
  { param: 'payer', api: 'payer', label: 'Payer', options: 'payers' },
  { param: 'panel', api: 'panel', label: 'Panel Type', options: 'panels' },
  { param: 'category', api: 'category', label: 'Denial Category', options: 'categories' },
  { param: 'status', api: 'status', label: 'Workflow Status', options: 'statuses' },
  { param: 'agent', api: 'agent', label: 'Assigned Agent', options: 'agents' },
  { param: 'priority', api: 'priority', label: 'Priority', options: 'priorities' },
  { param: 'aging', api: 'aging', label: 'AR Aging', options: 'agingBuckets' },
  { param: 'queue', api: 'queue', label: 'AR Queue', options: 'queues' }
];

function NextFollowUp({ date }) {
  if (!date) return '—';
  const days = fmt.daysUntil(date);
  const cls = days < 0 ? 'text-critical' : days <= 2 ? 'text-warning-ink' : '';
  return <span className={cls}>{fmt.date(date)}</span>;
}

// The mockup's Work Queue columns (handoff FR-WQ-05); * = hidden by default.
function buildColumns(openClaim) {
  return [
    { key: 'claimID', label: 'Claim ID', sortKey: 'claimId',
      render: (r) => <button type="button" className="arwb-claim-link" onClick={(e) => { e.stopPropagation(); openClaim(r); }}>{r.claimID}</button> },
    { key: 'labName', label: 'Client', render: (r) => r.labName || '—' },
    { key: 'patientID', label: 'Patient Acct', sortKey: 'patientId', render: (r) => <span className="mono">{r.patientID || '—'}</span> },
    { key: 'dateOfService', label: 'DOS', sortKey: 'dateOfService', render: (r) => fmt.date(r.dateOfService), csv: (r) => fmt.date(r.dateOfService) },
    { key: 'payerName', label: 'Payer', sortKey: 'payerName', wrap: true },
    { key: 'panelName', label: 'Panel Type', sortKey: 'panelName' },
    { key: 'cpt', label: 'CPT', render: (r) => (r.firstCptCode ? `${r.firstCptCode}${r.lineCount > 1 ? ` +${r.lineCount - 1}` : ''}` : '—'),
      csv: (r) => (r.firstCptCode ? `${r.firstCptCode}${r.lineCount > 1 ? ` +${r.lineCount - 1}` : ''}` : '') },
    { key: 'denialCode', label: 'Denial Code', render: (r) => (r.denialCode ? <span className="mono">{r.denialCode}</span> : '—'), csv: (r) => r.denialCode || '' },
    { key: 'denialCategory', label: 'Denial Category', sortKey: 'denialCategory', wrap: true },
    { key: 'denialReason', label: 'Denial Reason', wrap: true, defaultHidden: true },
    { key: 'sourceClaimStatus', label: 'Claim Status', defaultHidden: true },
    { key: 'insuranceBalance', label: 'Ins. Balance', align: 'end', sortKey: 'insuranceBalance',
      render: (r) => <span className="mono">{fmt.money(r.insuranceBalance)}</span>, csv: (r) => r.insuranceBalance },
    { key: 'agingBucket', label: 'Aging', sortKey: 'agingDays', render: (r) => r.agingBucket || '—' },
    { key: 'isTflRisk', label: 'TFL', render: (r) => <TflBadge atRisk={r.isTflRisk} />, csv: (r) => (r.isTflRisk ? 'At Risk' : 'OK') },
    { key: 'priority', label: 'Priority', sortKey: 'priority', render: (r) => <PriorityText priority={r.priority} /> },
    { key: 'assignedAgentName', label: 'Assigned Agent', render: (r) => <AgentName name={r.assignedAgentName || r.assignedAgentUser} />,
      csv: (r) => r.assignedAgentName || r.assignedAgentUser || '' },
    { key: 'workflowStatus', label: 'Workflow Status', sortKey: 'workflowStatus', render: (r) => <StatusBadge status={r.workflowStatus} /> },
    { key: 'queue', label: 'AR Queue', render: (r) => <QueueBadge queueId={r.arQueueId} label={r.arQueueLabel} subLabel={r.arSubQueueLabel} />,
      csv: (r) => [r.arQueueLabel, r.arSubQueueLabel].filter(Boolean).join(' · ') },
    { key: 'fixResolution', label: 'Fix / Resolution', wrap: true, defaultHidden: true },
    { key: 'recoveredAmount', label: 'Recovered', align: 'end', sortKey: 'recoveredAmount', defaultHidden: true,
      render: (r) => <span className="mono">{fmt.money(r.recoveredAmount)}</span>, csv: (r) => r.recoveredAmount },
    { key: 'remainingAR', label: 'Remaining AR', align: 'end', sortKey: 'remainingAR', defaultHidden: true,
      render: (r) => <span className="mono">{fmt.money(r.remainingAR)}</span>, csv: (r) => r.remainingAR },
    { key: 'lastFollowUpDate', label: 'Last Follow-Up', sortKey: 'lastFollowUpDate', render: (r) => fmt.date(r.lastFollowUpDate), csv: (r) => fmt.date(r.lastFollowUpDate) },
    { key: 'nextFollowUpDate', label: 'Next Follow-Up', sortKey: 'nextFollowUpDate', render: (r) => <NextFollowUp date={r.nextFollowUpDate} />,
      csv: (r) => fmt.date(r.nextFollowUpDate) },
    { key: 'action', label: 'Action', align: 'end', csv: () => '',
      render: (r) => <button type="button" className="arwb-btn arwb-btn-sm" onClick={(e) => { e.stopPropagation(); openClaim(r); }}>Open</button> }
  ];
}

export default function WorkQueuePage() {
  const { labId, can } = useWorkbench();
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const [options, setOptions] = useState(null);
  const [data, setData] = useState({ items: [], totalCount: 0 });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  // Assign / reassign from the queue (System Administrator, RCM Manager, Team Lead).
  const canAssign = can('assign');
  const [selected, setSelected] = useState(() => new Set());
  const [assigning, setAssigning] = useState(false);
  const [notice, setNotice] = useState(null);
  const [reloadKey, setReloadKey] = useState(0);
  const [searchText, setSearchText] = useState(params.get('q') || '');

  const pageSize = Number(params.get('size')) || DEFAULT_PAGE_SIZE;
  const filter = useMemo(() => {
    const f = {
      labId,
      search: params.get('q') || '',
      openInsuranceArOnly: params.get('open') === '1',
      tflRiskOnly: params.get('tfl') === '1',
      sortBy: params.get('sort') || 'remainingAR',
      sortDesc: params.get('dir') !== 'asc',
      page: Number(params.get('page')) || 1,
      pageSize
    };
    LIST_FILTERS.forEach((lf) => { f[lf.api] = params.getAll(lf.param); });
    return f;
  }, [labId, params, pageSize]);

  function update(changes, resetPage = true) {
    const next = new URLSearchParams(params);
    Object.entries(changes).forEach(([k, v]) => {
      next.delete(k);
      if (Array.isArray(v)) v.forEach((x) => next.append(k, x));
      else if (v !== '' && v !== null && v !== undefined) next.set(k, v);
    });
    if (resetPage) next.delete('page');
    setParams(next, { replace: true });
  }

  function clearFilters() {
    const next = new URLSearchParams();
    ['sort', 'dir', 'size'].forEach((k) => { if (params.get(k)) next.set(k, params.get(k)); });
    setSearchText('');
    setParams(next, { replace: true });
  }

  useEffect(() => {
    const controller = new AbortController();
    arWorkbenchService.claimFilterOptions(labId, controller.signal)
      .then(setOptions)
      .catch((e) => { if (e.name !== 'AbortError') setError(e.message); });
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
  }, [filter, reloadKey]);

  // A selection belongs to one set of filters: changing them starts over.
  const filterKey = JSON.stringify({ ...filter, page: 0, sortBy: '', sortDesc: false, pageSize: 0 });
  useEffect(() => { setSelected(new Set()); }, [filterKey]);

  // Debounced search, so typing does not fire a query per keystroke.
  useEffect(() => {
    const t = setTimeout(() => { if (searchText.trim() !== (params.get('q') || '')) update({ q: searchText.trim() }); }, 400);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchText]);

  const openClaim = (row) => navigate(`/claims/${row.claimKey}`, { state: { from: `/work-queue?${params}` } });
  const columns = useMemo(() => buildColumns(openClaim), [params]); // eslint-disable-line react-hooks/exhaustive-deps

  const activeChips = LIST_FILTERS.flatMap((lf) => params.getAll(lf.param).map((v) => {
    const label = options?.[lf.options]?.find((o) => o.value === v)?.label ?? v;
    return { key: `${lf.param}:${v}`, text: `${lf.label}: ${label}`, remove: () => update({ [lf.param]: params.getAll(lf.param).filter((x) => x !== v) }) };
  }));

  return (
    <>
      <div className="arwb-panel arwb-filter-card">
        <div className="arwb-filter-bar">
          <div className="arwb-field grow">
            <label htmlFor="wq-search">Search</label>
            <input id="wq-search" type="search" className="arwb-input" placeholder="Claim ID, patient acct, provider, denial code…"
              value={searchText} maxLength={200} onChange={(e) => setSearchText(e.target.value)} />
          </div>
          {LIST_FILTERS.map((lf) => (
            <MultiSelect key={lf.param} id={lf.param} label={lf.label}
              options={options?.[lf.options] || []}
              selected={filter[lf.api]}
              onChange={(values) => update({ [lf.param]: values })} />
          ))}
          <div className="arwb-checkbox-row">
            <input id="wq-tfl" type="checkbox" checked={filter.tflRiskOnly} onChange={(e) => update({ tfl: e.target.checked ? '1' : '' })} />
            <label htmlFor="wq-tfl">TFL risk only</label>
          </div>
          <div className="arwb-checkbox-row">
            <input id="wq-open" type="checkbox" checked={filter.openInsuranceArOnly} onChange={(e) => update({ open: e.target.checked ? '1' : '' })} />
            <label htmlFor="wq-open">Open insurance AR only</label>
          </div>
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={clearFilters}>Clear Filters</button>
        </div>
        {activeChips.length > 0 && (
          <div className="arwb-filter-chip-row">
            {activeChips.map((c) => (
              <span key={c.key} className="arwb-filter-chip">{c.text}<button type="button" aria-label={`Remove ${c.text}`} onClick={c.remove}>×</button></span>
            ))}
          </div>
        )}
      </div>

      <ErrorBox message={error} />
      <Notice notice={notice} onClose={() => setNotice(null)} />

      <DataTable
        tableId="workqueue-v2"
        exportName="denial-ar-work-queue"
        columns={columns}
        rows={data.items}
        totalCount={data.totalCount}
        page={filter.page}
        pageSize={pageSize}
        sortBy={filter.sortBy}
        sortDesc={filter.sortDesc}
        loading={loading}
        onSort={(sort, desc) => update({ sort, dir: desc ? '' : 'asc' })}
        onPage={(page) => update({ page: page > 1 ? String(page) : '' }, false)}
        onPageSize={(size) => update({ size: size === DEFAULT_PAGE_SIZE ? '' : String(size) })}
        onRowClick={openClaim}
        selectable={canAssign}
        selectedKeys={selected}
        onSelectionChange={setSelected}
        toolbar={canAssign && (
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!selected.size} onClick={() => setAssigning(true)}>
            Assign Selected{selected.size ? ` (${fmt.count(selected.size)})` : ''} →
          </button>
        )}
      />

      {assigning && (
        <AssignModal labId={labId} claimKeys={[...selected]} onClose={() => setAssigning(false)}
          onDone={(result) => {
            setAssigning(false);
            setSelected(new Set());
            setNotice({ kind: 'good', text: result?.message || 'Assigned.' });
            setReloadKey((k) => k + 1);
          }} />
      )}
    </>
  );
}
