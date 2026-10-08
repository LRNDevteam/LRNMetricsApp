import { useMemo, useState } from 'react';

// Strings compare case-insensitively and numerically ("Line 10" after "Line 9"); blanks sort last.
const collator = new Intl.Collator('en-US', { numeric: true, sensitivity: 'base' });
function compare(a, b) {
  const blankA = a === null || a === undefined || a === '';
  const blankB = b === null || b === undefined || b === '';
  if (blankA || blankB) return blankA === blankB ? 0 : blankA ? 1 : -1;
  if (typeof a === 'number' && typeof b === 'number') return a - b;
  if (typeof a === 'boolean' && typeof b === 'boolean') return Number(a) - Number(b);
  return collator.compare(String(a), String(b));
}

/**
 * Click-to-sort for the plain tables (claim tabs, dashboard, reports, settings) that show every
 * row at once - the DataTable component handles the paged, server-sorted lists.
 *
 * getters: { columnKey: (row) => value }. Returns the sorted rows and th(key, label, props),
 * a header cell in the same style as DataTable's (▲ / ▼ / ↕, aria-sort). A column with no getter
 * renders as a plain header. Blanks always sort last.
 */
export default function useTableSort(rows, getters, initial = { key: null, desc: false }) {
  const [sort, setSort] = useState(initial);

  const sorted = useMemo(() => {
    const get = sort.key && getters[sort.key];
    if (!get || !rows) return rows || [];
    return [...rows].sort((x, y) => {
      const a = get(x);
      const b = get(y);
      const blank = (v) => v === null || v === undefined || v === '';
      if (blank(a) || blank(b)) return compare(a, b);      // blanks last in both directions
      return sort.desc ? -compare(a, b) : compare(a, b);
    });
  }, [rows, sort]); // eslint-disable-line react-hooks/exhaustive-deps

  function th(key, label, { className = '', ...props } = {}) {
    if (!getters[key]) return <th key={key} scope="col" className={className || undefined} {...props}>{label}</th>;
    const active = sort.key === key;
    const toggle = () => setSort((s) => (s.key === key ? { key, desc: !s.desc } : { key, desc: false }));
    return (
      <th key={key} scope="col" className={['sortable', active ? 'sorted' : '', className].join(' ').trim()}
        aria-sort={active ? (sort.desc ? 'descending' : 'ascending') : undefined}
        tabIndex={0} onClick={toggle} onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(); } }} {...props}>
        {label}<span className="arwb-sort-arrow">{active ? (sort.desc ? '▼' : '▲') : '↕'}</span>
      </th>
    );
  }

  return { rows: sorted, th, sort };
}
