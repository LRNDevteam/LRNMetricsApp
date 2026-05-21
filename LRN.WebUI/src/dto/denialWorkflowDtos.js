export const emptyFilterOptions = {
  statuses: [],
  actionCategories: [],
  priorities: [],
  denialCodes: [],
  payerNames: [],
  denialClassifications: [],
  clinics: [],
  salesReps: [],
  referringProviders: []
};

export const emptyFilter = {
  status: '',
  reviewer: '',
  actionCategory: '',
  priority: '',
  denialCode: '',
  payerName: '',
  clinic: '',
  salesRepname: '',
  referringProvider: '',
  denialClassification: '',
  searchText: '',
  page: 1
};

export const emptyDashboard = { totalDenials: 0, totalClaims: 0, totalTasks: 0, outstandingAmount: 0, openInProgressCount: 0, closedCount: 0, assignedClaims: 0, pendingClaims: 0, closedClaims: 0, denialClassifications: [], actionCategories: [], analystWorkload: [], slaTiles: [] };
export const emptyPagedResult = { items: [], page: 1, totalPages: 0, totalCount: 0 };
