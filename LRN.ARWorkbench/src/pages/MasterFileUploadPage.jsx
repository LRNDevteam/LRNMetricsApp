import { useState } from 'react';
import Icon from '../components/Icon';
import { Badge, ErrorBox, Notice, PageHeader } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';
import { MasterFileLoads } from './DataProcessingPage';

// Master File Upload: the master data of a lab whose master file does not reach the SharePoint master
// folder (a client that takes only the AR Workbench), or a one-off load for any lab. The user
// downloads the standard template, maps their claim-level and line-level data into it, and uploads
// it with the week it belongs to. The API checks it against the template, stores it and queues the
// Master File Processor, which loads it exactly like a SharePoint master file: dbo.ClaimLevelData /
// dbo.LineLevelData with the denial data, then the AR Workbench sync. Progress: Master File Loads.

const isoDate = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

function defaultPeriod() {
  const end = new Date();
  const start = new Date(end);
  start.setDate(end.getDate() - 6);
  return { start: isoDate(start), end: isoDate(end) };
}

const MAX_MB = 90;

export default function MasterFileUploadPage() {
  const { labId, lab } = useWorkbench();
  const [file, setFile] = useState(null);
  const [period, setPeriod] = useState(defaultPeriod);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');
  const [notice, setNotice] = useState(null);
  // The last check of the chosen file: { errors, warnings, claimRows, lineRows, valid }.
  const [check, setCheck] = useState(null);
  const [confirming, setConfirming] = useState(false);
  const [loadsVersion, setLoadsVersion] = useState(0);

  const labName = lab?.labName || 'this lab';
  const periodError = !period.start || !period.end ? 'Choose the week the data belongs to.'
    : period.end < period.start ? 'The period end is before its start.' : '';

  function choose(f) {
    setError('');
    setNotice(null);
    setCheck(null);
    setConfirming(false);
    if (!f) { setFile(null); return; }
    if (!/\.xlsx$/i.test(f.name)) { setFile(null); setError('Choose the filled template as an Excel workbook (.xlsx).'); return; }
    if (f.size > MAX_MB * 1024 * 1024) { setFile(null); setError(`The file is larger than ${MAX_MB} MB.`); return; }
    setFile(f);
  }

  async function downloadTemplate() {
    setBusy('template');
    setError('');
    try {
      await arWorkbenchService.masterFileTemplate(labId);
    } catch (e) {
      setError(e.message || 'The template could not be downloaded.');
    } finally {
      setBusy('');
    }
  }

  async function validate() {
    if (!file) return;
    setBusy('validate');
    setError('');
    setNotice(null);
    try {
      setCheck(await arWorkbenchService.validateMasterFile(labId, file));
    } catch (e) {
      setError(e.message || 'The file could not be checked.');
    } finally {
      setBusy('');
    }
  }

  async function upload() {
    setConfirming(false);
    setBusy('upload');
    setError('');
    setNotice(null);
    try {
      const r = await arWorkbenchService.uploadMasterFile(labId, file, { periodStart: period.start, periodEnd: period.end, note: note.trim() || null });
      setCheck(r.validation || null);
      setNotice({
        kind: r.validation?.warnings?.length ? 'warning' : 'good',
        text: `${file.name} uploaded and queued (load #${r.requestId}): ${fmt.count(r.validation?.claimRows)} claims and ${fmt.count(r.validation?.lineRows)} lines for the week ${fmt.date(period.start)} – ${fmt.date(period.end)}. `
          + 'The Master File Processor loads it on its next poll; follow it under Master File Loads below.',
        details: r.validation?.warnings
      });
      setFile(null);
      setNote('');
    } catch (e) {
      // A file that does not match the template comes back with the full check in the body.
      if (e.body?.validation) setCheck(e.body.validation);
      setError(e.message || 'The upload failed.');
    } finally {
      setBusy('');
      setLoadsVersion((v) => v + 1);
    }
  }

  return (
    <>
      <PageHeader note={`Load ${labName}'s claim-level and line-level master data from the standard template — the same load as the SharePoint master file`}>
        <button type="button" className="arwb-btn arwb-btn-sm" disabled={!!busy} onClick={downloadTemplate}
          title="The standard master file template: Instructions, Claim Level and Line Level sheets">
          {busy === 'template' ? <span className="arwb-spinner" /> : <Icon name="download" size={15} />} Download Template
        </button>
      </PageHeader>

      <ErrorBox message={error} />
      <Notice notice={notice} onClose={() => setNotice(null)} />

      <div className="arwb-grid-2 arwb-section">
        <div className="arwb-card">
          <h3 className="arwb-section-title" style={{ marginTop: 0 }}>Upload the filled template</h3>

          <div className="arwb-field" style={{ marginBottom: 12 }}>
            <span className="arwb-label">Master file (.xlsx, up to {MAX_MB} MB)</span>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
              <label className={`arwb-btn arwb-btn-sm arwb-upload${busy ? ' disabled' : ''}`} aria-disabled={!!busy}>
                <Icon name="upload" size={15} /> {file ? 'Choose another file' : 'Choose file'}
                <input type="file" accept=".xlsx" disabled={!!busy} onChange={(e) => { choose(e.target.files?.[0]); e.target.value = ''; }} />
              </label>
              {file
                ? <span className="mono">{file.name} <span className="arwb-hint">({(file.size / 1024 / 1024).toFixed(1)} MB)</span></span>
                : <span className="arwb-hint">No file chosen</span>}
            </div>
          </div>

          <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 12 }}>
            <div className="arwb-field">
              <label htmlFor="mfu-start">Week from</label>
              <input id="mfu-start" type="date" className="arwb-input" value={period.start} onChange={(e) => setPeriod((p) => ({ ...p, start: e.target.value }))} />
            </div>
            <div className="arwb-field">
              <label htmlFor="mfu-end">Week to</label>
              <input id="mfu-end" type="date" className="arwb-input" value={period.end} onChange={(e) => setPeriod((p) => ({ ...p, end: e.target.value }))} />
            </div>
          </div>
          <div className="arwb-field-note" style={{ marginTop: -6, marginBottom: 12 }}>
            The week the data belongs to. It names the load and its output files, like the SharePoint week folder.
          </div>
          {periodError && file && <div className="text-critical" style={{ marginBottom: 12 }}>{periodError}</div>}

          <div className="arwb-field" style={{ marginBottom: 14 }}>
            <label htmlFor="mfu-note">Reason / note (optional)</label>
            <input id="mfu-note" className="arwb-input" value={note} maxLength={1000} onChange={(e) => setNote(e.target.value)} />
          </div>

          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            <button type="button" className="arwb-btn arwb-btn-sm" disabled={!file || !!busy} onClick={validate}
              title="Check the file against the template without loading anything">
              {busy === 'validate' ? <><span className="arwb-spinner" /> Checking…</> : <><Icon name="check" size={15} /> Check file</>}
            </button>
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!file || !!busy || !!periodError || check?.valid === false}
              onClick={() => setConfirming(true)}>
              {busy === 'upload' ? <><span className="arwb-spinner" /> Uploading…</> : <><Icon name="upload" size={15} /> Upload &amp; Load</>}
            </button>
          </div>

          {confirming && (
            <div className="arwb-card arwb-confirm" style={{ marginTop: 14 }}>
              <p style={{ marginTop: 0 }}>
                This replaces {labName}&rsquo;s claim-level and line-level master data (<code>dbo.ClaimLevelData</code>, <code>dbo.LineLevelData</code>)
                with <b>{file?.name}</b> for the week {fmt.date(period.start)} – {fmt.date(period.end)}, loads the denial data and runs the
                AR Workbench sync — the same as a weekly master file from SharePoint. Workflow state (assignments, follow-ups, QA, CIP) is kept.
              </p>
              <div style={{ display: 'flex', gap: 8 }}>
                <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={upload}>Upload and load</button>
                <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => setConfirming(false)}>Cancel</button>
              </div>
            </div>
          )}

          {check && <CheckResult check={check} />}
        </div>

        <div className="arwb-card">
          <h3 className="arwb-section-title" style={{ marginTop: 0 }}>How it works</h3>
          <ol style={{ paddingLeft: 18, margin: 0, lineHeight: 1.6 }}>
            <li><b>Download Template.</b> One workbook: an <i>Instructions</i> sheet listing every column, a <i>Claim Level</i> sheet (one row per claim) and a <i>Line Level</i> sheet (one row per CPT line).</li>
            <li><b>Map your data.</b> Copy your billing system&rsquo;s claim and line data under the matching headers. Keep the header row as it is; red headers are required on every row. ClaimID links each line to its claim.</li>
            <li><b>Check, then upload.</b> Check file shows any problem by sheet, column and row before anything is loaded. Upload &amp; Load queues the Master File Processor for {labName}.</li>
            <li><b>Follow the load</b> under Master File Loads. When it completes, the claims are in the Work Queue and the Denial Analysis on Data Processing is rebuilt.</li>
          </ol>
          <p className="arwb-hint" style={{ marginBottom: 0 }}>
            Every lab can use this. A lab whose master file comes from SharePoint keeps its weekly SharePoint load; an upload replaces
            the data until the next load of either kind. A lab without the SharePoint master sync is set up in the Master File
            Processor with <code>MasterDataSource: &quot;Upload&quot;</code>.
          </p>
        </div>
      </div>

      <MasterFileLoads labId={labId} version={loadsVersion} />
    </>
  );
}

function CheckResult({ check }) {
  return (
    <div style={{ marginTop: 14 }}>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap', marginBottom: 6 }}>
        {check.valid
          ? <Badge className="arwb-badge-good">Matches the template</Badge>
          : <Badge className="arwb-badge-critical">{check.errors.length} problem{check.errors.length === 1 ? '' : 's'} to fix</Badge>}
        <span className="arwb-hint">{fmt.count(check.claimRows)} claim rows · {fmt.count(check.lineRows)} line rows · template v{check.templateVersion}</span>
      </div>
      {check.errors?.length > 0 && (
        <ul className="arwb-error-list text-critical">{check.errors.map((m, i) => <li key={i}>{m}</li>)}</ul>
      )}
      {check.warnings?.length > 0 && (
        <>
          <div className="arwb-label" style={{ marginTop: 8 }}>Warnings (the file can still be loaded)</div>
          <ul className="arwb-error-list">{check.warnings.map((m, i) => <li key={i}>{m}</li>)}</ul>
        </>
      )}
    </div>
  );
}
