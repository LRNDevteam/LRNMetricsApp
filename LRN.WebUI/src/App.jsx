import React, { useEffect, useMemo, useState } from 'react';
import { API_BASE } from './config/apiConfig';
import { emptyDashboard, emptyFilter, emptyFilterOptions, emptyPagedResult } from './dto/denialWorkflowDtos';
import { denialWorkflowService, qs } from './services/denialWorkflowService';
import { claimRole, claimUser, ensureWorkflowJwt, getJwt, parseJwt } from './utils/auth';
import { canAssignRole, initials } from './utils/formatters';
import DashboardFilter from './components/DashboardFilter';
import DashboardPage from './pages/DashboardPage';
import DenialSummaryPage from './pages/DenialSummaryPage';
import InsightPage from './pages/InsightPage';
import ClaimAssignmentPage from './pages/ClaimAssignmentPage';
import TasksPage from './pages/TasksPage';
import VerificationPage from './pages/VerificationPage';
import MyWorklistPage from './pages/MyWorklistPage';

export default function App() {
  const jwtClaims = useMemo(() => parseJwt(getJwt()), []);
  const [user, setUser] = useState({ userName: claimUser(jwtClaims), role: claimRole(jwtClaims), labs: [] });
  const [labs, setLabs] = useState([]);
  const [reviewers, setReviewers] = useState([]);
  const [filterOptions, setFilterOptions] = useState(emptyFilterOptions);
  const [labId, setLabId] = useState(Number(localStorage.getItem('denial.labId') || 0));
  const [view, setView] = useState('dashboard');
  const [filter, setFilter] = useState(emptyFilter);
  const [debouncedFilter, setDebouncedFilter] = useState(emptyFilter);
  const [dashboard, setDashboard] = useState(emptyDashboard);
  const [insights, setInsights] = useState(emptyPagedResult);
  const [claims, setClaims] = useState(emptyPagedResult);
  const [tasks, setTasks] = useState(emptyPagedResult);
  const [verification, setVerification] = useState(emptyPagedResult);
  const [selected, setSelected] = useState({});
  const [selectedClaims, setSelectedClaims] = useState({});
  const [claimTasks, setClaimTasks] = useState({});
  const [expandedClaim, setExpandedClaim] = useState('');
  const [bulkReviewer, setBulkReviewer] = useState('');
  const [rowReviewers, setRowReviewers] = useState({});
  const [message, setMessage] = useState(null);
  const [loading, setLoading] = useState(false);
  const [authReady, setAuthReady] = useState(false);
  const [authChecking, setAuthChecking] = useState(true);
  const [authError, setAuthError] = useState('');

  useEffect(() => {
    let cancelled = false;

    async function bootAuth() {
      try {
        await ensureWorkflowJwt();
        const me = await denialWorkflowService.getMe();
        if (cancelled) return;

        setUser(me);
        const labData = me.labs?.length ? me.labs : [];
        setLabs(labData);
        if (!labId && labData.length) setLabId(labData[0].labId ?? labData[0].LabId);
        setAuthReady(true);
      } catch (err) {
        if (!cancelled) {
          setAuthReady(false);
          setAuthError(err?.message || 'Login required.');
        }
      } finally {
        if (!cancelled) setAuthChecking(false);
      }
    }

    bootAuth();
    return () => { cancelled = true; };
  }, []);

  useEffect(() => { if (labId) localStorage.setItem('denial.labId', labId); }, [labId]);

  // Avoid reloading 300k+ row queries on every keystroke in Search/Clinic/Sales Rep/Provider.
  useEffect(() => {
    const handle = window.setTimeout(() => setDebouncedFilter(filter), 450);
    return () => window.clearTimeout(handle);
  }, [filter]);

  useEffect(() => {
    if (!authReady || !labId) { setReviewers([]); return; }
    const cacheKey = `denial.reviewers.${labId}`;
    try {
      const cached = sessionStorage.getItem(cacheKey);
      if (cached) setReviewers(JSON.parse(cached) || []);
    } catch { /* ignore bad browser cache */ }

    denialWorkflowService.getReviewers(labId)
      .then(x => {
        const rows = x || [];
        setReviewers(rows);
        try { sessionStorage.setItem(cacheKey, JSON.stringify(rows)); } catch { /* ignore storage quota */ }
      })
      .catch(err => {
        if (!reviewers.length) setReviewers([]);
        setMessage({ type: 'danger', text: `Reviewer load failed: ${err.message}` });
      });
  }, [authReady, labId]);

  useEffect(() => {
    if (!authReady || !labId) return;
    const cacheKey = `denial.filterOptions.${labId}`;
    try {
      const cached = sessionStorage.getItem(cacheKey);
      if (cached) setFilterOptions({ ...emptyFilterOptions, ...(JSON.parse(cached) || {}) });
    } catch { /* ignore bad browser cache */ }

    // Load dropdown/autocomplete values in the background. This should not block the page.
    denialWorkflowService.getFilterOptions(labId)
      .then(x => {
        const options = { ...emptyFilterOptions, ...(x || {}) };
        setFilterOptions(options);
        try { sessionStorage.setItem(cacheKey, JSON.stringify(options)); } catch { /* ignore storage quota */ }
      })
      .catch(() => {
        if (!sessionStorage.getItem(cacheKey)) setFilterOptions(emptyFilterOptions);
      });
  }, [authReady, labId]);

  const query = useMemo(() => ({
    labId,
    role: user.role,
    userName: user.userName,
    status: debouncedFilter.status,
    reviewer: debouncedFilter.reviewer,
    assignedTo: debouncedFilter.reviewer,
    actionCategory: debouncedFilter.actionCategory,
    priority: debouncedFilter.priority,
    denialCode: debouncedFilter.denialCode,
    payerName: debouncedFilter.payerName,
    clinic: debouncedFilter.clinic,
    salesRepname: debouncedFilter.salesRepname,
    referringProvider: debouncedFilter.referringProvider,
    denialClassification: debouncedFilter.denialClassification,
    searchText: debouncedFilter.searchText,
    page: debouncedFilter.page || 1,
    pageSize: 50
  }), [labId, user, debouncedFilter]);

  useEffect(() => {
    if (!authReady || !labId) return;
    setLoading(true);
    setMessage(null);

    let call;
    if (view === 'dashboard' || view === 'summary') {
      call = denialWorkflowService.getDashboard(query).then(setDashboard);
    } else if (view === 'insight') {
      call = denialWorkflowService.getInsights(query).then(i => { setInsights(i || emptyPagedResult); setSelected({}); });
    } else if (view === 'claims') {
      call = denialWorkflowService.getClaims(query).then(c => { setClaims(c || emptyPagedResult); setSelectedClaims({}); setClaimTasks({}); setExpandedClaim(''); });
    } else if (view === 'tasks') {
      call = denialWorkflowService.getTasks(query).then(t => setTasks(t || emptyPagedResult));
    } else if (view === 'verification') {
      call = denialWorkflowService.getVerification(query).then(v => setVerification(v || emptyPagedResult));
    } else {
      call = Promise.resolve();
    }

    call.catch(err => setMessage({ type: 'danger', text: err.message })).finally(() => setLoading(false));
  }, [authReady, labId, view, query]);

  const labName = labs.find(l => Number(l.labId ?? l.LabId) === Number(labId))?.labName || 'Select Lab';
  const pageTitle = { dashboard: 'Denial Workflow Dashboard', summary: 'Denial Summary', insight: 'Denial Insight', claims: 'Claim Level Assignment', myworklist: 'My Worklist', tasks: 'Task Board', verification: 'Verification Queue' }[view] || 'Denial Workflow';

  function setFilterValue(k, v) { setFilter(f => ({ ...f, [k]: v, page: 1 })); }
  function clearFilter() { setFilter(emptyFilter); }
  function changePage(page) { setFilter(f => ({ ...f, page })); }


  function openClaimsByClassification(classification) {
    setFilter(f => ({
      ...f,
      denialClassification: classification || '',
      page: 1
    }));
    setView('claims');
    setMessage({
      type: 'info',
      text: classification
        ? `Showing Claim Assignment filtered by Denial Classification: ${classification}`
        : 'Showing Claim Assignment filtered by Unclassified denial classification.'
    });
  }

  function openClaimsByActionCategory(actionCategory) {
    setFilter(f => ({
      ...f,
      actionCategory: actionCategory || '',
      page: 1
    }));
    setView('claims');
    setMessage({
      type: 'info',
      text: actionCategory
        ? `Showing Claim Assignment filtered by Action Category: ${actionCategory}`
        : 'Showing Claim Assignment filtered by Unclassified action category.'
    });
  }

  async function reloadInsight() { setInsights(await denialWorkflowService.getInsights(query)); }

  async function assignRows(rows, reviewer) {
    if (!reviewer) return setMessage({ type: 'warning', text: 'Please select a reviewer.' });
    if (!rows.length) return setMessage({ type: 'warning', text: 'Please tick one or more rows. Bulk assign will not assign the full page.' });
    setLoading(true);
    try {
      let count = 0;
      for (const row of rows) {
        const result = await denialWorkflowService.assignInsight({ labId, runId: row.runId, denialCode: row.denialCodes, payerName: row.highImpactInsurance, reviewerUserName: reviewer, actionBy: user.userName || 'ReactWorkflow' });
        count += Number(result.rowsAffected || 0);
      }
      setMessage({ type: 'success', text: `Assigned ${rows.length} selected row(s). ${count.toLocaleString()} task(s) updated.` });
      setSelected({});
      await reloadInsight();
    } catch (err) { setMessage({ type: 'danger', text: err.message }); }
    finally { setLoading(false); }
  }

  async function loadClaimTasks(rawClaimId) {
    const claimId = String(rawClaimId || '').trim();
    if (!claimId) return setMessage({ type: 'warning', text: 'ClaimId is missing for this row.' });
    if (expandedClaim === claimId) { setExpandedClaim(''); return; }
    setExpandedClaim(claimId);
    if (claimTasks[claimId]) return;
    try {
      const rows = await denialWorkflowService.getClaimTasks(labId, claimId);
      setClaimTasks(prev => ({ ...prev, [claimId]: rows || [] }));
    } catch (err) { setMessage({ type: 'danger', text: err.message }); }
  }

  async function assignClaims(claimIds, reviewer, overwriteExisting = false) {
    if (!reviewer) return setMessage({ type: 'warning', text: 'Please select a reviewer.' });
    if (!claimIds.length) return setMessage({ type: 'warning', text: 'Please tick one or more claim rows.' });
    setLoading(true);
    try {
      const result = await denialWorkflowService.assignClaims({ labId, claimIds, reviewerUserName: reviewer, actionBy: user.userName || 'ReactWorkflow', overwriteExisting });
      if (result.hasConflicts && !overwriteExisting) {
        const sample = (result.conflicts || []).slice(0, 5).map(x => `${x.claimId} / ${x.taskId} -> ${x.assignedTo}`).join('\n');
        const ok = window.confirm(`Some selected tasks are already assigned to another reviewer.\n\n${sample}\n\nDo you want to overwrite and assign to ${reviewer}?`);
        if (ok) return assignClaims(claimIds, reviewer, true);
        setMessage({ type: 'warning', text: 'Assignment cancelled. Existing reviewer was not overwritten.' });
        return;
      }
      setMessage({ type: result.success ? 'success' : 'warning', text: result.message || 'Claim assignment completed.' });
      setSelectedClaims({});
      setClaimTasks({});
      setExpandedClaim('');
      setClaims(await denialWorkflowService.getClaims(query));
    } catch (err) { setMessage({ type: 'danger', text: err.message }); }
    finally { setLoading(false); }
  }

  async function saveTask(task, status, comments) {
    setLoading(true);
    try {
      const result = await denialWorkflowService.updateTask({ labId, taskId: task.taskId, status, comments, actionBy: user.userName || 'ReactWorkflow' });
      setMessage({ type: result.success ? 'success' : 'warning', text: result.message || 'Task saved.' });
      setTasks(await denialWorkflowService.getTasks(query));
    } catch (err) { setMessage({ type: 'danger', text: err.message }); }
    finally { setLoading(false); }
  }

  if (authChecking) {
    return <div className="auth-gate"><div className="auth-card"><strong>Checking LRN Metrics login...</strong><span>Please wait.</span></div></div>;
  }

  if (!authReady) {
    return <div className="auth-gate"><div className="auth-card"><strong>LRN Metrics login/auth failed</strong><span>{authError || 'This page is protected.'}</span><button type="button" className="topbar-btn teal" onClick={() => window.location.reload()}>Retry</button></div></div>;
  }

  return <div className="lrn-wrap">
    <aside className="lrn-sidebar">
      <div className="lrn-brand"><div className="lrn-brand-icon">LRN</div><div><div className="lrn-brand-text">Lab Revenue</div><div className="lrn-brand-sub">Intelligence Navigator</div></div></div>
      <div className="user-card"><span className="avatar-sm">{initials(user.displayName || user.userName)}</span><div><strong>{user.displayName || user.userName || 'LRN User'}</strong><small>{user.role || 'Workflow User'}</small></div></div>
      <nav className="lrn-nav">
        <div className="lrn-nav-section">Overview</div>
        <button className={`lrn-nav-item ${view === 'dashboard' ? 'active' : ''}`} onClick={() => setView('dashboard')}><i className="bi bi-grid-1x2-fill" />Dashboard</button>
        <div className="lrn-nav-section">Denial Workflow</div>
        <button className={`lrn-nav-item ${view === 'summary' ? 'active' : ''}`} onClick={() => setView('summary')}><i className="bi bi-table" />Denial Summary</button>
        <button className={`lrn-nav-item ${view === 'insight' ? 'active' : ''}`} onClick={() => setView('insight')}><i className="bi bi-file-earmark-text" />Denial Insight</button>
        <button className={`lrn-nav-item ${view === 'claims' ? 'active' : ''}`} onClick={() => setView('claims')}><i className="bi bi-folder-check" />Claim Assignment</button>
        <button className={`lrn-nav-item ${view === 'myworklist' ? 'active' : ''}`} onClick={() => setView('myworklist')}><i className="bi bi-person-check" />My Worklist</button>
        <button className={`lrn-nav-item ${view === 'tasks' ? 'active' : ''}`} onClick={() => setView('tasks')}><i className="bi bi-list-check" />Task Board<span className="lrn-nav-badge">{dashboard.openInProgressCount || 0}</span></button>
        <button className={`lrn-nav-item ${view === 'verification' ? 'active' : ''}`} onClick={() => setView('verification')}><i className="bi bi-shield-check" />Verification</button>
      </nav>
      <div className="lrn-sync"><div>API endpoint</div><span>{API_BASE}</span></div>
    </aside>
    <div className="lrn-main">
      <header className="lrn-topbar"><div><div className="lrn-page-title">{pageTitle}</div><div className="lrn-breadcrumb">LRN Analytics / <span>{pageTitle}</span></div></div><div className="topbar-actions"><select className="top-lab-select" value={labId || ''} onChange={e => setLabId(Number(e.target.value))}>{labs.map(l => <option key={l.labId ?? l.LabId} value={l.labId ?? l.LabId}>{l.labName ?? l.LabName}</option>)}</select><span className="current-lab">{labName}</span><button className="topbar-btn teal" onClick={() => setMessage({ type: 'info', text: 'Use backend export endpoint for Excel download.' })}><i className="bi bi-download" />Export</button></div></header>
      <main className="lrn-content">
        {view !== 'myworklist' && <DashboardFilter filter={filter} setFilterValue={setFilterValue} clearFilter={clearFilter} reviewers={reviewers} options={filterOptions} />}
        {message && <div className={`lrn-alert ${message.type}`}>{message.text}</div>}
        {loading && <div className="loading-line" />}
        {view === 'dashboard' && <DashboardPage data={dashboard} />}
        {view === 'summary' && <DenialSummaryPage data={dashboard} canAssign={canAssignRole(user.role)} onClassificationClick={openClaimsByClassification} onActionCategoryClick={openClaimsByActionCategory} onAssign={() => { setView('insight'); setMessage({ type: 'info', text: 'Select the required rows in Denial Insight, choose reviewer, then assign.' }); }} />}
        {view === 'insight' && <InsightPage data={insights} reviewers={reviewers} selected={selected} setSelected={setSelected} bulkReviewer={bulkReviewer} setBulkReviewer={setBulkReviewer} rowReviewers={rowReviewers} setRowReviewers={setRowReviewers} assignRows={assignRows} changePage={changePage} labId={labId} currentUser={user.userName || 'ReactWorkflow'} />}
        {view === 'claims' && <ClaimAssignmentPage data={claims} reviewers={reviewers} selected={selectedClaims} setSelected={setSelectedClaims} bulkReviewer={bulkReviewer} setBulkReviewer={setBulkReviewer} loadClaimTasks={loadClaimTasks} claimTasks={claimTasks} expandedClaim={expandedClaim} assignClaims={assignClaims} changePage={changePage} labId={labId} currentUser={user.userName || 'ReactWorkflow'} />}
        {view === 'myworklist' && <MyWorklistPage labId={labId} user={user} options={filterOptions} filter={filter} setMessage={setMessage} />}
        {view === 'tasks' && <TasksPage data={tasks} saveTask={saveTask} changePage={changePage} labId={labId} currentUser={user.userName || 'ReactWorkflow'} />}
        {view === 'verification' && <VerificationPage data={verification} changePage={changePage} labId={labId} currentUser={user.userName || 'ReactWorkflow'} />}
      </main>
    </div>
  </div>;
}
