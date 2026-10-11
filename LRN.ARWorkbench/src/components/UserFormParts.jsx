import { useEffect, useId, useMemo, useRef, useState } from 'react';
import Icon from './Icon';
import { arWorkbenchService } from '../services/arWorkbenchService';

// Pieces shared by Add User (UserCreatePage) and Edit User (UsersPage).

export function LabPicker({ labs, selected, onChange }) {
  const [term, setTerm] = useState('');
  const sel = new Set(selected);
  const shown = labs.filter((l) => l.labName.toLowerCase().includes(term.trim().toLowerCase()));
  const toggle = (id) => onChange(sel.has(id) ? selected.filter((x) => x !== id) : [...selected, id]);
  const allShown = shown.length > 0 && shown.every((l) => sel.has(l.labId));
  const toggleAll = () => onChange(allShown
    ? selected.filter((id) => !shown.some((l) => l.labId === id))
    : [...new Set([...selected, ...shown.map((l) => l.labId)])]);

  return (
    <div className="arwb-check-list">
      {labs.length > 8 && (
        <input type="search" className="arwb-input" placeholder="Find a lab…" value={term} onChange={(e) => setTerm(e.target.value)} aria-label="Find a lab" />
      )}
      <label className="arwb-check-item arwb-check-all">
        <input type="checkbox" checked={allShown} onChange={toggleAll} /> {term ? 'All matching' : 'All labs'}
      </label>
      <div className="arwb-check-items">
        {shown.map((l) => (
          <label key={l.labId} className="arwb-check-item">
            <input type="checkbox" checked={sel.has(l.labId)} onChange={() => toggle(l.labId)} /> {l.labName}
          </label>
        ))}
        {shown.length === 0 && <span className="arwb-hint">No lab matches.</span>}
      </div>
      <small className="arwb-hint">{selected.length} selected</small>
    </div>
  );
}

const MAX_SHOWN = 200;

/**
 * Type to search, then pick one value from `options` (strings). Only a listed value can be chosen:
 * the API rejects a clinic / provider that is not on the lab's claims. Arrow keys move, Enter picks,
 * Escape closes. Lists of thousands stay fast because only the first 200 matches are rendered.
 */
export function SearchSelect({ id, options, value, onChange, placeholder, disabled, loading }) {
  const [open, setOpen] = useState(false);
  const [term, setTerm] = useState('');
  const [active, setActive] = useState(0);
  const ref = useRef(null);
  const listRef = useRef(null);
  const listId = useId();

  useEffect(() => {
    if (!open) return undefined;
    const close = (e) => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [open]);

  const matches = useMemo(() => {
    const q = term.trim().toLowerCase();
    return q ? options.filter((o) => o.toLowerCase().includes(q)) : options;
  }, [options, term]);
  const shown = matches.slice(0, MAX_SHOWN);

  useEffect(() => { setActive(0); }, [term, open]);
  useEffect(() => {
    listRef.current?.querySelector(`[data-index="${active}"]`)?.scrollIntoView({ block: 'nearest' });
  }, [active]);

  function pick(v) {
    onChange(v);
    setTerm('');
    setOpen(false);
  }

  function onKeyDown(e) {
    if (e.key === 'ArrowDown') { e.preventDefault(); setOpen(true); setActive((a) => Math.min(a + 1, shown.length - 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setActive((a) => Math.max(a - 1, 0)); }
    else if (e.key === 'Enter') {
      // Never submit the surrounding form from inside the picker.
      if (open) { e.preventDefault(); if (shown[active]) pick(shown[active]); }
    } else if (e.key === 'Escape') { if (open) { e.stopPropagation(); setOpen(false); } }
  }

  return (
    <div className="arwb-search-select" ref={ref}>
      <div className="arwb-input-row">
        <input id={id} className="arwb-input" role="combobox" aria-expanded={open} aria-controls={listId} aria-autocomplete="list"
          autoComplete="off" disabled={disabled}
          placeholder={loading ? 'Loading…' : (value || placeholder)}
          value={open ? term : value}
          onFocus={() => setOpen(true)}
          onChange={(e) => { setTerm(e.target.value); setOpen(true); }}
          onKeyDown={onKeyDown} />
        {value && !disabled && (
          <button type="button" className="arwb-icon-btn" aria-label="Clear" onClick={() => pick('')}><Icon name="close" size={14} /></button>
        )}
      </div>
      {open && !disabled && (
        <div className="arwb-popover arwb-search-select-pop" id={listId} role="listbox" ref={listRef}>
          {shown.map((o, i) => (
            <button type="button" key={o} role="option" data-index={i} aria-selected={o === value}
              className={`arwb-search-option${i === active ? ' active' : ''}${o === value ? ' selected' : ''}`}
              onMouseEnter={() => setActive(i)} onMouseDown={(e) => e.preventDefault()} onClick={() => pick(o)}>
              {o}
            </button>
          ))}
          {matches.length === 0 && <span className="arwb-hint">No match for “{term}”.</span>}
          {matches.length > MAX_SHOWN && <span className="arwb-hint">Showing {MAX_SHOWN} of {matches.length.toLocaleString()} — type more to narrow.</span>}
        </div>
      )}
    </div>
  );
}

/**
 * Clinic / Referring Provider per selected lab, for the Clinic Viewer and Provider Viewer roles.
 * Each lab's choices are the distinct values on that lab's claims; the user then sees only claims
 * whose ClinicName / ReferringProvider equals the chosen value, in that lab only.
 * scopes: { [labId]: value }   onChange(nextScopes)
 */
export function ScopePicker({ labId, roleScope, labs, labIds, scopes, onChange }) {
  const [choices, setChoices] = useState({});   // `${level}|${labId}` -> string[] | { loading } | { error }

  useEffect(() => {
    if (!roleScope) return;
    labIds.forEach((id) => {
      const key = `${roleScope}|${id}`;
      if (choices[key]) return;
      setChoices((c) => ({ ...c, [key]: { loading: true } }));
      arWorkbenchService.userScopeOptions(labId, id, roleScope)
        .then((list) => setChoices((c) => ({ ...c, [key]: list })))
        .catch((e) => setChoices((c) => ({ ...c, [key]: { error: e.message } })));
    });
  }, [roleScope, labIds]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!roleScope || labIds.length === 0) return null;
  const noun = roleScope === 'clinic' ? 'clinic' : 'referring provider';

  return (
    <div className="arwb-field">
      <span className="arwb-field-label">Access — {roleScope === 'clinic' ? 'Clinic' : 'Referring Provider'} per lab</span>
      <small className="arwb-hint">This user will see only the claims of the {noun} chosen for each lab, and nothing in labs without one. Type to search the names on that lab&rsquo;s claims.</small>
      <div className="arwb-scope-grid">
        {labIds.map((id) => {
          const lab = labs.find((l) => l.labId === id);
          const c = choices[`${roleScope}|${id}`];
          const list = Array.isArray(c) ? c : [];
          const current = scopes[id] || '';
          const options = current && !list.includes(current) ? [current, ...list] : list;
          return (
            <div key={id} className="arwb-field">
              <label htmlFor={`u-scope-${id}`}>{lab?.labName || `Lab ${id}`}</label>
              {c?.error
                ? <small className="text-critical">{c.error}</small>
                : (
                  <SearchSelect id={`u-scope-${id}`} options={options} value={current} loading={!Array.isArray(c)} disabled={!Array.isArray(c)}
                    placeholder={`Search ${noun}…`} onChange={(v) => onChange({ ...scopes, [id]: v })} />
                )}
              {Array.isArray(c) && <small className="arwb-hint">{list.length.toLocaleString()} {noun}{list.length === 1 ? '' : 's'} on this lab&rsquo;s claims</small>}
            </div>
          );
        })}
      </div>
    </div>
  );
}

/** The API body for scopes, from the form's { [labId]: value } map. */
export function scopesBody(roleScope, labIds, scopes) {
  if (!roleScope) return [];
  return labIds.map((id) => (roleScope === 'clinic' ? { labId: id, clinicName: scopes[id] } : { labId: id, providerName: scopes[id] }));
}
