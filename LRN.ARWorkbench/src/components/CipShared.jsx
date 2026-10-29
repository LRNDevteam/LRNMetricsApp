import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';
import Icon from './Icon';

// Shared by the internal CIP Escalations queue, the client's Escalation Requests and the claim page.
export const CIP_BADGE = {
  'Awaiting QA': 'arwb-badge-neutral', 'Pending Approval': 'arwb-badge-warning', 'Sent to Client': 'arwb-badge-info',
  'Client Responded': 'arwb-badge-purple', 'Returned to Agent': 'arwb-badge-good'
};

/** Download links for a CIP response's attachments (each download is logged server-side). */
export function Attachments({ labId, files }) {
  if (!files?.length) return <span className="text-muted-ink">—</span>;
  return (
    <span className="arwb-attach-list">
      {files.map((f) => f.scanStatus === 'Malicious' ? (
        // Quarantined by the virus scan: shown, never downloadable.
        <span key={f.documentId} className="arwb-quarantine-label" title="Virus detected - this document is quarantined and cannot be downloaded.">
          <Icon name="warn" size={13} /> {f.fileName} (virus - quarantined)
        </span>
      ) : (
        <button key={f.documentId} type="button" className="arwb-link-btn" title={`${f.fileName} · ${fmt.count(Math.ceil(f.sizeBytes / 1024))} KB`}
          onClick={(e) => {
            e.stopPropagation();
            // A refused download (still being scanned, blocked, integrity failure) must not fail silently.
            arWorkbenchService.downloadDocument(labId, f.documentId, f.fileName)
              .catch((err) => window.alert(err?.message || 'The document could not be downloaded.'));
          }}>
          <Icon name="doc" size={13} /> {f.fileName}
        </button>
      ))}
    </span>
  );
}
