import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router';
import { isActiveJob, useExportJobs } from '../context/ExportJobsContext';
import { fmt } from '../utils/format';
import Icon from './Icon';

export const EXPORT_STATUS = {
  Queued: ['Queued', 'arwb-badge-info'],
  Running: ['In progress', 'arwb-badge-info'],
  Completed: ['Ready', 'arwb-badge-good'],
  Downloaded: ['Downloaded', 'arwb-badge-neutral'],
  Failed: ['Failed', 'arwb-badge-critical'],
  Cancelled: ['Cancelled', 'arwb-badge-warning']
};

export function elapsed(job, now) {
  const start = new Date(job.createdOnUtc).getTime();
  if (!Number.isFinite(start)) return '';
  const end = job.completedOnUtc ? new Date(job.completedOnUtc).getTime() : now;
  const s = Math.max(0, Math.floor((end - start) / 1000));
  return s >= 60 ? `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s` : `${s}s`;
}

/**
 * An Export button that queues a background export. While its export runs it shows a spinner and
 * stays disabled; the file downloads by itself when the job completes.
 * scope: the job's label (also used to match the running job); start: () => Promise<job>.
 */
export function ExportButton({ scope, start, label = 'Export', title, className = 'arwb-btn arwb-btn-sm', disabled }) {
  const { startExport, isRunning } = useExportJobs();
  const [starting, setStarting] = useState(false);
  const running = starting || isRunning(scope);

  async function onClick() {
    setStarting(true);
    try { await startExport(start); } finally { setStarting(false); }
  }

  return (
    <button type="button" className={className} disabled={disabled || running} onClick={onClick}
      title={running ? `${scope} export is in progress - it downloads automatically when ready` : title}>
      {running ? <span className="arwb-spinner" /> : <Icon name="download" size={15} />} {running ? `${label}…` : label}
    </button>
  );
}

/** Top bar: Downloads - the user's running and recent exports, with Download / Cancel / Remove. */
export function ExportJobsMenu() {
  const { jobs, tick, activeCount, download, cancel, refresh } = useExportJobs();
  const [open, setOpen] = useState(false);
  const ref = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    refresh();
    const onDown = (e) => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    const onKey = (e) => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => { document.removeEventListener('mousedown', onDown); document.removeEventListener('keydown', onKey); };
  }, [open, refresh]);

  return (
    <div className="arwb-user-menu" ref={ref}>
      <button type="button" className="arwb-icon-btn arwb-bell-btn" onClick={() => setOpen((v) => !v)}
        aria-haspopup="true" aria-expanded={open}
        aria-label={activeCount ? `Downloads, ${activeCount} in progress` : 'Downloads'} title="Downloads">
        {activeCount > 0 ? <span className="arwb-spinner" /> : <Icon name="download" />}
        {activeCount > 0 && <span className="arwb-bell-count" aria-hidden="true">{activeCount}</span>}
      </button>
      {open && (
        <div className="arwb-popover right arwb-bell-dropdown" role="dialog" aria-label="Downloads">
          <div className="arwb-bell-head">
            <b>Downloads</b>
            <Link to="/downloads" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => setOpen(false)}>View all</Link>
          </div>
          {jobs.length === 0 ? (
            <div className="arwb-hint" style={{ padding: '10px 8px' }}>No exports yet. Use an Export button on any page.</div>
          ) : (
            <ul className="arwb-bell-list">
              {jobs.map((j) => {
                const [text, cls] = EXPORT_STATUS[j.status] || [j.status, 'arwb-badge-neutral'];
                const active = isActiveJob(j);
                return (
                  <li key={j.jobId} className="arwb-export-job">
                    <div className="arwb-bell-meta">
                      <b className="arwb-export-job-name" title={j.fileName}>{j.scope || j.fileName}</b>
                      <span className={`arwb-badge ${cls} ms-auto`}>{text}</span>
                    </div>
                    <div className="arwb-bell-meta">
                      <span>{fmt.dateTime(j.createdOnUtc)}</span>
                      <span>· {elapsed(j, tick)}</span>
                      {j.rowCount > 0 && <span>· {fmt.count(j.rowCount)} rows</span>}
                    </div>
                    {(active || ['Failed', 'Cancelled'].includes(j.status)) && <div className="arwb-bell-msg arwb-hint">{j.message}</div>}
                    <div className="arwb-export-job-actions">
                      {j.canDownload && (
                        <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={() => download(j)}>
                          <Icon name="download" size={14} /> Download File
                        </button>
                      )}
                      {active ? (
                        <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => cancel(j)}>Cancel</button>
                      ) : (
                        <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => cancel(j)} title="Remove from the list (deletes the file)">
                          <Icon name="trash" size={14} /> Remove
                        </button>
                      )}
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}
