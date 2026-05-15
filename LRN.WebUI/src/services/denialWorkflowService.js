import { api, qs } from './httpClient';

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
  getLabs: () => api('/labs'),
  getReviewers: (labId) => api(`/reviewers?labId=${encodeURIComponent(labId)}`),
  getFilterOptions: (labId) => api(`/filter-options?labId=${encodeURIComponent(labId)}`),
  getDashboard: (query) => api(`/dashboard?${qs(query)}`),
  getInsights: (query) => api(`/insights?${qs(query)}`),
  getClaims: async (query) => normalizePagedResult(await api(`/claims?${qs(query)}`)),
  getTasks: async (query) => normalizePagedResult(await api(`/tasks?${qs(query)}`)),
  getVerification: async (query) => normalizePagedResult(await api(`/verification?${qs(query)}`)),
  getClaimTasks: (labId, claimId, taskView = '') => api(`/claims/${encodeURIComponent(claimId)}/tasks?${qs({ labId, taskView })}`),
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
