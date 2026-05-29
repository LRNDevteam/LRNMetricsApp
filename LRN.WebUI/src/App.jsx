import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { API_BASE, LOGOUT_URL } from './config/apiConfig';
import { emptyDashboard, emptyFilter, emptyFilterOptions, emptyPagedResult } from './dto/denialWorkflowDtos';
import { denialWorkflowService, qs } from './services/denialWorkflowService';
import { claimRole, claimUser, clearWorkflowJwt, ensureWorkflowJwt, getJwt, parseJwt } from './utils/auth';
import { canAssignRole, initials, isArReviewerRole, isClientManagerRole, isAccountManagerRole, isReadOnlyWorkflowRole } from './utils/formatters';
import DashboardFilter from './components/DashboardFilter';
import DashboardPage from './pages/DashboardPage';
import AgingDashboardPage from './pages/AgingDashboardPage';
import DenialSummaryPage from './pages/DenialSummaryPage';
import ClaimAssignmentPage from './pages/ClaimAssignmentPage';
import MyWorklistPage from './pages/MyWorklistPage';
import EscalationQueuePage from './pages/EscalationQueuePage';
import VerificationPage from './pages/VerificationPage';

function roleIsReviewerOnly(role) { return isArReviewerRole(role); }

export default function App() {
  const jwtClaims = useMemo(() => parseJwt(getJwt()), []);
  const [user, setUser] = useState({ userName: claimUser(jwtClaims), role: claimRole(jwtClaims), labs: [] });
  const [labs, setLabs] = useState([]);
  const [reviewers, setReviewers] = useState([]);
  const [filterOptions, setFilterOptions] = useState(emptyFilterOptions);
  const [labId, setLabId] = useState(Number(localStorage.getItem('denial.labId') || 0));
  const workflowViews = ['dashboard', 'aging', 'summary', 'claims', 'myworklist', 'escalations', 'verification'];
  const getStoredView = () => {
    const hashView = String(window.location.hash || '').replace('#', '').trim().toLowerCase();
    if (hashView === 'dashboard' || hashView === 'summary') return 'aging';
    return workflowViews.includes(hashView) ? hashView : '';
  };
  const [view, setViewState] = useState(getStoredView() || 'aging');
  const [filter, setFilter] = useState(emptyFilter);
  const [debouncedFilter, setDebouncedFilter] = useState(emptyFilter);
  const [dashboard, setDashboard] = useState(emptyDashboard);
  const [agingDashboard, setAgingDashboard] = useState({});
  const [claims, setClaims] = useState(emptyPagedResult);
  const [tasks, setTasks] = useState(emptyPagedResult);
  const [verification, setVerification] = useState(emptyPagedResult);
  const [selected, setSelected] = useState({});
  const [selectedClaims, setSelectedClaims] = useState({});
  const [claimTasks, setClaimTasks] = useState({});
  const [expandedClaim, setExpandedClaim] = useState('');
  const [claimTaskView, setClaimTaskView] = useState('new');
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
  const [workflowNotifications, setWorkflowNotifications] = useState({ loading: false, sections: [], total: 0 });
  const [notificationOpen, setNotificationOpen] = useState(false);
  const [notificationPopupOpen, setNotificationPopupOpen] = useState(false);
  const initialNotificationKeyRef = useRef('');
  const [claimMenuCounts, setClaimMenuCounts] = useState({ new: null, unassigned: null, assigned: null, escalations: null, internalEscalation: null, externalEscalation: null, escalationResponse: null, verification: null, closed: null });
  const [myWorklistMenuCounts, setMyWorklistMenuCounts] = useState({ open: null, assigned: null, escalations: null, closed: null });
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [claimFiltersOpen, setClaimFiltersOpen] = useState(false);
  const claimRequestSeq = useRef(0);
  const claimAbortRef = useRef(null);
  const lastClaimQueryKeyRef = useRef('');
  const reviewerOnly = roleIsReviewerOnly(user.role);
  const canAssign = canAssignRole(user.role);
  const clientManager = isClientManagerRole(user.role);
  const accountManager = isAccountManagerRole(user.role);
  const externalManager = clientManager || accountManager;
  const adminRole = String(user.role || '').toLowerCase().includes('admin');
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
      panelNames: toStrings(fromMaybeDelimitedString(source.panelNames ?? source.PanelNames), ['panelName', 'PanelName', 'name', 'Name']),
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
    panelName: debouncedFilter.panelName,
    clinic: debouncedFilter.clinic,
    salesRepname: debouncedFilter.salesRepname,
    referringProvider: debouncedFilter.referringProvider,
    denialClassification: debouncedFilter.denialClassification,
    searchText: debouncedFilter.searchText,
    fromDate: debouncedFilter.fromDate || '',
    toDate: debouncedFilter.toDate || '',
    taskView: view === 'claims' ? claimTaskView : '',
    page: debouncedFilter.page || 1,
    pageSize: 100
  }), [labId, user.role, user.userName, debouncedFilter, reviewerOnly, view, claimTaskView]);

  const menuCountQuery = useMemo(() => ({
    labId,
    role: user.role,
    userName: user.userName,
    reviewer: reviewerOnly ? (user.userName || '') : debouncedFilter.reviewer,
    assignedTo: reviewerOnly ? (user.userName || '') : debouncedFilter.reviewer,
    actionCategory: debouncedFilter.actionCategory,
    priority: debouncedFilter.priority,
    denialCode: debouncedFilter.denialCode,
    payerName: debouncedFilter.payerName,
    panelName: debouncedFilter.panelName,
    clinic: debouncedFilter.clinic,
    salesRepname: debouncedFilter.salesRepname,
    referringProvider: debouncedFilter.referringProvider,
    denialClassification: debouncedFilter.denialClassification,
    searchText: debouncedFilter.searchText,
    page: 1,
    pageSize: 1
  }), [
    labId,
    user.role,
    user.userName,
    reviewerOnly,
    debouncedFilter.reviewer,
    debouncedFilter.actionCategory,
    debouncedFilter.priority,
    debouncedFilter.denialCode,
    debouncedFilter.payerName,
    debouncedFilter.clinic,
    debouncedFilter.salesRepname,
    debouncedFilter.referringProvider,
    debouncedFilter.denialClassification,
    debouncedFilter.searchText
  ]);


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

  function normalizeNotificationItems(result) {
    const rows = result?.items || [];
    const seen = new Set();
    return rows.map(row => ({
      claimId: row.claimId || row.ClaimId || '',
      taskId: row.taskId || row.TaskId || '',
      cptCode: row.cptCode || row.CptCode || '',
      payerName: row.payerName || row.PayerName || row.payerNameNormalized || '',
      status: row.status || row.Status || '',
      assignedTo: row.assignedTo || row.AssignedTo || '',
      actionCategory: row.actionCategory || row.ActionCategory || row.escalationReason || '',
      slaStatus: row.slaStatus || row.SlaStatus || '',
      balance: Number(row.insuranceBalance ?? row.InsuranceBalance ?? 0)
    })).filter(item => {
      const key = `${item.claimId}|${item.taskId}|${item.cptCode}`;
      if (!item.claimId || seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  }

  function distinctClaimCount(items) {
    return new Set((items || []).map(item => item.claimId).filter(Boolean)).size;
  }

  function normalizeEscalationNotificationItems(result) {
    const rows = result?.items || [];
    return rows.map(row => ({
      claimId: row.claimId || row.ClaimId || '',
      taskId: row.taskId || row.TaskId || '',
      cptCode: row.cptCode || row.CptCode || '',
      payerName: row.payerName || row.PayerName || '',
      status: row.status || row.Status || 'Open',
      assignedTo: row.escalatedTo || row.EscalatedTo || '',
      actionCategory: row.escalationReason || row.EscalationReason || 'Escalation',
      slaStatus: row.slaStatus || row.SlaStatus || '',
      balance: Number(row.insuranceBalance ?? row.InsuranceBalance ?? 0)
    })).filter(item => item.claimId);
  }

  async function refreshWorkflowNotifications() {
    if (!authReady || !labId || (!reviewerOnly && !externalManager)) {
      setWorkflowNotifications({ loading: false, sections: [], total: 0 });
      setNotificationOpen(false);
      setNotificationPopupOpen(false);
      return;
    }

    setWorkflowNotifications(prev => ({ ...prev, loading: true }));
    try {
      let sections = [];
      if (reviewerOnly) {
        const baseQuery = {
          labId,
          role: user.role,
          userName: user.userName,
          reviewer: user.userName,
          assignedTo: user.userName,
          page: 1,
          pageSize: 500
        };
        const [assigned, pending, actionRequired, escalations] = await Promise.all([
          denialWorkflowService.getTasks({ ...baseQuery, taskView: 'assigned' }),
          denialWorkflowService.getTasks({ ...baseQuery, taskView: 'open' }),
          denialWorkflowService.getTasks({ ...baseQuery, status: 'Pending Review' }),
          denialWorkflowService.getTasks({ ...baseQuery, taskView: 'escalations' })
        ]);
        const assignedItems = normalizeNotificationItems(assigned);
        const pendingItems = normalizeNotificationItems(pending);
        const actionRequiredItems = normalizeNotificationItems(actionRequired);
        const escalationItems = normalizeNotificationItems(escalations);
        sections = [
          { key: 'assigned', label: 'Assigned claims', count: distinctClaimCount(assignedItems), items: assignedItems, targetView: 'assigned' },
          { key: 'pending', label: 'Pending claims', count: distinctClaimCount(pendingItems), items: pendingItems, targetView: 'open' },
          { key: 'action', label: 'Action required claims', count: distinctClaimCount(actionRequiredItems), items: actionRequiredItems, targetView: 'open', status: 'Pending Review' },
          { key: 'escalations', label: 'Escalation claims', count: distinctClaimCount(escalationItems), items: escalationItems, targetView: 'escalations' }
        ].filter(section => section.count > 0);
      } else if (externalManager) {
        const managerBaseQuery = {
          labId,
          role: user.role,
          userName: user.userName,
          page: 1,
          pageSize: 500
        };
        const escalations = await denialWorkflowService.getEscalationQueue(managerBaseQuery, 'Claim');
        const escalationItems = normalizeEscalationNotificationItems(escalations);
        sections = [
          {
            key: 'manager-escalations',
            label: 'Escalation claims',
            count: distinctClaimCount(escalationItems),
            items: escalationItems,
            targetView: 'manager-escalations'
          }
        ].filter(section => section.count > 0);
      }

      const total = sections.reduce((sum, section) => sum + Number(section.count || 0), 0);
      setWorkflowNotifications({ loading: false, sections, total });
      const key = `${user.userName || ''}|${user.role || ''}|${labId}`;
      if (total > 0 && initialNotificationKeyRef.current !== key) {
        initialNotificationKeyRef.current = key;
        setNotificationPopupOpen(true);
      }
      if (total === 0) {
        setNotificationOpen(false);
        setNotificationPopupOpen(false);
      }
    } catch {
      setWorkflowNotifications(prev => ({ ...prev, loading: false }));
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
    refreshWorkflowNotifications();
    const timer = window.setInterval(refreshWorkflowNotifications, 60000);
    return () => window.clearInterval(timer);
  }, [authReady, labId, reviewerOnly, externalManager, user.userName, user.role]);

  useEffect(() => {
    if (!authReady || !labId) return;

    const requestId = ++claimRequestSeq.current;
    const abortController = new AbortController();
    const isClaimView = view === 'claims';

    if (isClaimView) {
      const key = JSON.stringify(query);
      if (lastClaimQueryKeyRef.current === key && claims?.items?.length) return;
      lastClaimQueryKeyRef.current = key;
      if (claimAbortRef.current) claimAbortRef.current.abort();
      claimAbortRef.current = abortController;
    }

    setLoading(true);
    setMessage(null);

    let call;
    if (view === 'dashboard' || view === 'summary') {
      call = denialWorkflowService.getDashboard(query).then(setDashboard);
    } else if (view === 'aging') {
      call = denialWorkflowService.getAgingDashboard(query).then(setAgingDashboard);
    } else if (view === 'claims') {
      call = denialWorkflowService.getClaims(query, { signal: abortController.signal }).then(c => {
        if (requestId !== claimRequestSeq.current || abortController.signal.aborted) return;
        const next = c || emptyPagedResult;
        setClaims(next);
        setClaimMenuCounts(prev => ({ ...prev, [claimTaskView]: Number(next.totalCount || 0) }));
        setSelectedClaims({});
        setClaimTasks({});
        setExpandedClaim('');
      });
    } else if (view === 'verification') {
      call = denialWorkflowService.getVerification(query, { signal: abortController.signal }).then(setVerification);
    } else {
      call = Promise.resolve();
    }

    call
      .catch(err => {
        if (abortController.signal.aborted || err?.name === 'AbortError') return;
        setMessage({ type: 'danger', text: err.message });
      })
      .finally(() => {
        if (requestId === claimRequestSeq.current || !isClaimView) setLoading(false);
      });

    return () => {
      if (isClaimView) abortController.abort();
    };
  }, [authReady, labId, view, query, reviewerOnly]);



  function menuCountText(value) {
    if (value === null || value === undefined) return '...';
    const n = Number(value || 0);
    return n > 99999 ? `${Math.round(n / 1000)}k` : n.toLocaleString();
  }

  async function refreshMenuCounts() {
    if (!authReady || !labId) return;

    // Do not call /claims four times only to calculate menu badges.
    // The backend already has a light count endpoint for these values.
    try {
      const counts = await denialWorkflowService.getClaimMenuCounts(menuCountQuery);
      setClaimMenuCounts({
        new: Number(counts?.new ?? counts?.New ?? 0),
        unassigned: Number(counts?.unassigned ?? counts?.Unassigned ?? 0),
        assigned: Number(counts?.assigned ?? counts?.Assigned ?? 0),
        escalations: Number(counts?.escalated ?? counts?.Escalated ?? 0),
        internalEscalation: Number(counts?.internalEscalation ?? counts?.InternalEscalation ?? 0),
        externalEscalation: Number(counts?.externalEscalation ?? counts?.ExternalEscalation ?? 0),
        escalationResponse: Number(counts?.escalationResponse ?? counts?.EscalationResponse ?? 0),
        verification: Number(counts?.verification ?? counts?.Verification ?? 0),
        closed: Number(counts?.closed ?? counts?.Closed ?? 0)
      });
    } catch {
      setClaimMenuCounts({ new: 0, unassigned: 0, assigned: 0, escalations: 0, internalEscalation: 0, externalEscalation: 0, escalationResponse: 0, verification: 0, closed: 0 });
    }

    try {
      const myFilters = {
        ...menuCountQuery,
        reviewer: reviewerOnly ? (user.userName || '') : (menuCountQuery.reviewer || user.userName || ''),
        assignedTo: reviewerOnly ? (user.userName || '') : (menuCountQuery.assignedTo || user.userName || '')
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
  }, [authReady, labId, menuCountQuery, reviewerOnly]);

  const labName = labs.find(l => Number(l.labId ?? l.LabId) === Number(labId))?.labName || 'Select Lab';
  const pageTitle = { dashboard: 'Denial Workflow Dashboard', aging: 'Aging Dashboard', summary: 'Denial Summary', claims: canAssign ? 'Claim Level Assignment' : 'Claim View', myworklist: 'My Worklist', escalations: escalationView === 'response' ? 'Escalation Response' : 'Escalation Queue', verification: 'Verification' }[view] || 'Denial Workflow';
  const claimNavTabs = useMemo(() => ([
    { key: 'new', label: 'New' },
    { key: 'unassigned', label: 'Unassigned' },
    { key: 'assigned', label: 'Assigned' },
    { key: 'internalEscalation', label: 'Internal Escalation' },
    { key: 'externalEscalation', label: 'External Escalation' },
    { key: 'closed', label: 'Closed' },
    ...(canAssign ? [{ key: 'response', label: 'Escalation Response', countKey: 'escalationResponse' }, { key: 'verification', label: 'Verification' }] : [])
  ]), [canAssign]);
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

  function handleClaimTabRoute(nextView) {
    if (nextView === 'response') {
      setEscalationView('response');
      setView('escalations');
      return;
    }
    if (nextView === 'verification') {
      setView('verification');
      return;
    }
    setView('claims');
    handleClaimTaskViewChange(nextView);
  }

  function handleMyWorklistViewChange(nextView) {
    if (nextView === myWorklistView) return;
    setMyWorklistView(nextView);
  }

  useEffect(() => {
    if (externalManager && myWorklistView !== 'escalations') setMyWorklistView('escalations');
  }, [externalManager, myWorklistView]);

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
    setClaimTaskView('new');
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
    setClaimTaskView('new');
    setView('claims');
    setMessage({
      type: 'info',
      text: actionCategory
        ? `Showing Claim Assignment filtered by Action Category: ${actionCategory}`
        : 'Showing Claim Assignment filtered by Unclassified action category.'
    });
  }

  function openNotificationSection(section, item = null) {
    setNotificationOpen(false);
    setNotificationPopupOpen(false);
    if (reviewerOnly) {
      setMyWorklistView(section?.targetView || 'open');
      setFilter(f => ({
        ...f,
        status: section?.status || '',
        searchText: item?.claimId || '',
        page: 1
      }));
      setView('myworklist');
      return;
    }

    if (externalManager) {
      setEscalationView('claim');
      setFilter(f => ({
        ...f,
        searchText: item?.claimId || '',
        page: 1
      }));
      setView('escalations');
    }
  }

  function NotificationDetails({ popup = false }) {
    const sections = workflowNotifications.sections || [];
    if (!sections.length) return null;
    return <div className={popup ? 'workflow-notification-panel popup' : 'workflow-notification-panel'}>
      {sections.map(section => <div className="workflow-notification-section" key={section.key}>
        <button type="button" className="notification-section-head" onClick={() => openNotificationSection(section)}>
          <span>{section.label}</span>
          <b>{Number(section.count || 0).toLocaleString()}</b>
        </button>
        <div className="notification-claim-list">
          {(section.items || []).length ? section.items.map((item, index) => (
            <button type="button" className="notification-claim-row" key={`${section.key}-${item.claimId}-${item.taskId}-${index}`} onClick={() => openNotificationSection(section, item)}>
              <strong>{item.claimId}</strong>
              <span>{item.actionCategory || item.status || 'Claim'}</span>
              <small>{item.payerName || 'Payer not available'}{item.slaStatus ? ` · ${item.slaStatus}` : ''}</small>
            </button>
          )) : <div className="notification-empty">Open the section to view claim details.</div>}
        </div>
      </div>)}
    </div>;
  }

  function WorkflowNotificationPopup() {
    if (!notificationPopupOpen || !workflowNotifications.total) return null;
    return <div className="workflow-popup-backdrop" onMouseDown={() => setNotificationPopupOpen(false)}>
      <div className="workflow-popup-modal" onMouseDown={e => e.stopPropagation()}>
        <div className="workflow-popup-head">
          <div><strong>Claims need attention</strong><span>{Number(workflowNotifications.total || 0).toLocaleString()} distinct claim(s) available for your role.</span></div>
          <button type="button" className="modal-close" onClick={() => setNotificationPopupOpen(false)}>×</button>
        </div>
        <div className="workflow-popup-counts">
          {(workflowNotifications.sections || []).map(section => (
            <button type="button" className="workflow-popup-count-row" key={section.key} onClick={() => openNotificationSection(section)}>
              <span>{section.label}</span>
              <b>{Number(section.count || 0).toLocaleString()}</b>
            </button>
          ))}
        </div>
      </div>
    </div>;
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
      refreshWorkflowNotifications();
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
    <WorkflowNotificationPopup />
    <div className={`sidebar-backdrop ${sidebarOpen ? 'open' : ''}`} onClick={() => setSidebarOpen(false)} />
    <aside className={`lrn-sidebar ${sidebarOpen ? 'open' : ''}`}>
      <div className="lrn-brand"><div className="lrn-brand-icon">LRN</div><div><div className="lrn-brand-text">Lab Revenue</div><div className="lrn-brand-sub">Intelligence Navigator</div></div></div>
      <div className="user-card"><span className="avatar-sm">{initials(user.displayName || user.userName)}</span><div><strong>{user.displayName || user.userName || 'LRN User'}</strong><small>{user.role || 'Workflow User'}</small></div></div>
      <nav className="lrn-nav">
        <div className="lrn-nav-section">Overview</div>
        <button className={`lrn-nav-item ${view === 'aging' ? 'active' : ''}`} onClick={() => setView('aging')}><i className="bi bi-hourglass-split" />Aging Dashboard</button>
        <div className="lrn-nav-section">Denial Workflow</div>
        {(canAssign || externalManager || adminRole) && (
          <>
            <button className={`lrn-nav-item ${(view === 'claims' || view === 'verification' || (view === 'escalations' && escalationView === 'response')) ? 'active' : ''}`} onClick={() => setView('claims', { closeSidebar: false })}><i className="bi bi-folder-check" />{canAssign ? 'Claim Assignment' : 'Claim View'}</button>
            {(view === 'claims' || view === 'verification' || (view === 'escalations' && escalationView === 'response')) && (
              <div className="lrn-nav-submenu">
                {claimNavTabs.map(t => {
                  const isResponse = t.key === 'response';
                  const isVerification = t.key === 'verification';
                  const isActive = isResponse ? (view === 'escalations' && escalationView === 'response') : isVerification ? view === 'verification' : (view === 'claims' && claimTaskView === t.key);
                  return <button key={t.key} type="button" className={`lrn-nav-subitem ${isActive ? 'active' : ''}`} onClick={() => {
                    if (isResponse) { setEscalationView('response'); setView('escalations'); }
                    else if (isVerification) { setView('verification'); }
                    else { setView('claims'); handleClaimTaskViewChange(t.key); }
                  }}>
                    <span className="nav-sub-label">{t.label}</span><span className="nav-sub-count">{menuCountText(claimMenuCounts[t.countKey || t.key])}</span>
                  </button>;
                })}
              </div>
            )}
          </>
        )}
        {(reviewerOnly || adminRole) && (
          <>
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
          </>
        )}
        {(!canAssign && (externalManager || readOnlyWorkflow)) && (
          <>
            <button className={`lrn-nav-item ${view === 'escalations' ? 'active' : ''}`} onClick={() => setView('escalations', { closeSidebar: false })}><i className="bi bi-exclamation-triangle" />{canAssign ? 'Escalation Response' : 'Escalation Queue'}<span className="lrn-nav-badge">{menuCountText(claimMenuCounts.escalations)}</span></button>
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
      </nav>
      <div className="sidebar-logout"><button type="button" className="sidebar-logout-btn" onClick={logoutWorkflow}><i className="bi bi-box-arrow-right" />Logout</button></div>
    </aside>
    <div className="lrn-main">
      <header className="lrn-topbar">
        <div className="topbar-left">
          <button type="button" className="menu-toggle" onClick={() => setSidebarOpen(v => !v)} aria-label="Toggle menu"><i className="bi bi-list" /></button>
          <div><div className="lrn-page-title">{pageTitle}</div><div className="lrn-breadcrumb">LRN Analytics / <span>{pageTitle}</span></div></div>
        </div>
        <div className="topbar-actions">{workflowNotifications.total > 0 && <div className="notification-wrap"><button type="button" className="notification-btn" title="Claims needing attention" onClick={() => setNotificationOpen(v => !v)}><i className="bi bi-bell-fill" /><span className="notification-count">{workflowNotifications.total}</span><span className="notification-text"><b>{workflowNotifications.total}</b> {reviewerOnly ? 'claims need attention' : 'escalation claim(s)'}</span></button>{notificationOpen && <NotificationDetails />}</div>}<select className="top-lab-select" value={labId || ''} onChange={e => setLabId(Number(e.target.value))}>{labs.map(l => <option key={l.labId ?? l.LabId} value={l.labId ?? l.LabId}>{l.labName ?? l.LabName}</option>)}</select><span className="current-lab">{labName}</span><button className="topbar-btn teal" onClick={() => setMessage({ type: 'info', text: 'Use backend export endpoint for Excel download.' })}><i className="bi bi-download" />Export</button><button type="button" className="topbar-btn" onClick={logoutWorkflow}><i className="bi bi-box-arrow-right" />Logout</button></div>
      </header>
      <main className="lrn-content">
        {view === 'claims' && <div className="claim-filter-toggle-row"><button type="button" className="wl-btn xs" onClick={() => setClaimFiltersOpen(v => !v)}><i className={`bi ${claimFiltersOpen ? 'bi-eye-slash' : 'bi-funnel'}`} />{claimFiltersOpen ? 'Hide Filters' : 'View Filters'}</button></div>}
        {view !== 'myworklist' && view !== 'aging' && (
          <div className={(view === 'verification' || view === 'escalations' || (view === 'claims' && !claimFiltersOpen)) ? 'global-filter-hidden' : ''}>
            <DashboardFilter filter={filter} setFilterValue={setFilterValue} clearFilter={clearFilter} reviewers={reviewers} options={filterOptions} />
          </div>
        )}
        {message && <div className={`lrn-alert ${message.type}`}>{message.text}</div>}
        {loading && <div className="loading-line" />}
        {view === 'dashboard' && <DashboardPage data={dashboard} user={user} labName={labName} />}
        {view === 'aging' && <AgingDashboardPage data={agingDashboard} filter={filter} setFilterValue={setFilterValue} clearFilter={clearFilter} reviewers={reviewers} options={filterOptions} onCellClick={({ pivot, row, bucket }) => {
          const next = { page: 1 };
          if (pivot === 'payer') next.payerName = row?.name || '';
          if (pivot === 'classification') next.denialClassification = row?.name || '';
          if (pivot === 'action') next.actionCategory = row?.name || '';
          setFilter(f => ({ ...f, ...next }));
          setClaimTaskView('new');
          setView((reviewerOnly || readOnlyWorkflow) ? 'myworklist' : 'claims');
          setMessage({ type: 'info', text: `Showing claims for ${row?.name || 'selected group'} / ${bucket?.label || 'aging bucket'}.` });
        }} />}
        {view === 'summary' && <DenialSummaryPage data={dashboard} canAssign={canAssign} onClassificationClick={openClaimsByClassification} onActionCategoryClick={openClaimsByActionCategory} onAssign={() => { setClaimTaskView('new'); setView((reviewerOnly || readOnlyWorkflow) ? 'myworklist' : 'claims'); setMessage({ type: 'info', text: canAssign ? 'Select the required claim rows, choose reviewer, then assign.' : 'This role has read-only workflow access.' }); }} />}
        {view === 'claims' && <ClaimAssignmentPage data={claims} reviewers={reviewers} selected={selectedClaims} setSelected={setSelectedClaims} bulkReviewer={bulkReviewer} setBulkReviewer={setBulkReviewer} loadClaimTasks={loadClaimTasks} claimTasks={claimTasks} expandedClaim={expandedClaim} assignClaims={assignClaims} changePage={changePage} labId={labId} currentUser={user.userName || 'ReactWorkflow'} canAssign={canAssign} readOnlyWorkflow={readOnlyWorkflow} taskView={claimTaskView} setTaskView={handleClaimTaskViewChange} tabCounts={claimMenuCounts} openEscalationResponse={() => handleClaimTabRoute('response')} openVerification={() => handleClaimTabRoute('verification')} setMessage={setMessage} />}
        {view === 'verification' && <VerificationPage data={verification} changePage={changePage} tabCounts={claimMenuCounts} onTabChange={handleClaimTabRoute} reviewers={reviewers} canAssign={canAssign} assignClaims={assignClaims} />}
        {view === 'myworklist' && <MyWorklistPage labId={labId} user={user} options={filterOptions} filter={filter} setMessage={setMessage} onSaved={() => { refreshReviewerNotification(); refreshWorkflowNotifications(); }} taskView={myWorklistView} setTaskView={handleMyWorklistViewChange} />}
        {view === 'escalations' && <EscalationQueuePage labId={labId} user={user} reviewers={reviewers} taskView={escalationView === 'response' ? 'claim' : escalationView} responseOnly={escalationView === 'response'} setTaskView={setEscalationView} tabCounts={claimMenuCounts} onClaimTabChange={handleClaimTabRoute} canAssign={canAssign} assignClaims={assignClaims} setMessage={setMessage} />}
      </main>
    </div>
  </div>;
}
