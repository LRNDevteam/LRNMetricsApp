import { useEffect, useMemo, useRef, useState } from 'react';
import Icon from './Icon';
import { fmt } from '../utils/format';

/**
 * The mockup's multi-select filter (App.multiSelectField / App.wireMultiSelect): a labelled button
 * showing "All", the one value, or "n selected", opening a popover with an "All" box and one box per
 * option. Ticking "All" clears the selection. Long lists get a search box.
 *
 * options: [{ value, label, count? }]   selected: string[] of values   onChange(values)
 */
export default function MultiSelect({ id, label, options, selected, onChange, searchable }) {
  const [open, setOpen] = useState(false);
  const [term, setTerm] = useState('');
  const ref = useRef(null);
  const sel = useMemo(() => new Set(selected), [selected]);

  useEffect(() => {
    if (!open) return undefined;
    const close = (e) => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    const esc = (e) => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', close);
    document.addEventListener('keydown', esc);
    return () => { document.removeEventListener('mousedown', close); document.removeEventListener('keydown', esc); };
  }, [open]);

  useEffect(() => { if (!open) setTerm(''); }, [open]);

  const labelOf = (value) => options.find((o) => o.value === value)?.label ?? value;
  const summary = selected.length === 0 ? 'All' : selected.length === 1 ? labelOf(selected[0]) : `${selected.length} selected`;
  const showSearch = searchable ?? options.length > 12;
  const shown = term ? options.filter((o) => o.label.toLowerCase().includes(term.toLowerCase())) : options;

  function toggle(value) {
    const next = new Set(sel);
    if (next.has(value)) next.delete(value); else next.add(value);
    onChange([...next]);
  }

  return (
    <div className="arwb-field" ref={ref}>
      <label htmlFor={`ms-${id}`}>{label}</label>
      <button id={`ms-${id}`} type="button" className="arwb-btn arwb-btn-sm arwb-ms-toggle" aria-haspopup="listbox" aria-expanded={open}
        onClick={() => setOpen((v) => !v)} title={selected.length > 1 ? selected.map(labelOf).join(', ') : undefined}>
        <span>{summary}</span><Icon name="chevronDown" size={15} />
      </button>
      {open && (
        <div className="arwb-popover" role="listbox" aria-multiselectable="true">
          {showSearch && (
            <input className="arwb-input" type="search" placeholder={`Search ${label.toLowerCase()}…`} value={term} autoFocus
              onChange={(e) => setTerm(e.target.value)} />
          )}
          <div className="arwb-col-toggle-menu">
            <label className="all">
              <input type="checkbox" checked={selected.length === 0} onChange={(e) => { if (e.target.checked) { onChange([]); setOpen(false); } }} /> All
            </label>
            {shown.map((o) => (
              <label key={o.value}>
                <input type="checkbox" checked={sel.has(o.value)} onChange={() => toggle(o.value)} />
                <span>{o.label}</span>
                {o.count !== undefined && <span className="arwb-ms-count">{fmt.count(o.count)}</span>}
              </label>
            ))}
            {shown.length === 0 && <span className="arwb-hint">No matches</span>}
          </div>
        </div>
      )}
    </div>
  );
}
