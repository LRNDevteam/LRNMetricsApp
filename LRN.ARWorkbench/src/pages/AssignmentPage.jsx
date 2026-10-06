import { useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router';
import AssignModal from '../components/AssignModal';
import { BarList } from '../components/Charts';
import DataTable from '../components/DataTable';
import Icon from '../components/Icon';
import Modal from '../components/Modal';
import MultiSelect from '../components/MultiSelect';
import { AgentName, Badge, ErrorBox, Loading, Notice, PriorityText, StatusBadge } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

// Assignment Management, laid out as the mockup's App.views.assignment:
//   Agent Workload | Create Assignment Batch
//   Assignment Batches
//   Unassigned Claims (open balance, untouched 45+ days) -> Assign Selected
//   Assigned Claims - Bulk Reassign -> Reassign Selected
// Every rule (the pool, status moves, ad-hoc assignment, resolving reassignment requests, scope)
// lives in the API (SqlArWorkbenchRepository.Assignment.cs); this screen only collects choices.

const BLANK_CRITERIA = { category: [], payer: [], panel: [], priority: [] };
const CRITERIA_FIELDS = [
  ['category', 'Denial Category', 'categories'],
  ['payer', 'Payer', 'payers'],
  ['panel', 'Panel Type', 'panels'],
  ['priority', 'Priority', 'priorities']
];
const BLANK_REASSIGN = { agent: [], category: [], panel: [], priority: [] };
const REASSIGN_FIELDS = [
  ['agent', 'Current Agent', 'agents'],
  ['category', 'Denial Category', 'categories'],
  ['panel', 'Panel Type', 'panels'],
  ['priority', 'Priority', 'priorities']
];

const hasCriteria = (c) => CRITERIA_FIELDS.some(([k]) => c[k].length > 0);
const today = () => new Date().toISOString().slice(0, 10);

// The mockup's Category column: one category, "n categories", or "All Categories".
function categoryLabel(b) {
  const c = b.criteria?.category || [];
  if (c.length === 1) return c[0] === '__none' ? '(No denial)' : c[0];
  return c.length ? `${c.length} categories` : 'All Categories';
}

function Progress({ pct }) {
  return (
    <span className="arwb-progress" title={`${pct}% complete`}>
      <span className="arwb-progress-track"><span className="arwb-progress-fill" style={{ width: `${pct}%` }} /></span>
      <span className="mono">{pct}%</span>
    </span>
  );
}

function batchBadge(b) {
  if (b.batchStatus === 'Cancelled') return <Badge className="arwb-badge-neutral">Cancelled</Badge>;
  if (b.batchStatus === 'Completed') return <Badge className="arwb-badge-good">Complete</Badge>;
  return b.isOverdue ? <Badge className="arwb-badge-critical">Overdue</Badge> : <Badge className="arwb-badge-info">Open</Badge>;
}

export default function AssignmentPage() {
  const { labId, lab } = useWorkbench();
  const navigate = useNavigate();
  const [overview, setOverview] = useState(null);
  const [options, setOptions] = useState(null);           // Work Queue filter options (reassign filters)
  const [notice, setNotice] = useState(null);
  const [error, setError] = useState('');
  const [refreshKey, setRefreshKey] = useState(0);
  const refresh = () => setRefreshKey((k) => k + 1);

  useEffect(() => {
    const controller = new AbortController();
    arWorkbenchService.assignmentOverview(labId, controller.signal)
      .then(setOverview)
      .catch((e) => { if (e.name !== 'AbortError') setError(e.message || 'Assignment Management could not be loaded.'); });
    return () => controller.abort();
  }, [labId, refreshKey]);

  useEffect(() => {
    const controller = new AbortController();
    arWorkbenchService.claimFilterOptions(labId, controller.signal).then(setOptions).catch(() => {});
    return () => controller.abort();
  }, [labId, refreshKey]);

  const agents = overview?.agents || [];
  const assignable = agents.filter((a) => a.isAssignable);
  const untouchedDays = overview?.untouchedDays || 45;
  const clientName = lab?.labName || '—';

  // ---- Create Assignment Batch -----------------------------------------------------------------
  const [criteria, setCriteria] = useState(BLANK_CRITERIA);
  const [preview, setPreview] = useState(null);
  const [agentUser, setAgentUser] = useState('');
  const [dueDate, setDueDate] = useState('');
  const [creating, setCreating] = useState(false);
  const [batchError, setBatchError] = useState('');

  // The mockup preselects the first agent.
  useEffect(() => { if (!agentUser && assignable.length) setAgentUser(assignable[0].userName); }, [assignable, agentUser]);

  useEffect(() => {
    if (!hasCriteria(criteria)) { setPreview(null); return undefined; }
    const controller = new AbortController();
    const t = setTimeout(() => {
      arWorkbenchService.previewBatch(labId, criteria, controller.signal)
        .then(setPreview)
        .catch((e) => { if (e.name !== 'AbortError') setBatchError(e.message); });
    }, 250);
    return () => { clearTimeout(t); controller.abort(); };
  }, [labId, criteria, refreshKey]);

  async function createBatch() {
    setBatchError('');
    setCreating(true);
    try {
      const result = await arWorkbenchService.createBatch(labId, { criteria, agentUser, dueDate: dueDate || null });
      setNotice({ kind: 'good', text: result?.message || 'Batch created.' });
      refresh();
    } catch (e) {
      setBatchError(e.message || 'The batch could not be created.');
    } finally {
      setCreating(false);
    }
  }

  // ---- Assignment Batches ----------------------------------------------------------------------
  const [batches, setBatches] = useState(null);
  const [detail, setDetail] = useState(null);
  const [cancelling, setCancelling] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    arWorkbenchService.batches(labId, 'all', controller.signal)
      .then((b) => setBatches(b || []))
      .catch((e) => { if (e.name !== 'AbortError') { setBatches([]); setError(e.message); } });
    return () => controller.abort();
  }, [labId, refreshKey]);

  async function openBatch(batchId) {
    setDetail({ loading: true });
    try {
      setDetail(await arWorkbenchService.batchDetail(labId, batchId));
    } catch (e) {
      setDetail(null);
      setError(e.message || 'The batch could not be loaded.');
    }
  }

  async function cancelBatch() {
    setCancelling(true);
    try {
      const result = await arWorkbenchService.cancelBatch(labId, detail.batch.assignmentBatchId);
      setNotice({ kind: 'good', text: result?.message || 'Batch cancelled.' });
      setDetail(null);
      refresh();
    } catch (e) {
      setError(e.message || 'The batch could not be cancelled.');
    } finally {
      setCancelling(false);
    }
  }

  // ---- Unassigned Claims -----------------------------------------------------------------------
  const [uaQuery, setUaQuery] = useState({ page: 1, pageSize: 25, sortBy: 'daysSinceLastTouch', sortDesc: true });
  const [uaData, setUaData] = useState({ items: [], totalCount: 0 });
  const [uaLoading, setUaLoading] = useState(true);
  const [uaSelected, setUaSelected] = useState(() => new Set());

  useEffect(() => {
    if (!overview) return undefined;
    const controller = new AbortController();
    setUaLoading(true);
    arWorkbenchService.claims({
      labId, status: ['Unassigned'], agent: ['__unassigned'], openInsuranceArOnly: true, minDaysUntouched: untouchedDays,
      sortBy: uaQuery.sortBy, sortDesc: uaQuery.sortDesc, page: uaQuery.page, pageSize: uaQuery.pageSize
    }, controller.signal)
      .then((r) => { setUaData(r); setUaLoading(false); })
      .catch((e) => { if (e.name !== 'AbortError') { setError(e.message); setUaLoading(false); } });
    return () => controller.abort();
  }, [labId, uaQuery, untouchedDays, overview === null, refreshKey]); // eslint-disable-line react-hooks/exhaustive-deps

  // ---- Assigned Claims - Bulk Reassign ---------------------------------------------------------
  const [raFilter, setRaFilter] = useState(BLANK_REASSIGN);
  const [raQuery, setRaQuery] = useState({ page: 1, pageSize: 25, sortBy: 'remainingAR', sortDesc: true });
  const [raData, setRaData] = useState({ items: [], totalCount: 0 });
  const [raLoading, setRaLoading] = useState(true);
  const [raSelected, setRaSelected] = useState(() => new Set());

  useEffect(() => {
    const controller = new AbortController();
    setRaLoading(true);
    arWorkbenchService.claims({
      labId, assignedOnly: true, openInsuranceArOnly: true,
      agent: raFilter.agent, category: raFilter.category, panel: raFilter.panel, priority: raFilter.priority,
      sortBy: raQuery.sortBy, sortDesc: raQuery.sortDesc, page: raQuery.page, pageSize: raQuery.pageSize
    }, controller.signal)
      .then((r) => { setRaData(r); setRaLoading(false); })
      .catch((e) => { if (e.name !== 'AbortError') { setError(e.message); setRaLoading(false); } });
    return () => controller.abort();
  }, [labId, raFilter, raQuery, refreshKey]);

  const setRa = (k, v) => { setRaFilter((f) => ({ ...f, [k]: v })); setRaQuery((q) => ({ ...q, page: 1 })); setRaSelected(new Set()); };
  const raOptions = useMemo(() => ({
    ...(options || {}),
    agents: (options?.agents || []).filter((a) => a.value !== '__unassigned')
  }), [options]);

  // ---- Assign dialog ---------------------------------------------------------------------------
  const [assigning, setAssigning] = useState(null);     // { keys, source: 'unassigned' | 'reassign' | 'batch', excludeAgent? }

  const afterAssign = useCallback((result) => {
    setNotice({ kind: 'good', text: result?.message || 'Done.' });
    if (assigning?.source === 'unassigned') setUaSelected(new Set());
    if (assigning?.source === 'reassign') setRaSelected(new Set());
    if (assigning?.source === 'batch') setDetail(null);
    setAssigning(null);
    refresh();
  }, [assigning]);

  const openClaim = (row) => navigate(`/claims/${row.claimKey}`, { state: { from: '/assignment' } });
  const claimLink = (r) => <button type="button" className="arwb-claim-link" onClick={(e) => { e.stopPropagation(); openClaim(r); }}>{r.claimID}</button>;
  const money = (v) => <span className="mono">{fmt.money(v)}</span>;

  const uaColumns = [
    { key: 'claimID', label: 'Claim ID', sortKey: 'claimId', render: claimLink },
    { key: 'labName', label: 'Client', render: (r) => r.labName || clientName },
    { key: 'payerName', label: 'Payer', sortKey: 'payerName', wrap: true },
    { key: 'panelName', label: 'Panel Type', sortKey: 'panelName' },
    { key: 'denialCategory', label: 'Denial Category', sortKey: 'denialCategory', wrap: true },
    { key: 'insuranceBalance', label: 'Ins. Balance', align: 'end', sortKey: 'insuranceBalance', render: (r) => money(r.insuranceBalance), csv: (r) => r.insuranceBalance },
    { key: 'agingBucket', label: 'Aging', sortKey: 'agingDays', render: (r) => r.agingBucket || '—' },
    { key: 'priority', label: 'Priority', sortKey: 'priority', render: (r) => <PriorityText priority={r.priority} /> },
    { key: 'daysSinceLastTouch', label: 'Days Untouched', align: 'end', sortKey: 'daysSinceLastTouch', render: (r) => (r.daysSinceLastTouch ?? '—') }
  ];

  const raColumns = [
    { key: 'claimID', label: 'Claim ID', sortKey: 'claimId', render: claimLink },
    { key: 'labName', label: 'Client', render: (r) => r.labName || clientName },
    { key: 'payerName', label: 'Payer', sortKey: 'payerName', wrap: true },
    { key: 'panelName', label: 'Panel Type', sortKey: 'panelName' },
    { key: 'denialCategory', label: 'Denial Category', sortKey: 'denialCategory', wrap: true },
    { key: 'insuranceBalance', label: 'Ins. Balance', align: 'end', sortKey: 'insuranceBalance', render: (r) => money(r.insuranceBalance), csv: (r) => r.insuranceBalance },
    { key: 'assignedAgentName', label: 'Current Agent', render: (r) => r.assignedAgentName || r.assignedAgentUser || '—', csv: (r) => r.assignedAgentName || r.assignedAgentUser || '' },
    { key: 'workflowStatus', label: 'Status', sortKey: 'workflowStatus', render: (r) => <StatusBadge status={r.workflowStatus} nonCollectible={r.hasNonCollectibleDenial} />,
      csv: (r) => r.workflowStatus + (r.hasNonCollectibleDenial ? ' (Non-Collectible)' : '') },
    { key: 'priority', label: 'Priority', sortKey: 'priority', render: (r) => <PriorityText priority={r.priority} /> },
    { key: 'agingBucket', label: 'Aging', sortKey: 'agingDays', render: (r) => r.agingBucket || '—' }
  ];

  const workload = [...agents].sort((a, b) => b.openClaims - a.openClaims)
    .map((a) => ({ label: a.displayName, value: a.openClaims, display: fmt.count(a.openClaims) }));

  if (!overview && !error) return <Loading text="Loading Assignment Management…" />;

  return (
    <>
      <Notice notice={notice} onClose={() => setNotice(null)} />
      <ErrorBox message={error} onRetry={error ? () => { setError(''); refresh(); } : undefined} />

      <div className="arwb-grid arwb-grid-charts arwb-section">
        <div className="arwb-card arwb-card-flush">
          <div className="arwb-card-head"><h3>Agent Workload</h3><span className="arwb-card-sub">open claims per agent</span></div>
          <div className="arwb-panel-pad">
            <BarList items={workload} empty="No AR Agents or Team Leads have access to this lab yet." />
          </div>
        </div>

        <div className="arwb-card arwb-card-flush">
          <div className="arwb-card-head"><Icon name="target" /><h3>Create Assignment Batch</h3></div>
          <div className="arwb-panel-pad">
            <div className="arwb-grid-2">
              {CRITERIA_FIELDS.map(([k, label, optKey]) => (
                <MultiSelect key={k} id={`b-${k}`} label={label} options={overview?.poolOptions?.[optKey] || []}
                  selected={criteria[k]} onChange={(v) => setCriteria((c) => ({ ...c, [k]: v }))} />
              ))}
            </div>
            <div className="arwb-section-note" style={{ marginTop: 10 }} aria-live="polite">
              {!hasCriteria(criteria) || !preview
                ? 'Select criteria to preview matching unassigned claims.'
                : <><b>{fmt.count(preview.claimCount)}</b> unassigned claim{preview.claimCount === 1 ? '' : 's'} match &middot; <b>{fmt.money(preview.totalInsuranceAR)}</b> total insurance AR</>}
            </div>
            <div className="arwb-grid-2" style={{ marginTop: 10 }}>
              <div className="arwb-field">
                <label htmlFor="batch-agent">Assign to Agent</label>
                <select id="batch-agent" className="arwb-select" value={agentUser} onChange={(e) => setAgentUser(e.target.value)}>
                  {!assignable.length && <option value="">No assignable agents</option>}
                  {assignable.map((a) => <option key={a.userName} value={a.userName}>{a.displayName} ({a.userName})</option>)}
                </select>
              </div>
              <div className="arwb-field">
                <label htmlFor="batch-due">Due Date</label>
                <input id="batch-due" type="date" className="arwb-input" min={today()} value={dueDate} onChange={(e) => setDueDate(e.target.value)} />
              </div>
            </div>
            <ErrorBox message={batchError} />
            <button type="button" className="arwb-btn arwb-btn-primary" style={{ marginTop: 10 }}
              disabled={creating || !hasCriteria(criteria) || !preview || preview.claimCount === 0 || !agentUser} onClick={createBatch}>
              {creating ? <><span className="arwb-spinner" /> Creating…</> : <>Create Batch &amp; Assign</>}
            </button>
          </div>
        </div>
      </div>

      <div className="arwb-card arwb-card-flush arwb-section">
        <div className="arwb-card-head"><h3>Assignment Batches</h3><span className="arwb-card-sub">{batches ? `${fmt.count(batches.length)} created` : ''}</span></div>
        <div className="arwb-table-wrap">
          <table className="arwb-data-table">
            <thead>
              <tr>
                <th>Batch ID</th><th>Client</th><th>Category</th><th className="num"># Claims</th><th className="num">Total Ins. AR</th>
                <th>Assigned Agent</th><th>Created By</th><th>Assign Date</th><th>Due Date</th><th>Status</th><th className="num">Completion</th>
              </tr>
            </thead>
            <tbody>
              {batches === null && <tr><td colSpan={11}><Loading /></td></tr>}
              {batches?.length === 0 && <tr><td colSpan={11}><div className="arwb-empty-state">No batches created yet.</div></td></tr>}
              {batches?.map((b) => (
                <tr key={b.assignmentBatchId} className="clickable" title={b.batchName} onClick={() => openBatch(b.assignmentBatchId)}>
                  <td className="mono">{b.batchNumber}</td>
                  <td>{clientName}</td>
                  <td>{categoryLabel(b)}</td>
                  <td className="num">{fmt.count(b.claimCount)}</td>
                  <td className="num mono">{fmt.money(b.remainingAR)}</td>
                  <td>{b.agentName || b.agentUser}</td>
                  <td>{b.createdBy}</td>
                  <td>{fmt.date(b.createdOn)}</td>
                  <td>{b.dueDate ? fmt.date(b.dueDate) : '—'}</td>
                  <td>{batchBadge(b)}</td>
                  <td className="num">{b.completionPct}%</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <div className="arwb-card arwb-card-flush arwb-section">
        <div className="arwb-card-head">
          <h3>Unassigned Claims</h3>
          <span className="arwb-card-sub">{fmt.count(uaData.totalCount)} claims with an open balance, untouched for {untouchedDays}+ days</span>
        </div>
        <DataTable
          tableId="assignment-unassigned"
          exportName="unassigned-claims"
          columns={uaColumns}
          rows={uaData.items || []}
          totalCount={uaData.totalCount}
          page={uaQuery.page}
          pageSize={uaQuery.pageSize}
          sortBy={uaQuery.sortBy}
          sortDesc={uaQuery.sortDesc}
          loading={uaLoading}
          emptyText={`No unassigned claims with an open balance have gone ${untouchedDays}+ days untouched.`}
          onSort={(sortBy, sortDesc) => setUaQuery((q) => ({ ...q, sortBy, sortDesc, page: 1 }))}
          onPage={(page) => setUaQuery((q) => ({ ...q, page }))}
          onPageSize={(pageSize) => setUaQuery((q) => ({ ...q, pageSize, page: 1 }))}
          onRowClick={openClaim}
          selectable
          selectedKeys={uaSelected}
          onSelectionChange={setUaSelected}
          toolbar={(
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!uaSelected.size}
              onClick={() => setAssigning({ keys: [...uaSelected], source: 'unassigned' })}>
              Assign Selected &rarr;
            </button>
          )}
        />
      </div>

      <div className="arwb-card arwb-card-flush arwb-section">
        <div className="arwb-card-head">
          <h3>Assigned Claims &mdash; Bulk Reassign</h3>
          <span className="arwb-card-sub">every assigned claim with an outstanding insurance balance, including ones marked Completed &mdash; select a caseload and move it in one step</span>
        </div>
        <div className="arwb-panel-pad">
          <div className="arwb-filter-bar">
            {REASSIGN_FIELDS.map(([k, label, optKey]) => (
              <MultiSelect key={k} id={`ra-${k}`} label={label} options={raOptions[optKey] || []} selected={raFilter[k]} onChange={(v) => setRa(k, v)} />
            ))}
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost"
              onClick={() => { setRaFilter(BLANK_REASSIGN); setRaQuery((q) => ({ ...q, page: 1 })); setRaSelected(new Set()); }}>Clear Filters</button>
          </div>
        </div>
        <DataTable
          tableId="assignment-reassign"
          exportName="assigned-claims-reassign"
          columns={raColumns}
          rows={raData.items || []}
          totalCount={raData.totalCount}
          page={raQuery.page}
          pageSize={raQuery.pageSize}
          sortBy={raQuery.sortBy}
          sortDesc={raQuery.sortDesc}
          loading={raLoading}
          emptyText="No assigned claims with an open balance match the filters."
          onSort={(sortBy, sortDesc) => setRaQuery((q) => ({ ...q, sortBy, sortDesc, page: 1 }))}
          onPage={(page) => setRaQuery((q) => ({ ...q, page }))}
          onPageSize={(pageSize) => setRaQuery((q) => ({ ...q, pageSize, page: 1 }))}
          onRowClick={openClaim}
          selectable
          selectedKeys={raSelected}
          onSelectionChange={setRaSelected}
          toolbar={(
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!raSelected.size}
              onClick={() => setAssigning({ keys: [...raSelected], source: 'reassign', excludeAgent: raFilter.agent.length === 1 ? raFilter.agent[0] : undefined })}>
              Reassign Selected &rarr;
            </button>
          )}
        />
      </div>

      {assigning && (
        <AssignModal labId={labId} claimKeys={assigning.keys} agents={agents} excludeAgent={assigning.excludeAgent}
          onClose={() => setAssigning(null)} onDone={afterAssign} />
      )}

      {detail && !assigning && (
        <Modal
          wide
          title={detail.loading ? 'Loading batch…' : `${detail.batch.batchNumber} · ${detail.batch.batchName}`}
          subtitle={detail.loading ? undefined : `${detail.batch.agentName || detail.batch.agentUser} · created ${fmt.dateTime(detail.batch.createdOn)} by ${detail.batch.createdBy}`}
          submitLabel={null}
          onClose={() => setDetail(null)}>
          {detail.loading ? <Loading /> : <BatchDetail detail={detail} cancelling={cancelling} onCancel={cancelBatch} onOpenClaim={openClaim}
            onReassign={(keys) => setAssigning({ keys, source: 'batch', excludeAgent: detail.batch.agentUser })} />}
        </Modal>
      )}
    </>
  );
}

function BatchDetail({ detail, cancelling, onCancel, onOpenClaim, onReassign }) {
  const { batch, claims, log } = detail;
  const [confirmCancel, setConfirmCancel] = useState(false);
  const remaining = claims.filter((c) => !c.isWorkComplete && c.currentAgentUser === batch.agentUser).map((c) => c.claimKey);

  return (
    <>
      <div className="arwb-impact-counts">
        <div><span>Status</span><strong style={{ fontSize: 14 }}>{batchBadge(batch)}</strong></div>
        <div><span>Claims</span><strong>{fmt.count(batch.claimCount)}</strong></div>
        <div><span>Completed</span><strong>{fmt.count(batch.completedCount)}</strong></div>
        <div><span>Ins. AR at assignment</span><strong style={{ fontSize: 15 }}>{fmt.money(batch.totalInsuranceAR)}</strong></div>
        <div><span>Remaining AR</span><strong style={{ fontSize: 15 }}>{fmt.money(batch.remainingAR)}</strong></div>
        <div><span>Due</span><strong style={{ fontSize: 15 }} className={batch.isOverdue ? 'text-critical' : ''}>{batch.dueDate ? fmt.date(batch.dueDate) : '—'}</strong></div>
      </div>
      <Progress pct={batch.completionPct} />
      {batch.criteriaSummary && <div className="arwb-hint">Criteria: {batch.criteriaSummary}</div>}

      <div className="arwb-table-wrap" style={{ maxHeight: 280 }}>
        <table className="arwb-data-table">
          <thead><tr><th>Claim ID</th><th>Payer</th><th>Category</th><th className="num">AR at Assignment</th><th className="num">Remaining AR</th><th>Status</th><th>Current Agent</th></tr></thead>
          <tbody>
            {claims.map((c) => (
              <tr key={c.claimKey} className={c.isWorkComplete ? 'arwb-row-inactive' : ''}>
                <td><button type="button" className="arwb-claim-link" onClick={() => onOpenClaim(c)}>{c.claimID}</button></td>
                <td className="wrap">{c.payerName || '—'}</td>
                <td className="wrap">{c.denialCategory || '—'}</td>
                <td className="num mono">{fmt.money(c.insuranceARAtAssignment)}</td>
                <td className="num mono">{fmt.money(c.remainingAR)}</td>
                <td><StatusBadge status={c.workflowStatus} /></td>
                <td>
                  <AgentName name={c.currentAgentName || c.currentAgentUser} />
                  {c.currentAgentUser !== batch.agentUser && <Badge className="arwb-badge-neutral" title="Moved to another agent after the batch was created">moved</Badge>}
                </td>
              </tr>
            ))}
            {!claims.length && <tr><td colSpan={7}><div className="arwb-empty-state">No claims in your access.</div></td></tr>}
          </tbody>
        </table>
      </div>

      <div>
        <h4 className="arwb-section-title" style={{ fontSize: 13, margin: '4px 0 6px' }}>Running log</h4>
        <div className="arwb-log arwb-timeline">
          {!log.length && <div className="arwb-hint">No activity yet.</div>}
          {log.map((a, i) => (
            <div key={i} className="arwb-tl-item">
              <div className="arwb-tl-time">{fmt.dateTime(a.activityOn)} · <span className="mono">{a.claimID}</span></div>
              <div><strong className="arwb-tl-action">{a.actionType}</strong> <span className="arwb-tl-user">{a.isSystem ? 'System' : a.userName}</span></div>
              {a.detail && <div className="arwb-tl-desc">{a.detail}</div>}
            </div>
          ))}
        </div>
      </div>

      {batch.batchStatus === 'Open' && (
        <div className="arwb-flex-between">
          <button type="button" className="arwb-btn arwb-btn-sm" disabled={!remaining.length} onClick={() => onReassign(remaining)}
            title="Move this batch's open claims that are still with its agent">
            Reassign remaining ({fmt.count(remaining.length)})
          </button>
          {confirmCancel
            ? <span className="arwb-row-actions">
                <span className="arwb-hint">Cancel the batch? Its claims stay with their agents.</span>
                <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-danger" disabled={cancelling} onClick={onCancel}>{cancelling ? 'Cancelling…' : 'Cancel batch'}</button>
                <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" disabled={cancelling} onClick={() => setConfirmCancel(false)}>Keep</button>
              </span>
            : <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => setConfirmCancel(true)}>Cancel batch…</button>}
        </div>
      )}
    </>
  );
}
