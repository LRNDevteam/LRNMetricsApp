import React, { useRef, useState } from 'react';
import { denialWorkflowService } from '../services/denialWorkflowService';

const isSuccess = (s) => String(s || '').toLowerCase() === 'success';

export default function ClaimCsvUpload({ labId, setMessage = () => {}, onUploaded = () => {}, onDownloadTemplate = () => {}, templateBusy = false, label = 'Upload Template' }) {
  const inputRef = useRef(null);
  const [open, setOpen] = useState(false);
  // 'form' -> pick file, 'uploading' -> spinner, 'results' -> per-row table
  const [phase, setPhase] = useState('form');
  const [file, setFile] = useState(null);
  const [result, setResult] = useState(null);
  const [error, setError] = useState('');

  function openModal() {
    setFile(null);
    setResult(null);
    setError('');
    setPhase('form');
    setOpen(true);
  }

  function closeModal() {
    if (phase === 'uploading') return; // never close mid-upload
    const finished = result;
    setOpen(false);
    setPhase('form');
    setFile(null);
    setError('');
    setResult(null);
    if (inputRef.current) inputRef.current.value = '';
    if (finished) {
      const type = finished.failureCount > 0 ? (finished.successCount > 0 ? 'warning' : 'danger') : 'success';
      setMessage({ type, text: finished.message || 'Upload processed.' });
      // Refresh the underlying grid only after the results modal is dismissed.
      onUploaded(finished);
    }
  }

  async function doUpload() {
    if (phase === 'uploading') return; // guard against double-submit
    if (!file || !labId) { setError('Please choose a file to upload.'); return; }
    setError('');
    setPhase('uploading');
    try {
      const res = await denialWorkflowService.uploadClaimsCsv(labId, file);
      setResult(res);
      setPhase('results');
    } catch (e) {
      setError(e.message || 'Unable to process the upload file.');
      setPhase('form');
    }
  }

  const rows = result?.results || [];
  const totalRows = result?.totalRows ?? rows.length;
  const successCount = result?.successCount ?? rows.filter(r => isSuccess(r.status)).length;
  const failureCount = result?.failureCount ?? rows.filter(r => !isSuccess(r.status)).length;

  return <>
    <input ref={inputRef} type="file" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,.csv,text/csv" hidden onChange={e => { setError(''); setFile(e.target.files?.[0] || null); }} />
    <button type="button" className="claim-tab-download" disabled={templateBusy || !labId} onClick={onDownloadTemplate} title="Download the filtered claim-level Excel upload template with dropdowns.">
      <i className="bi bi-file-earmark-arrow-down" />{templateBusy ? 'Preparing Claims' : 'Download Claims'}
    </button>
    <button type="button" className="claim-tab-download claim-csv-upload" disabled={!labId} onClick={openModal} title="Process the claim-level Excel upload template. The uploaded file is not stored.">
      <i className="bi bi-upload" />{label}
    </button>

    {open && <div className="modal-backdrop" onClick={closeModal}>
      <div className="note-modal csv-upload-modal" onClick={e => e.stopPropagation()}>
        <div className="note-modal-hd">
          <div>
            <strong>Upload Claim Template</strong>
            <small>{phase === 'results' ? 'Upload results' : 'Process the claim-level Excel/CSV template. The file is not stored.'}</small>
          </div>
          <button className="modal-close" disabled={phase === 'uploading'} onClick={closeModal}>×</button>
        </div>

        <div className="note-modal-body">
          {phase === 'form' && <>
            <div className="info-strip">Choose the filled claim-level template (.xlsx or .csv). Each claim row can update status &amp; values, add a comment, raise an escalation, or post an escalation response.</div>
            <div className="csv-upload-drop">
              <i className="bi bi-cloud-arrow-up" />
              <strong>{file ? file.name : 'Choose a file to upload'}</strong>
              <span>{file ? `${Math.ceil((file.size || 0) / 1024)} KB · ready to upload` : 'Excel (.xlsx) or CSV template'}</span>
              <button type="button" className="wl-btn xs" onClick={() => inputRef.current?.click()}>{file ? 'Change file' : 'Browse…'}</button>
            </div>
            {error && <div className="csv-upload-error"><i className="bi bi-exclamation-circle" /> {error}</div>}
          </>}

          {phase === 'uploading' && <div className="csv-upload-loading">
            <i className="bi bi-arrow-repeat csv-upload-spinner" />
            <strong>Uploading… please wait</strong>
            <span>Processing each claim row. Please do not close this window.</span>
          </div>}

          {phase === 'results' && result && <>
            <div className="csv-upload-summary">
              <span className="csv-sum-badge total">Total {totalRows}</span>
              <span className="csv-sum-badge success">Success {successCount}</span>
              <span className="csv-sum-badge failed">Failed {failureCount}</span>
              {result.skippedRows > 0 ? <span className="csv-sum-badge skipped">Skipped {result.skippedRows}</span> : null}
            </div>
            <div className="csv-upload-results-scroll">
              <table className="csv-upload-results-table">
                <thead><tr><th>Row</th><th>Claim</th><th>Result</th><th>Action</th><th>Status change</th><th>Value changes</th><th>Note</th><th>Reason</th></tr></thead>
                <tbody>
                  {rows.length ? rows.map((r, i) => <tr key={`${r.rowNumber}-${i}`} className={isSuccess(r.status) ? 'row-ok' : 'row-fail'}>
                    <td>{r.rowNumber}</td>
                    <td>{r.claimId || '-'}{r.taskId ? <small> · {r.taskId}</small> : null}</td>
                    <td><span className={`csv-row-badge ${isSuccess(r.status) ? 'ok' : 'fail'}`}>{isSuccess(r.status) ? 'Success' : 'Failed'}</span></td>
                    <td>{r.action || '—'}</td>
                    <td>{isSuccess(r.status) && r.newStatus && r.newStatus !== r.oldStatus
                      ? <span className="csv-status-change">{r.oldStatus || '—'} → <b>{r.newStatus}</b></span>
                      : '—'}</td>
                    <td>{(r.changedValues || []).length
                      ? <ul className="csv-change-list">{r.changedValues.map((c, j) => <li key={j}><span className="csv-change-field">{c.field}:</span> {c.oldValue ? `${c.oldValue} → ` : ''}<b>{c.newValue}</b></li>)}</ul>
                      : '—'}</td>
                    <td className="csv-note-cell" title={r.note || ''}>{r.note || '—'}</td>
                    <td className="csv-reason-cell">{isSuccess(r.status) ? '—' : (r.failureReason || 'Failed')}</td>
                  </tr>) : <tr><td colSpan={8} className="csv-empty">No actionable claim rows were found in the file.</td></tr>}
                </tbody>
              </table>
            </div>
          </>}
        </div>

        <div className="note-modal-ft">
          {phase === 'form' && <>
            <button className="wl-btn" onClick={closeModal}>Cancel</button>
            <button className="wl-btn teal" disabled={!file || !labId} onClick={doUpload}>Upload</button>
          </>}
          {phase === 'uploading' && <button className="wl-btn" disabled>Uploading…</button>}
          {phase === 'results' && <button className="wl-btn teal" onClick={closeModal}>Close &amp; refresh</button>}
        </div>
      </div>
    </div>}
  </>;
}
