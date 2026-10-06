import { useCallback, useEffect, useMemo, useState } from 'react';
import DataTable from '../components/DataTable';
import Icon from '../components/Icon';
import Modal from '../components/Modal';
import { Badge, ErrorBox, Notice } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';
import { Attachments, CIP_BADGE } from '../components/CipShared';

// Client portal - Escalation Requests (mockup client.js, App.views['client-cip']).
//   T064: Awaiting Your Response / Submitted - Under Review / Resolved; Respond with text + up to 3 files.
//   T065: bulk CSV response template - download the open requests, fill Response, upload.
//   T066: Clinic and Provider Viewers see their clinic's / provider's requests read-only.
// The client never sees Awaiting QA or Pending Approval, nor a case rejected internally.

const TABS = [
  ['awaiting', 'Awaiting Your Response', ['Sent to Client'], 'sentToClient'],
  ['submitted', 'Submitted — Under Review', ['Client Responded'], 'clientResponded'],
  ['resolved', 'Resolved', ['Returned to Agent'], 'returnedToAgent']
];
const MAX_FILES = 3;

function RequestSummary({ row }) {
  return (
    <div className="arwb-section-note" style={{ marginBottom: 12 }}>
      <b className="mono">{row.claimID}</b> · {row.caseNumber}{row.roundNumber > 1 ? ` · Round ${row.roundNumber}` : ''} · {row.payerName || '—'}
      · Patient Acct {row.patientID || '—'} · DOS {fmt.date(row.dateOfService)}
      <div style={{ marginTop: 8 }}><b>{row.cipCategory}</b> · {row.requiredInfo}</div>
      <div style={{ marginTop: 4 }}>{row.cipComment}</div>
      {row.lastReviewDecision === 'insufficient' && row.lastReviewNote && (
        <div style={{ marginTop: 8 }}><Badge className="arwb-badge-critical" dot>Needs more info</Badge> {row.lastReviewNote}</div>
      )}
    </div>
  );
}

function RespondModal({ row, onClose, onDone }) {
  const { labId, masterData } = useWorkbench();
  const [text, setText] = useState('');
  const [files, setFiles] = useState([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const allowed = masterData?.settings?.AttachmentAllowedTypes || 'pdf,png,jpg,jpeg,tif,tiff,gif,doc,docx,xls,xlsx,csv,txt';
  const maxBytes = Number(masterData?.settings?.AttachmentMaxBytes) || 15 * 1024 * 1024;

  function addFiles(list) {
    const next = [...files, ...list].slice(0, MAX_FILES);
    const tooBig = next.find((f) => f.size > maxBytes);
    if (tooBig) { setError(`${tooBig.name} is larger than ${fmt.count(Math.round(maxBytes / 1048576))} MB.`); return; }
    if (files.length + list.length > MAX_FILES) setError(`Attach at most ${MAX_FILES} files.`); else setError('');
    setFiles(next);
  }

  async function submit() {
    if (!text.trim()) { setError('Enter the requested information.'); return; }
    setBusy(true);
    setError('');
    try {
      onDone(await arWorkbenchService.cipRespond(labId, row.cipCaseId, text.trim(), files));
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  }

  return (
    <Modal wide title="Respond to Escalation Request" busy={busy} busyLabel="Submitting…" submitLabel="Submit Response" onClose={onClose} onSubmit={submit}>
      <ErrorBox message={error} />
      <RequestSummary row={row} />
      <div className="arwb-field">
        <label htmlFor="cr-text">Requested information</label>
        <textarea id="cr-text" className="arwb-input" rows={5} maxLength={4000} value={text} onChange={(e) => setText(e.target.value)} />
      </div>
      <div className="arwb-field" style={{ marginTop: 10 }}>
        <span className="arwb-field-label">Attachments (up to {MAX_FILES})</span>
        <div className="arwb-attach-list" style={{ marginBottom: 6 }}>
          {files.map((f, i) => (
            <span key={`${f.name}-${i}`} className="arwb-chip">
              {f.name} <button type="button" className="arwb-link-btn" aria-label={`Remove ${f.name}`} onClick={() => setFiles(files.filter((_, j) => j !== i))}>×</button>
            </span>
          ))}
        </div>
        {files.length < MAX_FILES && (
          <label className="arwb-btn arwb-btn-sm arwb-upload">
            <Icon name="upload" size={15} /> Add file
            <input type="file" multiple accept={allowed.split(',').map((x) => `.${x.trim()}`).join(',')}
              onChange={(e) => { addFiles([...(e.target.files || [])]); e.target.value = ''; }} />
          </label>
        )}
        <small className="arwb-hint">Allowed: {allowed}. Up to {fmt.count(Math.round(maxBytes / 1048576))} MB each.</small>
      </div>
    </Modal>
  );
}

function ViewModal({ row, onClose }) {
  const { labId } = useWorkbench();
  return (
    <Modal wide title={`Escalation ${row.caseNumber}`} submitLabel={null} onClose={onClose}>
      <RequestSummary row={row} />
      <div className="arwb-field">
        <span className="arwb-field-label">Response</span>
        {row.clientResponseText
          ? <div><div style={{ whiteSpace: 'pre-wrap' }}>{row.clientResponseText}</div><div className="arwb-hint">{row.clientRespondedBy} · {fmt.dateTime(row.clientRespondedOn)}</div></div>
          : <span className="text-muted-ink">No response yet.</span>}
      </div>
      <div className="arwb-field" style={{ marginTop: 10 }}>
        <span className="arwb-field-label">Attachments</span>
        <Attachments labId={labId} files={row.attachments} />
      </div>
    </Modal>
  );
}

export default function ClientCipPage() {
  const { labId, user } = useWorkbench();
  // T066: a viewer limited to a clinic or provider sees the requests read-only.
  const readOnly = user?.roleCode === 'viewer' && ['clinic', 'provider'].includes(user?.access?.level);
  const [tab, setTab] = useState('awaiting');
  const [searchText, setSearchText] = useState('');
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState({ page: 1, pageSize: 25, sortBy: 'requestedOn', sortDesc: false });
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState(null);
  const [responding, setResponding] = useState(null);
  const [viewing, setViewing] = useState(null);
  const [busy, setBusy] = useState('');
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    const t = setTimeout(() => { if (searchText.trim() !== search) { setSearch(searchText.trim()); setQuery((q) => ({ ...q, page: 1 })); } }, 400);
    return () => clearTimeout(t);
  }, [searchText]); // eslint-disable-line react-hooks/exhaustive-deps

  const status = TABS.find(([id]) => id === tab)[2];
  const filter = useMemo(() => ({ labId, status, search, ...query }), [labId, status, search, query]);
  const load = useCallback((signal) => {
    setLoading(true);
    setError('');
    return arWorkbenchService.clientCipQueue(filter, signal)
      .then((r) => { setData(r); setLoading(false); })
      .catch((e) => { if (e.name !== 'AbortError') { setError(e.message); setLoading(false); } });
  }, [filter]);
  useEffect(() => {
    const controller = new AbortController();
    load(controller.signal);
    return () => controller.abort();
  }, [load, reloadKey]);

  const c = data?.counts;
  const rows = data?.rows?.items || [];

  async function downloadTemplate() {
    setBusy('template');
    try { await arWorkbenchService.clientCipTemplate(labId); } catch (e) { setError(e.message); } finally { setBusy(''); }
  }
  async function uploadTemplate(file) {
    if (!file) return;
    setBusy('upload');
    setError('');
    try {
      const r = await arWorkbenchService.clientCipUpload(labId, file);
      setNotice({ kind: r.updated ? 'good' : 'info', text: r.message, details: r.errors });
      setReloadKey((k) => k + 1);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy('');
    }
  }

  const columns = [
    { key: 'claimID', label: 'Claim ID', render: (r) => <span className="mono">{r.claimID}</span> },
    { key: 'caseNumber', label: 'Case ID', render: (r) => <span className="mono">{r.caseNumber}</span> },
    { key: 'payerName', label: 'Payer', sortKey: 'payerName', wrap: true },
    { key: 'patientID', label: 'Patient Acct', render: (r) => <span className="mono">{r.patientID || '—'}</span> },
    { key: 'dateOfService', label: 'DOS', render: (r) => fmt.date(r.dateOfService), csv: (r) => fmt.date(r.dateOfService) },
    { key: 'caseStatus', label: 'Status', csv: (r) => r.caseStatus,
      render: (r) => <Badge className={CIP_BADGE[r.caseStatus]}>{r.caseStatus === 'Returned to Agent' ? 'Resolved' : r.caseStatus}{r.roundNumber > 1 ? ` · Round ${r.roundNumber}` : ''}</Badge> },
    { key: 'cipCategory', label: 'Category', wrap: true },
    { key: 'requiredInfo', label: 'Information Requested', wrap: true },
    { key: 'cipComment', label: 'Request From Your AR Team', wrap: true, render: (r) => <span className="arwb-clamp-2">{r.cipComment}</span>, csv: (r) => r.cipComment },
    { key: 'feedback', label: 'Reviewer Feedback', wrap: true, csv: (r) => (r.lastReviewDecision === 'insufficient' ? r.lastReviewNote || '' : ''),
      render: (r) => (r.lastReviewDecision === 'insufficient'
        ? <span><Badge className="arwb-badge-critical" dot>Needs more info</Badge> {r.lastReviewNote}</span>
        : <span className="text-muted-ink">—</span>) },
    { key: 'attachments', label: 'Attachments', csv: (r) => (r.attachments || []).map((a) => a.fileName).join('; '), render: (r) => <Attachments labId={labId} files={r.attachments} /> },
    { key: 'action', label: 'Action', align: 'end', csv: () => '',
      render: (r) => (r.caseStatus === 'Sent to Client' && !readOnly
        ? <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={(e) => { e.stopPropagation(); setResponding(r); }}>Respond</button>
        : <button type="button" className="arwb-btn arwb-btn-sm" onClick={(e) => { e.stopPropagation(); setViewing(r); }}>View</button>) }
  ];

  return (
    <>
      <div className="arwb-card arwb-section" style={{ padding: 16 }}>
        <div className="arwb-hint">
          {readOnly
            ? 'These are the requests your AR team sent for your clinic / provider. Your access is read-only — the client contact responds.'
            : 'Your AR team needs information on the items below. Respond with what is requested and attach any supporting documentation — they will review it and follow up. Items needing more information after review are marked and sent back to you.'}
        </div>
        <div className="arwb-grid arwb-grid-kpi" style={{ marginTop: 12 }}>
          {TABS.map(([id, label, , key]) => (
            <button key={id} type="button" className={`arwb-kpi arwb-kpi-tile arwb-kpi-tile-btn${tab === id ? ' active' : ''}`} aria-pressed={tab === id}
              onClick={() => { setTab(id); setQuery((q) => ({ ...q, page: 1 })); }}>
              <span className="arwb-kpi-label">{label}</span><span className="arwb-kpi-value mono">{c ? fmt.count(c[key]) : '…'}</span>
            </button>
          ))}
        </div>
        {!readOnly && (
          <>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 14 }}>
              <button type="button" className="arwb-btn arwb-btn-sm" disabled={!!busy || !c?.sentToClient} onClick={downloadTemplate}>
                {busy === 'template' ? <span className="arwb-spinner" /> : <Icon name="download" size={15} />} Download Response Template
              </button>
              <label className={`arwb-btn arwb-btn-sm arwb-upload${busy ? ' disabled' : ''}`} aria-disabled={!!busy}>
                {busy === 'upload' ? <><span className="arwb-spinner" /> Uploading…</> : <><Icon name="upload" size={15} /> Upload Completed Template</>}
                <input type="file" accept=".csv,text/csv" disabled={!!busy} onChange={(e) => { uploadTemplate(e.target.files?.[0]); e.target.value = ''; }} />
              </label>
            </div>
            <div className="arwb-hint" style={{ marginTop: 8 }}>
              The template is a CSV file that opens in Excel. Fill in the Response column (and Attachment Notes, if useful) and upload it to answer every row at once — to attach documents, use Respond on an individual request.
            </div>
          </>
        )}
      </div>

      <Notice notice={notice} onClose={() => setNotice(null)} />
      <ErrorBox message={error} />

      <div className="arwb-card arwb-card-flush">
        <div className="arwb-card-head">
          <Icon name="warn" size={16} /><h3>{TABS.find(([id]) => id === tab)[1]}</h3>
          <div className="arwb-card-head-actions">
            <input type="search" className="arwb-input" style={{ width: 240 }} placeholder="Claim ID, case, patient acct…" value={searchText}
              onChange={(e) => setSearchText(e.target.value)} aria-label="Search requests" />
          </div>
        </div>
        <DataTable
          tableId="client-cip-v2"
          exportName="escalation-requests"
          columns={columns}
          rows={rows}
          totalCount={data?.rows?.totalCount || 0}
          page={query.page}
          pageSize={query.pageSize}
          sortBy={query.sortBy}
          sortDesc={query.sortDesc}
          loading={loading}
          rowKey={(r) => r.cipCaseId}
          emptyText={tab === 'awaiting' ? 'Nothing is waiting for your response.' : 'No requests here.'}
          onSort={(sortBy, sortDesc) => setQuery((q) => ({ ...q, sortBy, sortDesc, page: 1 }))}
          onPage={(page) => setQuery((q) => ({ ...q, page }))}
          onPageSize={(pageSize) => setQuery((q) => ({ ...q, pageSize, page: 1 }))}
          onRowClick={(r) => setViewing(r)}
        />
      </div>

      {responding && (
        <RespondModal row={responding} onClose={() => setResponding(null)}
          onDone={(r) => { setResponding(null); setNotice({ kind: 'good', text: r.message }); setReloadKey((k) => k + 1); }} />
      )}
      {viewing && <ViewModal row={viewing} onClose={() => setViewing(null)} />}
    </>
  );
}
