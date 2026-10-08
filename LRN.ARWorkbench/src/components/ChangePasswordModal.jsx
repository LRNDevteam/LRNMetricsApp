import { useState } from 'react';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import Modal from './Modal';
import { ErrorBox } from './Status';

// Same rule as the API (ArWorkbenchUserRules.ValidatePassword): 8-128 characters, a letter and a number.
function passwordProblem(current, next, confirm) {
  if (!current) return 'Enter your current password.';
  if (next.length < 8 || next.length > 128) return 'New password must be 8 to 128 characters.';
  if (!/[A-Za-z]/.test(next) || !/\d/.test(next)) return 'New password must contain at least one letter and one number.';
  if (next === current) return 'The new password must be different from the current one.';
  if (next !== confirm) return 'The new passwords do not match.';
  return '';
}

/**
 * User menu > Change password: the signed-in user changes their own LRN Metrics password
 * (POST me/password). The API checks the current password; the session stays signed in.
 */
export default function ChangePasswordModal({ onClose, onChanged }) {
  const { labId, user } = useWorkbench();
  const [form, setForm] = useState({ current: '', next: '', confirm: '' });
  const [show, setShow] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const set = (key) => (e) => setForm((f) => ({ ...f, [key]: e.target.value }));

  async function submit() {
    const problem = passwordProblem(form.current, form.next, form.confirm);
    if (problem) { setError(problem); return; }
    setBusy(true);
    setError('');
    try {
      const r = await arWorkbenchService.changeOwnPassword(labId, { currentPassword: form.current, newPassword: form.next });
      onChanged(r?.message || 'Your password has been changed.');
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  }

  const type = show ? 'text' : 'password';
  return (
    <Modal title="Change password" subtitle={`Signed in as ${user?.userName}`} submitLabel="Change password" busy={busy} busyLabel="Changing…"
      onClose={onClose} onSubmit={submit}>
      <ErrorBox message={error} />
      <div className="arwb-field">
        <label htmlFor="pw-current">Current password *</label>
        <input id="pw-current" type={type} className="arwb-input" autoComplete="current-password" maxLength={128}
          value={form.current} onChange={set('current')} />
      </div>
      <div className="arwb-field">
        <label htmlFor="pw-new">New password *</label>
        <input id="pw-new" type={type} className="arwb-input" autoComplete="new-password" maxLength={128}
          value={form.next} onChange={set('next')} />
        <div className="arwb-field-note">8 to 128 characters, with at least one letter and one number.</div>
      </div>
      <div className="arwb-field">
        <label htmlFor="pw-confirm">Confirm new password *</label>
        <input id="pw-confirm" type={type} className="arwb-input" autoComplete="new-password" maxLength={128}
          value={form.confirm} onChange={set('confirm')} />
      </div>
      <label className="arwb-check" style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
        <input type="checkbox" checked={show} onChange={(e) => setShow(e.target.checked)} /> Show passwords
      </label>
      <p className="arwb-hint" style={{ margin: '10px 0 0' }}>This is your LRN Metrics password: it changes for every LRN application you sign in to.</p>
    </Modal>
  );
}
