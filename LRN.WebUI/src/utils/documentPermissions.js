export function isClosedWorkflowStatus(value) {
  const text = String(value || '').trim().toLowerCase();
  return text === 'closed' || text === 'completed' || text === 'closed claim';
}

export function isEscalationResponseStage(value) {
  const text = String(value || '').trim().toLowerCase();
  return text === 'response'
    || text === 'escalationresponse'
    || text === 'escalated response'
    || text === 'response escalation'
    || text === 'manager response'
    || text === 'response submitted'
    || text === 'responded'
    || text === 'in review'
    || text.includes('escalated response')
    || text.includes('response escalation');
}

export function canDeleteClaimDocument(context, options = {}) {
  if (options.busy || options.uploading) return false;
  if (options.canEdit === false || options.canUpload === false) return false;
  if (isClosedWorkflowStatus(context?.status) || isClosedWorkflowStatus(context?.workflowStatus) || isClosedWorkflowStatus(context?.workFlowStatus)) return false;
  if (isEscalationResponseStage(context?.status) || isEscalationResponseStage(context?.workflowStatus) || isEscalationResponseStage(context?.workFlowStatus)) return false;
  if (isEscalationResponseStage(options.taskView) || isClosedWorkflowStatus(options.taskView)) return false;
  return true;
}
