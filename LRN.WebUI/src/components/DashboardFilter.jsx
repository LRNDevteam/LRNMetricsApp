import React from 'react';
import { statusOptions, actionCategoryOptions, priorityOptions } from '../utils/options';
function listWithDefault(values, fallback) { const list = Array.isArray(values) && values.length ? values : fallback.filter(Boolean); return [...new Set(list.filter(Boolean))]; }

export default function DashboardFilter({ filter, setFilterValue, clearFilter, reviewers, options }) {
  const statuses = listWithDefault(options?.statuses, statusOptions);
  const actions = listWithDefault(options?.actionCategories, actionCategoryOptions);
  const priorities = listWithDefault(options?.priorities, priorityOptions);
  const denialClassifications = listWithDefault(options?.denialClassifications, []);
  return <div className="lrn-card filter-card"><div className="filter-row">
    <div><label>Status</label><select value={filter.status} onChange={e => setFilterValue('status', e.target.value)}><option value="">All statuses</option>{statuses.map(x => <option key={x} value={x}>{x}</option>)}</select></div>
    <div><label>Reviewer</label><select value={filter.reviewer} onChange={e => setFilterValue('reviewer', e.target.value)}><option value="">All reviewers</option>{reviewers.map(r => <option key={r.userName} value={r.userName}>{r.displayName || r.userName}</option>)}</select></div>
    <div><label>Payer Name</label><select value={filter.payerName} onChange={e => setFilterValue('payerName', e.target.value)}><option value="">All payers</option>{(options?.payerNames || []).map(x => <option key={x} value={x}>{x}</option>)}</select></div>
    <div><label>Denial Classification</label><select value={filter.denialClassification || ''} onChange={e => setFilterValue('denialClassification', e.target.value)}><option value="">All classifications</option>{denialClassifications.map(x => <option key={x} value={x}>{x}</option>)}</select></div>
    <div><label>Action Category</label><select value={filter.actionCategory} onChange={e => setFilterValue('actionCategory', e.target.value)}><option value="">All action categories</option>{actions.map(x => <option key={x} value={x}>{x}</option>)}</select></div>
    <div><label>Denial Code</label><select value={filter.denialCode} onChange={e => setFilterValue('denialCode', e.target.value)}><option value="">All denial codes</option>{(options?.denialCodes || []).map(x => <option key={x} value={x}>{x}</option>)}</select></div>
    <div><label>Priority</label><select value={filter.priority} onChange={e => setFilterValue('priority', e.target.value)}><option value="">All priorities</option>{priorities.map(x => <option key={x} value={x}>{x}</option>)}</select></div>
    <div><label>Clinic</label><input value={filter.clinic || ''} onChange={e => setFilterValue('clinic', e.target.value)} list="clinic-options" placeholder="Clinic" /><datalist id="clinic-options">{(options?.clinics || []).map(x => <option key={x} value={x} />)}</datalist></div>
    <div><label>Sales Rep</label><input value={filter.salesRepname || ''} onChange={e => setFilterValue('salesRepname', e.target.value)} list="sales-rep-options" placeholder="Sales rep" /><datalist id="sales-rep-options">{(options?.salesReps || []).map(x => <option key={x} value={x} />)}</datalist></div>
    <div><label>Referring Provider</label><input value={filter.referringProvider || ''} onChange={e => setFilterValue('referringProvider', e.target.value)} list="provider-options" placeholder="Provider" /><datalist id="provider-options">{(options?.referringProviders || []).map(x => <option key={x} value={x} />)}</datalist></div>
    <div><label>Search</label><input value={filter.searchText || ''} onChange={e => setFilterValue('searchText', e.target.value)} placeholder="Claim / patient / payer" /></div>
    <div className="filter-actions"><button className="topbar-btn" type="button" onClick={clearFilter}>Clear</button></div>
  </div></div>;
}
