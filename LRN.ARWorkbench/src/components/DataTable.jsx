import { useEffect, useRef, useState } from 'react';
import Icon from './Icon';
import { downloadText, fmt, toCsv } from '../utils/format';

function readHidden(storageKey) {
  try { return new Set(JSON.parse(localStorage.getItem(storageKey) || '[]')); } catch { return new Set(); }
}

function writeHidden(storageKey, hidden) {
  try { localStorage.setItem(storageKey, JSON.stringify([...hidden])); } catch { /* per-session only */ }
}

/**
 * Gives every column listed in sortKeys ({ columnKey: apiSortKey }) a sort key, leaving columns that
 * already have one alone. The API sorts by that key across every page - never just the rows on screen.
 */
export function withSortKeys(columns, sortKeys) {
  return columns.map((c) => (c.sortKey || !sortKeys[c.key] ? c : { ...c, sortKey: sortKeys[c.key] }));
}

// Every table offers the same page sizes; screens default to 50.
export const PAGE_SIZES = [50, 100, 500, 1000];
export const DEFAULT_PAGE_SIZE = 50;

/**
 * The one table component every queue uses (server-side paging and sorting), in the mockup's
 * App.createTable markup: toolbar (record count, Columns, Export), a bounded scroll box with a
 * sticky header, and the Prev / Next + Rows per page footer.
 *
 * columns: [{ key, label, sortKey?, render?(row), csv?(row), align?: 'end', wrap?, defaultHidden? }]
 *
 * Selection (opt-in): selectable + selectedKeys (a Set of rowKey values, kept by the caller so a
 * selection survives paging) + onSelectionChange(nextSet). The header box selects this page.
 */
function SelectAll({ checked, indeterminate, onChange, disabled }) {
  const ref = useRef(null);
  useEffect(() => { if (ref.current) ref.current.indeterminate = indeterminate; }, [indeterminate]);
  return <input ref={ref} type="checkbox" aria-label="Select every row on this page" checked={checked} disabled={disabled} onChange={onChange} />;
}

export default function DataTable({
  tableId, columns, rows, totalCount, page, pageSize, sortBy, sortDesc,
  onSort, onPage, onPageSize, onRowClick, loading, emptyText = 'No records match the current filters.',
  exportName = 'export', toolbar, rowKey = (r, i) => r.claimKey ?? i,
  selectable = false, selectedKeys, onSelectionChange
}) {
  const storageKey = `lrn.arwb.cols.${tableId}`;
  const [hidden, setHidden] = useState(() => {
    const stored = readHidden(storageKey);
    return stored.size ? stored : new Set(columns.filter((c) => c.defaultHidden).map((c) => c.key));
  });
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef(null);

  useEffect(() => {
    if (!menuOpen) return undefined;
    const close = (e) => { if (menuRef.current && !menuRef.current.contains(e.target)) setMenuOpen(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [menuOpen]);

  const visible = columns.filter((c) => !hidden.has(c.key));
  const total = totalCount || 0;
  const pageCount = Math.max(1, Math.ceil(total / pageSize));
  const firstRow = total ? (page - 1) * pageSize + 1 : 0;
  const lastRow = Math.min(page * pageSize, total);

  function toggle(key) {
    const next = new Set(hidden);
    if (next.has(key)) next.delete(key); else next.add(key);
    setHidden(next);
    writeHidden(storageKey, next);
  }

  const selected = selectedKeys || new Set();
  const pageKeys = rows.map((r, i) => rowKey(r, i));
  const pageSelected = pageKeys.filter((k) => selected.has(k)).length;
  const colCount = visible.length + (selectable ? 1 : 0);

  function toggleRow(key) {
    const next = new Set(selected);
    if (next.has(key)) next.delete(key); else next.add(key);
    onSelectionChange?.(next);
  }

  function togglePage() {
    const next = new Set(selected);
    if (pageSelected === pageKeys.length) pageKeys.forEach((k) => next.delete(k));
    else pageKeys.forEach((k) => next.add(k));
    onSelectionChange?.(next);
  }

  function exportCsv() {
    const stamp = new Date().toISOString().slice(0, 10);
    downloadText(`${exportName}_${stamp}.csv`, toCsv(visible, rows));
  }

  return (
    <div className="arwb-table-card">
      <div className="arwb-table-toolbar">
        <span className="arwb-hint">
          {loading ? 'Loading…' : `${fmt.count(total)} record${total === 1 ? '' : 's'}${total > pageSize ? ` · showing ${fmt.count(firstRow)}–${fmt.count(lastRow)}` : ''}`}
        </span>
        {selectable && selected.size > 0 && (
          <span className="arwb-badge arwb-badge-accent">
            {fmt.count(selected.size)} selected
            <button type="button" className="arwb-badge-clear" onClick={() => onSelectionChange?.(new Set())} aria-label="Clear selection">×</button>
          </span>
        )}
        <div className="grow" />
        {toolbar}
        <div style={{ position: 'relative' }} ref={menuRef}>
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => setMenuOpen((v) => !v)} aria-expanded={menuOpen}>
            <Icon name="filter" size={15} /> Columns
          </button>
          {menuOpen && (
            <div className="arwb-popover right">
              <div className="arwb-col-toggle-menu">
                {columns.map((c) => (
                  <label key={c.key}>
                    <input type="checkbox" checked={!hidden.has(c.key)} onChange={() => toggle(c.key)} /> {c.label}
                  </label>
                ))}
              </div>
            </div>
          )}
        </div>
        <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={exportCsv} disabled={!rows.length} title="Export the rows on this page (CSV)">
          <Icon name="doc" size={15} /> Export
        </button>
      </div>

      <div className="arwb-table-wrap">
        <table className="arwb-data-table">
          <thead>
            <tr>
              {selectable && (
                <th className="arwb-select-col" scope="col">
                  <SelectAll checked={pageKeys.length > 0 && pageSelected === pageKeys.length} indeterminate={pageSelected > 0 && pageSelected < pageKeys.length}
                    disabled={!pageKeys.length} onChange={togglePage} />
                </th>
              )}
              {visible.map((c) => {
                const active = c.sortKey && c.sortKey === sortBy;
                const cls = [c.align === 'end' ? 'num' : '', c.sortKey ? 'sortable' : '', active ? 'sorted' : ''].join(' ').trim();
                return (
                  <th key={c.key} className={cls} scope="col"
                    aria-sort={active ? (sortDesc ? 'descending' : 'ascending') : undefined}
                    onClick={c.sortKey ? () => onSort(c.sortKey, active ? !sortDesc : true) : undefined}>
                    {c.label}
                    {c.sortKey && <span className="arwb-sort-arrow">{active ? (sortDesc ? '▼' : '▲') : '↕'}</span>}
                  </th>
                );
              })}
            </tr>
          </thead>
          <tbody>
            {!loading && rows.length === 0 && (
              <tr><td colSpan={colCount}><div className="arwb-empty-state"><Icon name="search" /><div>{emptyText}</div></div></td></tr>
            )}
            {rows.map((row, i) => {
              const key = rowKey(row, i);
              const isSelected = selectable && selected.has(key);
              return (
              <tr key={key} onClick={onRowClick ? () => onRowClick(row) : undefined}
                className={[onRowClick ? 'clickable' : '', isSelected ? 'selected' : ''].join(' ').trim() || undefined}>
                {selectable && (
                  <td className="arwb-select-col" onClick={(e) => e.stopPropagation()}>
                    <input type="checkbox" aria-label={`Select row ${i + 1}`} checked={isSelected} onChange={() => toggleRow(key)} />
                  </td>
                )}
                {visible.map((c) => (
                  <td key={c.key} className={[c.align === 'end' ? 'num' : '', c.wrap ? 'wrap' : ''].join(' ').trim() || undefined}>
                    {c.render ? c.render(row) : (row[c.key] ?? '—')}
                  </td>
                ))}
              </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <div className="arwb-pagination">
        <button type="button" className="arwb-btn arwb-btn-sm" disabled={page <= 1 || loading} onClick={() => onPage(1)} title="First page" aria-label="First page">« First</button>
        <button type="button" className="arwb-btn arwb-btn-sm" disabled={page <= 1 || loading} onClick={() => onPage(page - 1)} aria-label="Previous page">‹ Prev</button>
        <span>Page {fmt.count(page)} of {fmt.count(pageCount)}</span>
        <button type="button" className="arwb-btn arwb-btn-sm" disabled={page >= pageCount || loading} onClick={() => onPage(page + 1)} aria-label="Next page">Next ›</button>
        <button type="button" className="arwb-btn arwb-btn-sm" disabled={page >= pageCount || loading} onClick={() => onPage(pageCount)} title="Last page" aria-label="Last page">Last »</button>
        <span className="grow" />
        {onPageSize && (
          <span className="arwb-hint">
            <label htmlFor={`ps-${tableId}`}>Rows per page</label>
            <select id={`ps-${tableId}`} className="arwb-select arwb-select-inline" value={pageSize} onChange={(e) => onPageSize(Number(e.target.value))}>
              {(PAGE_SIZES.includes(pageSize) ? PAGE_SIZES : [...PAGE_SIZES, pageSize].sort((a, b) => a - b)).map((n) => <option key={n} value={n}>{fmt.count(n)}</option>)}
            </select>
          </span>
        )}
      </div>
    </div>
  );
}
