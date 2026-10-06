import { useMemo, useState } from 'react';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import Modal from './Modal';
import { Badge, ErrorBox } from './Status';

// The mockup's Log Follow-Up Note (App.openFollowUpModal): the Comments Framework fields plus the
// next follow-up date. Options come from Master Values (masterData lists and Fix / Resolution by
// Claim Status). Saving sends the claim to the QA Verification Queue; the API holds every rule
// (ArWorkbenchFollowUpRules) - the checks here only save a round trip.

const CIP = 'CIP - Client Escalations';
const DENIED = 'Denied';

function addDays(days) {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return d.toISOString().slice(0, 10);
}

// suggestedRootCause: the primary code's Action Category from the Denial Code master; used as the
// default Denial Root Cause when it is on that list and the claim has none yet.
export default function FollowUpModal({ claim, lastFollowUp, onClose, onDone, suggestedRootCause }) {
  const { labId, masterData } = useWorkbench();
  const lists = masterData?.lists || {};
  const byStatus = masterData?.fixResolutionsByStatus || {};
  const defaultDays = Number(masterData?.settings?.NextFollowUpDefaultDays) || 45;

  const statuses = lists.CLAIM_STATUS || [];
  const initialStatus = statuses.includes(lastFollowUp?.followUpClaimStatus) ? lastFollowUp.followUpClaimStatus
    : statuses.includes('In Process') ? 'In Process' : statuses[0] || '';

  const fixesFor = (status) => (byStatus[status]?.length ? byStatus[status] : lists.FIX_RESOLUTION || []);
  const pickFix = (status, preferred) => { const l = fixesFor(status); return l.includes(preferred) ? preferred : l[0] || ''; };

  const [form, setForm] = useState(() => ({
    claimType: (lists.CLAIM_TYPE || []).includes('Primary') ? 'Primary' : (lists.CLAIM_TYPE || [])[0] || '',
    followUpType: (lists.FOLLOW_UP_TYPE || []).includes('Call') ? 'Call' : (lists.FOLLOW_UP_TYPE || [])[0] || '',
    claimStatus: initialStatus,
    denialRootCause: claim.DenialRootCause
      || (lists.DENIAL_ROOT_CAUSE || []).find((v) => suggestedRootCause && v.toLowerCase() === suggestedRootCause.toLowerCase())
      || (lists.DENIAL_ROOT_CAUSE || [])[0] || '',
    fixResolution: pickFix(initialStatus, claim.FixResolution),
    comment: '',
    nextFollowUpDate: addDays(defaultDays),
    cipCategory: (lists.CIP_CATEGORY || [])[0] || '',
    cipRequiredInfo: (lists.CIP_REQUIRED_INFO || [])[0] || '',
    cipComment: ''
  }));
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  const set = (k, v) => setForm((f) => ({ ...f, [k]: v }));
  const setStatus = (status) => setForm((f) => ({ ...f, claimStatus: status, fixResolution: pickFix(status, f.fixResolution) }));
  const fixOptions = useMemo(() => fixesFor(form.claimStatus), [form.claimStatus, byStatus, lists]); // eslint-disable-line react-hooks/exhaustive-deps
  const isDenied = form.claimStatus === DENIED;
  const isCip = form.fixResolution === CIP;

  async function save() {
    if (!form.comment.trim()) { setError('Add a follow-up comment: what did you find or do?'); return; }
    if (isCip && !form.cipComment.trim()) { setError('Add the CIP comment the client will see.'); return; }
    setBusy(true);
    setError('');
    try {
      const result = await arWorkbenchService.logFollowUp(labId, claim.ClaimKey, {
        claimType: form.claimType,
        followUpType: form.followUpType,
        claimStatus: form.claimStatus,
        denialRootCause: isDenied ? form.denialRootCause : null,
        fixResolution: form.fixResolution,
        comment: form.comment.trim(),
        nextFollowUpDate: form.nextFollowUpDate || null,
        cipCategory: isCip ? form.cipCategory : null,
        cipRequiredInfo: isCip ? form.cipRequiredInfo : null,
        cipComment: isCip ? form.cipComment.trim() : null
      });
      onDone?.(result);
    } catch (e) {
      setError(e.message || 'The follow-up note could not be saved.');
    } finally {
      setBusy(false);
    }
  }

  const select = (id, value, options, onChange) => (
    <select id={id} className="arwb-select" value={value} onChange={(e) => onChange(e.target.value)}>
      {!options.includes(value) && <option value={value}>{value || 'Select…'}</option>}
      {options.map((o) => <option key={o} value={o}>{o}</option>)}
    </select>
  );

  return (
    <Modal wide title="Log Follow-Up Note" submitLabel="Save Follow-Up Note" busy={busy} onClose={onClose} onSubmit={save}>
      <div className="arwb-section-note">
        Claim <b className="mono">{claim.ClaimID}</b> · {claim.LabName} · {claim.PayerName || '—'}. This logs what was found and done — fixes happen in
        the PMS / with the payer. Saving routes this claim to the QA Verification Queue.
      </div>
      <ErrorBox message={error} />
      <div className="arwb-form-grid">
        <div className="arwb-field"><label htmlFor="fu-ct">Claim Type</label>{select('fu-ct', form.claimType, lists.CLAIM_TYPE || [], (v) => set('claimType', v))}</div>
        <div className="arwb-field"><label htmlFor="fu-ft">Follow Up Type</label>{select('fu-ft', form.followUpType, lists.FOLLOW_UP_TYPE || [], (v) => set('followUpType', v))}</div>
        <div className="arwb-field"><label htmlFor="fu-cs">Claim Status</label>{select('fu-cs', form.claimStatus, statuses, setStatus)}</div>
        {isDenied
          ? <div className="arwb-field"><label htmlFor="fu-rc">Denial Root Cause *</label>{select('fu-rc', form.denialRootCause, lists.DENIAL_ROOT_CAUSE || [], (v) => set('denialRootCause', v))}</div>
          : <div />}
        <div className="arwb-field span-2">
          <label htmlFor="fu-fix">Fix / Resolution</label>
          {select('fu-fix', form.fixResolution, fixOptions, (v) => set('fixResolution', v))}
          <div className="arwb-field-note">Options are specific to the Claim Status selected above.</div>
        </div>
        <div className="arwb-field span-2">
          <label htmlFor="fu-comment">Follow Up Comment *</label>
          <textarea id="fu-comment" className="arwb-textarea" rows={3} maxLength={4000} placeholder="What did you find / do on this follow-up?"
            value={form.comment} onChange={(e) => set('comment', e.target.value)} />
        </div>
        <div className="arwb-field">
          <label htmlFor="fu-next">Next Follow-Up Date</label>
          <input id="fu-next" type="date" className="arwb-input" value={form.nextFollowUpDate} min={new Date().toISOString().slice(0, 10)}
            onChange={(e) => set('nextFollowUpDate', e.target.value)} />
          <div className="arwb-field-note">Drives the Re-follow-up Required queue — clear it if no further follow-up is expected.</div>
        </div>
      </div>

      {isCip && (
        <div className="arwb-card" style={{ background: 'var(--purple-soft)', borderColor: 'var(--purple)' }}>
          <div style={{ marginBottom: 8 }}>
            <Badge className="arwb-badge-purple" dot>CIP — Client Escalations</Badge>{' '}
            <span className="arwb-hint">Tracked separately so it can be shared with the client. It goes to approval once QA approves this note.</span>
          </div>
          <div className="arwb-form-grid">
            <div className="arwb-field"><label htmlFor="fu-cipc">CIP Category *</label>{select('fu-cipc', form.cipCategory, lists.CIP_CATEGORY || [], (v) => set('cipCategory', v))}</div>
            <div className="arwb-field"><label htmlFor="fu-cipi">Required Information *</label>{select('fu-cipi', form.cipRequiredInfo, lists.CIP_REQUIRED_INFO || [], (v) => set('cipRequiredInfo', v))}</div>
            <div className="arwb-field span-2">
              <label htmlFor="fu-cipm">CIP Comment *</label>
              <textarea id="fu-cipm" className="arwb-textarea" rows={3} maxLength={4000} placeholder="Detail for the client on what's required / what was escalated…"
                value={form.cipComment} onChange={(e) => set('cipComment', e.target.value)} />
            </div>
          </div>
        </div>
      )}
    </Modal>
  );
}
