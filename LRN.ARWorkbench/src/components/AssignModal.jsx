import { useEffect, useState } from 'react';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';
import Modal from './Modal';
import { ErrorBox } from './Status';

/**
 * The mockup's shared Assign dialog (App.openAssignModal): pick an AR Agent or Team Lead, an
 * optional note and due date, and assign the selected claims. Claims already assigned are
 * reassigned; the API records the previous agent and resolves any pending reassignment request.
 *
 * agents: optional, from a screen that already loaded them (with workload); otherwise fetched.
 */
export default function AssignModal({ labId, claimKeys, agents: givenAgents, excludeAgent, onClose, onDone }) {
  const [agents, setAgents] = useState(givenAgents || null);
  const [agentUser, setAgentUser] = useState('');
  const [note, setNote] = useState('');
  const [dueDate, setDueDate] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (givenAgents) return;
    arWorkbenchService.assignableAgents(labId)
      .then((list) => setAgents(list || []))
      .catch((e) => { setAgents([]); setError(e.message || 'The agent list could not be loaded.'); });
  }, [labId, givenAgents]);

  const choices = (agents || []).filter((a) => a.isAssignable && a.userName !== excludeAgent);
  const count = claimKeys.length;

  async function submit() {
    if (!agentUser) { setError('Choose the agent to assign to.'); return; }
    setBusy(true);
    setError('');
    try {
      const result = await arWorkbenchService.assignClaims(labId, { claimKeys, agentUser, note: note.trim() || null, dueDate: dueDate || null });
      onDone?.(result);
    } catch (e) {
      setError(e.message || 'The claims could not be assigned.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal
      title={`Assign ${fmt.count(count)} claim${count === 1 ? '' : 's'}`}
      submitLabel="Assign"
      busy={busy}
      busyLabel="Assigning…"
      onClose={onClose}
      onSubmit={submit}>
      <ErrorBox message={error} />
      <div className="arwb-field">
        <label htmlFor="assign-agent">Assign to AR Agent *</label>
        <select id="assign-agent" className="arwb-select" value={agentUser} disabled={agents === null} onChange={(e) => setAgentUser(e.target.value)}>
          <option value="">{agents === null ? 'Loading agents…' : choices.length ? 'Select an agent' : 'No AR Agents or Team Leads have access to this lab'}</option>
          {choices.map((a) => (
            <option key={a.userName} value={a.userName}>
              {a.displayName} ({a.roleLabel}){a.openClaims !== undefined && givenAgents ? ` · ${fmt.count(a.openClaims)} open` : ''}
            </option>
          ))}
        </select>
      </div>
      <div className="arwb-field">
        <label htmlFor="assign-due">Due date (optional)</label>
        <input id="assign-due" type="date" className="arwb-input" value={dueDate} min={new Date().toISOString().slice(0, 10)} onChange={(e) => setDueDate(e.target.value)} />
      </div>
      <div className="arwb-field">
        <label htmlFor="assign-note">Note (optional)</label>
        <textarea id="assign-note" className="arwb-textarea" rows={2} maxLength={1000} placeholder="Reason for this assignment / batch context"
          value={note} onChange={(e) => setNote(e.target.value)} />
      </div>
      <div className="arwb-section-note">
        {fmt.count(count)} claim{count === 1 ? '' : 's'} selected. Claims already assigned are reassigned — the previous agent is recorded in the
        audit trail, and a pending reassignment request on the claim is resolved.
      </div>
    </Modal>
  );
}
