import { useState } from 'react';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import Modal from './Modal';
import { ErrorBox } from './Status';

const KINDS = {
  escalation: {
    title: 'Escalate to Supervisor', list: 'ESCALATION_REASON', submit: 'Escalate',
    noteLabel: 'What do you need help with? *', placeholder: 'What you have tried, and what you need the supervisor to decide or do.',
    help: 'The claim stays with you. A Team Lead, RCM Manager or Administrator sees this in Escalation & Reassignment Requests and responds there.'
  },
  reassignment: {
    title: 'Request Reassignment', list: 'REASSIGNMENT_REASON', submit: 'Request Reassignment',
    noteLabel: 'Why should it be reassigned? *', placeholder: 'Anything the next agent or the lead should know.',
    help: 'The claim stays with you until a lead reassigns it; reassigning it resolves this request.'
  }
};

/** An AR agent's Escalate to Supervisor / Request Reassignment on one claim (POST claims/{key}/agent-requests). */
export default function AgentRequestModal({ claim, kind, onClose, onDone }) {
  const { labId, masterData } = useWorkbench();
  const k = KINDS[kind];
  const reasons = masterData?.lists?.[k.list] || [];
  const [reason, setReason] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function submit() {
    if (!reason) { setError('Choose a reason.'); return; }
    if (!note.trim()) { setError('Add a note so the lead knows what you need.'); return; }
    setBusy(true);
    setError('');
    try {
      const r = await arWorkbenchService.createAgentRequest(labId, claim.ClaimKey, { requestType: kind, reasonCategory: reason, note: note.trim() });
      onDone(r?.message || `${k.title} sent.`);
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  }

  return (
    <Modal title={k.title} subtitle={`Claim ${claim.ClaimID}`} submitLabel={k.submit} busy={busy} busyLabel="Sending…" onClose={onClose} onSubmit={submit}>
      <ErrorBox message={error} />
      <div className="arwb-field">
        <label htmlFor="req-reason">Reason *</label>
        <select id="req-reason" className="arwb-select" value={reason} onChange={(e) => setReason(e.target.value)}>
          <option value="">{reasons.length ? 'Select a reason' : 'No reasons set up (Master Values > Workbench Lists)'}</option>
          {reasons.map((r) => <option key={r} value={r}>{r}</option>)}
        </select>
      </div>
      <div className="arwb-field">
        <label htmlFor="req-note">{k.noteLabel}</label>
        <textarea id="req-note" className="arwb-textarea" rows={4} maxLength={2000} placeholder={k.placeholder}
          value={note} onChange={(e) => setNote(e.target.value)} />
      </div>
      <div className="arwb-section-note">{k.help}</div>
    </Modal>
  );
}
