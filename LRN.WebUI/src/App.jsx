import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { API_BASE, LOGOUT_URL } from './config/apiConfig';
import { emptyDashboard, emptyFilter, emptyFilterOptions, emptyPagedResult } from './dto/denialWorkflowDtos';
import { denialWorkflowService, qs } from './services/denialWorkflowService';
import { GENERIC_WORKFLOW_ERROR } from './services/httpClient';
import { claimRole, claimUser, clearWorkflowJwt, ensureWorkflowJwt, getJwt, parseJwt } from './utils/auth';
import { canAssignRole, canDownloadWorkflowRole, initials, isArManagerRole, isArReviewerRole, isClientManagerRole, isAccountManagerRole, isReadOnlyWorkflowRole } from './utils/formatters';
import DashboardFilter from './components/DashboardFilter';
import { clearHiddenWorkflowFilters, getFiltersForRoleQueue, getQueuesForRole, normalizeQueueKey } from './config/workflowRoleQueues';
import DashboardPage from './pages/DashboardPage';
import AgingDashboardPage from './pages/AgingDashboardPage';
import DenialSummaryPage from './pages/DenialSummaryPage';
import ClaimAssignmentPage from './pages/ClaimAssignmentPage';
import MyWorklistPage from './pages/MyWorklistPage';
import EscalationQueuePage from './pages/EscalationQueuePage';
import VerificationPage from './pages/VerificationPage';
import ContactSupportPage from './pages/ContactSupportPage';
import DenialCodeMasterPage from './pages/DenialCodeMasterPage';
import DenialActionVerificationPage from './pages/DenialActionVerificationPage';
import DenialMapperPage from './pages/DenialMapperPage';

function roleIsReviewerOnly(role) { return isArReviewerRole(role); }

// UAT: the role badge showed the raw "AR Reviewer" role string, but the spec calls that role
// "AR Analyst" in the UI. Only relabel the display text here -- permission checks throughout
// this file (isArReviewerRole, etc.) keep matching on the underlying "AR Reviewer" role string.
function roleDisplayLabel(role) {
  const value = String(role || '').trim();
  return isArReviewerRole(value) ? 'AR Analyst' : (value || 'Workflow User');
}

function WorkflowPlaceholder({ title, children }) {
  return <div className="workflow-placeholder">
    <div className="workflow-placeholder-icon"><i className="bi bi-tools" /></div>
    <div>
      <h2>{title}</h2>
      <p>{children}</p>
    </div>
  </div>;
}

export default function App() {
  const jwtClaims = useMemo(() => parseJwt(getJwt()), []);
  const [user, setUser] = useState({ userName: claimUser(jwtClaims), role: claimRole(jwtClaims), labs: [] });
  const [labs, setLabs] = useState([]);
  const [reviewers, setReviewers] = useState([]);
  const [filterOptions, setFilterOptions] = useState(emptyFilterOptions);
  const [labId, setLabId] = useState(Number(localStorage.getItem('denial.labId') || 0));
  const workflowViews = ['dashboard', 'aging', 'summary', 'claims', 'myworklist', 'escalations', 'verification', 'denialcodemaster', 'denialmapper', 'denialactionverification', 'exports', 'reports', 'support', 'admin'];
  const getStoredView = () => {
    const hashView = String(window.location.hash || '').replace('#', '').trim().toLowerCase();
    return workflowViews.includes(hashView) ? hashView : '';
  };
  const [view, setViewState] = useState(getStoredView() || 'aging');
  const [denialMapperView, setDenialMapperView] = useState('dashboard');
  const [denialMapperLabs, setDenialMapperLabs] = useState([]);
  const [mapperNotification, setMapperNotification] = useState(null);
  const [mapperReviewAuditId, setMapperReviewAuditId] = useState(null);
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
  const [myWorklistView, setMyWorklistView] = useState('assigned');
  const [escalationView, setEscalationView] = useState('claim');
  const [bulkReviewer, setBulkReviewer] = useState('');
  const [rowReviewers, setRowReviewers] = useState({});
  const [message, setMessage] = useState(null);
  const [actionVerificationBatchId, setActionVerificationBatchId] = useState('');
  const [supportEmails, setSupportEmails] = useState([]);
  const [loading, setLoading] = useState(false);
  const [claimExportJob, setClaimExportJob] = useState(null);
  const [myWorklistExportQuery, setMyWorklistExportQuery] = useState(null);
  const [lastRunReference, setLastRunReference] = useState(null);
  const [lastRunLoading, setLastRunLoading] = useState(false);
  const [exportTick, setExportTick] = useState(Date.now());
  const [authReady, setAuthReady] = useState(false);
  const [authChecking, setAuthChecking] = useState(true);
  const [authError, setAuthError] = useState('');
  const [workflowNotifications, setWorkflowNotifications] = useState({ loading: false, sections: [], total: 0 });
  const [notificationOpen, setNotificationOpen] = useState(false);
  const [notificationPopupOpen, setNotificationPopupOpen] = useState(false);
  const initialNotificationKeyRef = useRef('');
  const [claimMenuCounts, setClaimMenuCounts] = useState({ new: null, unassigned: null, assigned: null, payerFollowup: null, pendingDocumentation: null, pendingPayerResponse: null, writeOffApproval: null, slaAtRisk: null, escalations: null, internalEscalation: null, externalEscalation: null, escalationResponse: null, verification: null, closed: null, all: null });
  const [myWorklistMenuCounts, setMyWorklistMenuCounts] = useState({ assigned: null, payerFollowup: null, pendingDocumentation: null, pendingPayerResponse: null, internalEscalation: null, externalEscalation: null, escalationResponse: null, closed: null, all: null });
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [dashboardFiltersOpen, setDashboardFiltersOpen] = useState(false);
  const [claimFiltersOpen, setClaimFiltersOpen] = useState(false);
  const [profileOpen, setProfileOpen] = useState(false);
  const claimRequestSeq = useRef(0);
  const claimAbortRef = useRef(null);
  const claimExportInFlightRef = useRef(false);
  const reviewerOnly = roleIsReviewerOnly(user.role);
  const arManagerOnly = isArManagerRole(user.role);
  const canAssign = canAssignRole(user.role);
  const canDownloadWorkflow = canDownloadWorkflowRole(user.role);
  const clientManager = isClientManagerRole(user.role);
  const accountManager = isAccountManagerRole(user.role);
  const externalManager = clientManager || accountManager;
  const adminRole = String(user.role || '').toLowerCase().includes('admin');
  const readOnlyWorkflow = isReadOnlyWorkflowRole(user.role);
  const denialMapperViewer = /viewer|read\s*only/i.test(String(user.role || ''));
  const denialMapperLabUser = /lab\s*user/i.test(String(user.role || ''));
  const denialMapperRole = adminRole || arManagerOnly || clientManager || accountManager || denialMapperViewer || denialMapperLabUser;
  const denialMapperAdmin = adminRole;
  const exportBusy = !!claimExportJob && ['Queued', 'Running'].includes(claimExportJob.status);
  const activeQueueKey = view === 'myworklist' ? myWorklistView : view === 'claims' ? claimTaskView : '';
  const visibleFilters = useMemo(() => (view === 'dashboard'
    ? ['status', 'reviewer', 'payerName', 'denialClassification', 'actionCategory', 'denialCode', 'priority', 'clinic', 'salesRepname', 'referringProvider']
    : getFiltersForRoleQueue(user.role, activeQueueKey)), [view, user.role, activeQueueKey]);
  const copyrightYear = new Date().getFullYear();

  useEffect(() => {
    if (!authReady || !arManagerOnly || !labId) return;
    denialWorkflowService.getDenialMapperNotifications(labId).then(items => setMapperNotification(items?.[0] || null)).catch(() => {});
  }, [authReady, arManagerOnly, labId]);

  const supportEmailList = useCallback((err = null) => {
    const fromError = Array.isArray(err?.supportEmails) ? err.supportEmails : [];
    return [...new Set([...fromError, ...supportEmails].map(x => String(x || '').trim()).filter(Boolean))];
  }, [supportEmails]);

  const workflowIssueMessage = useCallback((err = null) => ({
    type: 'danger',
    text: GENERIC_WORKFLOW_ERROR,
    supportEmails: supportEmailList(err),
    correlationId: err?.correlationId || ''
  }), [supportEmailList]);

  const setWorkflowMessage = useCallback((next) => {
    if (typeof next === 'function') {
      setMessage(prev => {
        const resolved = next(prev);
        return resolved?.type === 'danger'
          ? { type: 'danger', text: GENERIC_WORKFLOW_ERROR, supportEmails: supportEmailList() }
          : resolved;
      });
      return;
    }

    setMessage(next?.type === 'danger'
      ? { type: 'danger', text: GENERIC_WORKFLOW_ERROR, supportEmails: supportEmailList() }
      : next);
  }, [supportEmailList]);

  function resetWorkflowFilters() {
    setFilter(emptyFilter);
    setDebouncedFilter(emptyFilter);
  }

  function setView(nextView, { closeSidebar = true, preserveFilters = false } = {}) {
    let safeView = workflowViews.includes(nextView) ? nextView : 'dashboard';
    let blockedByRole = false;
    if (reviewerOnly && safeView === 'claims') { safeView = 'myworklist'; blockedByRole = true; }
    if (externalManager && safeView === 'myworklist') { safeView = 'claims'; blockedByRole = true; }
    if ((safeView === 'denialcodemaster' || safeView === 'denialactionverification') && !isArManagerRole(user.role) && !String(user.role || '').toLowerCase().includes('admin')) { safeView = resolveLandingView(user.role); blockedByRole = true; }
    // Cumulative Audit F-19: the security boundary was already enforced (the restricted
    // content never rendered), but the user got no explanation for why they landed somewhere
    // else — just a silently-swapped page. Surface it so the redirect isn't confusing.
    if (blockedByRole) setMessage({ type: 'warning', text: 'You do not have access to that page. Showing your default view instead.' });
    if (!preserveFilters && safeView !== view) resetWorkflowFilters();
    setViewState(safeView);
    if (closeSidebar) setSidebarOpen(false);
    if (window.location.hash !== `#${safeView}`) {
      window.history.replaceState(null, '', `${window.location.pathname}${window.location.search}#${safeView}`);
    }
  }

  useEffect(() => {
    if (externalManager && view === 'myworklist') setView('claims', { closeSidebar: false });
  }, [externalManager, view]);

  useEffect(() => {
    // The initial `view` state is seeded straight from the URL hash (getStoredView) before the
    // user's role is known, bypassing setView's role-based safeView checks entirely. A deep link
    // or direct URL edit to a restricted route (e.g. #denialcodemaster as an AR Reviewer) would
    // then render the fallback content for that role but leave the restricted route's hash
    // sitting in the address bar with no redirect. Re-run the same validation setView applies
    // once the role is known, so both the rendered view and the visible URL are corrected together.
    if (!authReady) return;
    setView(view, { closeSidebar: false, preserveFilters: true });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [authReady]);

  // TC-002: deep-linking via the URL hash only worked on a fresh page load (the initial `view`
  // is seeded from the hash). Editing `#dashboard` etc. in the address bar of an already-open app
  // did nothing because nothing listened for hashchange. Route those through setView (which applies
  // the same role/permission validation) so hash edits navigate correctly and stay in sync.
  useEffect(() => {
    if (!authReady) return;
    function onHashChange() {
      const hashView = getStoredView();
      if (hashView && hashView !== view) setView(hashView, { closeSidebar: false, preserveFilters: true });
    }
    window.addEventListener('hashchange', onHashChange);
    return () => window.removeEventListener('hashchange', onHashChange);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [authReady, view]);

  useEffect(() => {
    if (!denialMapperAdmin || (view !== 'denialmapper' && view !== 'denialactionverification')) return;
    let cancelled = false;
    denialWorkflowService.getDenialMapperLabs().then(activeLabs => {
      if (cancelled) return;
      const next = Array.isArray(activeLabs) ? activeLabs : [];
      setDenialMapperLabs(next);
      if (next.length && !next.some(x => Number(x.labId ?? x.LabId) === Number(labId))) {
        setLabId(Number(next[0].labId ?? next[0].LabId));
      }
    }).catch(() => { /* page-level API handling will report mapper errors */ });
    return () => { cancelled = true; };
  }, [denialMapperAdmin, view]);

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
      referringProviders: toStrings(fromMaybeDelimitedString(source.referringProviders ?? source.ReferringProviders), ['referringProvider', 'ReferringProvider', 'providerName', 'ProviderName', 'name', 'Name']),
      assignedUsers: toStrings(fromMaybeDelimitedString(source.assignedUsers ?? source.AssignedUsers), ['userName', 'UserName', 'assignedTo', 'AssignedTo', 'name', 'Name'])
    };
  }

  function resolveLandingView(role) {
    const stored = getStoredView();
    if (stored) return stored;
    if (isArReviewerRole(role)) return 'myworklist';
    if (isClientManagerRole(role) || isAccountManagerRole(role)) return 'claims';
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

  useEffect(() => {
    if (!authReady) return;
    let cancelled = false;
    denialWorkflowService.getSupportContacts()
      .then(x => {
        if (cancelled) return;
        const emails = x?.supportEmails || x?.SupportEmails || [];
        setSupportEmails(Array.isArray(emails) ? emails.filter(Boolean) : []);
      })
      .catch(() => {
        if (!cancelled) setSupportEmails([]);
      });
    return () => { cancelled = true; };
  }, [authReady]);

  useEffect(() => { if (labId) localStorage.setItem('denial.labId', labId); }, [labId]);

  // Avoid reloading 300k+ row queries on every keystroke in Search/Clinic/Sales Rep/Provider.
  useEffect(() => {
    const handle = window.setTimeout(() => setDebouncedFilter(filter), 450);
    return () => window.clearTimeout(handle);
  }, [filter]);

  useEffect(() => {
    if (!authReady || !labId || (!canAssign && !externalManager)) { setReviewers([]); return; }
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
        setMessage(workflowIssueMessage(err));
      });
  }, [authReady, labId, canAssign, externalManager]);

  useEffect(() => {
    if (!authReady || !labId) return;
    const cacheKey = `denial.filterOptions.v3.${labId}`;
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
        setMessage(workflowIssueMessage(err));
      });
  }, [authReady, labId]);

  useEffect(() => {
    if (!authReady || !labId) {
      setLastRunReference(null);
      setLastRunLoading(false);
      return;
    }

    let cancelled = false;
    setLastRunLoading(true);
    denialWorkflowService.getLastRunReference(labId)
      .then(x => {
        if (!cancelled) setLastRunReference(x || null);
      })
      .catch(() => {
        if (!cancelled) setLastRunReference(null);
      })
      .finally(() => {
        if (!cancelled) setLastRunLoading(false);
      });

    return () => { cancelled = true; };
  }, [authReady, labId]);

  function filterValue(value) {
    if (Array.isArray(value)) return value.map(x => String(x || '').trim()).filter(Boolean).join('\u00ac');
    if (value === undefined || value === null) return '';
    return String(value).trim();
  }

  const query = useMemo(() => ({
    labId,
    role: user.role,
    userName: user.userName,
    status: filterValue(debouncedFilter.status),
    reviewer: reviewerOnly ? (user.userName || '') : filterValue(debouncedFilter.reviewer),
    assignedTo: reviewerOnly ? (user.userName || '') : filterValue(debouncedFilter.reviewer),
    assignedUserId: filterValue(debouncedFilter.assignedUserId),
    assignedDuration: filterValue(debouncedFilter.assignedDuration),
    actionCategory: filterValue(debouncedFilter.actionCategory),
    priority: filterValue(debouncedFilter.priority),
    denialCode: filterValue(debouncedFilter.denialCode),
    payerName: filterValue(debouncedFilter.payerName),
    panelName: filterValue(debouncedFilter.panelName),
    clinic: filterValue(debouncedFilter.clinic),
    salesRepname: filterValue(debouncedFilter.salesRepname),
    referringProvider: filterValue(debouncedFilter.referringProvider),
    denialClassification: filterValue(debouncedFilter.denialClassification),
    followUpReason: filterValue(debouncedFilter.followUpReason),
    documentationType: filterValue(debouncedFilter.documentationType),
    escalationReason: filterValue(debouncedFilter.escalationReason),
    expectedResponseBy: debouncedFilter.expectedResponseBy || '',
    nextFollowUpDate: debouncedFilter.nextFollowUpDate || '',
    followupDue: filterValue(debouncedFilter.followupDue),
    agingBucket: filterValue(debouncedFilter.agingBucket),
    balanceBucket: filterValue(debouncedFilter.balanceBucket),
    searchText: filterValue(debouncedFilter.searchText),
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
    reviewer: reviewerOnly ? (user.userName || '') : filterValue(debouncedFilter.reviewer),
    assignedTo: reviewerOnly ? (user.userName || '') : filterValue(debouncedFilter.reviewer),
    assignedUserId: filterValue(debouncedFilter.assignedUserId),
    assignedDuration: filterValue(debouncedFilter.assignedDuration),
    actionCategory: filterValue(debouncedFilter.actionCategory),
    priority: filterValue(debouncedFilter.priority),
    denialCode: filterValue(debouncedFilter.denialCode),
    payerName: filterValue(debouncedFilter.payerName),
    panelName: filterValue(debouncedFilter.panelName),
    clinic: filterValue(debouncedFilter.clinic),
    salesRepname: filterValue(debouncedFilter.salesRepname),
    referringProvider: filterValue(debouncedFilter.referringProvider),
    denialClassification: filterValue(debouncedFilter.denialClassification),
    followUpReason: filterValue(debouncedFilter.followUpReason),
    documentationType: filterValue(debouncedFilter.documentationType),
    escalationReason: filterValue(debouncedFilter.escalationReason),
    expectedResponseBy: debouncedFilter.expectedResponseBy || '',
    nextFollowUpDate: debouncedFilter.nextFollowUpDate || '',
    followupDue: filterValue(debouncedFilter.followupDue),
    agingBucket: filterValue(debouncedFilter.agingBucket),
    balanceBucket: filterValue(debouncedFilter.balanceBucket),
    searchText: filterValue(debouncedFilter.searchText),
    page: 1,
    pageSize: 1
  }), [labId, user.role, user.userName, reviewerOnly, debouncedFilter]);


  function normalizeNotificationItems(result) {
    const rows = result?.items || [];
    const seen = new Set();
    return rows.map(row => ({
      claimId: row.claimUid || row.claimUID || row.ClaimUid || row.ClaimUID || row.claimId || row.ClaimId || '',
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

  function normalizeFollowUpNotificationItems(rows) {
    return (rows || []).map(row => ({
      claimId: row.claimId || row.ClaimId || '', taskId: row.taskId || row.TaskId || '',
      cptCode: row.cptCode || row.CptCode || '', payerName: row.payerName || row.PayerName || '',
      status: 'Follow-up due tomorrow', assignedTo: row.assignedTo || row.AssignedTo || '',
      actionCategory: row.lastAction || row.LastAction || row.actionCode || row.ActionCode || 'Follow-up',
      followUpDate: row.followUpDate || row.FollowUpDate || '', followUpReason: row.followUpReason || row.FollowUpReason || '',
      slaStatus: row.cptCode || row.CptCode ? `CPT ${row.cptCode || row.CptCode}` : ''
    })).filter(item => item.claimId);
  }

  function distinctSectionClaimCount(sections) {
    return distinctClaimCount((sections || []).flatMap(section => section.items || []));
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
          pageSize: 50
        };
        const [assigned, pending, actionRequired, escalations, responses, followUps] = await Promise.all([
          denialWorkflowService.getTasks({ ...baseQuery, taskView: 'assigned' }),
          denialWorkflowService.getTasks({ ...baseQuery, taskView: 'open' }),
          denialWorkflowService.getTasks({ ...baseQuery, status: 'Pending Review' }),
          denialWorkflowService.getTasks({ ...baseQuery, taskView: 'escalations' }),
          denialWorkflowService.getTasks({ ...baseQuery, taskView: 'response' }),
          denialWorkflowService.getFollowUpNotifications(labId)
        ]);
        const assignedItems = normalizeNotificationItems(assigned);
        const pendingItems = normalizeNotificationItems(pending);
        const actionRequiredItems = normalizeNotificationItems(actionRequired);
        const escalationItems = normalizeNotificationItems(escalations);
        const responseItems = normalizeNotificationItems(responses);
        const followUpItems = normalizeFollowUpNotificationItems(followUps);
        sections = [
          { key: 'follow-up', label: 'Follow-ups due tomorrow', count: distinctClaimCount(followUpItems), items: followUpItems, targetView: 'all' },
          { key: 'assigned', label: 'Assigned claims', count: distinctClaimCount(assignedItems), items: assignedItems, targetView: 'assigned' },
          { key: 'pending', label: 'Pending claims', count: distinctClaimCount(pendingItems), items: pendingItems, targetView: 'open' },
          { key: 'action', label: 'Action required claims', count: distinctClaimCount(actionRequiredItems), items: actionRequiredItems, targetView: 'open', status: 'Pending Review' },
          { key: 'response', label: 'Escalated response claims', count: distinctClaimCount(responseItems), items: responseItems, targetView: 'escalationResponse' },
          { key: 'escalations', label: 'Escalation claims', count: distinctClaimCount(escalationItems), items: escalationItems, targetView: 'escalations' }
        ].filter(section => section.count > 0);
      } else if (externalManager) {
        const managerBaseQuery = {
          labId,
          role: user.role,
          userName: user.userName,
          page: 1,
          pageSize: 50
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

      const total = distinctSectionClaimCount(sections);
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
      // Always re-fetch rather than skip on an unchanged query key: `claims` is not a dependency
      // of this effect, so checking cached claim data here would read a stale closure value that
      // may not correspond to the currently selected tab (e.g. mid-flight tab switches), which
      // could leave a previous tab's rows on screen under the newly active tab's label with no
      // fetch in flight to correct it. The requestId + AbortController guard below already
      // prevents stale responses from being applied, so it is safe to always fetch here.
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
        setMessage(workflowIssueMessage(err));
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
    let latestClaimCounts = null;
    try {
      const counts = await denialWorkflowService.getClaimMenuCounts(menuCountQuery);
      latestClaimCounts = counts;
      setClaimMenuCounts({
        new: Number(counts?.new ?? counts?.New ?? 0),
        unassigned: Number(counts?.unassigned ?? counts?.Unassigned ?? 0),
        assigned: Number(counts?.assigned ?? counts?.Assigned ?? 0),
        payerFollowup: Number(counts?.payerFollowup ?? counts?.PayerFollowup ?? 0),
        pendingDocumentation: Number(counts?.pendingDocumentation ?? counts?.PendingDocumentation ?? 0),
        pendingPayerResponse: Number(counts?.pendingPayerResponse ?? counts?.PendingPayerResponse ?? 0),
        writeOffApproval: Number(counts?.writeOffApproval ?? counts?.WriteOffApproval ?? 0),
        slaAtRisk: Number(counts?.slaAtRisk ?? counts?.SlaAtRisk ?? 0),
        escalations: Number(counts?.escalated ?? counts?.Escalated ?? 0),
        internalEscalation: Number(counts?.internalEscalation ?? counts?.InternalEscalation ?? 0),
        externalEscalation: Number(counts?.externalEscalation ?? counts?.ExternalEscalation ?? 0),
        escalationResponse: Number(counts?.escalationResponse ?? counts?.EscalationResponse ?? 0),
        verification: Number(counts?.verification ?? counts?.Verification ?? 0),
        closed: Number(counts?.closed ?? counts?.Closed ?? 0),
        all: Number(counts?.allClaims ?? counts?.AllClaims ?? counts?.totalClaims ?? counts?.TotalClaims ?? 0)
      });
    } catch {
      setClaimMenuCounts({ new: 0, unassigned: 0, assigned: 0, payerFollowup: 0, pendingDocumentation: 0, pendingPayerResponse: 0, writeOffApproval: 0, slaAtRisk: 0, escalations: 0, internalEscalation: 0, externalEscalation: 0, escalationResponse: 0, verification: 0, closed: 0, all: 0 });
    }

    try {
      setMyWorklistMenuCounts({
        assigned: Number(latestClaimCounts?.assigned ?? latestClaimCounts?.Assigned ?? 0),
        payerFollowup: Number(latestClaimCounts?.payerFollowup ?? latestClaimCounts?.PayerFollowup ?? 0),
        pendingDocumentation: Number(latestClaimCounts?.pendingDocumentation ?? latestClaimCounts?.PendingDocumentation ?? 0),
        pendingPayerResponse: Number(latestClaimCounts?.pendingPayerResponse ?? latestClaimCounts?.PendingPayerResponse ?? 0),
        internalEscalation: Number(latestClaimCounts?.internalEscalation ?? latestClaimCounts?.InternalEscalation ?? 0),
        externalEscalation: Number(latestClaimCounts?.externalEscalation ?? latestClaimCounts?.ExternalEscalation ?? 0),
        escalationResponse: Number(latestClaimCounts?.escalationResponse ?? latestClaimCounts?.EscalationResponse ?? 0),
        all: Number(latestClaimCounts?.allClaims ?? latestClaimCounts?.AllClaims ?? latestClaimCounts?.totalClaims ?? latestClaimCounts?.TotalClaims ?? 0),
        closed: Number(latestClaimCounts?.closed ?? latestClaimCounts?.Closed ?? 0)
      });
    } catch {
      setMyWorklistMenuCounts({ assigned: null, payerFollowup: null, pendingDocumentation: null, pendingPayerResponse: null, internalEscalation: null, externalEscalation: null, escalationResponse: null, all: null, closed: null });
    }
  }

  useEffect(() => {
    if (!authReady || !labId) return;
    refreshMenuCounts();
  }, [authReady, labId, menuCountQuery, reviewerOnly]);

  const mapperHeaderActive = denialMapperAdmin && (view === 'denialmapper' || view === 'denialactionverification');
  const headerLabs = mapperHeaderActive && denialMapperLabs.length ? denialMapperLabs : labs;
  const labName = [...denialMapperLabs, ...labs].find(l => Number(l.labId ?? l.LabId) === Number(labId))?.labName || 'Select Lab';
  const pageTitle = { dashboard: 'Denial Dashboard', aging: 'Aging Dashboard', summary: 'Denial Summary', claims: canAssign ? 'Claim Assignment' : 'Claim View', myworklist: 'My Worklist', escalations: escalationView === 'response' ? 'Escalation Response' : 'Escalation Queue', verification: 'Verification', denialcodemaster: 'Denial Code Master', denialmapper: 'Denial Mapper', denialactionverification: 'Action Change Verification', exports: 'Exports', reports: 'Reports', support: 'Contact Support', admin: 'Admin Setup' }[view] || 'Denial Workflow';
  // UAT: the browser tab title stayed on the generic static value from index.html and never
  // reflected which page was open.
  useEffect(() => { document.title = `${pageTitle} · LRN Denial Workflow`; }, [pageTitle]);
  const showOverallDownload = canDownloadWorkflow && (view === 'claims' || view === 'myworklist');
  const claimNavTabs = useMemo(() => [
    ...getQueuesForRole(user.role),
    ...(canAssign ? [{ key: 'verification', label: 'Verification' }] : [])
  ], [canAssign, user.role]);
  const myWorklistNavTabs = useMemo(() => getQueuesForRole(user.role), [user.role]);
  const escalationNavTabs = useMemo(() => ([
    { key: 'claim', label: 'Claim level' },
    { key: 'line', label: 'Line level' }
  ]), []);

  function handleClaimTaskViewChange(nextView) {
    const normalized = normalizeQueueKey(nextView);
    if (normalized === claimTaskView) return;
    setClaimTaskView(normalized);
    setFilter(f => ({ ...clearHiddenWorkflowFilters(f, getFiltersForRoleQueue(user.role, normalized)), page: 1 }));
    setClaims(emptyPagedResult);
    setSelectedClaims({});
    setClaimTasks({});
    setExpandedClaim('');
  }

  function handleClaimTabRoute(nextView) {
    const normalized = normalizeQueueKey(nextView);
    if (normalized === 'escalationResponse') {
      setEscalationView('response');
      setView('escalations');
      return;
    }
    if (nextView === 'verification') {
      setView('verification');
      return;
    }
    setView('claims');
    handleClaimTaskViewChange(normalized);
  }

  function handleMyWorklistViewChange(nextView) {
    const normalized = normalizeQueueKey(nextView);
    if (normalized === myWorklistView) return;
    setMyWorklistView(normalized);
    setFilter(f => ({ ...clearHiddenWorkflowFilters(f, getFiltersForRoleQueue(user.role, normalized)), page: 1 }));
  }

  useEffect(() => {
    if (externalManager && !['pendingDocumentation', 'externalEscalation', 'closed', 'all'].includes(myWorklistView)) setMyWorklistView('externalEscalation');
  }, [externalManager, myWorklistView]);

  function setFilterValue(k, v) { setFilter(f => ({ ...f, [k]: v, page: 1 })); }
  function clearFilter() { resetWorkflowFilters(); }
  function changePage(page) { setFilter(f => ({ ...f, page })); }

  function applyDrilldownFilters(next = {}) {
    const nextFilter = { ...filter, ...next, page: 1 };
    setFilter(nextFilter);
    setDebouncedFilter(nextFilter);
  }


  function openClaimsByClassification(classification) {
    applyDrilldownFilters({ denialClassification: classification || '' });
    if (reviewerOnly) {
      setMyWorklistView('assigned');
      setView('myworklist', { preserveFilters: true });
      return;
    }
    setClaimTaskView('all');
    setView('claims', { preserveFilters: true });
    setMessage({
      type: 'info',
      text: classification
        ? `Showing Claim Assignment filtered by Denial Classification: ${classification}`
        : 'Showing Claim Assignment filtered by Unclassified denial classification.'
    });
  }

  function openClaimsByActionCategory(actionCategory) {
    applyDrilldownFilters({ actionCategory: actionCategory || '' });
    if (reviewerOnly) {
      setMyWorklistView('assigned');
      setView('myworklist', { preserveFilters: true });
      return;
    }
    setClaimTaskView('all');
    setView('claims', { preserveFilters: true });
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
      setMyWorklistView(section?.targetView || 'assigned');
      applyDrilldownFilters({ status: section?.status || '', searchText: item?.claimId || '' });
      setView('myworklist', { preserveFilters: true });
      return;
    }

    if (externalManager) {
      setEscalationView('claim');
      applyDrilldownFilters({ searchText: item?.claimId || '' });
      setView('escalations', { preserveFilters: true });
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

  function claimExportStorageKey() {
    return `denial.claimExport.${labId || 0}.${user.userName || 'user'}`;
  }

  function rememberClaimExport(job) {
    try {
      if (!job?.jobId) return;
      localStorage.setItem(claimExportStorageKey(), JSON.stringify(job));
    } catch { /* ignore browser storage errors */ }
  }

  function forgetClaimExport() {
    claimExportInFlightRef.current = false;
    setClaimExportJob(null);
    try { localStorage.removeItem(claimExportStorageKey()); } catch { /* ignore browser storage errors */ }
  }

  function exportElapsedText(job = claimExportJob) {
    if (!job?.createdOnUtc) return '';
    const started = new Date(job.createdOnUtc).getTime();
    if (!Number.isFinite(started)) return '';
    const end = job.completedOnUtc ? new Date(job.completedOnUtc).getTime() : exportTick;
    const seconds = Math.max(0, Math.floor((end - started) / 1000));
    const minutes = Math.floor(seconds / 60);
    const rem = seconds % 60;
    return minutes > 0 ? `${minutes}m ${String(rem).padStart(2, '0')}s` : `${rem}s`;
  }

  function exportStatusText(job = claimExportJob) {
    if (!job) return '';
    const scope = job.jobScope ? `${job.jobScope} - ` : '';
    const elapsed = exportElapsedText(job);
    return `${scope}${job.status || 'Export'}${elapsed ? ` for ${elapsed}` : ''}`;
  }

  useEffect(() => {
    if (!exportBusy) return;
    const timer = window.setInterval(() => setExportTick(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [exportBusy]);

  useEffect(() => {
    if (!authReady || !labId || !user.userName) return;
    try {
      const cached = JSON.parse(localStorage.getItem(claimExportStorageKey()) || 'null');
      if (!cached?.jobId) return;
      if (!['Queued', 'Running'].includes(cached.status)) {
        localStorage.removeItem(claimExportStorageKey());
        return;
      }
      setClaimExportJob(cached);
      claimExportInFlightRef.current = ['Queued', 'Running'].includes(cached.status);
    } catch { /* ignore bad browser cache */ }
  }, [authReady, labId, user.userName]);

  useEffect(() => {
    if (!claimExportJob?.jobId || claimExportJob.status === 'Completed' || claimExportJob.status === 'Failed') return;

    let cancelled = false;
    const checkStatus = async () => {
      try {
        const status = await denialWorkflowService.getClaimsExportStatus(claimExportJob.jobId);
        if (cancelled) return;
        const nextStatus = { ...status, jobScope: claimExportJob.jobScope };
        setClaimExportJob(nextStatus);
        rememberClaimExport(nextStatus);
        if (status?.status === 'Completed') {
          claimExportInFlightRef.current = false;
          try { localStorage.removeItem(claimExportStorageKey()); } catch { }
          setMessage({ type: 'success', text: `${claimExportJob.jobScope || 'Claim detail'} export is ready. Your browser download should start now; use Download File if it does not.` });
          downloadClaimExportById(status.jobId);
        } else if (status?.status === 'Failed') {
          claimExportInFlightRef.current = false;
          try { localStorage.removeItem(claimExportStorageKey()); } catch { }
          setMessage(workflowIssueMessage());
        }
      } catch (err) {
        if (cancelled) return;
        const message = err.message || 'Unable to check export status.';
        if (message.toLowerCase().includes('export job was not found')) {
          forgetClaimExport();
          setMessage({ type: 'info', text: 'The previous export job expired. Please start Overall Download again.' });
          return;
        }
        claimExportInFlightRef.current = false;
        setMessage(workflowIssueMessage(err));
      }
    };

    checkStatus();
    const timer = window.setInterval(checkStatus, 5000);

    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [claimExportJob?.jobId, claimExportJob?.status]);

  async function refreshClaimExportStatus() {
    if (!claimExportJob?.jobId) return;
    try {
      const status = await denialWorkflowService.getClaimsExportStatus(claimExportJob.jobId);
      const nextStatus = { ...status, jobScope: claimExportJob.jobScope };
      setClaimExportJob(nextStatus);
      rememberClaimExport(nextStatus);
      if (status?.status === 'Completed') {
        claimExportInFlightRef.current = false;
        try { localStorage.removeItem(claimExportStorageKey()); } catch { }
        setMessage({ type: 'success', text: `${claimExportJob.jobScope || 'Claim detail'} export is ready. Click Download File to save it.` });
      } else if (status?.status === 'Failed') {
        claimExportInFlightRef.current = false;
        try { localStorage.removeItem(claimExportStorageKey()); } catch { }
        setMessage(workflowIssueMessage());
      } else {
        setMessage({ type: 'info', text: `Export is still ${String(status?.status || 'running').toLowerCase()} (${exportStatusText(nextStatus)}).` });
      }
    } catch (err) {
      setMessage(workflowIssueMessage(err));
    }
  }

  async function cancelClaimExport() {
    if (!claimExportJob?.jobId) return;
    try {
      await denialWorkflowService.cancelClaimsExport(claimExportJob.jobId);
      forgetClaimExport();
      setMessage({ type: 'info', text: 'Export cancelled. You can start a filtered tab download or overall download again.' });
    } catch (err) {
      setMessage(workflowIssueMessage(err));
    }
  }

  async function startClaimExport({ currentTab = false, queryOverride = null, tabKey = '', tabLabel = '', uploadTemplate = false } = {}) {
    if (!labId) return setMessage({ type: 'warning', text: 'Please select a lab before exporting.' });
    if (claimExportInFlightRef.current || (claimExportJob && ['Queued', 'Running'].includes(claimExportJob.status))) {
      return setMessage({ type: 'info', text: 'Claim detail export is already in progress. Please wait until it completes.' });
    }

    try {
      claimExportInFlightRef.current = true;
      const activeTabKey = tabKey || (view === 'myworklist' ? myWorklistView : claimTaskView);
      const activeTabLabel = (tabLabel || (view === 'myworklist'
        ? myWorklistNavTabs.find(t => t.key === activeTabKey)?.label
        : claimNavTabs.find(t => t.key === activeTabKey)?.label) || activeTabKey || 'Current Tab').trim();
      const jobScope = uploadTemplate ? `${activeTabLabel} upload template` : currentTab ? `${activeTabLabel} tab` : 'Overall filtered';
      const baseQuery = queryOverride || (view === 'myworklist' && myWorklistExportQuery ? myWorklistExportQuery : query);
      const exportQuery = {
        ...baseQuery,
        taskView: currentTab ? activeTabKey : '',
        uploadTemplate,
        page: 1,
        pageSize: 100,
        fromDate: baseQuery.fromDate || null,
        toDate: baseQuery.toDate || null
      };
      Object.keys(exportQuery).forEach(key => {
        if (exportQuery[key] === '' || exportQuery[key] === undefined) delete exportQuery[key];
      });
      const job = await denialWorkflowService.startClaimsExport(exportQuery);
      const nextJob = { ...job, jobScope };
      setClaimExportJob(nextJob);
      rememberClaimExport(nextJob);
      claimExportInFlightRef.current = ['Queued', 'Running'].includes(job?.status);
      setMessage({ type: 'info', text: job.message || `${jobScope} download is in progress. File creation is happening in the background; please wait for completion.` });
    } catch (err) {
      claimExportInFlightRef.current = false;
      setMessage(workflowIssueMessage(err));
    }
  }

  async function downloadClaimExportById(jobId) {
    if (!jobId) return;
    const url = await denialWorkflowService.getClaimsExportDownloadUrl(jobId);
    const a = document.createElement('a');
    a.href = url;
    a.download = '';
    document.body.appendChild(a);
    a.click();
    a.remove();
  }

  async function downloadClaimExport() {
    if (!claimExportJob?.jobId) return;
    await downloadClaimExportById(claimExportJob.jobId);
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
    } catch (err) { setMessage(workflowIssueMessage(err)); }
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
    } catch (err) { setMessage(workflowIssueMessage(err)); }
    finally { setLoading(false); }
  }

  async function saveTask(task, status, comments, extra = {}) {
    setLoading(true);
    try {
      // UAT: this call sent none of the fields ValidateTaskStatusUpdate requires for several
      // statuses (e.g. ActualOutcome for Closed) -- every such save genuinely 400'd. Let callers
      // pass the extra fields their status transition needs (see TasksPage.jsx).
      const result = await denialWorkflowService.updateTask({ labId, taskId: task.taskId, status, comments, actionBy: user.userName || 'ReactWorkflow', ...extra });
      setMessage({ type: result.success ? 'success' : 'warning', text: result.message || 'Task saved.' });
      setTasks(await denialWorkflowService.getTasks(query));
      refreshWorkflowNotifications();
    } catch (err) { setMessage(workflowIssueMessage(err)); }
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
      <div className="lrn-brand"><div className="lrn-brand-icon"><i className="bi bi-layers" /></div><div><div className="lrn-brand-text">Denial Workflow</div><div className="lrn-brand-sub">Revenue recovery</div></div></div>
      <div className="user-card"><span className="avatar-sm">{initials(user.displayName || user.userName)}</span><div><strong>{user.displayName || user.userName || 'LRN User'}</strong><small>{roleDisplayLabel(user.role)}</small></div></div>
      <nav className="lrn-nav">
        <div className="lrn-nav-section">Overview</div>
        <button className={`lrn-nav-item ${view === 'dashboard' ? 'active' : ''}`} onClick={() => setView('dashboard')}><i className="bi bi-speedometer2" />Denial Dashboard</button>
        <button className={`lrn-nav-item ${view === 'aging' ? 'active' : ''}`} onClick={() => setView('aging')}><i className="bi bi-hourglass-split" />Aging Dashboard</button>
        <div className="lrn-nav-section">Denial Workflow</div>
        {(canAssign || externalManager || adminRole) && (
          <>
            <button className={`lrn-nav-item ${view === 'claims' ? 'active' : ''}`} onClick={() => setView('claims', { closeSidebar: false })}><i className="bi bi-folder-check" />{canAssign ? 'Claim Assignment' : 'Claim View'}</button>
            {(view === 'claims' || view === 'verification' || (view === 'escalations' && escalationView === 'response')) && (
              <div className="lrn-nav-submenu">
                {claimNavTabs.map(t => {
                  const isResponse = t.key === 'escalationResponse';
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
            <button className={`lrn-nav-item ${view === 'myworklist' ? 'active' : ''}`} onClick={() => setView('myworklist', { closeSidebar: false })}><i className="bi bi-person-check" />My Worklist</button>
            {view === 'myworklist' && (
              <div className="lrn-nav-submenu">
                {myWorklistNavTabs.map(t => (
                  <button key={t.key} type="button" className={`lrn-nav-subitem ${myWorklistView === t.key ? 'active' : ''} ${t.alert && Number(myWorklistMenuCounts[t.key] || 0) > 0 ? 'has-alert' : ''}`} onClick={() => { setView('myworklist'); handleMyWorklistViewChange(t.key); }}>
                    <span className="nav-sub-label">{t.label}</span><span className="nav-sub-count">{menuCountText(myWorklistMenuCounts[t.key])}</span>
                  </button>
                ))}
              </div>
            )}
          </>
        )}
        {(externalManager || readOnlyWorkflow) && (
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
        {denialMapperRole && <>
          <button className={`lrn-nav-item ${view === 'denialmapper' || view === 'denialcodemaster' || view === 'denialactionverification' ? 'active' : ''}`} onClick={() => { if (arManagerOnly) setView('denialcodemaster', { closeSidebar: false }); else { setDenialMapperView(adminRole ? 'dashboard' : 'lab'); setView('denialmapper', { closeSidebar: false }); } }}><i className="bi bi-diagram-3" />Denial Mapper</button>
          {(view === 'denialmapper' || view === 'denialcodemaster' || view === 'denialactionverification') && <div className="lrn-nav-submenu dm-nav-submenu">
            {arManagerOnly && <button className={`lrn-nav-subitem ${view === 'denialcodemaster' ? 'active' : ''}`} onClick={() => setView('denialcodemaster')}><span className="nav-sub-label">Denial Action Master</span></button>}
            {(denialMapperAdmin || clientManager || accountManager) && <button className={`lrn-nav-subitem ${view === 'denialmapper' && denialMapperView === 'dashboard' ? 'active' : ''}`} onClick={() => { setDenialMapperView('dashboard'); setView('denialmapper'); }}><span className="nav-sub-label">Dashboard</span></button>}
            {(denialMapperAdmin || denialMapperViewer) && <button className={`lrn-nav-subitem ${view === 'denialmapper' && denialMapperView === 'super' ? 'active' : ''}`} onClick={() => { setDenialMapperView('super'); setView('denialmapper'); }}><span className="nav-sub-label">{denialMapperAdmin ? 'Super Master / Push' : 'Super Master'}</span></button>}
            <button className={`lrn-nav-subitem ${view === 'denialmapper' && (denialMapperView === 'labs' || denialMapperView === 'lab') ? 'active' : ''}`} onClick={() => { setDenialMapperView(denialMapperAdmin ? 'labs' : 'lab'); setView('denialmapper'); }}><span className="nav-sub-label">Lab Master</span></button>
            {/* UAT: AR Manager owns Denial Code Master but had no way to see its change history —
                there's no DCM-specific audit table, so grant them the Denial Mapper's existing
                Audit Log (Super Master/push/override history) instead of building a new one. */}
            {(denialMapperAdmin || clientManager || accountManager || denialMapperLabUser || arManagerOnly) && <button className={`lrn-nav-subitem ${view === 'denialmapper' && denialMapperView === 'audit' ? 'active' : ''}`} onClick={() => { setDenialMapperView('audit'); setView('denialmapper'); }}><span className="nav-sub-label">Audit Log</span></button>}
            {denialMapperAdmin && <button className={`lrn-nav-subitem ${view === 'denialmapper' && denialMapperView === 'upload' ? 'active' : ''}`} onClick={() => { setDenialMapperView('upload'); setView('denialmapper'); }}><span className="nav-sub-label">Upload Mapper</span></button>}
            {(denialMapperAdmin || arManagerOnly) && <button className={`lrn-nav-subitem ${view === 'denialactionverification' ? 'active' : ''}`} onClick={() => setView('denialactionverification')}><span className="nav-sub-label">Action Code Verification</span></button>}
          </div>}
        </>}
        <button className={`lrn-nav-item ${view === 'reports' ? 'active' : ''}`} onClick={() => setView('reports')}><i className="bi bi-bar-chart-line" />Reports</button>
        <button className={`lrn-nav-item ${view === 'support' ? 'active' : ''}`} onClick={() => setView('support')}><i className="bi bi-life-preserver" />Contact Support</button>
        {adminRole && <button className={`lrn-nav-item ${view === 'admin' ? 'active' : ''}`} onClick={() => setView('admin')}><i className="bi bi-gear" />Admin Setup</button>}
      </nav>
      <div className="sidebar-logout"><button type="button" className="sidebar-logout-btn" onClick={logoutWorkflow}><i className="bi bi-box-arrow-right" />Logout</button></div>
    </aside>
    <div className="lrn-main">
      <header className="lrn-topbar">
        <div className="topbar-left">
          <button type="button" className="menu-toggle" onClick={() => setSidebarOpen(v => !v)} aria-label="Toggle menu"><i className="bi bi-list" /></button>
          <div><div className="lrn-page-title">{pageTitle}</div><div className="lrn-breadcrumb">LRN Analytics / <span>{pageTitle}</span></div></div>
        </div>
        <div className="topbar-actions">
          {workflowNotifications.total > 0 && <div className="notification-wrap"><button type="button" className="notification-btn" title="Claims needing attention" onClick={() => setNotificationOpen(v => !v)}><i className="bi bi-bell-fill" /><span className="notification-count">{workflowNotifications.total}</span><span className="notification-text"><b>{workflowNotifications.total}</b> {reviewerOnly ? 'claims need attention' : 'escalation claim(s)'}</span></button>{notificationOpen && <NotificationDetails />}</div>}
          {headerLabs.length > 0 && <select className="top-lab-select" value={labId || ''} onChange={e => setLabId(Number(e.target.value))}>{headerLabs.map(l => <option key={l.labId ?? l.LabId} value={l.labId ?? l.LabId}>{l.labName ?? l.LabName}</option>)}</select>}
          {showOverallDownload && claimExportJob && <span className={`export-status-pill ${claimExportJob.status === 'Completed' ? 'done' : exportBusy ? 'running' : 'failed'}`} title={claimExportJob.message || claimExportJob.status}>{exportStatusText()}</span>}
          {showOverallDownload && claimExportJob && <button type="button" className={`topbar-btn ${claimExportJob.status === 'Completed' ? 'teal' : ''}`} disabled={claimExportJob.status !== 'Completed'} onClick={downloadClaimExport} title={claimExportJob.message || claimExportJob.status}><i className={`bi ${claimExportJob.status === 'Completed' ? 'bi-file-earmark-excel' : 'bi-hourglass-split'}`} />{claimExportJob.status === 'Completed' ? 'Download File' : 'Waiting'}</button>}
          {showOverallDownload && exportBusy && <button type="button" className="topbar-btn" onClick={refreshClaimExportStatus}><i className="bi bi-arrow-clockwise" />Refresh Export</button>}
          {showOverallDownload && exportBusy && <button type="button" className="topbar-btn danger" onClick={cancelClaimExport}><i className="bi bi-x-circle" />Cancel Export</button>}
          {showOverallDownload && <button className="topbar-btn teal" onClick={() => startClaimExport({ currentTab: false })} disabled={exportBusy}><i className="bi bi-download" />Overall Download</button>}
          <button type="button" className={`topbar-btn ${view === 'support' ? 'teal' : ''}`} onClick={() => setView('support')}><i className="bi bi-life-preserver" />Support</button>
          <div className="profile-menu">
            <button type="button" className="profile-trigger" onClick={() => setProfileOpen(v => !v)}>
              <span className="avatar-sm">{initials(user.displayName || user.userName)}</span>
              <span className="profile-name">{user.displayName || user.userName || 'Workflow User'}</span>
              <i className="bi bi-chevron-down" />
            </button>
            {profileOpen && <div className="profile-dropdown">
              <div className="profile-dropdown-head">
                <span className="avatar-sm">{initials(user.displayName || user.userName)}</span>
                <div><strong>{user.displayName || user.userName || 'Workflow User'}</strong><small>{roleDisplayLabel(user.role)}</small></div>
              </div>
              <button type="button" onClick={() => { setProfileOpen(false); setView('support'); }}><i className="bi bi-life-preserver" />Contact Support</button>
              <button type="button" onClick={logoutWorkflow}><i className="bi bi-box-arrow-right" />Logout</button>
            </div>}
          </div>
          <button type="button" className="topbar-btn logout-top" onClick={logoutWorkflow}><i className="bi bi-box-arrow-right" />Logout</button>
        </div>
      </header>
      <main className="lrn-content">
        {mapperNotification&&<div className="lrn-alert warning mapper-login-alert"><div><strong>Denial Code push confirmation is pending.</strong><span>Review it in Denial Action Master before applying the codes to this lab.</span></div><div><button className="wl-btn teal xs" onClick={()=>{setMapperReviewAuditId(mapperNotification.pushAuditId);setView('denialcodemaster');}}>Review Now</button><button className="wl-btn xs" onClick={()=>setMapperNotification(null)}>Later</button></div></div>}
        {view !== 'denialmapper' && <div className="claim-filter-toggle-row">
          <div className="last-run-reference" title={lastRunReference?.outputFileName || lastRunReference?.OutputFileName || lastRunReference?.runId || lastRunReference?.RunId || ''}>
            <i className="bi bi-file-earmark-text" />
            <span className="last-run-label">Source File</span>
            <strong>{lastRunLoading ? 'Loading...' : (lastRunReference?.fileNameWithoutExtension || lastRunReference?.FileNameWithoutExtension || 'Not available')}</strong>
          </div>
          {(view === 'dashboard' || view === 'claims') && <button type="button" className="wl-btn xs" onClick={() => view === 'dashboard' ? setDashboardFiltersOpen(v => !v) : setClaimFiltersOpen(v => !v)}><i className={`bi ${view === 'dashboard' ? (dashboardFiltersOpen ? 'bi-eye-slash' : 'bi-funnel') : (claimFiltersOpen ? 'bi-eye-slash' : 'bi-funnel')}`} />{view === 'dashboard' ? (dashboardFiltersOpen ? 'Hide Filters' : 'View Filters') : (claimFiltersOpen ? 'Hide Filters' : 'View Filters')}</button>}
        </div>}
        {view !== 'myworklist' && view !== 'aging' && view !== 'support' && view !== 'denialcodemaster' && view !== 'denialmapper' && view !== 'denialactionverification' && (
          <div className={(view === 'verification' || view === 'escalations' || (view === 'claims' && !claimFiltersOpen) || (view === 'dashboard' && !dashboardFiltersOpen)) ? 'global-filter-hidden' : ''}>
            <DashboardFilter filter={filter} setFilterValue={setFilterValue} clearFilter={clearFilter} reviewers={reviewers} options={filterOptions} visibleFilters={visibleFilters} />
          </div>
        )}
        {message && <div className={`lrn-alert ${message.type}`}>
          <div>{message.text}</div>
          {message.type === 'danger' && (message.supportEmails?.length ? message.supportEmails : supportEmails).length > 0 && (
            <div className="support-email-list">
              <span>Admin support:</span>
              {(message.supportEmails?.length ? message.supportEmails : supportEmails).map(email => <a key={email} href={`mailto:${email}`}>{email}</a>)}
            </div>
          )}
          {message.type === 'danger' && message.correlationId && <small>Error ID: {message.correlationId}</small>}
        </div>}
        {loading && <div className="loading-line" />}
        {view === 'dashboard' && <DashboardPage data={{ ...dashboard, assignedClaims: (reviewerOnly ? myWorklistMenuCounts.assigned : claimMenuCounts.assigned) ?? dashboard.assignedClaims }} user={user} labName={labName} onKpiClick={(next = {}) => {
          const { taskView: nextTaskView, ...nextFilter } = next;
          const targetQueue = normalizeQueueKey(nextTaskView || 'all');
          applyDrilldownFilters(nextFilter);
          if (reviewerOnly) setMyWorklistView(targetQueue === 'new' || targetQueue === 'unassigned' ? 'assigned' : targetQueue);
          else setClaimTaskView(targetQueue);
          setView(reviewerOnly ? 'myworklist' : 'claims', { preserveFilters: true });
        }} />}
        {view === 'aging' && <AgingDashboardPage data={agingDashboard} filter={filter} setFilterValue={setFilterValue} clearFilter={clearFilter} reviewers={reviewers} options={filterOptions} onCellClick={({ pivot, row, bucket }) => {
          const next = { page: 1 };
          if (pivot === 'payer') next.payerName = row?.name || '';
          if (pivot === 'classification') next.denialClassification = row?.name || '';
          if (pivot === 'action') next.actionCategory = row?.name || '';
          if (pivot === 'panel') next.panelName = row?.name || '';
          applyDrilldownFilters(next);
          if (reviewerOnly) setMyWorklistView('assigned');
          else setClaimTaskView('all');
          setView(reviewerOnly ? 'myworklist' : 'claims', { preserveFilters: true });
          setMessage({ type: 'info', text: `Showing claims for ${row?.name || 'selected group'} / ${bucket?.label || 'aging bucket'}.` });
        }} />}
        {view === 'summary' && <DenialSummaryPage data={dashboard} canAssign={canAssign} onClassificationClick={openClaimsByClassification} onActionCategoryClick={openClaimsByActionCategory} onAssign={() => { setClaimTaskView('new'); setView(reviewerOnly ? 'myworklist' : 'claims'); setMessage({ type: 'info', text: canAssign ? 'Select the required claim rows, choose reviewer, then assign.' : 'This role has read-only workflow access.' }); }} />}
        {view === 'claims' && <ClaimAssignmentPage data={claims} loading={loading} reviewers={reviewers} selected={selectedClaims} setSelected={setSelectedClaims} bulkReviewer={bulkReviewer} setBulkReviewer={setBulkReviewer} loadClaimTasks={loadClaimTasks} claimTasks={claimTasks} expandedClaim={expandedClaim} assignClaims={assignClaims} changePage={changePage} labId={labId} currentUser={user.userName || 'ReactWorkflow'} currentUserRole={user.role || ''} canAssign={canAssign} readOnlyWorkflow={readOnlyWorkflow} taskView={claimTaskView} setTaskView={handleClaimTaskViewChange} tabCounts={claimMenuCounts} openEscalationResponse={() => handleClaimTabRoute('response')} openVerification={() => handleClaimTabRoute('verification')} setMessage={setWorkflowMessage} onDownloadTemplate={() => startClaimExport({ currentTab: true, uploadTemplate: true })} onCsvUploaded={async () => { setClaimTasks({}); setExpandedClaim(''); setClaims(await denialWorkflowService.getClaims({ ...query, taskView: claimTaskView })); await refreshMenuCounts(); }} exportBusy={exportBusy} filter={filter} setFilterValue={setFilterValue} assignedUsers={filterOptions.assignedUsers || []} />}
        {view === 'verification' && <VerificationPage data={verification} changePage={changePage} tabCounts={claimMenuCounts} onTabChange={handleClaimTabRoute} reviewers={reviewers} canAssign={canAssign} assignClaims={assignClaims} />}
        {view === 'myworklist' && <MyWorklistPage labId={labId} user={user} options={filterOptions} filter={filter} setMessage={setWorkflowMessage} onSaved={() => { refreshMenuCounts(); refreshWorkflowNotifications(); }} taskView={myWorklistView} setTaskView={handleMyWorklistViewChange} tabCounts={myWorklistMenuCounts} onExportQueryChange={setMyWorklistExportQuery} onDownloadTemplate={(exportQuery, tab) => startClaimExport({ currentTab: true, uploadTemplate: true, queryOverride: exportQuery, tabKey: tab?.key || myWorklistView, tabLabel: tab?.label || '' })} exportBusy={exportBusy} />}
        {view === 'escalations' && <EscalationQueuePage labId={labId} user={user} reviewers={reviewers} taskView={escalationView === 'response' ? 'claim' : escalationView} responseOnly={escalationView === 'response'} setTaskView={setEscalationView} tabCounts={claimMenuCounts} onClaimTabChange={handleClaimTabRoute} canAssign={canAssign} assignClaims={assignClaims} setMessage={setWorkflowMessage} />}
        {view === 'denialcodemaster' && arManagerOnly && <DenialCodeMasterPage labId={labId} role={user.role || ''} setMessage={setWorkflowMessage} initialPushAuditId={mapperReviewAuditId} onPushConfirmed={()=>{setMapperNotification(null);setMapperReviewAuditId(null);}} onReviewActionChanges={(batchId) => { setActionVerificationBatchId(batchId || ''); setView('denialactionverification'); }} />}
        {view === 'denialmapper' && denialMapperRole && <DenialMapperPage user={user} labs={labs} labId={labId} setLabId={setLabId} setMessage={setWorkflowMessage} screen={denialMapperView} onScreenChange={setDenialMapperView} />}
        {view === 'denialactionverification' && (denialMapperAdmin || arManagerOnly) && <DenialActionVerificationPage labId={labId} setMessage={setWorkflowMessage} initialBatchId={actionVerificationBatchId} />}
        {view === 'exports' && <WorkflowPlaceholder title="Exports">Use Overall Download or per-tab Download from Claim Assignment for claim extracts. Aging Dashboard also includes a Download Excel action.</WorkflowPlaceholder>}
        {view === 'reports' && <WorkflowPlaceholder title="Reports">Coming soon. Denial trend analysis, payer performance, and SLA compliance reporting will be available here in a future release. In the meantime, the Denial Dashboard, Aging Dashboard, and per-tab Download actions cover current reporting needs.</WorkflowPlaceholder>}
        {view === 'support' && <ContactSupportPage user={user} currentPage={pageTitle} setMessage={setWorkflowMessage} />}
        {view === 'admin' && <WorkflowPlaceholder title="Admin Setup">Admin setup is available from the LRN Metrics administration area. This workflow shell keeps the menu entry visible for administrators.</WorkflowPlaceholder>}
      </main>
      <footer className="lrn-footer">Copyright @Lab Revenue Navigator {copyrightYear}</footer>
    </div>
  </div>;
}
