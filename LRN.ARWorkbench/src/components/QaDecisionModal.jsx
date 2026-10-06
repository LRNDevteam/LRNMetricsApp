import { useState } from 'react';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import Modal from './Modal';
import { ErrorBox } from './Status';

// The six quality-scoring criteria (mockup renderQa).
export const QA_CRITERIA = [
  ['claimAnalysis', 'Correct claim analysis'],
  ['denialCategory', 'Correct denial categorization'],
  ['actionTaken', 'Appropriate action taken'],
  ['documentation', 'Proper documentation'],
  ['financialUpdate', 'Accurate financial updates'],
  ['followUpTiming', 'Correct / timely follow-up']
];

/**
 * Approve or Reject (Return for Correction) one claim's follow-up note. Reject needs an Error
 * Type (QA_ERROR_TYPE list) and a note, and returns the claim to the same agent under QA Rejected.
 * row: { claimKey, claimID, isEscalation, isWriteOff, followUpComment, fixResolution }.
 */
export default function QaDecisionModal({ row, decision, onClose, onDone }) {
  const { labId, masterData } = useWorkbench();
  const errorTypes = masterData?.lists?.QA_ERROR_TYPE?.length ? masterData.lists.QA_ERROR_TYPE
    : ['Incomplete Documentation', 'Incorrect Denial Category', 'Missed Follow-Up', 'Financial Update Error', 'Other'];
  const approve = decision === 'approve';
  const [errorType, setErrorType] = useState(errorTypes[0]);
  const [note, setNote] = useState('');
  const [scores, setScores] = useState(() => Object.fromEntries(QA_CRITERIA.map(([k]) => [k, approve])));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function submit() {
    if (!approve && !note.trim()) { setError('Add a note explaining what needs correcting.'); return; }
    setBusy(true);
    setError('');
    try {
      const r = await arWorkbenchService.qaDecision(labId, row.claimKey, { decision, errorType: approve ? null : errorType, note: note.trim() || null, scores });
      onDone(r);
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  }

  return (
    <Modal title={approve ? `Approve ${row.claimID}` : `Return ${row.claimID} for Correction`} busy={busy} busyLabel={approve ? 'Approving…' : 'Returning…'}
      submitLabel={approve ? 'Approve' : 'Return to Agent'} submitClass={approve ? 'arwb-btn-primary' : 'arwb-btn-danger'} onClose={onClose} onSubmit={submit}
      subtitle={approve
        ? (row.isEscalation ? 'CIP escalation: approving moves it to Pending Approval (CIP Escalations).' : row.isWriteOff ? 'Write Off: approving makes it an Approved Write-Off to post in the PMS.' : 'The claim moves to Completed.')
        : 'The claim goes back to the same AR agent under QA Rejected.'}>
      <ErrorBox message={error} />
      {(row.fixResolution || row.followUpComment) && (
        <div className="arwb-hint" style={{ marginBottom: 10 }}>
          <b>{row.fixResolution}</b>{row.followUpComment ? ` — ${row.followUpComment}` : ''}
        </div>
      )}
      {!approve && (
        <div className="arwb-field">
          <label htmlFor="qa-err">Error Type</label>
          <select id="qa-err" className="arwb-select" value={errorType} onChange={(e) => setErrorType(e.target.value)}>
            {errorTypes.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        </div>
      )}
      <div className="arwb-field" style={{ marginTop: 10 }}>
        <label htmlFor="qa-note">{approve ? 'Note (optional)' : 'What needs correction?'}</label>
        <textarea id="qa-note" className="arwb-input" rows={3} maxLength={2000} value={note} onChange={(e) => setNote(e.target.value)} />
      </div>
      <div className="arwb-field" style={{ marginTop: 10 }}>
        <span className="arwb-field-label">Quality Scoring Criteria</span>
        <div className="arwb-qa-criteria">
          {QA_CRITERIA.map(([k, label]) => (
            <label key={k}><input type="checkbox" checked={!!scores[k]} onChange={(e) => setScores((s) => ({ ...s, [k]: e.target.checked }))} /> {label}</label>
          ))}
        </div>
      </div>
    </Modal>
  );
}
