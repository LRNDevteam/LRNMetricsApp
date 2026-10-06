import { useCallback, useEffect, useMemo, useState } from 'react';
import Icon from '../components/Icon';
import Modal from '../components/Modal';
import { Badge, ErrorBox, Loading, Notice } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';

// The mockup's User Management (App.views.users), on the real LRNMaster user tables. A Super Admin
// manages every lab; an AR Workbench System Administrator (or Lab Admin) manages the labs assigned
// to them. A user is created with a username, password, email, one AR Workbench role and one or
// more labs, and signs in with those LRN Metrics credentials. The API enforces every rule; rows the
// caller may not change come back read-only with the reason.

function LabPicker({ labs, selected, onChange }) {
  const [term, setTerm] = useState('');
  const sel = new Set(selected);
  const shown = labs.filter((l) => l.labName.toLowerCase().includes(term.trim().toLowerCase()));
  const toggle = (id) => onChange(sel.has(id) ? selected.filter((x) => x !== id) : [...selected, id]);
  const allShown = shown.length > 0 && shown.every((l) => sel.has(l.labId));
  const toggleAll = () => onChange(allShown
    ? selected.filter((id) => !shown.some((l) => l.labId === id))
    : [...new Set([...selected, ...shown.map((l) => l.labId)])]);

  return (
    <div className="arwb-check-list">
      {labs.length > 8 && (
        <input type="search" className="arwb-input" placeholder="Find a lab…" value={term} onChange={(e) => setTerm(e.target.value)} aria-label="Find a lab" />
      )}
      <label className="arwb-check-item arwb-check-all">
        <input type="checkbox" checked={allShown} onChange={toggleAll} /> {term ? 'All matching' : 'All labs'}
      </label>
      <div className="arwb-check-items">
        {shown.map((l) => (
          <label key={l.labId} className="arwb-check-item">
            <input type="checkbox" checked={sel.has(l.labId)} onChange={() => toggle(l.labId)} /> {l.labName}
          </label>
        ))}
        {shown.length === 0 && <span className="arwb-hint">No lab matches.</span>}
      </div>
      <small className="arwb-hint">{selected.length} selected</small>
    </div>
  );
}

function UserModal({ data, user, onClose, onSaved }) {
  const { labId } = useWorkbench();
  const isNew = !user;
  const currentRole = user?.roles?.find((r) => data.roles.some((x) => x.roleId === r.roleId))?.roleId;
  const [form, setForm] = useState(() => ({
    userName: user?.userName || '',
    email: user?.email || '',
    password: '',
    roleId: currentRole || '',
    labIds: user ? user.labs.map((l) => l.labId) : (data.labs.length === 1 ? [data.labs[0].labId] : []),
    isActive: user ? user.isActive : true
  }));
  const [showPassword, setShowPassword] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const set = (k, v) => setForm((f) => ({ ...f, [k]: v }));

  async function save() {
    if (isNew && !form.userName.trim()) { setError('Enter a username.'); return; }
    if (!form.email.trim()) { setError('Enter an email address.'); return; }
    if (isNew && !form.password) { setError('Enter a password.'); return; }
    if (!form.roleId) { setError('Choose a role.'); return; }
    if (form.labIds.length === 0) { setError('Choose at least one lab.'); return; }
    setBusy(true);
    setError('');
    try {
      const body = { email: form.email.trim(), roleId: Number(form.roleId), labIds: form.labIds };
      const result = isNew
        ? await arWorkbenchService.createUser(labId, { ...body, userName: form.userName.trim(), password: form.password })
        : await arWorkbenchService.updateUser(labId, user.labUserId, { ...body, isActive: form.isActive, password: form.password || null });
      onSaved(result?.message || 'Saved.');
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  }

  return (
    <Modal title={isNew ? 'Add User' : `Edit ${user.userName}`} wide busy={busy} onClose={onClose} onSubmit={save}
      submitLabel={isNew ? 'Create User' : 'Save Changes'}
      subtitle={isNew ? 'The user signs in to LRN Metrics and the AR Workbench with this username and password.' : null}>
      <ErrorBox message={error} />
      <div className="arwb-form-grid">
        <div className="arwb-field">
          <label htmlFor="u-name">Username</label>
          <input id="u-name" className="arwb-input" maxLength={100} autoComplete="off" value={form.userName} readOnly={!isNew}
            onChange={(e) => set('userName', e.target.value)} />
        </div>
        <div className="arwb-field">
          <label htmlFor="u-email">Email</label>
          <input id="u-email" type="email" className="arwb-input" maxLength={256} autoComplete="off" value={form.email}
            onChange={(e) => set('email', e.target.value)} />
        </div>
        <div className="arwb-field">
          <label htmlFor="u-password">{isNew ? 'Password' : 'New password (leave blank to keep)'}</label>
          <div className="arwb-input-row">
            <input id="u-password" type={showPassword ? 'text' : 'password'} className="arwb-input" maxLength={128} autoComplete="new-password"
              value={form.password} onChange={(e) => set('password', e.target.value)} />
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => setShowPassword((v) => !v)}>{showPassword ? 'Hide' : 'Show'}</button>
          </div>
          <small className="arwb-hint">At least 8 characters, with a letter and a number.</small>
        </div>
        <div className="arwb-field">
          <label htmlFor="u-role">Role</label>
          <select id="u-role" className="arwb-select" value={form.roleId} onChange={(e) => set('roleId', e.target.value)}>
            <option value="">Choose a role…</option>
            {data.roles.map((r) => <option key={r.roleId} value={r.roleId}>{r.label}</option>)}
          </select>
        </div>
        {!isNew && (
          <div className="arwb-checkbox-row">
            <input id="u-active" type="checkbox" checked={form.isActive} onChange={(e) => set('isActive', e.target.checked)} />
            <label htmlFor="u-active">Active (can sign in)</label>
          </div>
        )}
      </div>
      <div className="arwb-field" style={{ marginTop: 12 }}>
        <span className="arwb-field-label">Labs</span>
        <LabPicker labs={data.labs} selected={form.labIds} onChange={(v) => set('labIds', v)} />
        {!isNew && user.otherLabCount > 0 && (
          <small className="arwb-hint">Also has {user.otherLabCount} lab{user.otherLabCount === 1 ? '' : 's'} outside yours; those stay as they are.</small>
        )}
      </div>
    </Modal>
  );
}

export default function UsersPage() {
  const { labId } = useWorkbench();
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState(null);
  const [editing, setEditing] = useState(null);   // null | 'new' | user
  const [term, setTerm] = useState('');
  const [showInactive, setShowInactive] = useState(false);

  const load = useCallback(() => {
    setError('');
    return arWorkbenchService.users(labId).then(setData).catch((e) => setError(e.message));
  }, [labId]);

  useEffect(() => { load(); }, [load]);

  const rows = useMemo(() => {
    const q = term.trim().toLowerCase();
    return (data?.users || []).filter((u) => (showInactive || u.isActive)
      && (!q || u.userName.toLowerCase().includes(q) || (u.email || '').toLowerCase().includes(q)
        || u.roles.some((r) => r.label.toLowerCase().includes(q)) || u.labs.some((l) => l.labName.toLowerCase().includes(q))));
  }, [data, term, showInactive]);

  if (!data && !error) return <Loading text="Loading users…" />;

  return (
    <>
      <Notice notice={notice} onClose={() => setNotice(null)} />
      <ErrorBox message={error} onRetry={load} />

      {data && (
        <div className="arwb-card arwb-card-flush">
          <div className="arwb-card-head">
            <h3>Users</h3>
            <span className="arwb-card-sub">{rows.length} of {data.users.length}</span>
            <div className="arwb-card-head-actions">
              <input type="search" className="arwb-input" style={{ width: 220 }} placeholder="Find user, email, role, lab…" value={term}
                onChange={(e) => setTerm(e.target.value)} aria-label="Find a user" />
              <label className="arwb-checkbox-row" style={{ margin: 0 }}>
                <input type="checkbox" checked={showInactive} onChange={(e) => setShowInactive(e.target.checked)} /> Show inactive
              </label>
              <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!data.labs.length || !data.roles.length}
                onClick={() => setEditing('new')}>
                <Icon name="plus" size={15} /> Add User
              </button>
            </div>
          </div>
          <div className="arwb-table-wrap">
            <table className="arwb-data-table">
              <thead><tr><th>Username</th><th>Email</th><th>Role</th><th>Labs</th><th>Status</th><th>Created By</th><th /></tr></thead>
              <tbody>
                {rows.map((u) => (
                  <tr key={u.labUserId}>
                    <td className="mono">{u.userName}</td>
                    <td>{u.email || '—'}</td>
                    <td>{u.roles.map((r) => r.label).join(', ') || '—'}{u.isSiteAdmin && <> <Badge className="arwb-badge-purple">Site admin</Badge></>}</td>
                    <td>
                      <div className="arwb-chip-row">
                        {u.labs.map((l) => <span key={l.labId} className="arwb-chip">{l.labName}</span>)}
                        {u.otherLabCount > 0 && <span className="arwb-chip arwb-chip-muted" title="Labs outside the ones you manage">+{u.otherLabCount} other</span>}
                      </div>
                    </td>
                    <td>{u.isActive ? <Badge className="arwb-badge-good">Active</Badge> : <Badge className="arwb-badge-neutral">Inactive</Badge>}</td>
                    <td className="arwb-hint">{u.createdBy || '—'}</td>
                    <td className="num">
                      {u.canEdit
                        ? <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => setEditing(u)}><Icon name="edit" size={14} /> Edit</button>
                        : <span className="arwb-hint" title={u.readOnlyReason || ''}>Read-only</span>}
                    </td>
                  </tr>
                ))}
                {rows.length === 0 && <tr><td colSpan={7} className="arwb-hint" style={{ textAlign: 'center', padding: 24 }}>No users match.</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {data && (
        <div className="arwb-section-note" style={{ marginTop: 12 }}>
          {data.allLabs
            ? <>As a <b>Super Admin</b> you can create AR Workbench users for <b>every lab</b>.</>
            : <>You can create AR Workbench users for <b>your assigned labs</b> ({data.labs.map((l) => l.labName).join(', ') || 'none'}). Users who also have other labs or LRN Metrics roles are changed by a Super Admin.</>}
          {' '}Clinic and Provider Viewer access, which also needs the clinic or provider, is set up by a Super Admin.
        </div>
      )}

      {editing && (
        <UserModal data={data} user={editing === 'new' ? null : editing} onClose={() => setEditing(null)}
          onSaved={(message) => { setEditing(null); setNotice({ kind: 'good', text: message }); load(); }} />
      )}
    </>
  );
}
