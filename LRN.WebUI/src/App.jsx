import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { API_BASE, LOGOUT_URL } from './config/apiConfig';
import { emptyDashboard, emptyFilter, emptyFilterOptions, emptyPagedResult } from './dto/denialWorkflowDtos';
import { denialWorkflowService, qs } from './services/denialWorkflowService';
import { claimRole, claimUser, clearWorkflowJwt, ensureWorkflowJwt, getJwt, parseJwt } from './utils/auth';
import { canAssignRole, initials, isArReviewerRole, isClientManagerRole, isAccountManagerRole, isReadOnlyWorkflowRole } from './utils/formatters';
import DashboardFilter from './components/DashboardFilter';
import DashboardPage from './pages/DashboardPage';
import DenialSummaryPage from './pages/DenialSummaryPage';
import ClaimAssignmentPage from './pages/ClaimAssignmentPage';
import TasksPage from './pages/TasksPage';
import VerificationPage from './pages/VerificationPage';
import MyWorklistPage from './pages/MyWorklistPage';
import EscalationQueuePage from './pages/EscalationQueuePage';

function roleIsReviewerOnly(role) { return isArReviewerRole(role); }

export default function App() {
  const jwtClaims = useMemo(() => parseJwt(getJwt()), []);
  const [user, setUser] = useState({ userName: claimUser(jwtClaims), role: claimRole(jwtClaims), labs: [] });
  const [labs, setLabs] = useState([]);
  const [reviewers, setReviewers] = useState([]);
  const [filterOptions, setFilterOptions] = useState(emptyFilterOptions);
  const [labId, setLabId] = useState(Number(localStorage.getItem('denial.labId') || 0));
  const workflowViews = ['dashboard', 'summary', 'claims', 'myworklist', 'tasks', 'escalations', 'verification'];
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
  const [claimTaskView, setClaimTaskView] = useState('unassigned');
  const [myWorklistView, setMyWorklistView] = useState('open');
  const [escalationView, setEscalationView] = useState('claim');
  const [bulkReviewer, setBulkReviewer] = useState('');
  const [rowReviewers, setRowReviewers] = useState({});
  const [message, setMessage] = useState(null);
  const [loading, setLoading] = useState(false);
  const [authReady, setAuthReady] = useState(false);
  const [authChecking, setAuthChecking] = useState(true);
  const [authError, setAuthError] = useState('');
  const [reviewerNotification, setReviewerNotification] = useState({ assignedTasks: 0, pendingTasks: 0, loading: false });
  const [claimMenuCounts, setClaimMenuCounts] = useState({ unassigned: null, assigned: null, escalations: null, closed: null });
  const [myWorklistMenuCounts, setMyWorklistMenuCounts] = useState({ open: null, assigned: null, escalations: null, closed: null });
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const claimRequestSeq = useRef(0);
  const reviewerOnly = roleIsReviewerOnly(user.role);
  const canAssign = canAssignRole(user.role);
  const clientManager = isClientManagerRole(user.role);
  const readOnlyWorkflow = isReadOnlyWorkflowRole(user.role);

  function setView(nextView, { closeSidebar = true } = {}) {
    let safeView = workflowViews.includes(nextView) ? nextView : 'dashboard';
    if (reviewerOnly && safeView === 'claims') safeView = 'myworklist';
    setViewState(safeView);
    if (closeSidebar) setSidebarOpen(false);
    if (window.location.hash !== `#${safeView}`) {
      window.history.replaceState(null, '', `${window.location.pathname}${window.location.search}#${safeView}`);
    }
  }

  function normalizeFilterOptions(raw = {}) {
    const source = raw?.data ?? raw?.Data ?? raw?.result ?? raw?.Result ?? raw;
    const toStrings = (value, keys = []) => {
      if (value === undefined || value === null) return [];
      const list = Array.isArray(value) ? value : [value];
      const seen = new Set();
      const normalizeKey = (s) => String(s || '').toLowerCase().replace(/[-_]/g, ' ').replace(/\s+/g, ' ').trim();

      return list
        .map(item => {
          if (item === undefined || item === null) return '';
          if (typeof item === 'string') return item.trim();
          if (typeof item === 'number') return String(item).trim();
          if (typeof item === 'object') {
            for (const k of keys) {
              const v = item?.[k];
              if (v !== undefined && v !== null) return String(v).trim();
            }
            const fallback = item?.value ?? item?.Value ?? item?.label ?? item?.Label ?? item?.userName ?? item?.UserName ?? item?.displayName ?? item?.DisplayName;
            if (fallback !== undefined && fallback !== null) return String(fallback).trim();
          }
          return '';
        })
        .filter(Boolean)
        .filter(s => {
          const k = normalizeKey(s);
          if (!k || seen.has(k)) return false;
          seen.add(k);
          return true;
        });
    };
    const fromMaybeDelimitedString = (value) => {
      if (Array.isArray(value)) return value;
      if (typeof value !== 'string') return value;
      const s = value.trim();
      if (!s) return [];
      const splitBy = s.includes('¬') ? '¬' : (s.includes(',') ? ',' : null);
      if (!splitBy) return [s];
      return s.split(splitBy).map(x => x.trim()).filter(Boolean);
    };

    return {
      statuses: toStrings(fromMaybeDelimitedString(source.statuses ?? source.Statuses), ['status', 'Status', 'name', 'Name']),
      actionCategories: toStrings(fromMaybeDelimitedString(source.actionCategories ?? source.ActionCategories), ['actionCategory', 'ActionCategory', 'category', 'Category', 'name', 'Name']),
      priorities: toStrings(fromMaybeDelimitedString(source.priorities ?? source.Priorities), ['priority', 'Priority', 'name', 'Name']),
      denialCodes: toStrings(fromMaybeDelimitedString(source.denialCodes ?? source.DenialCodes), ['denialCode', 'DenialCode', 'code', 'Code', 'name', 'Name']),
      payerNames: toStrings(fromMaybeDelimitedString(source.payerNames ?? source.PayerNames), ['payerName', 'PayerName', 'name', 'Name']),
      denialClassifications: toStrings(fromMaybeDelimitedString(source.denialClassifications ?? source.DenialClassifications), ['denialClassification', 'DenialClassification', 'classification', 'Classification', 'name', 'Name']),
      clinics: toStrings(fromMaybeDelimitedString(source.clinics ?? source.Clinics), ['clinic', 'Clinic', 'clinicName', 'ClinicName', 'name', 'Name']),
      salesReps: toStrings(fromMaybeDelimitedString(source.salesReps ?? source.SalesReps), ['salesRepname', 'SalesRepname', 'salesRep', 'SalesRep', 'name', 'Name']),
      referringProviders: toStrings(fromMaybeDelimitedString(source.referringProviders ?? source.ReferringProviders), ['referringProvider', 'ReferringProvider', 'providerName', 'ProviderName', 'name', 'Name'])
    };
  }

  function resolveLandingView(role) {
    const stored = getStoredView();
    if (stored) return stored;
    // Every Denial Workflow role lands on the workflow dashboard after login.
    return 'dashboard';
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
    const cacheKey = `denial.filterOptions.v2.${labId}`;
    try {
      const cached = sessionStorage.getItem(cacheKey);
      if (cached) setFilterOptions({ ...emptyFilterOptions, ...normalizeFilterOptions(JSON.parse(cached) || {}) });
    } catch { /* ignore bad browser cache */ }

    // Load dropdown/autocomplete values in the background. This should not block the page.
    denialWorkflowService.getFilterOptions(labId)
      .then(x => {
        const options = { ...emptyFilterOptions, ...normalizeFilterOptions(x || {}) };
        setFilterOptions(options);
        try { sessionStorage.setItem(cacheKey, JSON.stringify(options)); } catch { /* ignore storage quota */ }
      })
      .catch(err => {
        if (!sessionStorage.getItem(cacheKey)) setFilterOptions(emptyFilterOptions);
        setMessage({ type: 'danger', text: `Filter values load failed: ${err.message}` });
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
    taskView: view === 'claims' ? claimTaskView : '',
    page: debouncedFilter.page || 1,
    pageSize: 100
  }), [labId, user, debouncedFilter, reviewerOnly, view, claimTaskView]);


  async function refreshReviewerNotification() {
    if (!authReady || !labId || !reviewerOnly || !user.userName) {
      setReviewerNotification({ assignedTasks: 0, pendingTasks: 0, loading: false });
      return;
    }

    setReviewerNotification(prev => ({ ...prev, loading: true }));
    try {
      const baseQuery = {
        labId,
        role: user.role,
        userName: user.userName,
        reviewer: user.userName,
        assignedTo: user.userName,
        page: 1,
        pageSize: 1
      };

      const [assignedResult, closedResult] = await Promise.all([
        denialWorkflowService.getTasks(baseQuery),
        denialWorkflowService.getTasks({ ...baseQuery, status: 'Closed' })
      ]);

      const assignedTasks = Number(assignedResult?.totalCount || assignedResult?.items?.length || 0);
      const closedTasks = Number(closedResult?.totalCount || closedResult?.items?.length || 0);
      setReviewerNotification({ assignedTasks, pendingTasks: Math.max(assignedTasks - closedTasks, 0), loading: false });
    } catch {
      setReviewerNotification(prev => ({ ...prev, loading: false }));
    }
  }

  useEffect(() => {
    if (!authReady || !labId || !reviewerOnly) return;
    refreshReviewerNotification();
    const timer = window.setInterval(refreshReviewerNotification, 60000);
    return () => window.clearInterval(timer);
  }, [authReady, labId, reviewerOnly, user.userName, user.role]);

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
        setClaims(next);
        setSelectedClaims({});
        setClaimTasks({});
        setExpandedClaim('');
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


  function menuCountText(value) {
    if (value === null || value === undefined) return '...';
    const n = Number(value || 0);
    return n > 99999 ? `${Math.round(n / 1000)}k` : n.toLocaleString();
  }

  async function refreshMenuCounts() {
    if (!authReady || !labId) return;

    const commonFilters = {
      labId,
      role: user.role,
      userName: user.userName,
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
      page: 1,
      pageSize: 1
    };

    try {
      const [newClaims, assignedClaims, escalatedClaims, closedClaims] = await Promise.all([
        denialWorkflowService.getClaims({ ...commonFilters, taskView: 'unassigned' }),
        denialWorkflowService.getClaims({ ...commonFilters, taskView: 'assigned' }),
        denialWorkflowService.getClaims({ ...commonFilters, taskView: 'escalations' }),
        denialWorkflowService.getClaims({ ...commonFilters, taskView: 'closed' })
      ]);
      setClaimMenuCounts({
        unassigned: Number(newClaims?.totalCount || 0),
        assigned: Number(assignedClaims?.totalCount || 0),
        escalations: Number(escalatedClaims?.totalCount || 0),
        closed: Number(closedClaims?.totalCount || 0)
      });
    } catch {
      setClaimMenuCounts({ unassigned: null, assigned: null, escalations: null, closed: null });
    }

    try {
      const myFilters = {
        ...commonFilters,
        reviewer: reviewerOnly ? (user.userName || '') : (debouncedFilter.reviewer || user.userName || ''),
        assignedTo: reviewerOnly ? (user.userName || '') : (debouncedFilter.reviewer || user.userName || '')
      };
      const [newTasks, assignedTasks, escalatedTasks, closedTasks] = await Promise.all([
        denialWorkflowService.getTasks({ ...myFilters, taskView: 'open' }),
        denialWorkflowService.getTasks({ ...myFilters, taskView: 'assigned' }),
        denialWorkflowService.getTasks({ ...myFilters, taskView: 'escalations' }),
        denialWorkflowService.getTasks({ ...myFilters, taskView: 'closed' })
      ]);
      setMyWorklistMenuCounts({
        open: Number(newTasks?.totalCount || 0),
        assigned: Number(assignedTasks?.totalCount || 0),
        escalations: Number(escalatedTasks?.totalCount || 0),
        closed: Number(closedTasks?.totalCount || 0)
      });
    } catch {
      setMyWorklistMenuCounts({ open: null, assigned: null, escalations: null, closed: null });
    }
  }

  useEffect(() => {
    if (!authReady || !labId) return;
    refreshMenuCounts();
  }, [authReady, labId, user.role, user.userName, reviewerOnly, debouncedFilter]);

  const labName = labs.find(l => Number(l.labId ?? l.LabId) === Number(labId))?.labName || 'Select Lab';
  const pageTitle = { dashboard: 'Denial Workflow Dashboard', summary: 'Denial Summary', claims: 'Claim Level Assignment', myworklist: 'My Worklist', tasks: 'Task Board', escalations: 'Escalation Queue', verification: 'Verification Queue' }[view] || 'Denial Workflow';
  const claimNavTabs = useMemo(() => ([
    { key: 'unassigned', label: 'New' },
    { key: 'assigned', label: 'Assigned' },
    { key: 'escalations', label: 'Escalate' },
    { key: 'closed', label: 'Closed' }
  ]), []);
  const myWorklistNavTabs = useMemo(() => ([
    { key: 'open', label: 'New' },
    { key: 'assigned', label: 'Assigned' },
    { key: 'escalations', label: 'Escalate' },
    { key: 'closed', label: 'Closed' }
  ]), []);
  const escalationNavTabs = useMemo(() => ([
    { key: 'claim', label: 'Claim level' },
    { key: 'line', label: 'Line level' }
  ]), []);

  function handleClaimTaskViewChange(nextView) {
    if (nextView === claimTaskView) return;
    setClaimTaskView(nextView);
    setFilter(f => (Number(f.page || 1) === 1 ? f : { ...f, page: 1 }));
    setClaims(emptyPagedResult);
    setSelectedClaims({});
    setClaimTasks({});
    setExpandedClaim('');
  }

  function handleMyWorklistViewChange(nextView) {
    if (nextView === myWorklistView) return;
    setMyWorklistView(nextView);
  }

  useEffect(() => {
    if (clientManager && myWorklistView !== 'escalations') setMyWorklistView('escalations');
  }, [clientManager, myWorklistView]);

  function setFilterValue(k, v) { setFilter(f => ({ ...f, [k]: v, page: 1 })); }
  function clearFilter() { setFilter(emptyFilter); }
  function changePage(page) { setFilter(f => ({ ...f, page })); }


  function openClaimsByClassification(classification) {
    setFilter(f => ({
      ...f,
      denialClassification: classification || '',
      page: 1
    }));
    if (reviewerOnly) {
      setMyWorklistView('open');
      setView('myworklist');
      return;
    }
    setClaimTaskView('unassigned');
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
    if (reviewerOnly) {
      setMyWorklistView('open');
      setView('myworklist');
      return;
    }
    setClaimTaskView('unassigned');
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
      const rows = await denialWorkflowService.getClaimTasks(labId, claimId, claimTaskView);
      setClaimTasks(prev => ({ ...prev, [claimId]: rows || [] }));
    } catch (err) { setMessage({ type: 'danger', text: err.message }); }
  }

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
      setClaims(await denialWorkflowService.getClaims({ ...query, taskView: claimTaskView }));
    } catch (err) { setMessage({ type: 'danger', text: err.message }); }
    finally { setLoading(false); }
  }

  async function saveTask(task, status, comments) {
    setLoading(true);
    try {
      const result = await denialWorkflowService.updateTask({ labId, taskId: task.taskId, status, comments, actionBy: user.userName || 'ReactWorkflow' });
      setMessage({ type: result.success ? 'success' : 'warning', text: result.message || 'Task saved.' });
      setTasks(await denialWorkflowService.getTasks(query));
      refreshReviewerNotification();
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
    <div className={`sidebar-backdrop ${sidebarOpen ? 'open' : ''}`} onClick={() => setSidebarOpen(false)} />
    <aside className={`lrn-sidebar ${sidebarOpen ? 'open' : ''}`}>
      <div className="lrn-brand"><div className="lrn-brand-icon">LRN</div><div><div className="lrn-brand-text">Lab Revenue</div><div className="lrn-brand-sub">Intelligence Navigator</div></div></div>
      <div className="user-card"><span className="avatar-sm">{initials(user.displayName || user.userName)}</span><div><strong>{user.displayName || user.userName || 'LRN User'}</strong><small>{user.role || 'Workflow User'}</small></div></div>
      <nav className="lrn-nav">
        <div className="lrn-nav-section">Overview</div>
        <button className={`lrn-nav-item ${view === 'dashboard' ? 'active' : ''}`} onClick={() => setView('dashboard')}><i className="bi bi-grid-1x2-fill" />Dashboard</button>
        <div className="lrn-nav-section">Denial Workflow</div>
        <button className={`lrn-nav-item ${view === 'summary' ? 'active' : ''}`} onClick={() => setView('summary')}><i className="bi bi-table" />Denial Summary</button>
        {!reviewerOnly && (
          <>
            <button className={`lrn-nav-item ${view === 'claims' ? 'active' : ''}`} onClick={() => setView('claims', { closeSidebar: false })}><i className="bi bi-folder-check" />{canAssign ? 'Claim Assignment' : 'Claim View'}</button>
            {view === 'claims' && (
              <div className="lrn-nav-submenu">
                {claimNavTabs.map(t => (
                  <button key={t.key} type="button" className={`lrn-nav-subitem ${claimTaskView === t.key ? 'active' : ''}`} onClick={() => { setView('claims'); handleClaimTaskViewChange(t.key); }}>
                    <span className="nav-sub-label">{t.label}</span><span className="nav-sub-count">{menuCountText(claimMenuCounts[t.key])}</span>
                  </button>
                ))}
              </div>
            )}
          </>
        )}
        <div className="lrn-nav-section">My Tasks</div>
        <button className={`lrn-nav-item ${view === 'myworklist' ? 'active' : ''}`} onClick={() => setView('myworklist', { closeSidebar: false })}><i className="bi bi-person-check" />My Worklist</button>
        {view === 'myworklist' && (
          <div className="lrn-nav-submenu">
            {myWorklistNavTabs.map(t => (
              <button key={t.key} type="button" className={`lrn-nav-subitem ${myWorklistView === t.key ? 'active' : ''}`} onClick={() => { setView('myworklist'); handleMyWorklistViewChange(t.key); }}>
                <span className="nav-sub-label">{t.label}</span><span className="nav-sub-count">{menuCountText(myWorklistMenuCounts[t.key])}</span>
              </button>
            ))}
          </div>
        )}
        {(canAssign || clientManager || readOnlyWorkflow) && (
          <>
            <button className={`lrn-nav-item ${view === 'escalations' ? 'active' : ''}`} onClick={() => setView('escalations', { closeSidebar: false })}><i className="bi bi-exclamation-triangle" />Escalation Queue<span className="lrn-nav-badge">{menuCountText(claimMenuCounts.escalations)}</span></button>
            {view === 'escalations' && (
              <div className="lrn-nav-submenu">
                {escalationNavTabs.map(t => (
                  <button key={t.key} type="button" className={`lrn-nav-subitem ${escalationView === t.key ? 'active' : ''}`} onClick={() => { setView('escalations'); setEscalationView(t.key); }}>
                    <span className="nav-sub-label">{t.label}</span>
                  </button>
                ))}
              </div>
            )}
          </>
        )}
        <button className={`lrn-nav-item ${view === 'tasks' ? 'active' : ''}`} onClick={() => setView('tasks')}><i className="bi bi-list-check" />Task Board<span className="lrn-nav-badge">{dashboard.openInProgressCount || 0}</span></button>
        <button className={`lrn-nav-item ${view === 'verification' ? 'active' : ''}`} onClick={() => setView('verification')}><i className="bi bi-shield-check" />Verification</button>
      </nav>
      <div className="lrn-sync"><div>API endpoint</div><span>{API_BASE}</span></div>
      <div className="sidebar-logout"><button type="button" className="sidebar-logout-btn" onClick={logoutWorkflow}><i className="bi bi-box-arrow-right" />Logout</button></div>
    </aside>
    <div className="lrn-main">
      <header className="lrn-topbar">
        <div className="topbar-left">
          <button type="button" className="menu-toggle" onClick={() => setSidebarOpen(v => !v)} aria-label="Toggle menu"><i className="bi bi-list" /></button>
          <div><div className="lrn-page-title">{pageTitle}</div><div className="lrn-breadcrumb">LRN Analytics / <span>{pageTitle}</span></div></div>
        </div>
        <div className="topbar-actions">{reviewerOnly && <button type="button" className="notification-btn" title="Pending assigned tasks" onClick={() => setView('myworklist')}><i className="bi bi-bell-fill" /><span className="notification-count">{reviewerNotification.pendingTasks}</span><span className="notification-text"><b>{reviewerNotification.pendingTasks}</b> pending / {reviewerNotification.assignedTasks} assigned</span></button>}<select className="top-lab-select" value={labId || ''} onChange={e => setLabId(Number(e.target.value))}>{labs.map(l => <option key={l.labId ?? l.LabId} value={l.labId ?? l.LabId}>{l.labName ?? l.LabName}</option>)}</select><span className="current-lab">{labName}</span><button className="topbar-btn teal" onClick={() => setMessage({ type: 'info', text: 'Use backend export endpoint for Excel download.' })}><i className="bi bi-download" />Export</button><button type="button" className="topbar-btn" onClick={logoutWorkflow}><i className="bi bi-box-arrow-right" />Logout</button></div>
      </header>
      <main className="lrn-content">
        {view !== 'myworklist' && <DashboardFilter filter={filter} setFilterValue={setFilterValue} clearFilter={clearFilter} reviewers={reviewers} options={filterOptions} />}
        {message && <div className={`lrn-alert ${message.type}`}>{message.text}</div>}
        {loading && <div className="loading-line" />}
        {view === 'dashboard' && <DashboardPage data={dashboard} user={user} labName={labName} />}
        {view === 'summary' && <DenialSummaryPage data={dashboard} canAssign={canAssign} onClassificationClick={openClaimsByClassification} onActionCategoryClick={openClaimsByActionCategory} onAssign={() => { setClaimTaskView('unassigned'); setView((reviewerOnly || readOnlyWorkflow) ? 'myworklist' : 'claims'); setMessage({ type: 'info', text: canAssign ? 'Select the required claim rows, choose reviewer, then assign.' : 'This role has read-only workflow access.' }); }} />}
        {view === 'claims' && <ClaimAssignmentPage data={claims} reviewers={reviewers} selected={selectedClaims} setSelected={setSelectedClaims} bulkReviewer={bulkReviewer} setBulkReviewer={setBulkReviewer} loadClaimTasks={loadClaimTasks} claimTasks={claimTasks} expandedClaim={expandedClaim} assignClaims={assignClaims} changePage={changePage} labId={labId} currentUser={user.userName || 'ReactWorkflow'} canAssign={canAssign} readOnlyWorkflow={readOnlyWorkflow} taskView={claimTaskView} setTaskView={handleClaimTaskViewChange} />}
        {view === 'myworklist' && <MyWorklistPage labId={labId} user={user} options={filterOptions} filter={filter} setMessage={setMessage} onSaved={refreshReviewerNotification} taskView={myWorklistView} setTaskView={handleMyWorklistViewChange} />}
        {view === 'escalations' && <EscalationQueuePage labId={labId} user={user} reviewers={reviewers} taskView={escalationView} setTaskView={setEscalationView} setMessage={setMessage} />}
        {view === 'tasks' && <TasksPage data={tasks} saveTask={saveTask} changePage={changePage} labId={labId} currentUser={user.userName || 'ReactWorkflow'} userRole={user.role || ''} readOnlyWorkflow={readOnlyWorkflow} />}
        {view === 'verification' && <VerificationPage data={verification} changePage={changePage} labId={labId} currentUser={user.userName || 'ReactWorkflow'} />}
      </main>
    </div>
  </div>;
}
