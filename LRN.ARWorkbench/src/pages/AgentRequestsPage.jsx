import { useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import AssignModal from '../components/AssignModal';
import DataTable, { withSortKeys } from '../components/DataTable';
import Icon from '../components/Icon';
import Modal from '../components/Modal';
import MultiSelect from '../components/MultiSelect';
import { Badge, ErrorBox, Notice, PageHeader } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { arQueueBadgeClass, fmt } from '../utils/format';

const ESCALATION = 'Escalation to Supervisor';
const REASSIGNMENT = 'Reassignment Request';

// URL param -> API filter, like the Work Queue: the filters survive a reload and a Back from the claim.
const LIST_FILTERS = [
  { param: 'type', label: 'Request Type', options: () => [ESCALATION, REASSIGNMENT].map((v) => ({ value: v, label: v })) },
  { param: 'status', label: 'Status', options: () => ['Pending', 'Resolved'].map((v) => ({ value: v, label: v })) },
  { param: 'payer', label: 'Payer', options: (d) => d?.payers || [] },
  { param: 'agent', label: 'AR Agent', options: (d) => d?.agents || [] },
  { param: 'requestedBy', label: 'Requested By', options: (d) => d?.requestedBy || [] },
  { param: 'queue', label: 'Current AR Queue', options: (d) => d?.queues || [] }
];

// Client-side sorts (the whole filtered list is loaded): every data column.
const lower = (v) => String(v ?? '').toLowerCase();
const SORTS = {
  requestedOn: (r) => r.requestedOn,
  claimId: (r) => r.claimID,
  payerName: (r) => lower(r.payerName),
  agent: (r) => lower(r.assignedAgentName),
  insuranceBalance: (r) => r.insuranceBalance,
  requestType: (r) => r.requestType,
  reason: (r) => lower(r.reasonCategory),
  queue: (r) => lower(r.arQueueLabel),
  requestedBy: (r) => lower(r.requestedByName),
  requestStatus: (r) => (r.requestStatus === 'Pending' ? 0 : 1),
  response: (r) => r.resolvedOn || ''
};

/**
 * Escalation & Reassignment Requests (mockup App.views['agent-requests']): every "Escalate to
 * Supervisor" and "Request Reassignment" an AR agent raised from a claim, for a Team Lead, RCM
 * Manager or Administrator to answer - one at a time (Respond), or many with one shared note
 * (Resolve Selected). A reassignment request is best answered by reassigning the claim, which
 * resolves it automatically.
 */
export default function AgentRequestsPage() {
  const { labId } = useWorkbench();
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState(null);
  const [reload, setReload] = useState(0);
  const [searchText, setSearchText] = useState(params.get('q') || '');
  const [selected, setSelected] = useState(new Set());
  const [responding, setResponding] = useState(null);       // one request row
  const [bulkResolving, setBulkResolving] = useState(false);
  const [reassigning, setReassigning] = useState(null);     // request row whose claim is being reassigned
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(50);
  const [sort, setSort] = useState({ by: 'requestStatus', desc: false });

  // Pending only by default: the queue is the work still waiting for an answer.
  const filter = useMemo(() => {
    const f = { labId, search: params.get('q') || '' };
    LIST_FILTERS.forEach((lf) => { f[lf.param] = params.getAll(lf.param); });
    if (!params.has('status') && !params.has('all')) f.status = ['Pending'];
    return f;
  }, [labId, params]);

  useEffect(() => {
    const controller = new AbortController();
    setError('');
    arWorkbenchService.agentRequests(filter, controller.signal)
      .then((d) => { setData(d); setPage(1); })
      .catch((e) => { if (e.name !== 'AbortError') setError(e.message); });
    return () => controller.abort();
  }, [filter, reload]);

  useEffect(() => { setSelected(new Set()); }, [filter]);

  useEffect(() => {
    const t = setTimeout(() => {
      if (searchText.trim() !== (params.get('q') || '')) update({ q: searchText.trim() });
    }, 400);
    return () => clearTimeout(t);
  }, [searchText]); // eslint-disable-line react-hooks/exhaustive-deps

  function update(changes) {
    const next = new URLSearchParams(params);
    Object.entries(changes).forEach(([k, v]) => {
      next.delete(k);
      if (Array.isArray(v)) v.forEach((x) => next.append(k, x));
      else if (v !== '' && v != null) next.set(k, v);
    });
    setParams(next, { replace: true });
  }

  const done = useCallback((text) => {
    setNotice({ kind: 'good', text });
    setResponding(null);
    setBulkResolving(false);
    setReassigning(null);
    setSelected(new Set());
    setReload((n) => n + 1);
  }, []);

  const rows = useMemo(() => {
    const list = [...(data?.rows || [])];
    const key = SORTS[sort.by];
    if (key) {
      list.sort((a, b) => {
        const x = key(a); const y = key(b);
        const c = x < y ? -1 : x > y ? 1 : 0;
        return sort.desc ? -c : c;
      });
    }
    return list;
  }, [data, sort]);
  const pageRows = rows.slice((page - 1) * pageSize, page * pageSize);
  const selectedPending = rows.filter((r) => selected.has(r.agentRequestId) && r.requestStatus === 'Pending');
  const openClaim = (row) => navigate(`/claims/${row.claimKey}`, { state: { from: `/agent-requests?${params}` } });

  const columns = withSortKeys([
    { key: 'claimID', label: 'Claim ID', sortKey: 'claimId', render: (r) => <span className="mono">{r.claimID}</span> },
    { key: 'payerName', label: 'Payer', wrap: true, render: (r) => r.payerName || '—' },
    { key: 'agent', label: 'AR Agent', render: (r) => r.assignedAgentName || <span className="text-muted-ink">Unassigned</span>, csv: (r) => r.assignedAgentName || '' },
    { key: 'requestType', label: 'Request Type', sortKey: 'requestType', csv: (r) => r.requestType,
      render: (r) => <Badge className={r.requestType === ESCALATION ? 'arwb-badge-critical' : 'arwb-badge-info'} dot>{r.requestType}</Badge> },
    { key: 'reason', label: 'Reason / Note', wrap: true, csv: (r) => `${r.reasonCategory} - ${r.requestNote}`,
      render: (r) => <><b>{r.reasonCategory}</b><div className="arwb-pre-line" style={{ minWidth: 0 }}>{r.requestNote}</div></> },
    { key: 'insuranceBalance', label: 'Ins. Balance', align: 'end', sortKey: 'insuranceBalance', csv: (r) => r.insuranceBalance, render: (r) => <span className="mono">{fmt.money(r.insuranceBalance)}</span> },
    { key: 'queue', label: 'Current AR Queue', csv: (r) => r.arQueueLabel || '',
      render: (r) => (r.arQueueLabel ? <Badge className={arQueueBadgeClass(r.arQueueId)}>{r.arQueueLabel}</Badge> : '—') },
    { key: 'requestedBy', label: 'Requested By', csv: (r) => r.requestedByName, render: (r) => r.requestedByName },
    { key: 'requestedOn', label: 'Requested', sortKey: 'requestedOn', csv: (r) => r.requestedOn, render: (r) => fmt.dateTime(r.requestedOn) },
    { key: 'requestStatus', label: 'Status', sortKey: 'requestStatus', csv: (r) => r.requestStatus,
      render: (r) => <Badge className={r.requestStatus === 'Pending' ? 'arwb-badge-warning' : 'arwb-badge-good'}>{r.requestStatus}</Badge> },
    { key: 'response', label: 'Response', wrap: true,
      csv: (r) => (r.requestStatus === 'Resolved' ? `${r.resolutionNote || ''} (${r.resolvedByName || ''} ${r.resolvedOn || ''})` : 'Awaiting response'),
      render: (r) => (r.requestStatus === 'Resolved'
        ? <><div className="arwb-pre-line" style={{ minWidth: 0 }}>{r.resolutionNote || '—'}</div><div className="arwb-hint">{r.resolvedByName} · {fmt.dateTime(r.resolvedOn)}{r.isBulk ? ' · bulk' : ''}</div></>
        : <span className="text-muted-ink">Awaiting response</span>) },
    { key: 'action', label: '', align: 'end',
      render: (r) => (r.requestStatus === 'Pending'
        ? <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={(e) => { e.stopPropagation(); setResponding(r); }}>Respond</button>
        : <button type="button" className="arwb-btn arwb-btn-sm" onClick={(e) => { e.stopPropagation(); openClaim(r); }}>Open Claim</button>) }
  ], { payerName: 'payerName', agent: 'agent', reason: 'reason', insuranceBalance: 'insuranceBalance', queue: 'queue', requestedBy: 'requestedBy', response: 'response' });

  const tiles = [
    ['Pending Escalations', data?.pendingEscalations, { type: ESCALATION, status: 'Pending' }],
    ['Pending Reassignment Requests', data?.pendingReassignments, { type: REASSIGNMENT, status: 'Pending' }],
    ['Resolved', data?.resolved, { status: 'Resolved' }],
    ['Total Requests', data?.total, { all: '1' }]
  ];

  return (
    <>
      <PageHeader note="Raised by AR agents from a claim · answered here by a Team Lead, RCM Manager or Administrator. Reassigning a claim resolves its reassignment request automatically." />
      <Notice notice={notice} onClose={() => setNotice(null)} />
      <ErrorBox message={error} />

      <div className="arwb-grid arwb-grid-kpi arwb-section">
        {tiles.map(([label, value, target]) => (
          <button key={label} type="button" className="arwb-panel arwb-kpi-tile arwb-kpi-tile-btn"
            onClick={() => { setSearchText(''); setParams(new URLSearchParams(target), { replace: true }); }}>
            <span className="arwb-kpi-accent-bar" />
            <span className="arwb-kpi-label">{label}</span>
            <span className="arwb-kpi-value">{data ? fmt.count(value) : '…'}</span>
          </button>
        ))}
      </div>

      <div className="arwb-panel arwb-filter-card">
        <div className="arwb-filter-bar">
          <div className="arwb-field grow">
            <label htmlFor="ar-search">Search</label>
            <input id="ar-search" type="search" className="arwb-input" placeholder="Claim ID, agent, requested by, reason…" maxLength={200}
              value={searchText} onChange={(e) => setSearchText(e.target.value)} />
          </div>
          {LIST_FILTERS.map((lf) => (
            <MultiSelect key={lf.param} id={`ar-${lf.param}`} label={lf.label} options={lf.options(data)}
              selected={filter[lf.param]}
              // Clearing Status means every status (all=1), not the pending-only default.
              onChange={(values) => update(lf.param === 'status' ? { status: values, all: values.length ? '' : '1' } : { [lf.param]: values })} />
          ))}
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => { setSearchText(''); setParams(new URLSearchParams(), { replace: true }); }}>Clear Filters</button>
        </div>
        {!params.has('status') && !params.has('all') && <div className="arwb-hint" style={{ padding: '0 16px 10px' }}>Showing pending requests. Pick a Status, or click Total Requests, to see resolved ones.</div>}
      </div>

      {data?.truncated && <div className="arwb-hint arwb-section">Showing the first 2,000 requests — narrow the filters to see the rest.</div>}

      <DataTable tableId="agent-requests" exportName="ARWorkbench_EscalationReassignmentRequests"
        columns={columns} rows={pageRows} totalCount={rows.length} loading={!data}
        page={page} pageSize={pageSize} onPage={setPage} onPageSize={(n) => { setPageSize(n); setPage(1); }}
        sortBy={sort.by} sortDesc={sort.desc} onSort={(by, desc) => setSort({ by, desc })}
        rowKey={(r) => r.agentRequestId} onRowClick={openClaim}
        selectable selectedKeys={selected} onSelectionChange={setSelected}
        emptyText="No requests match these filters."
        toolbar={(
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!selectedPending.length} onClick={() => setBulkResolving(true)}>
            <Icon name="check" size={15} /> Resolve Selected{selectedPending.length ? ` (${fmt.count(selectedPending.length)})` : ''}
          </button>
        )} />

      {responding && (
        <RespondModal labId={labId} request={responding} onClose={() => setResponding(null)} onDone={done}
          onReassign={() => { setReassigning(responding); setResponding(null); }} onOpenClaim={() => openClaim(responding)} />
      )}
      {bulkResolving && (
        <BulkResolveModal labId={labId} requests={selectedPending} onClose={() => setBulkResolving(false)} onDone={done} />
      )}
      {reassigning && (
        <AssignModal labId={labId} claimKeys={[reassigning.claimKey]} excludeAgent={reassigning.assignedAgentUser}
          onClose={() => setReassigning(null)}
          onDone={() => done(`Claim ${reassigning.claimID} reassigned; its reassignment request is resolved.`)} />
      )}
    </>
  );
}

function RequestSummary({ request }) {
  return (
    <div className="arwb-section-note" style={{ marginBottom: 12 }}>
      <b className="mono">{request.claimID}</b>{request.payerName ? ` · ${request.payerName}` : ''} · requested by <b>{request.requestedByName}</b>
      {request.requestedByRole ? ` (${request.requestedByRole})` : ''} · {fmt.dateTime(request.requestedOn)}
      <div style={{ marginTop: 6 }}><b>{request.reasonCategory}</b></div>
      <div className="arwb-pre-line" style={{ minWidth: 0 }}>{request.requestNote}</div>
    </div>
  );
}

function RespondModal({ labId, request, onClose, onDone, onReassign, onOpenClaim }) {
  const isReassign = request.requestType === REASSIGNMENT;
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function resolve() {
    if (!note.trim()) { setError('Add a response note: it is what the agent sees.'); return; }
    setBusy(true);
    setError('');
    try {
      const r = await arWorkbenchService.resolveAgentRequests(labId, { requestIds: [request.agentRequestId], note: note.trim() });
      if (r.resolved === 0) { setError('This request was already resolved. Reload to see the latest.'); setBusy(false); return; }
      onDone(`${request.requestType} on claim ${request.claimID} resolved.`);
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  }

  return (
    <Modal title={`Respond — ${request.requestType}`} submitLabel="Mark Resolved" busy={busy} busyLabel="Resolving…" onClose={onClose} onSubmit={resolve}>
      <ErrorBox message={error} />
      <RequestSummary request={request} />
      <div className="arwb-field">
        <label htmlFor="ar-respond-note">Response / resolution note *</label>
        <textarea id="ar-respond-note" className="arwb-textarea" rows={3} maxLength={2000} value={note} onChange={(e) => setNote(e.target.value)}
          placeholder="What did you tell the agent, or what was done?" />
      </div>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        {isReassign && (
          <button type="button" className="arwb-btn arwb-btn-sm" disabled={busy} onClick={onReassign} title="Pick the new agent; the request resolves when the claim is reassigned">
            <Icon name="users" size={15} /> Reassign &amp; Resolve
          </button>
        )}
        <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" disabled={busy} onClick={onOpenClaim}>Open Claim</button>
      </div>
    </Modal>
  );
}

function BulkResolveModal({ labId, requests, onClose, onDone }) {
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const escalations = requests.filter((r) => r.requestType === ESCALATION).length;
  const reassignments = requests.length - escalations;

  async function resolve() {
    if (!note.trim()) { setError('Add a response note: it is recorded on every selected request.'); return; }
    setBusy(true);
    setError('');
    try {
      const r = await arWorkbenchService.resolveAgentRequests(labId, { requestIds: requests.map((x) => x.agentRequestId), note: note.trim() });
      onDone(r.message);
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  }

  return (
    <Modal title={`Resolve ${fmt.count(requests.length)} request${requests.length === 1 ? '' : 's'}`} submitLabel={`Mark ${fmt.count(requests.length)} Resolved`}
      busy={busy} busyLabel="Resolving…" onClose={onClose} onSubmit={resolve}>
      <ErrorBox message={error} />
      <div className="arwb-section-note" style={{ marginBottom: 12 }}>
        {fmt.count(escalations)} escalation{escalations === 1 ? '' : 's'} · {fmt.count(reassignments)} reassignment request{reassignments === 1 ? '' : 's'}.
        This note is recorded as the response on every selected request. Use Respond on one row when each needs a different answer, or to resolve a
        reassignment request by reassigning the claim.
      </div>
      <div className="arwb-field">
        <label htmlFor="ar-bulk-note">Response / resolution note *</label>
        <textarea id="ar-bulk-note" className="arwb-textarea" rows={3} maxLength={2000} value={note} onChange={(e) => setNote(e.target.value)}
          placeholder="What did you tell the agent(s), or what was done?" />
      </div>
    </Modal>
  );
}
