export const money = (v) => `$${Number(v || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
export const date = (v) => v ? new Date(v).toLocaleDateString() : '';
export const initials = (name) => String(name || 'NA').split(/[\s._-]+/).filter(Boolean).slice(0, 2).map(x => x[0]?.toUpperCase()).join('') || 'NA';
export const statusClass = (v) => { const s = String(v || '').toLowerCase(); if (s.includes('closed') || s.includes('complete')) return 'badge-closed'; if (s.includes('progress') || s.includes('pending')) return 'badge-ip'; if (s.includes('escal')) return 'badge-escalated'; return 'badge-open'; };
export const priorityClass = (v) => String(v || '').toLowerCase().includes('high') ? 'badge-high' : String(v || '').toLowerCase().includes('medium') ? 'badge-med' : 'badge-low';
export const canAssignRole = (role) => { const r = String(role || '').toLowerCase(); return r.includes('admin') || r.includes('ar manager') || r.includes('manager'); };
export const actionBadgeClass = (v) => { const s = String(v || '').toLowerCase(); if (s.includes('appeal')) return 'badge-appeal'; if (s.includes('rebill')) return 'badge-rebill'; if (s.includes('write')) return 'badge-woff'; if (s.includes('client')) return 'badge-cip'; return 'badge-review'; };
