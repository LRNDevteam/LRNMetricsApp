import { canAssignRole, isAccountManagerRole, isArReviewerRole, isClientManagerRole, isLabUserRole } from '../utils/formatters';

const commonManagerFilters = ['reviewer', 'aging', 'denialClassification', 'actionCategory', 'payerName', 'panelName', 'clinic', 'salesRepname'];
// Client / Account Manager: the SAME claim + line view as the AR Manager (read-only), plus the
// "Respond Escalation" tab (external escalations routed to them, which they respond to). Rendered
// inline in the unified ClaimAssignmentPage, not the separate escalation page. There is no
// "External Response" tab for them -- once they respond, the claim leaves their queue and moves to
// the AR Manager's Assigned / External Response.
const externalManagerQueues = [
  { key: 'new', label: 'New', filters: commonManagerFilters },
  { key: 'unassigned', label: 'Unassigned', filters: [...commonManagerFilters, 'balanceBucket'] },
  { key: 'assigned', label: 'Assigned', filters: commonManagerFilters },
  { key: 'externalEscalation', label: 'Respond Escalation', filters: [...commonManagerFilters, 'documentationType', 'escalationReason'], alert: true },
  { key: 'closed', label: 'Closed', filters: commonManagerFilters },
  { key: 'all', label: 'All Claims', filters: ['status', 'reviewer', 'aging', 'denialClassification', 'actionCategory', 'payerName', 'panelName'] }
];

export const workflowQueueConfig = {
  arReviewer: [
    { key: 'assigned', label: 'Worklist', filters: ['status', 'aging', 'denialClassification', 'actionCategory', 'payerName', 'panelName', 'followupDue'] },
    { key: 'slaAtRisk', label: 'SLA in 3 Days', filters: ['aging', 'denialClassification', 'actionCategory', 'payerName', 'panelName'], alert: true },
    { key: 'followupDue', label: 'Follow-ups Due', filters: ['payerName', 'panelName', 'actionCategory'], alert: true },
    { key: 'payerFollowup', label: 'Payer Follow-up Required', filters: ['followUpReason', 'aging', 'payerName', 'panelName', 'followupDue'] },
    { key: 'pendingDocumentation', label: 'Pending Documentation', filters: [...commonManagerFilters, 'documentationType'] },
    { key: 'pendingPayerResponse', label: 'Pending Payer Response', filters: ['aging', 'nextFollowUpDate', 'payerName', 'actionCategory'] },
    { key: 'internalEscalation', label: 'Escalated Claims', filters: [...commonManagerFilters, 'escalationReason'] },
    { key: 'escalationResponse', label: 'Escalation Response', filters: [...commonManagerFilters, 'documentationType', 'escalationReason'] },
    { key: 'closed', label: 'Closed', filters: commonManagerFilters },
    { key: 'all', label: 'All Claims', filters: ['status', 'aging', 'denialClassification', 'actionCategory', 'payerName', 'panelName'] }
  ],
  arManager: [
    { key: 'new', label: 'New', filters: commonManagerFilters },
    { key: 'unassigned', label: 'Unassigned', filters: [...commonManagerFilters, 'balanceBucket'] },
    { key: 'slaAtRisk', label: 'SLA At Risk', filters: commonManagerFilters, alert: true },
    { key: 'assigned', label: 'Assigned', filters: commonManagerFilters.filter(x => x !== 'reviewer') },
    { key: 'payerFollowup', label: 'Payer Follow-up Required', filters: commonManagerFilters },
    { key: 'pendingDocumentation', label: 'Pending Documentation', filters: [...commonManagerFilters, 'documentationType', 'reviewer', 'expectedResponseBy'] },
    { key: 'pendingPayerResponse', label: 'Pending Payer Response', filters: [...commonManagerFilters, 'reviewer', 'nextFollowUpDate'] },
    { key: 'internalEscalation', label: 'Internal Escalation', filters: [...commonManagerFilters, 'documentationType', 'escalationReason'] },
    { key: 'externalEscalation', label: 'External Escalation', filters: [...commonManagerFilters, 'documentationType', 'escalationReason'] },
    // AR Manager no longer has an "Escalation Response" tab: when an INTERNAL escalation is
    // responded to, the claim returns to the manager's "Assigned" queue (and the AR Reviewer sees
    // it under their "Escalation Response"). The manager's response tab is now "External Response",
    // holding the Client/Account Manager responses only.
    { key: 'externalResponse', label: 'External Response', filters: [...commonManagerFilters, 'documentationType', 'escalationReason'] },
    { key: 'writeOffApproval', label: 'Write Off Approval', filters: commonManagerFilters },
    { key: 'closed', label: 'Closed', filters: commonManagerFilters },
    { key: 'all', label: 'All Claims', filters: ['status', 'reviewer', 'aging', 'denialClassification', 'actionCategory', 'payerName', 'panelName'] }
  ],
  accountManager: externalManagerQueues,
  clientManager: externalManagerQueues,
  // Lab User: the external-manager claim queues minus "Respond Escalation" -- they never act
  // on an escalation, so they get no escalation queue at all. Pure read: the API refuses every
  // write for this role, and the claim view renders without its action controls.
  labUser: externalManagerQueues.filter(q => q.key !== 'externalEscalation')
};

export function normalizeQueueKey(key) {
  const value = String(key || '').trim().toLowerCase().replace(/[\s_-]+/g, '');
  return {
    payerfollowup: 'payerFollowup',
    open: 'assigned',
    myopen: 'assigned',
    pendingdocumentation: 'pendingDocumentation',
    documentation: 'pendingDocumentation',
    documentationqueue: 'pendingDocumentation',
    pendingpayerresponse: 'pendingPayerResponse',
    payerresponse: 'pendingPayerResponse',
    followupdue: 'followupDue',
    followupsdue: 'followupDue',
    internalescalation: 'internalEscalation',
    externalescalation: 'externalEscalation',
    escalationresponse: 'escalationResponse',
    response: 'escalationResponse',
    externalresponse: 'externalResponse',
    writeoffapproval: 'writeOffApproval',
    writeoff: 'writeOffApproval',
    slaatrisk: 'slaAtRisk',
    atrisk: 'slaAtRisk',
    allclaims: 'all'
  }[value] || value || 'assigned';
}

export function getWorkflowRoleKey(role) {
  if (isClientManagerRole(role)) return 'clientManager';
  if (isAccountManagerRole(role)) return 'accountManager';
  // Before the arReviewer fallback: without this a Lab User would land on the reviewer
  // worklist, which is both the wrong data scope and a queue set built around editing.
  if (isLabUserRole(role)) return 'labUser';
  if (isArReviewerRole(role)) return 'arReviewer';
  if (canAssignRole(role)) return 'arManager';
  return 'arReviewer';
}

export function getQueuesForRole(role) {
  return workflowQueueConfig[getWorkflowRoleKey(role)] || workflowQueueConfig.arReviewer;
}

export function getFiltersForRoleQueue(role, queueKey) {
  const normalized = normalizeQueueKey(queueKey);
  return getQueuesForRole(role).find(q => q.key === normalized)?.filters || [];
}

export function clearHiddenWorkflowFilters(filter, visibleFilters = []) {
  const visible = new Set([...(visibleFilters || []), 'searchText', 'page']);
  return Object.fromEntries(Object.entries(filter || {}).map(([key, value]) => [key, visible.has(key) ? value : '']));
}
