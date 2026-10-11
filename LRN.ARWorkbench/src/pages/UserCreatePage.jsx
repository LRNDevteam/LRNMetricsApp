import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router';
import Icon from '../components/Icon';
import { ErrorBox, Loading } from '../components/Status';
import { LabPicker, ScopePicker, scopesBody } from '../components/UserFormParts';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';

// User Management > Add User (#/users/new). No password is set here: the API emails the user an
// invitation with their username, a one-time password and a single-use link to LRN Metrics, where
// they create their own password. Several users may share one email address.

export default function UserCreatePage() {
  const { labId } = useWorkbench();
  const navigate = useNavigate();
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [form, setForm] = useState({ userName: '', email: '', roleId: '', labIds: [], managerUserId: '', teamName: '', scopes: {} });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const set = (k, v) => setForm((f) => ({ ...f, [k]: v }));

  useEffect(() => {
    arWorkbenchService.users(labId)
      .then((d) => {
        setData(d);
        if (d.labs.length === 1) setForm((f) => ({ ...f, labIds: [d.labs[0].labId] }));
      })
      .catch((e) => setLoadError(e.message));
  }, [labId]);

  if (loadError) return <ErrorBox message={loadError} />;
  if (!data) return <Loading text="Loading…" />;

  const role = data.roles.find((r) => String(r.roleId) === String(form.roleId));
  const roleScope = role?.scope || null;
  const back = (notice) => navigate('/users', notice ? { state: { notice } } : undefined);

  async function save(e) {
    e.preventDefault();
    if (busy) return;
    if (!form.userName.trim()) { setError('Enter a username.'); return; }
    if (!form.email.trim()) { setError('Enter the email address the invitation goes to.'); return; }
    if (!form.roleId) { setError('Choose a role.'); return; }
    if (form.labIds.length === 0) { setError('Choose at least one lab.'); return; }
    if (roleScope && form.labIds.some((id) => !form.scopes[id])) {
      setError(`Choose the ${roleScope === 'clinic' ? 'clinic' : 'referring provider'} for every selected lab.`);
      return;
    }
    setBusy(true);
    setError('');
    try {
      const result = await arWorkbenchService.createUser(labId, {
        userName: form.userName.trim(),
        email: form.email.trim(),
        roleId: Number(form.roleId),
        labIds: form.labIds,
        managerUserId: form.managerUserId ? Number(form.managerUserId) : null,
        teamName: form.teamName.trim() || null,
        scopes: scopesBody(roleScope, form.labIds, form.scopes)
      });
      back({ kind: result?.emailSent === false ? 'warning' : 'good', text: result?.message || 'User created.' });
    } catch (err) {
      setError(err.message);
      setBusy(false);
    }
  }

  return (
    <form className="arwb-card arwb-card-flush" onSubmit={save} autoComplete="off">
      <div className="arwb-card-head">
        <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => back()} disabled={busy}>
          <Icon name="arrowLeft" size={15} /> Users
        </button>
        <h3>Add User</h3>
      </div>

      {error && <div style={{ padding: '12px 18px 0' }}><ErrorBox message={error} /></div>}

      <section className="arwb-form-section">
        <h4>Account</h4>
        <div className="arwb-form-grid">
          <div className="arwb-field">
            <label htmlFor="u-name">Username</label>
            <input id="u-name" className="arwb-input" maxLength={100} autoFocus value={form.userName} onChange={(e) => set('userName', e.target.value)} />
            <small className="arwb-hint">Letters, numbers and . _ @ - only. The user signs in with this.</small>
          </div>
          <div className="arwb-field">
            <label htmlFor="u-email">Email</label>
            <input id="u-email" type="email" className="arwb-input" maxLength={256} value={form.email} onChange={(e) => set('email', e.target.value)} />
            <small className="arwb-hint">The invitation with a one-time password and first-login link is sent here.</small>
          </div>
        </div>
      </section>

      <section className="arwb-form-section">
        <h4>Role and team</h4>
        <div className="arwb-form-grid">
          <div className="arwb-field">
            <label htmlFor="u-role">Role</label>
            <select id="u-role" className="arwb-select" value={form.roleId} onChange={(e) => set('roleId', e.target.value)}>
              <option value="">Choose a role…</option>
              {data.roles.map((r) => <option key={r.roleId} value={r.roleId}>{r.label}</option>)}
            </select>
            {roleScope && (
              <small className="arwb-hint">
                {roleScope === 'clinic' ? 'Clinic Viewer: sees only one clinic’s claims per lab.' : 'Provider Viewer: sees only one referring provider’s claims per lab.'}
              </small>
            )}
          </div>
          <div className="arwb-field">
            <label htmlFor="u-manager">Manager</label>
            <select id="u-manager" className="arwb-select" value={form.managerUserId} onChange={(e) => set('managerUserId', e.target.value)}>
              <option value="">No manager</option>
              {data.managers.map((m) => <option key={m.labUserId} value={m.labUserId}>{m.label}</option>)}
            </select>
          </div>
          <div className="arwb-field">
            <label htmlFor="u-team">Team</label>
            <input id="u-team" className="arwb-input" list="u-team-list" maxLength={100} value={form.teamName} onChange={(e) => set('teamName', e.target.value)} />
            <datalist id="u-team-list">{data.teams.map((t) => <option key={t} value={t} />)}</datalist>
          </div>
        </div>
      </section>

      <section className="arwb-form-section">
        <h4>Lab access</h4>
        <LabPicker labs={data.labs} selected={form.labIds} onChange={(v) => set('labIds', v)} />
        {roleScope && form.labIds.length > 0 && (
          <div style={{ marginTop: 14 }}>
            <ScopePicker labId={labId} roleScope={roleScope} labs={data.labs} labIds={form.labIds} scopes={form.scopes}
              onChange={(v) => set('scopes', v)} />
          </div>
        )}
      </section>

      <div className="arwb-form-actions">
        <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => back()} disabled={busy}>Cancel</button>
        <button type="submit" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={busy}>
          {busy ? <><span className="arwb-spinner" /> Creating…</> : <><Icon name="mail" size={14} /> Create User &amp; Send Invitation</>}
        </button>
      </div>
    </form>
  );
}
