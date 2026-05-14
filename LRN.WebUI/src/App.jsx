import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { API_BASE, LOGOUT_URL } from './config/apiConfig';
import { emptyDashboard, emptyFilter, emptyFilterOptions, emptyPagedResult } from './dto/denialWorkflowDtos';
import { denialWorkflowService, qs } from './services/denialWorkflowService';
import { claimRole, claimUser, clearWorkflowJwt, ensureWorkflowJwt, getJwt, parseJwt } from './utils/auth';
import { canAssignRole, initials } from './utils/formatters';
import DashboardFilter from './components/DashboardFilter';
import DashboardPage from './pages/DashboardPage';
import DenialSummaryPage from './pages/DenialSummaryPage';
import ClaimAssignmentPage from './pages/ClaimAssignmentPage';
import TasksPage from './pages/TasksPage';
import VerificationPage from './pages/VerificationPage';
import MyWorklistPage from './pages/MyWorklistPage';

function roleIsReviewerOnly(role) {
  const r = String(role || '').replace(/[^a-z0-9]/gi, '').toLowerCase();
  return (r.includes('arreviewer') || r.includes('aranalyser') || r.includes('aranalyzer') || r.includes('reviewer'))
    && !r.includes('manager')
    && !r.includes('admin');
}

export default function App() {
  const jwtClaims = useMemo(() => parseJwt(getJwt()), []);
  const [user, setUser] = useState({ userName: claimUser(jwtClaims), role: claimRole(jwtClaims), labs: [] });
  const [labs, setLabs] = useState([]);
  const [reviewers, setReviewers] = useState([]);
  const [filterOptions, setFilterOptions] = useState(emptyFilterOptions);
  const [labId, setLabId] = useState(Number(localStorage.getItem('denial.labId') || 0));
  const workflowViews = ['dashboard', 'summary', 'claims', 'myworklist', 'tasks', 'verification'];
  const getStoredView = () => {
    const hashView = String(window.location.hash || '').replace('#', '').trim().toLowerCase();
    return workflowViews.includes(hashView) ? hashView : '';
  };
  const [view, setViewState] = useState(getStoredView() || 'dashboard');
  const [filter, setFilter] = useState(emptyFilter);
  const [debouncedFilter, setDebouncedFilter] = useState(emptyFilter);
  const [dashboard, setDashboard] = useState(emptyDashboard);
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
  const claimRequestSeq = useRef(0);
  const reviewerOnly = roleIsReviewerOnly(user.role);
  const canAssign = canAssignRole(user.role);

  function setView(nextView) {
    const safeView = workflowViews.includes(nextView) ? nextView : 'dashboard';
    setViewState(safeView);
    if (window.location.hash !== `#${safeView}`) {
      window.history.replaceState(null, '', `${window.location.pathname}${window.location.search}#${safeView}`);
    }
  }

  function resolveLandingView(role) {
    const stored = getStoredView();
    if (stored) return stored;
    return roleIsReviewerOnly(role) ? 'myworklist' : 'dashboard';
  }

  async function refreshLoginUserFromMetrics({ forceRefresh = true, resetData = false, applyLanding = false } = {}) {
    await ensureWorkflowJwt({ forceRefresh });
    const me = await denialWorkflowService.getMe();
    setUser(me);

    const labData = me.labs?.length ? me.labs : [];
    setLabs(labData);

    const allowedLabIds = labData.map(l => Number(l.labId ?? l.LabId)).filter(Boolean);
    if (allowedLabIds.length && !allowedLabIds.includes(Number(labId))) {
      setLabId(allowedLabIds[0]);
      localStorage.setItem('denial.labId', String(allowedLabIds[0]));
    }

    if (applyLanding) setView(resolveLandingView(me.role));

    if (resetData) {
      setDashboard(emptyDashboard);
      setClaims(emptyPagedResult);
      setTasks(emptyPagedResult);
      setVerification(emptyPagedResult);
      setSelected({});
      setSelectedClaims({});
      setClaimTasks({});
      setExpandedClaim('');
    }

    return me;
  }

  useEffect(() => {
    let cancelled = false;

    async function bootAuth() {
      try {
        const me = await refreshLoginUserFromMetrics({ forceRefresh: true, resetData: false, applyLanding: true });
        if (cancelled) return;

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

  useEffect(() => {
    if (!authReady) return;
    let refreshing = false;

    async function handleFocus() {
      if (refreshing) return;
      refreshing = true;
      try {
        await refreshLoginUserFromMetrics({ forceRefresh: true, resetData: false, applyLanding: false });
      } catch (err) {
        setAuthReady(false);
        setAuthError(err?.message || 'Login required.');
      } finally {
        refreshing = false;
      }
    }

    window.addEventListener('focus', handleFocus);
    return () => window.removeEventListener('focus', handleFocus);
  }, [authReady, labId]);

  useEffect(() => { if (labId) localStorage.setItem('denial.labId', labId); }, [labId]);

  // Avoid reloading 300k+ row queries on every keystroke in Search/Clinic/Sales Rep/Provider.
  useEffect(() => {
    const handle = window.setTimeout(() => setDebouncedFilter(filter), 450);
    return () => window.clearTimeout(handle);
  }, [filter]);

  useEffect(() => {
    if (!authReady || !labId || !canAssign) { setReviewers([]); return; }
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
  }, [authReady, labId, canAssign]);

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
    reviewer: reviewerOnly ? (user.userName || '') : debouncedFilter.reviewer,
    assignedTo: reviewerOnly ? (user.userName || '') : debouncedFilter.reviewer,
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
  }), [labId, user, debouncedFilter, reviewerOnly]);

  useEffect(() => {
    if (!authReady || !labId) return;
    setLoading(true);
    setMessage(null);


    let call;
    if (view === 'dashboard' || view === 'summary') {
      call = denialWorkflowService.getDashboard(query).then(setDashboard);
    } else if (view === 'claims') {
      const requestId = ++claimRequestSeq.current;
      call = denialWorkflowService.getClaims(query).then(c => {
        if (requestId !== claimRequestSeq.current) return;
        const next = c || emptyPagedResult;
        const nextPage = Number(next.pageNumber || query.page || 1);

        setClaims(prev => {
          if (nextPage <= 1) return next;

          const seen = new Set((prev.items || [])
            .map(r => String(r?.claimId ?? r?.claimID ?? r?.ClaimId ?? r?.ClaimID ?? '').trim())
            .filter(Boolean));
          const mergedItems = [...(prev.items || [])];

          (next.items || []).forEach(row => {
            const id = String(row?.claimId ?? row?.claimID ?? row?.ClaimId ?? row?.ClaimID ?? '').trim();
            if (!id || !seen.has(id)) {
              if (id) seen.add(id);
              mergedItems.push(row);
            }
          });

          return { ...next, items: mergedItems };
        });

        if (nextPage <= 1) {
          setSelectedClaims({});
          setClaimTasks({});
          setExpandedClaim('');
        }
      });
    } else if (view === 'tasks') {
      call = denialWorkflowService.getTasks(query).then(t => setTasks(t || emptyPagedResult));
    } else if (view === 'verification') {
      call = denialWorkflowService.getVerification(query).then(v => setVerification(v || emptyPagedResult));
    } else {
      call = Promise.resolve();
    }

    call.catch(err => setMessage({ type: 'danger', text: err.message })).finally(() => setLoading(false));
  }, [authReady, labId, view, query, reviewerOnly]);

  const labName = labs.find(l => Number(l.labId ?? l.LabId) === Number(labId))?.labName || 'Select Lab';
  const pageTitle = { dashboard: 'Denial Workflow Dashboard', summary: 'Denial Summary', claims: 'Claim Level Assignment', myworklist: 'My Worklist', tasks: 'Task Board', verification: 'Verification Queue' }[view] || 'Denial Workflow';

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

  const loadMoreClaims = useCallback(() => {
    if (view !== 'claims' || loading) return;
    const loaded = claims.items?.length || 0;
    const total = claims.totalCount || 0;
    if (!total || loaded >= total) return;

    const currentPage = Number(claims.pageNumber || debouncedFilter.page || 1);
    setFilter(f => ({ ...f, page: currentPage + 1 }));
  }, [view, loading, claims, debouncedFilter.page]);

  async function assignClaims(claimIds, reviewer, overwriteExisting = false) {
    if (!canAssign) return setMessage({ type: 'warning', text: 'Only Admin and AR Manager users can assign claims.' });
    if (!reviewer) return setMessage({ type: 'warning', text: 'Please select a reviewer.' });
    if (!claimIds.length) return setMessage({ type: 'warning', text: 'Please select one or more claim rows.' });
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

  function logoutWorkflow() {
    clearWorkflowJwt();
    try {
      localStorage.removeItem('denial.labId');
      Object.keys(sessionStorage).forEach(key => {
        if (key.startsWith('denial.')) sessionStorage.removeItem(key);
      });
    } catch { /* ignore browser storage cleanup errors */ }
    window.location.href = LOGOUT_URL;
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
        <button className={`lrn-nav-item ${view === 'claims' ? 'active' : ''}`} onClick={() => setView('claims')}><i className="bi bi-folder-check" />{canAssign ? 'Claim Assignment' : 'Claim View'}</button>
        <div className="lrn-nav-section">My Tasks</div>
        <button className={`lrn-nav-item ${view === 'myworklist' ? 'active' : ''}`} onClick={() => setView('myworklist')}><i className="bi bi-person-check" />My Worklist</button>
        <button className={`lrn-nav-item ${view === 'tasks' ? 'active' : ''}`} onClick={() => setView('tasks')}><i className="bi bi-list-check" />Task Board<span className="lrn-nav-badge">{dashboard.openInProgressCount || 0}</span></button>
        <button className={`lrn-nav-item ${view === 'verification' ? 'active' : ''}`} onClick={() => setView('verification')}><i className="bi bi-shield-check" />Verification</button>
      </nav>
      <div className="lrn-sync"><div>API endpoint</div><span>{API_BASE}</span></div>
      <div className="sidebar-logout"><button type="button" className="sidebar-logout-btn" onClick={logoutWorkflow}><i className="bi bi-box-arrow-right" />Logout</button></div>
    </aside>
    <div className="lrn-main">
      <header className="lrn-topbar"><div><div className="lrn-page-title">{pageTitle}</div><div className="lrn-breadcrumb">LRN Analytics / <span>{pageTitle}</span></div></div><div className="topbar-actions"><select className="top-lab-select" value={labId || ''} onChange={e => setLabId(Number(e.target.value))}>{labs.map(l => <option key={l.labId ?? l.LabId} value={l.labId ?? l.LabId}>{l.labName ?? l.LabName}</option>)}</select><span className="current-lab">{labName}</span><button className="topbar-btn teal" onClick={() => setMessage({ type: 'info', text: 'Use backend export endpoint for Excel download.' })}><i className="bi bi-download" />Export</button><button type="button" className="topbar-btn" onClick={logoutWorkflow}><i className="bi bi-box-arrow-right" />Logout</button></div></header>
      <main className="lrn-content">
        {view !== 'myworklist' && <DashboardFilter filter={filter} setFilterValue={setFilterValue} clearFilter={clearFilter} reviewers={reviewers} options={filterOptions} />}
        {message && <div className={`lrn-alert ${message.type}`}>{message.text}</div>}
        {loading && <div className="loading-line" />}
        {view === 'dashboard' && <DashboardPage data={dashboard} />}
        {view === 'summary' && <DenialSummaryPage data={dashboard} canAssign={canAssign} onClassificationClick={openClaimsByClassification} onActionCategoryClick={openClaimsByActionCategory} onAssign={() => { setView('claims'); setMessage({ type: 'info', text: 'Select the required claim rows, choose reviewer, then assign.' }); }} />}
        {view === 'claims' && <ClaimAssignmentPage data={claims} reviewers={reviewers} selected={selectedClaims} setSelected={setSelectedClaims} bulkReviewer={bulkReviewer} setBulkReviewer={setBulkReviewer} loadClaimTasks={loadClaimTasks} claimTasks={claimTasks} expandedClaim={expandedClaim} assignClaims={assignClaims} changePage={changePage} loadMoreClaims={loadMoreClaims} isLoadingClaims={loading} labId={labId} currentUser={user.userName || 'ReactWorkflow'} canAssign={canAssign} />}
        {view === 'myworklist' && <MyWorklistPage labId={labId} user={user} options={filterOptions} filter={filter} setMessage={setMessage} />}
        {view === 'tasks' && <TasksPage data={tasks} saveTask={saveTask} changePage={changePage} labId={labId} currentUser={user.userName || 'ReactWorkflow'} />}
        {view === 'verification' && <VerificationPage data={verification} changePage={changePage} labId={labId} currentUser={user.userName || 'ReactWorkflow'} />}
      </main>
    </div>
  </div>;
}
