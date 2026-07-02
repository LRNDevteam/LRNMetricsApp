import { api, apiUrl, qs } from './httpClient';

function normalizePagedResult(result) {
  const raw = result || {};
  const items = raw.items ?? raw.Items ?? raw.data ?? raw.Data ?? [];
  const totalCount = Number((raw.totalCount ?? raw.TotalCount ?? raw.totalRecords ?? raw.TotalRecords ?? items.length) || 0);
  const totalPages = Number((raw.totalPages ?? raw.TotalPages ?? raw.pageCount ?? raw.PageCount ?? raw.totalPageCount ?? raw.TotalPageCount ?? raw.pages ?? raw.Pages) || 0);
  const page = Number(raw.page ?? raw.pageNumber ?? raw.PageNumber ?? raw.pageIndex ?? raw.PageIndex ?? raw.currentPage ?? raw.CurrentPage ?? 1);
  return { ...raw, items, totalCount, totalPages, page };
}

export const denialWorkflowService = {
  getMe: () => api('/me'),
  getSupportContacts: () => api('/support-contacts'),
  submitSupportRequest: (payload) => api('/support-request', { method: 'POST', body: JSON.stringify(payload) }),
  getLabs: () => api('/labs'),
  getReviewers: (labId) => api(`/reviewers?labId=${encodeURIComponent(labId)}`),
  getLastRunReference: (labId) => api(`/last-run-reference?labId=${encodeURIComponent(labId)}`),
  getFilterOptions: (labId) => api(`/filter-options?labId=${encodeURIComponent(labId)}`),
  getDashboard: (query) => api(`/dashboard?${qs(query)}`),
  getAgingDashboard: (query) => api(`/aging-dashboard?${qs(query)}`),
  getInsights: (query) => api(`/insights?${qs(query)}`),
  getClaims: async (query, options = {}) => normalizePagedResult(await api(`/claims?${qs(query)}`, options)),
  startClaimsExport: (query) => api('/claims/export', { method: 'POST', body: JSON.stringify(query || {}) }),
  getClaimsExportStatus: (jobId) => api(`/claims/export/${encodeURIComponent(jobId)}`),
  cancelClaimsExport: (jobId) => api(`/claims/export/${encodeURIComponent(jobId)}`, { method: 'DELETE' }),
  getClaimsExportDownloadUrl: (jobId) => apiUrl(`/claims/export/${encodeURIComponent(jobId)}/download`),
  uploadClaimsCsv: (labId, file) => {
    const form = new FormData();
    form.append('labId', labId);
    form.append('file', file);
    return api('/claims/upload-csv', { method: 'POST', body: form });
  },
  getTasks: async (query, options = {}) => normalizePagedResult(await api(`/tasks?${qs(query)}`, options)),
  getVerification: async (query, options = {}) => normalizePagedResult(await api(`/verification?${qs(query)}`, options)),
  getClaimTasks: (labId, claimId, taskView = '') => api(`/claims/${encodeURIComponent(claimId)}/tasks?${qs({ labId, taskView })}`),
  getClaimMenuCounts: (query) => api(`/claim-menu-counts?${qs(query)}`),
  assignInsight: (payload) => api('/assign-insight', { method: 'POST', body: JSON.stringify(payload) }),
  assignClaims: (payload) => api('/assign-claims', { method: 'POST', body: JSON.stringify(payload) }),
  updateTask: (payload) => api('/update-task', { method: 'POST', body: JSON.stringify(payload) }),
  getNotes: (query) => api(`/notes?${qs(query)}`),
  saveNote: (payload) => api('/notes', { method: 'POST', body: JSON.stringify(payload) }),
  getFollowUpNotifications: (labId) => api(`/follow-up-notifications?labId=${encodeURIComponent(labId)}`),
  getClaimDocuments: (labId, claimId) => api(`/claim-documents?labId=${encodeURIComponent(labId)}&claimId=${encodeURIComponent(claimId)}`),
  getClaimDocumentDownloadUrl: (labId, documentId) => apiUrl(`/claim-documents/${encodeURIComponent(documentId)}/download?labId=${encodeURIComponent(labId)}`),
  deleteClaimDocument: (labId, documentId) => api(`/claim-documents/${encodeURIComponent(documentId)}?labId=${encodeURIComponent(labId)}`, { method: 'DELETE' }),
  getClaimHistory: (query) => api(`/claim-history?${qs(query)}`),
  getEscalations: (query) => api(`/escalations?${qs(query)}`),
  getEscalationQueue: async (query, escalationLevel = 'Claim', options = {}) => normalizePagedResult(await api(`/escalation-queue?${qs({ ...(query || {}), escalationLevel })}`, options)),
  resolveEscalation: (payload) => api('/resolve-escalation', { method: 'POST', body: JSON.stringify(payload) }),
  saveEscalation: (payload) => api('/escalations', { method: 'POST', body: JSON.stringify(payload) }),
  updateEscalation: (payload) => api('/update-escalation', { method: 'POST', body: JSON.stringify(payload) }),
  uploadClaimDocuments: async (labId, claimId, comment, uploadedBy, files) => {
    const form = new FormData();
    form.append('labId', labId);
    form.append('claimId', claimId);
    form.append('comment', comment || '');
    form.append('uploadedBy', uploadedBy || 'ReactWorkflow');
    Array.from(files || []).forEach(f => form.append('files', f));

    return api('/claim-documents', { method: 'POST', body: form });
  },
  getDenialCodeMaster: async (query) => normalizePagedResult(await api(`/denial-code-master?${qs(query)}`)),
  getDenialCodeMasterLookups: (labId) => api(`/denial-code-master/lookups?labId=${encodeURIComponent(labId)}`),
  createDenialCodeMaster: (labId, payload) => api(`/denial-code-master?labId=${encodeURIComponent(labId)}`, { method: 'POST', body: JSON.stringify(payload) }),
  updateDenialCodeMaster: (labId, originalKey, payload) => api(`/denial-code-master/${encodeURIComponent(originalKey.denialCode)}?${qs({ labId, coverageStatus: originalKey.coverageStatus, icdComplianceStatus: originalKey.icdComplianceStatus })}`, { method: 'PUT', body: JSON.stringify(payload) }),
  getDenialCodeMasterImpact: (labId, denialCode) => api(`/denial-code-master/${encodeURIComponent(denialCode)}/impact?labId=${encodeURIComponent(labId)}`),
  deleteDenialCodeMaster: (labId, originalKey) => api(`/denial-code-master/${encodeURIComponent(originalKey.denialCode)}?${qs({ labId, coverageStatus: originalKey.coverageStatus, icdComplianceStatus: originalKey.icdComplianceStatus })}`, { method: 'DELETE' }),
  importDenialCodeMaster: (labId, file) => {
    const form = new FormData();
    form.append('file', file);
    return api(`/denial-code-master/import?labId=${encodeURIComponent(labId)}`, { method: 'POST', body: form });
  },
  regenerateDenialCodeMasterExcel: (labId) => api(`/denial-code-master/regenerate-export?labId=${encodeURIComponent(labId)}`, { method: 'POST' }),
  getDenialCodeMasterExportUrl: (labId) => apiUrl(`/denial-code-master/export?labId=${encodeURIComponent(labId)}`),
  getDenialActionVerification: async (query) => normalizePagedResult(await api(`/denial-action-verification?${qs(query)}`)),
  getDenialActionVerificationBatch: (labId, batchId) => api(`/denial-action-verification/batch/${encodeURIComponent(batchId)}?labId=${encodeURIComponent(labId)}`),
  getDenialActionVerificationLookups: (labId) => api(`/denial-action-verification/lookups?labId=${encodeURIComponent(labId)}`),
  confirmDenialActionVerification: (labId, verificationId) => api(`/denial-action-verification/${encodeURIComponent(verificationId)}/confirm?labId=${encodeURIComponent(labId)}`, { method: 'POST' }),
  confirmSelectedDenialActionVerification: (labId, verificationIds) => api(`/denial-action-verification/confirm-selected?labId=${encodeURIComponent(labId)}`, { method: 'POST', body: JSON.stringify(verificationIds || []) }),
  confirmAllDenialActionVerification: (labId, batchId) => api(`/denial-action-verification/batch/${encodeURIComponent(batchId)}/confirm-all?labId=${encodeURIComponent(labId)}`, { method: 'POST' }),
  ignoreDenialActionVerification: (labId, verificationId) => api(`/denial-action-verification/${encodeURIComponent(verificationId)}/ignore?labId=${encodeURIComponent(labId)}`, { method: 'POST' }),
  getDenialActionVerificationExportUrl: (query) => apiUrl(`/denial-action-verification/export?${qs(query)}`)
  ,getDenialMapperDashboard: (labId) => api(`/denial-mapper/dashboard?${qs({ labId })}`)
  ,getDenialMapperMasterData: () => api('/denial-mapper/master-data')
  ,getDenialMapperSuper: async (query) => normalizePagedResult(await api(`/denial-mapper/super-master?${qs(query)}`))
  ,createDenialMapperSuper: (payload) => api('/denial-mapper/super-master', { method: 'POST', body: JSON.stringify(payload) })
  ,updateDenialMapperSuper: (id, payload) => api(`/denial-mapper/super-master/${id}`, { method: 'PUT', body: JSON.stringify(payload) })
  ,deleteDenialMapperSuper: (id) => api(`/denial-mapper/super-master/${id}`, { method: 'DELETE' })
  ,getDenialMapperLabs: () => api('/denial-mapper/labs')
  ,compareDenialMapperPush: (labIds) => api('/denial-mapper/compare-push', { method: 'POST', body: JSON.stringify({ labIds }) })
  ,confirmDenialMapperPush: (pushAuditIds) => api('/denial-mapper/confirm-push', { method: 'POST', body: JSON.stringify({ pushAuditIds }) })
  ,cancelDenialMapperPush: (pushAuditIds) => api('/denial-mapper/cancel-push', { method: 'POST', body: JSON.stringify({ pushAuditIds }) })
  ,getDenialMapperPushVerification: (pushAuditId) => api(`/denial-mapper/push-verification/${pushAuditId}`)
  ,updateDenialMapperPushVerificationDetail: (pushAuditId, detailId, payload) => api(`/denial-mapper/push-verification/${pushAuditId}/details/${detailId}`, { method: 'PUT', body: JSON.stringify(payload) })
  ,getDenialMapperPushVerificationExportUrl: (pushAuditId) => apiUrl(`/denial-mapper/push-verification/${pushAuditId}/export`)
  ,getDenialMapperNotifications: (labId) => api(`/denial-mapper/notifications?labId=${encodeURIComponent(labId)}`)
  ,acknowledgeDenialMapperNotification: (pushAuditId, labId) => api(`/denial-mapper/notifications/${pushAuditId}/acknowledge?labId=${encodeURIComponent(labId)}`, { method: 'POST' })
  ,getDenialMapperLab: async (labId, query) => normalizePagedResult(await api(`/denial-mapper/lab-master?${qs({ ...query, labId })}`))
  ,saveDenialMapperOverride: (labId, id, payload) => api(`/denial-mapper/lab-master/${id}/override?labId=${labId}`, { method: 'PUT', body: JSON.stringify(payload) })
  ,removeDenialMapperOverride: (labId, id) => api(`/denial-mapper/lab-master/${id}/override?labId=${labId}`, { method: 'DELETE' })
  ,getDenialMapperAudit: (labId) => api(`/denial-mapper/audit?${qs({ labId, take: 200 })}`)
  ,getDenialMapperClassifications: (labId) => api(`/denial-mapper/classifications?${qs({ labId })}`)
  ,uploadDenialMapper: (file) => { const form = new FormData(); form.append('file', file); return api('/denial-mapper/upload', { method: 'POST', body: form }); }
};

export { qs };
