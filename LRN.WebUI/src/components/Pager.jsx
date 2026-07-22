import React from 'react';

const PAGE_SIZES = [25, 50, 100];

// Pager with a Rows-per-page selector. The size dropdown shows whenever there are rows (even a
// single page); the Previous/Next nav shows only when there is more than one page.
export default function Pager({ data, changePage, changePageSize, pageSize }) {
  const total = Number(data?.totalCount || 0);
  const totalPages = Number(data?.totalPages || 0);
  if (!total) return null;

  const page = Number(data?.page || 1);
  const size = Number(pageSize || data?.pageSize || 50);
  const from = total === 0 ? 0 : (page - 1) * size + 1;
  const to = Math.min(page * size, total);

  return <div className="pager">
    {changePageSize && <label className="pager-size">Rows
      <select value={PAGE_SIZES.includes(size) ? size : 50} onChange={e => changePageSize(Number(e.target.value))}>
        {PAGE_SIZES.map(s => <option key={s} value={s}>{s}</option>)}
      </select>
    </label>}
    <span className="pager-range">{from.toLocaleString()}–{to.toLocaleString()} of {total.toLocaleString()}</span>
    {totalPages > 1 && <>
      <button className="topbar-btn" disabled={page <= 1} onClick={() => changePage(1)} title="First page">«</button>
      <button className="topbar-btn" disabled={page <= 1} onClick={() => changePage(page - 1)}>Previous</button>
      <span>Page {page} of {totalPages}</span>
      <button className="topbar-btn" disabled={page >= totalPages} onClick={() => changePage(page + 1)}>Next</button>
      <button className="topbar-btn" disabled={page >= totalPages} onClick={() => changePage(totalPages)} title="Last page">»</button>
    </>}
  </div>;
}
