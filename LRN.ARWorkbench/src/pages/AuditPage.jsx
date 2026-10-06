import { useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router';
import DataTable from '../components/DataTable';
import Icon from '../components/Icon';
import MultiSelect from '../components/MultiSelect';
import { Badge, ErrorBox } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

// Audit Logs (mockup App.views.audit): every workflow-changing action across claims, from the
// claim activity spine. Filters: search, user, action, client, date range, and whether to include
// the data sync's system entries. Rows open the claim. Export downloads every match as Excel.

const BLANK = { user: [], action: [], client: [] };

export default function AuditPage() {
  const { labId } = useWorkbench();
  const navigate = useNavigate();
  const [lists, setLists] = useState(BLANK);
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [includeSystem, setIncludeSystem] = useState(false);
  const [searchText, setSearchText] = useState('');
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState({ page: 1, pageSize: 50, sortBy: 'activityOn', sortDesc: true });
  const [data, setData] = useState(null);
  const [options, setOptions] = useState(null);
  const [loading, setLoading] = useState(true);
  const [exporting, setExporting] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    const t = setTimeout(() => { if (searchText.trim() !== search) { setSearch(searchText.trim()); setQuery((q) => ({ ...q, page: 1 })); } }, 400);
    return () => clearTimeout(t);
  }, [searchText]); // eslint-disable-line react-hooks/exhaustive-deps

  const filter = useMemo(() => ({ labId, ...lists, from: from || null, to: to || null, includeSystem, search, ...query }),
    [labId, lists, from, to, includeSystem, search, query]);

  const load = useCallback((signal) => {
    setLoading(true);
    setError('');
    return arWorkbenchService.auditLog({ ...filter, options: !options }, signal)
      .then((r) => {
        setData(r);
        if (!options) setOptions({ users: r.users, actions: r.actions, clients: r.clients });
        setLoading(false);
      })
      .catch((e) => { if (e.name !== 'AbortError') { setError(e.message); setLoading(false); } });
  }, [filter]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    const controller = new AbortController();
    load(controller.signal);
    return () => controller.abort();
  }, [load]);

  const setList = (k, v) => { setLists((l) => ({ ...l, [k]: v })); setQuery((q) => ({ ...q, page: 1 })); };
  const openClaim = (r) => navigate(`/claims/${r.claimKey}`, { state: { from: '/audit' } });

  async function exportAll() {
    setExporting(true);
    try {
      const { page, pageSize, ...rest } = filter; // eslint-disable-line no-unused-vars
      await arWorkbenchService.auditExport(rest);
    } catch (e) {
      setError(e.message);
    } finally {
      setExporting(false);
    }
  }

  const columns = [
    { key: 'activityOn', label: 'Timestamp', sortKey: 'activityOn', render: (r) => fmt.dateTime(r.activityOn), csv: (r) => r.activityOn },
    { key: 'claimID', label: 'Claim ID', sortKey: 'claimId',
      render: (r) => <button type="button" className="arwb-claim-link" onClick={(e) => { e.stopPropagation(); openClaim(r); }}>{r.claimID}</button> },
    { key: 'labName', label: 'Client', sortKey: 'labName' },
    { key: 'userName', label: 'User', sortKey: 'userName', render: (r) => <>{r.userName}{r.isSystem && <> <Badge>System</Badge></>}</> },
    { key: 'roleCode', label: 'Role', render: (r) => r.roleCode || '—' },
    { key: 'actionType', label: 'Action', sortKey: 'actionType' },
    { key: 'previousValue', label: 'Previous Value', wrap: true, render: (r) => r.previousValue ?? '—' },
    { key: 'newValue', label: 'New Value', wrap: true, render: (r) => r.newValue ?? '—' },
    { key: 'detail', label: 'Description', wrap: true, render: (r) => <span className="arwb-clamp-2">{r.detail || '—'}</span>, csv: (r) => r.detail || '' }
  ];

  return (
    <>
      <div className="arwb-panel arwb-filter-card arwb-section">
        <div className="arwb-filter-bar">
          <div className="arwb-field grow">
            <label htmlFor="au-search">Search</label>
            <input id="au-search" type="search" className="arwb-input" maxLength={200} placeholder="Claim ID, user, action, description…" value={searchText}
              onChange={(e) => setSearchText(e.target.value)} />
          </div>
          <MultiSelect id="au-user" label="User" options={options?.users || []} selected={lists.user} onChange={(v) => setList('user', v)} searchable />
          <MultiSelect id="au-action" label="Action" options={options?.actions || []} selected={lists.action} onChange={(v) => setList('action', v)} searchable />
          <MultiSelect id="au-client" label="Client" options={options?.clients || []} selected={lists.client} onChange={(v) => setList('client', v)} />
          <div className="arwb-field">
            <label htmlFor="au-from">From</label>
            <input id="au-from" type="date" className="arwb-input" value={from} onChange={(e) => { setFrom(e.target.value); setQuery((q) => ({ ...q, page: 1 })); }} />
          </div>
          <div className="arwb-field">
            <label htmlFor="au-to">To</label>
            <input id="au-to" type="date" className="arwb-input" value={to} onChange={(e) => { setTo(e.target.value); setQuery((q) => ({ ...q, page: 1 })); }} />
          </div>
          <div className="arwb-checkbox-row">
            <input id="au-system" type="checkbox" checked={includeSystem} onChange={(e) => { setIncludeSystem(e.target.checked); setQuery((q) => ({ ...q, page: 1 })); }} />
            <label htmlFor="au-system" title="The data sync's entries (claim identified, source data updated, auto-processing)">Include system entries</label>
          </div>
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost"
            onClick={() => { setLists(BLANK); setFrom(''); setTo(''); setIncludeSystem(false); setSearchText(''); setSearch(''); setQuery((q) => ({ ...q, page: 1 })); }}>Clear Filters</button>
        </div>
      </div>

      <ErrorBox message={error} />

      <div className="arwb-card arwb-card-flush">
        <div className="arwb-card-head"><Icon name="shield" size={16} /><h3>Audit Log</h3>
          <span className="arwb-card-sub">immutable trail of workflow-changing actions · {data ? `${fmt.count(data.rows.totalCount)} entries` : ''}</span></div>
        <DataTable
          tableId="audit-v1"
          exportName="audit-log"
          columns={columns}
          rows={data?.rows?.items || []}
          totalCount={data?.rows?.totalCount || 0}
          page={query.page}
          pageSize={query.pageSize}
          sortBy={query.sortBy}
          sortDesc={query.sortDesc}
          loading={loading}
          rowKey={(r) => r.activityId}
          emptyText="No audit entries match."
          onSort={(sortBy, sortDesc) => setQuery((q) => ({ ...q, sortBy, sortDesc, page: 1 }))}
          onPage={(page) => setQuery((q) => ({ ...q, page }))}
          onPageSize={(pageSize) => setQuery((q) => ({ ...q, pageSize, page: 1 }))}
          onRowClick={openClaim}
          toolbar={(
            <button type="button" className="arwb-btn arwb-btn-sm" disabled={exporting} onClick={exportAll} title="Every matching entry (up to 50,000) as Excel">
              {exporting ? <span className="arwb-spinner" /> : <Icon name="download" size={15} />} Export Excel
            </button>
          )}
        />
      </div>
    </>
  );
}
