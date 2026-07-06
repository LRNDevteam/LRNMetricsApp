import React, { useRef, useState } from 'react';
import { denialWorkflowService } from '../services/denialWorkflowService';

export default function ClaimCsvUpload({ labId, setMessage = () => {}, onUploaded = () => {}, onDownloadTemplate = () => {}, templateBusy = false, label = 'Upload Template' }) {
  const inputRef = useRef(null);
  const [busy, setBusy] = useState(false);

  async function upload(file) {
    if (!file || !labId) return;
    setBusy(true);
    try {
      const result = await denialWorkflowService.uploadClaimsCsv(labId, file);
      const errors = result.errors || [];
      setMessage({
        type: result.success ? 'success' : 'warning',
        text: `${result.message || 'CSV processed.'}${errors.length ? ` ${errors.slice(0, 3).join(' ')}` : ''}`
      });
      await onUploaded(result);
    } catch (e) {
      setMessage({ type: 'danger', text: e.message || 'Unable to process CSV.' });
    } finally {
      setBusy(false);
      if (inputRef.current) inputRef.current.value = '';
    }
  }

  return <>
    <input ref={inputRef} type="file" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,.csv,text/csv" hidden onChange={e => upload(e.target.files?.[0])} />
    <button type="button" className="claim-tab-download" disabled={templateBusy || !labId} onClick={onDownloadTemplate} title="Download the filtered claim-level Excel upload template with dropdowns.">
      <i className="bi bi-file-earmark-arrow-down" />{templateBusy ? 'Preparing Claims' : 'Download Claims'}
    </button>
    <button type="button" className="claim-tab-download claim-csv-upload" disabled={busy || !labId} onClick={() => inputRef.current?.click()} title="Process the claim-level Excel upload template. The uploaded file is not stored.">
      <i className="bi bi-upload" />{busy ? 'Processing Template' : label}
    </button>
  </>;
}
