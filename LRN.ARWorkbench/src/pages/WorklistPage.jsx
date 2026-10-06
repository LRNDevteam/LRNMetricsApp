import { useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router';
import DataTable from '../components/DataTable';
import BulkUpdateModal from '../components/BulkUpdateModal';
import FollowUpModal from '../components/FollowUpModal';
import Icon from '../components/Icon';
import MultiSelect from '../components/MultiSelect';
import SavedViews from '../components/SavedViews';
import { AgentName, ErrorBox, Notice, PriorityText, QueueBadge, StatusBadge, TflBadge } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

// My Work (mockup App.views.mywork) and Follow-Up Management (App.views.followup) - one component,
// two views. Both are the server-side claims query with a base filter; the tiles are one-click
// quick filters whose counts come from GET work-summary (same rules as the list behind them).
//   mywork   : every assigned claim - an agent's own caseload (scope is enforced in SQL), a lead's team
//   followup : claims waiting on the next touch (IsFollowUpActionable): assigned / reassigned,
//              QA-rejected or returned with a CIP response, still owed. Logging a note drops it off.

const MY_WORK_TILES = [
  ['all', 'Total Assigned', 'totalAssigned', {}],
  ['dueToday', 'Due Today', 'dueToday', { followUpWindow: 'today' }],
  ['overdue', 'Overdue', 'overdue', { followUpWindow: 'overdue', activeOnly: true }],
  ['highPriority', 'High Priority', 'highPriority', { priority: ['High'], activeOnly: true }],
  ['refollowup', 'Re-follow-up Required', 'refollowupRequired', { queue: ['refollowup'] }],
  ['cipResponse', 'CIP Response Received', 'cipResponseReceived', { queue: ['cipresponse'] }],
  ['awaitingPayer', 'Awaiting Payer Response', 'awaitingPayer', { awaitingPayerOnly: true, activeOnly: true }],
  ['submittedQA', 'Submitted for QA', 'submittedForQa', { status: ['Submitted for QA'] }],
  ['rejectedQA', 'Rejected QA Items', 'qaRejected', { status: ['QA Rejected'] }]
];

const FOLLOW_UP_TILES = [
  ['all', 'All Active', 'actionableAll', {}],
  ['overdue', 'Overdue', 'actionableOverdue', { followUpWindow: 'overdue' }],
  ['today', 'Due Today', 'actionableDueToday', { followUpWindow: 'today' }],
  ['upcoming', 'Upcoming', 'actionableUpcoming', { followUpWindow: 'upcoming' }],
  ['none', 'No Follow-Up Scheduled', 'actionableNoFollowUp', { followUpWindow: 'none' }]
];

const CONFIG = {
  mywork: {
    base: { assignedOnly: true },
    tiles: MY_WORK_TILES,
    title: 'Your Queue',
    exportName: 'my-work-queue',
    filters: [['payer', 'Payer', 'payers'], ['panel', 'Panel Type', 'panels'], ['category', 'Denial Category', 'categories'],
      ['priority', 'Priority', 'priorities'], ['status', 'Status', 'statuses']],
    more: [['sourceStatus', 'Claim Status', 'sourceStatuses'], ['fixResolution', 'Fix / Resolution', 'fixResolutions'], ['agent', 'Assigned Agent', 'agents']],
    note: null
  },
  followup: {
    base: { followUpActionableOnly: true },
    tiles: FOLLOW_UP_TILES,
    title: 'Follow-Up Schedule',
    exportName: 'followup-schedule',
    filters: [['payer', 'Payer', 'payers'], ['panel', 'Panel Type', 'panels'], ['category', 'Denial Category', 'categories'],
      ['priority', 'Priority', 'priorities'], ['aging', 'AR Aging', 'agingBuckets']],
    more: [['agent', 'Assigned Agent', 'agents'], ['status', 'Workflow Status', 'statuses'], ['sourceStatus', 'Claim Status', 'sourceStatuses'],
      ['fixResolution', 'Fix / Resolution', 'fixResolutions']],
    note: 'Showing claims waiting on your next touch — newly assigned or reassigned, QA-rejected, or returned with a CIP client response. Log a follow-up and it moves off this list (it stays visible in My Work).'
  }
};

const BLANK = { payer: [], panel: [], category: [], priority: [], status: [], aging: [], sourceStatus: [], fixResolution: [], agent: [] };

function NextFollowUp({ date, withDays }) {
  if (!date) return <span className="text-muted-ink">{withDays ? 'Not scheduled' : '—'}</span>;
  const d = fmt.daysUntil(date);
  const cls = d < 0 ? 'text-critical' : d <= (withDays ? 0 : 2) ? 'text-warning-ink' : '';
  return <span className={cls}>{fmt.date(date)}{withDays && (d < 0 ? ` (${Math.abs(d)}d overdue)` : d === 0 ? ' (today)' : '')}</span>;
}

export default function WorklistPage({ view = 'mywork' }) {
  const cfg = CONFIG[view];
  const { labId, can, user } = useWorkbench();
  const navigate = useNavigate();
  const [summary, setSummary] = useState(null);
  const [options, setOptions] = useState(null);
  const [quick, setQuick] = useState('all');
  const [lists, setLists] = useState(BLANK);
  const [tflOnly, setTflOnly] = useState(false);
  const [moreOpen, setMoreOpen] = useState(false);
  const [searchText, setSearchText] = useState('');
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState({ page: 1, pageSize: 25, sortBy: 'nextFollowUpDate', sortDesc: false });
  const [data, setData] = useState({ items: [], totalCount: 0 });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState(null);
  const [logging, setLogging] = useState(null);
  const [reloadKey, setReloadKey] = useState(0);
  const [bulkOpen, setBulkOpen] = useState(false);       // Bulk Update (Excel)

  // An agent's caseload is theirs by scope, so the agent filter is for leads and above.
  const moreFilters = cfg.more.filter(([k]) => k !== 'agent' || user?.roleCode !== 'agent');

  useEffect(() => {
    const t = setTimeout(() => { if (searchText.trim() !== search) { setSearch(searchText.trim()); setQuery((q) => ({ ...q, page: 1 })); } }, 400);
    return () => clearTimeout(t);
  }, [searchText]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    arWorkbenchService.workSummary(labId).then(setSummary).catch(() => {});
  }, [labId, reloadKey]);

  // Base filter + the tile's filter + the filter bar. A tile's list wins over the same bar filter.
  const filter = useMemo(() => {
    const tile = cfg.tiles.find(([id]) => id === quick)?.[3] || {};
    return {
      labId, ...cfg.base, ...lists, ...tile,
      tflRiskOnly: tflOnly, search,
      sortBy: query.sortBy, sortDesc: query.sortDesc, page: query.page, pageSize: query.pageSize
    };
  }, [cfg, labId, lists, quick, tflOnly, search, query]);

  // Cascading filter lists (T047): each list counted over the view's other filters (tile included).
  const optionsKey = JSON.stringify({ ...filter, page: 0, pageSize: 0, sortBy: '', sortDesc: false });
  useEffect(() => {
    const controller = new AbortController();
    const t = setTimeout(() => {
      arWorkbenchService.claimFilterOptions(labId, controller.signal, filter).then(setOptions).catch(() => {});
    }, 250);
    return () => { clearTimeout(t); controller.abort(); };
  }, [labId, optionsKey, reloadKey]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    const controller = new AbortController();
    setLoading(true);
    setError('');
    arWorkbenchService.claims(filter, controller.signal)
      .then((r) => { setData(r); setLoading(false); })
      .catch((e) => { if (e.name !== 'AbortError') { setError(e.message); setLoading(false); } });
    return () => controller.abort();
  }, [filter, reloadKey]);

  const setList = (k, v) => { setLists((l) => ({ ...l, [k]: v })); setQuery((q) => ({ ...q, page: 1 })); };
  const clear = () => { setLists(BLANK); setTflOnly(false); setSearchText(''); setSearch(''); setQuick('all'); setQuery((q) => ({ ...q, page: 1 })); };
  const pickTile = (id) => { setQuick(id); setQuery((q) => ({ ...q, page: 1 })); };

  // Saved Views: the tile, the filter bar and the search box.
  const viewState = () => ({ quick, lists, tflOnly, search });
  const applyView = (v) => {
    setQuick(cfg.tiles.some(([id]) => id === v.quick) ? v.quick : 'all');
    setLists({ ...BLANK, ...(v.lists || {}) });
    setTflOnly(Boolean(v.tflOnly));
    setSearchText(v.search || '');
    setSearch(v.search || '');
    setQuery((q) => ({ ...q, page: 1 }));
  };

  const openClaim = (row) => navigate(`/claims/${row.claimKey}`, { state: { from: view === 'mywork' ? '/my-work' : '/follow-up' } });
  const canLogRow = (r) => can('editClaim') && r.workflowStatus !== 'Submitted for QA';
  const startLog = (r) => setLogging({ ClaimKey: r.claimKey, ClaimID: r.claimID, LabName: r.labName, PayerName: r.payerName, FixResolution: r.fixResolution });

  const onLogged = useCallback((result) => {
    setLogging(null);
    setNotice({ kind: 'good', text: result?.message || 'Follow-up logged and sent to QA.' });
    setReloadKey((k) => k + 1);
  }, []);

  const columns = [
    { key: 'claimID', label: 'Claim ID', sortKey: 'claimId',
      render: (r) => <button type="button" className="arwb-claim-link" onClick={(e) => { e.stopPropagation(); openClaim(r); }}>{r.claimID}</button> },
    { key: 'labName', label: 'Client', render: (r) => r.labName || '—' },
    { key: 'payerName', label: 'Payer', sortKey: 'payerName', wrap: true },
    { key: 'panelName', label: 'Panel Type', sortKey: 'panelName' },
    { key: 'denialCategory', label: 'Denial Category', sortKey: 'denialCategory', wrap: true },
    { key: 'insuranceBalance', label: 'Ins. Balance', align: 'end', sortKey: 'insuranceBalance',
      render: (r) => <span className="mono">{fmt.money(r.insuranceBalance)}</span>, csv: (r) => r.insuranceBalance },
    { key: 'priority', label: 'Priority', sortKey: 'priority', render: (r) => <PriorityText priority={r.priority} /> },
    ...(view === 'followup' ? [
      { key: 'agingBucket', label: 'Aging', sortKey: 'agingDays', defaultHidden: true, render: (r) => r.agingBucket || '—' },
      { key: 'assignedAgentName', label: 'Agent', render: (r) => <AgentName name={r.assignedAgentName || r.assignedAgentUser} />,
        csv: (r) => r.assignedAgentName || r.assignedAgentUser || '' }
    ] : []),
    { key: 'workflowStatus', label: 'Status', sortKey: 'workflowStatus', render: (r) => <StatusBadge status={r.workflowStatus} nonCollectible={r.hasNonCollectibleDenial} />,
      csv: (r) => r.workflowStatus + (r.hasNonCollectibleDenial ? ' (Non-Collectible)' : '') },
    { key: 'fixResolution', label: 'Fix / Resolution', wrap: true, defaultHidden: true, render: (r) => r.fixResolution || '—' },
    ...(view === 'mywork' ? [
      { key: 'queue', label: 'AR Queue', render: (r) => <QueueBadge queueId={r.arQueueId} label={r.arQueueLabel} subLabel={r.arSubQueueLabel} />,
        csv: (r) => [r.arQueueLabel, r.arSubQueueLabel].filter(Boolean).join(' · ') },
      { key: 'isTflRisk', label: 'TFL', defaultHidden: true, render: (r) => <TflBadge atRisk={r.isTflRisk} />, csv: (r) => (r.isTflRisk ? 'At Risk' : 'OK') }
    ] : [
      { key: 'lastFollowUpDate', label: 'Last Follow-Up', sortKey: 'lastFollowUpDate', render: (r) => fmt.date(r.lastFollowUpDate), csv: (r) => fmt.date(r.lastFollowUpDate) }
    ]),
    { key: 'nextFollowUpDate', label: 'Next Follow-Up', sortKey: 'nextFollowUpDate',
      render: (r) => <NextFollowUp date={r.nextFollowUpDate} withDays={view === 'followup'} />, csv: (r) => fmt.date(r.nextFollowUpDate) },
    { key: 'action', label: 'Action', align: 'end', csv: () => '',
      render: (r) => (canLogRow(r)
        ? <button type="button" className={`arwb-btn arwb-btn-sm${view === 'followup' ? ' arwb-btn-primary' : ''}`} onClick={(e) => { e.stopPropagation(); startLog(r); }}>Log Follow-Up</button>
        : <span className="text-muted-ink">—</span>) }
  ];

  return (
    <>
      <div className="arwb-grid arwb-grid-kpi arwb-section">
        {cfg.tiles.map(([id, label, key]) => (
          <button key={id} type="button" className={`arwb-kpi arwb-kpi-tile arwb-kpi-tile-btn${quick === id ? ' active' : ''}`}
            aria-pressed={quick === id} onClick={() => pickTile(id)}>
            <span className="arwb-kpi-accent-bar" />
            <span className="arwb-kpi-label">{label}</span>
            <span className="arwb-kpi-value mono">{summary ? fmt.count(summary[key]) : '…'}</span>
          </button>
        ))}
      </div>

      {cfg.note && <div className="arwb-section-note" style={{ marginBottom: 14 }}>{cfg.note}</div>}
      <Notice notice={notice} onClose={() => setNotice(null)} />

      <div className="arwb-panel arwb-filter-card arwb-section">
        <div className="arwb-filter-bar">
          <div className="arwb-field grow">
            <label htmlFor={`${view}-search`}>Search</label>
            <input id={`${view}-search`} type="search" className="arwb-input" maxLength={200} placeholder="Claim ID, patient acct, provider…"
              value={searchText} onChange={(e) => setSearchText(e.target.value)} />
          </div>
          {cfg.filters.map(([k, label, optKey]) => (
            <MultiSelect key={k} id={`${view}-${k}`} label={label} options={options?.[optKey] || []} selected={lists[k]} onChange={(v) => setList(k, v)} />
          ))}
          <div className="arwb-checkbox-row">
            <input id={`${view}-tfl`} type="checkbox" checked={tflOnly} onChange={(e) => { setTflOnly(e.target.checked); setQuery((q) => ({ ...q, page: 1 })); }} />
            <label htmlFor={`${view}-tfl`}>TFL risk only</label>
          </div>
          <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => setMoreOpen((v) => !v)}>{moreOpen ? 'Fewer filters' : 'More filters'}</button>
          <SavedViews viewKey={view} getState={viewState} onApply={applyView} />
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={clear}>Clear Filters</button>
        </div>
        {moreOpen && (
          <div className="arwb-filter-bar" style={{ borderTop: '1px solid var(--border-soft)' }}>
            {moreFilters.map(([k, label, optKey]) => (
              <MultiSelect key={k} id={`${view}-${k}`} label={label}
                options={(options?.[optKey] || []).filter((o) => k !== 'agent' || o.value !== '__unassigned')}
                selected={lists[k]} onChange={(v) => setList(k, v)} />
            ))}
          </div>
        )}
      </div>

      <ErrorBox message={error} />

      <div className="arwb-card arwb-card-flush">
        <div className="arwb-card-head"><h3>{cfg.title}</h3><span className="arwb-card-sub">{loading ? '' : `${fmt.count(data.totalCount)} claim${data.totalCount === 1 ? '' : 's'}`}</span></div>
        <DataTable
          tableId={`${view}-v1`}
          exportName={cfg.exportName}
          columns={columns}
          rows={data.items || []}
          totalCount={data.totalCount}
          page={query.page}
          pageSize={query.pageSize}
          sortBy={query.sortBy}
          sortDesc={query.sortDesc}
          loading={loading}
          emptyText={view === 'followup' ? 'Nothing is waiting on a follow-up in this view.' : 'No assigned claims match this view.'}
          onSort={(sortBy, sortDesc) => setQuery((q) => ({ ...q, sortBy, sortDesc, page: 1 }))}
          onPage={(page) => setQuery((q) => ({ ...q, page }))}
          onPageSize={(pageSize) => setQuery((q) => ({ ...q, pageSize, page: 1 }))}
          onRowClick={openClaim}
          toolbar={(can('assign') || can('editClaim')) && (
            <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => setBulkOpen(true)}
              title="Log follow-ups (and assign) for many claims from an Excel file - the template lists this view's claims">
              <Icon name="upload" size={15} /> Bulk Update (Excel)
            </button>
          )}
        />
      </div>

      {bulkOpen && (
        <BulkUpdateModal filter={filter} onClose={() => setBulkOpen(false)}
          onDone={() => { setBulkOpen(false); setNotice({ kind: 'good', text: 'Bulk update finished - the list is refreshed.' }); setReloadKey((k) => k + 1); }} />
      )}
      {logging && <FollowUpModal claim={logging} lastFollowUp={null} onClose={() => setLogging(null)} onDone={onLogged} />}
    </>
  );
}

export function MyWorkPage() { return <WorklistPage view="mywork" />; }
export function FollowUpPage() { return <WorklistPage view="followup" />; }
