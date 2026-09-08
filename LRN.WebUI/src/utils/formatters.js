// Accounting layout, not Currency — matching Helpers/AccountingHtml.cs on the LRN Metrics MVC
// pages so both halves of the product read the same: the symbol is separated from the figure,
// negatives are parenthesised rather than signed, and a zero shows as a dash instead of "$0.00".
// Returns a plain string on purpose: money() is rendered inline in places (claim drawer subtitle,
// KPI values) as well as in table cells, and an element that laid the symbol out flush-left would
// have to be a full-width flex box, which would break onto its own line in those inline spots.
export const accounting = (value, decimals = 2) => {
  const n = Number(value || 0);
  if (!Number.isFinite(n) || n === 0) return '$ -';
  const opts = { minimumFractionDigits: decimals, maximumFractionDigits: decimals };
  return n < 0
    ? `$ (${Math.abs(n).toLocaleString(undefined, opts)})`
    : `$ ${n.toLocaleString(undefined, opts)}`;
};
export const money = (v) => accounting(v, 2);
export const date = (v) => v ? new Date(v).toLocaleDateString() : '';
export const initials = (name) => String(name || 'NA').split(/[\s._-]+/).filter(Boolean).slice(0, 2).map(x => x[0]?.toUpperCase()).join('') || 'NA';
export const statusClass = (v) => {
  const s = String(v || '').toLowerCase();
  if (s.includes('breach')) return 'badge-breached';
  if (s.includes('due')) return 'badge-due-soon';
  if (s.includes('good')) return 'badge-good';
  if (s.includes('verification')) return 'badge-verification';
  if (s.includes('closed') || s.includes('complete')) return 'badge-closed';
  if (s.includes('escal')) return 'badge-escalated';
  if (s.includes('progress') || s.includes('pending')) return 'badge-ip';
  return 'badge-open';
};
export const priorityClass = (v) => String(v || '').toLowerCase().includes('high') ? 'badge-high' : String(v || '').toLowerCase().includes('medium') ? 'badge-med' : 'badge-low';
export const normalizeRole = (role) => String(role || '').replace(/[^a-z0-9]/gi, '').toLowerCase();
export const isClientManagerRole = (role) => normalizeRole(role).includes('clientmanager');
export const isAccountManagerRole = (role) => normalizeRole(role).includes('accountmanager');
// Lab User: the lab's own staff, watching their claims. Stricter than Client/Account Manager,
// who are read-only on the queues but still respond to escalations routed to them -- a Lab User
// has no write path at all and no escalation queues. Mirrors IsLabUserRole in the API's
// DenialWorkflowController; both must agree or the UI offers something the API refuses.
export const isLabUserRole = (role) => normalizeRole(role).includes('labuser');
export const isReadOnlyWorkflowRole = (role) => isClientManagerRole(role) || isAccountManagerRole(role) || isLabUserRole(role);
export const isArManagerRole = (role) => normalizeRole(role).includes('armanager');
export const isArReviewerRole = (role) => {
  const r = normalizeRole(role);
  return (r.includes('arreviewer') || r.includes('aranalyser') || r.includes('aranalyzer') || r.includes('reviewer'))
    && !r.includes('manager')
    && !r.includes('admin');
};
export const canAssignRole = (role) => {
  const r = normalizeRole(role);
  return r.includes('admin') || isArManagerRole(role);
};
export const canDownloadWorkflowRole = (role) => {
  const r = normalizeRole(role);
  // Exporting is reading: a Lab User may take their lab's claim data to a spreadsheet
  // even though they cannot change any of it.
  return r.includes('admin') || r.includes('armanager') || isArReviewerRole(role) || isClientManagerRole(role) || isAccountManagerRole(role) || isLabUserRole(role);
};
export const canUpdateWorkflowRole = (role) => {
  const r = normalizeRole(role);
  return r.includes('admin') || r.includes('armanager') || isArReviewerRole(role);
};
export const actionBadgeClass = (v) => { const s = String(v || '').toLowerCase(); if (s.includes('appeal')) return 'badge-appeal'; if (s.includes('rebill')) return 'badge-rebill'; if (s.includes('write')) return 'badge-woff'; if (s.includes('client')) return 'badge-cip'; return 'badge-review'; };
