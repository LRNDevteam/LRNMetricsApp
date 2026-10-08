import { useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router';
import DataTable, { withSortKeys } from '../components/DataTable';
import { CIP_SORT_KEYS } from '../config/sortKeys';
import Icon from '../components/Icon';
import Modal from '../components/Modal';
import MultiSelect from '../components/MultiSelect';
import { Badge, ErrorBox, Notice } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { arQueueBadgeClass, fmt } from '../utils/format';
import { Attachments, CIP_BADGE } from '../components/CipShared';

// CIP - Client Escalations (mockup App.views['cip-escalations']) for Team Lead / RCM Manager /
// Administrator, and the client's Escalation Requests (App.views['client-cip']), one component:
//   internal: Pending Approval -> approve (send to client) / reject (back to agent);
//             Client Responded -> approve response (back to agent) / insufficient (re-send, round + 1);
//             bulk approve / bulk send back over a mixed selection (each case by its own stage).
//   client:   the requests sent to them; Respond with the requested information.

const INTERNAL_STATUSES = ['Pending Approval', 'Sent to Client', 'Client Responded', 'Returned to Agent'];
const CLIENT_STATUSES = ['Sent to Client', 'Client Responded', 'Returned to Agent'];

function CaseSummary({ row, client }) {
  return (
    <div className="arwb-section-note" style={{ marginBottom: 12 }}>
      <b className="mono">{row.claimID}</b> · {row.caseNumber}{row.roundNumber > 1 ? ` · Round ${row.roundNumber}` : ''} · {row.payerName || '—'}
      {!client && <> · requested by <b>{row.requestedBy}</b> on {fmt.date(row.followUpDate || row.requestedOn)}</>}
      {client && <> · Patient Acct {row.patientID || '—'} · DOS {fmt.date(row.dateOfService)}</>}
      <div style={{ marginTop: 8 }}><b>{row.cipCategory}</b> · {row.requiredInfo}</div>
      <div style={{ marginTop: 4 }}>{row.cipComment}</div>
      {row.lastReviewDecision === 'insufficient' && row.lastReviewNote && (
        <div style={{ marginTop: 8 }} className="text-critical">Previous response was insufficient: {row.lastReviewNote}</div>
      )}
      {!client && row.clientResponseText && (
        <div style={{ marginTop: 8 }}><b>Client response</b> ({row.clientRespondedBy} · {fmt.dateTime(row.clientRespondedOn)}): {row.clientResponseText}</div>
      )}
    </div>
  );
}

function CipActionModal({ row, mode, onClose, onDone }) {
  // mode: approval (Pending Approval) | review (Client Responded) | respond (client)
  const { labId } = useWorkbench();
  const [note, setNote] = useState(mode === 'respond' ? '' : '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function act(action) {
    const needsText = action !== 'approve' && action !== 'approve-response';
    if (needsText && !note.trim()) { setError(action === 'respond' ? 'Enter the requested information.' : 'Add a reason first.'); return; }
    setBusy(true);
    setError('');
    try {
      onDone(await arWorkbenchService.cipAction(labId, row.cipCaseId, action, note.trim() || null));
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  }

  const titles = { approval: 'Review CIP Escalation', review: 'Review Client Response', respond: 'Respond to Escalation Request' };
  return (
    <Modal wide title={titles[mode]} busy={busy} onClose={onClose} submitLabel={null}>
      <ErrorBox message={error} />
      <CaseSummary row={row} client={mode === 'respond'} />
      <div className="arwb-field">
        <label htmlFor="cip-note">
          {mode === 'respond' ? 'Requested information' : mode === 'approval' ? 'Note (optional to approve, required to reject)' : 'Note (optional to approve, required if insufficient - the client sees it)'}
        </label>
        <textarea id="cip-note" className="arwb-input" rows={mode === 'respond' ? 5 : 3} maxLength={4000} value={note} onChange={(e) => setNote(e.target.value)} />
      </div>
      <div className="arwb-modal-actions">
        <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" disabled={busy} onClick={onClose}>Cancel</button>
        {mode === 'approval' && <>
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-danger" disabled={busy} onClick={() => act('reject')}>Reject — Return to Agent</button>
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={busy} onClick={() => act('approve')}>Approve &amp; Send to Client</button>
        </>}
        {mode === 'review' && <>
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-danger" disabled={busy} onClick={() => act('insufficient')}>Insufficient — Re-send to Client</button>
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={busy} onClick={() => act('approve-response')}>Approve &amp; Return to Agent</button>
        </>}
        {mode === 'respond' && (
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={busy} onClick={() => act('respond')}>Submit Response</button>
        )}
        {busy && <span className="arwb-spinner" />}
      </div>
    </Modal>
  );
}

// T063: bring the Denial Workflow's external escalations / Account Manager responses into CIP
// Escalations. Preview first; re-running only adds escalations not converted yet.
function LegacyConvertModal({ onClose, onDone }) {
  const { labId } = useWorkbench();
  const [preview, setPreview] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => { arWorkbenchService.convertLegacyCip(labId, true).then(setPreview).catch((e) => setError(e.message)); }, [labId]);
  async function run() {
    setBusy(true);
    setError('');
    try { onDone(await arWorkbenchService.convertLegacyCip(labId, false)); } catch (e) { setError(e.message); setBusy(false); }
  }
  const nothing = preview && preview.candidates - preview.noMatchingClaim <= 0;
  return (
    <Modal title="Convert Denial Workflow Escalations" busy={busy} busyLabel="Converting…" onClose={onClose}
      onSubmit={preview && !nothing ? run : onClose} submitLabel={preview && !nothing ? 'Convert' : null}>
      <ErrorBox message={error} />
      {!preview && !error && <p className="arwb-hint">Checking the Denial Workflow&rsquo;s external escalations…</p>}
      {preview && <p>{preview.message}</p>}
      <p className="arwb-hint">
        External escalations (escalated to a Client / Account Manager) become CIP cases: open ones as Sent to Client, answered ones as Client Responded
        with the response text, closed ones as Returned to Agent. The Denial Workflow data is only read; each escalation is converted once.
      </p>
    </Modal>
  );
}

export default function CipPage({ view = 'internal' }) {
  const client = view === 'client';
  const { labId, user } = useWorkbench();
  const [converting, setConverting] = useState(false);
  const navigate = useNavigate();
  const statusOptions = (client ? CLIENT_STATUSES : INTERNAL_STATUSES).map((s) => ({ value: s, label: s }));
  const [status, setStatus] = useState(client ? ['Sent to Client'] : []);
  const [category, setCategory] = useState([]);
  const [searchText, setSearchText] = useState('');
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState({ page: 1, pageSize: 50, sortBy: 'caseStatus', sortDesc: false });
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState(null);
  const [selected, setSelected] = useState(() => new Set());
  const [acting, setActing] = useState(null);      // { row, mode }
  const [bulk, setBulk] = useState(null);          // 'approve' | 'sendback'
  const [bulkNote, setBulkNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);
  const { masterData } = useWorkbench();
  const categoryOptions = (masterData?.lists?.CIP_CATEGORY || []).map((c) => ({ value: c, label: c }));

  useEffect(() => {
    const t = setTimeout(() => { if (searchText.trim() !== search) { setSearch(searchText.trim()); setQuery((q) => ({ ...q, page: 1 })); } }, 400);
    return () => clearTimeout(t);
  }, [searchText]); // eslint-disable-line react-hooks/exhaustive-deps

  const filter = useMemo(() => ({ labId, status, category, search, ...query }), [labId, status, category, search, query]);
  const load = useCallback((signal) => {
    setLoading(true);
    setError('');
    return (client ? arWorkbenchService.clientCipQueue(filter, signal) : arWorkbenchService.cipQueue(filter, signal))
      .then((r) => { setData(r); setLoading(false); })
      .catch((e) => { if (e.name !== 'AbortError') { setError(e.message); setLoading(false); } });
  }, [filter, client]);
  useEffect(() => {
    const controller = new AbortController();
    load(controller.signal);
    return () => controller.abort();
  }, [load, reloadKey]);
  useEffect(() => { setSelected(new Set()); }, [filter]);

  const rows = data?.rows?.items || [];
  const c = data?.counts;
  const done = (r) => { setActing(null); setNotice({ kind: 'good', text: r?.message || 'Saved.' }); setReloadKey((k) => k + 1); };
  const openClaim = (r) => !client && navigate(`/claims/${r.claimKey}`, { state: { from: '/cip' } });
  const selectedRows = rows.filter((r) => selected.has(r.cipCaseId));
  const actionable = selectedRows.filter((r) => r.caseStatus === 'Pending Approval' || r.caseStatus === 'Client Responded');

  async function runBulk() {
    if (bulk === 'sendback' && !bulkNote.trim()) { setError('Add a reason - it is applied to every case sent back.'); return; }
    setBusy(true);
    try {
      const r = await arWorkbenchService.cipBulk(labId, [...selected], bulk, bulkNote.trim() || null);
      setBulk(null);
      setBulkNote('');
      setNotice({ kind: 'good', text: r.message });
      setReloadKey((k) => k + 1);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  const columns = [
    { key: 'claimID', label: 'Claim ID', sortKey: 'claimId', render: (r) => <span className="mono">{r.claimID}</span> },
    { key: 'caseNumber', label: 'Case', defaultHidden: !client, render: (r) => <span className="mono">{r.caseNumber}</span> },
    ...(client ? [
      { key: 'patientID', label: 'Patient Acct' },
      { key: 'dateOfService', label: 'DOS', render: (r) => fmt.date(r.dateOfService), csv: (r) => fmt.date(r.dateOfService) }
    ] : [{ key: 'labName', label: 'Client' }]),
    { key: 'payerName', label: 'Payer', sortKey: 'payerName', wrap: true },
    { key: 'caseStatus', label: 'Status', sortKey: 'caseStatus', csv: (r) => r.caseStatus,
      render: (r) => <Badge className={CIP_BADGE[r.caseStatus]}>{r.caseStatus}{r.roundNumber > 1 ? ` · Round ${r.roundNumber}` : ''}</Badge> },
    { key: 'cipCategory', label: 'CIP Category', sortKey: 'cipCategory', wrap: true },
    { key: 'requiredInfo', label: 'Required Information', wrap: true },
    { key: 'cipComment', label: client ? 'Request' : 'AR Agent Request', wrap: true, render: (r) => <span className="arwb-clamp-2">{r.cipComment}</span>, csv: (r) => r.cipComment },
    ...(!client ? [
      { key: 'insuranceBalance', label: 'Ins. Balance', align: 'end', sortKey: 'insuranceBalance', render: (r) => <span className="mono">{fmt.money(r.insuranceBalance)}</span>, csv: (r) => r.insuranceBalance },
      { key: 'arQueueLabel', label: 'Current AR Queue', render: (r) => (r.arQueueLabel ? <Badge className={arQueueBadgeClass(r.arQueueId)}>{r.arQueueLabel}</Badge> : '—') },
      { key: 'requestedBy', label: 'Requested By', sortKey: 'requestedBy' }
    ] : []),
    { key: 'requestedOn', label: 'Logged Date', sortKey: 'requestedOn', render: (r) => fmt.date(r.followUpDate || r.requestedOn), csv: (r) => fmt.date(r.followUpDate || r.requestedOn) },
    { key: 'clientResponseText', label: client ? 'Your Response' : 'Client Response', wrap: true, csv: (r) => r.clientResponseText || '',
      render: (r) => (r.clientResponseText
        ? <span><span className="arwb-clamp-2">{r.clientResponseText}</span><div className="arwb-hint">{r.clientRespondedBy} · {fmt.date(r.clientRespondedOn)}</div></span>
        : <span className="text-muted-ink">—</span>) },
    { key: 'attachments', label: 'Attachments', csv: (r) => (r.attachments || []).map((a) => a.fileName).join('; '),
      render: (r) => <Attachments labId={labId} files={r.attachments} /> },
    { key: 'action', label: 'Action', align: 'end', csv: () => '',
      render: (r) => {
        const btn = (label, mode, primary = true) => (
          <button type="button" className={`arwb-btn arwb-btn-sm${primary ? ' arwb-btn-primary' : ''}`} onClick={(e) => { e.stopPropagation(); setActing({ row: r, mode }); }}>{label}</button>
        );
        if (client) return r.caseStatus === 'Sent to Client' ? btn('Respond', 'respond') : <span className="text-muted-ink">{r.caseStatus === 'Client Responded' ? 'Under review' : 'Closed'}</span>;
        if (r.caseStatus === 'Pending Approval') return btn('Review & Approve', 'approval');
        if (r.caseStatus === 'Client Responded') return btn('Review Response', 'review');
        return <button type="button" className="arwb-btn arwb-btn-sm" onClick={(e) => { e.stopPropagation(); openClaim(r); }}>Open Claim</button>;
      } }
  ];

  const tiles = client
    ? [['Awaiting Your Response', c?.sentToClient], ['Responded — Under Review', c?.clientResponded], ['Closed', c?.returnedToAgent]]
    : [['Pending Your Approval', c?.pendingApproval], ['Awaiting Client', c?.sentToClient], ['Client Responded — Needs Review', c?.clientResponded],
      ['Returned to Agent', c?.returnedToAgent], ['Awaiting QA', c?.awaitingQa]];

  return (
    <>
      <div className="arwb-card arwb-section" style={{ padding: 16 }}>
        <div className="arwb-hint">
          {client
            ? 'Your AR team needs information to resolve these claims. Respond with what is requested; the team reviews your answer and either continues with the claim or asks again.'
            : 'Every follow-up note logged with Fix / Resolution "CIP - Client Escalations" opens a case here once QA approves the note: approve it to send the CIP Category, Required Information and CIP Comment to the client, review what they send back, and either return the claim to the AR agent or re-escalate with a reason.'}
        </div>
        <div className="arwb-grid arwb-grid-kpi" style={{ marginTop: 12 }}>
          {tiles.map(([label, v]) => (
            <div key={label} className="arwb-kpi arwb-kpi-tile"><span className="arwb-kpi-label">{label}</span><span className="arwb-kpi-value mono">{c ? fmt.count(v) : '…'}</span></div>
          ))}
        </div>
      </div>

      <Notice notice={notice} onClose={() => setNotice(null)} />

      <div className="arwb-panel arwb-filter-card arwb-section">
        <div className="arwb-filter-bar">
          <div className="arwb-field grow">
            <label htmlFor="cip-search">Search</label>
            <input id="cip-search" type="search" className="arwb-input" maxLength={200} placeholder="Claim ID, case, patient acct…" value={searchText} onChange={(e) => setSearchText(e.target.value)} />
          </div>
          <MultiSelect id="cip-status" label="Status" options={statusOptions} selected={status} onChange={(v) => { setStatus(v); setQuery((q) => ({ ...q, page: 1 })); }} />
          <MultiSelect id="cip-category" label="CIP Category" options={categoryOptions} selected={category} onChange={(v) => { setCategory(v); setQuery((q) => ({ ...q, page: 1 })); }} />
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => { setStatus([]); setCategory([]); setSearchText(''); setSearch(''); }}>Clear Filters</button>
        </div>
      </div>

      <ErrorBox message={error} />

      <div className="arwb-card arwb-card-flush">
        <div className="arwb-card-head">
          <Icon name="warn" size={16} /><h3>{client ? 'Escalation Requests' : 'CIP — Client Escalations'}</h3>
          {!client && (user?.siteAdmin || ['admin', 'manager'].includes(user?.roleCode)) && (
            <div className="arwb-card-head-actions">
              <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => setConverting(true)} title="Bring the Denial Workflow's external escalations and responses in as CIP cases">
                <Icon name="refresh" size={15} /> Convert Denial Workflow Escalations
              </button>
            </div>
          )}
        </div>
        <DataTable
          tableId={client ? 'client-cip-v1' : 'cip-v1'}
          exportName={client ? 'escalation-requests' : 'cip-client-escalations'}
          columns={withSortKeys(columns, CIP_SORT_KEYS)}
          rows={rows}
          totalCount={data?.rows?.totalCount || 0}
          page={query.page}
          pageSize={query.pageSize}
          sortBy={query.sortBy}
          sortDesc={query.sortDesc}
          loading={loading}
          rowKey={(r) => r.cipCaseId}
          emptyText={client ? 'No escalation requests in this view.' : 'No CIP escalations in this view.'}
          onSort={(sortBy, sortDesc) => setQuery((q) => ({ ...q, sortBy, sortDesc, page: 1 }))}
          onPage={(page) => setQuery((q) => ({ ...q, page }))}
          onPageSize={(pageSize) => setQuery((q) => ({ ...q, pageSize, page: 1 }))}
          onRowClick={client ? undefined : openClaim}
          selectable={!client}
          selectedKeys={selected}
          onSelectionChange={setSelected}
          toolbar={!client && (
            <>
              <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!actionable.length} onClick={() => { setBulkNote(''); setBulk('approve'); }}>
                <Icon name="check" size={15} /> Bulk Approve Selected
              </button>
              <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-danger" disabled={!actionable.length} onClick={() => { setBulkNote(''); setBulk('sendback'); }}>
                Bulk Reject / Send Back Selected
              </button>
            </>
          )}
        />
      </div>

      {converting && (
        <LegacyConvertModal onClose={() => setConverting(false)}
          onDone={(r) => { setConverting(false); setNotice({ kind: 'good', text: r.message }); setReloadKey((k) => k + 1); }} />
      )}
      {acting && <CipActionModal row={acting.row} mode={acting.mode} onClose={() => setActing(null)} onDone={done} />}

      {bulk && (() => {
        const pending = actionable.filter((r) => r.caseStatus === 'Pending Approval').length;
        const responded = actionable.filter((r) => r.caseStatus === 'Client Responded').length;
        const skipped = selected.size - pending - responded;
        return (
          <Modal title={bulk === 'approve' ? 'Bulk Approve Selected' : 'Bulk Reject / Send Back Selected'} busy={busy}
            submitLabel={`${bulk === 'approve' ? 'Approve' : 'Send Back'} ${pending + responded} Case${pending + responded === 1 ? '' : 's'}`}
            submitClass={bulk === 'approve' ? 'arwb-btn-primary' : 'arwb-btn-danger'} onClose={() => setBulk(null)} onSubmit={runBulk}>
            <div className="arwb-section-note" style={{ marginBottom: 12 }}>
              {pending > 0 && <div><Badge className="arwb-badge-warning">{pending} Pending Approval</Badge> — {bulk === 'approve' ? 'approved & sent to the client.' : 'rejected straight back to the AR agent (never sent to the client).'}</div>}
              {responded > 0 && <div style={{ marginTop: 6 }}><Badge className="arwb-badge-purple">{responded} Client Responded</Badge> — {bulk === 'approve' ? 'approved & returned to the AR agent.' : 'marked insufficient and re-sent to the client (round + 1).'}</div>}
              {skipped > 0 && <div style={{ marginTop: 6 }} className="arwb-hint">{skipped} selected item(s) are not awaiting a decision and will be skipped.</div>}
            </div>
            <div className="arwb-field">
              <label htmlFor="cip-bulk-note">{bulk === 'approve' ? 'Note (optional, applied to every case)' : 'Reason (required, applied to every case)'}</label>
              <textarea id="cip-bulk-note" className="arwb-input" rows={3} maxLength={4000} value={bulkNote} onChange={(e) => setBulkNote(e.target.value)} />
            </div>
          </Modal>
        );
      })()}
    </>
  );
}
