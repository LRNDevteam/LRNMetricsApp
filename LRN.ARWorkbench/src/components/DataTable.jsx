import { useEffect, useRef, useState } from 'react';
import { downloadText, fmt, toCsv } from '../utils/format';

function readHidden(storageKey) {
  try { return new Set(JSON.parse(localStorage.getItem(storageKey) || '[]')); } catch { return new Set(); }
}

function writeHidden(storageKey, hidden) {
  try { localStorage.setItem(storageKey, JSON.stringify([...hidden])); } catch { /* per-session only */ }
}

/**
 * The one table component every queue uses (server-side paging and sorting).
 * Gives each screen, for free: sortable headers, pager, column show/hide (remembered per table),
 * and CSV export of exactly the rows and columns on screen.
 *
 * columns: [{ key, label, sortKey?, render?(row), csv?(row), align?, defaultHidden? }]
 */
export default function DataTable({
  tableId, columns, rows, totalCount, page, pageSize, sortBy, sortDesc,
  onSort, onPage, onRowClick, loading, emptyText = 'No claims match these filters.', exportName = 'export', toolbar
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
  const pageCount = Math.max(1, Math.ceil((totalCount || 0) / pageSize));
  const firstRow = totalCount ? (page - 1) * pageSize + 1 : 0;
  const lastRow = Math.min(page * pageSize, totalCount || 0);

  function toggle(key) {
    const next = new Set(hidden);
    if (next.has(key)) next.delete(key); else next.add(key);
    setHidden(next);
    writeHidden(storageKey, next);
  }

  function exportCsv() {
    const stamp = new Date().toISOString().slice(0, 10);
    downloadText(`${exportName}_${stamp}.csv`, toCsv(visible, rows));
  }

  return (
    <div className="arwb-table-card">
      <div className="arwb-table-toolbar">
        <div className="text-secondary small">
          {loading ? 'Loading…' : `${fmt.count(firstRow)}–${fmt.count(lastRow)} of ${fmt.count(totalCount || 0)}`}
        </div>
        <div className="ms-auto d-flex gap-2 align-items-center">
          {toolbar}
          <div className="position-relative" ref={menuRef}>
            <button type="button" className="btn btn-sm btn-outline-secondary" onClick={() => setMenuOpen((v) => !v)}>
              <i className="bi bi-layout-three-columns me-1" />Columns
            </button>
            {menuOpen && (
              <div className="arwb-col-menu shadow-sm">
                {columns.map((c) => (
                  <label key={c.key} className="form-check small mb-1">
                    <input type="checkbox" className="form-check-input" checked={!hidden.has(c.key)} onChange={() => toggle(c.key)} />
                    <span className="form-check-label">{c.label}</span>
                  </label>
                ))}
              </div>
            )}
          </div>
          <button type="button" className="btn btn-sm btn-outline-secondary" onClick={exportCsv} disabled={!rows.length} title="Export the rows on screen">
            <i className="bi bi-download me-1" />CSV
          </button>
        </div>
      </div>

      <div className="table-responsive">
        <table className="table table-hover table-sm align-middle mb-0 arwb-table">
          <thead>
            <tr>
              {visible.map((c) => {
                const active = c.sortKey && c.sortKey === sortBy;
                return (
                  <th key={c.key} className={c.align === 'end' ? 'text-end' : ''} scope="col">
                    {c.sortKey ? (
                      <button type="button" className="arwb-sort" onClick={() => onSort(c.sortKey, active ? !sortDesc : true)}>
                        {c.label}
                        <i className={`bi ms-1 ${active ? (sortDesc ? 'bi-caret-down-fill' : 'bi-caret-up-fill') : 'bi-chevron-expand text-body-tertiary'}`} />
                      </button>
                    ) : c.label}
                  </th>
                );
              })}
            </tr>
          </thead>
          <tbody>
            {!loading && rows.length === 0 && (
              <tr><td colSpan={visible.length} className="text-center text-secondary py-5">{emptyText}</td></tr>
            )}
            {rows.map((row, i) => (
              <tr key={row.claimKey ?? i} onClick={onRowClick ? () => onRowClick(row) : undefined} className={onRowClick ? 'arwb-clickable' : ''}>
                {visible.map((c) => (
                  <td key={c.key} className={c.align === 'end' ? 'text-end text-nowrap' : ''}>
                    {c.render ? c.render(row) : (row[c.key] ?? '—')}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="arwb-table-footer">
        <button type="button" className="btn btn-sm btn-outline-secondary" disabled={page <= 1 || loading} onClick={() => onPage(page - 1)}>
          <i className="bi bi-chevron-left" />
        </button>
        <span className="small text-secondary">Page {fmt.count(page)} of {fmt.count(pageCount)}</span>
        <button type="button" className="btn btn-sm btn-outline-secondary" disabled={page >= pageCount || loading} onClick={() => onPage(page + 1)}>
          <i className="bi bi-chevron-right" />
        </button>
      </div>
    </div>
  );
}
