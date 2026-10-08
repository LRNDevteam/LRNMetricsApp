// Column key -> the API's sort key, per endpoint, for columns that have no sortKey of their own
// (applied with DataTable's withSortKeys). Each value must be in that endpoint's server-side
// whitelist, so a sort always orders every page of results, not only the rows on screen.

// GET claims - SqlArWorkbenchRepository.SortColumns (Work Queue, My Work, Follow-Up, Assignment)
export const CLAIM_SORT_KEYS = {
  labName: 'labName', cpt: 'cpt', denialCode: 'denialCode', denialReason: 'denialReason', sourceClaimStatus: 'sourceClaimStatus',
  isTflRisk: 'isTflRisk', assignedAgentName: 'assignedAgent', queue: 'queue', fixResolution: 'fixResolution',
  insuranceBalance: 'insuranceBalance', daysSinceLastTouch: 'daysSinceLastTouch', patientID: 'patientId', dateOfService: 'dateOfService',
  remainingAR: 'remainingAR', revenueExpectation: 'revenueExpectation', recoveredAmount: 'recoveredAmount'
};

// GET qa - QaSortColumns
export const QA_SORT_KEYS = {
  labName: 'labName', insuranceBalance: 'insuranceBalance', note: 'note', escalation: 'escalation', errorType: 'errorType', panelName: 'panelName'
};

// GET cip / client-cip - CipSortColumns
export const CIP_SORT_KEYS = {
  claimID: 'claimId', caseNumber: 'caseNumber', patientID: 'patientId', dateOfService: 'dateOfService', labName: 'labName',
  payerName: 'payerName', caseStatus: 'caseStatus', cipCategory: 'cipCategory', requiredInfo: 'requiredInfo', cipComment: 'cipComment',
  feedback: 'feedback', insuranceBalance: 'insuranceBalance', arQueueLabel: 'arQueue', requestedBy: 'requestedBy', requestedOn: 'requestedOn'
};

// GET audit - AuditSortColumns
export const AUDIT_SORT_KEYS = { roleCode: 'roleCode', previousValue: 'previousValue', newValue: 'newValue', detail: 'detail' };
