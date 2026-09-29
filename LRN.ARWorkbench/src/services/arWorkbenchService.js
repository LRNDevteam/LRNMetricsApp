import { api, qs } from './httpClient';

// One function per /api/ar-workbench endpoint (LRN.ReportsApi ArWorkbenchController).
export const arWorkbenchService = {
  labs: () => api('labs'),
  me: (labId) => api(`me${qs({ labId })}`),
  queues: (labId, signal) => api(`queues${qs({ labId })}`, { signal }),
  dashboard: (labId, signal) => api(`dashboard${qs({ labId })}`, { signal }),
  claims: (filter, signal) => api(`claims${qs(filter)}`, { signal }),
  claim: (labId, claimKey, signal) => api(`claims/${encodeURIComponent(claimKey)}${qs({ labId })}`, { signal }),
  masterData: (labId) => api(`master-data${qs({ labId })}`),
  refreshRuns: (labId, top = 10) => api(`data-processing/runs${qs({ labId, top })}`),
  runRefresh: (labId, note) => api(`data-processing/run${qs({ labId })}`, { method: 'POST', body: JSON.stringify({ note }) })
};
