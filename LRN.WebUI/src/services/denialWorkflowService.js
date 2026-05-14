import { api, qs } from './httpClient';

export const denialWorkflowService = {
  getMe: () => api('/me'),
  getLabs: () => api('/labs'),
  getReviewers: (labId) => api(`/reviewers?labId=${encodeURIComponent(labId)}`),
  getFilterOptions: (labId) => api(`/filter-options?labId=${encodeURIComponent(labId)}`),
  getDashboard: (query) => api(`/dashboard?${qs(query)}`),
  getInsights: (query) => api(`/insights?${qs(query)}`),
  getClaims: (query) => api(`/claims?${qs(query)}`),
  getTasks: (query) => api(`/tasks?${qs(query)}`),
  getVerification: (query) => api(`/verification?${qs(query)}`),
  getClaimTasks: (labId, claimId) => api(`/claims/${encodeURIComponent(claimId)}/tasks?labId=${encodeURIComponent(labId)}`),
  assignInsight: (payload) => api('/assign-insight', { method: 'POST', body: JSON.stringify(payload) }),
  assignClaims: (payload) => api('/assign-claims', { method: 'POST', body: JSON.stringify(payload) }),
  updateTask: (payload) => api('/update-task', { method: 'POST', body: JSON.stringify(payload) }),
  getNotes: (query) => api(`/notes?${qs(query)}`),
  saveNote: (payload) => api('/notes', { method: 'POST', body: JSON.stringify(payload) }),
  getClaimDocuments: (labId, claimId) => api(`/claim-documents?labId=${encodeURIComponent(labId)}&claimId=${encodeURIComponent(claimId)}`),
  getEscalations: (query) => api(`/escalations?${qs(query)}`),
  saveEscalation: (payload) => api('/escalations', { method: 'POST', body: JSON.stringify(payload) }),
  uploadClaimDocuments: async (labId, claimId, comment, uploadedBy, files) => {
    const form = new FormData();
    form.append('labId', labId);
    form.append('claimId', claimId);
    form.append('comment', comment || '');
    form.append('uploadedBy', uploadedBy || 'ReactWorkflow');
    Array.from(files || []).forEach(f => form.append('files', f));

    const { api } = await import('./httpClient');
    return api('/claim-documents', { method: 'POST', body: form });
  }
};

export { qs };
