import React, { useMemo, useRef, useState } from 'react';
import Pager from '../components/Pager';
import { money, date, statusClass } from '../utils/formatters';
import { denialWorkflowService } from '../services/denialWorkflowService';

const noteStatusOptions = ['Open', 'In Progress', 'Pending Payer', 'Pending Documentation', 'Escalated', 'Closed'];
const escalationReasons = ['EOB Pending', 'Client Info Pending', 'Document Required', 'Others'];

function dedupeEscalations(rows = []) {
  const seen = new Set();
  return (rows || []).filter(e => {
    const key = [
      String(e.claimId || '').trim().toLowerCase(),
      String(e.taskId || '').trim().toLowerCase(),
      String(e.cptCode || '').trim().toLowerCase(),
      String(e.escalationLevel || '').trim().toLowerCase(),
      String(e.escalationReason || '').trim().toLowerCase(),
      String(e.comments || '').trim().toLowerCase(),
      String(e.status || '').trim().toLowerCase(),
      String(e.createdBy || '').trim().toLowerCase(),
      e.createdOn ? new Date(e.createdOn).toISOString().slice(0, 19) : ''
    ].join('|');
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export default function ClaimAssignmentPage({ data, reviewers, selected, setSelected, bulkReviewer, setBulkReviewer, loadClaimTasks, claimTasks, expandedClaim, assignClaims, changePage, labId, currentUser, canAssign = false, readOnlyWorkflow = false, taskView = 'unassigned', setTaskView = () => {}, tabCounts = {}, openEscalationResponse = () => {}, openVerification = () => {}, setMessage = () => {}, onDownloadTab = () => {}, exportBusy = false, exportStatusText = '' }) {
  const [notePopup, setNotePopup] = useState(null);
  const [docPopup, setDocPopup] = useState(null);
  const [historyPopup, setHistoryPopup] = useState(null);
  const [drawerTab, setDrawerTab] = useState('lines');
  const [noteLineTarget, setNoteLineTarget] = useState('');
  const [docLineTarget, setDocLineTarget] = useState('');
  const [noteText, setNoteText] = useState('');
  const [noteStatus, setNoteStatus] = useState('In Progress');
  const [noteFollowUpDate, setNoteFollowUpDate] = useState('');
  const [uploadFiles, setUploadFiles] = useState([]);
  const [uploadComment, setUploadComment] = useState('');
  const [noteHistory, setNoteHistory] = useState([]);
  const [documents, setDocuments] = useState([]);
  const [busy, setBusy] = useState(false);
  const [escalationAssignee, setEscalationAssignee] = useState('');
  const [escalationPopup, setEscalationPopup] = useState(null);
  const [escalationReason, setEscalationReason] = useState('Client Info Pending');
  const [escalationComment, setEscalationComment] = useState('');
  const [escalationFollowUpDate, setEscalationFollowUpDate] = useState('');
  const [escalationOtherReason, setEscalationOtherReason] = useState('');
  const [escalationProgress, setEscalationProgress] = useState({ done: 0, total: 0, current: '' });
  const [escalationHistory, setEscalationHistory] = useState([]);
  const [claimSearch, setClaimSearch] = useState('');
  const [sort, setSort] = useState({ key: 'dateOfService', dir: 'desc' });
  const noteSavingRef = useRef(false);
  const escalationSubmittingRef = useRef(false);
  const rawItems = data.items || [];
  const searchedItems = useMemo(() => {
    const q = claimSearch.trim().toLowerCase();
    if (!q) return rawItems;
    return rawItems.filter(r => [
      r.claimId, r.claimID, r.ClaimId, r.ClaimID,
      r.claimUid, r.claimUID, r.ClaimUid, r.ClaimUID,
      r.source, r.Source,
      r.visitNumber, r.VisitNumber,
      r.accessionNumber, r.AccessionNumber,
      r.payerName, r.PayerName,
      r.patientName, r.PatientName,
      r.patientId, r.PatientId,
      r.subscriberId, r.SubscriberId,
      r.panelName, r.PanelName,
      r.clinicName, r.ClinicName,
      r.referringProvider, r.ReferringProvider
    ].some(v => String(v ?? '').toLowerCase().includes(q)));
  }, [rawItems, claimSearch]);
  const sortValue = (row, key) => {
    if (key === 'insuranceBalance') return Number(row.insuranceBalance || 0);
    if (key === 'dateOfService' || key === 'createdOn') return row[key] ? new Date(row[key]).getTime() : 0;
    return String(row[key] ?? '').toLowerCase();
  };
  const items = useMemo(() => [...searchedItems].sort((a, b) => {
    const av = sortValue(a, sort.key);
    const bv = sortValue(b, sort.key);
    if (av < bv) return sort.dir === 'asc' ? -1 : 1;
    if (av > bv) return sort.dir === 'asc' ? 1 : -1;
    return 0;
  }), [searchedItems, sort]);
  const setSortKey = key => setSort(prev => ({ key, dir: prev.key === key && prev.dir === 'asc' ? 'desc' : 'asc' }));
  const SortButton = ({ sortKey, children }) => <button type="button" className="claim-sort-btn" onClick={() => setSortKey(sortKey)}>{children}<i className={`bi ${sort.key === sortKey && sort.dir === 'asc' ? 'bi-sort-up' : 'bi-sort-down'}`} /></button>;
  const getClaimId = (r) => String(r?.claimId ?? r?.claimID ?? r?.ClaimId ?? r?.ClaimID ?? '').trim();
  const getClaimUid = (r) => String(r?.claimUid ?? r?.claimUID ?? r?.ClaimUid ?? r?.ClaimUID ?? '').trim() || getClaimId(r);
  const all = canAssign && items.length > 0 && items.every((_, i) => selected[i]);
  const selectedClaimIds = canAssign ? items.filter((_, i) => selected[i]).map(getClaimUid).filter(Boolean) : [];
  const loadedCount = items.length;
  const totalCount = data.totalCount || loadedCount;
  const isEscalatedView = taskView === 'internalEscalation' || taskView === 'externalEscalation' || taskView === 'escalations';
  const claimTabs = useMemo(() => [
    { key: 'new', label: 'New', hint: 'Not assigned and created within 48 hours' },
    { key: 'unassigned', label: 'Unassigned', hint: 'Not assigned after 48 hours' },
    { key: 'assigned', label: 'Assigned', hint: 'Assigned and still active' },
    { key: 'internalEscalation', label: 'Internal Escalation', hint: 'Escalated by AR Reviewer' },
    { key: 'externalEscalation', label: 'External Escalation', hint: 'Escalated to Client or Account Manager' },
    ...(canAssign ? [
      { key: 'response', label: 'Escalated Response', hint: 'Manager responses waiting for review', countKey: 'escalationResponse', route: openEscalationResponse },
      { key: 'verification', label: 'Verification Claim', hint: 'Claims moved to verification', route: openVerification }
    ] : []),
    { key: 'closed', label: 'Closed', hint: 'Completed / closed by reviewer' }
  ], [canAssign, openEscalationResponse, openVerification]);
  const tabCountText = value => {
    if (value === null || value === undefined) return '...';
    const n = Number(value || 0);
    return n > 99999 ? `${Math.round(n / 1000)}k` : n.toLocaleString();
  };
  const activeTab = useMemo(() => claimTabs.find(t => t.key === taskView) || claimTabs[0], [claimTabs, taskView]);
  const normalizeRole = value => String(value || '').replace(/[^a-z0-9]/gi, '').toLowerCase();
  const arReviewers = useMemo(() => (reviewers || []).filter(r => {
    const role = normalizeRole(r.role || r.Role);
    return !role || role.includes('arreviewer') || role.includes('analyst') || role.includes('analyser') || (role.includes('reviewer') && !role.includes('manager'));
  }), [reviewers]);
  const escalationAssignees = useMemo(() => (reviewers || []).filter(r => {
    const role = normalizeRole(r.role || r.Role);
    return role.includes('clientmanager') || role.includes('accountmanager');
  }), [reviewers]);
  const escalationAssigneeOption = useMemo(() => escalationAssignees.find(r => (r.userName || r.UserName) === escalationAssignee), [escalationAssignees, escalationAssignee]);

  async function loadNotes(info) {
    const rows = await denialWorkflowService.getNotes({ labId, claimId: info.claimId, taskId: info.taskId, cptCode: info.cptCode, noteLevel: info.type });
    setNoteHistory(rows || []);
  }

  function claimLineOptions(claimId) {
    const rows = claimTasks?.[claimId] || [];
    return rows.map((t, i) => ({
      key: `${t.taskId || ''}|${t.cptCode || ''}|${i}`,
      taskId: t.taskId || '',
      cptCode: t.cptCode || '',
      label: `${t.denialCode || 'Denial'} - CPT ${t.cptCode || '-'}`
    }));
  }

  function selectedLineTarget(value, claimId) {
    if (!value) return { taskId: '', cptCode: '', label: 'Overall claim' };
    return claimLineOptions(claimId).find(x => x.key === value) || { taskId: '', cptCode: '', label: 'Overall claim' };
  }

  async function openClaimNotes(row, targetKey = '') {
    const claimId = getClaimId(row);
    const claimUid = getClaimUid(row);
    const info = { type: 'Claim', claimId, title: `Claim Notes — ${claimId}`, meta: `${row.payerName || '-'} · ${row.patientName || '-'} · DOS ${date(row.dateOfService)}`, options: claimLineOptions(claimId) };
    info.claimId = claimId || claimUid;
    info.title = `Claim Notes - ${claimUid}`;
    info.meta = `Visit ${claimId || '-'} - ${row.payerName || '-'} - ${row.patientName || '-'} - DOS ${date(row.dateOfService)}`;
    info.options = claimLineOptions(claimUid);
    setNotePopup(info); setNoteLineTarget(targetKey); setNoteText(''); setNoteStatus(row.status || row.claimStatus || 'In Progress'); setNoteFollowUpDate(''); setNoteHistory([]);
    try { await loadNotes(info); } catch { }
  }

  async function openLineNotes(task, claimId) {
    const info = { type: 'Line', claimId, taskId: task.taskId || '', cptCode: task.cptCode || '', title: `Line Notes — ${claimId} / CPT ${task.cptCode || '-'}`, meta: `${task.taskId || '-'} · ${task.denialCode || '-'} · ${task.denialClassification || '-'}` };
    setNotePopup(info); setNoteText(''); setNoteStatus(task.status || 'In Progress'); setNoteFollowUpDate(''); setNoteHistory([]);
    try { await loadNotes(info); } catch { }
  }

  async function saveNote() {
    if (readOnlyWorkflow) return;
    if (noteSavingRef.current) return;
    if (!notePopup || !noteText.trim()) return;
    noteSavingRef.current = true;
    setBusy(true);
    try {
      const line = (notePopup.options || []).find(x => x.key === noteLineTarget) || selectedLineTarget(noteLineTarget, notePopup.claimId);
      const taskId = line.taskId || notePopup.taskId || null;
      const cptCode = line.cptCode || notePopup.cptCode || null;
      const noteLevel = taskId || cptCode || notePopup.type === 'Line' ? 'Line' : 'Claim';
      await denialWorkflowService.saveNote({ labId, claimId: notePopup.claimId, taskId, cptCode, noteLevel, noteText, status: noteStatus, nextFollowUpDate: noteFollowUpDate || null, createdBy: currentUser });
      setNoteText('');
      await loadNotes(notePopup);
    } finally { noteSavingRef.current = false; setBusy(false); }
  }

  async function openClaimDocuments(claimId, targetKey = '') {
    const drawerOptions = activeSupportClaimId && claimId === activeSupportClaimId
      ? activeTasks.map((t, i) => ({
        key: `${t.taskId || ''}|${t.cptCode || ''}|${i}`,
        taskId: t.taskId || '',
        cptCode: t.cptCode || '',
        label: `${t.denialCode || 'Denial'} - CPT ${t.cptCode || '-'}`
      }))
      : [];
    setDocPopup({ claimId, title: `Claim Documents - ${claimId}`, options: drawerOptions.length ? drawerOptions : claimLineOptions(claimId) });
    setDocLineTarget(targetKey); setUploadFiles([]); setUploadComment(''); setDocuments([]);
    try { setDocuments(await denialWorkflowService.getClaimDocuments(labId, claimId) || []); } catch { }
  }

  async function uploadDocuments() {
    if (readOnlyWorkflow) return;
    if (!docPopup || !uploadFiles.length) return;
    setBusy(true);
    try {
      const line = (docPopup.options || []).find(x => x.key === docLineTarget) || selectedLineTarget(docLineTarget, docPopup.claimId);
      const contextualComment = line.taskId || line.cptCode ? `[${line.label}] ${uploadComment || ''}`.trim() : uploadComment;
      await denialWorkflowService.uploadClaimDocuments(labId, docPopup.claimId, contextualComment, currentUser, uploadFiles);
      setUploadFiles([]); setUploadComment('');
      setDocuments(await denialWorkflowService.getClaimDocuments(labId, docPopup.claimId) || []);
    } finally { setBusy(false); }
  }

  async function openDocument(documentId) {
    const url = await denialWorkflowService.getClaimDocumentDownloadUrl(labId, documentId);
    window.open(url, '_blank', 'noopener,noreferrer');
  }

  async function deleteDocument(documentId, claimId = docPopup?.claimId || activeClaimId) {
    if (readOnlyWorkflow || !documentId || !claimId) return;
    if (!window.confirm('Delete this uploaded document?')) return;
    setBusy(true);
    try {
      await denialWorkflowService.deleteClaimDocument(labId, documentId);
      setDocuments(await denialWorkflowService.getClaimDocuments(labId, claimId) || []);
      setMessage({ type: 'success', text: 'Document deleted.' });
    } catch (e) {
      setMessage({ type: 'danger', text: e.message || 'Unable to delete document.' });
    } finally { setBusy(false); }
  }

  async function loadClaimDrawerTab(tab, claimId) {
    setDrawerTab(tab);
    if (!claimId) return;
    if (tab === 'notes') {
      setNoteHistory([]);
      try { setNoteHistory(await denialWorkflowService.getNotes({ labId, claimId, noteLevel: 'Claim' }) || []); } catch { }
    }
    if (tab === 'documents') {
      setDocuments([]);
      try { setDocuments(await denialWorkflowService.getClaimDocuments(labId, claimId) || []); } catch { }
    }
    if (tab === 'history') {
      setNoteHistory([]); setDocuments([]); setEscalationHistory([]);
      try {
        const [notes, docs, escalations] = await Promise.all([
          denialWorkflowService.getNotes({ labId, claimId, noteLevel: 'Claim' }),
          denialWorkflowService.getClaimDocuments(labId, claimId),
          denialWorkflowService.getEscalations({ labId, claimId, escalationLevel: 'Claim' })
        ]);
        setNoteHistory(notes || []); setDocuments(docs || []); setEscalationHistory(dedupeEscalations(escalations || []));
      } catch { }
    }
  }

  async function openEscalation(target) {
    if (!canAssign) return setMessage({ type: 'warning', text: 'Only Admin and AR Manager users can escalate claims/tasks.' });
    if (!target || !target.claimIds?.length) return setMessage({ type: 'warning', text: 'Please select one or more claim rows.' });
    setEscalationPopup(target);
    setEscalationReason('Client Info Pending');
    setEscalationComment('');
    setEscalationAssignee('');
    setEscalationFollowUpDate('');
    setEscalationOtherReason('');
    setEscalationProgress({ done: 0, total: 0, current: '' });
    setEscalationHistory([]);
    setNoteHistory([]);

    if (target.claimIds.length !== 1) return;

    try {
      const [rows, notes] = await Promise.all([
        denialWorkflowService.getEscalations({
        labId,
        claimId: target.claimIds[0],
        taskId: target.taskId || '',
        cptCode: target.cptCode || '',
        escalationLevel: target.level || 'Claim'
        }),
        denialWorkflowService.getNotes({
          labId,
          claimId: target.claimIds[0],
          taskId: target.taskId || '',
          cptCode: target.cptCode || '',
          noteLevel: target.level || 'Claim'
        })
      ]);
      const history = dedupeEscalations(rows || []);
      setEscalationHistory(history);
      setNoteHistory(notes || []);
      const latest = history[0];
      if (target.mode === 'update' && latest) {
        setEscalationPopup({ ...target, escalationId: latest.escalationId });
        setEscalationReason(latest.escalationReason || 'Client Info Pending');
        setEscalationAssignee(latest.escalatedTo || '');
        setEscalationFollowUpDate(latest.nextFollowUpDate ? String(latest.nextFollowUpDate).slice(0, 10) : '');
      }
    } catch {
      setEscalationHistory([]);
    }
  }

  async function escalateSelectedClaims() {
    openEscalation({ level: 'Claim', claimIds: selectedClaimIds, title: `Escalate ${selectedClaimIds.length} selected claim(s)` });
  }

  async function submitEscalationPopup() {
    if (!canAssign) return;
    if (escalationSubmittingRef.current) return;
    if (!escalationPopup?.claimIds?.length) return setMessage({ type: 'warning', text: 'Please select one or more claims/tasks.' });
    if (!escalationAssignee) return setMessage({ type: 'warning', text: 'Please select Client Manager or Account Manager.' });
    if (escalationReason === 'Others' && !escalationOtherReason.trim()) return setMessage({ type: 'warning', text: 'Please enter other escalation reason.' });
    if (!escalationComment.trim()) return setMessage({ type: 'warning', text: 'Please enter escalation comments.' });

    const finalEscalationReason = escalationReason === 'Others' ? `Others - ${escalationOtherReason.trim()}` : escalationReason;
    const finalEscalationComment = escalationReason === 'Others' ? `Other Reason: ${escalationOtherReason.trim()}${escalationComment ? '\n' + escalationComment : ''}` : escalationComment;
    const assignee = escalationAssigneeOption || {};
    const assigneeName = assignee.userName || assignee.UserName || escalationAssignee;
    const assigneeRole = assignee.role || assignee.Role || '';
    const claimIds = Array.from(new Set((escalationPopup.claimIds || []).map(x => String(x || '').trim()).filter(Boolean)));
    if (!claimIds.length) return setMessage({ type: 'warning', text: 'Please select one or more claims/tasks.' });
    const total = claimIds.length;
    escalationSubmittingRef.current = true;
    setBusy(true);
    setEscalationProgress({ done: 0, total, current: '' });
    try {
      if (escalationPopup.mode === 'update') {
        if (!escalationPopup.escalationId) return setMessage({ type: 'warning', text: 'No previous escalation found to update.' });
        const claimId = escalationPopup.claimIds[0];
        setEscalationProgress({ done: 0, total: 1, current: claimId });
        await denialWorkflowService.updateEscalation({
          labId,
          escalationId: escalationPopup.escalationId,
          claimId,
          taskId: escalationPopup.taskId || '',
          cptCode: escalationPopup.cptCode || '',
          escalationLevel: escalationPopup.level || 'Claim',
          escalationReason: finalEscalationReason,
          comments: finalEscalationComment,
          status: 'Open',
          nextFollowUpDate: escalationFollowUpDate || null,
          actionBy: currentUser || 'ReactWorkflow',
          escalatedTo: assigneeName,
          escalatedToRole: assigneeRole
        });
        setEscalationProgress({ done: 1, total: 1, current: '' });
        setEscalationPopup(null);
        setEscalationProgress({ done: 0, total: 0, current: '' });
        setMessage({ type: 'success', text: `Updated escalation for claim ${claimId}.` });
        return;
      }

      for (const claimId of claimIds) {
        setEscalationProgress(prev => ({ ...prev, current: claimId }));
        await denialWorkflowService.saveEscalation({
          labId,
          claimId,
          taskId: escalationPopup.taskId || '',
          cptCode: escalationPopup.cptCode || '',
          escalationLevel: escalationPopup.level || 'Claim',
          escalationReason: finalEscalationReason,
          comments: finalEscalationComment,
          status: 'Open',
          nextFollowUpDate: escalationFollowUpDate || null,
          createdBy: currentUser || 'ReactWorkflow',
          escalatedTo: assigneeName,
          escalatedToRole: assigneeRole
        });
        setEscalationProgress(prev => ({ ...prev, done: prev.done + 1, current: '' }));
      }
      setSelected({});
      setEscalationPopup(null);
      setEscalationProgress({ done: 0, total: 0, current: '' });
      setMessage({ type: 'success', text: `Escalated ${claimIds.length} ${String(escalationPopup.level || 'Claim').toLowerCase()} item(s) to ${assigneeName}.` });
    } catch (err) {
      setMessage({ type: 'danger', text: err.message || 'Escalation failed.' });
    } finally {
      escalationSubmittingRef.current = false;
      setBusy(false);
    }
  }

  async function openAssignmentHistory(claimId) {
    setHistoryPopup({ claimId, title: `Claim History — ${claimId}` });
    setNoteHistory([]); setDocuments([]); setEscalationHistory([]);
    try {
      const [claimNotes, docs, escalations] = await Promise.all([
        denialWorkflowService.getNotes({ labId, claimId, noteLevel: 'Claim' }),
        denialWorkflowService.getClaimDocuments(labId, claimId),
        denialWorkflowService.getEscalations({ labId, claimId, escalationLevel: 'Claim' })
      ]);
      setNoteHistory(claimNotes || []); setDocuments(docs || []); setEscalationHistory(dedupeEscalations(escalations || []));
    } catch { }
  }

  const statusLabel = useMemo(() => {
    if (taskView === 'assigned') return 'Assigned';
    if (taskView === 'closed') return 'Closed';
    if (taskView === 'internalEscalation') return 'Internal Escalation';
    if (taskView === 'externalEscalation') return 'External Escalation';
    if (taskView === 'unassigned') return 'Unassigned';
    return 'New';
  }, [taskView]);

  const tableColSpan = canAssign ? 20 : 18;
  const activeClaim = useMemo(() => items.find(r => getClaimUid(r) === expandedClaim) || null, [items, expandedClaim]);
  const activeClaimId = activeClaim ? getClaimUid(activeClaim) : '';
  const activeSupportClaimId = activeClaim ? (getClaimId(activeClaim) || activeClaimId) : '';
  const activeTasks = activeClaimId ? (claimTasks?.[activeClaimId] || []) : [];

  function resetDrawerState() {
    setDrawerTab('lines');
    setNoteHistory([]);
    setDocuments([]);
    setEscalationHistory([]);
  }

  function toggleClaim(row) {
    const claimUid = typeof row === 'string' ? row : getClaimUid(row);
    if (expandedClaim !== claimUid) resetDrawerState();
    loadClaimTasks(claimUid);
  }

  return <>
    <div className={`claim-split-shell ${activeClaim ? 'drawer-open' : ''}`}>
      <section className={`claim-list-pane ${activeClaim ? 'narrow' : 'full'}`}>
        <div className="claim-view-top">
          <div>
            <div className="claim-view-title">{canAssign ? 'Claim Level Assignment' : 'Claim Level View'}</div>
            <div className="claim-view-subtitle">{activeTab.label} claims - {loadedCount} of {totalCount}</div>
          </div>
          <span className="table-count">{statusLabel}</span>
        </div>
        <div className="claim-list-toolbar">
          <label className="claim-search-wrap"><i className="bi bi-search" /><input value={claimSearch} onChange={e => setClaimSearch(e.target.value)} placeholder="Search claim, payer, patient" /></label>
          <div className="claim-tab-row">{claimTabs.map(t => {
            const count = tabCounts?.[t.countKey || t.key];
            return <button key={t.key} type="button" className={`claim-tab ${taskView === t.key ? 'active' : ''}`} title={t.hint} onClick={() => t.route ? t.route() : setTaskView(t.key)}><span>{t.label}</span><b>{tabCountText(count)}</b></button>;
          })}<button type="button" className="claim-tab-download" onClick={onDownloadTab} disabled={exportBusy} title={exportStatusText || `Download ${activeTab.label} claims using current filters`}><i className="bi bi-download" />{exportBusy ? 'Export running' : `Download ${activeTab.label}`}</button></div>
        </div>
        {canAssign && <div className="claim-assign-bar2"><label><input type="checkbox" checked={all} onChange={e => { const next = {}; if (e.target.checked) items.forEach((_, i) => next[i] = true); setSelected(next); }} /> Select page</label><strong>{selectedClaimIds.length} selected</strong><select value={bulkReviewer} onChange={e => setBulkReviewer(e.target.value)}><option value="">Select AR Reviewer</option>{arReviewers.map(r => <option key={r.userName || r.UserName} value={r.userName || r.UserName}>{r.displayName || r.DisplayName || r.userName || r.UserName}</option>)}</select><button className="wl-btn teal xs" onClick={() => assignClaims(selectedClaimIds, bulkReviewer)} disabled={!selectedClaimIds.length}>Assign</button>{!isEscalatedView && <button className="wl-btn red xs" type="button" disabled={busy || !selectedClaimIds.length} onClick={escalateSelectedClaims}>Escalate</button>}</div>}
        <div className="claim-list-head claim-list-head-wide"><span><SortButton sortKey="claimId">Claim</SortButton></span><span><SortButton sortKey="source">Source</SortButton></span><span><SortButton sortKey="payerName">Payer Name</SortButton></span><span><SortButton sortKey="patientName">Patient Name</SortButton></span><span><SortButton sortKey="patientId">Patient ID</SortButton></span><span><SortButton sortKey="subscriberId">Subscriber ID</SortButton></span><span><SortButton sortKey="dateOfService">DOS</SortButton></span><span><SortButton sortKey="insuranceBalance">Balance</SortButton></span><span><SortButton sortKey="claimStatus">Status</SortButton></span></div>
        <div className="claim-rows-scroll">{items.length ? items.map((r, i) => { const claimId = getClaimId(r); const claimUid = getClaimUid(r); const isOpen = expandedClaim === claimUid; const workflowStatus = r.workflowStatus || r.status || r.taskStatus || statusLabel; const claimStatus = r.claimStatus || workflowStatus; return <div key={`${claimUid || claimId || 'claim'}-${i}`} className={`claim-list-row claim-list-row-wide ${isOpen ? 'active' : ''}`}>{canAssign && <span className="claim-row-check"><input type="checkbox" checked={!!selected[i]} onChange={e => setSelected({ ...selected, [i]: e.target.checked })} /></span>}<span className="claim-expand-dot"><i className={`bi ${isOpen ? 'bi-chevron-down' : 'bi-chevron-right'}`} /></span><span className="claim-list-id"><button className="claim-id-link" type="button" disabled={!claimUid} onClick={() => toggleClaim(r)}>{claimId || '-'}</button><small>UID {claimUid || '-'}</small></span><span className="claim-list-payer" title={r.source || ''}>{r.source || '-'}</span><span className="claim-list-payer" title={r.payerName || ''}>{r.payerName || '-'}</span><span className="claim-list-payer" title={r.patientName || ''}>{r.patientName || '-'}</span><span className="claim-list-payer" title={r.patientId || ''}>{r.patientId || '-'}</span><span className="claim-list-payer" title={r.subscriberId || ''}>{r.subscriberId || '-'}</span><span className="claim-list-payer">{date(r.dateOfService) || '-'}</span><span className="claim-list-amt">{money(r.insuranceBalance)}</span><span className={`badge ${statusClass(claimStatus)}`}>{claimStatus}</span></div>; }) : <div className="claim-empty-panel">No claim records found.</div>}</div>
      </section>
      {activeClaim && <section className="claim-drawer open">
        <div className="claim-drawer-header"><div><div className="claim-drawer-kicker">Claims / {activeTab.label} / Line Level</div><h3>{getClaimId(activeClaim) || '-'}</h3><p>Accession No: {activeClaim.accessionNumber || activeClaim.AccessionNumber || '-'}<br />{activeClaim.payerName || '-'} - {activeClaim.patientName || '-'} - {money(activeClaim.insuranceBalance)}</p></div><button className="wl-icon" title="Close claim drawer" type="button" onClick={() => { resetDrawerState(); loadClaimTasks(activeClaimId); }}><i className="bi bi-x-lg" /></button></div>
        <div className="claim-drawer-meta"><span><b>Source</b>{activeClaim.source || '-'}</span><span><b>Panel</b>{activeClaim.panelName || '-'}</span><span><b>DOB</b>{date(activeClaim.patientDOB)}</span><span><b>DOS</b>{date(activeClaim.dateOfService)}</span><span><b>Subscriber</b>{activeClaim.subscriberId || '-'}</span><span><b>Clinic</b>{activeClaim.clinicName || '-'}</span><span><b>Provider</b>{activeClaim.referringProvider || '-'}</span><span><b>Assigned</b>{activeClaim.assignedTo || '-'}</span></div>
        <div className="claim-drawer-actions"><button className="wl-icon icon-note" title={readOnlyWorkflow ? 'View claim notes' : 'Claim notes'} type="button" onClick={() => openClaimNotes(activeClaim)}><i className="bi bi-pencil-square" /></button><button className="wl-icon icon-doc" title={readOnlyWorkflow ? 'View documents' : 'Upload documents'} type="button" onClick={() => openClaimDocuments(activeSupportClaimId)}><i className="bi bi-paperclip" /></button>{canAssign && taskView === 'internalEscalation' && <><select className="drawer-reviewer-select" value={bulkReviewer} onChange={e => setBulkReviewer(e.target.value)}><option value="">Select AR Reviewer</option>{arReviewers.map(r => <option key={r.userName || r.UserName} value={r.userName || r.UserName}>{r.displayName || r.DisplayName || r.userName || r.UserName}</option>)}</select><button className="wl-btn teal xs" type="button" disabled={!activeClaimId} onClick={() => assignClaims([activeClaimId], bulkReviewer)}>Assign</button></>}{canAssign && <button className={`wl-btn ${isEscalatedView ? 'amber' : 'red'} xs`} type="button" onClick={() => openEscalation({ mode: isEscalatedView ? 'update' : undefined, level: 'Claim', claimIds: [activeSupportClaimId || activeClaimId], title: `${isEscalatedView ? 'Update escalation' : 'Escalate claim'} ${activeSupportClaimId || activeClaimId}` })}>{isEscalatedView ? 'Update' : 'Escalate'}</button>}</div>
        <div className="claim-drawer-tabs"><button className={drawerTab === 'lines' ? 'active' : ''} type="button" onClick={() => setDrawerTab('lines')}>Line Tasks</button><button className={drawerTab === 'notes' ? 'active' : ''} type="button" onClick={() => loadClaimDrawerTab('notes', activeSupportClaimId)}>Claim Notes</button><button className={drawerTab === 'documents' ? 'active' : ''} type="button" onClick={() => loadClaimDrawerTab('documents', activeSupportClaimId)}>Documents</button><button className={drawerTab === 'history' ? 'active' : ''} type="button" onClick={() => loadClaimDrawerTab('history', activeSupportClaimId)}>History</button></div>
        <div className="claim-drawer-body">
          {drawerTab === 'lines' && <table className="claim-task-table"><thead><tr><th>TaskID</th><th>CPTCode</th><th>Units</th><th>Modifier</th><th>DenialCode</th><th>DenialDescription</th><th>DenialClassification</th><th>ActionCode</th><th>ActionCategory</th><th>RecommendedAction</th><th>Priority</th><th className="r">InsuranceBalance</th><th>SLADays</th><th>Status</th><th>DateOpened</th><th>DueDate</th><th>SLAStatus</th><th>FirstBilledDate</th><th>ChargeEnteredDate</th><th>ICDComplianceStatus</th><th>DenialValidity</th></tr></thead><tbody>{activeTasks.length ? activeTasks.map((t, i) => <tr key={t.taskId || i}><td><strong>{t.taskId || '-'}</strong></td><td><code className="code">{t.cptCode || '-'}</code></td><td>{t.units ?? '-'}</td><td>{t.modifier || '-'}</td><td><code className="code">{t.denialCode || '-'}</code></td><td className="wrap-wide">{t.denialDescription || '-'}</td><td>{t.denialClassification || '-'}</td><td>{t.actionCode || '-'}</td><td>{t.actionCategory || '-'}</td><td className="wrap-wide">{t.recommendedAction || '-'}</td><td>{t.priority || '-'}</td><td className="r">{money(t.insuranceBalance)}</td><td>{t.slaDays ?? '-'}</td><td><span className={`badge ${statusClass(t.status || '')}`}>{t.status || '-'}</span></td><td>{date(t.dateOpened)}</td><td>{date(t.dueDate)}</td><td><span className={`badge ${statusClass(t.slaStatus || '')}`}>{t.slaStatus || '-'}</span></td><td>{date(t.firstBilledDate)}</td><td>{date(t.chargeEnteredDate)}</td><td>{t.icdComplianceStatus || '-'}</td><td>{t.denialValidity || '-'}</td></tr>) : <tr><td colSpan={21} className="empty-cell">Loading or no tasks found for this claim.</td></tr>}</tbody></table>}
          {drawerTab === 'notes' && <div className="claim-history-panel"><div className="claim-panel-actions"><button className="wl-btn teal xs" type="button" onClick={() => openClaimNotes(activeClaim)}>Add claim note</button></div>{noteHistory.length ? noteHistory.map(n => <div className="modal-row" key={n.noteId}><div className="modal-row-title">{n.noteText}</div><div className="modal-row-meta">{n.cptCode ? `CPT ${n.cptCode} · ` : 'Overall claim · '}{n.taskId ? `${n.taskId} · ` : ''}{n.status ? `Status: ${n.status} · ` : ''}{n.nextFollowUpDate ? `Follow-up: ${date(n.nextFollowUpDate)} · ` : ''}{n.createdBy || '-'} · {date(n.createdOn)}</div></div>) : <div className="claim-empty-panel">No claim notes found.</div>}</div>}
          {drawerTab === 'documents' && <div className="claim-history-panel"><div className="claim-panel-actions"><button className="wl-btn teal xs" type="button" onClick={() => openClaimDocuments(activeSupportClaimId)}>Upload document</button></div>{documents.length ? documents.map(d => <div className="modal-row document-row" key={d.documentId}><div><div className="modal-row-title">{d.originalFileName}</div><div className="modal-row-meta">{Math.ceil((d.fileSizeBytes || 0) / 1024)} KB · {d.uploadedBy || '-'} · {date(d.uploadedOn)} {d.comment ? `· ${d.comment}` : ''}</div></div><div className="doc-row-actions"><button className="wl-btn xs" type="button" onClick={() => openDocument(d.documentId)}>Download</button>{!readOnlyWorkflow && <button className="wl-btn red xs" type="button" disabled={busy} onClick={() => deleteDocument(d.documentId, activeSupportClaimId)}>Delete</button>}</div></div>) : <div className="claim-empty-panel">No documents uploaded.</div>}</div>}
          {drawerTab === 'history' && <div className="claim-history-panel"><div className="history-section-title">Escalations</div>{escalationHistory.length ? escalationHistory.map(e => <div className="modal-row" key={e.escalationId}><div className="modal-row-title">{e.escalationReason || '-'} {e.status ? `- ${e.status}` : ''}</div><div className="modal-row-meta">{e.escalatedTo ? `To: ${e.escalatedTo} · ` : ''}{e.createdBy || '-'} · {date(e.createdOn)}</div>{e.comments ? <div className="modal-row-meta">{e.comments}</div> : null}</div>) : <div className="modal-row"><div className="modal-row-title">No escalation history</div></div>}<div className="history-section-title">Claim Notes</div>{noteHistory.length ? noteHistory.map(n => <div className="modal-row" key={`h-note-${n.noteId}`}><div className="modal-row-title">{n.noteText}</div><div className="modal-row-meta">{n.cptCode ? `CPT ${n.cptCode} · ` : 'Overall claim · '}{n.createdBy || '-'} · {date(n.createdOn)}</div></div>) : <div className="modal-row"><div className="modal-row-title">No note history</div></div>}<div className="history-section-title">Documents</div>{documents.length ? documents.map(d => <div className="modal-row document-row" key={`h-doc-${d.documentId}`}><div><div className="modal-row-title">{d.originalFileName}</div><div className="modal-row-meta">{d.uploadedBy || '-'} · {date(d.uploadedOn)} {d.comment ? `· ${d.comment}` : ''}</div></div><button className="wl-btn xs" type="button" onClick={() => openDocument(d.documentId)}>Download</button></div>) : <div className="modal-row"><div className="modal-row-title">No document history</div></div>}</div>}
        </div>
      </section>}
    </div>
    {canAssign && (
      <div className="lrn-card assignment-toolbar claim-assign-toolbar">
        <div className="assign-left"><strong>Selected claims:</strong> <span>{selectedClaimIds.length}</span><small>Assigning a claim assigns all matching DenialTaskBoard task rows for that claim.</small></div>
        <div className="assign-right"><select value={bulkReviewer} onChange={e => setBulkReviewer(e.target.value)}><option value="">Select AR Reviewer</option>{arReviewers.map(r => <option key={r.userName || r.UserName} value={r.userName || r.UserName}>{r.displayName || r.DisplayName || r.userName || r.UserName}</option>)}</select><button className="wl-btn teal" onClick={() => assignClaims(selectedClaimIds, bulkReviewer)}><i className="bi bi-person-check" />{' '}Assign Selected Claims</button>{!isEscalatedView && <button className="wl-btn red" type="button" disabled={busy || !selectedClaimIds.length} onClick={escalateSelectedClaims}><i className="bi bi-exclamation-triangle" />{' '}Escalate</button>}</div>
      </div>
    )}

    <div className="lrn-card claim-card">
      <div className="lrn-card-header claim-card-hd"><div><div className="lrn-card-title">{canAssign ? 'Claim Level Assignment' : 'Claim Level View'} · {activeTab.label}</div><small className="claim-subtitle">VisitNumber grouped claim rows filtered by selected tab. Click a claim to expand task details under the row.</small></div><span className="table-count">Showing {loadedCount} of {totalCount} claim(s)</span></div>
      <div className="dt-wrap claim-assign-scroll">
        <table className={`lrn-table workflow-table claim-assign-table thin-bordered ${canAssign ? '' : 'claim-view-only-table'}`}><thead><tr>{canAssign && <th className="sticky-col select-col"><input type="checkbox" checked={all} onChange={e => { const next = {}; if (e.target.checked) items.forEach((_, i) => next[i] = true); setSelected(next); }} /></th>}<th>Claim ID</th><th>Claim UID</th><th>Source</th><th>Accession No</th><th>Payer Name</th><th>Panel Name</th><th>Patient Name</th><th>Patient DOB</th><th>Subscriber ID</th><th>Date Of Service</th><th>Created On</th><th>Clinic Name</th><th>Referring Provider</th><th className="text-right">Insurance Balance</th><th>Assigned To</th><th>Claim Level Status</th><th>Workflow Status</th>{canAssign && <th>Assign</th>}<th>Actions</th></tr></thead>
          <tbody>{items.length ? items.map((r, i) => { const claimId = getClaimId(r); const claimUid = getClaimUid(r); const isOpen = expandedClaim === claimUid; const tasks = claimTasks?.[claimUid] || []; const workflowStatus = r.workflowStatus || r.status || r.taskStatus || statusLabel; const claimStatus = r.claimStatus || workflowStatus; return <React.Fragment key={`${claimUid || claimId || 'claim'}-${i}`}><tr className={`claim-row-ui ${isOpen ? 'open' : ''}`}>{canAssign && <td className="sticky-col select-col"><input type="checkbox" checked={!!selected[i]} onChange={e => setSelected({ ...selected, [i]: e.target.checked })} /></td>}<td><button className="claim-id-link" type="button" disabled={!claimUid} onClick={() => toggleClaim(r)}><i className={`bi ${isOpen ? 'bi-chevron-down' : 'bi-chevron-right'}`} /> {claimId || '-'}</button></td><td><code className="code">{claimUid || '-'}</code></td><td>{r.source || '-'}</td><td>{r.accessionNumber || r.AccessionNumber || '-'}</td><td className="payer-full-cell" title={r.payerName || ''}>{r.payerName || '-'}</td><td>{r.panelName || '-'}</td><td>{r.patientName || '-'}</td><td>{date(r.patientDOB)}</td><td>{r.subscriberId || '-'}</td><td>{date(r.dateOfService)}</td><td>{date(r.createdOn)}</td><td>{r.clinicName || '-'}</td><td>{r.referringProvider || '-'}</td><td className="text-right claim-money">{money(r.insuranceBalance)}</td><td className="assigned-to-cell" title={r.assignedTo || ''}>{r.assignedTo || '-'}</td><td><span className={`badge ${statusClass(claimStatus)}`}>{claimStatus}</span></td><td><span className={`badge ${statusClass(workflowStatus)}`}>{workflowStatus}</span></td>{canAssign && <td><button className="wl-btn teal xs" type="button" onClick={() => assignClaims([claimUid], bulkReviewer)} disabled={!claimUid}>Assign</button></td>}<td className="actions-cell"><div className="claim-row-actions"><button className="wl-icon icon-note" title={readOnlyWorkflow ? 'View claim notes' : 'Claim notes'} type="button" onClick={() => openClaimNotes(r)}><i className="bi bi-pencil-square" /></button><button className="wl-icon icon-doc" title={readOnlyWorkflow ? 'View documents' : 'Upload documents'} type="button" disabled={!claimUid} onClick={() => openClaimDocuments(claimUid)}><i className="bi bi-paperclip" /></button><button className="wl-icon icon-history" title="Claim history" type="button" disabled={!claimUid} onClick={() => openAssignmentHistory(claimUid)}><i className="bi bi-clock-history" /></button>{canAssign && (isEscalatedView ? <button className="wl-btn amber xs update-action" type="button" disabled={!claimUid} onClick={() => openEscalation({ mode: 'update', level: 'Claim', claimIds: [claimUid], title: `Update escalation ${claimUid}` })}>Update</button> : <button className="wl-btn red xs" type="button" disabled={!claimUid} onClick={() => openEscalation({ level: 'Claim', claimIds: [claimUid], title: `Escalate claim ${claimUid}` })}>Escalate</button>)}</div></td></tr>{isOpen && <tr className="claim-task-expanded-row"><td colSpan={tableColSpan}><InlineClaimTaskDrill claimId={claimUid} tasks={tasks} openClaimNotes={() => openClaimNotes(r)} openLineNotes={openLineNotes} openClaimDocuments={openClaimDocuments} openAssignmentHistory={openAssignmentHistory} readOnlyWorkflow={readOnlyWorkflow} canAssign={canAssign} openEscalation={openEscalation} isEscalatedView={isEscalatedView} /></td></tr>}</React.Fragment>; }) : <tr><td colSpan={tableColSpan} className="empty-cell">No claim records found.</td></tr>}</tbody></table>
        <div style={{ padding: '10px 12px', textAlign: 'center', fontSize: 11, color: '#64748b' }}>
          {loadedCount ? <span>Showing page {data.page || 1} · {loadedCount} of {totalCount} matching claim(s).</span> : null}
        </div>
      </div>
    </div>
    <Pager data={data} changePage={changePage} />

    {notePopup && <div className="modal-backdrop"><div className="note-modal"><div className="note-modal-hd"><div><strong>{notePopup.title}</strong><small>{notePopup.meta}</small></div><button className="modal-close" onClick={() => setNotePopup(null)}>×</button></div><div className="note-modal-body"><div className="info-strip">Claim note can apply to the overall claim or a selected Denial Code - CPT Code.</div>{!readOnlyWorkflow && <><div className="note-form-grid"><label>Denial Code - CPT Code<select className="wl-full" value={noteLineTarget} onChange={e => setNoteLineTarget(e.target.value)}><option value="">Overall claim</option>{(notePopup.options || []).map(x => <option key={x.key} value={x.key}>{x.label}</option>)}</select></label><label>Status<select className="wl-full" value={noteStatus} onChange={e => setNoteStatus(e.target.value)}>{noteStatusOptions.map(x => <option key={x}>{x}</option>)}</select></label><label>Next follow-up date<input type="date" value={noteFollowUpDate} onChange={e => setNoteFollowUpDate(e.target.value)} /></label></div><textarea value={noteText} onChange={e => setNoteText(e.target.value)} placeholder="Add claim note..." /><div className="note-actions"><button className="wl-btn teal" type="button" disabled={busy || !noteText.trim()} onClick={saveNote}>Save note</button></div></>}<div className="modal-list">{noteHistory.length ? noteHistory.map(n => <div className="modal-row" key={n.noteId}><div className="modal-row-title">{n.noteText}</div><div className="modal-row-meta">{n.cptCode ? `CPT ${n.cptCode} · ` : 'Overall claim · '}{n.taskId ? `${n.taskId} · ` : ''}{n.status ? `Status: ${n.status} · ` : ''}{n.nextFollowUpDate ? `Follow-up: ${date(n.nextFollowUpDate)} · ` : ''}{n.createdBy || '-'} · {date(n.createdOn)}</div></div>) : <div className="modal-row"><div className="modal-row-title">No previous notes found</div><div className="modal-row-meta">Saved claim notes will show here.</div></div>}</div></div><div className="note-modal-ft"><button className="wl-btn" onClick={() => setNotePopup(null)}>Close</button></div></div></div>}

    {escalationPopup && <div className="modal-backdrop"><div className="note-modal"><div className="note-modal-hd"><div><strong>{escalationPopup.title || 'Escalate'}</strong><small>{busy && escalationProgress.total ? `${escalationPopup.mode === 'update' ? 'Updating' : 'Escalating'} ${escalationProgress.done} of ${escalationProgress.total}${escalationProgress.current ? ` - ${escalationProgress.current}` : ''}` : 'Select manager, reason, comments and next follow-up date.'}</small></div><button className="modal-close" disabled={busy} onClick={() => setEscalationPopup(null)}>×</button></div><div className="note-modal-body"><div className="note-form-grid"><label>Escalation value<select className="wl-full" value={escalationReason} disabled={busy} onChange={e => setEscalationReason(e.target.value)}>{escalationReasons.map(x => <option key={x}>{x}</option>)}</select></label><label>Client / Account Manager<select className="wl-full" value={escalationAssignee} disabled={busy} onChange={e => setEscalationAssignee(e.target.value)}><option value="">Select Client / Account Manager</option>{escalationAssignees.map(r => <option key={r.userName || r.UserName} value={r.userName || r.UserName}>{r.displayName || r.DisplayName || r.userName || r.UserName} — {r.role || r.Role}</option>)}</select></label><label>Next follow-up date<input type="date" value={escalationFollowUpDate} disabled={busy} onChange={e => setEscalationFollowUpDate(e.target.value)} /></label>{escalationReason === 'Others' && <label className="span2">Other reason<input value={escalationOtherReason} disabled={busy} onChange={e => setEscalationOtherReason(e.target.value)} placeholder="Enter other escalation reason..." /></label>}</div><textarea value={escalationComment} disabled={busy} onChange={e => setEscalationComment(e.target.value)} placeholder={escalationPopup.mode === 'update' ? 'Enter update comments...' : 'Enter escalation comments...'} /><div className="modal-list flat-history">{escalationHistory.length ? escalationHistory.map(e => <div className="modal-row" key={e.escalationId}><div className="modal-row-title">{e.escalationReason || '-'} {e.status ? `- ${e.status}` : ''}</div><div className="modal-row-meta">{e.escalatedTo ? `To: ${e.escalatedTo} · ` : ''}{e.nextFollowUpDate ? `Follow-up: ${date(e.nextFollowUpDate)} · ` : ''}{e.createdBy || '-'} · {date(e.createdOn)}</div>{e.comments ? <div className="modal-row-meta">{e.comments}</div> : null}</div>) : <div className="modal-row"><div className="modal-row-title">No previous escalation history found</div><div className="modal-row-meta">Escalation updates for this claim will show here.</div></div>}{noteHistory.length ? noteHistory.map(n => <div className="modal-row" key={`note-${n.noteId}`}><div className="modal-row-title">{n.noteText}</div><div className="modal-row-meta">{n.status ? `Status: ${n.status} · ` : ''}{n.nextFollowUpDate ? `Follow-up: ${date(n.nextFollowUpDate)} · ` : ''}{n.createdBy || '-'} · {date(n.createdOn)}</div></div>) : <div className="modal-row"><div className="modal-row-title">No notes found</div><div className="modal-row-meta">Saved claim notes will show here.</div></div>}</div>{busy && escalationProgress.total ? <div className="info-strip"><strong>{escalationPopup.mode === 'update' ? 'Updating escalation...' : 'Submitting escalations...'}</strong><span style={{ display: 'block', marginTop: 6 }}>{escalationProgress.done} of {escalationProgress.total} completed. Please keep this window open.</span><div style={{ marginTop: 8, height: 8, borderRadius: 999, background: '#e2e8f0', overflow: 'hidden' }}><div style={{ width: `${Math.max(2, Math.round((escalationProgress.done / escalationProgress.total) * 100))}%`, height: '100%', background: '#0f766e', transition: 'width 160ms ease' }} /></div></div> : null}<div className="note-actions"><button className={`wl-btn ${escalationPopup.mode === 'update' ? 'amber' : 'red'}`} type="button" disabled={busy || !escalationComment.trim() || !escalationAssignee || (escalationReason === 'Others' && !escalationOtherReason.trim())} onClick={submitEscalationPopup}>{busy && escalationProgress.total ? `${escalationPopup.mode === 'update' ? 'Updating' : 'Submitting'} ${escalationProgress.done}/${escalationProgress.total}` : escalationPopup.mode === 'update' ? 'Update escalation' : 'Submit escalation'}</button></div></div><div className="note-modal-ft"><button className="wl-btn" disabled={busy} onClick={() => setEscalationPopup(null)}>Close</button></div></div></div>}

    {docPopup && <div className="modal-backdrop"><div className="note-modal doc-modal"><div className="note-modal-hd"><div><strong>{docPopup.title}</strong><small>Upload supporting documents at claim level; optionally tag Denial Code - CPT Code.</small></div><button className="modal-close" onClick={() => setDocPopup(null)}>×</button></div><div className="note-modal-body">{!readOnlyWorkflow && <><div className="note-form-grid"><label>Denial Code - CPT Code<select className="wl-full" value={docLineTarget} onChange={e => setDocLineTarget(e.target.value)}><option value="">Overall claim</option>{(docPopup.options || []).map(x => <option key={x.key} value={x.key}>{x.label}</option>)}</select></label></div><textarea className="upload-comment" value={uploadComment} onChange={e => setUploadComment(e.target.value)} placeholder="Document comment..." /><div className="upload-drop"><i className="bi bi-cloud-arrow-up" /><strong>Upload claim document</strong><span>PDF, image, Excel, Word or EOB/supporting files</span><input type="file" multiple onChange={e => setUploadFiles(Array.from(e.target.files || []))} /></div><div className="note-actions"><button className="wl-btn teal" type="button" disabled={busy || !uploadFiles.length} onClick={uploadDocuments}>Upload document</button></div></>}<div className="modal-list upload-file-list">{uploadFiles.map((f, i) => <div className="modal-row" key={`${f.name}-${i}`}><div className="modal-row-title">{f.name}</div><div className="modal-row-meta">{Math.ceil(f.size / 1024)} KB · Ready to upload</div></div>)}{documents.length ? documents.map(d => <div className="modal-row document-row" key={d.documentId}><div><div className="modal-row-title">{d.originalFileName}</div><div className="modal-row-meta">{Math.ceil((d.fileSizeBytes || 0) / 1024)} KB · {d.uploadedBy || '-'} · {date(d.uploadedOn)} {d.comment ? `· ${d.comment}` : ''}</div></div><div className="doc-row-actions"><button className="wl-btn xs" type="button" onClick={() => openDocument(d.documentId)}>Download</button>{!readOnlyWorkflow && <button className="wl-btn red xs" type="button" disabled={busy} onClick={() => deleteDocument(d.documentId, docPopup.claimId)}>Delete</button>}</div></div>) : !uploadFiles.length && <div className="modal-row"><div className="modal-row-title">No document uploaded</div><div className="modal-row-meta">Choose files above to attach them to claim {docPopup.claimId}.</div></div>}</div></div><div className="note-modal-ft"><button className="wl-btn" onClick={() => setDocPopup(null)}>Close</button></div></div></div>}

    {historyPopup && <div className="modal-backdrop"><div className="note-modal"><div className="note-modal-hd"><div><strong>{historyPopup.title}</strong><small>Claim note, document and escalation history.</small></div><button className="modal-close" onClick={() => setHistoryPopup(null)}>×</button></div><div className="note-modal-body"><div className="modal-list"><div className="modal-row"><div className="modal-row-title">Escalations</div><div className="modal-row-meta">{escalationHistory.length} item(s)</div></div>{escalationHistory.map(e => <div className="modal-row" key={e.escalationId}><div className="modal-row-title">{e.escalationReason || '-'} {e.status ? `- ${e.status}` : ''}</div><div className="modal-row-meta">{e.escalatedTo ? `To: ${e.escalatedTo} · ` : ''}{e.createdBy || '-'} · {date(e.createdOn)}</div>{e.comments ? <div className="modal-row-meta">{e.comments}</div> : null}</div>)}<div className="modal-row"><div className="modal-row-title">Claim notes</div><div className="modal-row-meta">{noteHistory.length} note(s)</div></div>{noteHistory.map(n => <div className="modal-row" key={n.noteId}><div className="modal-row-title">{n.noteText}</div><div className="modal-row-meta">{n.createdBy || '-'} · {date(n.createdOn)}</div></div>)}<div className="modal-row"><div className="modal-row-title">Documents</div><div className="modal-row-meta">{documents.length} document(s)</div></div>{documents.map(d => <div className="modal-row" key={d.documentId}><div className="modal-row-title">{d.originalFileName}</div><div className="modal-row-meta">{d.uploadedBy || '-'} · {date(d.uploadedOn)} {d.comment ? `· ${d.comment}` : ''}</div></div>)}</div></div><div className="note-modal-ft"><button className="wl-btn" onClick={() => setHistoryPopup(null)}>Close</button></div></div></div>}
  </>;
}

function InlineClaimTaskDrill({ claimId, tasks, openClaimNotes, openLineNotes, openClaimDocuments, openAssignmentHistory, readOnlyWorkflow = false, canAssign = false, openEscalation = () => {}, isEscalatedView = false }) {
  return <div className="cpt-wrap"><div className="claim-drill-header claim-drill-header-compact"><div className="claim-level-actions-left"><button className="wl-icon icon-note" title="Claim notes" type="button" onClick={openClaimNotes}><i className="bi bi-pencil-square" /></button><button className="wl-icon icon-doc" title="Upload claim documents" type="button" onClick={() => openClaimDocuments(claimId)}><i className="bi bi-paperclip" /></button><button className="wl-icon icon-history" title="Claim history" type="button" onClick={() => openAssignmentHistory(claimId)}><i className="bi bi-clock-history" /></button></div><div className="claim-drill-title-block"><div className="cpt-title" style={{ marginBottom: 0 }}>Line-level task view</div><div className="line-note-hint">Claim-level icons are on the left. Line notes are saved per task/CPT row.</div></div></div><div className="cpt-scroll"><table className="cpt-tbl line-task-grid thin-bordered"><thead><tr><th className="task-sticky task-id-col">Task ID</th><th className="task-sticky claim-id-col">Claim ID</th><th>CPT Code</th><th>Units</th><th>Modifier</th><th>Denial Code</th><th className="denial-desc-col">Denial Description</th><th>Denial Classification</th><th>ICD Codes</th><th>ICD Status</th><th>Coverage</th><th>Validity</th><th>SLA Days</th><th>SLA Status</th><th>Assigned To</th><th className="r">Insurance Balance</th><th>Action Category</th><th>Action Code</th><th>Date Of Service</th><th>Recommended Action</th><th>Task</th><th>Days Remaining</th><th>Created On</th><th>Line Notes</th>{canAssign && <th>{isEscalatedView ? 'Update' : 'Escalate'}</th>}</tr></thead><tbody>{tasks.length ? tasks.map((t, i) => <tr key={t.taskId || i}><td className="task-sticky task-id-col"><strong>{t.taskId || '-'}</strong></td><td className="task-sticky claim-id-col"><strong>{t.claimId || claimId || '-'}</strong></td><td><code className="code">{t.cptCode || '-'}</code></td><td>{t.units ?? '-'}</td><td>{t.modifier || '-'}</td><td><code className="code">{t.denialCode || '-'}</code></td><td className="wrap-wide denial-desc-cell" title={t.denialDescription || ''}>{t.denialDescription || '-'}</td><td>{t.denialClassification || '-'}</td><td><code className="code">{t.icdCodes || '-'}</code></td><td>{t.icdComplianceStatus || '-'}</td><td>{t.coverageStatus || '-'}</td><td>{t.denialValidity || '-'}</td><td>{t.slaDays ?? '-'}</td><td>{t.slaStatus || '-'}</td><td>{t.assignedTo || '-'}</td><td className="r">{money(t.insuranceBalance)}</td><td>{t.actionCategory || '-'}</td><td>{t.actionCode || '-'}</td><td>{date(t.dateOfService)}</td><td className="task-action-cell">{t.recommendedAction || '-'}</td><td className="task-action-cell">{t.task || '-'}</td><td className="days-cell">{t.daysRemaining ?? '-'}</td><td>{date(t.createdOn)}</td><td><button className="wl-icon icon-note" type="button" title={readOnlyWorkflow ? 'View line notes' : 'Line notes'} onClick={() => openLineNotes(t, t.claimId || claimId)}><i className="bi bi-pencil-square" /></button></td>{canAssign && <td>{isEscalatedView ? <button className="wl-btn amber xs update-action" type="button" onClick={() => openEscalation({ mode: 'update', level: 'Line', claimIds: [claimId], taskId: t.taskId || '', cptCode: t.cptCode || '', title: `Update escalation ${t.taskId || ''} / CPT ${t.cptCode || '-'}` })}>Update</button> : <button className="wl-btn red xs" type="button" onClick={() => openEscalation({ level: 'Line', claimIds: [claimId], taskId: t.taskId || '', cptCode: t.cptCode || '', title: `Escalate task ${t.taskId || ''} / CPT ${t.cptCode || '-'}` })}>Escalate</button>}</td>}</tr>) : <tr><td colSpan={canAssign ? 25 : 24} className="empty-cell">No tasks found for this claim.</td></tr>}</tbody></table></div></div>;
}


