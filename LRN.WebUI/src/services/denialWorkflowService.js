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
  updateTask: (payload) => api('/update-task', { method: 'POST', body: JSON.stringify(payload) })
};

export { qs };
