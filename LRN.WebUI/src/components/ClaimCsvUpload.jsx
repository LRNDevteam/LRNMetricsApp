import React, { useRef, useState } from 'react';
import { denialWorkflowService } from '../services/denialWorkflowService';

// Fire-and-forget upload: the file is enqueued on the server (202 + jobId) and processed in the
// background. The user is NOT held on this modal — after enqueue we show a confirmation and they
// can close immediately and follow progress via the topbar Jobs badge / Uploads & Downloads page.
export default function ClaimCsvUpload({ labId, setMessage = () => {}, onUploaded = () => {}, onDownloadTemplate = () => {}, templateBusy = false, label = 'Upload Template' }) {
  const inputRef = useRef(null);
  const [open, setOpen] = useState(false);
  // 'form' -> pick file, 'submitting' -> enqueue call in flight, 'queued' -> confirmation
  const [phase, setPhase] = useState('form');
  const [file, setFile] = useState(null);
  const [queued, setQueued] = useState(null);
  const [error, setError] = useState('');

  function openModal() {
    setFile(null);
    setQueued(null);
    setError('');
    setPhase('form');
    setOpen(true);
  }

  function closeModal() {
    if (phase === 'submitting') return;
    setOpen(false);
    setPhase('form');
    setFile(null);
    setQueued(null);
    setError('');
    if (inputRef.current) inputRef.current.value = '';
  }

  function openJobs() {
    closeModal();
    window.dispatchEvent(new CustomEvent('lrn-open-jobs'));
  }

  async function doUpload() {
    if (phase === 'submitting') return;
    if (!file || !labId) { setError('Please choose a file to upload.'); return; }
    setError('');
    setPhase('submitting');
    try {
      const start = await denialWorkflowService.enqueueClaimsUpload(labId, file);
      setQueued(start);
      setPhase('queued');
      // Wake the topbar Jobs badge immediately so the new job appears without waiting a poll cycle.
      window.dispatchEvent(new CustomEvent('lrn-jobs-refresh'));
      setMessage({ type: 'info', text: start?.message || 'Upload is in progress. Track it from the Jobs badge at the top right.' });
      onUploaded(start);
    } catch (e) {
      setError(e.message || 'Unable to start the upload.');
      setPhase('form');
    }
  }

  return <>
    <input ref={inputRef} type="file" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,.csv,text/csv" hidden onChange={e => { setError(''); setFile(e.target.files?.[0] || null); }} />
    <button type="button" className="claim-tab-download" disabled={templateBusy || !labId} onClick={onDownloadTemplate} title="Download the filtered claim-level Excel upload template with dropdowns.">
      <i className="bi bi-file-earmark-arrow-down" />{templateBusy ? 'Preparing Claims' : 'Download Claims'}
    </button>
    <button type="button" className="claim-tab-download claim-csv-upload" disabled={!labId} onClick={openModal} title="Process the claim-level Excel upload template in the background. The uploaded file is not stored.">
      <i className="bi bi-upload" />{label}
    </button>

    {open && <div className="modal-backdrop" onClick={closeModal}>
      <div className="note-modal csv-upload-modal csv-upload-modal-compact" onClick={e => e.stopPropagation()}>
        <div className="note-modal-hd">
          <div>
            <strong>Upload Claim Template</strong>
            <small>{phase === 'queued' ? 'Upload queued — processing runs in the background.' : 'Choose the filled claim-level Excel/CSV template.'}</small>
          </div>
          <button className="modal-close" disabled={phase === 'submitting'} onClick={closeModal}>×</button>
        </div>

        <div className="note-modal-body">
          {phase !== 'queued' && <>
            <div className="info-strip">Each claim row can update status &amp; values, add a comment, raise an escalation, or post an escalation response. Processing happens in the background — you will not have to wait on this page.</div>
            <div className="csv-upload-drop">
              <i className="bi bi-cloud-arrow-up" />
              <strong>{file ? file.name : 'Choose a file to upload'}</strong>
              <span>{file ? `${Math.ceil((file.size || 0) / 1024)} KB · ready to upload` : 'Excel (.xlsx) or CSV template'}</span>
              <button type="button" className="wl-btn xs" disabled={phase === 'submitting'} onClick={() => inputRef.current?.click()}>{file ? 'Change file' : 'Browse…'}</button>
            </div>
            {error && <div className="csv-upload-error"><i className="bi bi-exclamation-circle" /> {error}</div>}
          </>}

          {phase === 'queued' && <div className="csv-upload-queued">
            <i className="bi bi-check-circle-fill" />
            <strong>Upload in progress</strong>
            <span>{queued?.totalRows ? `${queued.totalRows} row(s) queued for processing.` : 'Your file has been queued for processing.'} You can close this window and keep working.</span>
            <span>Track progress from the <b>Jobs badge</b> in the top-right corner. When it completes you can review every claim's result and download the log from <b>Uploads &amp; Downloads</b>.</span>
          </div>}
        </div>

        <div className="note-modal-ft">
          {phase === 'form' && <>
            <button className="wl-btn" onClick={closeModal}>Cancel</button>
            <button className="wl-btn teal" disabled={!file || !labId} onClick={doUpload}>Upload</button>
          </>}
          {phase === 'submitting' && <button className="wl-btn" disabled><i className="bi bi-arrow-repeat csv-upload-spinner" /> Starting…</button>}
          {phase === 'queued' && <>
            <button className="wl-btn" onClick={openJobs}>View upload status</button>
            <button className="wl-btn teal" onClick={closeModal}>Close</button>
          </>}
        </div>
      </div>
    </div>}
  </>;
}
