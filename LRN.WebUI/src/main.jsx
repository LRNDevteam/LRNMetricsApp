import React, { useEffect, useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import 'bootstrap-icons/font/bootstrap-icons.css';
import './styles.css';

const API_BASE = (import.meta.env.VITE_DENIAL_API_BASE || 'https://localhost:62408/api/denialworkflow').replace(/\/$/, '');
const statusOptions = ['', 'New', 'Open', 'Pending Review', 'In-Progress', 'In Progress', 'Verification Pending', 'Closed', 'Completed'];
const actionCategoryOptions = ['', 'Appeal', 'Rebill', 'Write Off', 'Client Info Pending', 'Manual Review'];
const priorityOptions = ['', 'High', 'Medium', 'Low', 'Normal'];
const money = (v) => `$${Number(v || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const date = (v) => v ? new Date(v).toLocaleDateString() : '';
const initials = (name) => String(name || 'NA').split(/[\s._-]+/).filter(Boolean).slice(0, 2).map(x => x[0]?.toUpperCase()).join('') || 'NA';
const statusClass = (v) => { const s = String(v || '').toLowerCase(); if (s.includes('closed') || s.includes('complete')) return 'badge-closed'; if (s.includes('progress') || s.includes('pending')) return 'badge-ip'; if (s.includes('escal')) return 'badge-escalated'; return 'badge-open'; };
const priorityClass = (v) => String(v || '').toLowerCase().includes('high') ? 'badge-high' : String(v || '').toLowerCase().includes('medium') ? 'badge-med' : 'badge-low';
const canAssignRole = (role) => { const r = String(role || '').toLowerCase(); return r.includes('admin') || r.includes('ar manager') || r.includes('manager'); };
const actionBadgeClass = (v) => { const s = String(v || '').toLowerCase(); if (s.includes('appeal')) return 'badge-appeal'; if (s.includes('rebill')) return 'badge-rebill'; if (s.includes('write')) return 'badge-woff'; if (s.includes('client')) return 'badge-cip'; return 'badge-review'; };

function getJwt() {
  const keys = ['lrn.jwt', 'lrnMetrics.jwt', 'access_token', 'jwtToken', 'token', 'authToken'];
  for (const k of keys) { const v = localStorage.getItem(k) || sessionStorage.getItem(k); if (v) return v.replace(/^Bearer\s+/i, ''); }
  return '';
}
function parseJwt(token) {
  try { const payload = token.split('.')[1]; return JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/'))); } catch { return {}; }
}
function claimRole(claims) { const r = claims.role || claims.roles || claims['http://schemas.microsoft.com/ws/2008/06/identity/claims/role']; return Array.isArray(r) ? r[0] : (r || 'AR Manager'); }
function claimUser(claims) { return claims.name || claims.preferred_username || claims.unique_name || claims.upn || claims.email || claims['http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name'] || ''; }
async function api(path, options = {}) {
  const token = getJwt();
  const response = await fetch(`${API_BASE}${path}`, { ...options, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(options.headers || {}) } });
  if (!response.ok) throw new Error(await response.text() || `API error ${response.status}`);
  return response.json();
}
function qs(obj) { const p = new URLSearchParams(); Object.entries(obj).forEach(([k, v]) => { if (v !== undefined && v !== null && v !== '') p.append(k, v); }); return p.toString(); }

function App() {
  const jwtClaims = useMemo(() => parseJwt(getJwt()), []);
  const [user, setUser] = useState({ userName: claimUser(jwtClaims), role: claimRole(jwtClaims), labs: [] });
  const [labs, setLabs] = useState([]);
  const [reviewers, setReviewers] = useState([]);
  const [filterOptions, setFilterOptions] = useState({ statuses: [], actionCategories: [], priorities: [], denialCodes: [], payerNames: [] });
  const [labId, setLabId] = useState(Number(localStorage.getItem('denial.labId') || 0));
  const [view, setView] = useState('dashboard');
  const [filter, setFilter] = useState({ status: '', reviewer: '', actionCategory: '', priority: '', denialCode: '', payerName: '', page: 1 });
  const [dashboard, setDashboard] = useState({ denialClassifications: [], analystWorkload: [], slaTiles: [] });
  const [insights, setInsights] = useState({ items: [], page: 1, totalPages: 0, totalCount: 0 });
  const [tasks, setTasks] = useState({ items: [], page: 1, totalPages: 0, totalCount: 0 });
  const [verification, setVerification] = useState({ items: [], page: 1, totalPages: 0, totalCount: 0 });
  const [selected, setSelected] = useState({});
  const [bulkReviewer, setBulkReviewer] = useState('');
  const [rowReviewers, setRowReviewers] = useState({});
  const [message, setMessage] = useState(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    Promise.allSettled([api('/me')]).then(([me]) => {
      const meData = me.status === 'fulfilled' ? me.value : { userName: claimUser(jwtClaims), role: claimRole(jwtClaims), labs: [] };
      setUser(meData);
      const labData = meData.labs?.length ? meData.labs : [];
      setLabs(labData);
      if (!labId && labData.length) setLabId(labData[0].labId ?? labData[0].LabId);
      if (me.status === 'rejected') api('/labs').then(x => { setLabs(x || []); if (!labId && x?.length) setLabId(x[0].labId ?? x[0].LabId); }).catch(err => setMessage({ type: 'danger', text: err.message }));
    });
  }, []);
  useEffect(() => { if (labId) localStorage.setItem('denial.labId', labId); }, [labId]);
  useEffect(() => {
    if (!labId) { setReviewers([]); return; }
    api(`/reviewers?labId=${encodeURIComponent(labId)}`)
      .then(x => setReviewers(x || []))
      .catch(err => { setReviewers([]); setMessage({ type: 'danger', text: `Reviewer load failed: ${err.message}` }); });
  }, [labId]);
  useEffect(() => {
    if (!labId) return;
    api(`/filter-options?labId=${encodeURIComponent(labId)}`)
      .then(x => setFilterOptions(x || { statuses: [], actionCategories: [], priorities: [], denialCodes: [], payerNames: [] }))
      .catch(() => setFilterOptions({ statuses: [], actionCategories: [], priorities: [], denialCodes: [], payerNames: [] }));
  }, [labId]);

  const query = useMemo(() => ({ labId, role: user.role, userName: user.userName, status: filter.status, reviewer: filter.reviewer, assignedTo: filter.reviewer, actionCategory: filter.actionCategory, priority: filter.priority, denialCode: filter.denialCode, payerName: filter.payerName, page: filter.page || 1 }), [labId, user, filter]);

  useEffect(() => {
    if (!labId) return;
    setLoading(true); setMessage(null);
    const base = qs(query);
    let call = api(`/dashboard?${base}`).then(setDashboard);
    if (view === 'insight') call = Promise.all([api(`/dashboard?${base}`), api(`/insights?${base}`)]).then(([d, i]) => { setDashboard(d); setInsights(i || { items: [] }); setSelected({}); });
    if (view === 'tasks') call = Promise.all([api(`/dashboard?${base}`), api(`/tasks?${base}`)]).then(([d, t]) => { setDashboard(d); setTasks(t || { items: [] }); });
    if (view === 'verification') call = Promise.all([api(`/dashboard?${base}`), api(`/verification?${base}`)]).then(([d, v]) => { setDashboard(d); setVerification(v || { items: [] }); });
    call.catch(err => setMessage({ type: 'danger', text: err.message })).finally(() => setLoading(false));
  }, [labId, view, query]);

  const labName = labs.find(l => Number(l.labId ?? l.LabId) === Number(labId))?.labName || 'Select Lab';
  const pageTitle = { dashboard: 'Denial Workflow Dashboard', summary: 'Denial Summary', insight: 'Denial Insight', tasks: 'Task Board', verification: 'Verification Queue' }[view] || 'Denial Workflow';
  function setFilterValue(k, v) { setFilter(f => ({ ...f, [k]: v, page: 1 })); }
  function clearFilter() { setFilter({ status: '', reviewer: '', actionCategory: '', priority: '', denialCode: '', payerName: '', page: 1 }); }
  function changePage(page) { setFilter(f => ({ ...f, page })); }
  async function reloadInsight() { setInsights(await api(`/insights?${qs(query)}`)); }
  async function assignRows(rows, reviewer) {
    if (!reviewer) return setMessage({ type: 'warning', text: 'Please select a reviewer.' });
    if (!rows.length) return setMessage({ type: 'warning', text: 'Please tick one or more rows. Bulk assign will not assign the full page.' });
    setLoading(true);
    try {
      let count = 0;
      for (const row of rows) {
        const result = await api('/assign-insight', { method: 'POST', body: JSON.stringify({ labId, runId: row.runId, denialCode: row.denialCodes, payerName: row.highImpactInsurance, reviewerUserName: reviewer, actionBy: user.userName || 'ReactWorkflow' }) });
        count += Number(result.rowsAffected || 0);
      }
      setMessage({ type: 'success', text: `Assigned ${rows.length} selected row(s). ${count.toLocaleString()} task(s) updated.` }); setSelected({}); await reloadInsight();
    } catch (err) { setMessage({ type: 'danger', text: err.message }); } finally { setLoading(false); }
  }
  async function saveTask(task, status, comments) {
    setLoading(true);
    try { const result = await api('/update-task', { method: 'POST', body: JSON.stringify({ labId, taskId: task.taskId, status, comments, actionBy: user.userName || 'ReactWorkflow' }) }); setMessage({ type: result.success ? 'success' : 'warning', text: result.message || 'Task saved.' }); setTasks(await api(`/tasks?${qs(query)}`)); }
    catch (err) { setMessage({ type: 'danger', text: err.message }); } finally { setLoading(false); }
  }

  return <div className="lrn-wrap">
    <aside className="lrn-sidebar"><div className="lrn-brand"><div className="lrn-brand-icon">LRN</div><div><div className="lrn-brand-text">Lab Revenue</div><div className="lrn-brand-sub">Intelligence Navigator</div></div></div><div className="user-card"><span className="avatar-sm">{initials(user.displayName || user.userName)}</span><div><strong>{user.displayName || user.userName || 'LRN User'}</strong><small>{user.role || 'Workflow User'}</small></div></div><nav className="lrn-nav"><div className="lrn-nav-section">Overview</div><button className={`lrn-nav-item ${view === 'dashboard' ? 'active' : ''}`} onClick={() => setView('dashboard')}><i className="bi bi-grid-1x2-fill" />Dashboard</button><div className="lrn-nav-section">Denial Workflow</div><button className={`lrn-nav-item ${view === 'summary' ? 'active' : ''}`} onClick={() => setView('summary')}><i className="bi bi-table" />Denial Summary</button><button className={`lrn-nav-item ${view === 'insight' ? 'active' : ''}`} onClick={() => setView('insight')}><i className="bi bi-file-earmark-text" />Denial Insight</button><button className={`lrn-nav-item ${view === 'tasks' ? 'active' : ''}`} onClick={() => setView('tasks')}><i className="bi bi-list-check" />Task Board<span className="lrn-nav-badge">{dashboard.openInProgressCount || 0}</span></button><button className={`lrn-nav-item ${view === 'verification' ? 'active' : ''}`} onClick={() => setView('verification')}><i className="bi bi-shield-check" />Verification</button></nav><div className="lrn-sync"><div>API endpoint</div><span>{API_BASE}</span></div></aside>
    <div className="lrn-main"><header className="lrn-topbar"><div><div className="lrn-page-title">{pageTitle}</div><div className="lrn-breadcrumb">LRN Analytics / <span>{pageTitle}</span></div></div><div className="topbar-actions"><select className="top-lab-select" value={labId || ''} onChange={e => setLabId(Number(e.target.value))}>{labs.map(l => <option key={l.labId ?? l.LabId} value={l.labId ?? l.LabId}>{l.labName ?? l.LabName}</option>)}</select><span className="current-lab">{labName}</span><button className="topbar-btn teal" onClick={() => setMessage({ type: 'info', text: 'Use backend export endpoint for Excel download.' })}><i className="bi bi-download" />Export</button></div></header>
      <main className="lrn-content"><DashboardFilter filter={filter} setFilterValue={setFilterValue} clearFilter={clearFilter} reviewers={reviewers} options={filterOptions} />{message && <div className={`lrn-alert ${message.type}`}>{message.text}</div>}{loading && <div className="loading-line" />}{view === 'dashboard' && <Dashboard data={dashboard} />}{view === 'summary' && <DenialSummary data={dashboard} canAssign={canAssignRole(user.role)} onAssign={() => { setView('insight'); setMessage({ type: 'info', text: 'Select the required rows in Denial Insight, choose reviewer, then assign.' }); }} />}{view === 'insight' && <Insight data={insights} reviewers={reviewers} selected={selected} setSelected={setSelected} bulkReviewer={bulkReviewer} setBulkReviewer={setBulkReviewer} rowReviewers={rowReviewers} setRowReviewers={setRowReviewers} assignRows={assignRows} changePage={changePage} />}{view === 'tasks' && <Tasks data={tasks} saveTask={saveTask} changePage={changePage} />}{view === 'verification' && <Verification data={verification} changePage={changePage} />}</main></div>
  </div>;
}

function listWithDefault(values, fallback) { const list = Array.isArray(values) && values.length ? values : fallback.filter(Boolean); return [...new Set(list.filter(Boolean))]; }

function StatusPill({ label, value, cls }) { return <span className={`summary-pill ${cls}`}>{label}</span>; }
function DenialSummary({ data, canAssign, onAssign }) {
  const classifications = data.denialClassifications || [];
  const actions = data.actionCategories || [];
  return <>
    <div className="lrn-card summary-card">
      <div className="lrn-card-header"><div className="lrn-card-title">Summary by denial classification</div></div>
      <div className="dt-wrap"><table className="lrn-table summary-table"><thead><tr><th>Classification</th><th>Total</th><th>Outstanding</th><th>Open</th><th>In Progress</th><th>Closed</th>{canAssign && <th></th>}</tr></thead><tbody>{classifications.length ? classifications.map((r, i) => <tr key={`${r.classification}-${i}`}><td><strong>{r.classification || 'Unclassified'}</strong></td><td>{Number(r.count || 0).toLocaleString()}</td><td>{money(r.outstanding)}</td><td><StatusPill label="Open" cls="open" /> <span>{Number(r.open || 0).toLocaleString()}</span></td><td><StatusPill label="In Progress" cls="progress" /> <span>{Number(r.inProgress || 0).toLocaleString()}</span></td><td><StatusPill label="Closed" cls="closed" /> <span>{Number(r.closed || 0).toLocaleString()}</span></td>{canAssign && <td className="summary-action"><button className="mini-btn outline" onClick={onAssign}>Assign</button></td>}</tr>) : <tr><td colSpan={canAssign ? 7 : 6} className="empty-cell">No denial classification summary found.</td></tr>}</tbody></table></div>
    </div>
    <div className="lrn-card summary-card">
      <div className="lrn-card-header"><div className="lrn-card-title">Summary by action category</div></div>
      <div className="dt-wrap"><table className="lrn-table summary-table"><thead><tr><th>Action Category</th><th>Count</th><th>Outstanding</th><th>Share</th></tr></thead><tbody>{actions.length ? actions.map((r, i) => <tr key={`${r.actionCategory}-${i}`}><td><span className={`badge ${actionBadgeClass(r.actionCategory)}`}>{r.actionCategory || 'Unclassified'}</span></td><td>{Number(r.count || 0).toLocaleString()}</td><td>{money(r.outstanding)}</td><td><div className="progress-bar"><div className="pb-fill" style={{ width: `${Math.min(100, Number(r.percentageOfTotal || 0))}%` }} /></div></td></tr>) : <tr><td colSpan="4" className="empty-cell">No action category summary found.</td></tr>}</tbody></table></div>
    </div>
  </>;
}

function DashboardFilter({ filter, setFilterValue, clearFilter, reviewers, options }) {
  const statuses = listWithDefault(options?.statuses, statusOptions);
  const actions = listWithDefault(options?.actionCategories, actionCategoryOptions);
  const priorities = listWithDefault(options?.priorities, priorityOptions);
  return <div className="lrn-card filter-card"><div className="filter-row">
    <div><label>Status</label><select value={filter.status} onChange={e => setFilterValue('status', e.target.value)}><option value="">All statuses</option>{statuses.map(x => <option key={x} value={x}>{x}</option>)}</select></div>
    <div><label>Reviewer</label><select value={filter.reviewer} onChange={e => setFilterValue('reviewer', e.target.value)}><option value="">All reviewers</option>{reviewers.map(r => <option key={r.userName} value={r.userName}>{r.displayName || r.userName}</option>)}</select></div>
    <div><label>Denial Action Category</label><select value={filter.actionCategory} onChange={e => setFilterValue('actionCategory', e.target.value)}><option value="">All action categories</option>{actions.map(x => <option key={x} value={x}>{x}</option>)}</select></div>
    <div><label>Priority</label><select value={filter.priority} onChange={e => setFilterValue('priority', e.target.value)}><option value="">All priorities</option>{priorities.map(x => <option key={x} value={x}>{x}</option>)}</select></div>
    <div><label>Denial Code</label><input value={filter.denialCode} onChange={e => setFilterValue('denialCode', e.target.value)} list="denial-code-options" placeholder="CO-96" /><datalist id="denial-code-options">{(options?.denialCodes || []).map(x => <option key={x} value={x} />)}</datalist></div>
    <div><label>Payer Name</label><input value={filter.payerName} onChange={e => setFilterValue('payerName', e.target.value)} list="payer-name-options" placeholder="Aetna" /><datalist id="payer-name-options">{(options?.payerNames || []).map(x => <option key={x} value={x} />)}</datalist></div>
    <div className="filter-actions"><button className="topbar-btn" type="button" onClick={clearFilter}>Clear</button></div>
  </div></div>;
}
function Dashboard({ data }) {
  const classifications = data.denialClassifications || [];
  const workload = data.analystWorkload || [];
  const sla = data.slaTiles || [];
  return <>
    <div className="kpi-grid four">
      <Kpi title="Total denials" value={Number(data.totalDenials || 0).toLocaleString()} sub="DenialTaskBoard rows" color="#1abc9c" />
      <Kpi title="Outstanding amount" value={money(data.outstandingAmount || 0)} sub="InsuranceBalance total" color="#3498db" />
      <Kpi title="Open / Inprogress" value={Number(data.openInProgressCount || 0).toLocaleString()} sub="Not closed/completed" color="#e74c3c" trend="kpi-dn" />
      <Kpi title="Closed" value={Number(data.closedCount || 0).toLocaleString()} sub="Completed/closed tasks" color="#1abc9c" trend="kpi-up" />
    </div>
    <div className="row-2">
      <div className="lrn-card"><div className="lrn-card-header"><div className="lrn-card-title">By denial classification</div></div><div className="dt-wrap dashboard-table-wrap"><table className="lrn-table"><thead><tr><th>Classification</th><th>Count</th><th>Outstanding</th><th>% of Total</th></tr></thead><tbody>{classifications.length ? classifications.map((r, i) => <tr key={i}><td><strong>{r.classification}</strong></td><td>{Number(r.count || 0).toLocaleString()}</td><td>{money(r.outstanding)}</td><td><div className="progress-bar"><div className="pb-fill" style={{ width: `${Math.min(100, Number(r.percentageOfTotal || 0))}%` }} /></div></td></tr>) : <tr><td colSpan="4" className="empty-cell">No classification data found.</td></tr>}</tbody></table></div></div>
      <div className="lrn-card"><div className="lrn-card-header"><div className="lrn-card-title">Analyst workload</div></div><div className="dt-wrap dashboard-table-wrap"><table className="lrn-table"><thead><tr><th>Analyst</th><th>Assigned</th><th>Closed</th></tr></thead><tbody>{workload.length ? workload.map((r, i) => <tr key={i}><td><span className="avatar-sm">{initials(r.reviewerName)}</span> {r.reviewerName}</td><td>{Number(r.totalAssigned || 0).toLocaleString()}</td><td><span className="kpi-up"><strong>{Number(r.closed || 0).toLocaleString()}</strong></span></td></tr>) : <tr><td colSpan="3" className="empty-cell">No reviewer workload found.</td></tr>}</tbody></table></div></div>
    </div>
    <div className="lrn-card sla-card"><div className="lrn-card-header"><div className="lrn-card-title">SLA & performance metrics</div></div><div className="sla-grid">{sla.length ? sla.map((s, i) => <div className="sla-box" key={i}><div className="lbl">{s.label}</div><div className="val">{Number(s.count || 0).toLocaleString()}</div><div className={`stat ${String(s.status).toLowerCase().includes('overdue') ? 'kpi-warn' : 'kpi-up'}`}>{s.status}</div></div>) : <div className="empty-cell">No SLA data found.</div>}</div></div>
  </>;
}
function Kpi({ title, value, sub, color, trend }) { return <div className="kpi-card" style={{ '--kpi-color': color }}><div className="kpi-label">{title}</div><div className={`kpi-value ${trend || ''}`}>{value}</div><div className="kpi-sub">{sub}</div></div>; }
function Insight({ data, reviewers, selected, setSelected, bulkReviewer, setBulkReviewer, rowReviewers, setRowReviewers, assignRows, changePage }) { const items = data.items || []; const all = items.length > 0 && items.every((_, i) => selected[i]); const rows = items.filter((_, i) => selected[i]); return <><div className="lrn-card assignment-toolbar"><div className="assign-left"><strong>Selected rows:</strong> <span>{rows.length}</span><small>Only checked rows will be assigned.</small></div><div className="assign-right"><select value={bulkReviewer} onChange={e => setBulkReviewer(e.target.value)}><option value="">Select Reviewer</option>{reviewers.map(r => <option key={r.userName} value={r.userName}>{r.displayName || r.userName}</option>)}</select><button className="topbar-btn teal" onClick={() => assignRows(rows, bulkReviewer)}><i className="bi bi-person-check" />Assign Selected</button></div></div><div className="lrn-card"><div className="lrn-card-header"><div className="lrn-card-title">Denial Insight</div><span className="table-count">Showing {items.length} of {data.totalCount || 0}</span></div><div className="dt-wrap workflow-scroll"><table className="lrn-table workflow-table"><thead><tr><th className="sticky-col select-col"><input type="checkbox" checked={all} onChange={e => { const next = {}; if (e.target.checked) items.forEach((_, i) => next[i] = true); setSelected(next); }} /></th><th className="sticky-col reviewer-col">Reviewer</th><th className="sticky-col assign-col">Assign</th><th>Denial Code</th><th>Description</th><th>Denial Count</th><th>Claims</th><th>Total Balance</th><th>High Impact Insurance</th><th>Insurance Balance</th><th>Impact %</th><th>Action Category</th><th>Action Code</th><th>Task</th><th>Assigned To</th><th>Run Id</th></tr></thead><tbody>{items.map((r, i) => <tr key={`${r.denialCodes}-${i}`}><td className="sticky-col select-col"><input type="checkbox" checked={!!selected[i]} onChange={e => setSelected({ ...selected, [i]: e.target.checked })} /></td><td className="sticky-col reviewer-col"><select value={rowReviewers[i] || ''} onChange={e => setRowReviewers({ ...rowReviewers, [i]: e.target.value })}><option value="">Select reviewer</option>{reviewers.map(x => <option key={x.userName} value={x.userName}>{x.displayName || x.userName}</option>)}</select></td><td className="sticky-col assign-col"><button className="mini-btn" onClick={() => assignRows([r], rowReviewers[i])}>Assign</button></td><td className="claim-link">{r.denialCodes}</td><td className="wrap-cell">{r.descriptions}</td><td>{r.noOfDenialCount}</td><td>{r.noOfClaimsCount}</td><td>{money(r.totalBalance)}</td><td>{r.highImpactInsurance}</td><td>{money(r.insuranceBalance)}</td><td>{r.impactPercentage}</td><td>{r.actionCategory}</td><td>{r.actionCode}</td><td className="wrap-cell">{r.task}</td><td>{r.assignedTo}</td><td>{r.runId}</td></tr>)}</tbody></table></div></div><Pager data={data} changePage={changePage} /></>; }
function Tasks({ data, saveTask, changePage }) { const items = data.items || []; return <><div className="lrn-card"><div className="lrn-card-header"><div className="lrn-card-title">Task Board</div><span className="table-count">Showing {items.length} of {data.totalCount || 0}</span></div><div className="dt-wrap workflow-scroll"><table className="lrn-table workflow-table"><thead><tr><th className="sticky-col edit-col">Edit</th><th>Task ID</th><th>Claim</th><th>Patient</th><th>CPT</th><th>Denial</th><th>Description</th><th>Classification</th><th>Action Category</th><th>Priority</th><th>Status</th><th>Assigned To</th><th>Insurance Balance</th><th>Due</th><th>SLA</th><th>Payer</th><th>Comments</th></tr></thead><tbody>{items.map((t, i) => <TaskRow key={t.taskId || i} task={t} saveTask={saveTask} />)}</tbody></table></div></div><Pager data={data} changePage={changePage} /></>; }
function TaskRow({ task, saveTask }) { const [editing, setEditing] = useState(false); const [status, setStatus] = useState(task.status || ''); const [comments, setComments] = useState(task.reviewerComments || ''); return <tr><td className="sticky-col edit-col"><button className="mini-btn outline" onClick={() => setEditing(!editing)}>{editing ? 'Close' : 'Edit'}</button>{editing && <div className="edit-pop"><label>Status</label><select value={status} onChange={e => setStatus(e.target.value)}>{statusOptions.filter(Boolean).map(s => <option key={s}>{s}</option>)}</select><label>Reviewer Comments</label><textarea rows="4" value={comments} onChange={e => setComments(e.target.value)} /><button className="topbar-btn teal" onClick={() => { saveTask(task, status, comments); setEditing(false); }}>Save</button></div>}</td><td>{task.taskId}</td><td className="claim-link">{task.claimId}</td><td>{task.patientId}</td><td>{task.cptCode}</td><td>{task.denialCode}</td><td className="wrap-cell">{task.denialDescription}</td><td>{task.denialClassification}</td><td>{task.actionCategory}</td><td><span className={`badge ${priorityClass(task.priority)}`}>{task.priority || 'Normal'}</span></td><td><span className={`badge ${statusClass(task.status)}`}>{task.status || 'New'}</span></td><td>{task.assignedTo}</td><td>{money(task.insuranceBalance)}</td><td>{date(task.dueDate)}</td><td>{task.slaStatus}</td><td>{task.payerName}</td><td className="wrap-cell">{task.reviewerComments}</td></tr>; }
function Verification({ data, changePage }) { const items = data.items || []; return <><div className="lrn-card"><div className="lrn-card-header"><div className="lrn-card-title">Verification Queue</div><span className="table-count">Showing {items.length} of {data.totalCount || 0}</span></div><div className="dt-wrap workflow-scroll"><table className="lrn-table"><thead><tr><th>Task ID</th><th>Claim</th><th>CPT</th><th>Denial</th><th>Description</th><th>Status</th><th>Assigned To</th><th>Payer</th><th>Balance</th><th>Reason</th></tr></thead><tbody>{items.map((v, i) => <tr key={v.verificationId || i}><td>{v.taskId}</td><td className="claim-link">{v.claimId}</td><td>{v.cptCode}</td><td>{v.denialCode}</td><td className="wrap-cell">{v.denialDescription}</td><td><span className={`badge ${statusClass(v.status)}`}>{v.status}</span></td><td>{v.assignedTo}</td><td>{v.payerName}</td><td>{money(v.insuranceBalance)}</td><td className="wrap-cell">{v.verificationComments}</td></tr>)}</tbody></table></div></div><Pager data={data} changePage={changePage} /></>; }
function Pager({ data, changePage }) { if (!data.totalPages || data.totalPages <= 1) return null; return <div className="pager"><button className="topbar-btn" disabled={data.page <= 1} onClick={() => changePage(data.page - 1)}>Previous</button><span>Page {data.page} of {data.totalPages}</span><button className="topbar-btn" disabled={data.page >= data.totalPages} onClick={() => changePage(data.page + 1)}>Next</button></div>; }

createRoot(document.getElementById('root')).render(<App />);
