import { useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router';
import DataTable, { withSortKeys } from '../components/DataTable';
import { QA_SORT_KEYS } from '../config/sortKeys';
import Icon from '../components/Icon';
import Modal from '../components/Modal';
import MultiSelect from '../components/MultiSelect';
import QaDecisionModal from '../components/QaDecisionModal';
import { AgentName, Badge, ErrorBox, Notice } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

// QA Verification Queue (mockup App.views.qa). Every logged follow-up note lands here. Approve ->
// Completed (a CIP note -> its escalation Pending Approval; a Write Off -> Approved Write-Off);
// Reject -> back to the same agent under QA Rejected. Nobody may decide their own work.

const STATUS_BADGE = { 'Awaiting QA': 'arwb-badge-purple', Approved: 'arwb-badge-good', Rejected: 'arwb-badge-critical' };
const BLANK = { reviewStatus: ['Awaiting QA'], payer: [], panel: [], category: [], agent: [], reviewer: [] };
const STATUS_OPTIONS = ['Awaiting QA', 'Approved', 'Rejected'].map((s) => ({ value: s, label: s }));

export default function QaPage() {
  const { labId } = useWorkbench();
  const navigate = useNavigate();
  const [lists, setLists] = useState(BLANK);
  const [escalation, setEscalation] = useState('');
  const [searchText, setSearchText] = useState('');
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState({ page: 1, pageSize: 50, sortBy: 'submittedOn', sortDesc: false });
  const [data, setData] = useState(null);
  const [options, setOptions] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState(null);
  const [selected, setSelected] = useState(() => new Set());
  const [deciding, setDeciding] = useState(null);       // { row, decision }
  const [bulkConfirm, setBulkConfirm] = useState(false);
  const [busy, setBusy] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    const t = setTimeout(() => { if (searchText.trim() !== search) { setSearch(searchText.trim()); setQuery((q) => ({ ...q, page: 1 })); } }, 400);
    return () => clearTimeout(t);
  }, [searchText]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    const controller = new AbortController();
    arWorkbenchService.claimFilterOptions(labId, controller.signal).then(setOptions).catch(() => {});
    return () => controller.abort();
  }, [labId]);

  const filter = useMemo(() => ({ labId, ...lists, escalation, search, ...query }), [labId, lists, escalation, search, query]);

  const load = useCallback((signal) => {
    setLoading(true);
    setError('');
    return arWorkbenchService.qaQueue(filter, signal)
      .then((r) => { setData(r); setLoading(false); })
      .catch((e) => { if (e.name !== 'AbortError') { setError(e.message); setLoading(false); } });
  }, [filter]);

  useEffect(() => {
    const controller = new AbortController();
    load(controller.signal);
    return () => controller.abort();
  }, [load, reloadKey]);

  useEffect(() => { setSelected(new Set()); }, [filter]);

  const rows = data?.rows?.items || [];
  const s = data?.summary;
  const setList = (k, v) => { setLists((l) => ({ ...l, [k]: v })); setQuery((q) => ({ ...q, page: 1 })); };
  const decidable = (r) => r.reviewStatus === 'Awaiting QA' && !r.isOwnWork;
  const openClaim = (r) => navigate(`/claims/${r.claimKey}`, { state: { from: '/qa' } });
  const done = (r) => { setDeciding(null); setNotice({ kind: 'good', text: r?.message || 'Saved.' }); setReloadKey((k) => k + 1); };

  const selectedRows = rows.filter((r) => selected.has(r.claimKey));
  async function bulkApprove() {
    setBusy(true);
    try {
      const r = await arWorkbenchService.qaBulkApprove(labId, [...selected]);
      setBulkConfirm(false);
      setNotice({ kind: r.approved ? 'good' : 'info', text: r.message });
      setReloadKey((k) => k + 1);
    } catch (e) {
      setError(e.message);
      setBulkConfirm(false);
    } finally {
      setBusy(false);
    }
  }

  const columns = [
    { key: 'claimID', label: 'Claim ID', sortKey: 'claimId',
      render: (r) => <button type="button" className="arwb-claim-link" onClick={(e) => { e.stopPropagation(); openClaim(r); }}>{r.claimID}</button> },
    { key: 'labName', label: 'Client', defaultHidden: true },
    { key: 'agent', label: 'Agent', sortKey: 'agent', render: (r) => <AgentName name={r.assignedAgentName} />, csv: (r) => r.assignedAgentName || '' },
    { key: 'payerName', label: 'Payer', sortKey: 'payerName', wrap: true, defaultHidden: true },
    { key: 'denialCategory', label: 'Denial Category', sortKey: 'denialCategory', wrap: true },
    { key: 'insuranceBalance', label: 'Ins. Balance', align: 'end', sortKey: 'insuranceBalance', render: (r) => <span className="mono">{fmt.money(r.insuranceBalance)}</span>, csv: (r) => r.insuranceBalance },
    { key: 'note', label: 'Note under review', wrap: true,
      render: (r) => <span><b>{r.fixResolution || '—'}</b>{r.followUpClaimStatus ? <span className="arwb-hint"> · {r.followUpClaimStatus}</span> : null}{r.followUpComment ? <div className="arwb-hint arwb-clamp-2">{r.followUpComment}</div> : null}</span>,
      csv: (r) => `${r.fixResolution || ''} | ${r.followUpComment || ''}` },
    { key: 'submittedOn', label: 'Agent Completed', sortKey: 'submittedOn', render: (r) => fmt.dateTime(r.submittedOn), csv: (r) => r.submittedOn },
    { key: 'reviewStatus', label: 'QA Status', sortKey: 'reviewStatus', render: (r) => <Badge className={STATUS_BADGE[r.reviewStatus]}>{r.reviewStatus}</Badge> },
    { key: 'escalation', label: 'Escalation', csv: (r) => (r.isEscalation ? 'CIP' : r.isWriteOff ? 'Write Off' : ''),
      render: (r) => (r.isEscalation ? <Badge className="arwb-badge-purple" dot>CIP Escalation</Badge> : r.isWriteOff ? <Badge className="arwb-badge-warning">Write Off</Badge> : <span className="text-muted-ink">—</span>) },
    { key: 'reviewer', label: 'QA Reviewer', sortKey: 'reviewer', render: (r) => r.reviewedBy || <span className="text-muted-ink">Unassigned</span>, csv: (r) => r.reviewedBy || '' },
    { key: 'errorType', label: 'Error Type', render: (r) => r.errorType || (r.reviewStatus === 'Approved' ? 'None' : '—') },
    { key: 'action', label: 'Action', align: 'end', csv: () => '',
      render: (r) => (decidable(r)
        ? (
          <span className="arwb-row-actions">
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={(e) => { e.stopPropagation(); setDeciding({ row: r, decision: 'approve' }); }}>Approve</button>
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-danger" onClick={(e) => { e.stopPropagation(); setDeciding({ row: r, decision: 'reject' }); }}>Reject</button>
          </span>
        )
        : <button type="button" className="arwb-btn arwb-btn-sm" title={r.isOwnWork && r.reviewStatus === 'Awaiting QA' ? 'Your own work: another reviewer must decide it' : undefined}
          onClick={(e) => { e.stopPropagation(); openClaim(r); }}>Review</button>) }
  ];

  return (
    <>
      <div className="arwb-grid arwb-grid-kpi arwb-section">
        {[['Awaiting QA', s?.awaitingQa], ['Escalations Pending Review', s?.escalationsPending], ['Write-Offs Pending Review', s?.writeOffsPending],
          ['QA Rejected', s?.rejected], ['Reject Rate', s?.rejectRate != null ? fmt.pct(s.rejectRate) : '—']].map(([label, v]) => (
          <div key={label} className="arwb-kpi arwb-kpi-tile">
            <span className="arwb-kpi-accent-bar" />
            <span className="arwb-kpi-label">{label}</span>
            <span className="arwb-kpi-value mono">{s ? (typeof v === 'number' ? fmt.count(v) : v) : '…'}</span>
          </div>
        ))}
      </div>

      <Notice notice={notice} onClose={() => setNotice(null)} />

      <div className="arwb-panel arwb-filter-card arwb-section">
        <div className="arwb-filter-bar">
          <div className="arwb-field grow">
            <label htmlFor="qa-search">Search</label>
            <input id="qa-search" type="search" className="arwb-input" maxLength={200} placeholder="Claim ID, agent, payer…" value={searchText} onChange={(e) => setSearchText(e.target.value)} />
          </div>
          <MultiSelect id="qa-status" label="QA Status" options={STATUS_OPTIONS} selected={lists.reviewStatus} onChange={(v) => setList('reviewStatus', v)} />
          <MultiSelect id="qa-payer" label="Payer" options={options?.payers || []} selected={lists.payer} onChange={(v) => setList('payer', v)} />
          <MultiSelect id="qa-panel" label="Panel Type" options={options?.panels || []} selected={lists.panel} onChange={(v) => setList('panel', v)} />
          <MultiSelect id="qa-category" label="Denial Category" options={options?.categories || []} selected={lists.category} onChange={(v) => setList('category', v)} />
          <MultiSelect id="qa-agent" label="Agent" options={(options?.agents || []).filter((a) => a.value !== '__unassigned')} selected={lists.agent} onChange={(v) => setList('agent', v)} />
          <MultiSelect id="qa-reviewer" label="QA Reviewer" options={data?.reviewers || []} selected={lists.reviewer} onChange={(v) => setList('reviewer', v)} />
          <div className="arwb-field">
            <label htmlFor="qa-esc">Escalation</label>
            <select id="qa-esc" className="arwb-select" value={escalation} onChange={(e) => { setEscalation(e.target.value); setQuery((q) => ({ ...q, page: 1 })); }}>
              <option value="">All</option><option value="yes">CIP escalations</option><option value="no">Not escalations</option>
            </select>
          </div>
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost"
            onClick={() => { setLists(BLANK); setEscalation(''); setSearchText(''); setSearch(''); setQuery((q) => ({ ...q, page: 1 })); }}>Clear Filters</button>
        </div>
      </div>

      <ErrorBox message={error} />

      <div className="arwb-card arwb-card-flush">
        <div className="arwb-card-head"><Icon name="check" size={16} /><h3>QA Verification Queue</h3><span className="arwb-card-sub">an agent may not approve their own work</span></div>
        <DataTable
          tableId="qa-v1"
          exportName="qa-verification-queue"
          columns={withSortKeys(columns, QA_SORT_KEYS)}
          rows={rows}
          totalCount={data?.rows?.totalCount || 0}
          page={query.page}
          pageSize={query.pageSize}
          sortBy={query.sortBy}
          sortDesc={query.sortDesc}
          loading={loading}
          emptyText="Nothing waiting for QA in this view."
          onSort={(sortBy, sortDesc) => setQuery((q) => ({ ...q, sortBy, sortDesc, page: 1 }))}
          onPage={(page) => setQuery((q) => ({ ...q, page }))}
          onPageSize={(pageSize) => setQuery((q) => ({ ...q, pageSize, page: 1 }))}
          onRowClick={openClaim}
          selectable
          selectedKeys={selected}
          onSelectionChange={(keys) => setSelected(new Set([...keys].filter((k) => { const r = rows.find((x) => x.claimKey === k); return !r || decidable(r); })))}
          toolbar={(
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!selected.size} onClick={() => setBulkConfirm(true)}>
              <Icon name="check" size={15} /> Approve Selected{selected.size ? ` (${fmt.count(selected.size)})` : ''}
            </button>
          )}
        />
      </div>

      {deciding && <QaDecisionModal row={deciding.row} decision={deciding.decision} onClose={() => setDeciding(null)} onDone={done} />}

      {bulkConfirm && (
        <Modal title="Approve Selected" submitLabel="Approve" busy={busy} busyLabel="Approving…" onClose={() => setBulkConfirm(false)} onSubmit={bulkApprove}>
          <p>
            Approve <b>{fmt.count(selected.size)}</b> selected claim{selected.size === 1 ? '' : 's'} totaling{' '}
            <b>{fmt.money(selectedRows.reduce((sum, r) => sum + (r.insuranceBalance || 0), 0))}</b> insurance AR?
          </p>
          {selectedRows.some((r) => r.isEscalation) && (
            <p className="arwb-hint">{selectedRows.filter((r) => r.isEscalation).length} of these are CIP escalations and will move to Pending Approval in CIP Escalations.</p>
          )}
          {selectedRows.some((r) => r.isWriteOff) && (
            <p className="arwb-hint">{selectedRows.filter((r) => r.isWriteOff).length} are Write Offs and become Approved Write-Offs to post in the PMS.</p>
          )}
          <p className="arwb-hint">Claims you worked yourself or that were decided meanwhile are skipped and counted.</p>
        </Modal>
      )}
    </>
  );
}
