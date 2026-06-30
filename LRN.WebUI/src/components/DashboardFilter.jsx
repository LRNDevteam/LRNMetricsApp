import React from 'react';
import SearchableMultiSelect from './SearchableMultiSelect';
import { statusOptions, actionCategoryOptions, priorityOptions } from '../utils/options';
function listWithDefault(values, fallback) { const list = Array.isArray(values) && values.length ? values : fallback.filter(Boolean); return [...new Set(list.filter(Boolean))]; }

export default function DashboardFilter({ filter, setFilterValue, clearFilter, reviewers, options, visibleFilters }) {
  const statuses = listWithDefault(options?.statuses, statusOptions);
  const actions = listWithDefault(options?.actionCategories, actionCategoryOptions);
  const priorities = listWithDefault(options?.priorities, priorityOptions);
  const denialClassifications = listWithDefault(options?.denialClassifications, []);
  const reviewerOptions = (reviewers || []).map(r => ({ value: r.userName || r.UserName, label: r.displayName || r.DisplayName || r.userName || r.UserName })).filter(x => x.value);
  const visible = new Set(visibleFilters?.length ? visibleFilters : ['status', 'reviewer', 'payerName', 'denialClassification', 'actionCategory', 'denialCode', 'priority', 'clinic', 'salesRepname', 'referringProvider']);
  const show = key => visible.has(key);

  return <div className="lrn-card filter-card"><div className="filter-row">
    {show('status') && <SearchableMultiSelect label="Status" value={filter.status} onChange={v => setFilterValue('status', v)} options={statuses} placeholder="All statuses" />}
    {show('reviewer') && <SearchableMultiSelect label="Assigned To" value={filter.reviewer} onChange={v => setFilterValue('reviewer', v)} options={reviewerOptions} placeholder="All reviewers" />}
    {show('payerName') && <SearchableMultiSelect label="Payer Name" value={filter.payerName} onChange={v => setFilterValue('payerName', v)} options={options?.payerNames || []} placeholder="All payers" />}
    {show('panelName') && <SearchableMultiSelect label="Panel" value={filter.panelName} onChange={v => setFilterValue('panelName', v)} options={options?.panelNames || []} placeholder="All panels" />}
    {show('denialClassification') && <SearchableMultiSelect label="Denial Classification" value={filter.denialClassification} onChange={v => setFilterValue('denialClassification', v)} options={denialClassifications} placeholder="All classifications" />}
    {show('actionCategory') && <SearchableMultiSelect label="Action Category" value={filter.actionCategory} onChange={v => setFilterValue('actionCategory', v)} options={actions} placeholder="All action categories" />}
    {show('denialCode') && <SearchableMultiSelect label="Denial Code" value={filter.denialCode} onChange={v => setFilterValue('denialCode', v)} options={options?.denialCodes || []} placeholder="All denial codes" />}
    {show('priority') && <SearchableMultiSelect label="Priority" value={filter.priority} onChange={v => setFilterValue('priority', v)} options={priorities} placeholder="All priorities" />}
    {show('clinic') && <SearchableMultiSelect label="Clinic" value={filter.clinic} onChange={v => setFilterValue('clinic', v)} options={options?.clinics || []} placeholder="All clinics" />}
    {show('salesRepname') && <SearchableMultiSelect label="Sales Rep" value={filter.salesRepname} onChange={v => setFilterValue('salesRepname', v)} options={options?.salesReps || []} placeholder="All sales reps" />}
    {show('referringProvider') && <SearchableMultiSelect label="Referring Provider" value={filter.referringProvider} onChange={v => setFilterValue('referringProvider', v)} options={options?.referringProviders || []} placeholder="All providers" />}
    {show('aging') && <SearchableMultiSelect label="Aging" value={filter.agingBucket} onChange={v => setFilterValue('agingBucket', v)} options={options?.agingBuckets || []} placeholder="All aging buckets" />}
    {show('followupDue') && <SearchableMultiSelect label="Follow-up Due" value={filter.followupDue} onChange={v => setFilterValue('followupDue', v)} options={options?.followupDueBuckets || []} placeholder="Any due date" />}
    {show('followUpReason') && <SearchableMultiSelect label="Follow-up Reason" value={filter.followUpReason} onChange={v => setFilterValue('followUpReason', v)} options={options?.followUpReasons || []} placeholder="All reasons" />}
    {show('documentationType') && <SearchableMultiSelect label="Documentation Type" value={filter.documentationType} onChange={v => setFilterValue('documentationType', v)} options={options?.documentationTypes || []} placeholder="All types" />}
    {show('escalationReason') && <SearchableMultiSelect label="Escalation Reason" value={filter.escalationReason} onChange={v => setFilterValue('escalationReason', v)} options={options?.escalationReasons || []} placeholder="All reasons" />}
    {show('balanceBucket') && <SearchableMultiSelect label="Balance $" value={filter.balanceBucket} onChange={v => setFilterValue('balanceBucket', v)} options={options?.balanceBuckets || []} placeholder="All balances" />}
    {show('nextFollowUpDate') && <div className="filter-search"><label>Next Follow-up Date</label><input type="date" value={filter.nextFollowUpDate || ''} onChange={e => setFilterValue('nextFollowUpDate', e.target.value)} /></div>}
    {show('expectedResponseBy') && <div className="filter-search"><label>Expected Response By</label><input type="date" value={filter.expectedResponseBy || ''} onChange={e => setFilterValue('expectedResponseBy', e.target.value)} /></div>}
    <div className="filter-search"><label>Search</label><input value={filter.searchText || ''} onChange={e => setFilterValue('searchText', e.target.value)} placeholder="Claim / patient / payer" /></div>
    <div className="filter-actions"><button className="topbar-btn" type="button" onClick={clearFilter}>Clear</button></div>
  </div></div>;
}
