import React from 'react';

const labels = [
  'Update Scope',
  'Scope Value',
  'New Line Status',
  'Next Follow-up Date',
  'Actual Action / Outcome',
  'Recommended Action',
  'Action Completed',
  'Documentation Type',
  'Documentation Description',
  'Affected Lines',
  'Note'
];

function parseStructuredNote(text = '') {
  const value = String(text || '').trim();
  if (!value) return [];
  const pattern = new RegExp(`(?:^|\\s|\\n)(${labels.map(x => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')}):\\s*`, 'g');
  const matches = Array.from(value.matchAll(pattern));
  if (!matches.length) return [];
  return matches.map((match, index) => {
    const next = matches[index + 1];
    return {
      label: match[1],
      value: value.slice(match.index + match[0].length, next ? next.index : value.length).trim()
    };
  }).filter(item => item.value);
}

function formatFieldValue(field) {
  if (field.label !== 'Affected Lines') return field.value;
  const cpts = [...new Set(Array.from(String(field.value || '').matchAll(/CPTs?\s*:?\s*([A-Za-z0-9.-]+)/gi)).map(match => match[1]).filter(Boolean))];
  return cpts.length ? `CPTs: ${cpts.join(', ')}` : field.value;
}

export default function StructuredNoteText({ text }) {
  const fields = parseStructuredNote(text);
  if (!fields.length) return <span className="structured-note-plain">{text || '-'}</span>;
  return <div className="structured-note">
    {fields.map(field => <div className={`structured-note-field ${field.label === 'Note' || field.label === 'Affected Lines' || field.label === 'Documentation Description' ? 'wide' : ''} ${field.label === 'Recommended Action' ? 'recommended-action' : ''}`} key={field.label}>
      <span>{field.label}</span>
      <strong>{formatFieldValue(field)}</strong>
    </div>)}
  </div>;
}
