import React, { useEffect, useMemo, useRef, useState } from 'react';
import { denialWorkflowService } from '../services/denialWorkflowService';

// Jobs Center: background upload + download (export) tracking.
// - JobsBadge lives in the topbar: badge count of active jobs + dropdown of recent jobs.
// - JobsPage is the full "Uploads & Downloads" page: tabbed job history with sorting and a
//   date filter, upload detail popup with the per-row results table, and log/file downloads.
// The upload modal enqueues and closes immediately; these components are how the user
// follows progress afterwards. `lrn-jobs-refresh` (window event) forces an immediate poll.

const isActive = s => ['queued', 'running'].includes(String(s || '').toLowerCase());
const isSuccessRow = s => String(s || '').toLowerCase() === 'success';

function statusChip(status) {
  const s = String(status || '').toLowerCase();
  if (s === 'downloaded') return <span className="jobs-chip downloaded"><i className="bi bi-check2-all" />Downloaded</span>;
  const cls = s === 'completed' ? 'ok' : s === 'failed' ? 'fail' : 'run';
  return <span className={`jobs-chip ${cls}`}>{isActive(s) ? <i className="bi bi-arrow-repeat jobs-spin" /> : null}{status || '-'}</span>;
}

function fmtTime(value) {
  if (!value) return '-';
  const d = new Date(value);
  return Number.isFinite(d.getTime()) ? d.toLocaleString() : '-';
}

function stampName(base, createdOnUtc, extension) {
  const d = new Date(createdOnUtc || Date.now());
  const pad = n => String(n).padStart(2, '0');
  const stamp = Number.isFinite(d.getTime())
    ? `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}_${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`
    : '';
  const clean = String(base || 'file').replace(/\.[^.]+$/, '').replace(/[\\/:*?"<>|]+/g, '_');
  return `${clean}${stamp ? `_${stamp}` : ''}${extension}`;
}

// apiUrl() fetches with the JWT and resolves to a blob URL; a blob URL carries no
// content-disposition, so set a.download or the browser saves it under a random GUID name.
async function saveFile(urlPromise, fileName, setMessage) {
  try {
    const url = await urlPromise;
    const a = document.createElement('a');
    a.href = url;
    a.download = fileName || 'download';
    document.body.appendChild(a);
    a.click();
    a.remove();
  } catch (e) {
    setMessage?.({ type: 'danger', text: e.message || 'Unable to download the file.' });
  }
}

function downloadExportFile(job, setMessage) {
  const name = job.fileName || stampName('Claim_Export', job.createdOnUtc, '.xlsx');
  return saveFile(denialWorkflowService.getClaimsExportDownloadUrl(job.jobId), name, setMessage);
}

function downloadUploadLog(job, setMessage) {
  const name = stampName(`UploadLog_${job.fileName || 'claims'}`, job.createdOnUtc, '.csv');
  return saveFile(denialWorkflowService.getUploadLogUrl(job.jobId), name, setMessage);
}

async function fetchJobs() {
  const [uploads, exports] = await Promise.all([
    denialWorkflowService.listUploadJobs().catch(() => []),
    denialWorkflowService.listExportJobs().catch(() => [])
  ]);
  return {
    uploads: uploads || [],
    exports: exports || [],
    activeCount: (uploads || []).filter(j => isActive(j.status)).length + (exports || []).filter(j => isActive(j.status)).length
  };
}

// ── Topbar badge + dropdown ─────────────────────────────────────────────────
export function JobsBadge({ enabled = true, onOpenJobs = () => {}, setMessage = () => {}, onUploadCompleted = () => {} }) {
  const [open, setOpen] = useState(false);
  const [jobs, setJobs] = useState({ uploads: [], exports: [], activeCount: 0 });
  const prevStatusRef = useRef({});
  const wrapRef = useRef(null);

  useEffect(() => {
    if (!enabled) return;
    let cancelled = false;
    const poll = async () => {
      const next = await fetchJobs();
      if (cancelled) return;
      // Toast + grid refresh when an upload we saw active finishes.
      const prev = prevStatusRef.current;
      for (const j of next.uploads) {
        const before = prev[j.jobId];
        if (before && isActive(before) && !isActive(j.status)) {
          if (String(j.status).toLowerCase() === 'completed') {
            setMessage({ type: j.failureCount > 0 ? 'warning' : 'success', text: `Upload "${j.fileName}" finished: ${j.successCount} success, ${j.failureCount} failed. Open Uploads & Downloads for details.` });
            onUploadCompleted(j);
          } else {
            setMessage({ type: 'danger', text: `Upload "${j.fileName}" failed. Open Uploads & Downloads for details.` });
          }
        }
      }
      prevStatusRef.current = Object.fromEntries([...next.uploads, ...next.exports].map(j => [j.jobId, j.status]));
      setJobs(next);
    };
    poll();
    // Poll faster while something is in flight so completion toasts arrive promptly.
    const timer = window.setInterval(poll, jobs.activeCount > 0 ? 5000 : 20000);
    const onRefresh = () => poll();
    window.addEventListener('lrn-jobs-refresh', onRefresh);
    return () => { cancelled = true; window.clearInterval(timer); window.removeEventListener('lrn-jobs-refresh', onRefresh); };
  }, [enabled, jobs.activeCount]);

  useEffect(() => {
    if (!open) return;
    const onDoc = e => { if (wrapRef.current && !wrapRef.current.contains(e.target)) setOpen(false); };
    document.addEventListener('mousedown', onDoc);
    return () => document.removeEventListener('mousedown', onDoc);
  }, [open]);

  if (!enabled) return null;
  const recent = [
    ...jobs.uploads.map(j => ({ ...j, kind: 'upload' })),
    ...jobs.exports.map(j => ({ ...j, kind: 'download' }))
  ].sort((a, b) => new Date(b.createdOnUtc) - new Date(a.createdOnUtc)).slice(0, 8);

  return <div className="notification-wrap jobs-badge-wrap" ref={wrapRef}>
    <button type="button" className="notification-btn jobs-badge-btn" title="Uploads & downloads" onClick={() => setOpen(v => !v)}>
      <i className="bi bi-arrow-down-up" />
      {jobs.activeCount > 0
        ? <span className="notification-count jobs-badge-count">{jobs.activeCount}</span>
        : null}
      <span className="notification-text jobs-badge-text">{jobs.activeCount > 0 ? <><b>{jobs.activeCount}</b> job(s) running</> : 'Jobs'}</span>
    </button>
    {open && <div className="jobs-dropdown">
      <div className="jobs-dropdown-hd"><strong>Uploads &amp; Downloads</strong><span>{jobs.activeCount > 0 ? `${jobs.activeCount} in progress` : 'All done'}</span></div>
      <div className="jobs-dropdown-list">
        {recent.length ? recent.map(j => <div className="jobs-row" key={`${j.kind}-${j.jobId}`}>
          <i className={`bi ${j.kind === 'upload' ? 'bi-upload' : 'bi-download'} jobs-row-icon ${j.kind}`} />
          <div className="jobs-row-main">
            <div className="jobs-row-title" title={j.fileName}>{j.fileName || (j.kind === 'upload' ? 'Claim upload' : 'Claim export')}</div>
            <div className="jobs-row-meta">{fmtTime(j.createdOnUtc)}{j.kind === 'upload' && !isActive(j.status) ? ` · ${j.successCount} ok / ${j.failureCount} failed` : ''}{j.kind === 'download' && j.rowCount ? ` · ${Number(j.rowCount).toLocaleString()} rows` : ''}</div>
          </div>
          {statusChip(j.status)}
          {j.kind === 'download' && j.downloadUrl && <button type="button" className="jobs-icon-btn" title="Download file" onClick={() => downloadExportFile(j, setMessage)}><i className="bi bi-download" /></button>}
          {j.kind === 'upload' && String(j.status).toLowerCase() === 'completed' && <button type="button" className="jobs-icon-btn" title="View results" onClick={() => { setOpen(false); onOpenJobs(j.jobId); }}><i className="bi bi-list-check" /></button>}
        </div>) : <div className="jobs-empty">No uploads or downloads yet.</div>}
      </div>
      <button type="button" className="jobs-dropdown-ft" onClick={() => { setOpen(false); onOpenJobs(); }}>View all uploads &amp; downloads</button>
    </div>}
  </div>;
}

// ── Upload detail popup (summary + per-row results + log download) ──────────
function UploadDetailModal({ jobId, onClose, setMessage }) {
  const [detail, setDetail] = useState(null);
  const [error, setError] = useState('');

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const status = await denialWorkflowService.getUploadStatus(jobId);
        if (!cancelled) setDetail(status);
      } catch (e) {
        if (!cancelled) setError(e.message || 'Unable to load upload details.');
      }
    })();
    return () => { cancelled = true; };
  }, [jobId]);

  const result = detail?.result;
  const rows = result?.results || [];
  return <div className="modal-backdrop" onClick={onClose}>
    <div className="note-modal csv-upload-modal" onClick={e => e.stopPropagation()}>
      <div className="note-modal-hd">
        <div><strong>Upload results</strong><small>{detail?.fileName || jobId} · {fmtTime(detail?.createdOnUtc)}</small></div>
        <button className="modal-close" onClick={onClose}>×</button>
      </div>
      <div className="note-modal-body">
        {error && <div className="csv-upload-error"><i className="bi bi-exclamation-circle" /> {error}</div>}
        {!detail && !error && <div className="csv-upload-loading"><i className="bi bi-arrow-repeat csv-upload-spinner" /><strong>Loading upload details…</strong></div>}
        {detail && isActive(detail.status) && <div className="csv-upload-loading"><i className="bi bi-arrow-repeat csv-upload-spinner" /><strong>Upload is still processing…</strong><span>{detail.message}</span></div>}
        {detail && !isActive(detail.status) && !result && <div className="info-strip">{detail.message || 'No per-row results are available for this upload.'}</div>}
        {result && <>
          <div className="csv-upload-summary">
            <span className="csv-sum-badge total">Total {result.totalRows}</span>
            <span className="csv-sum-badge success">Success {result.successCount}</span>
            <span className="csv-sum-badge failed">Failed {result.failureCount}</span>
            {result.skippedRows > 0 ? <span className="csv-sum-badge skipped">Skipped {result.skippedRows}</span> : null}
          </div>
          <div className="csv-upload-results-scroll">
            <table className="csv-upload-results-table">
              <thead><tr><th>Row</th><th>Claim</th><th>Result</th><th>Action</th><th>Status change</th><th>Value changes</th><th>Note</th><th>Reason</th></tr></thead>
              <tbody>
                {rows.length ? rows.map((r, i) => <tr key={`${r.rowNumber}-${i}`} className={isSuccessRow(r.status) ? 'row-ok' : 'row-fail'}>
                  <td>{r.rowNumber}</td>
                  <td>{r.claimId || '-'}{r.taskId ? <small> · {r.taskId}</small> : null}</td>
                  <td><span className={`csv-row-badge ${isSuccessRow(r.status) ? 'ok' : 'fail'}`}>{isSuccessRow(r.status) ? 'Success' : 'Failed'}</span></td>
                  <td>{r.action || '—'}</td>
                  <td>{isSuccessRow(r.status) && r.newStatus && r.newStatus !== r.oldStatus ? <span className="csv-status-change">{r.oldStatus || '—'} → <b>{r.newStatus}</b></span> : '—'}</td>
                  <td>{(r.changedValues || []).length ? <ul className="csv-change-list">{r.changedValues.map((c, k) => <li key={k}><span className="csv-change-field">{c.field}:</span> {c.oldValue ? `${c.oldValue} → ` : ''}<b>{c.newValue}</b></li>)}</ul> : '—'}</td>
                  <td className="csv-note-cell" title={r.note || ''}>{r.note || '—'}</td>
                  <td className="csv-reason-cell">{isSuccessRow(r.status) ? '—' : (r.failureReason || 'Failed')}</td>
                </tr>) : <tr><td colSpan={8} className="csv-empty">No actionable claim rows were found in the file.</td></tr>}
              </tbody>
            </table>
          </div>
        </>}
      </div>
      <div className="note-modal-ft">
        {detail?.downloadUrl && <button className="wl-btn" type="button" onClick={() => downloadUploadLog(detail, setMessage)}><i className="bi bi-file-earmark-arrow-down" /> Download log</button>}
        <button className="wl-btn teal" type="button" onClick={onClose}>Close</button>
      </div>
    </div>
  </div>;
}

// ── Full "Uploads & Downloads" page ─────────────────────────────────────────
const uploadSorters = {
  fileName: j => String(j.fileName || '').toLowerCase(),
  createdOnUtc: j => new Date(j.createdOnUtc || 0).getTime(),
  status: j => String(j.status || '').toLowerCase(),
  totalRows: j => Number(j.totalRows || 0),
  successCount: j => Number(j.successCount || 0),
  failureCount: j => Number(j.failureCount || 0),
  completedOnUtc: j => new Date(j.completedOnUtc || 0).getTime()
};
const exportSorters = {
  fileName: j => String(j.fileName || '').toLowerCase(),
  createdOnUtc: j => new Date(j.createdOnUtc || 0).getTime(),
  status: j => String(j.status || '').toLowerCase(),
  rowCount: j => Number(j.rowCount || 0),
  completedOnUtc: j => new Date(j.completedOnUtc || 0).getTime()
};

function sortRows(rows, sorters, sort) {
  const getter = sorters[sort.key];
  if (!getter) return rows;
  const sorted = [...rows].sort((a, b) => {
    const av = getter(a); const bv = getter(b);
    if (av < bv) return -1;
    if (av > bv) return 1;
    return 0;
  });
  return sort.dir === 'desc' ? sorted.reverse() : sorted;
}

function inDateRange(job, fromDate, toDate) {
  if (!fromDate && !toDate) return true;
  const t = new Date(job.createdOnUtc || 0);
  if (!Number.isFinite(t.getTime())) return true;
  if (fromDate && t < new Date(`${fromDate}T00:00:00`)) return false;
  if (toDate && t > new Date(`${toDate}T23:59:59.999`)) return false;
  return true;
}

export function JobsPage({ setMessage = () => {}, initialUploadJobId = '' }) {
  const [jobs, setJobs] = useState({ uploads: [], exports: [], activeCount: 0 });
  const [loading, setLoading] = useState(true);
  const [tab, setTab] = useState(initialUploadJobId ? 'uploads' : 'uploads');
  const [detailJobId, setDetailJobId] = useState(initialUploadJobId || '');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [sort, setSort] = useState({ key: 'createdOnUtc', dir: 'desc' });

  async function load() {
    const next = await fetchJobs();
    setJobs(next);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  // Keep refreshing while anything is running so statuses land without manual refresh.
  useEffect(() => {
    if (!jobs.activeCount) return;
    const timer = window.setInterval(load, 5000);
    return () => window.clearInterval(timer);
  }, [jobs.activeCount]);

  function toggleSort(key) {
    setSort(prev => prev.key === key ? { key, dir: prev.dir === 'asc' ? 'desc' : 'asc' } : { key, dir: 'asc' });
  }

  function SortTh({ sortKey, children, className = '' }) {
    const active = sort.key === sortKey;
    return <th className={`jobs-sort-th ${className}`} onClick={() => toggleSort(sortKey)}>
      <span>{children}<i className={`bi ${active ? (sort.dir === 'asc' ? 'bi-caret-up-fill' : 'bi-caret-down-fill') : 'bi-arrow-down-up'} jobs-sort-icon ${active ? 'active' : ''}`} /></span>
    </th>;
  }

  async function removeJob(kind, job) {
    const label = isActive(job.status) ? 'Cancel this job?' : `Remove "${job.fileName}" from the list?`;
    if (!window.confirm(label)) return;
    try {
      if (kind === 'upload') await denialWorkflowService.cancelUpload(job.jobId);
      else await denialWorkflowService.cancelClaimsExport(job.jobId);
      load();
    } catch (e) {
      setMessage({ type: 'danger', text: e.message || 'Unable to remove the job.' });
    }
  }

  const filteredUploads = useMemo(
    () => sortRows(jobs.uploads.filter(j => inDateRange(j, fromDate, toDate)), uploadSorters, sort),
    [jobs.uploads, fromDate, toDate, sort]);
  const filteredExports = useMemo(
    () => sortRows(jobs.exports.filter(j => inDateRange(j, fromDate, toDate)), exportSorters, sort),
    [jobs.exports, fromDate, toDate, sort]);

  return <>
    <div className="lrn-card jobs-page-card">
      <div className="jobs-tab-bar">
        <div className="jobs-tabs">
          <button type="button" className={`jobs-tab ${tab === 'uploads' ? 'active' : ''}`} onClick={() => { setTab('uploads'); setSort({ key: 'createdOnUtc', dir: 'desc' }); }}><i className="bi bi-upload" /> Uploads <b>{jobs.uploads.length}</b></button>
          <button type="button" className={`jobs-tab ${tab === 'downloads' ? 'active' : ''}`} onClick={() => { setTab('downloads'); setSort({ key: 'createdOnUtc', dir: 'desc' }); }}><i className="bi bi-download" /> Downloads <b>{jobs.exports.length}</b></button>
        </div>
        <div className="jobs-tab-tools">
          <label>From<input type="date" value={fromDate} max={toDate || undefined} onChange={e => setFromDate(e.target.value)} /></label>
          <label>To<input type="date" value={toDate} min={fromDate || undefined} onChange={e => setToDate(e.target.value)} /></label>
          {(fromDate || toDate) && <button type="button" className="wl-btn xs" onClick={() => { setFromDate(''); setToDate(''); }}>Clear</button>}
          <button type="button" className="wl-btn xs" onClick={load}><i className="bi bi-arrow-clockwise" /> Refresh</button>
        </div>
      </div>

      {tab === 'uploads' && <div className="dt-wrap">
        <table className="lrn-table workflow-table thin-bordered jobs-table">
          <thead><tr>
            <SortTh sortKey="fileName">Uploaded file</SortTh>
            <SortTh sortKey="createdOnUtc">Uploaded on</SortTh>
            <SortTh sortKey="status">Status</SortTh>
            <SortTh sortKey="totalRows" className="r">Total rows</SortTh>
            <SortTh sortKey="successCount" className="r">Success</SortTh>
            <SortTh sortKey="failureCount" className="r">Failed</SortTh>
            <SortTh sortKey="completedOnUtc">Completed on</SortTh>
            <th>Actions</th>
          </tr></thead>
          <tbody>
            {filteredUploads.length ? filteredUploads.map(j => <tr key={j.jobId} className="jobs-click-row" onClick={() => setDetailJobId(j.jobId)}>
              <td className="jobs-file-cell" title={j.fileName}><i className="bi bi-upload jobs-row-icon upload" /> {j.fileName || '-'}</td>
              <td>{fmtTime(j.createdOnUtc)}</td>
              <td>{statusChip(j.status)}</td>
              <td className="r">{j.totalRows ?? '-'}</td>
              <td className="r jobs-num-ok">{isActive(j.status) ? '…' : j.successCount}</td>
              <td className="r jobs-num-fail">{isActive(j.status) ? '…' : j.failureCount}</td>
              <td>{fmtTime(j.completedOnUtc)}</td>
              <td onClick={e => e.stopPropagation()}>
                <div className="jobs-actions">
                  <button type="button" className="jobs-icon-btn teal" title="View per-claim results" onClick={() => setDetailJobId(j.jobId)}><i className="bi bi-list-check" /></button>
                  {String(j.status).toLowerCase() === 'completed' && <button type="button" className="jobs-icon-btn" title="Download log" onClick={() => downloadUploadLog(j, setMessage)}><i className="bi bi-download" /></button>}
                  <button type="button" className="jobs-icon-btn danger" title={isActive(j.status) ? 'Cancel upload' : 'Remove from list'} onClick={() => removeJob('upload', j)}><i className={`bi ${isActive(j.status) ? 'bi-x-circle' : 'bi-trash3'}`} /></button>
                </div>
              </td>
            </tr>) : <tr><td colSpan={8} className="empty-cell">{loading ? 'Loading…' : (fromDate || toDate) ? 'No uploads in the selected date range.' : 'No uploads yet. Use Upload Template on Claim Assignment or My Worklist.'}</td></tr>}
          </tbody>
        </table>
      </div>}

      {tab === 'downloads' && <div className="dt-wrap">
        <table className="lrn-table workflow-table thin-bordered jobs-table">
          <thead><tr>
            <SortTh sortKey="fileName">File</SortTh>
            <SortTh sortKey="createdOnUtc">Requested on</SortTh>
            <SortTh sortKey="status">Status</SortTh>
            <SortTh sortKey="rowCount" className="r">Rows</SortTh>
            <SortTh sortKey="completedOnUtc">Completed on</SortTh>
            <th>Actions</th>
          </tr></thead>
          <tbody>
            {filteredExports.length ? filteredExports.map(j => <tr key={j.jobId}>
              <td className="jobs-file-cell" title={j.fileName}><i className="bi bi-download jobs-row-icon download" /> {j.fileName || '-'}</td>
              <td>{fmtTime(j.createdOnUtc)}</td>
              <td>{statusChip(j.status)}</td>
              <td className="r">{j.rowCount ? Number(j.rowCount).toLocaleString() : '-'}</td>
              <td>{fmtTime(j.completedOnUtc)}</td>
              <td>
                <div className="jobs-actions">
                  {j.downloadUrl && <button type="button" className="jobs-icon-btn" title="Download file" onClick={() => downloadExportFile(j, setMessage)}><i className="bi bi-download" /></button>}
                  <button type="button" className="jobs-icon-btn danger" title={isActive(j.status) ? 'Cancel export' : 'Remove from list'} onClick={() => removeJob('download', j)}><i className={`bi ${isActive(j.status) ? 'bi-x-circle' : 'bi-trash3'}`} /></button>
                  {!isActive(j.status) && !j.downloadUrl && <span className="muted-text" title={j.message || ''}>{String(j.status).toLowerCase() === 'failed' ? 'Failed' : ''}</span>}
                </div>
              </td>
            </tr>) : <tr><td colSpan={6} className="empty-cell">{loading ? 'Loading…' : (fromDate || toDate) ? 'No downloads in the selected date range.' : 'No downloads yet. Use Overall Download or a tab Download Claims button.'}</td></tr>}
          </tbody>
        </table>
      </div>}
    </div>

    {detailJobId && <UploadDetailModal jobId={detailJobId} onClose={() => setDetailJobId('')} setMessage={setMessage} />}
  </>;
}
