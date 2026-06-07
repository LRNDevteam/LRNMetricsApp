import React, { useEffect, useMemo, useRef, useState } from 'react';

const multiValueDelimiterPattern = new RegExp('\\u00ac|\\u00c2\\u00ac|\\u00c3\\u0082\\u00c2\\u00ac');

function toArray(value) {
  if (Array.isArray(value)) return value.filter(Boolean).map(String);
  if (value === undefined || value === null || value === '') return [];
  return String(value).split(multiValueDelimiterPattern).map(x => x.trim()).filter(Boolean);
}

function uniqueOptions(options) {
  const seen = new Set();
  return (options || [])
    .map(x => {
      if (typeof x === 'string') return { value: x, label: x };
      return { value: String(x?.value ?? x?.userName ?? ''), label: String(x?.label ?? x?.displayName ?? x?.userName ?? '') };
    })
    .filter(x => x.value && !seen.has(x.value) && seen.add(x.value));
}

export default function SearchableMultiSelect({ label, value, options, onChange, placeholder = 'All', className = '' }) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState('');
  const rootRef = useRef(null);
  const selected = useMemo(() => toArray(value), [value]);
  const optionRows = useMemo(() => uniqueOptions(options), [options]);
  const labelMap = useMemo(() => new Map(optionRows.map(x => [x.value, x.label || x.value])), [optionRows]);

  useEffect(() => {
    function closeOnOutside(e) {
      if (rootRef.current && !rootRef.current.contains(e.target)) setOpen(false);
    }
    document.addEventListener('mousedown', closeOnOutside);
    return () => document.removeEventListener('mousedown', closeOnOutside);
  }, []);

  const sortedRows = useMemo(() => {
    const selectedSet = new Set(selected);
    const q = search.trim().toLowerCase();
    return optionRows
      .filter(x => !q || x.label.toLowerCase().includes(q) || x.value.toLowerCase().includes(q))
      .sort((a, b) => {
        const as = selectedSet.has(a.value) ? 0 : 1;
        const bs = selectedSet.has(b.value) ? 0 : 1;
        if (as !== bs) return as - bs;
        return a.label.localeCompare(b.label);
      });
  }, [optionRows, search, selected]);

  function toggle(nextValue) {
    const exists = selected.includes(nextValue);
    const next = exists ? selected.filter(x => x !== nextValue) : [...selected, nextValue];
    onChange(next);
  }

  function clear(e) {
    e.stopPropagation();
    onChange([]);
    setSearch('');
  }

  const firstLabel = selected.length ? (labelMap.get(selected[0]) || selected[0]) : placeholder;

  return <div className={`ms-field ${className}`} ref={rootRef}>
    {label && <label>{label}</label>}
    <button type="button" className={`ms-control ${open ? 'open' : ''}`} onClick={() => setOpen(x => !x)} title={selected.map(x => labelMap.get(x) || x).join(', ')}>
      <span className={selected.length ? 'ms-selected-text' : 'ms-placeholder'}>{firstLabel}</span>
      {selected.length > 1 && <span className="ms-count">+{selected.length - 1}</span>}
      {selected.length > 0 && <span className="ms-clear" onClick={clear}>x</span>}
      <span className="ms-caret">v</span>
    </button>
    {open && <div className="ms-menu">
      <input className="ms-search" autoFocus value={search} onChange={e => setSearch(e.target.value)} placeholder="Search..." />
      <div className="ms-options">
        {sortedRows.length ? sortedRows.map(x => <label className={`ms-option ${selected.includes(x.value) ? 'selected' : ''}`} key={x.value}>
          <input type="checkbox" checked={selected.includes(x.value)} onChange={() => toggle(x.value)} />
          <span>{x.label}</span>
        </label>) : <div className="ms-empty">No matching options</div>}
      </div>
    </div>}
  </div>;
}

export { toArray as multiSelectToArray };
