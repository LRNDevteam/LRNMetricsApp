const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 2 });
const moneyCompact = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', notation: 'compact', maximumFractionDigits: 1 });
const count = new Intl.NumberFormat('en-US');

export const fmt = {
  money: (v) => (v === null || v === undefined || v === '' ? '—' : money.format(Number(v))),
  moneyCompact: (v) => (v === null || v === undefined ? '—' : moneyCompact.format(Number(v))),
  count: (v) => (v === null || v === undefined ? '—' : count.format(Number(v))),
  // API dates arrive as ISO strings; date-only values must not shift across time zones.
  date: (v) => {
    if (!v) return '—';
    const s = String(v).slice(0, 10);
    const [y, m, d] = s.split('-');
    return y && m && d ? `${m}/${d}/${y}` : String(v);
  },
  dateTime: (v) => {
    if (!v) return '—';
    const d = new Date(String(v).endsWith('Z') ? v : `${v}Z`);
    return Number.isNaN(d.getTime()) ? String(v) : d.toLocaleString();
  },
  pct: (v) => (v === null || v === undefined ? '—' : `${(Number(v) * 100).toFixed(1)}%`)
};

// Queue badge colours come from arwb.ArQueue.BadgeClass so the same queue looks the same everywhere.
export function badgeClass(kind) {
  return {
    good: 'text-bg-success',
    info: 'text-bg-info',
    warning: 'text-bg-warning',
    critical: 'text-bg-danger',
    purple: 'arwb-badge-purple',
    neutral: 'text-bg-secondary'
  }[kind] || 'text-bg-secondary';
}

export function statusBadgeClass(status) {
  return {
    Unassigned: 'text-bg-secondary',
    Assigned: 'text-bg-info',
    'Submitted for QA': 'arwb-badge-purple',
    'QA Rejected': 'text-bg-danger',
    Completed: 'text-bg-success'
  }[status] || 'text-bg-secondary';
}

export function priorityBadgeClass(priority) {
  return { High: 'text-bg-danger', Medium: 'text-bg-warning', Low: 'text-bg-light border' }[priority] || 'text-bg-light border';
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
