import { useCallback, useEffect, useMemo, useState } from 'react';
import { useLocation, useNavigate } from 'react-router';
import Icon from '../components/Icon';
import Modal from '../components/Modal';
import { Badge, ErrorBox, Loading, Notice } from '../components/Status';
import UserEmailsPanel from '../components/UserEmailsPanel';
import { LabPicker, ScopePicker, scopesBody } from '../components/UserFormParts';
import useTableSort from '../components/useTableSort';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

// The mockup's User Management (App.views.users), on the real LRNMaster user tables. A Super Admin
// manages every lab; an AR Workbench System Administrator (or Lab Admin) manages the labs assigned
// to them. Add User is its own page (UserCreatePage): no password is set by the admin - the user is
// emailed a one-time password and a link to create their own. On Edit, a Super Admin or System
// Administrator may also set a password directly (a user who cannot change their own). The API enforces every rule; rows
// the caller may not change come back read-only with the reason.

function EditUserModal({ data, user, onClose, onSaved }) {
  const { labId } = useWorkbench();
  const currentRole = user.roles?.find((r) => data.roles.some((x) => x.roleId === r.roleId))?.roleId;
  const [form, setForm] = useState(() => ({
    email: user.email || '',
    roleId: currentRole || '',
    labIds: user.labs.map((l) => l.labId),
    isActive: user.isActive,
    managerUserId: user.managerUserId || '',
    teamName: user.teamName || '',
    // { [labId]: clinic or provider } for a Clinic / Provider Viewer
    scopes: Object.fromEntries((user.scopes || []).map((s) => [s.labId, s.clinicName || s.providerName || ''])),
    // Set Password (Super Admin / System Administrator only): blank keeps the current password
    password: '',
    confirmPassword: ''
  }));
  const [showPassword, setShowPassword] = useState(false);
  // A Microsoft (Azure AD) user's password lives in their Microsoft account: nothing to set here.
  const microsoft = isAzureAd(user);
  const canSetPassword = Boolean(data.canSetPasswords) && !microsoft;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const set = (k, v) => setForm((f) => ({ ...f, [k]: v }));

  const roleScope = data.roles.find((r) => String(r.roleId) === String(form.roleId))?.scope || null;
  const managers = data.managers.filter((m) => m.labUserId !== user.labUserId);

  async function save() {
    if (!form.email.trim()) { setError('Enter an email address.'); return; }
    if (!form.roleId) { setError('Choose a role.'); return; }
    if (form.labIds.length === 0) { setError('Choose at least one lab.'); return; }
    if (roleScope && form.labIds.some((id) => !form.scopes[id])) { setError(`Choose the ${roleScope === 'clinic' ? 'clinic' : 'referring provider'} for every selected lab.`); return; }
    const settingPassword = canSetPassword && (form.password || form.confirmPassword);
    if (settingPassword) {
      if (form.password.length < 8 || form.password.length > 128) { setError('The new password must be 8 to 128 characters.'); return; }
      if (form.password !== form.confirmPassword) { setError('The new password and its confirmation do not match.'); return; }
    }
    setBusy(true);
    setError('');
    try {
      const result = await arWorkbenchService.updateUser(labId, user.labUserId, {
        email: form.email.trim(), roleId: Number(form.roleId), labIds: form.labIds, isActive: form.isActive,
        managerUserId: form.managerUserId ? Number(form.managerUserId) : null, teamName: form.teamName.trim() || null,
        scopes: scopesBody(roleScope, form.labIds, form.scopes),
        password: settingPassword ? form.password : null
      });
      onSaved({ kind: 'good', text: (result?.message || 'Saved.') + (settingPassword ? ` New password set for ${user.userName} - share it with them securely.` : '') });
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  }

  return (
    <Modal title={`Edit ${user.userName}`} wide busy={busy} onClose={onClose} onSubmit={save} submitLabel="Save Changes"
      subtitle={microsoft
        ? 'Signs in with Microsoft — their password is managed in their Microsoft account.'
        : canSetPassword
          ? 'Leave Set Password blank to keep the current password. Send password link on the user list lets the user choose their own.'
          : 'Passwords are not set here. Use Send password link on the user list to let the user choose a new one.'}>
      <ErrorBox message={error} />
      <div className="arwb-form-grid">
        <div className="arwb-field">
          <label htmlFor="u-name">Username</label>
          <input id="u-name" className="arwb-input" value={user.userName} readOnly />
        </div>
        <div className="arwb-field">
          <label htmlFor="u-email">Email</label>
          <input id="u-email" type="email" className="arwb-input" maxLength={256} autoComplete="off" value={form.email}
            onChange={(e) => set('email', e.target.value)} />
        </div>
        <div className="arwb-field">
          <label htmlFor="u-role">Role</label>
          <select id="u-role" className="arwb-select" value={form.roleId} onChange={(e) => set('roleId', e.target.value)}>
            <option value="">Choose a role…</option>
            {data.roles.map((r) => <option key={r.roleId} value={r.roleId}>{r.label}</option>)}
          </select>
        </div>
        <div className="arwb-field">
          <label htmlFor="u-manager">Manager</label>
          <select id="u-manager" className="arwb-select" value={form.managerUserId} onChange={(e) => set('managerUserId', e.target.value)}>
            <option value="">No manager</option>
            {managers.map((m) => <option key={m.labUserId} value={m.labUserId}>{m.label}</option>)}
          </select>
        </div>
        <div className="arwb-field">
          <label htmlFor="u-team">Team</label>
          <input id="u-team" className="arwb-input" list="u-team-list" maxLength={100} value={form.teamName} onChange={(e) => set('teamName', e.target.value)} />
          <datalist id="u-team-list">{data.teams.map((t) => <option key={t} value={t} />)}</datalist>
        </div>
        <div className="arwb-checkbox-row">
          <input id="u-active" type="checkbox" checked={form.isActive} onChange={(e) => set('isActive', e.target.checked)} />
          <label htmlFor="u-active">Active (can sign in)</label>
        </div>
      </div>
      <div className="arwb-field" style={{ marginTop: 12 }}>
        <span className="arwb-field-label">Labs</span>
        <LabPicker labs={data.labs} selected={form.labIds} onChange={(v) => set('labIds', v)} />
        {user.otherLabCount > 0 && (
          <small className="arwb-hint">Also has {user.otherLabCount} lab{user.otherLabCount === 1 ? '' : 's'} outside yours; those stay as they are.</small>
        )}
      </div>
      {roleScope && form.labIds.length > 0 && (
        <div style={{ marginTop: 12 }}>
          <ScopePicker labId={labId} roleScope={roleScope} labs={data.labs} labIds={form.labIds} scopes={form.scopes} onChange={(v) => set('scopes', v)} />
        </div>
      )}
      {canSetPassword && (
        <fieldset className="arwb-field" style={{ marginTop: 16, border: 0, padding: 0 }}>
          <legend className="arwb-field-label" style={{ fontSize: 'inherit' }}>Set Password <span className="arwb-hint">(optional — Super Admin / System Administrator)</span></legend>
          <div className="arwb-form-grid">
            <div className="arwb-field">
              <label htmlFor="u-pass">New password</label>
              <input id="u-pass" type={showPassword ? 'text' : 'password'} className="arwb-input" maxLength={128} autoComplete="new-password"
                value={form.password} onChange={(e) => set('password', e.target.value)} />
            </div>
            <div className="arwb-field">
              <label htmlFor="u-pass2">Confirm new password</label>
              <input id="u-pass2" type={showPassword ? 'text' : 'password'} className="arwb-input" maxLength={128} autoComplete="new-password"
                value={form.confirmPassword} onChange={(e) => set('confirmPassword', e.target.value)} />
            </div>
          </div>
          <div className="arwb-checkbox-row">
            <input id="u-pass-show" type="checkbox" checked={showPassword} onChange={(e) => setShowPassword(e.target.checked)} />
            <label htmlFor="u-pass-show">Show password</label>
          </div>
          <small className="arwb-hint">8 to 128 characters. The user signs in with it straight away (LRN Metrics and the AR Workbench share the login).</small>
        </fieldset>
      )}
    </Modal>
  );
}

// Confirmation for the row actions that change access: deactivate, activate, delete, (re)send invitation.
const ACTIONS = {
  invite: { title: 'Send invitation', label: 'Send Email', cls: 'arwb-btn-primary' },
  deactivate: { title: 'Deactivate user', label: 'Deactivate', cls: 'arwb-btn-danger' },
  activate: { title: 'Activate user', label: 'Activate', cls: 'arwb-btn-primary' },
  delete: { title: 'Delete user', label: 'Delete Permanently', cls: 'arwb-btn-danger' }
};

function ConfirmActionModal({ action, user, onClose, onDone }) {
  const { labId } = useWorkbench();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const meta = ACTIONS[action];

  async function run() {
    setBusy(true);
    setError('');
    try {
      const result = action === 'invite' ? await arWorkbenchService.resendInvite(labId, user.labUserId)
        : action === 'delete' ? await arWorkbenchService.deleteUser(labId, user.labUserId)
          : await arWorkbenchService.setUserActive(labId, user.labUserId, action === 'activate');
      onDone({ kind: 'good', text: result?.message || 'Done.' });
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  }

  return (
    <Modal title={`${meta.title} — ${user.userName}`} busy={busy} busyLabel="Working…" onClose={onClose} onSubmit={run}
      submitLabel={meta.label} submitClass={meta.cls}>
      <ErrorBox message={error} />
      {action === 'invite' && (
        <p>A new email with a one-time password and a single-use link will be sent to <b>{user.email || '(no email)'}</b>.
          {' '}Any earlier invitation link stops working. {user.invite?.hasPassword && 'The current password keeps working until the user sets a new one.'}</p>
      )}
      {action === 'deactivate' && (
        <p><b>{user.userName}</b> will no longer be able to sign in to LRN Metrics or the AR Workbench, and any open invitation link is cancelled.
          {' '}Their roles, labs and history are kept, so you can activate the account again later.</p>
      )}
      {action === 'activate' && <p><b>{user.userName}</b> will be able to sign in again with their existing password.</p>}
      {action === 'delete' && (
        <>
          <p>This permanently removes <b>{user.userName}</b>, their roles, labs, clinic / provider access and invitations. It cannot be undone.</p>
          <p className="arwb-hint">Claims still assigned to this username keep the name. Users who report to them lose their manager.
            {' '}If the account has history elsewhere, the delete is refused — deactivate it instead.</p>
        </>
      )}
    </Modal>
  );
}

function InviteBadge({ invite }) {
  if (!invite || invite.hasPassword) return null;
  if (invite.lastEmailStatus === 'Failed') return <Badge className="arwb-badge-critical" title="The last invitation email could not be sent">Invite failed</Badge>;
  if (invite.lastEmailStatus === 'Sent') return <Badge className="arwb-badge-info" title={invite.lastEmailUtc ? `Sent ${fmt.date(invite.lastEmailUtc)}` : ''}>Invite sent</Badge>;
  return null;
}

const isAzureAd = (u) => String(u.authProvider || '').toLowerCase() === 'entra';

// Azure AD users: inactive (waiting for access) first, then the most recent sign-in; never signed in last.
function azureOrder(a, b) {
  if (a.isActive !== b.isActive) return a.isActive ? 1 : -1;
  const ta = a.lastLoginUtc ? Date.parse(a.lastLoginUtc) : -Infinity;
  const tb = b.lastLoginUtc ? Date.parse(b.lastLoginUtc) : -Infinity;
  return tb - ta;
}

// Icon-only row action; the label is the tooltip and the accessible name.
function IconAction({ icon, label, onClick, danger, disabled }) {
  return (
    <button type="button" className={`arwb-btn arwb-btn-sm${danger ? ' arwb-btn-danger' : ''}`} title={label} aria-label={label}
      disabled={disabled} onClick={onClick}>
      <Icon name={icon} size={15} />
    </button>
  );
}

export default function UsersPage() {
  const { labId } = useWorkbench();
  const navigate = useNavigate();
  const location = useLocation();
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState(location.state?.notice || null);
  const [editing, setEditing] = useState(null);   // user
  const [confirm, setConfirm] = useState(null);   // { action, user }
  const [term, setTerm] = useState('');
  const [showInactive, setShowInactive] = useState(false);
  const [tab, setTab] = useState('users');   // users | emails
  const [kind, setKind] = useState('system');   // system | azure

  // The Add User page hands its result back in history state; drop it so a refresh does not repeat it.
  useEffect(() => {
    if (location.state?.notice) navigate(location.pathname, { replace: true, state: null });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const load = useCallback(() => {
    setError('');
    return arWorkbenchService.users(labId).then(setData).catch((e) => setError(e.message));
  }, [labId]);

  useEffect(() => { load(); }, [load]);

  const counts = useMemo(() => {
    const all = data?.users || [];
    const azure = all.filter(isAzureAd).length;
    return { system: all.length - azure, azure };
  }, [data]);

  const rows = useMemo(() => {
    const q = term.trim().toLowerCase();
    const azure = kind === 'azure';
    const list = (data?.users || []).filter((u) => isAzureAd(u) === azure
      // Azure AD users always include inactive ones - they lead the list.
      && (azure || showInactive || u.isActive)
      && (!q || u.userName.toLowerCase().includes(q) || (u.email || '').toLowerCase().includes(q)
        || u.roles.some((r) => r.label.toLowerCase().includes(q)) || u.labs.some((l) => l.labName.toLowerCase().includes(q))
        || (u.scopes || []).some((s) => (s.clinicName || s.providerName || '').toLowerCase().includes(q))));
    return azure ? [...list].sort(azureOrder) : list;
  }, [data, term, showInactive, kind]);
  const { rows: sortedRows, th } = useTableSort(rows, {
    user: (u) => u.userName, email: (u) => u.email, role: (u) => u.roles.map((r) => r.label).join(', '), labs: (u) => u.labs.map((l) => l.labName).join(', '),
    manager: (u) => u.managerName || u.teamName, status: (u) => (u.isActive ? 0 : 1),
    lastLogin: (u) => (u.lastLoginUtc ? Date.parse(u.lastLoginUtc) : null), createdBy: (u) => u.createdBy
  });

  if (!data && !error) return <Loading text="Loading users…" />;

  const done = (n) => { setEditing(null); setConfirm(null); setNotice(n); load(); };

  return (
    <>
      <Notice notice={notice} onClose={() => setNotice(null)} />
      <ErrorBox message={error} onRetry={load} />

      {data && (
        <div className="arwb-tabs" role="tablist" style={{ padding: 0 }}>
          <button type="button" role="tab" aria-selected={tab === 'users'} className={`arwb-tab-btn${tab === 'users' ? ' active' : ''}`} onClick={() => setTab('users')}>
            Users
          </button>
          <button type="button" role="tab" aria-selected={tab === 'emails'} className={`arwb-tab-btn${tab === 'emails' ? ' active' : ''}`} onClick={() => setTab('emails')}>
            Sent Emails
          </button>
        </div>
      )}

      {data && tab === 'emails' && <UserEmailsPanel roles={data.roles} />}

      {data && tab === 'users' && (
        <div className="arwb-card arwb-card-flush">
          <div className="arwb-card-head">
            <h3>Users</h3>
            <span className="arwb-card-sub">{rows.length} of {kind === 'azure' ? counts.azure : counts.system}</span>
            <div className="arwb-card-head-actions">
              <input type="search" className="arwb-input" style={{ width: 240 }} placeholder="Find user, email, role, lab, clinic…" value={term}
                onChange={(e) => setTerm(e.target.value)} aria-label="Find a user" />
              {kind === 'system' && (
                <label className="arwb-checkbox-row" style={{ margin: 0 }}>
                  <input type="checkbox" checked={showInactive} onChange={(e) => setShowInactive(e.target.checked)} /> Show inactive
                </label>
              )}
              <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!data.labs.length || !data.roles.length}
                onClick={() => navigate('/users/new')}>
                <Icon name="plus" size={15} /> Add User
              </button>
            </div>
          </div>
          <div className="arwb-tabs" role="tablist" aria-label="User type" style={{ padding: '0 16px' }}>
            <button type="button" role="tab" aria-selected={kind === 'system'} className={`arwb-tab-btn${kind === 'system' ? ' active' : ''}`} onClick={() => setKind('system')}>
              System Users <span className="arwb-hint">({counts.system})</span>
            </button>
            <button type="button" role="tab" aria-selected={kind === 'azure'} className={`arwb-tab-btn${kind === 'azure' ? ' active' : ''}`} onClick={() => setKind('azure')}>
              Azure AD Users <span className="arwb-hint">({counts.azure})</span>
            </button>
          </div>
          <div className="arwb-table-wrap">
            <table className="arwb-data-table">
              <thead>
                <tr>
                  {th('user', 'Username')}{th('email', 'Email')}{th('role', 'Role / Access')}{th('labs', 'Labs')}{th('manager', 'Manager / Team')}
                  {th('status', 'Status')}{th('lastLogin', 'Last Login')}{th('createdBy', 'Created By')}<th scope="col" aria-label="Actions" />
                </tr>
              </thead>
              <tbody>
                {sortedRows.map((u) => (
                  <tr key={u.labUserId}>
                    <td className="mono">{u.userName}</td>
                    <td>{u.email || '—'}</td>
                    <td>{u.roles.map((r) => r.label).join(', ') || '—'}{u.isSiteAdmin && <> <Badge className="arwb-badge-purple">Site admin</Badge></>}
                      {u.scopes?.length > 0 && (
                        <div className="arwb-hint">
                          {u.scopes.map((s) => {
                            const lab = data.labs.find((l) => l.labId === s.labId)?.labName;
                            return `${lab ? `${lab}: ` : ''}${s.clinicName || s.providerName}`;
                          }).join(' · ')}
                        </div>
                      )}</td>
                    <td>
                      <div className="arwb-chip-row">
                        {u.labs.map((l) => <span key={l.labId} className="arwb-chip">{l.labName}</span>)}
                        {u.otherLabCount > 0 && <span className="arwb-chip arwb-chip-muted" title="Labs outside the ones you manage">+{u.otherLabCount} other</span>}
                      </div>
                    </td>
                    <td>{u.managerName || <span className="text-muted-ink">—</span>}{u.teamName && <div className="arwb-hint">{u.teamName}</div>}</td>
                    <td>
                      <div className="arwb-status-stack">
                        {u.isActive ? <Badge className="arwb-badge-good">Active</Badge> : <Badge className="arwb-badge-neutral">Inactive</Badge>}
                        {u.isActive && !isAzureAd(u) && <InviteBadge invite={u.invite} />}
                      </div>
                    </td>
                    <td className="arwb-hint">{u.lastLoginUtc ? fmt.dateTime(u.lastLoginUtc) : 'Never'}</td>
                    <td className="arwb-hint">{u.createdBy || '—'}</td>
                    <td className="num">
                      {u.canEdit
                        ? (
                          <div className="arwb-row-actions" style={{ flexWrap: 'nowrap' }}>
                            <IconAction icon="edit" label={`Edit ${u.userName}`} onClick={() => setEditing(u)} />
                            {u.isActive && !isAzureAd(u) && (
                              <IconAction icon="mail"
                                label={!u.email ? 'Add an email address first' : u.invite?.hasPassword ? 'Send password link' : 'Resend invitation'}
                                disabled={!u.email} onClick={() => setConfirm({ action: 'invite', user: u })} />
                            )}
                            <IconAction icon={u.isActive ? 'userOff' : 'userCheck'} label={u.isActive ? `Deactivate ${u.userName}` : `Activate ${u.userName}`}
                              onClick={() => setConfirm({ action: u.isActive ? 'deactivate' : 'activate', user: u })} />
                            <IconAction icon="trash" label={`Delete ${u.userName}`} danger onClick={() => setConfirm({ action: 'delete', user: u })} />
                          </div>
                        )
                        : <span className="arwb-hint" title={u.readOnlyReason || ''}>Read-only</span>}
                    </td>
                  </tr>
                ))}
                {rows.length === 0 && <tr><td colSpan={9} className="arwb-hint" style={{ textAlign: 'center', padding: 24 }}>No users match.</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {data && tab === 'users' && (
        <div className="arwb-section-note" style={{ marginTop: 12 }}>
          {data.allLabs
            ? <>As a <b>Super Admin</b> you can create AR Workbench users for <b>every lab</b>.</>
            : <>You can create AR Workbench users for <b>your assigned labs</b> ({data.labs.map((l) => l.labName).join(', ') || 'none'}). Users who also have other labs or LRN Metrics roles are changed by a Super Admin.</>}
          {' '}New users get an email with a one-time password to create their own password. Clinic and Provider Viewers see only the claims of the clinic or referring provider chosen for each lab.
        </div>
      )}

      {editing && <EditUserModal data={data} user={editing} onClose={() => setEditing(null)} onSaved={done} />}
      {confirm && <ConfirmActionModal action={confirm.action} user={confirm.user} onClose={() => setConfirm(null)} onDone={done} />}
    </>
  );
}
