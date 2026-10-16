import { useState } from 'react';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';
import Icon from './Icon';
import { Badge, ErrorBox } from './Status';
import useTableSort from './useTableSort';

// Claim documents (handoff §8.2): follow-up attachments and client CIP responses. Shared by the
// claim's Documents tab and the Document Vault. Every download goes through the API, which checks
// the claim's scope and writes the HIPAA access log.

const SOURCE_LABEL = { FollowUp: 'Follow-up', CipResponse: 'CIP response', Other: 'Other' };

function size(bytes) {
  if (!bytes && bytes !== 0) return '—';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

export function DocumentTable({ rows: all, showClaim = false, onOpenClaim }) {
  const { labId } = useWorkbench();
  const [error, setError] = useState('');
  const { rows, th } = useTableSort(all, {
    uploaded: (d) => d.uploadedOn, file: (d) => d.fileName, category: (d) => d.documentCategory, source: (d) => d.documentSource,
    claim: (d) => d.claimID, patient: (d) => d.patientName, by: (d) => d.uploadedBy, size: (d) => d.sizeBytes
  }, { key: 'uploaded', desc: true });

  async function download(d) {
    setError('');
    try { await arWorkbenchService.downloadDocument(labId, d.documentId, d.fileName); }
    catch (e) { setError(e.message || 'The document could not be downloaded.'); }
  }

  if (!all.length) return <div className="arwb-empty-state"><Icon name="filetext" /><div>No documents.</div></div>;
  return (
    <>
      <ErrorBox message={error} />
      <div className="arwb-table-wrap">
        <table className="arwb-data-table">
          <thead>
            <tr>
              {th('uploaded', 'Uploaded')}{th('file', 'File')}{th('category', 'Category')}{th('source', 'Source')}
              {showClaim && <>{th('claim', 'Claim')}{th('patient', 'Patient')}</>}
              {th('by', 'Uploaded By')}{th('size', 'Size', { className: 'num' })}
              <th scope="col" className="num">Action</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((d) => (
              <tr key={d.documentId}>
                <td>{fmt.dateTime(d.uploadedOn)}</td>
                <td className="wrap">{d.fileName}{d.description ? <div className="arwb-hint">{d.description}</div> : null}</td>
                <td><Badge className="arwb-badge-accent">{d.documentCategory}</Badge></td>
                <td>{SOURCE_LABEL[d.documentSource] || d.documentSource}{d.roundNumber ? ` · round ${d.roundNumber}` : ''}</td>
                {showClaim && (
                  <>
                    <td className="mono">
                      {onOpenClaim
                        ? <button type="button" className="arwb-link-btn" onClick={() => onOpenClaim(d)}>{d.claimID}</button>
                        : d.claimID}
                      {d.accessionNumber ? <div className="arwb-hint">Visit {d.accessionNumber}</div> : null}
                    </td>
                    <td className="wrap">{d.patientName || '—'}{d.patientID ? <div className="arwb-hint mono">{d.patientID}</div> : null}</td>
                  </>
                )}
                <td>{d.uploadedBy}</td>
                <td className="num">{size(d.sizeBytes)}</td>
                <td className="num">
                  <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => download(d)}><Icon name="download" size={14} /> Download</button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}

export const MAX_DOCUMENTS = 5;
export const MAX_DESCRIPTION = 500;

// The lab's attachment rules (Master Values settings), with the API's defaults.
export function useAttachmentRules() {
  const { masterData } = useWorkbench();
  const categories = masterData?.lists?.DOCUMENT_CATEGORY || [];
  const maxBytes = Number(masterData?.settings?.AttachmentMaxBytes) || 15 * 1024 * 1024;
  const allowed = String(masterData?.settings?.AttachmentAllowedTypes || 'pdf,png,jpg,jpeg,tif,tiff,gif,doc,docx,xls,xlsx,csv,txt')
    .split(',').map((t) => t.trim().replace(/^\./, '').toLowerCase()).filter(Boolean);
  return { categories, maxBytes, allowed };
}

// The first problem with the documents to upload, or '' when they can go (the API checks again).
export function validateDocuments(docs, { maxBytes, allowed }) {
  for (const d of docs) {
    const name = d.file.name;
    if (!d.category) return `${name}: choose a document category.`;
    if (d.file.size > maxBytes) return `${name} is larger than ${Math.round(maxBytes / 1024 / 1024)} MB.`;
    if (!allowed.includes((name.split('.').pop() || '').toLowerCase())) return `${name}: that file type is not allowed (${allowed.join(', ')}).`;
    if ((d.description || '').length > MAX_DESCRIPTION) return `${name}: the description must be ${MAX_DESCRIPTION} characters or fewer.`;
  }
  return '';
}

let nextDocId = 1;

// One row per document: the file, its category and a description. "Add documents" picks one or more
// files; each becomes a row (category defaults to the one used last). Up to MAX_DOCUMENTS rows.
export function DocumentRowsEditor({ docs, onChange, disabled }) {
  const { categories, maxBytes, allowed } = useAttachmentRules();
  const [inputKey, setInputKey] = useState(0);
  const room = MAX_DOCUMENTS - docs.length;

  function add(fileList) {
    const lastCategory = docs.length ? docs[docs.length - 1].category : '';
    const added = Array.from(fileList || []).slice(0, Math.max(room, 0))
      .map((file) => ({ id: nextDocId++, file, category: lastCategory, description: '' }));
    if (added.length) onChange([...docs, ...added]);
    setInputKey((k) => k + 1);
  }
  const update = (id, patch) => onChange(docs.map((d) => (d.id === id ? { ...d, ...patch } : d)));
  const remove = (id) => onChange(docs.filter((d) => d.id !== id));

  return (
    <div>
      {docs.length > 0 && (
        <div className="arwb-table-wrap" style={{ marginBottom: 8 }}>
          <table className="arwb-data-table">
            <thead>
              <tr>
                <th scope="col">File</th>
                <th scope="col" style={{ width: 200 }}>Category *</th>
                <th scope="col">Description</th>
                <th scope="col" className="num" aria-label="Remove" />
              </tr>
            </thead>
            <tbody>
              {docs.map((d, i) => (
                <tr key={d.id}>
                  <td className="wrap">{d.file.name}<div className="arwb-hint">{size(d.file.size)}</div></td>
                  <td>
                    <select className="arwb-select" aria-label={`Category for ${d.file.name}`} value={d.category} disabled={disabled}
                      onChange={(e) => update(d.id, { category: e.target.value })}>
                      <option value="">{categories.length ? 'Choose…' : 'No document categories set up'}</option>
                      {categories.map((c) => <option key={c} value={c}>{c}</option>)}
                    </select>
                  </td>
                  <td>
                    <input className="arwb-input" aria-label={`Description for ${d.file.name}`} maxLength={MAX_DESCRIPTION} disabled={disabled}
                      placeholder={i === 0 ? 'e.g. Appeal letter sent to payer' : 'What is this document?'}
                      value={d.description} onChange={(e) => update(d.id, { description: e.target.value })} />
                  </td>
                  <td className="num">
                    <button type="button" className="arwb-btn arwb-btn-sm" disabled={disabled} onClick={() => remove(d.id)}
                      title="Remove" aria-label={`Remove ${d.file.name}`}><Icon name="trash" size={14} /></button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <label className="arwb-btn arwb-btn-sm"
        style={disabled || room <= 0 ? { opacity: 0.45, cursor: 'not-allowed' } : { cursor: 'pointer' }}>
        <Icon name="plus" size={14} /> {docs.length ? 'Add more documents' : 'Add documents'}
        <input key={inputKey} type="file" multiple hidden disabled={disabled || room <= 0} accept={allowed.map((t) => `.${t}`).join(',')}
          onChange={(e) => add(e.target.files)} />
      </label>
      <div className="arwb-field-note">
        Up to {MAX_DOCUMENTS} documents, {Math.round(maxBytes / 1024 / 1024)} MB each ({allowed.join(', ')}). Each needs a category; the description is optional.
        {room <= 0 ? ' The limit is reached - remove one to add another.' : ''}
      </div>
    </div>
  );
}

// Attach documents to a claim, each with a mandatory category and a description (DEF-13). AR users only; the API enforces scope.
export function UploadDocuments({ claimKey, onUploaded }) {
  const { labId } = useWorkbench();
  const rules = useAttachmentRules();
  const [docs, setDocs] = useState([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function upload() {
    setError('');
    if (!docs.length) { setError('Add at least one document.'); return; }
    const problem = validateDocuments(docs, rules);
    if (problem) { setError(problem); return; }
    setBusy(true);
    try {
      const r = await arWorkbenchService.uploadClaimDocuments(labId, claimKey, docs);
      setDocs([]);
      onUploaded?.(r?.message || 'Uploaded.');
    } catch (e) {
      setError(e.message || 'The documents could not be uploaded.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="arwb-card" style={{ marginBottom: 12 }}>
      <ErrorBox message={error} />
      <DocumentRowsEditor docs={docs} onChange={setDocs} disabled={busy} />
      {docs.length > 0 && (
        <button type="button" className="arwb-btn arwb-btn-primary arwb-btn-sm" style={{ marginTop: 8 }} disabled={busy} onClick={upload}>
          {busy ? 'Uploading…' : <><Icon name="upload" size={14} /> Attach {docs.length} to Claim</>}
        </button>
      )}
    </div>
  );
}
