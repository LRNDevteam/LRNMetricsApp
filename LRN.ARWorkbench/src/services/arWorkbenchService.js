import { api, downloadFile, qs } from './httpClient';

const json = (method, body) => ({ method, body: JSON.stringify(body) });

// One function per /api/ar-workbench endpoint (LRN.ReportsApi ArWorkbenchController).
export const arWorkbenchService = {
  // Assignment Management (ARWorkbench.Assign)
  assignmentOverview: (labId, signal) => api(`assignment${qs({ labId })}`, { signal }),
  assignableAgents: (labId) => api(`assignment/agents${qs({ labId })}`),
  previewBatch: (labId, criteria, signal) => api(`assignment/preview${qs({ labId })}`, { ...json('POST', { criteria }), signal }),
  createBatch: (labId, body) => api(`assignment/batches${qs({ labId })}`, json('POST', body)),
  batches: (labId, status, signal) => api(`assignment/batches${qs({ labId, status })}`, { signal }),
  batchDetail: (labId, batchId) => api(`assignment/batches/${batchId}${qs({ labId })}`),
  cancelBatch: (labId, batchId) => api(`assignment/batches/${batchId}/cancel${qs({ labId })}`, { method: 'POST' }),
  assignClaims: (labId, body) => api(`assignment/assign${qs({ labId })}`, json('POST', body)),

  // Master File Maintenance (ARWorkbench.ManageSettings)
  masterValues: (labId) => api(`masters${qs({ labId })}`),
  addMasterValue: (labId, type, body) => api(`masters/${encodeURIComponent(type)}${qs({ labId })}`, json('POST', body)),
  updateMasterValue: (labId, type, body) => api(`masters/${encodeURIComponent(type)}${qs({ labId })}`, json('PUT', body)),
  deleteMasterValue: (labId, type, value) => api(`masters/${encodeURIComponent(type)}${qs({ labId, value })}`, { method: 'DELETE' }),

  denialCodes: (query, signal) => api(`denial-codes${qs(query)}`, { signal }),
  unmappedDenialCodes: (labId) => api(`denial-codes/unmapped${qs({ labId })}`),
  denialCodeImpact: (labId, code) => api(`denial-codes/impact${qs({ labId, code })}`),
  addDenialCode: (labId, body) => api(`denial-codes${qs({ labId })}`, json('POST', body)),
  updateDenialCode: (labId, body) => api(`denial-codes${qs({ labId })}`, json('PUT', body)),
  deleteDenialCode: (labId, code) => api(`denial-codes${qs({ labId, code })}`, { method: 'DELETE' }),
  importDenialCodes: (labId, file) => {
    const form = new FormData();
    form.append('file', file);
    return api(`denial-codes/import${qs({ labId })}`, { method: 'POST', body: form });
  },
  downloadDenialCodeTemplate: (labId) => downloadFile(`denial-codes/template${qs({ labId })}`, 'ARWorkbench_DenialCodeMaster_Template.xlsx'),
  exportDenialCodes: (labId) => downloadFile(`denial-codes/export${qs({ labId })}`, 'ARWorkbench_DenialCodeMaster.xlsx'),
  applyDenialCodes: (labId) => api(`denial-codes/apply${qs({ labId })}`, { method: 'POST' }),

  // Denial Mapper Super Master and its dropdown lists (central, LRNMaster) - the Denial Workflow's data
  superMaster: (query, signal) => api(`super-master${qs(query)}`, { signal }),
  superMasterOptions: (labId) => api(`super-master/options${qs({ labId })}`),
  addSuperMaster: (labId, body) => api(`super-master${qs({ labId })}`, json('POST', body)),
  updateSuperMaster: (labId, id, body) => api(`super-master/${id}${qs({ labId })}`, json('PUT', body)),
  deleteSuperMaster: (labId, id) => api(`super-master/${id}${qs({ labId })}`, { method: 'DELETE' }),
  importSuperMaster: (labId, file) => {
    const form = new FormData();
    form.append('file', file);
    return api(`super-master/import${qs({ labId })}`, { method: 'POST', body: form });
  },
  exportSuperMaster: (labId) => downloadFile(`super-master/export${qs({ labId })}`, 'DenialActionSuperMaster.xlsx'),
  downloadSuperMasterTemplate: (labId) => downloadFile(`super-master/template${qs({ labId })}`, 'DenialActionSuperMaster_Template.xlsx'),
  mapperMasters: (labId) => api(`mapper-masters${qs({ labId })}`),
  addMapperMaster: (labId, type, body) => api(`mapper-masters/${encodeURIComponent(type)}${qs({ labId })}`, json('POST', body)),
  updateMapperMaster: (labId, type, body) => api(`mapper-masters/${encodeURIComponent(type)}${qs({ labId })}`, json('PUT', body)),
  deleteMapperMaster: (labId, type, value) => api(`mapper-masters/${encodeURIComponent(type)}${qs({ labId, value })}`, { method: 'DELETE' }),

  labs: () => api('labs'),
  me: (labId) => api(`me${qs({ labId })}`),
  queues: (labId, signal) => api(`queues${qs({ labId })}`, { signal }),
  dashboard: (labId, signal) => api(`dashboard${qs({ labId })}`, { signal }),
  claims: (filter, signal) => api(`claims${qs(filter)}`, { signal }),
  claimFilterOptions: (labId, signal) => api(`claims/filter-options${qs({ labId })}`, { signal }),
  claim: (labId, claimKey, signal) => api(`claims/${encodeURIComponent(claimKey)}${qs({ labId })}`, { signal }),
  masterData: (labId) => api(`master-data${qs({ labId })}`),
  refreshRuns: (labId, top = 10) => api(`data-processing/runs${qs({ labId, top })}`),
  runRefresh: (labId, note) => api(`data-processing/run${qs({ labId })}`, { method: 'POST', body: JSON.stringify({ note }) })
};
