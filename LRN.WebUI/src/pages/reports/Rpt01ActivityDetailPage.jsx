import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { denialWorkflowService } from '../../services/denialWorkflowService';

/**
 * RPT-01 — AR Follow-up Activity Detail.
 * Denial Workflow Management | AR Reporting Requirements v1.0, section 3.1.
 *
 * The audit/drill-down report behind the operational dashboards: one row per qualifying activity
 * event, with the summary measures that sit above it and the claim timeline it drills into.
 *
 * Two things this screen is deliberately careful about, because the spec is explicit and the
 * numbers are easy to misread:
 *   - Grain labels are never interchangeable. Every KPI says what it counts (activity events vs
 *     claim-days vs denial-line-days vs actions), because three same-day notes on one claim are
 *     three events and one claim-day.
 *   - The Due Status column is an AUDIT SNAPSHOT of the follow-up date that activity captured,
 *     judged at the as-of instant. It is not the current overdue backlog, which belongs to RPT-05.
 */

const REPORT_CODE = 'RPT-01';

function isoDay(date) {
  return new Date(date.getTime() - date.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
}

function defaultRange() {
  const today = new Date();
  const from = new Date(today);
  from.setDate(from.getDate() - 6);
  return { fromDate: isoDay(from), toDate: isoDay(today) };
}

const blankFilters = () => ({
  ...defaultRange(),
  analyst: '',
  manager: '',
  team: '',
  payer: '',
  denialClassification: '',
  actionCategory: '',
  task: '',
  workflowStatus: '',
  reportingBucket: '',
  agingBucket: '',
  dueStatus: '',
  escalationStatus: '',
  activityType: '',
  contactMethod: '',
  updateSource: '',
  searchText: '',
  grain: 'Claim',
  latestOnly: false,
  groupBy: 'none',
  sortBy: 'activityDate',
  sortDir: 'desc',
  page: 1,
  pageSize: 50
});

/** The API serialises camelCase, but read both casings so a serializer change cannot blank the grid. */
function pick(row, key) {
  if (!row) return undefined;
  if (row[key] !== undefined) return row[key];
  const pascal = key.charAt(0).toUpperCase() + key.slice(1);
  return row[pascal];
}

function text(row, key, fallback = '—') {
  const value = pick(row, key);
  return value === undefined || value === null || value === '' ? fallback : String(value);
}

function money(value) {
  const n = Number(value || 0);
  return n.toLocaleString(undefined, { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });
}

function moneyExact(value) {
  const n = Number(value || 0);
  return n.toLocaleString(undefined, { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function count(value) {
  return Number(value || 0).toLocaleString();
}

function dateTime(value) {
  if (!value) return '—';
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? String(value) : d.toLocaleString(undefined, { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function dayOnly(value) {
  if (!value) return '—';
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? String(value) : d.toLocaleDateString(undefined, { day: '2-digit', month: 'short', year: 'numeric' });
}

function bucketClass(bucket) {
  const b = String(bucket || '').toLowerCase();
  if (b.includes('active')) return 'active';
  if (b.includes('pending')) return 'pending';
  if (b.includes('escalat')) return 'escalated';
  if (b.includes('closed')) return 'closed';
  if (b.includes('unmapped')) return 'unmapped';
  return 'open';
}

function dueClass(due) {
  const d = String(due || '').toLowerCase();
  if (d.includes('overdue')) return 'overdue';
  if (d.includes('today')) return 'pending';
  if (d.includes('soon')) return 'pending';
  if (d.includes('no follow')) return 'unmapped';
  return 'open';
}

const GROUP_TABS = [
  { key: 'none', label: 'Detail' },
  { key: 'analyst', label: 'By Analyst' },
  { key: 'classification', label: 'By Classification' },
  { key: 'action', label: 'By Action' },
  { key: 'payer', label: 'By Payer' },
  { key: 'activityType', label: 'By Activity Type' }
];

/** Column order follows the spec's "Required detail columns" groups, left to right. */
const DETAIL_COLUMNS = [
  { key: 'activityId', label: 'Activity ID', group: 'Identification' },
  { key: 'claimId', label: 'Claim ID', group: 'Identification' },
  { key: 'lineItemId', label: 'Line Item ID', group: 'Identification' },
  { key: 'encounterNumber', label: 'Encounter', group: 'Identification' },
  { key: 'cptCode', label: 'CPT', group: 'Identification' },
  { key: 'dateOfService', label: 'DOS', group: 'Identification' },
  { key: 'payerName', label: 'Payer', group: 'Classification' },
  { key: 'denialClassification', label: 'Classification', group: 'Classification' },
  { key: 'denialReason', label: 'Denial Reason', group: 'Classification' },
  { key: 'reportingBucket', label: 'Reporting Bucket', group: 'Classification' },
  { key: 'agingBucket', label: 'AR Aging', group: 'Classification' },
  { key: 'analystName', label: 'AR Analyst', group: 'Assignment' },
  { key: 'managerName', label: 'AR Manager', group: 'Assignment' },
  { key: 'assignedOn', label: 'Assigned Date/Time', group: 'Assignment' },
  { key: 'assignedBy', label: 'Assigned By', group: 'Assignment' },
  { key: 'activityDate', label: 'Activity Date/Time', group: 'Activity' },
  { key: 'author', label: 'Author', group: 'Activity' },
  { key: 'activityType', label: 'Activity Type', group: 'Activity' },
  { key: 'contactMethod', label: 'Contact Method', group: 'Activity' },
  { key: 'noteText', label: 'Note Text', group: 'Activity' },
  { key: 'previousStatus', label: 'Previous Status', group: 'Workflow change' },
  { key: 'newStatus', label: 'New Status', group: 'Workflow change' },
  { key: 'statusReason', label: 'Status Reason', group: 'Workflow change' },
  { key: 'actionCategory', label: 'Action', group: 'Action' },
  { key: 'task', label: 'Task', group: 'Action' },
  { key: 'actionCompleted', label: 'Action Completed', group: 'Action' },
  { key: 'nextFollowUpDate', label: 'Next Follow-up', group: 'Follow-up' },
  { key: 'followUpCategory', label: 'Follow-up Category', group: 'Follow-up' },
  { key: 'originalFollowUpDate', label: 'Original Due', group: 'Follow-up' },
  { key: 'rescheduleCount', label: 'Reschedules', group: 'Follow-up' },
  { key: 'dueStatus', label: 'Due Status', group: 'Follow-up' },
  { key: 'escalated', label: 'Escalation', group: 'Escalation' },
  { key: 'originalCharge', label: 'Original Charge', group: 'Financial' },
  { key: 'balanceSnapshot', label: 'Balance', group: 'Financial' },
  { key: 'updateSource', label: 'Source', group: 'Audit' },
  { key: 'uploadBatchId', label: 'Batch / Run ID', group: 'Audit' }
];

function Select({ label, value, onChange, options, allLabel }) {
  return <label className="rpt-field">
    <span>{label}</span>
    <select value={value} onChange={e => onChange(e.target.value)}>
      <option value="">{allLabel}</option>
      {(options || []).map(x => <option key={x} value={x}>{x}</option>)}
    </select>
  </label>;
}

export default function Rpt01ActivityDetailPage({ labId, user, setMessage }) {
  const [draft, setDraft] = useState(blankFilters);
  const [query, setQuery] = useState(blankFilters);
  const [options, setOptions] = useState({});
  const [report, setReport] = useState(null);
  const [savedViews, setSavedViews] = useState([]);
  const [selectedClaim, setSelectedClaim] = useState('');
  const [timeline, setTimeline] = useState([]);
  const [timelineLoading, setTimelineLoading] = useState(false);
  const [loading, setLoading] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [saveViewOpen, setSaveViewOpen] = useState(false);
  const [saveViewName, setSaveViewName] = useState('');
  const [showNotes, setShowNotes] = useState(true);
  const requestSeq = useRef(0);
  // Held in a ref so `load` depends on labId alone. setMessage is stable today, but if it ever
  // stops being, a changing identity here would re-run the report on every parent render.
  const messageRef = useRef(setMessage);
  messageRef.current = setMessage;

  const metadata = report?.metadata || report?.Metadata || null;
  const summary = report?.summary || report?.Summary || {};
  const detail = report?.detail || report?.Detail || {};
  const rows = detail.items || detail.Items || [];
  const groups = report?.groups || report?.Groups || [];
  const totalCount = Number(detail.totalCount ?? detail.TotalCount ?? 0);
  const totalPages = Math.max(1, Math.ceil(totalCount / (query.pageSize || 50)));
  const emptyReason = report?.emptyStateReason || report?.EmptyStateReason || '';
  const grouped = query.groupBy !== 'none';
  const lineGrain = query.grain === 'Line';

  const load = useCallback(async (next) => {
    if (!labId) return;
    const seq = ++requestSeq.current;
    setLoading(true);
    try {
      const data = await denialWorkflowService.getRpt01({ ...next, labId });
      // A superseded request must not overwrite a newer one's results.
      if (seq !== requestSeq.current) return;
      setReport(data);
      const first = (data?.detail?.items || data?.Detail?.Items || [])[0];
      setSelectedClaim(prev => prev || (first ? String(pick(first, 'claimId') || '') : ''));
    } catch (err) {
      if (err?.name === 'AbortError' || seq !== requestSeq.current) return;
      messageRef.current?.({ type: 'danger', text: err.message || 'Unable to run RPT-01.' });
    } finally {
      if (seq === requestSeq.current) setLoading(false);
    }
  }, [labId]);

  useEffect(() => { load(query); }, [load, query]);

  useEffect(() => {
    if (!labId) return;
    let cancelled = false;
    (async () => {
      try {
        const [opts, views] = await Promise.all([
          denialWorkflowService.getRpt01FilterOptions(labId),
          denialWorkflowService.getRpt01SavedViews(labId).catch(() => [])
        ]);
        if (cancelled) return;
        setOptions(opts || {});
        setSavedViews(views || []);
      } catch (err) {
        if (!cancelled) messageRef.current?.({ type: 'warning', text: err.message || 'Report filter options are unavailable.' });
      }
    })();
    return () => { cancelled = true; };
  }, [labId]);

  useEffect(() => {
    if (!labId || !selectedClaim) { setTimeline([]); return; }
    let cancelled = false;
    setTimelineLoading(true);
    denialWorkflowService.getRpt01Timeline(labId, selectedClaim)
      .then(data => { if (!cancelled) setTimeline(data || []); })
      .catch(() => { if (!cancelled) setTimeline([]); })
      .finally(() => { if (!cancelled) setTimelineLoading(false); });
    return () => { cancelled = true; };
  }, [labId, selectedClaim]);

  function apply(overrides = {}) {
    setSelectedClaim('');
    setQuery({ ...draft, ...overrides, page: 1 });
  }

  function reset() {
    const next = blankFilters();
    setDraft(next);
    setSelectedClaim('');
    setQuery(next);
  }

  function patch(overrides) {
    setDraft(d => ({ ...d, ...overrides }));
    setQuery(q => ({ ...q, ...overrides, page: 1 }));
  }

  async function exportExcel() {
    setExporting(true);
    try {
      const url = await denialWorkflowService.getRpt01ExportUrl({ ...query, labId });
      const a = document.createElement('a');
      a.href = url;
      a.download = `RPT01_AR_Followup_Activity_Detail_${new Date().toISOString().slice(0, 10)}.xlsx`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      setMessage?.({ type: 'success', text: 'RPT-01 export downloaded. The workbook carries the applied filters, summary totals, detail rows and a reconciliation sheet.' });
    } catch (err) {
      setMessage?.({ type: 'danger', text: err.message || 'Unable to export RPT-01.' });
    } finally {
      setExporting(false);
    }
  }

  async function saveView() {
    const name = saveViewName.trim();
    if (!name) return;
    try {
      const saved = await denialWorkflowService.saveRpt01View({ labId, viewName: name, filtersJson: JSON.stringify(query), isDefault: false });
      setSavedViews(prev => [...prev.filter(v => (pick(v, 'viewName') || '') !== name), saved]);
      setSaveViewOpen(false);
      setSaveViewName('');
      setMessage?.({ type: 'success', text: `Saved view "${name}" stored for your account on this lab.` });
    } catch (err) {
      setMessage?.({ type: 'danger', text: err.message || 'Unable to save the view.' });
    }
  }

  function applySavedView(view) {
    try {
      const parsed = JSON.parse(pick(view, 'filtersJson') || '{}');
      const next = { ...blankFilters(), ...parsed, page: 1 };
      setDraft(next);
      setSelectedClaim('');
      setQuery(next);
    } catch {
      setMessage?.({ type: 'warning', text: 'That saved view could not be read and was skipped.' });
    }
  }

  async function removeView(view) {
    const id = pick(view, 'savedViewId');
    try {
      await denialWorkflowService.deleteRpt01View(id, labId);
      setSavedViews(prev => prev.filter(v => pick(v, 'savedViewId') !== id));
    } catch (err) {
      setMessage?.({ type: 'danger', text: err.message || 'Unable to remove the saved view.' });
    }
  }

  const appliedFilters = useMemo(() => metadata?.appliedFilters || metadata?.AppliedFilters || [], [metadata]);
  const unavailable = useMemo(() => metadata?.unavailableMeasures || metadata?.UnavailableMeasures || [], [metadata]);
  const fallbackBalanceRows = Number(pick(summary, 'rowsWithFallbackBalance') || 0);

  // The KPI row. Every tile names its own grain, because the spec forbids presenting claim counts,
  // line counts, event counts and action counts as interchangeable totals.
  const kpis = [
    { key: 'events', label: 'Activity Events', value: count(pick(summary, 'activityEvents')), note: 'Qualifying event rows after filters' },
    { key: 'claimDays', label: 'Distinct Claim-Days Worked', value: count(pick(summary, 'distinctClaimDaysWorked')), note: 'Claim + analyst + activity date', lead: !lineGrain },
    { key: 'lineDays', label: 'Distinct Line-Days Worked', value: count(pick(summary, 'distinctLineDaysWorked')), note: 'Denial line + analyst + activity date', lead: lineGrain },
    { key: 'actions', label: 'Actions Completed', value: count(pick(summary, 'actionsCompleted')), note: `${count(pick(summary, 'actionsCompletedFromEvents'))} backed by a completion event` },
    { key: 'balance', label: 'Balance Worked', value: money(pick(summary, 'balanceWorked')), note: 'Once per claim-day, never per note' },
    { key: 'escalations', label: 'Escalations Raised', value: count(pick(summary, 'escalationsRaised')), note: 'Raised events only; a response is separate' }
  ];

  return <section className="rpt01-page">
    <header className="rpt-head">
      <div>
        <h2>{REPORT_CODE} · AR Follow-up Activity Detail</h2>
        <p>Auditable event-level record of what meaningful AR follow-up work was performed, by whom, when, on which claim or denial line, and what changed as a result.</p>
      </div>
      <div className="rpt-head-actions">
        {savedViews.length > 0 && <div className="rpt-saved-views">
          <select value="" onChange={e => { const v = savedViews.find(x => String(pick(x, 'savedViewId')) === e.target.value); if (v) applySavedView(v); }}>
            <option value="">Saved views…</option>
            {savedViews.map(v => <option key={pick(v, 'savedViewId')} value={pick(v, 'savedViewId')}>{pick(v, 'viewName')}</option>)}
          </select>
        </div>}
        <button type="button" className="wl-btn xs" onClick={() => setSaveViewOpen(true)}><i className="bi bi-bookmark" /> Save View</button>
        <button type="button" className="wl-btn xs" onClick={reset}><i className="bi bi-arrow-counterclockwise" /> Reset</button>
        <button type="button" className="wl-btn xs teal" disabled={exporting || !totalCount} onClick={exportExcel}>
          <i className="bi bi-file-earmark-excel" /> {exporting ? 'Preparing…' : 'Export Excel'}
        </button>
      </div>
    </header>

    {/* FR-001 report run metadata. Shown on screen and written into every export. */}
    <div className="rpt-meta-strip">
      <div><span>Report Run ID</span><strong title={text(metadata, 'runId')}>{text(metadata, 'runId')}</strong></div>
      <div><span>As-of Date/Time</span><strong>{dateTime(pick(metadata, 'asOf'))}</strong></div>
      <div><span>Generated By</span><strong>{text(metadata, 'generatedBy', user?.userName || '—')}</strong></div>
      <div><span>Data Refresh</span><strong>{pick(metadata, 'dataRefreshedOn') ? dateTime(pick(metadata, 'dataRefreshedOn')) : 'Not available'}</strong></div>
      <div><span>Report Grain</span><strong>{text(metadata, 'grain', query.grain)}</strong></div>
      <div><span>Role View</span><strong>{text(metadata, 'roleView')}</strong></div>
    </div>

    <div className="rpt-filters">
      <div className="rpt-filters-head">
        <div className="rpt-filters-title">Filters</div>
        <div className="rpt-tabs" role="group" aria-label="Report grain">
          <button type="button" className={`rpt-tab ${query.grain === 'Claim' ? 'active' : ''}`} onClick={() => patch({ grain: 'Claim' })}>Claim Grain</button>
          <button type="button" className={`rpt-tab ${query.grain === 'Line' ? 'active' : ''}`} onClick={() => patch({ grain: 'Line' })}>Line Item Grain</button>
        </div>
      </div>

      <div className="rpt-filter-grid">
        <label className="rpt-field"><span>Activity From</span><input type="date" value={draft.fromDate} onChange={e => setDraft(d => ({ ...d, fromDate: e.target.value }))} /></label>
        <label className="rpt-field"><span>Activity To</span><input type="date" value={draft.toDate} onChange={e => setDraft(d => ({ ...d, toDate: e.target.value }))} /></label>
        <Select label="AR Analyst" allLabel="All Analysts" value={draft.analyst} options={options.analysts} onChange={v => setDraft(d => ({ ...d, analyst: v }))} />
        <Select label="AR Manager" allLabel="All Managers" value={draft.manager} options={options.managers} onChange={v => setDraft(d => ({ ...d, manager: v }))} />
        <Select label="Team" allLabel="All Teams" value={draft.team} options={options.teams} onChange={v => setDraft(d => ({ ...d, team: v }))} />
        <Select label="Payer" allLabel="All Payers" value={draft.payer} options={options.payers} onChange={v => setDraft(d => ({ ...d, payer: v }))} />
        <Select label="Denial Classification" allLabel="All Classifications" value={draft.denialClassification} options={options.denialClassifications} onChange={v => setDraft(d => ({ ...d, denialClassification: v }))} />
        <Select label="Action Category" allLabel="All Actions" value={draft.actionCategory} options={options.actionCategories} onChange={v => setDraft(d => ({ ...d, actionCategory: v }))} />
        <Select label="Task" allLabel="All Tasks" value={draft.task} options={options.tasks} onChange={v => setDraft(d => ({ ...d, task: v }))} />
        <Select label="Workflow Status" allLabel="All Statuses" value={draft.workflowStatus} options={options.workflowStatuses} onChange={v => setDraft(d => ({ ...d, workflowStatus: v }))} />
        <Select label="Reporting Bucket" allLabel="All Buckets" value={draft.reportingBucket} options={options.reportingBuckets} onChange={v => setDraft(d => ({ ...d, reportingBucket: v }))} />
        <Select label="AR Aging Bucket" allLabel="All Aging" value={draft.agingBucket} options={options.agingBuckets} onChange={v => setDraft(d => ({ ...d, agingBucket: v }))} />
        <Select label="Follow-up Due Status" allLabel="All Due Statuses" value={draft.dueStatus} options={options.dueStatuses} onChange={v => setDraft(d => ({ ...d, dueStatus: v }))} />
        <Select label="Escalation Status" allLabel="All Escalations" value={draft.escalationStatus} options={options.escalationStatuses} onChange={v => setDraft(d => ({ ...d, escalationStatus: v }))} />
        <Select label="Activity Type" allLabel="All Activity Types" value={draft.activityType} options={options.activityTypes} onChange={v => setDraft(d => ({ ...d, activityType: v }))} />
        <Select label="Contact Method" allLabel="All Contact Methods" value={draft.contactMethod} options={options.contactMethods} onChange={v => setDraft(d => ({ ...d, contactMethod: v }))} />
        <Select label="Update Source" allLabel="Application + Upload" value={draft.updateSource} options={options.updateSources} onChange={v => setDraft(d => ({ ...d, updateSource: v }))} />
        <label className="rpt-field"><span>Search</span><input type="search" placeholder="Claim, task, CPT, payer, note…" value={draft.searchText} onChange={e => setDraft(d => ({ ...d, searchText: e.target.value }))} onKeyDown={e => { if (e.key === 'Enter') apply(); }} /></label>
        <label className="rpt-field">
          <span>Activity Mode</span>
          <span className="rpt-toggle">
            {/* Latest Activity Only is an operational MODE, not a pending filter, so it re-runs
                immediately rather than waiting for Run Report. */}
            <input type="checkbox" checked={draft.latestOnly} onChange={e => patch({ latestOnly: e.target.checked })} />
            <span>Latest Activity Only</span>
          </span>
        </label>
        <div className="rpt-filter-actions">
          <button type="button" className="wl-btn xs teal" onClick={() => apply()}>Run Report</button>
          <button type="button" className="wl-btn xs" onClick={reset}>Clear</button>
        </div>
      </div>

      {appliedFilters.length > 0 && <div className="rpt-applied">
        <span>Applied filters:</span>
        {appliedFilters.map((f, i) => <span className="rpt-chip" key={`${pick(f, 'label')}-${i}`}><b>{pick(f, 'label')}:</b> {pick(f, 'value')}</span>)}
      </div>}
    </div>

    <div className="rpt-kpi-grid">
      {kpis.map(k => <div className={`rpt-kpi ${k.lead ? 'lead' : ''}`} key={k.key}>
        <div className="rpt-kpi-label">{k.label}</div>
        <div className="rpt-kpi-value">{k.value}</div>
        <div className="rpt-kpi-note">{k.note}</div>
      </div>)}
    </div>

    {(fallbackBalanceRows > 0 || unavailable.length > 0) && <details className="rpt-caveats">
      <summary>
        Data availability notes
        {fallbackBalanceRows > 0 && <em> · {count(fallbackBalanceRows)} row(s) show the current balance rather than a captured snapshot</em>}
      </summary>
      <ul>
        {unavailable.map((note, i) => <li key={i}>{note}</li>)}
        <li>Historical due dates in these rows are audit snapshots. Current overdue backlog must be read from the follow-up due report, not from here.</li>
      </ul>
    </details>}

    <div className="rpt-content">
      <div className="rpt-panel">
        <div className="rpt-panel-head">
          <div>
            <div className="rpt-panel-title">Activity Event Detail</div>
            <div className="rpt-panel-sub">
              {loading ? 'Running…' : `${count(totalCount)} activity event${totalCount === 1 ? '' : 's'} after filters`}
              {query.latestOnly ? ' · Latest Activity Only' : ''}
            </div>
          </div>
          <div className="rpt-tabs">
            {GROUP_TABS.map(t => <button
              key={t.key}
              type="button"
              className={`rpt-tab ${query.groupBy === t.key ? 'active' : ''}`}
              onClick={() => patch({ groupBy: t.key })}
            >{t.label}</button>)}
          </div>
        </div>

        {loading && <div className="loading-line" />}

        {grouped ? <div className="rpt-table-wrap">
          <table className="rpt-table">
            <thead>
              <tr>
                <th>{GROUP_TABS.find(t => t.key === query.groupBy)?.label.replace('By ', '') || 'Group'}</th>
                <th className="r">Activity Events</th>
                <th className="r">Claim-Days</th>
                <th className="r">Line-Days</th>
                <th className="r">Distinct Claims</th>
                <th className="r">Actions Completed</th>
                <th className="r">Escalations</th>
                <th className="r">Balance Worked</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {groups.length ? groups.map(g => <tr key={pick(g, 'groupKey')}>
                <td><strong>{text(g, 'groupLabel')}</strong></td>
                <td className="r">{count(pick(g, 'activityEvents'))}</td>
                <td className="r">{count(pick(g, 'distinctClaimDaysWorked'))}</td>
                <td className="r">{count(pick(g, 'distinctLineDaysWorked'))}</td>
                <td className="r">{count(pick(g, 'distinctClaims'))}</td>
                <td className="r">{count(pick(g, 'actionsCompleted'))}</td>
                <td className="r">{count(pick(g, 'escalationsRaised'))}</td>
                <td className="r">{moneyExact(pick(g, 'balanceWorked'))}</td>
                <td>
                  {/* Drill-down retains the clicked context (FR-010): the group value becomes the
                      matching filter and the view drops back to the underlying rows. */}
                  <button type="button" className="wl-btn xs" onClick={() => {
                    const key = String(pick(g, 'groupKey') || '');
                    const target = { analyst: 'analyst', classification: 'denialClassification', action: 'actionCategory', payer: 'payer', activityType: 'activityType' }[query.groupBy];
                    const next = { ...draft, groupBy: 'none', page: 1 };
                    if (target && !key.startsWith('(')) next[target] = key;
                    setDraft(next);
                    setSelectedClaim('');
                    setQuery(next);
                  }}>View rows</button>
                </td>
              </tr>) : <tr><td colSpan={9} className="rpt-empty">No grouped rows for the selected filters.</td></tr>}
            </tbody>
          </table>
        </div> : <>
          <div className="rpt-table-controls">
            <label className="rpt-inline-toggle">
              <input type="checkbox" checked={showNotes} onChange={e => setShowNotes(e.target.checked)} />
              <span>Show note text</span>
            </label>
            <label className="rpt-inline-toggle">
              <span>Rows per page</span>
              <select value={query.pageSize} onChange={e => setQuery(q => ({ ...q, pageSize: Number(e.target.value), page: 1 }))}>
                {[25, 50, 100, 200].map(n => <option key={n} value={n}>{n}</option>)}
              </select>
            </label>
          </div>
          <div className="rpt-table-wrap">
            <table className="rpt-table rpt-detail-table">
              <thead>
                <tr>
                  {DETAIL_COLUMNS.filter(c => showNotes || c.key !== 'noteText').map(c => <th
                    key={c.key}
                    title={`${c.group} · ${c.label}`}
                    className={['originalCharge', 'balanceSnapshot', 'rescheduleCount'].includes(c.key) ? 'r' : ''}
                  >{c.label}</th>)}
                </tr>
              </thead>
              <tbody>
                {rows.length ? rows.map(row => {
                  const claimId = String(pick(row, 'claimId') || '');
                  const isSelected = claimId && claimId === selectedClaim;
                  return <tr key={pick(row, 'activityId')} className={isSelected ? 'selected' : ''} onClick={() => setSelectedClaim(claimId)}>
                    <td className="mono">{text(row, 'activityId')}</td>
                    <td><button type="button" className="rpt-link" onClick={e => { e.stopPropagation(); setSelectedClaim(claimId); }}>{claimId || '—'}</button></td>
                    <td className="mono">{text(row, 'lineItemId')}</td>
                    <td>{text(row, 'encounterNumber')}</td>
                    <td className="mono">{text(row, 'cptCode')}</td>
                    <td>{dayOnly(pick(row, 'dateOfService'))}</td>
                    <td>{text(row, 'payerName')}</td>
                    <td>{text(row, 'denialClassification')}</td>
                    <td className="wrap">{text(row, 'denialReason')}</td>
                    <td><span className={`rpt-badge ${bucketClass(pick(row, 'reportingBucket'))}`}>{text(row, 'reportingBucket')}</span></td>
                    <td>{text(row, 'agingBucket')}</td>
                    <td>{text(row, 'analystName')}</td>
                    <td>{text(row, 'managerName', 'Not on file')}</td>
                    <td>{dateTime(pick(row, 'assignedOn'))}</td>
                    <td>{text(row, 'assignedBy')}</td>
                    <td>{dateTime(pick(row, 'activityDate'))}</td>
                    <td>{text(row, 'author')}</td>
                    <td><span className="rpt-badge type">{text(row, 'activityType')}</span></td>
                    <td>{text(row, 'contactMethod')}</td>
                    {showNotes && <td className={`wrap note ${pick(row, 'noteMasked') ? 'masked' : ''}`}>{text(row, 'noteText', '')}</td>}
                    <td>{text(row, 'previousStatus')}</td>
                    <td>{text(row, 'newStatus')}</td>
                    <td className="wrap">{text(row, 'statusReason')}</td>
                    <td>{text(row, 'actionCategory')}</td>
                    <td className="wrap">{text(row, 'task')}</td>
                    <td>
                      {pick(row, 'actionCompleted')
                        ? <span title={pick(row, 'actionCompletionIsEvent') ? 'Backed by a completion event' : 'From the current task-board flag — no completion event exists'}>
                            Yes{pick(row, 'actionCompletionIsEvent') ? '' : ' *'}<br />
                            <small>{dateTime(pick(row, 'actionCompletedOn'))}</small>
                          </span>
                        : 'No'}
                    </td>
                    <td>{dayOnly(pick(row, 'nextFollowUpDate'))}</td>
                    <td>{text(row, 'followUpCategory')}</td>
                    <td>{dayOnly(pick(row, 'originalFollowUpDate'))}</td>
                    <td className="r">{count(pick(row, 'rescheduleCount'))}</td>
                    <td><span className={`rpt-badge ${dueClass(pick(row, 'dueStatus'))}`}>{text(row, 'dueStatus')}</span></td>
                    <td className="wrap">
                      {pick(row, 'escalated')
                        ? <>Yes · {text(row, 'escalationReason')}<br /><small>{text(row, 'escalationId')} → {text(row, 'escalationRecipient')}</small></>
                        : 'No'}
                    </td>
                    <td className="r">{moneyExact(pick(row, 'originalCharge'))}</td>
                    <td className="r" title={pick(row, 'balanceIsSnapshot') ? 'Snapshot captured at the activity' : 'Current balance — this event predates snapshot capture'}>
                      {moneyExact(pick(row, 'balanceSnapshot'))}{pick(row, 'balanceIsSnapshot') ? '' : ' *'}
                    </td>
                    <td><span className={`rpt-badge ${String(pick(row, 'updateSource') || '').includes('Excel') ? 'upload' : 'app'}`}>{text(row, 'updateSource')}</span></td>
                    <td className="mono">{text(row, 'uploadBatchId', text(row, 'runId'))}</td>
                  </tr>;
                }) : <tr>
                  <td colSpan={DETAIL_COLUMNS.length} className="rpt-empty">
                    {loading ? 'Running the report…' : (emptyReason || 'No activity events matched the selected filters.')}
                  </td>
                </tr>}
              </tbody>
            </table>
          </div>
        </>}

        <div className="rpt-panel-foot">
          <span>Export includes applied filters, summary totals, detail rows, run ID, generation metadata and a reconciliation sheet.</span>
          <span>* marks a value read from current state rather than a captured event.</span>
        </div>

        {!grouped && <div className="pager">
          <button className="wl-btn xs" disabled={query.page <= 1 || loading} onClick={() => setQuery(q => ({ ...q, page: Math.max(1, q.page - 1) }))}>Previous</button>
          <span>Page {query.page} of {totalPages}</span>
          <button className="wl-btn xs" disabled={query.page >= totalPages || loading} onClick={() => setQuery(q => ({ ...q, page: q.page + 1 }))}>Next</button>
        </div>}
      </div>

      {/* Drill-down: Summary KPI → Analyst / Classification / Action → Claim → Denial Line →
          complete activity timeline (spec section 3.1 drill-down path). */}
      <aside className="rpt-panel rpt-side">
        <div className="rpt-panel-head">
          <div>
            <div className="rpt-panel-title">Claim Activity Timeline</div>
            <div className="rpt-panel-sub">{selectedClaim ? `Claim ${selectedClaim}` : 'Select a row to drill in'}</div>
          </div>
        </div>
        <div className="rpt-timeline">
          {timelineLoading && <div className="rpt-empty">Loading timeline…</div>}
          {!timelineLoading && !timeline.length && <div className="rpt-empty">{selectedClaim ? 'No activity recorded for this claim.' : 'Choose an activity row to see the full claim timeline, including events outside the current filter window.'}</div>}
          {!timelineLoading && timeline.map(item => <article className="rpt-timeline-item" key={pick(item, 'activityId')}>
            <div className="rpt-timeline-title">{text(item, 'activityType')}</div>
            <div className="rpt-timeline-meta">
              {dateTime(pick(item, 'activityDate'))} · {text(item, 'author')}
              {pick(item, 'lineItemId') ? <> · Line {text(item, 'lineItemId')}</> : null}
              {pick(item, 'cptCode') ? <> · CPT {text(item, 'cptCode')}</> : null}
            </div>
            {(pick(item, 'previousStatus') || pick(item, 'newStatus')) && <div className="rpt-timeline-status">
              {text(item, 'previousStatus', '—')} → {text(item, 'newStatus', '—')}
            </div>}
            <p className={pick(item, 'noteMasked') ? 'masked' : ''}>{text(item, 'noteText', '')}</p>
            <div className="rpt-timeline-audit">
              <span className={`rpt-badge ${String(pick(item, 'updateSource') || '').includes('Excel') ? 'upload' : 'app'}`}>{text(item, 'updateSource')}</span>
              {pick(item, 'runId') ? <small>Run {text(item, 'runId')}</small> : null}
            </div>
          </article>)}
        </div>
      </aside>
    </div>

    {saveViewOpen && <div className="modal-backdrop" onClick={e => { if (e.target === e.currentTarget) setSaveViewOpen(false); }}>
      <div className="rpt-save-modal">
        <div className="claim-modal-header">
          <div className="claim-modal-title">Save current view</div>
          <button type="button" className="modal-close" onClick={() => setSaveViewOpen(false)}><i className="bi bi-x-lg" /></button>
        </div>
        <div className="rpt-save-body">
          <p>Stores the current filters, grain, grouping and sort for your account on this lab. Saved views never cross a lab boundary.</p>
          <label className="rpt-field">
            <span>View name</span>
            <input value={saveViewName} maxLength={120} onChange={e => setSaveViewName(e.target.value)} onKeyDown={e => { if (e.key === 'Enter') saveView(); }} placeholder="e.g. Overdue appeals — my team" />
          </label>
          {savedViews.length > 0 && <div className="rpt-saved-list">
            {savedViews.map(v => <span className="rpt-chip" key={pick(v, 'savedViewId')}>
              {pick(v, 'viewName')}
              <button type="button" onClick={() => removeView(v)} aria-label={`Remove ${pick(v, 'viewName')}`}>×</button>
            </span>)}
          </div>}
        </div>
        <div className="dcm-modal-actions">
          <button type="button" className="wl-btn" onClick={() => setSaveViewOpen(false)}>Cancel</button>
          <button type="button" className="wl-btn teal" disabled={!saveViewName.trim()} onClick={saveView}>Save View</button>
        </div>
      </div>
    </div>}
  </section>;
}
