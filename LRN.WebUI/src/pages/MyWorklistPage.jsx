import React, { useEffect, useMemo, useRef, useState } from 'react';
import { denialWorkflowService } from '../services/denialWorkflowService';
import Pager from '../components/Pager';
import SearchableMultiSelect from '../components/SearchableMultiSelect';
import DocumentTable from '../components/DocumentTable';
import ClaimNotesPanel from '../components/ClaimNotesPanel';
import HistoryTimeline from '../components/HistoryTimeline';
import StructuredNoteText from '../components/StructuredNoteText';
import { canUpdateWorkflowRole, isAccountManagerRole, isClientManagerRole } from '../utils/formatters';
import { canDeleteClaimDocument } from '../utils/documentPermissions';
import { MAX_TEXT_LENGTH, limitText, textCountLabel } from '../utils/textLimits';
import { dedupeEscalations } from '../utils/escalations';
import { getQueuesForRole } from '../config/workflowRoleQueues';
import ClaimCsvUpload from '../components/ClaimCsvUpload';

const fmtDate = v => v ? new Date(v).toLocaleDateString() : '-';
const money = v => Number(v || 0).toLocaleString(undefined, { style: 'currency', currency: 'USD' });
const statusOptions = ['Assigned', 'Payer Follow-up Required', 'Pending Payer Response', 'Pending Documentation', 'Write-Off Pending Approval', 'Closed'];
const escalationReasons = ['Denial reason unclear', 'Action clarification required', 'Denial-action mapping unclear', 'Payer policy conflict', 'Appeal eligibility unclear', 'Rebill eligibility unclear', 'Write-off decision required', 'Payer follow-up guidance needed', 'Documentation requirement unclear', 'EOB / payer response clarification', 'Other'];
const statusRank = ['Escalated to AR Manager', 'Rework', 'Pending Documentation', 'Pending Payer Response', 'Payer Follow-up Required', 'Write-Off Pending Approval', 'Assigned', 'New', 'Unassigned', 'Closed'];
const escalationAppliesToOptions = ['Overall Claim', 'Specific CPT', 'Action Group', 'Denial Classification'];
const documentationTypes = ['Medical Records Required', 'Clinical Notes Required', 'Authorization Reference Required', 'Updated Insurance Required', 'Requisition / Order Required', 'Provider Information Required', 'Diagnosis / ICD Clarification Required', 'Patient Demographics Required', 'EOB / Payer Correspondence Required', 'Client Confirmation Required', 'Other Documentation Required'];
const documentationDescriptions = {
  'Medical Records Required': 'MR needed for appeal or payer review.',
  'Clinical Notes Required': 'Progress/visit/clinical notes required.',
  'Authorization Reference Required': 'Prior auth/referral/auth proof needed.',
  'Updated Insurance Required': 'Correct payer, member ID, COB, eligibility, or coverage info needed.',
  'Requisition / Order Required': 'Signed requisition, lab order, or provider order needed.',
  'Provider Information Required': 'NPI, provider signature, taxonomy, facility details, or rendering/ordering provider data needed.',
  'Diagnosis / ICD Clarification Required': 'ICD correction or diagnosis clarification needed.',
  'Patient Demographics Required': 'DOB, name, gender, address, member details, or demographic corrections needed.',
  'EOB / Payer Correspondence Required': 'Copy of EOB, remittance, denial letter, or payer communication needed.',
  'Client Confirmation Required': 'General client confirmation needed before proceeding.',
  'Other Documentation Required': 'Exception case; note should be mandatory.'
};
const noteScopeOptions = ['By Claim', 'By Action Group', 'By Denial Classification', 'By CPT', 'By Selected Lines'];
const followUpReasons = ['Denial unclear', 'Action uncertain', 'Payer policy conflict', 'Need filing instructions', 'Claim status check', 'Timely filing confirmation', 'Other'];
const closureReasons = ['Paid/Recovered', 'Written Off', 'Denial Upheld', 'No Further Action', 'Invalid Denial', 'Timely Filing Expired', 'Duplicate', 'Client Approved Closure'];
const actualOutcomes = ['Appeal Submitted', 'Documentation Uploaded', 'Rebill Submitted', 'Corrected Claim Submitted', 'Write-Off Recommended', 'Payer Call Completed', 'Claim Paid', 'Claim Reprocessed', 'Closed No Recovery', 'Other'];

function roleIsReviewerOnly(role) {
  const r = String(role || '').toLowerCase();
  return (r.includes('reviewer') || r.includes('analyst') || r.includes('analyser')) && !r.includes('manager') && !r.includes('admin');
}

function isClientInfoPending(item) {
  const text = `${item?.status || ''} ${item?.reviewerComments || ''} ${item?.task || ''} ${item?.recommendedAction || ''} ${item?.assignedTo || ''}`.toLowerCase();
  return text.includes('client info pending') || text.includes('client information pending') || String(item?.assignedTo || '').toLowerCase().trim() === 'client manager';
}

function claimHasClientInfoPending(claim) {
  return (claim?.lines || []).some(isClientInfoPending);
}

function normalizeStatus(value) {
  const v = String(value || '').trim().toLowerCase();
  if (!v || v === 'open' || v === 'in progress' || v === 'pending review') return 'Assigned';
  if (v === 'pending payer') return 'Pending Payer Response';
  if (v === 'escalated' || v === 'internal escalation' || v === 'external escalation') return 'Escalated to AR Manager';
  if (v === 'completed') return 'Closed';
  if (v === 'required review') return 'Rework';
  return value || 'Assigned';
}

function pendingPayerOutcomeForLines(lines = []) {
  const text = lines.map(l => `${l?.actionCategory || ''} ${l?.recommendedAction || ''} ${l?.task || ''}`).join(' ').toLowerCase();
  return text.includes('doc') || text.includes('medical record') || text.includes('auth') ? 'Documentation Uploaded' : 'Appeal Submitted';
}

function groupByClaim(rows) {
  const map = new Map();
  rows.forEach(t => {
    const id = t.claimUid || t.claimUID || t.claimId || '-';
    const displayId = t.claimId || id;
    if (!map.has(id)) map.set(id, { claimUid: id, claimId: displayId, source: t.source || '-', payerName: t.payerName || t.payerNameNormalized || '-', panelName: t.panelName || '-', patientName: t.patientName || '-', patientId: t.patientId || '-', subscriberId: t.subscriberId || '-', dateOfService: t.dateOfService, createdOn: t.createdOn, clinicName: t.clinicName || '-', referringProvider: t.referringProvider || '-', assignedTo: t.assignedTo || '-', status: t.status || 'Open', balance: 0, lines: [] });
    const c = map.get(id);
    c.balance += Number(t.insuranceBalance || 0);
    c.lines.push(t);
    if ((!c.source || c.source === '-') && t.source) c.source = t.source;
    if ((!c.patientName || c.patientName === '-') && t.patientName) c.patientName = t.patientName;
    if ((!c.subscriberId || c.subscriberId === '-') && t.subscriberId) c.subscriberId = t.subscriberId;
    if (!c.createdOn || (t.createdOn && new Date(t.createdOn) > new Date(c.createdOn))) c.createdOn = t.createdOn;
    if (!c.assignedTo || c.assignedTo === '-') c.assignedTo = t.assignedTo || '-';
    const rowStatus = t.status || 'Open';
    const currentRank = statusRank.findIndex(x => x.toLowerCase() === String(c.status || '').toLowerCase());
    const rowRank = statusRank.findIndex(x => x.toLowerCase() === String(rowStatus).toLowerCase());
    if (rowRank >= 0 && (currentRank < 0 || rowRank < currentRank)) c.status = rowStatus;
    if (String(rowStatus).toLowerCase().includes('escal')) c.status = 'Escalated to AR Manager';
  });
  return Array.from(map.values());
}

function Modal({ title, children, onClose, className = '' }) {
  return <div className="wl-modal-bg"><div className={`wl-modal ${className}`.trim()}><div className="wl-modal-hd"><strong>{title}</strong><button className="wl-btn xs" onClick={onClose}>✕</button></div>{children}</div></div>;
}

function ClaimTaskLevelView({ claim, canEditClaim, canEditLine, openNote, showManagerResponse = false }) {
  const lines = claim?.lines || [];
  const completeCount = lines.filter(l => String(l.status || '').toLowerCase().includes('closed')).length;
  const pct = lines.length ? Math.round((completeCount / lines.length) * 100) : 0;
  return <div className="claim-task-workbench">
    <div className="claim-task-workbench-main">
      <div className="claim-task-panel-head"><div><h3>Denial Lines / Action Tracker</h3><p>Use status updates by claim, action group, denial classification, CPT, or selected lines.</p></div><button className="wl-btn teal" type="button" disabled={!canEditClaim(claim)} onClick={() => openNote('Claim', claim)}>Open Update Status Modal</button></div>
      <div className="claim-action-table-wrap"><table className="claim-action-table full-line-table"><thead><tr><th>TaskID</th><th>CPTCode</th><th>Units</th><th>Modifier</th><th>DenialCode</th><th>DenialDescription</th><th>DenialClassification</th><th>ActionCode</th><th>ActionCategory</th><th>RecommendedAction</th>{showManagerResponse && <th>Manager Response</th>}<th>Priority</th><th>InsuranceBalance</th><th>SLADays</th><th>Status</th><th>DateOpened</th><th>DueDate</th><th>SLAStatus</th><th>FirstBilledDate</th><th>ChargeEnteredDate</th><th>ICDComplianceStatus</th><th>DenialValidity</th><th>Update</th></tr></thead><tbody>{lines.length ? lines.map((l, i) => <tr key={l.taskId || i} className={String(l.status || '').toLowerCase().includes('closed') ? 'dim' : ''}><td><strong>{l.taskId || '-'}</strong></td><td><code className="code">{l.cptCode || '-'}</code></td><td>{l.units ?? '-'}</td><td>{l.modifier || '-'}</td><td><code className="code">{l.denialCode || '-'}</code></td><td className="wrap-wide">{l.denialDescription || '-'}</td><td>{l.denialClassification || '-'}</td><td>{l.actionCode || '-'}</td><td>{l.actionCategory || '-'}</td><td className={`wrap-wide ${showManagerResponse ? 'recommended-action-cell' : ''}`}><strong>{l.recommendedAction || '-'}</strong></td>{showManagerResponse && <td className="wrap-wide manager-response-cell">{l.reviewerComments || 'No manager response recorded.'}</td>}<td>{l.priority || '-'}</td><td>{money(l.insuranceBalance)}</td><td>{l.slaDays ?? '-'}</td><td><span className={`wl-badge ${String(l.status || 'Assigned').toLowerCase().replaceAll(' ', '-')}`}>{l.status || 'Assigned'}</span></td><td>{fmtDate(l.dateOpened)}</td><td>{fmtDate(l.dueDate)}</td><td><span className={`wl-badge ${String(l.slaStatus || '').toLowerCase().replaceAll(' ', '-')}`}>{l.slaStatus || '-'}</span></td><td>{fmtDate(l.firstBilledDate)}</td><td>{fmtDate(l.chargeEnteredDate)}</td><td>{l.icdComplianceStatus || '-'}</td><td>{l.denialValidity || '-'}</td><td><button className="wl-btn xs" type="button" disabled={!canEditLine(l)} onClick={() => openNote('Line', claim, l)}>Update</button></td></tr>) : <tr><td colSpan={showManagerResponse ? 23 : 22} className="empty-cell">No task lines found for this claim.</td></tr>}</tbody></table></div>
    </div>
    <aside className="claim-task-side"><div><h4>Claim Status</h4><span className={`wl-badge ${String(claim?.status || 'Assigned').toLowerCase().replaceAll(' ', '-')}`}>{claim?.status || 'Assigned'}</span><p>Calculated from line status precedence.</p></div><div><h4>Status Completion</h4><div className="scope-progress"><i style={{ width: `${pct}%` }} /></div><p>{completeCount} of {lines.length} actions completed</p></div><div><h4>Action Summary</h4>{Array.from(new Set(lines.map(l => l.actionCategory || l.task || l.recommendedAction).filter(Boolean))).map(action => { const group = lines.filter(l => (l.actionCategory || l.task || l.recommendedAction) === action); const done = group.filter(l => String(l.status || '').toLowerCase().includes('closed')).length; return <div className="scope-kv" key={action}><span>{action}</span><strong>{done}/{group.length}</strong></div>; })}</div></aside>
  </div>;
}

function WorklistClaimSplit({ claims, rows, loading, data, expanded, setExpanded, drawerTab, setDrawerTab, activeClaim, clientManager, accountManager, taskView, setTaskView, myTabs, tabCounts = {}, notes, docs, escalations, canEditClaim, canEditLine, canCreateEscalation, canDeleteDocumentForClaim, openNote, openDocs, openEsc, openDocument, deleteDocument, loadDrawerTab, canDownloadWorkflow = false, onDownloadTab = () => {}, csvUpload = null, exportBusy = false, exportStatusText = '' }) {
  const roleLabel = clientManager ? 'Client Manager' : accountManager ? 'Account Manager' : 'AR Reviewer';
  const activeTab = myTabs.find(x => x.key === taskView);
  return <div className={`claim-split-shell ${activeClaim ? 'drawer-open' : ''} ${loading ? 'claims-loading' : ''}`}>
    <section className={`claim-list-pane my-worklist-pane thin-list-border ${activeClaim ? 'narrow' : 'full'}`}>
      <div className="claim-view-top"><div><div className="claim-view-title">My Worklist</div><div className="claim-view-subtitle">{activeTab?.label || 'Work'} claims - {claims.length} claim(s), {rows.length} task(s)</div></div><span className="table-count">{loading ? 'Loading...' : activeTab?.label || 'Work'}</span></div>
      <div className="claim-list-toolbar"><label className="claim-search-wrap"><i className="bi bi-search" /><input readOnly value="" placeholder="Search claim, payer, patient" /></label><div className="claim-tab-row">{myTabs.map(t => { const count = Number(tabCounts?.[t.countKey || t.key] || 0); const active = taskView === t.key; return <button key={t.key} type="button" className={`claim-tab ${active ? 'active' : ''} ${active && loading ? 'is-loading' : ''} ${t.alert && count > 0 ? 'has-alert' : ''}`} title={t.hint} onClick={() => setTaskView(t.key)} disabled={active && loading}><span>{t.label}</span>{active && loading ? <i className="bi bi-arrow-repeat claim-tab-spinner" aria-label="Loading claims" /> : <b>{tabCounts?.[t.countKey || t.key] ?? 0}</b>}</button>; })}{canDownloadWorkflow && activeTab ? <button type="button" className="claim-tab-download" onClick={() => onDownloadTab(activeTab)} disabled={exportBusy} title={exportStatusText || `Download ${activeTab.label} worklist records using current filters`}><i className="bi bi-download" />{exportBusy ? 'Export running' : `Download ${activeTab.label}`}</button> : null}{csvUpload}</div></div>
      {loading && <div className="claim-tab-loading" role="status"><i className="bi bi-arrow-repeat" /><strong>Loading {activeTab?.label || 'worklist'} claims</strong><span>Refreshing this queue with the latest assignments...</span></div>}
      <div className="claim-list-head claim-list-head-wide my-worklist-head"><span>Claim</span><span>Source</span><span>Payer Name</span><span>Patient Name</span><span>Patient ID</span><span>Subscriber ID</span><span>DOS</span><span>Balance</span><span>Status</span></div>
      <div className="claim-rows-scroll">{claims.length ? claims.map(c => <button type="button" key={c.claimId} className={`claim-list-row claim-list-row-wide my-worklist-row ${expanded === c.claimId ? 'active' : ''}`} onClick={() => { setExpanded(expanded === c.claimId ? '' : c.claimId); setDrawerTab('lines'); }}><span className="claim-row-check my-worklist-spacer" aria-hidden="true" /><span className="claim-expand-dot"><i className={`bi ${expanded === c.claimId ? 'bi-chevron-down' : 'bi-chevron-right'}`} /></span><span className="claim-list-id"><strong className="claim-id-link as-text">{c.claimId}</strong><small>UID {c.claimId || '-'}</small></span><span className="claim-list-payer" title={c.source}>{c.source || '-'}</span><span className="claim-list-payer" title={c.payerName}>{c.payerName}</span><span className="claim-list-payer" title={c.patientName}>{c.patientName || '-'}</span><span className="claim-list-payer" title={c.patientId}>{c.patientId || '-'}</span><span className="claim-list-payer" title={c.subscriberId}>{c.subscriberId || '-'}</span><span className="claim-list-payer">{fmtDate(c.dateOfService)}</span><span className="claim-list-amt">{money(c.balance)}</span><span className={`wl-badge ${String(c.status).toLowerCase().replaceAll(' ', '-')}`}>{c.status}</span></button>) : <div className="claim-empty-panel">No worklist claims found.</div>}</div>
    </section>
    {activeClaim && <section className="claim-drawer open">
      <div className="claim-drawer-header"><div><div className="claim-drawer-kicker">My Worklist / Claim / Line Level</div><h3>{activeClaim.claimId}</h3><p>{activeClaim.payerName || '-'} - {money(activeClaim.balance)}</p></div><button className="wl-icon" title="Close claim drawer" type="button" onClick={() => setExpanded('')}><i className="bi bi-x-lg" /></button></div>
      <div className="claim-drawer-meta"><span><b>Source</b>{activeClaim.source || '-'}</span><span><b>Panel</b>{activeClaim.panelName || '-'}</span><span><b>Patient</b>{activeClaim.patientName || '-'}</span><span><b>Subscriber</b>{activeClaim.subscriberId || '-'}</span><span><b>DOS</b>{fmtDate(activeClaim.dateOfService)}</span><span><b>Created</b>{fmtDate(activeClaim.createdOn)}</span><span><b>Clinic</b>{activeClaim.clinicName || '-'}</span><span><b>Provider</b>{activeClaim.referringProvider || '-'}</span><span><b>Assigned</b>{activeClaim.assignedTo || '-'}</span></div>
      <div className="claim-drawer-actions"><button className="wl-icon icon-note" title="Claim notes" type="button" onClick={() => openNote('Claim', activeClaim)}><i className="bi bi-pencil-square" /></button><button className="wl-icon icon-doc" title="Claim documents" type="button" onClick={() => openDocs(activeClaim)}><i className="bi bi-paperclip" /></button>{canCreateEscalation ? <button className="wl-btn red xs" type="button" onClick={() => openEsc('Claim', activeClaim)}>Escalate</button> : <span className="muted-text">View only</span>}</div>
      <div className="claim-drawer-tabs"><button className={drawerTab === 'lines' ? 'active' : ''} type="button" onClick={() => setDrawerTab('lines')}>Tasks ({activeClaim.lines?.length || 0})</button><button className={drawerTab === 'notes' ? 'active' : ''} type="button" onClick={() => loadDrawerTab('notes', activeClaim)}>Notes ({notes.length})</button><button className={drawerTab === 'documents' ? 'active' : ''} type="button" onClick={() => loadDrawerTab('documents', activeClaim)}>Documents ({docs.length})</button><button className={drawerTab === 'history' ? 'active' : ''} type="button" onClick={() => loadDrawerTab('history', activeClaim)}>History</button></div>
      <div className="claim-drawer-body">
        {drawerTab === 'lines' && <ClaimTaskLevelView claim={activeClaim} canEditClaim={canEditClaim} canEditLine={canEditLine} openNote={openNote} showManagerResponse={taskView === 'escalationResponse'} />}
        {drawerTab === 'notes' && <ClaimNotesPanel notes={notes} canAdd={canEditClaim(activeClaim)} onAdd={() => openNote('Claim', activeClaim)} formatDate={fmtDate} />}
        {drawerTab === 'documents' && <DocumentTable documents={docs} canUpload={canEditClaim(activeClaim)} canDelete={() => canDeleteDocumentForClaim(activeClaim)} onUpload={() => openDocs(activeClaim)} onDownload={openDocument} onDelete={documentId => deleteDocument(documentId, activeClaim.claimId)} formatDate={fmtDate} />}
        {drawerTab === 'history' && <HistoryTimeline claim={activeClaim} notes={notes} documents={docs} escalations={escalations} formatDate={fmtDate} />}
      </div>
    </section>}
  </div>;
}

export default function MyWorklistPage({ labId, user, options, filter, setMessage, onRefreshToken, onSaved, taskView = 'open', setTaskView = () => {}, tabCounts = {}, onExportQueryChange = () => {}, onDownloadTab = () => {}, onDownloadTemplate = () => {}, exportBusy = false, exportStatusText = '', canDownloadWorkflow = false }) {
  const [data, setData] = useState({ items: [], page: 1, pageSize: 100, totalCount: 0, totalPages: 0 });
  const [loading, setLoading] = useState(false);
  const [expanded, setExpanded] = useState('');
  const [drawerTab, setDrawerTab] = useState('lines');
  const [page, setPage] = useState(1);
  const [local, setLocal] = useState({ payerName: '', denialClassification: '', actionCategory: '', status: '', searchText: '' });
  const [noteCtx, setNoteCtx] = useState(null);
  const [noteText, setNoteText] = useState('');
  const [noteStatus, setNoteStatus] = useState('Assigned');
  const [noteFollowUpDate, setNoteFollowUpDate] = useState('');
  const [actionCompleted, setActionCompleted] = useState('');
  const [actualOutcome, setActualOutcome] = useState('');
  const [documentationType, setDocumentationType] = useState('');
  const [noteUpdateScope, setNoteUpdateScope] = useState('By Claim');
  const [noteScopeValue, setNoteScopeValue] = useState('');
  const [noteSelectedLineKeys, setNoteSelectedLineKeys] = useState([]);
  const [followUpReason, setFollowUpReason] = useState('');
  const [closureReason, setClosureReason] = useState('');
  const [validationStatus, setValidationStatus] = useState('');
  const [notes, setNotes] = useState([]);
  const [noteSaving, setNoteSaving] = useState(false);
  const [docCtx, setDocCtx] = useState(null);
  const [docs, setDocs] = useState([]);
  const [docComment, setDocComment] = useState('');
  const [docFiles, setDocFiles] = useState([]);
  const [docUploading, setDocUploading] = useState(false);
  const [noteLineTarget, setNoteLineTarget] = useState('');
  const [docLineTarget, setDocLineTarget] = useState('');
  const [noteError, setNoteError] = useState('');
  const [docError, setDocError] = useState('');
  const [escError, setEscError] = useState('');
  const [escCtx, setEscCtx] = useState(null);
  const [escReason, setEscReason] = useState('');
  const [escComment, setEscComment] = useState('');
  const [escFollowUpDate, setEscFollowUpDate] = useState('');
  const [escOtherReason, setEscOtherReason] = useState('');
  const [escAppliesTo, setEscAppliesTo] = useState('Overall Claim');
  const [escScopeValue, setEscScopeValue] = useState('');
  const [escFiles, setEscFiles] = useState([]);
  const [escalations, setEscalations] = useState([]);
  const [escSaving, setEscSaving] = useState(false);
  const escSavingRef = useRef(false);
  const loadRequestRef = useRef(0);

  const role = user?.role || '';
  const clientManager = isClientManagerRole(role);
  const accountManager = isAccountManagerRole(role);
  const canUpdateTasks = canUpdateWorkflowRole(role);
  const canCreateEscalation = canUpdateTasks;
  const canUploadDocuments = canUpdateTasks || clientManager;
  const canSaveComments = canUpdateTasks || clientManager;
  const showEscalationReason = roleIsReviewerOnly(role);
  const reviewerEscalationClaimOnly = roleIsReviewerOnly(role);
  const canEditClaim = (claim) => canUpdateTasks || (clientManager && claimHasClientInfoPending(claim));
  const canEditLine = (line) => canUpdateTasks || (clientManager && isClientInfoPending(line));
  const canDeleteDocumentForClaim = (claim) => canDeleteClaimDocument(claim, { canUpload: canUploadDocuments, canEdit: canEditClaim(claim), uploading: docUploading, taskView });

  const query = useMemo(() => ({
    labId,
    role: user?.role || '',
    userName: user?.userName || '',
    assignedTo: roleIsReviewerOnly(user?.role) ? (user?.userName || '') : (filter?.reviewer || ''),
    reviewer: roleIsReviewerOnly(user?.role) ? (user?.userName || '') : (filter?.reviewer || ''),
    payerName: local.payerName || filter?.payerName || '',
    denialClassification: local.denialClassification || filter?.denialClassification || '',
    actionCategory: local.actionCategory || filter?.actionCategory || '',
    status: local.status || filter?.status || '',
    followUpReason: filter?.followUpReason || '',
    documentationType: filter?.documentationType || '',
    escalationReason: filter?.escalationReason || '',
    expectedResponseBy: filter?.expectedResponseBy || '',
    nextFollowUpDate: filter?.nextFollowUpDate || '',
    followupDue: filter?.followupDue || '',
    agingBucket: filter?.agingBucket || '',
    balanceBucket: filter?.balanceBucket || '',
    taskView: taskView === 'open' ? 'myopen' : taskView,
    searchText: local.searchText || filter?.searchText || '',
    page,
    pageSize: 100
  }), [labId, user, filter, local, taskView, page]);

  useEffect(() => { onExportQueryChange(query); }, [query, onExportQueryChange]);

  async function load(signal) {
    if (!labId) return;
    const requestId = ++loadRequestRef.current;
    setLoading(true);
    setData({ items: [], page, pageSize: 100, totalCount: 0, totalPages: 0 });
    setExpanded('');
    try {
      const result = await denialWorkflowService.getTasks(query, signal ? { signal } : {});
      if (signal?.aborted || requestId !== loadRequestRef.current) return;
      setData({ items: result?.items || [], page: result?.page || page, pageSize: result?.pageSize || 100, totalCount: result?.totalCount || 0, totalPages: result?.totalPages || 0 });
    } catch (e) {
      if (!signal?.aborted && requestId === loadRequestRef.current) setMessage?.({ type: 'danger', text: e.message });
    }
    finally {
      if (requestId === loadRequestRef.current) setLoading(false);
    }
  }
  useEffect(() => {
    const controller = new AbortController();
    load(controller.signal);
    return () => controller.abort();
  }, [query, onRefreshToken]);

  const rows = data.items || [];
  function changePage(nextPage) { setExpanded(''); setPage(nextPage); }

  useEffect(() => { setPage(1); setExpanded(''); }, [local, taskView]);

  const claims = useMemo(() => groupByClaim(rows), [rows]);
  const kpi = useMemo(() => ({ claims: claims.length, tasks: rows.length, balance: rows.reduce((a, b) => a + Number(b.insuranceBalance || 0), 0), escalated: rows.filter(x => String(x.status || '').toLowerCase().includes('escal')).length }), [claims, rows]);
  const myTabs = useMemo(() => getQueuesForRole(user?.role).map(t => t.key === 'escalationResponse' ? { ...t, alert: true } : t), [user?.role]);

  const activeClaim = useMemo(() => claims.find(c => c.claimId === expanded) || null, [claims, expanded]);

  function lineOptions(claim) {
    return (claim?.lines || []).map((l, i) => ({
      key: `${l.taskId || ''}|${l.cptCode || ''}|${i}`,
      taskId: l.taskId || '',
      cptCode: l.cptCode || '',
      label: `${l.denialCode || 'Denial'} - CPT ${l.cptCode || '-'}`
    }));
  }

  function selectedLine(value, claim) {
    if (!value) return { taskId: '', cptCode: '', label: 'Overall claim' };
    return lineOptions(claim).find(x => x.key === value) || { taskId: '', cptCode: '', label: 'Overall claim' };
  }

  function lineKey(line, index = 0) {
    return `${line?.taskId || ''}|${line?.cptCode || ''}|${index}`;
  }

  function scopeValues(scope, claim) {
    const lines = claim?.lines || [];
    if (scope === 'By Claim') return ['Overall Claim'];
    if (scope === 'By Action Group') return Array.from(new Set(lines.map(l => l.actionCategory || l.task || l.recommendedAction).filter(Boolean)));
    if (scope === 'By Denial Classification') return Array.from(new Set(lines.map(l => l.denialClassification).filter(Boolean)));
    if (scope === 'By CPT') return Array.from(new Set(lines.map(l => l.cptCode).filter(Boolean)));
    return [`Selected ${noteSelectedLineKeys.length} line(s)`];
  }

  function isProtectedLine(line) {
    const status = String(line?.status || '').toLowerCase();
    return status.includes('closed') || status.includes('escalated');
  }

  function affectedNoteLines(claim = noteCtx?.claim) {
    const lines = claim?.lines || [];
    if (noteUpdateScope === 'By Claim') return lines.filter(l => !isProtectedLine(l));
    if (noteUpdateScope === 'By Action Group') return lines.filter(l => (l.actionCategory || l.task || l.recommendedAction || '') === noteScopeValue && !isProtectedLine(l));
    if (noteUpdateScope === 'By Denial Classification') return lines.filter(l => (l.denialClassification || '') === noteScopeValue && !isProtectedLine(l));
    if (noteUpdateScope === 'By CPT') return lines.filter(l => (l.cptCode || '') === noteScopeValue && !isProtectedLine(l));
    return lines.filter((l, i) => noteSelectedLineKeys.includes(lineKey(l, i)) && !isProtectedLine(l));
  }

  function setScope(scope, claim) {
    const values = scopeValues(scope, claim);
    setNoteError('');
    setNoteUpdateScope(scope);
    setNoteScopeValue(values[0] || '');
  }

  async function openNote(level, claim, task) {
    const key = task ? lineOptions(claim).find(x => x.taskId === (task.taskId || '') && x.cptCode === (task.cptCode || ''))?.key || '' : '';
    const ctx = { level: level === 'Line' || task ? 'Line' : 'Claim', claim, task: task || null };
    const defaultScope = task ? 'By CPT' : 'By Claim';
    const selectedKeys = task ? (claim.lines || []).map((l, i) => ((l.taskId || '') === (task.taskId || '') && (l.cptCode || '') === (task.cptCode || '') ? lineKey(l, i) : '')).filter(Boolean) : [];
    setNoteError(''); setNoteCtx(ctx); setNoteLineTarget(key); setNoteText(''); setNoteStatus(normalizeStatus(task?.status || claim?.status || 'Assigned')); setNoteFollowUpDate(''); setActionCompleted(''); setActualOutcome(''); setDocumentationType(''); setFollowUpReason(''); setClosureReason(''); setValidationStatus(''); setNoteSelectedLineKeys(selectedKeys); setNoteUpdateScope(defaultScope); setNoteScopeValue(task?.cptCode || scopeValues(defaultScope, claim)[0] || '');
    const data = await denialWorkflowService.getNotes({ labId, claimId: claim.claimId, taskId: task?.taskId || '', cptCode: task?.cptCode || '', noteLevel: ctx.level });
    setNotes(data || []);
  }
  async function saveNote() {
    if (noteSaving) return;
    const failNote = (text) => { setNoteError(text); return; };
    if (!noteText.trim()) return failNote('Please enter comments.');
    const claim = noteCtx.claim;
    const task = selectedLine(noteLineTarget, claim);
    const affectedLines = affectedNoteLines(claim);
    if (canUpdateTasks && !affectedLines.length) return failNote('No eligible open lines match the selected update scope.');
    if (!canSaveComments) return failNote('This role has read-only access.');
    const actualTask = affectedLines[0] || (claim.lines || []).find(l => (l.taskId || '') === task.taskId && (l.cptCode || '') === task.cptCode);
    if (clientManager && !(actualTask ? isClientInfoPending(actualTask) : claimHasClientInfoPending(claim))) {
      return failNote('Client Manager can update comments only for Client Info Pending escalations.');
    }
    if (canUpdateTasks) {
      if (noteStatus === 'Payer Follow-up Required' && (!followUpReason || !noteFollowUpDate)) return failNote('Follow-up reason and expected response date are required.');
      if (noteStatus === 'Pending Payer Response' && (actionCompleted !== 'true' || !noteFollowUpDate)) return failNote('Pending Payer Response requires Action Completed = Yes and expected response date.');
      if (noteStatus === 'Pending Documentation' && (!documentationType || !noteFollowUpDate)) return failNote('Documentation type and expected response date are required.');
      if (noteStatus === 'Closed' && !noteText.trim()) return failNote('Please enter comments.');
      if (noteStatus === 'Write-Off Pending Approval' && !actualOutcome) return failNote('Actual outcome is required for write-off approval.');
    }
    const effectiveActualOutcome = noteStatus === 'Pending Payer Response' && actionCompleted === 'true' ? pendingPayerOutcomeForLines(affectedLines.length ? affectedLines : [actualTask || task]) : actualOutcome;
    const updatePayload = taskId => ({
      labId,
      taskId,
      status: noteStatus,
      comments: noteText,
      actionCompleted: actionCompleted === '' ? null : actionCompleted === 'true',
      actualOutcome: effectiveActualOutcome,
      documentationType,
      followUpReason,
      closureReason,
      validationStatus,
      expectedResponseDate: noteFollowUpDate || null,
      updateScope: actualTask?.taskId ? 'Line' : 'Claim',
      updateScopeValue: noteUpdateScope === 'By Claim' ? claim.claimId : noteScopeValue,
      actionBy: user?.userName || 'ReactWorkflow'
    });
    setNoteSaving(true);
    setNoteError('');
    try {
      const noteLevel = affectedLines.length === 1 ? 'Line' : 'Claim';
      const completedLabel = actionCompleted === '' ? 'Not set' : actionCompleted === 'true' ? 'Yes' : 'No';
      const statusSummary = [
        `Update Scope: ${noteUpdateScope}`,
        `Scope Value: ${noteScopeValue || 'Overall Claim'}`,
        `New Line Status: ${noteStatus}`,
        noteFollowUpDate ? `Next Follow-up Date: ${noteFollowUpDate}` : '',
        effectiveActualOutcome ? `Actual Action / Outcome: ${effectiveActualOutcome}` : '',
        affectedLines.length ? `Recommended Action: ${[...new Set(affectedLines.map(l => String(l.recommendedAction || '').trim()).filter(Boolean))].join(', ') || 'Not set'}` : '',
        `Action Completed: ${completedLabel}`,
        documentationType ? `Documentation Type: ${documentationType}` : '',
        documentationType && documentationDescriptions[documentationType] ? `Documentation Description: ${documentationDescriptions[documentationType]}` : '',
        affectedLines.length ? `Affected Lines: CPTs: ${[...new Set(affectedLines.map(l => String(l.cptCode || '').trim()).filter(Boolean))].join(', ')}` : ''
      ].filter(Boolean).join('\n');
      const selectedNoteText = `${statusSummary}\n\nNote: ${noteText}`.trim();
      await denialWorkflowService.saveNote({ labId, claimId: claim.claimId, taskId: affectedLines.length === 1 ? affectedLines[0].taskId || '' : '', cptCode: affectedLines.length === 1 ? affectedLines[0].cptCode || '' : '', noteLevel, noteText: selectedNoteText, status: noteStatus, nextFollowUpDate: noteFollowUpDate || null, createdBy: user?.userName || 'ReactWorkflow' });
      if (canUpdateTasks && noteStatus) {
        for (const l of affectedLines) await denialWorkflowService.updateTask(updatePayload(l.taskId));
      }
      setMessage?.({ type: 'success', text: canUpdateTasks ? 'Comment and status saved.' : 'Comment saved.' });
      onSaved?.();
      setNoteCtx(null); await load();
    } catch (e) {
      setNoteError(e.message || 'Unable to save comment.');
    } finally {
      setNoteSaving(false);
    }
  }

  async function openDocs(claim, task = null) {
    const key = task ? lineOptions(claim).find(x => x.taskId === (task.taskId || '') && x.cptCode === (task.cptCode || ''))?.key || '' : '';
    setDocError(''); setDocCtx(claim); setDocLineTarget(key); setDocComment(''); setDocFiles([]);
    setDocs(await denialWorkflowService.getClaimDocuments(labId, claim.claimId));
  }
  async function uploadDocs() {
    if (docUploading) return;
    if (!canUploadDocuments) return setDocError('This role cannot upload documents.');
    if (clientManager && !claimHasClientInfoPending(docCtx)) return setDocError('Client Manager can upload documents only for Client Info Pending escalations.');
    if (!docFiles?.length) return setDocError('Select at least one document.');
    setDocUploading(true);
    setDocError('');
    try {
      const line = selectedLine(docLineTarget, docCtx);
      const contextualComment = line.taskId || line.cptCode ? `[${line.label}] ${docComment || ''}`.trim() : docComment;
      await denialWorkflowService.uploadClaimDocuments(labId, docCtx.claimId, contextualComment, user?.userName || 'ReactWorkflow', docFiles);
      const refreshedDocs = await denialWorkflowService.getClaimDocuments(labId, docCtx.claimId);
      setDocs(refreshedDocs || []);
      setMessage?.({ type: 'success', text: 'Document uploaded successfully.' });
      onSaved?.();
      setDocFiles([]); setDocComment('');
    } catch (e) {
      setDocError(e.message || 'Unable to upload document.');
    } finally {
      setDocUploading(false);
    }
  }

  async function openDocument(documentId) {
    const url = await denialWorkflowService.getClaimDocumentDownloadUrl(labId, documentId);
    window.open(url, '_blank', 'noopener,noreferrer');
  }

  async function deleteDocument(documentId, claimId = docCtx?.claimId) {
    if (!documentId || !claimId) return;
    if (!canUploadDocuments) return setMessage?.({ type: 'warning', text: 'This role cannot delete documents.' });
    if (!canDeleteDocumentForClaim(docCtx || activeClaim)) return setMessage?.({ type: 'warning', text: 'Documents can be deleted only while the claim is still in the active editable stage.' });
    if (clientManager && !claimHasClientInfoPending(docCtx || activeClaim)) return setMessage?.({ type: 'warning', text: 'Client Manager can delete documents only for Client Info Pending escalations.' });
    if (!window.confirm('Delete this uploaded document?')) return;
    await denialWorkflowService.deleteClaimDocument(labId, documentId);
    setMessage?.({ type: 'success', text: 'Document deleted.' });
    onSaved?.();
    setDocs(await denialWorkflowService.getClaimDocuments(labId, claimId));
  }

  async function loadDrawerTab(tab, claim) {
    setDrawerTab(tab);
    if (!claim?.claimId) return;
    if (tab === 'notes') setNotes(await denialWorkflowService.getNotes({ labId, claimId: claim.claimId, noteLevel: 'Claim' }) || []);
    if (tab === 'documents') setDocs(await denialWorkflowService.getClaimDocuments(labId, claim.claimId) || []);
    if (tab === 'history') {
      const [n, d, e] = await Promise.all([
        denialWorkflowService.getNotes({ labId, claimId: claim.claimId, noteLevel: 'Claim' }),
        denialWorkflowService.getClaimDocuments(labId, claim.claimId),
        denialWorkflowService.getEscalations({ labId, claimId: claim.claimId, escalationLevel: 'Claim' })
      ]);
      setNotes(n || []); setDocs(d || []); setEscalations(dedupeEscalations(e || []));
    }
  }

  async function openEsc(level, claim, task) {
    const appliesTo = reviewerEscalationClaimOnly ? 'Overall Claim' : task ? 'Specific CPT' : 'Overall Claim';
    setEscError(''); setEscCtx({ level: reviewerEscalationClaimOnly ? 'Claim' : level === 'Line' || task ? 'Line' : 'Claim', claim, task: reviewerEscalationClaimOnly ? null : task || null }); setEscReason(escalationReasons[0]); setEscComment(''); setEscFollowUpDate(''); setEscOtherReason(''); setEscFiles([]); setEscAppliesTo(appliesTo); setEscScopeValue(reviewerEscalationClaimOnly ? '' : task?.taskId || '');
    const data = await denialWorkflowService.getEscalations({ labId, claimId: claim.claimId, escalationLevel: 'Claim' });
    setEscalations(dedupeEscalations(data || []));
  }
  async function saveEscalation() {
    if (escSavingRef.current) return;
    const failEsc = (text) => { setEscError(text); return; };
    if (!canCreateEscalation) return failEsc('This role cannot submit escalations.');
    if (showEscalationReason && escReason === 'Other' && !escOtherReason.trim()) return failEsc('Please enter other escalation reason.');
    if (!reviewerEscalationClaimOnly && escAppliesTo !== 'Overall Claim' && !escScopeValue) return failEsc(`Please select ${escAppliesTo}.`);
    const { claim, task } = escCtx;
    const finalEscReason = showEscalationReason ? (escReason === 'Other' ? `Other - ${escOtherReason.trim()}` : escReason) : 'Manager review requested';
    const finalEscComment = showEscalationReason && escReason === 'Other' ? `Other Reason: ${escOtherReason.trim()}${escComment ? '\n' + escComment : ''}` : escComment;
    escSavingRef.current = true;
    setEscSaving(true);
    setEscError('');
    try {
      const sourceLines = claim.lines || [];
      const selectedTask = reviewerEscalationClaimOnly ? null : task || sourceLines.find(x => (x.taskId || '') === escScopeValue);
      const effectiveAppliesTo = reviewerEscalationClaimOnly ? 'Overall Claim' : escAppliesTo;
      const affectedRaw = effectiveAppliesTo === 'Specific CPT'
        ? sourceLines.filter(x => selectedTask?.taskId ? (x.taskId || '') === selectedTask.taskId : (x.cptCode || '') === escScopeValue)
        : effectiveAppliesTo === 'Action Group'
          ? sourceLines.filter(x => (x.actionCategory || '') === escScopeValue)
          : effectiveAppliesTo === 'Denial Classification'
            ? sourceLines.filter(x => (x.denialClassification || '') === escScopeValue)
            : sourceLines;
      const affected = affectedRaw.filter(x => !isProtectedLine(x));
      if (!affected.length) {
        throw new Error('No eligible lines can be escalated. Closed or already escalated lines are protected.');
      }
      const scopeDisplay = effectiveAppliesTo === 'Specific CPT'
        ? `CPT ${selectedTask?.cptCode || escScopeValue || '-'}${selectedTask?.denialCode ? ` / ${selectedTask.denialCode}` : ''}`
        : effectiveAppliesTo;
      const escalationStatus = finalEscReason.toLowerCase().includes('write-off decision required') ? 'WriteOffPending' : 'Open';
      await denialWorkflowService.saveEscalation({ labId, claimId: claim.claimId, taskId: reviewerEscalationClaimOnly ? '' : selectedTask?.taskId || '', cptCode: reviewerEscalationClaimOnly ? '' : selectedTask?.cptCode || '', escalationLevel: effectiveAppliesTo === 'Specific CPT' ? 'Line' : 'Claim', escalationScope: effectiveAppliesTo, escalationScopeValue: effectiveAppliesTo === 'Overall Claim' ? claim.claimId : escScopeValue || claim.claimId, escalationScopeDisplay: scopeDisplay, affectedTaskIds: affected.map(x => x.taskId).filter(Boolean).join(','), recommendedNextAction: 'Manager review', escalationReason: finalEscReason, comments: finalEscComment, status: escalationStatus, nextFollowUpDate: escFollowUpDate || null, createdBy: user?.userName || 'ReactWorkflow' });
      if (escFiles.length) await denialWorkflowService.uploadClaimDocuments(labId, claim.claimId, `[Escalation Attachment] ${finalEscReason}${finalEscComment ? ' - ' + finalEscComment : ''}`, user?.userName || 'ReactWorkflow', escFiles);
      for (const l of affected) await denialWorkflowService.updateTask({ labId, taskId: l.taskId, status: 'Escalated to AR Manager', comments: `${finalEscReason}${finalEscComment ? ' - ' + finalEscComment : ''}`, actionBy: user?.userName || 'ReactWorkflow' });
      setMessage?.({ type: 'success', text: 'Claim escalation saved.' });
      onSaved?.();
      setEscFiles([]);
      setEscCtx(null); await load();
    } catch (e) {
      setEscError(e.message || 'Unable to submit escalation.');
    } finally {
      escSavingRef.current = false;
      setEscSaving(false);
    }
  }

  function renderNoteModal() {
    if (!noteCtx) return null;
    const claim = noteCtx.claim;
    const values = scopeValues(noteUpdateScope, claim);
    const affected = affectedNoteLines(claim);
    const protectedCount = (claim.lines || []).filter(isProtectedLine).length;
    const docDescription = documentationDescriptions[documentationType] || '';
    const completedValue = actionCompleted === '' ? 'Not set' : actionCompleted === 'true' ? 'Yes' : 'No';
    const pendingPayerAutoOutcome = noteStatus === 'Pending Payer Response' && actionCompleted === 'true' ? pendingPayerOutcomeForLines(affected) : '';
    const actualOutcomeValue = pendingPayerAutoOutcome || actualOutcome;
    const pendingPayerCompletionMissing = noteStatus === 'Pending Payer Response' && actionCompleted === '';
    const pendingPayerCompletionWarning = noteStatus === 'Pending Payer Response' && actionCompleted === 'false';
    return <Modal title={`Update Status - Claim ${claim.claimId}`} className="status-scope-modal" onClose={() => { setNoteError(''); setNoteCtx(null); }}>
      <div className="status-scope-body">
        <div className="status-scope-callout"><strong>Update Scope controls bulk behavior</strong><span>Choose what you are updating, then review the affected open lines before saving.</span></div>
        {noteError ? <div className="esc-inline-error"><i className="bi bi-exclamation-circle" /> {noteError}</div> : null}
        <div className="status-scope-grid">
          <label>Update Scope<select className="wl-full" value={noteUpdateScope} disabled={noteSaving} onChange={e => setScope(e.target.value, claim)}>{noteScopeOptions.map(x => <option key={x}>{x}</option>)}</select></label>
          <label>Scope Value<select className="wl-full" value={noteScopeValue} disabled={noteSaving || noteUpdateScope === 'By Selected Lines'} onChange={e => { setNoteError(''); setNoteScopeValue(e.target.value); }}>{values.map(x => <option key={x} value={x}>{x}</option>)}</select></label>
          <label>New Line Status<select className="wl-full" value={noteStatus} disabled={noteSaving} onChange={e => { setNoteError(''); setNoteStatus(e.target.value); }}>{statusOptions.map(x => <option key={x}>{x}</option>)}</select></label>
          <label>Next Follow-up Date<input type="date" value={noteFollowUpDate} onChange={e => { setNoteError(''); setNoteFollowUpDate(e.target.value); }} disabled={noteSaving} /></label>
          <label>Actual Action / Outcome<select className="wl-full" value={actualOutcomeValue} disabled={noteSaving || !!pendingPayerAutoOutcome} onChange={e => { setNoteError(''); setActualOutcome(e.target.value); }}><option value="">Select outcome</option>{actualOutcomes.map(x => <option key={x}>{x}</option>)}</select>{pendingPayerAutoOutcome ? <span className="doctype-help">Auto-assigned from Action Category for Pending Payer Response.</span> : null}</label>
          <label><span className="field-label-row">Action Completed? {noteStatus === 'Pending Payer Response' ? <span className="required-star">*</span> : null}</span><select className="wl-full" value={actionCompleted} disabled={noteSaving} onChange={e => { setNoteError(''); setActionCompleted(e.target.value); }}><option value="">Select</option><option value="true">Yes</option><option value="false">No</option></select></label>
          {noteStatus === 'Pending Documentation' && <label className="doc-type-field">Documentation Type<select className="wl-full" value={documentationType} disabled={noteSaving} onChange={e => { setNoteError(''); setDocumentationType(e.target.value); }}><option value="">Select type</option>{documentationTypes.map(x => <option key={x}>{x}</option>)}</select>{docDescription ? <span className="doctype-help">{docDescription}</span> : null}</label>}
        </div>
        <label className="status-scope-comments">Clarification / Status Note<textarea className="wl-textarea" maxLength={MAX_TEXT_LENGTH} value={noteText} onChange={e => { setNoteError(''); setNoteText(limitText(e.target.value)); }} placeholder="Enter comments..." disabled={noteSaving} /><div className="text-count">{textCountLabel(noteText)}</div></label>
        {pendingPayerCompletionMissing ? <div className="status-validation-callout"><strong>Action Completed is required</strong><span>Select Yes for Pending Payer Response. The actual outcome will be assigned from the Action Category.</span></div> : null}
        {pendingPayerCompletionWarning ? <div className="status-validation-callout"><strong>Check action completion</strong><span>Pending Payer Response means the action was submitted to the payer. Set Action Completed = Yes before saving.</span></div> : null}
        <div className="status-preview">
          <h4>Affected Line Preview</h4>
          <p><strong>{affected.length}</strong> eligible open line(s) will be updated to <strong>{noteStatus}</strong>. Action Completed will be set to <strong>{completedValue}</strong>.</p>
          <div className="status-preview-chips">{affected.length ? affected.map(l => <span className="status-chip recommended" key={l.taskId || `${l.cptCode}-${l.denialCode}`}>CPT {l.cptCode || '-'} - {l.denialCode || '-'} - Recommended: {l.recommendedAction || 'Not set'}{l.actionCategory ? ` (Previous category: ${l.actionCategory})` : ''}</span>) : <span className="status-chip red">No eligible lines selected</span>}</div>
          {noteUpdateScope === 'By Claim' && protectedCount ? <div className="status-preview-warning">Closed and escalated lines are protected from claim-wide overwrite.</div> : null}
        </div>
        <h4>History</h4>
        <div className="modal-list compact-history">{notes.length ? notes.map(n => <div className="modal-row structured-history-row" key={n.noteId}><StructuredNoteText text={n.noteText} /><div className="modal-row-meta">{n.status ? `Status: ${n.status} - ` : ''}{n.nextFollowUpDate ? `Follow-up: ${fmtDate(n.nextFollowUpDate)} - ` : ''}{n.createdBy} - {fmtDate(n.createdOn)}</div></div>) : <div className="empty-cell">No notes found.</div>}</div>
      </div>
      <div className="note-modal-ft"><span>{affected.length} line(s) ready</span><button className="wl-btn teal" disabled={noteSaving || pendingPayerCompletionMissing || pendingPayerCompletionWarning || !canSaveComments || !affected.length || (clientManager && !(noteCtx.task ? isClientInfoPending(noteCtx.task) : claimHasClientInfoPending(noteCtx.claim)))} onClick={saveNote}>{noteSaving ? 'Saving status...' : 'Save Status Update'}</button></div>
    </Modal>;
  }

  useEffect(() => { if ((clientManager || accountManager) && !['pendingDocumentation', 'externalEscalation', 'closed', 'all'].includes(taskView)) setTaskView('externalEscalation'); }, [accountManager, clientManager, taskView, setTaskView]);

  return <div className="wl-page">
    <div className="wl-kpis"><div><b>{kpi.claims}</b><span>Assigned claims</span></div><div><b>{kpi.tasks}</b><span>Open tasks</span></div><div><b>{money(kpi.balance)}</b><span>Ins. balance</span></div><div><b>{kpi.escalated}</b><span>Escalated</span></div></div>
    {!roleIsReviewerOnly(user?.role) && <div className="wl-card wl-filters"><div className="wl-card-hd"><b>My Worklist Filters</b><button className="wl-btn xs" onClick={() => setLocal({ payerName: '', denialClassification: '', actionCategory: '', status: '', searchText: '' })}>Clear all</button></div><div className="wl-filter-grid">
      <SearchableMultiSelect label="Payer" value={local.payerName} onChange={v => setLocal(x => ({ ...x, payerName: v }))} options={options?.payerNames || []} placeholder="All payers" />
      <SearchableMultiSelect label="Classification" value={local.denialClassification} onChange={v => setLocal(x => ({ ...x, denialClassification: v }))} options={options?.denialClassifications || []} placeholder="All classifications" />
      <SearchableMultiSelect label="Action / Task" value={local.actionCategory} onChange={v => setLocal(x => ({ ...x, actionCategory: v }))} options={options?.actionCategories || []} placeholder="All actions" />
      <SearchableMultiSelect label="Status" value={local.status} onChange={v => setLocal(x => ({ ...x, status: v }))} options={statusOptions} placeholder="All statuses" />
      <label className="span2">Search<input value={local.searchText} onChange={e => setLocal(x => ({ ...x, searchText: e.target.value }))} placeholder="Claim, payer, CPT, task..." /></label>
    </div></div>}
    <WorklistClaimSplit claims={claims} rows={rows} loading={loading} data={data} expanded={expanded} setExpanded={setExpanded} drawerTab={drawerTab} setDrawerTab={setDrawerTab} activeClaim={activeClaim} clientManager={clientManager} accountManager={accountManager} taskView={taskView} setTaskView={setTaskView} myTabs={myTabs} tabCounts={tabCounts} notes={notes} docs={docs} escalations={escalations} canEditClaim={canEditClaim} canEditLine={canEditLine} canCreateEscalation={canCreateEscalation} canDeleteDocumentForClaim={canDeleteDocumentForClaim} openNote={openNote} openDocs={openDocs} openEsc={openEsc} openDocument={openDocument} deleteDocument={deleteDocument} loadDrawerTab={loadDrawerTab} canDownloadWorkflow={canDownloadWorkflow} onDownloadTab={(tab) => onDownloadTab(query, tab)} csvUpload={canUpdateTasks ? <ClaimCsvUpload labId={labId} setMessage={setMessage} onUploaded={async () => { await load(); onSaved?.(); }} onDownloadTemplate={() => onDownloadTemplate(query, myTabs.find(x => x.key === taskView))} templateBusy={exportBusy} /> : null} exportBusy={exportBusy} exportStatusText={exportStatusText} />
    <div className="wl-card my-worklist-old-table"><div className="wl-card-hd"><b>{clientManager ? 'Client Manager' : accountManager ? 'Account Manager' : 'AR Reviewer'} · My Worklist · {myTabs.find(x => x.key === taskView)?.label}</b><span>{loading ? 'Loading...' : `${data.totalCount || rows.length} task(s)`}</span></div><div className="wl-table-scroll"><table className="wl-main-table"><thead><tr><th></th><th>Claim ID</th><th>Payer</th><th>Panel</th><th>Patient ID</th><th>DOS</th><th>Created On</th><th>Clinic</th><th>Provider</th><th>Assigned To</th><th>Balance</th><th>Claim Notes</th><th>Docs</th><th>Escalate</th><th>Status</th></tr></thead><tbody>{claims.map(c => <React.Fragment key={c.claimId}><tr className={expanded === c.claimId ? 'open' : ''} onClick={() => setExpanded(expanded === c.claimId ? '' : c.claimId)}><td><i className={`bi ${expanded === c.claimId ? 'bi-chevron-down' : 'bi-chevron-right'}`} /></td><td className="linkish">{c.claimId}</td><td>{c.payerName}</td><td>{c.panelName}</td><td>{c.patientId}</td><td>{fmtDate(c.dateOfService)}</td><td>{fmtDate(c.createdOn)}</td><td>{c.clinicName}</td><td>{c.referringProvider}</td><td>{c.assignedTo || '-'}</td><td className="money">{money(c.balance)}</td><td><button className="wl-icon icon-note" disabled={!canEditClaim(c)} onClick={e => { e.stopPropagation(); openNote('Claim', c); }}><i className="bi bi-pencil-square" /></button></td><td><button className="wl-icon icon-doc" disabled={!canEditClaim(c)} onClick={e => { e.stopPropagation(); openDocs(c); }}><i className="bi bi-paperclip" /></button></td><td>{canCreateEscalation ? <button className="wl-btn red xs" onClick={e => { e.stopPropagation(); openEsc('Claim', c); }}>Escalate</button> : <span className="muted-text">View only</span>}</td><td><span className={`wl-badge ${String(c.status).toLowerCase().replaceAll(' ', '-')}`}>{c.status}</span></td></tr>{expanded === c.claimId && <tr><td colSpan="15" className="wl-detail-cell"><div className="wl-detail-title">CPT / line-level task details</div><div className="wl-line-scroll"><table className="wl-line-table"><thead><tr><th>Task ID</th><th>CPT</th><th>Units</th><th>Modifier</th><th>Denial</th><th>Coverage</th><th>ICD Status</th><th>Classification</th><th>Validity</th><th>Balance</th><th>Action / Task</th><th>SLA</th><th>Assigned To</th><th>Status</th><th>Created On</th><th>Notes</th><th>Escalate</th></tr></thead><tbody>{c.lines.map(l => <tr key={l.taskId}><td><b>{l.taskId}</b></td><td>{l.cptCode}</td><td>{l.units ?? '-'}</td><td>{l.modifier || '-'}</td><td>{l.denialCode}</td><td>{l.coverageStatus || '-'}</td><td>{l.icdComplianceStatus || '-'}</td><td>{l.denialClassification}</td><td>{l.denialValidity || '-'}</td><td className="money">{money(l.insuranceBalance)}</td><td>{l.task || l.recommendedAction}</td><td>{l.daysRemaining ?? '-'}</td><td>{l.assignedTo || '-'}</td><td><span className={`wl-badge ${String(l.status).toLowerCase().replaceAll(' ', '-')}`}>{l.status || 'Open'}</span></td><td>{fmtDate(l.createdOn)}</td><td><button className="wl-icon icon-note" disabled={!canEditLine(l)} onClick={() => openNote('Line', c, l)}><i className="bi bi-pencil-square" /></button></td><td>{canCreateEscalation ? <button className="wl-btn red xs" onClick={() => openEsc('Line', c, l)}>Escalate</button> : <span className="muted-text">View only</span>}</td></tr>)}</tbody></table></div></td></tr>}</React.Fragment>)}</tbody></table></div></div>
    <Pager data={data} changePage={changePage} />

    {renderNoteModal()}
    {docCtx && <Modal title={`Claim Documents · ${docCtx.claimId}`} onClose={() => { setDocError(''); setDocCtx(null); }}><div className="wl-modal-body">{docError ? <div className="esc-inline-error"><i className="bi bi-exclamation-circle" /> {docError}</div> : null}<label>Denial Code - CPT Code<select className="wl-full" value={docLineTarget} onChange={e => { setDocError(''); setDocLineTarget(e.target.value); }} disabled={docUploading}><option value="">Overall claim</option>{lineOptions(docCtx).map(x => <option key={x.key} value={x.key}>{x.label}</option>)}</select></label><input type="file" multiple onChange={e => { setDocError(''); setDocFiles(e.target.files); }} disabled={docUploading} /><div><textarea className="wl-textarea" maxLength={MAX_TEXT_LENGTH} value={docComment} onChange={e => { setDocError(''); setDocComment(limitText(e.target.value)); }} placeholder="Document comment..." disabled={docUploading} /><div className="text-count">{textCountLabel(docComment)}</div></div><button className="wl-btn teal" disabled={docUploading || !canUploadDocuments || (clientManager && !claimHasClientInfoPending(docCtx))} onClick={uploadDocs}>{docUploading ? 'Uploading documents...' : 'Upload documents'}</button><h4>Uploaded documents</h4>{docs.map(d => <div className="wl-history" key={d.documentId}><b>{d.originalFileName}</b><div>{d.comment}</div><small>{d.uploadedBy} · {fmtDate(d.uploadedOn)} · {Math.round(Number(d.fileSizeBytes || 0) / 1024)} KB</small><div className="doc-row-actions"><button className="wl-btn xs" type="button" onClick={() => openDocument(d.documentId)}>Download</button>{canDeleteDocumentForClaim(docCtx) && <button className="wl-btn red xs" type="button" onClick={() => deleteDocument(d.documentId, docCtx.claimId)}>Delete</button>}</div></div>)}</div></Modal>}
    {escCtx && <Modal title={`Escalate Claim ${escCtx.claim.claimId} to AR Manager`} className="wl-escalation-modal" onClose={() => { setEscError(''); setEscCtx(null); }}>
      <div className="wl-inline-escalation-body wl-modal-escalation-body">
        <div className="wl-inline-escalation-form">{escError ? <div className="esc-inline-error"><i className="bi bi-exclamation-circle" /> {escError}</div> : null}{!reviewerEscalationClaimOnly && <label>Escalation Applies To<select className="wl-full" value={escAppliesTo} disabled={escSaving} onChange={e => { setEscError(''); setEscAppliesTo(e.target.value); setEscScopeValue(''); }}>{escalationAppliesToOptions.map(x => <option key={x}>{x}</option>)}</select></label>}{!reviewerEscalationClaimOnly && escAppliesTo === 'Specific CPT' && <label>Specific CPT<select className="wl-full" value={escScopeValue} disabled={escSaving} onChange={e => { setEscError(''); setEscScopeValue(e.target.value); }}><option value="">Select CPT + Denial Code + Action</option>{(escCtx.claim.lines || []).map((l, i) => <option key={`${l.taskId || i}`} value={l.taskId || l.cptCode}>{l.cptCode || '-'} - {l.denialCode || '-'} - {l.actionCategory || l.task || l.recommendedAction || '-'}</option>)}</select></label>}{!reviewerEscalationClaimOnly && escAppliesTo === 'Action Group' && <label>Action Group<select className="wl-full" value={escScopeValue} disabled={escSaving} onChange={e => { setEscError(''); setEscScopeValue(e.target.value); }}><option value="">Select action group</option>{Array.from(new Set((escCtx.claim.lines || []).map(l => l.actionCategory).filter(Boolean))).map(x => <option key={x}>{x}</option>)}</select></label>}{!reviewerEscalationClaimOnly && escAppliesTo === 'Denial Classification' && <label>Denial Classification<select className="wl-full" value={escScopeValue} disabled={escSaving} onChange={e => { setEscError(''); setEscScopeValue(e.target.value); }}><option value="">Select classification</option>{Array.from(new Set((escCtx.claim.lines || []).map(l => l.denialClassification).filter(Boolean))).map(x => <option key={x}>{x}</option>)}</select></label>}{showEscalationReason && <><label>Escalation Reason<select className="wl-full" value={escReason} disabled={escSaving} onChange={e => { setEscError(''); setEscReason(e.target.value); }}>{escalationReasons.map(x => <option key={x}>{x}</option>)}</select></label>{escReason === 'Other' && <label>Other reason<input className="wl-full" value={escOtherReason} disabled={escSaving} onChange={e => { setEscError(''); setEscOtherReason(e.target.value); }} placeholder="Enter other escalation reason..." /></label>}</>}<label>Clarification / Escalation Note<textarea className="wl-textarea" maxLength={MAX_TEXT_LENGTH} value={escComment} disabled={escSaving} onChange={e => { setEscError(''); setEscComment(limitText(e.target.value)); }} placeholder="Explain what manager has to review..." /><div className="text-count">{textCountLabel(escComment)}</div></label><label>Expected Response<input className="wl-full" type="date" value={escFollowUpDate} disabled={escSaving} onChange={e => { setEscError(''); setEscFollowUpDate(e.target.value); }} /></label><label>Attachment <span className="muted-text">(Optional)</span><input className="wl-full" type="file" multiple disabled={escSaving} onChange={e => { setEscError(''); setEscFiles(Array.from(e.target.files || [])); }} /></label>{escFiles.length ? <div className="info-strip">{escFiles.length} attachment(s) selected.</div> : null}<button className="wl-btn red" disabled={escSaving || (showEscalationReason && escReason === 'Other' && !escOtherReason.trim())} onClick={saveEscalation}>{escSaving ? 'Submitting...' : 'Submit to AR Manager'}</button></div>
        <div className="wl-inline-escalation-history"><h4>Escalation history</h4>{escalations.length ? escalations.map(x => <div className="wl-history" key={x.escalationId}><b>{x.escalationReason}</b><div>{x.comments}</div><small>{x.status} · {x.nextFollowUpDate ? `Follow-up: ${fmtDate(x.nextFollowUpDate)} · ` : ''}{x.createdBy} · {fmtDate(x.createdOn)}</small></div>) : <div className="empty-cell">No escalation history found.</div>}</div>
      </div>
    </Modal>}
  </div>;
}

