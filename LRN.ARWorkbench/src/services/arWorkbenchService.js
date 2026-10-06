import { api, downloadFile, qs } from './httpClient';

const json = (method, body) => ({ method, body: JSON.stringify(body) });

// One function per /api/ar-workbench endpoint (LRN.ReportsApi ArWorkbenchController).
export const arWorkbenchService = {
  workSummary: (labId) => api(`work-summary${qs({ labId })}`),

  // Denial Code Descriptions: central Denial Code Master (all labs) + lab Non-Collectible sync
  codeMaster: (labId) => api(`code-master${qs({ labId })}`),
  addCodeMasterRow: (labId, body) => api(`code-master${qs({ labId })}`, json('POST', body)),
  updateCodeMasterRow: (labId, body) => api(`code-master${qs({ labId })}`, json('PUT', body)),
  deleteCodeMasterRow: (labId, code) => api(`code-master${qs({ labId, code })}`, { method: 'DELETE' }),
  importCodeMaster: (labId, file) => {
    const form = new FormData();
    form.append('file', file);
    return api(`code-master/import${qs({ labId })}`, { method: 'POST', body: form });
  },
  exportCodeMaster: (labId) => downloadFile(`code-master/export${qs({ labId })}`, 'ARWorkbench_DenialCodeDescriptions.xlsx'),
  downloadCodeMasterTemplate: (labId) => downloadFile(`code-master/template${qs({ labId })}`, 'ARWorkbench_DenialCodeDescriptions_Template.xlsx'),
  nonCollectibleSyncPreview: (labId) => api(`code-master/non-collectible-sync${qs({ labId })}`),
  applyNonCollectibleSync: (labId) => api(`code-master/non-collectible-sync${qs({ labId })}`, { method: 'POST' }),

  // Automatic Adjustment (claimKeys null = every eligible claim)
  previewAutoAdjust: (labId, claimKeys) => api(`auto-adjustments/preview${qs({ labId })}`, json('POST', { claimKeys })),
  processAutoAdjust: (labId, claimKeys) => api(`auto-adjustments/process${qs({ labId })}`, json('POST', { claimKeys })),
  markAdjustmentsPosted: (labId, claimKeys) => api(`auto-adjustments/mark-posted${qs({ labId })}`, json('POST', { claimKeys })),

  // User Management (ARWorkbench.ManageUsers)
  users: (labId) => api(`users${qs({ labId })}`),
  createUser: (labId, body) => api(`users${qs({ labId })}`, json('POST', body)),
  updateUser: (labId, id, body) => api(`users/${id}${qs({ labId })}`, json('PUT', body)),

  // Saved Views (each user's own, per screen)
  savedViews: (labId, viewKey) => api(`saved-views${qs({ labId, viewKey })}`),
  saveView: (labId, body) => api(`saved-views${qs({ labId })}`, json('POST', body)),
  updateSavedView: (labId, id, body) => api(`saved-views/${id}${qs({ labId })}`, json('PUT', body)),
  deleteSavedView: (labId, id) => api(`saved-views/${id}${qs({ labId })}`, { method: 'DELETE' }),

  // Follow-up notes, claim export, insights, timely-filing limits
  logFollowUp: (labId, claimKey, body) => api(`claims/${encodeURIComponent(claimKey)}/follow-ups${qs({ labId })}`, json('POST', body)),
  exportClaims: (filter) => downloadFile(`claims/export${qs(filter)}`, 'ARWorkbench_Claims.xlsx'),
  insights: (labId, signal) => api(`data-processing/insights${qs({ labId })}`, { signal }),
  tflSettings: (labId) => api(`settings/tfl${qs({ labId })}`),
  addTflThreshold: (labId, body) => api(`settings/tfl${qs({ labId })}`, json('POST', body)),
  updateTflThreshold: (labId, body) => api(`settings/tfl${qs({ labId })}`, json('PUT', body)),
  deleteTflThreshold: (labId, financialClass) => api(`settings/tfl${qs({ labId, financialClass })}`, { method: 'DELETE' }),
  saveTflDefaults: (labId, body) => api(`settings/tfl/defaults${qs({ labId })}`, json('PUT', body)),

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
