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
  listExportJobs: () => api('/claims/export'),
  getClaimsExportStatus: (jobId) => api(`/claims/export/${encodeURIComponent(jobId)}`),
  cancelClaimsExport: (jobId) => api(`/claims/export/${encodeURIComponent(jobId)}`, { method: 'DELETE' }),
  getClaimsExportDownloadUrl: (jobId) => apiUrl(`/claims/export/${encodeURIComponent(jobId)}/download`),
  // Enqueue a bulk upload — returns { jobId, status, message, totalRows } immediately (202); the
  // server processes it in the background so the user is no longer held on the page.
  enqueueClaimsUpload: (labId, file) => {
    const form = new FormData();
    form.append('labId', labId);
    form.append('file', file);
    return api('/claims/upload-csv', { method: 'POST', body: form });
  },
  getUploadStatus: (jobId) => api(`/claims/upload/${encodeURIComponent(jobId)}`),
  listUploadJobs: () => api('/claims/upload'),
  cancelUpload: (jobId) => api(`/claims/upload/${encodeURIComponent(jobId)}`, { method: 'DELETE' }),
  getUploadLogUrl: (jobId) => apiUrl(`/claims/upload/${encodeURIComponent(jobId)}/log`),
  // Back-compat wrapper: enqueue then poll to completion and resolve with the per-row result,
  // so existing callers keep working while the request thread is no longer blocked server-side.
  uploadClaimsCsv: async (labId, file, { onProgress } = {}) => {
    const start = await denialWorkflowService.enqueueClaimsUpload(labId, file);
    const jobId = start?.jobId;
    if (!jobId) return start;
    const deadline = Date.now() + 30 * 60 * 1000;
    for (;;) {
      await new Promise(r => setTimeout(r, 2000));
      const status = await denialWorkflowService.getUploadStatus(jobId);
      if (onProgress) onProgress(status);
      const s = String(status?.status || '').toLowerCase();
      if (s === 'completed') return status.result || { message: status.message, jobId };
      if (s === 'failed') throw new Error(status.message || 'Upload failed.');
      if (Date.now() > deadline) throw new Error('Upload is still processing — check the Uploads list shortly.');
    }
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
  getDenialCodeMasterTemplateUrl: () => apiUrl('/denial-code-master/template'),
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
  // Async "Push to Labs" — two backgrounded steps, each returns a jobId (202); poll the job for
  // completion so the admin is never blocked. Step 1 compares (creates pending pushes); step 2
  // confirms/distributes a pending push (deferrable, run from Push Status).
  ,startDenialMapperCompare: (labIds) => api('/denial-mapper/push/compare', { method: 'POST', body: JSON.stringify({ labIds }) })
  ,startDenialMapperConfirm: (pushAuditIds) => api('/denial-mapper/push/confirm', { method: 'POST', body: JSON.stringify({ pushAuditIds }) })
  ,getDenialMapperPushJob: (jobId) => api(`/denial-mapper/push/jobs/${encodeURIComponent(jobId)}`)
  ,listDenialMapperPushJobs: () => api('/denial-mapper/push/jobs')
  ,listDenialMapperPushes: (take = 100) => api(`/denial-mapper/confirm-push/list?take=${take}`)
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
