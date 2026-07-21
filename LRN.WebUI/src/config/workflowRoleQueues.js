import { canAssignRole, isAccountManagerRole, isArReviewerRole, isClientManagerRole } from '../utils/formatters';

const commonManagerFilters = ['reviewer', 'aging', 'denialClassification', 'actionCategory', 'payerName', 'panelName', 'clinic', 'salesRepname'];
const externalManagerQueues = [
  { key: 'new', label: 'New', filters: commonManagerFilters },
  { key: 'unassigned', label: 'Unassigned', filters: [...commonManagerFilters, 'balanceBucket'] },
  { key: 'assigned', label: 'Assigned', filters: commonManagerFilters },
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
    { key: 'escalationResponse', label: 'Escalation Response', filters: [...commonManagerFilters, 'documentationType', 'escalationReason'] },
    { key: 'writeOffApproval', label: 'Write Off Approval', filters: commonManagerFilters },
    { key: 'closed', label: 'Closed', filters: commonManagerFilters },
    { key: 'all', label: 'All Claims', filters: ['status', 'reviewer', 'aging', 'denialClassification', 'actionCategory', 'payerName', 'panelName'] }
  ],
  accountManager: externalManagerQueues,
  clientManager: externalManagerQueues
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
