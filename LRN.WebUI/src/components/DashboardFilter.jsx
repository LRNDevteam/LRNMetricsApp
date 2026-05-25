import React from 'react';
import SearchableMultiSelect from './SearchableMultiSelect';
import { statusOptions, actionCategoryOptions, priorityOptions } from '../utils/options';
function listWithDefault(values, fallback) { const list = Array.isArray(values) && values.length ? values : fallback.filter(Boolean); return [...new Set(list.filter(Boolean))]; }

export default function DashboardFilter({ filter, setFilterValue, clearFilter, reviewers, options }) {
  const statuses = listWithDefault(options?.statuses, statusOptions);
  const actions = listWithDefault(options?.actionCategories, actionCategoryOptions);
  const priorities = listWithDefault(options?.priorities, priorityOptions);
  const denialClassifications = listWithDefault(options?.denialClassifications, []);
  const reviewerOptions = (reviewers || []).map(r => ({ value: r.userName, label: r.displayName || r.userName }));

  return <div className="lrn-card filter-card"><div className="filter-row">
    <SearchableMultiSelect label="Status" value={filter.status} onChange={v => setFilterValue('status', v)} options={statuses} placeholder="All statuses" />
    <SearchableMultiSelect label="Reviewer" value={filter.reviewer} onChange={v => setFilterValue('reviewer', v)} options={reviewerOptions} placeholder="All reviewers" />
    <SearchableMultiSelect label="Payer Name" value={filter.payerName} onChange={v => setFilterValue('payerName', v)} options={options?.payerNames || []} placeholder="All payers" />
    <SearchableMultiSelect label="Denial Classification" value={filter.denialClassification} onChange={v => setFilterValue('denialClassification', v)} options={denialClassifications} placeholder="All classifications" />
    <SearchableMultiSelect label="Action Category" value={filter.actionCategory} onChange={v => setFilterValue('actionCategory', v)} options={actions} placeholder="All action categories" />
    <SearchableMultiSelect label="Denial Code" value={filter.denialCode} onChange={v => setFilterValue('denialCode', v)} options={options?.denialCodes || []} placeholder="All denial codes" />
    <SearchableMultiSelect label="Priority" value={filter.priority} onChange={v => setFilterValue('priority', v)} options={priorities} placeholder="All priorities" />
    <SearchableMultiSelect label="Clinic" value={filter.clinic} onChange={v => setFilterValue('clinic', v)} options={options?.clinics || []} placeholder="All clinics" />
    <SearchableMultiSelect label="Sales Rep" value={filter.salesRepname} onChange={v => setFilterValue('salesRepname', v)} options={options?.salesReps || []} placeholder="All sales reps" />
    <SearchableMultiSelect label="Referring Provider" value={filter.referringProvider} onChange={v => setFilterValue('referringProvider', v)} options={options?.referringProviders || []} placeholder="All providers" />
    <div className="filter-search"><label>Search</label><input value={filter.searchText || ''} onChange={e => setFilterValue('searchText', e.target.value)} placeholder="Claim / patient / payer" /></div>
    <div className="filter-actions"><button className="topbar-btn" type="button" onClick={clearFilter}>Clear</button></div>
  </div></div>;
}
