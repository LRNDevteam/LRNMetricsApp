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
      {files.map((f) => (
        <button key={f.documentId} type="button" className="arwb-link-btn" title={`${f.fileName} · ${fmt.count(Math.ceil(f.sizeBytes / 1024))} KB`}
          onClick={(e) => { e.stopPropagation(); arWorkbenchService.downloadDocument(labId, f.documentId, f.fileName); }}>
          <Icon name="doc" size={13} /> {f.fileName}
        </button>
      ))}
    </span>
  );
}
