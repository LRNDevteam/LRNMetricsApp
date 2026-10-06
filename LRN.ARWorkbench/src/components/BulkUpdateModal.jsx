import { useEffect, useRef, useState } from 'react';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';
import Icon from './Icon';
import Modal from './Modal';
import { Badge, ErrorBox } from './Status';

/**
 * Bulk Update (Excel) - T030. 1) Download the template: the page's filtered claims, the selected
 * claims, or blank. It has an Assign To dropdown (agents) and the follow-up note columns with the
 * master-list dropdowns. 2) Upload it: a background job assigns / logs notes row by row with the
 * same rules as the screens, and a conflict check skips claims worked since the download.
 * 3) See the per-row result and download the log.
 *
 * filter: the page's claim filter (without paging); selectedKeys: Set or array of ClaimKeys.
 */
const POLL_MS = 2000;

export default function BulkUpdateModal({ filter, selectedKeys, onClose, onDone }) {
  const { labId, can } = useWorkbench();
  const selected = selectedKeys ? [...selectedKeys] : [];
  const [mode, setMode] = useState(selected.length ? 'selected' : 'filtered');
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');
  const [job, setJob] = useState(null);       // upload status (polled)
  const changed = useRef(false);

  async function download() {
    setBusy('template');
    setError('');
    try {
      const { page, pageSize, ...rest } = filter || {}; // eslint-disable-line no-unused-vars
      await arWorkbenchService.bulkTemplate(labId, { mode, filter: rest, claimKeys: mode === 'selected' ? selected : null });
    } catch (e) {
      setError(e.message || 'The template could not be built.');
    } finally {
      setBusy('');
    }
  }

  async function upload(file) {
    if (!file) return;
    setBusy('upload');
    setError('');
    try {
      const start = await arWorkbenchService.bulkUpload(labId, file);
      setJob({ ...start, fileName: file.name });
    } catch (e) {
      setError(e.message || 'The upload failed.');
    } finally {
      setBusy('');
    }
  }

  // Poll the job until it finishes.
  const running = job && ['Queued', 'Running'].includes(job.status);
  useEffect(() => {
    if (!running) return undefined;
    const t = setTimeout(() => {
      arWorkbenchService.bulkJob(labId, job.jobId)
        .then((s) => {
          setJob((j) => ({ ...j, ...s }));
          if (s.status === 'Completed' && (s.successCount || 0) > 0) changed.current = true;
        })
        .catch((e) => setError(e.message));
    }, POLL_MS);
    return () => clearTimeout(t);
  }, [running, job, labId]);

  const close = () => (changed.current ? onDone?.() : onClose());
  const rows = job?.result?.results || [];
  const problems = rows.filter((r) => r.status !== 'Success');

  return (
    <Modal wide title="Bulk Update (Excel)" busy={!!busy} onClose={close} onSubmit={close} submitLabel={null}
      subtitle="Bulk assignment and bulk follow-up / status update from one spreadsheet">
      <ErrorBox message={error} />

      {!job && (
        <>
          <div className="arwb-bulk-step">
            <div className="arwb-bulk-step-no">1</div>
            <div className="grow">
              <b>Download the template</b>
              <div className="arwb-bulk-options">
                {selected.length > 0 && (
                  <label><input type="radio" name="bulk-mode" checked={mode === 'selected'} onChange={() => setMode('selected')} /> The {fmt.count(selected.length)} selected claim{selected.length === 1 ? '' : 's'}</label>
                )}
                <label><input type="radio" name="bulk-mode" checked={mode === 'filtered'} onChange={() => setMode('filtered')} /> All claims matching this page&rsquo;s filters (up to 5,000)</label>
                <label><input type="radio" name="bulk-mode" checked={mode === 'blank'} onChange={() => setMode('blank')} /> Blank template (type the Claim IDs)</label>
              </div>
              <button type="button" className="arwb-btn arwb-btn-sm" disabled={!!busy} onClick={download}>
                {busy === 'template' ? <span className="arwb-spinner" /> : <Icon name="download" size={15} />} Download Template
              </button>
              <p className="arwb-hint">
                Fill the yellow columns only.
                {can('assign') ? ' Assign To has a dropdown of this lab’s agents and team leads.' : ' (Your role cannot assign, so leave Assign To empty.)'}
                {can('editClaim') ? ' Claim Status, Fix / Resolution and the other note fields have dropdowns from the master lists; a logged note sends the claim to QA.' : ''}
              </p>
            </div>
          </div>
          <div className="arwb-bulk-step">
            <div className="arwb-bulk-step-no">2</div>
            <div className="grow">
              <b>Upload the filled file</b>
              <div style={{ marginTop: 8 }}>
                <label className={`arwb-btn arwb-btn-sm arwb-btn-primary arwb-upload${busy ? ' disabled' : ''}`} aria-disabled={!!busy}>
                  {busy === 'upload' ? <><span className="arwb-spinner" /> Uploading…</> : <><Icon name="upload" size={15} /> Upload &amp; Update</>}
                  <input type="file" accept=".xlsx" disabled={!!busy} onChange={(e) => { upload(e.target.files?.[0]); e.target.value = ''; }} />
                </label>
              </div>
              <p className="arwb-hint">
                Each row is checked on its own. A claim someone worked after you downloaded the template is not changed (conflict check) - download a fresh template for it.
              </p>
            </div>
          </div>
        </>
      )}

      {job && (
        <div>
          <div className="arwb-flex-between" style={{ marginBottom: 10 }}>
            <div>
              <b>{job.fileName}</b> · {fmt.count(job.totalRows)} row{job.totalRows === 1 ? '' : 's'}
              {' '}<Badge className={job.status === 'Completed' ? 'arwb-badge-good' : job.status === 'Failed' ? 'arwb-badge-critical' : 'arwb-badge-info'}>{job.status}</Badge>
            </div>
            {job.status === 'Completed' && (
              <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => arWorkbenchService.bulkLog(labId, job.jobId).catch((e) => setError(e.message))}>
                <Icon name="download" size={15} /> Download Result Log
              </button>
            )}
          </div>
          {running && <div className="arwb-loading"><span className="arwb-spinner" /> {job.message || 'Processing…'} You can keep this open or close it; the upload continues.</div>}
          {!running && <p>{job.message}</p>}

          {job.result && (
            <>
              <div className="arwb-grid arwb-grid-kpi" style={{ margin: '10px 0' }}>
                {[['Updated', job.result.successCount], ['Assigned', job.result.updatedTasks], ['Follow-up notes', job.result.addedComments],
                  ['Failed', job.result.failureCount], ['Skipped', job.result.skippedRows]].map(([label, v]) => (
                  <div key={label} className="arwb-kpi arwb-kpi-tile"><span className="arwb-kpi-label">{label}</span><span className="arwb-kpi-value mono">{fmt.count(v)}</span></div>
                ))}
              </div>
              {problems.length > 0 && (
                <div className="arwb-table-wrap" style={{ maxHeight: 300, overflowY: 'auto' }}>
                  <table className="arwb-data-table">
                    <thead><tr><th>Row</th><th>Claim ID</th><th>Result</th><th>Reason</th></tr></thead>
                    <tbody>
                      {problems.slice(0, 300).map((r) => (
                        <tr key={r.rowNumber}>
                          <td className="mono">{r.rowNumber}</td>
                          <td className="mono">{r.claimId || '—'}</td>
                          <td>{r.status === 'Failed' ? <Badge className="arwb-badge-critical">Failed</Badge> : <Badge>Skipped</Badge>}</td>
                          <td className="arwb-wrap">{r.failureReason || r.note}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
              {problems.length > 300 && <p className="arwb-hint">Showing the first 300; the result log has every row.</p>}
            </>
          )}
          {!running && (
            <div style={{ marginTop: 12 }}>
              <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => setJob(null)}>Upload another file</button>
            </div>
          )}
        </div>
      )}
    </Modal>
  );
}
