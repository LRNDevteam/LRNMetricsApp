import React, { useEffect, useMemo, useState } from 'react';
import { API_BASE } from './config/apiConfig';
import { emptyDashboard, emptyFilter, emptyFilterOptions, emptyPagedResult } from './dto/denialWorkflowDtos';
import { denialWorkflowService, qs } from './services/denialWorkflowService';
import { claimRole, claimUser, getJwt, parseJwt } from './utils/auth';
import { canAssignRole, initials } from './utils/formatters';
import DashboardFilter from './components/DashboardFilter';
import ClaimTaskModal from './components/ClaimTaskModal';
import DashboardPage from './pages/DashboardPage';
import DenialSummaryPage from './pages/DenialSummaryPage';
import InsightPage from './pages/InsightPage';
import ClaimAssignmentPage from './pages/ClaimAssignmentPage';
import TasksPage from './pages/TasksPage';
import VerificationPage from './pages/VerificationPage';

export default function App() {
  const jwtClaims = useMemo(() => parseJwt(getJwt()), []);
  const [user, setUser] = useState({ userName: claimUser(jwtClaims), role: claimRole(jwtClaims), labs: [] });
  const [labs, setLabs] = useState([]);
  const [reviewers, setReviewers] = useState([]);
  const [filterOptions, setFilterOptions] = useState(emptyFilterOptions);
  const [labId, setLabId] = useState(Number(localStorage.getItem('denial.labId') || 0));
  const [view, setView] = useState('dashboard');
  const [filter, setFilter] = useState(emptyFilter);
  const [dashboard, setDashboard] = useState(emptyDashboard);
  const [insights, setInsights] = useState(emptyPagedResult);
  const [claims, setClaims] = useState(emptyPagedResult);
  const [tasks, setTasks] = useState(emptyPagedResult);
  const [verification, setVerification] = useState(emptyPagedResult);
  const [selected, setSelected] = useState({});
  const [selectedClaims, setSelectedClaims] = useState({});
  const [claimTasks, setClaimTasks] = useState({});
  const [expandedClaim, setExpandedClaim] = useState('');
  const [claimTaskModal, setClaimTaskModal] = useState({ open: false, claimId: '' });
  const [bulkReviewer, setBulkReviewer] = useState('');
  const [rowReviewers, setRowReviewers] = useState({});
  const [message, setMessage] = useState(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    Promise.allSettled([denialWorkflowService.getMe()]).then(([me]) => {
      const meData = me.status === 'fulfilled' ? me.value : { userName: claimUser(jwtClaims), role: claimRole(jwtClaims), labs: [] };
      setUser(meData);
      const labData = meData.labs?.length ? meData.labs : [];
      setLabs(labData);
      if (!labId && labData.length) setLabId(labData[0].labId ?? labData[0].LabId);
      if (me.status === 'rejected') {
        denialWorkflowService.getLabs()
          .then(x => { setLabs(x || []); if (!labId && x?.length) setLabId(x[0].labId ?? x[0].LabId); })
          .catch(err => setMessage({ type: 'danger', text: err.message }));
      }
    });
  }, []);

  useEffect(() => { if (labId) localStorage.setItem('denial.labId', labId); }, [labId]);

  useEffect(() => {
    if (!labId) { setReviewers([]); return; }
    denialWorkflowService.getReviewers(labId)
      .then(x => setReviewers(x || []))
      .catch(err => { setReviewers([]); setMessage({ type: 'danger', text: `Reviewer load failed: ${err.message}` }); });
  }, [labId]);

  useEffect(() => {
    if (!labId) return;
    denialWorkflowService.getFilterOptions(labId)
      .then(x => setFilterOptions({ ...emptyFilterOptions, ...(x || {}) }))
      .catch(() => setFilterOptions(emptyFilterOptions));
  }, [labId]);

  const query = useMemo(() => ({
    labId,
    role: user.role,
    userName: user.userName,
    status: filter.status,
    reviewer: filter.reviewer,
    assignedTo: filter.reviewer,
    actionCategory: filter.actionCategory,
    priority: filter.priority,
    denialCode: filter.denialCode,
    payerName: filter.payerName,
    clinic: filter.clinic,
    salesRepname: filter.salesRepname,
    referringProvider: filter.referringProvider,
    denialClassification: filter.denialClassification,
    searchText: filter.searchText,
    page: filter.page || 1,
    pageSize: 50
  }), [labId, user, filter]);

  useEffect(() => {
    if (!labId) return;
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
  }, [labId, view, query]);

  const labName = labs.find(l => Number(l.labId ?? l.LabId) === Number(labId))?.labName || 'Select Lab';
  const pageTitle = { dashboard: 'Denial Workflow Dashboard', summary: 'Denial Summary', insight: 'Denial Insight', claims: 'Claim Level Assignment', tasks: 'Task Board', verification: 'Verification Queue' }[view] || 'Denial Workflow';

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
    if (claimTaskModal.open && claimTaskModal.claimId === claimId) { setClaimTaskModal({ open: false, claimId: '' }); return; }
    setExpandedClaim(claimId);
    setClaimTaskModal({ open: true, claimId });
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
        <button className={`lrn-nav-item ${view === 'tasks' ? 'active' : ''}`} onClick={() => setView('tasks')}><i className="bi bi-list-check" />Task Board<span className="lrn-nav-badge">{dashboard.openInProgressCount || 0}</span></button>
        <button className={`lrn-nav-item ${view === 'verification' ? 'active' : ''}`} onClick={() => setView('verification')}><i className="bi bi-shield-check" />Verification</button>
      </nav>
      <div className="lrn-sync"><div>API endpoint</div><span>{API_BASE}</span></div>
    </aside>
    <div className="lrn-main">
      <header className="lrn-topbar"><div><div className="lrn-page-title">{pageTitle}</div><div className="lrn-breadcrumb">LRN Analytics / <span>{pageTitle}</span></div></div><div className="topbar-actions"><select className="top-lab-select" value={labId || ''} onChange={e => setLabId(Number(e.target.value))}>{labs.map(l => <option key={l.labId ?? l.LabId} value={l.labId ?? l.LabId}>{l.labName ?? l.LabName}</option>)}</select><span className="current-lab">{labName}</span><button className="topbar-btn teal" onClick={() => setMessage({ type: 'info', text: 'Use backend export endpoint for Excel download.' })}><i className="bi bi-download" />Export</button></div></header>
      <main className="lrn-content">
        <DashboardFilter filter={filter} setFilterValue={setFilterValue} clearFilter={clearFilter} reviewers={reviewers} options={filterOptions} />
        {message && <div className={`lrn-alert ${message.type}`}>{message.text}</div>}
        {loading && <div className="loading-line" />}
        {view === 'dashboard' && <DashboardPage data={dashboard} />}
        {view === 'summary' && <DenialSummaryPage data={dashboard} canAssign={canAssignRole(user.role)} onClassificationClick={openClaimsByClassification} onAssign={() => { setView('insight'); setMessage({ type: 'info', text: 'Select the required rows in Denial Insight, choose reviewer, then assign.' }); }} />}
        {view === 'insight' && <InsightPage data={insights} reviewers={reviewers} selected={selected} setSelected={setSelected} bulkReviewer={bulkReviewer} setBulkReviewer={setBulkReviewer} rowReviewers={rowReviewers} setRowReviewers={setRowReviewers} assignRows={assignRows} changePage={changePage} />}
        {view === 'claims' && <ClaimAssignmentPage data={claims} reviewers={reviewers} selected={selectedClaims} setSelected={setSelectedClaims} bulkReviewer={bulkReviewer} setBulkReviewer={setBulkReviewer} loadClaimTasks={loadClaimTasks} assignClaims={assignClaims} changePage={changePage} />}
        {view === 'tasks' && <TasksPage data={tasks} saveTask={saveTask} changePage={changePage} />}
        {view === 'verification' && <VerificationPage data={verification} changePage={changePage} />}
        <ClaimTaskModal open={claimTaskModal.open} claimId={claimTaskModal.claimId} tasks={claimTasks[claimTaskModal.claimId] || []} onClose={() => setClaimTaskModal({ open: false, claimId: '' })} />
      </main>
    </div>
  </div>;
}
