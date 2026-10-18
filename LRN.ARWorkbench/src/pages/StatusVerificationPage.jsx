import { useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import AssignModal from '../components/AssignModal';
import DataTable, { withSortKeys } from '../components/DataTable';
import Icon from '../components/Icon';
import Modal from '../components/Modal';
import { Badge, ErrorBox, Notice, PageHeader } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

// The manager's three decisions (API ArWorkbenchStatusVerificationActions). Reassigning to another
// agent (Assign dialog) also resolves the verification.
const ACTIONS = {
  ReturnToAgent: { label: 'Return to Agent', verb: 'return', help: 'The status change needs follow-up by the same agent: the claim goes back to their queue with its previous status.' },
  Unassign: { label: 'Release to Unassigned', verb: 'release', help: 'The claim leaves the agent’s queue and returns to the Work Queue for reassignment.' },
  Complete: { label: 'Complete', verb: 'complete', help: 'The new status settles the claim (e.g. paid or adjusted): the work is closed with no further follow-up.' }
};
const ACTION_LABEL = { ...Object.fromEntries(Object.entries(ACTIONS).map(([k, v]) => [k, v.label])), Reassigned: 'Reassigned' };

const lower = (v) => String(v ?? '').toLowerCase();
const SORTS = {
  raisedOn: (r) => r.raisedOn,
  claimId: (r) => r.claimID,
  payerName: (r) => lower(r.payerName),
  agent: (r) => lower(r.agentName),
  manager: (r) => lower(r.managerName),
  change: (r) => lower(r.newSourceStatus),
  insuranceBalance: (r) => r.insuranceBalance,
  status: (r) => (r.verificationStatus === 'Pending' ? 0 : 1)
};

function StatusChange({ row }) {
  return (
    <span style={{ whiteSpace: 'nowrap' }}>
      <Badge className="arwb-badge-neutral">{row.previousSourceStatus || '—'}</Badge>
      <span aria-hidden="true" style={{ margin: '0 6px' }}>→</span>
      <span className="visually-hidden"> changed to </span>
      <Badge className="arwb-badge-warning">{row.newSourceStatus || '(blank)'}</Badge>
      {row.verificationStatus === 'Pending' && row.currentSourceStatus && row.currentSourceStatus !== row.newSourceStatus
        && <div className="arwb-hint">now {row.currentSourceStatus}</div>}
    </span>
  );
}

/**
 * Status Change Verification. The weekly claim sync (run by the Master File Processor after the
 * line / claim level load, or Data Processing > Run) holds here every ASSIGNED claim that is not
 * completed or closed whose claim status changed in the master file - e.g. No Response -> Paid -
 * routed to one of the lab's RCM Managers. The manager returns it to the agent, releases it to the
 * pool, completes it, or reassigns it.
 */
export default function StatusVerificationPage() {
  const { labId, user } = useWorkbench();
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState(null);
  const [reload, setReload] = useState(0);
  const [searchText, setSearchText] = useState(params.get('q') || '');
  const [selected, setSelected] = useState(new Set());
  const [deciding, setDeciding] = useState(null);       // { action, rows }
  const [reassigning, setReassigning] = useState(null); // rows
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(50);
  const [sort, setSort] = useState({ by: 'raisedOn', desc: true });

  // A manager starts on their own queue (routed to them, or to no one in particular); an admin on all.
  const isManager = user?.roleCode === 'manager';
  const mine = params.has('mine') ? params.get('mine') === '1' : isManager;
  const status = params.get('status') || 'Pending';

  const filter = useMemo(() => ({ labId, status, mine, search: params.get('q') || '' }), [labId, status, mine, params]);

  useEffect(() => {
    const controller = new AbortController();
    setError('');
    arWorkbenchService.statusVerification(filter, controller.signal)
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
      if (v !== '' && v != null) next.set(k, v);
    });
    setParams(next, { replace: true });
  }

  const done = useCallback((text) => {
    setNotice({ kind: 'good', text });
    setDeciding(null);
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
  const selectedPending = rows.filter((r) => selected.has(r.statusVerificationId) && r.verificationStatus === 'Pending');
  const openClaim = (row) => navigate(`/claims/${row.claimKey}`, { state: { from: `/status-verification?${params}` } });

  const columns = withSortKeys([
    { key: 'claimID', label: 'Claim ID', sortKey: 'claimId', render: (r) => <span className="mono">{r.claimID}</span> },
    { key: 'patientName', label: 'Patient', wrap: true, render: (r) => r.patientName || '—' },
    { key: 'payerName', label: 'Payer', wrap: true, render: (r) => r.payerName || '—' },
    { key: 'change', label: 'Claim Status Change', csv: (r) => `${r.previousSourceStatus || ''} -> ${r.newSourceStatus || ''}`, render: (r) => <StatusChange row={r} /> },
    { key: 'insuranceBalance', label: 'Ins. Balance', align: 'end', csv: (r) => r.insuranceBalance, render: (r) => <span className="mono">{fmt.money(r.insuranceBalance)}</span> },
    { key: 'agent', label: 'AR Agent', csv: (r) => r.agentName || '', render: (r) => <>{r.agentName || '—'}<div className="arwb-hint">was {r.previousWorkflowStatus}</div></> },
    { key: 'manager', label: 'RCM Manager', csv: (r) => r.managerName || 'Any manager',
      render: (r) => r.managerName || <span className="text-muted-ink">Any manager</span> },
    { key: 'raisedOn', label: 'Raised', sortKey: 'raisedOn', csv: (r) => r.raisedOn, render: (r) => fmt.dateTime(r.raisedOn) },
    { key: 'status', label: 'Verification', csv: (r) => r.verificationStatus,
      render: (r) => (r.verificationStatus === 'Pending'
        ? <Badge className="arwb-badge-critical" dot>Pending</Badge>
        : <><Badge className="arwb-badge-good">{ACTION_LABEL[r.resolvedAction] || 'Resolved'}</Badge>
            <div className="arwb-hint">{r.resolvedByName} · {fmt.dateTime(r.resolvedOn)}</div>
            {r.resolutionNote && <div className="arwb-pre-line arwb-hint" style={{ minWidth: 0 }}>{r.resolutionNote}</div>}</>) },
    { key: 'action', label: '', align: 'end',
      render: (r) => (r.verificationStatus === 'Pending'
        ? <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={(e) => { e.stopPropagation(); setDeciding({ action: null, rows: [r] }); }}>Verify</button>
        : <button type="button" className="arwb-btn arwb-btn-sm" onClick={(e) => { e.stopPropagation(); openClaim(r); }}>Open Claim</button>) }
  ], { patientName: 'patientName', payerName: 'payerName', change: 'change', insuranceBalance: 'insuranceBalance', agent: 'agent', manager: 'manager', status: 'status' });

  const tiles = [
    ['Pending — mine', data?.pendingMine, { status: 'Pending', mine: '1' }],
    ['Pending — any manager', data?.pendingUnrouted, { status: 'Pending', mine: '1' }],
    ['Pending — all managers', data?.pending, { status: 'Pending', mine: '0' }],
    ['Resolved (30 days)', data?.resolvedLast30Days, { status: 'Resolved', mine: '0' }]
  ];

  return (
    <>
      <PageHeader note="Raised by the weekly claim sync when an assigned claim that is not completed or closed comes back from the master file with a different claim status. Return it to the agent, release it to the Work Queue, complete it, or reassign it." />
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
            <label htmlFor="sv-search">Search</label>
            <input id="sv-search" type="search" className="arwb-input" placeholder="Claim ID, patient, payer, agent, status…" maxLength={200}
              value={searchText} onChange={(e) => setSearchText(e.target.value)} />
          </div>
          <div className="arwb-field">
            <label htmlFor="sv-status">Verification</label>
            <select id="sv-status" className="arwb-select" value={status} onChange={(e) => update({ status: e.target.value })}>
              <option value="Pending">Pending</option>
              <option value="Resolved">Resolved</option>
              <option value="All">All</option>
            </select>
          </div>
          <div className="arwb-field">
            <label htmlFor="sv-mine">RCM Manager</label>
            <select id="sv-mine" className="arwb-select" value={mine ? '1' : '0'} onChange={(e) => update({ mine: e.target.value })}>
              <option value="1">Mine and unrouted</option>
              <option value="0">All managers</option>
            </select>
          </div>
        </div>
      </div>

      {data?.truncated && <div className="arwb-hint arwb-section">Showing the first 2,000 verifications — narrow the filters to see the rest.</div>}

      <DataTable tableId="status-verification" exportName="ARWorkbench_StatusChangeVerification"
        columns={columns} rows={pageRows} totalCount={rows.length} loading={!data}
        page={page} pageSize={pageSize} onPage={setPage} onPageSize={(n) => { setPageSize(n); setPage(1); }}
        sortBy={sort.by} sortDesc={sort.desc} onSort={(by, desc) => setSort({ by, desc })}
        rowKey={(r) => r.statusVerificationId} onRowClick={openClaim}
        selectable selectedKeys={selected} onSelectionChange={setSelected}
        emptyText={status === 'Pending' ? 'No claims are waiting for status verification.' : 'No verifications match these filters.'}
        toolbar={(
          <>
            {Object.entries(ACTIONS).map(([action, a]) => (
              <button key={action} type="button" className={`arwb-btn arwb-btn-sm${action === 'ReturnToAgent' ? ' arwb-btn-primary' : ''}`}
                disabled={!selectedPending.length} onClick={() => setDeciding({ action, rows: selectedPending })}>
                {a.label}{selectedPending.length ? ` (${fmt.count(selectedPending.length)})` : ''}
              </button>
            ))}
            <button type="button" className="arwb-btn arwb-btn-sm" disabled={!selectedPending.length} onClick={() => setReassigning(selectedPending)}>
              <Icon name="users" size={15} /> Reassign
            </button>
          </>
        )} />

      {deciding && (
        <DecideModal labId={labId} rows={deciding.rows} initialAction={deciding.action} onClose={() => setDeciding(null)} onDone={done}
          onReassign={() => { setReassigning(deciding.rows); setDeciding(null); }}
          onOpenClaim={deciding.rows.length === 1 ? () => openClaim(deciding.rows[0]) : null} />
      )}
      {reassigning && (
        <AssignModal labId={labId} claimKeys={reassigning.map((r) => r.claimKey)}
          excludeAgent={reassigning.length === 1 ? reassigning[0].agentUser : undefined}
          onClose={() => setReassigning(null)}
          onDone={() => done(`${fmt.count(reassigning.length)} claim${reassigning.length === 1 ? '' : 's'} reassigned; the status verification is resolved.`)} />
      )}
    </>
  );
}

function DecideModal({ labId, rows, initialAction, onClose, onDone, onReassign, onOpenClaim }) {
  const [action, setAction] = useState(initialAction || 'ReturnToAgent');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const single = rows.length === 1 ? rows[0] : null;

  async function submit() {
    if (!note.trim()) { setError('Add a verification note: it is recorded on the claim and sent to the agent.'); return; }
    setBusy(true);
    setError('');
    try {
      const r = await arWorkbenchService.resolveStatusVerification(labId, { claimKeys: rows.map((x) => x.claimKey), action, note: note.trim() });
      if (r.resolved === 0) { setError('Nothing was changed: these claims are no longer waiting for verification. Reload to see the latest.'); setBusy(false); return; }
      onDone(r.message);
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  }

  const title = single ? `Verify claim ${single.claimID}` : `Verify ${fmt.count(rows.length)} claims`;
  return (
    <Modal title={title} submitLabel={ACTIONS[action].label} busy={busy} busyLabel="Saving…" onClose={onClose} onSubmit={submit}>
      <ErrorBox message={error} />
      {single ? (
        <div className="arwb-section-note" style={{ marginBottom: 12 }}>
          <b className="mono">{single.claimID}</b>{single.payerName ? ` · ${single.payerName}` : ''} · {fmt.money(single.insuranceBalance)}
          <div style={{ marginTop: 6 }}>Claim status: <StatusChange row={single} /></div>
          <div className="arwb-hint" style={{ marginTop: 4 }}>
            Held from <b>{single.agentName || single.agentUser || 'the agent'}</b> ({single.previousWorkflowStatus}) · raised {fmt.dateTime(single.raisedOn)}
          </div>
        </div>
      ) : (
        <div className="arwb-section-note" style={{ marginBottom: 12 }}>
          This decision and note are applied to every selected claim. Use Verify on one row when each needs a different answer.
        </div>
      )}
      <fieldset className="arwb-field">
        <legend style={{ fontSize: 'inherit', fontWeight: 600 }}>Decision</legend>
        {Object.entries(ACTIONS).map(([key, a]) => (
          <label key={key} style={{ display: 'flex', gap: 8, alignItems: 'flex-start', fontWeight: 400, marginBottom: 6 }}>
            <input type="radio" name="sv-action" value={key} checked={action === key} onChange={() => setAction(key)} style={{ marginTop: 3 }} />
            <span><b>{a.label}</b><br /><span className="arwb-hint">{a.help}</span></span>
          </label>
        ))}
      </fieldset>
      <div className="arwb-field">
        <label htmlFor="sv-note">Verification note *</label>
        <textarea id="sv-note" className="arwb-textarea" rows={3} maxLength={2000} value={note} onChange={(e) => setNote(e.target.value)}
          placeholder="What did you check, and what should happen next?" />
      </div>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        <button type="button" className="arwb-btn arwb-btn-sm" disabled={busy} onClick={onReassign} title="Pick another agent; reassigning resolves the verification">
          <Icon name="users" size={15} /> Reassign instead
        </button>
        {onOpenClaim && <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" disabled={busy} onClick={onOpenClaim}>Open Claim</button>}
      </div>
    </Modal>
  );
}
