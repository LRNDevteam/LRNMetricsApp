export const emptyFilterOptions = {
  statuses: [],
  actionCategories: [],
  priorities: [],
  denialCodes: [],
  payerNames: [],
  panelNames: [],
  denialClassifications: [],
  clinics: [],
  salesReps: [],
  referringProviders: [],
  assignedUsers: [],
  followUpReasons: [],
  documentationTypes: [],
  escalationReasons: [],
  agingBuckets: ['0-30', '31-60', '61-90', '91-120', '120+'],
  balanceBuckets: ['0-100', '100-500', '500-1000', '1000-5000', '5000+'],
  followupDueBuckets: ['Today', 'Overdue', 'Next 7 Days', 'Next 14 Days', 'No Date']
};

export const emptyFilter = {
  status: '',
  reviewer: '',
  assignedUserId: '',
  assignedDuration: '',
  actionCategory: '',
  priority: '',
  denialCode: '',
  payerName: '',
  panelName: '',
  clinic: '',
  salesRepname: '',
  referringProvider: '',
  denialClassification: '',
  followUpReason: '',
  documentationType: '',
  escalationReason: '',
  expectedResponseBy: '',
  nextFollowUpDate: '',
  followupDue: '',
  agingBucket: '',
  balanceBucket: '',
  searchText: '',
  page: 1
};

export const emptyDashboard = { totalDenials: 0, totalClaims: 0, totalTasks: 0, outstandingAmount: 0, openInProgressCount: 0, closedCount: 0, assignedClaims: 0, pendingClaims: 0, closedClaims: 0, denialClassifications: [], actionCategories: [], analystWorkload: [], slaTiles: [] };
export const emptyPagedResult = { items: [], page: 1, totalPages: 0, totalCount: 0 };
