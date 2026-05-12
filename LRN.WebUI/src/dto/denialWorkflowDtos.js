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

export const emptyDashboard = { denialClassifications: [], actionCategories: [], analystWorkload: [], slaTiles: [] };
export const emptyPagedResult = { items: [], page: 1, totalPages: 0, totalCount: 0 };
