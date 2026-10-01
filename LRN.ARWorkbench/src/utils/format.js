const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 2 });
const moneyCompact = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', notation: 'compact', maximumFractionDigits: 1 });
const count = new Intl.NumberFormat('en-US');

export const fmt = {
  money: (v) => (v === null || v === undefined || v === '' ? '—' : money.format(Number(v))),
  moneyCompact: (v) => (v === null || v === undefined ? '—' : moneyCompact.format(Number(v))),
  count: (v) => (v === null || v === undefined ? '—' : count.format(Number(v))),
  // API dates arrive as ISO strings; date-only values must not shift across time zones.
  // "MMM DD, YYYY" (handoff FR-UI-06).
  date: (v) => {
    if (!v) return '—';
    const [y, m, d] = String(v).slice(0, 10).split('-').map(Number);
    if (!y || !m || !d) return String(v);
    return `${MONTHS[m - 1]} ${String(d).padStart(2, '0')}, ${y}`;
  },
  dateTime: (v) => {
    if (!v) return '—';
    const d = new Date(String(v).endsWith('Z') ? v : `${v}Z`);
    if (Number.isNaN(d.getTime())) return String(v);
    return `${d.toLocaleDateString('en-US', { month: 'short', day: '2-digit', year: 'numeric' })} · ${d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })}`;
  },
  pct: (v) => (v === null || v === undefined ? '—' : `${(Number(v) * 100).toFixed(1)}%`),
  initials: (name) => (name ? name.split(/[\s.]+/).filter(Boolean).slice(0, 2).map((w) => w[0]).join('').toUpperCase() : '?'),
  // Whole days from today to an ISO date (negative = past).
  daysUntil: (v) => {
    if (!v) return null;
    const [y, m, d] = String(v).slice(0, 10).split('-').map(Number);
    const today = new Date(); today.setHours(0, 0, 0, 0);
    return Math.round((new Date(y, m - 1, d) - today) / 86400000);
  }
};

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// The mockup's badge colours (App.arQueueBadgeClass / App.statusBadgeClass), so the same queue or
// status looks the same on every screen.
export function badgeClass(kind) {
  return {
    good: 'arwb-badge-good',
    info: 'arwb-badge-info',
    warning: 'arwb-badge-warning',
    critical: 'arwb-badge-critical',
    purple: 'arwb-badge-purple',
    accent: 'arwb-badge-accent',
    neutral: 'arwb-badge-neutral'
  }[kind] || 'arwb-badge-neutral';
}

export function arQueueBadgeClass(topQueueId) {
  return {
    closed: 'arwb-badge-neutral', nonresponded: 'arwb-badge-info', denied: 'arwb-badge-warning', partial: 'arwb-badge-info',
    patientar: 'arwb-badge-neutral', partialadj: 'arwb-badge-warning', escalation: 'arwb-badge-purple', cipresponse: 'arwb-badge-accent',
    refollowup: 'arwb-badge-critical', submittedqa: 'arwb-badge-purple', completed: 'arwb-badge-good', qarejected: 'arwb-badge-critical',
    autoadj: 'arwb-badge-warning'
  }[topQueueId] || 'arwb-badge-neutral';
}

export function statusBadgeClass(status) {
  return {
    Unassigned: 'arwb-badge-neutral',
    Assigned: 'arwb-badge-info',
    'Submitted for QA': 'arwb-badge-purple',
    'QA Rejected': 'arwb-badge-critical',
    Completed: 'arwb-badge-good'
  }[status] || 'arwb-badge-neutral';
}

export function runStatusBadgeClass(status) {
  return { Succeeded: 'arwb-badge-good', Failed: 'arwb-badge-critical', Running: 'arwb-badge-warning' }[status] || 'arwb-badge-neutral';
}

export function toCsv(columns, rows) {
  const escape = (value) => {
    const s = value === null || value === undefined ? '' : String(value);
    return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const header = columns.map((c) => escape(c.label)).join(',');
  const body = rows.map((row) => columns.map((c) => escape(c.csv ? c.csv(row) : row[c.key])).join(','));
  return [header, ...body].join('\r\n');
}

export function downloadText(fileName, text, type = 'text/csv;charset=utf-8') {
  const blob = new Blob(['﻿', text], { type });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = fileName;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}
