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

// The AR Manager's response to an escalation is appended to the escalation comment as
// "Manager Response: ..." (and optionally "Recommended Next Action: ..."). Pull it out so it can be
// highlighted for the reviewer instead of blending into the rest of the comment text.
function extractManagerResponse(text = '') {
  const value = String(text || '');
  const mr = value.match(/Manager Response:\s*([\s\S]*?)(?=\n?\s*Recommended Next Action:|$)/i);
  const na = value.match(/Recommended Next Action:\s*([\s\S]*?)$/i);
  let cut = value.length;
  if (mr && mr.index < cut) cut = mr.index;
  if (na && na.index < cut) cut = na.index;
  return {
    managerResponse: mr ? mr[1].trim() : '',
    nextAction: na ? na[1].trim() : '',
    rest: value.slice(0, cut).trim()
  };
}

export default function StructuredNoteText({ text }) {
  const { managerResponse, nextAction, rest } = extractManagerResponse(text);
  const fields = parseStructuredNote(rest);
  const body = fields.length
    ? <div className="structured-note">
        {fields.map(field => <div className={`structured-note-field ${field.label === 'Note' || field.label === 'Affected Lines' || field.label === 'Documentation Description' ? 'wide' : ''} ${field.label === 'Recommended Action' ? 'recommended-action' : ''}`} key={field.label}>
          <span>{field.label}</span>
          <strong>{formatFieldValue(field)}</strong>
        </div>)}
      </div>
    : (rest ? <span className="structured-note-plain">{rest}</span> : null);

  if (!managerResponse && !nextAction) {
    return body || <span className="structured-note-plain">{text || '-'}</span>;
  }

  return <div className="structured-note-wrap">
    {body}
    <div className="manager-response-callout" role="note">
      <span className="manager-response-badge"><i className="bi bi-reply-fill" /> AR Manager Response</span>
      {managerResponse ? <div className="manager-response-line"><strong>{managerResponse}</strong></div> : null}
      {nextAction ? <div className="manager-response-line"><span>Recommended Next Action</span><strong>{nextAction}</strong></div> : null}
    </div>
  </div>;
}
