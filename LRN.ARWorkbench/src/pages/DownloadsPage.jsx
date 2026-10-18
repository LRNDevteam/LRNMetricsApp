import { useEffect, useMemo, useState } from 'react';
import { EXPORT_STATUS, elapsed } from '../components/ExportJobs';
import Icon from '../components/Icon';
import { Badge, PageHeader } from '../components/Status';
import { isActiveJob, useExportJobs } from '../context/ExportJobsContext';
import { useWorkbench } from '../context/WorkbenchContext';
import { fmt } from '../utils/format';

// My Downloads: every background export the signed-in user started (Work Queue, My Work, Follow-Up,
// Assignment, Audit Log, Reports) - running, ready and past ones - like the Denial Workflow's
// Uploads & Downloads page. History comes from dbo.DenialWorkflowJobHistory, so it survives an API
// restart; a finished file stays downloadable for 7 days.

const FILTERS = [
  ['all', 'All'],
  ['active', 'In progress'],
  ['ready', 'Ready / Downloaded'],
  ['failed', 'Failed / Cancelled']
];

function matches(job, filter) {
  if (filter === 'active') return isActiveJob(job);
  if (filter === 'ready') return ['Completed', 'Downloaded'].includes(job.status);
  if (filter === 'failed') return ['Failed', 'Cancelled'].includes(job.status);
  return true;
}

export default function DownloadsPage() {
  const { labs } = useWorkbench();
  const { jobs, tick, download, cancel, refresh } = useExportJobs();
  const [filter, setFilter] = useState('all');
  const [search, setSearch] = useState('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const controller = new AbortController();
    refresh(controller.signal).finally(() => setLoading(false));
    return () => controller.abort();
  }, [refresh]);

  const labName = (id) => labs.find((l) => l.labId === id)?.labName || (id ? `Lab ${id}` : '—');
  const rows = useMemo(() => {
    const text = search.trim().toLowerCase();
    return jobs.filter((j) => matches(j, filter)
      && (!text || `${j.scope} ${j.fileName} ${j.message}`.toLowerCase().includes(text)));
  }, [jobs, filter, search]);

  return (
    <>
      <PageHeader note="Exports run in the background — start one from any page and keep working. Finished files can be downloaded here for 7 days.">
        <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => { setLoading(true); refresh().finally(() => setLoading(false)); }}>
          <Icon name="refresh" size={15} /> Refresh
        </button>
      </PageHeader>

      <div className="arwb-panel arwb-filter-card arwb-section">
        <div className="arwb-filter-bar">
          <div className="arwb-field grow">
            <label htmlFor="dl-search">Search</label>
            <input id="dl-search" type="search" className="arwb-input" placeholder="Export or file name…" maxLength={200}
              value={search} onChange={(e) => setSearch(e.target.value)} />
          </div>
          <div className="arwb-field">
            <label htmlFor="dl-status">Status</label>
            <select id="dl-status" className="arwb-select" value={filter} onChange={(e) => setFilter(e.target.value)}>
              {FILTERS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
          </div>
        </div>
      </div>

      <div className="arwb-card arwb-card-flush">
        <div className="arwb-card-head"><h3>Downloads</h3><span className="arwb-card-sub">{fmt.count(rows.length)} of {fmt.count(jobs.length)}</span></div>
        <div className="arwb-table-wrap">
          <table className="arwb-data-table">
            <thead>
              <tr>
                <th>Export</th><th>File</th><th>Client</th><th>Status</th><th className="num">Rows</th>
                <th>Requested</th><th>Completed</th><th className="num">Duration</th><th className="num">Actions</th>
              </tr>
            </thead>
            <tbody>
              {loading && jobs.length === 0 && <tr><td colSpan={9}><div className="arwb-loading"><span className="arwb-spinner" /> Loading…</div></td></tr>}
              {!loading && rows.length === 0 && <tr><td colSpan={9}><div className="arwb-empty-state">{jobs.length ? 'No downloads match the filters.' : 'No exports yet. Use an Export button on any page.'}</div></td></tr>}
              {rows.map((j) => {
                const [text, cls] = EXPORT_STATUS[j.status] || [j.status, 'arwb-badge-neutral'];
                const active = isActiveJob(j);
                return (
                  <tr key={j.jobId}>
                    <td><b>{j.scope || '—'}</b></td>
                    <td className="mono" style={{ wordBreak: 'break-all' }}>{j.fileName}</td>
                    <td>{labName(j.labId)}</td>
                    <td>
                      <Badge className={cls}>{active && <span className="arwb-spinner" style={{ width: 10, height: 10, marginRight: 4 }} />}{text}</Badge>
                      {(active || ['Failed', 'Cancelled'].includes(j.status)) && <div className="arwb-hint" style={{ maxWidth: 320 }}>{j.message}</div>}
                    </td>
                    <td className="num">{j.rowCount ? fmt.count(j.rowCount) : '—'}</td>
                    <td>{fmt.dateTime(j.createdOnUtc)}</td>
                    <td>{j.completedOnUtc ? fmt.dateTime(j.completedOnUtc) : '—'}</td>
                    <td className="num">{elapsed(j, tick)}</td>
                    <td className="num" style={{ whiteSpace: 'nowrap' }}>
                      {j.canDownload && (
                        <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={() => download(j)}>
                          <Icon name="download" size={14} /> Download File
                        </button>
                      )}{' '}
                      {active ? (
                        <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => cancel(j)}>Cancel</button>
                      ) : (
                        <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => cancel(j)} title="Remove from the list (deletes the file)">
                          <Icon name="trash" size={14} />
                        </button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}
