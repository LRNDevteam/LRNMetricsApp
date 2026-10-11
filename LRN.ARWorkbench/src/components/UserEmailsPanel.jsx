import { useCallback, useEffect, useRef, useState } from 'react';
import Icon from './Icon';
import Modal from './Modal';
import { Badge, ErrorBox, Loading } from './Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

// User Management > Sent Emails: the invitation emails of the users this admin manages, from the
// log LRN Metrics and the AR Workbench share (dbo.UserEmailLog). A Super Admin sees every email; a
// lab-scoped admin only those of users in their labs (enforced by the API).

const PAGE_SIZE = 50;
const TYPE_LABEL = {
  UserInvitation: 'Invitation',
  UserInvitationResend: 'Invitation (resent)',
  DenialWorkflowSupport: 'Denial Workflow support',
  DenialWorkflowNotification: 'Denial Workflow notification',
  PayerMasterNotification: 'Payer Master notification'
};

function EmailViewModal({ emailLogId, onClose }) {
  const { labId } = useWorkbench();
  const [detail, setDetail] = useState(null);
  const [error, setError] = useState('');

  useEffect(() => {
    arWorkbenchService.userEmail(labId, emailLogId).then(setDetail).catch((e) => setError(e.message));
  }, [labId, emailLogId]);

  const m = detail?.email;
  return (
    <Modal title={m?.subject || 'Email'} wide submitLabel={null} onClose={onClose}
      subtitle={m ? [fmt.dateTime(m.createdUtc), `To ${m.toAddress}`, m.application, m.status].join(' · ') : null}>
      <ErrorBox message={error} />
      {!detail && !error && <Loading text="Loading email…" />}
      {detail && (
        <>
          {/* sandbox="": the stored HTML is shown with scripts, forms and navigation disabled. */}
          <iframe title="Email preview" sandbox="" referrerPolicy="no-referrer" className="arwb-email-preview"
            srcDoc={detail.bodyHtml || `<p style="font-family:Segoe UI,Arial;padding:16px;color:#64748b">No message body was stored (the email was not built).</p>`} />
          {m?.errorMessage && <p className="text-critical" style={{ marginTop: 8 }}>{m.errorMessage}</p>}
          <small className="arwb-hint">The one-time password and the first-login link are removed from stored copies.</small>
        </>
      )}
    </Modal>
  );
}

export default function UserEmailsPanel({ roles }) {
  const { labId } = useWorkbench();
  const [filters, setFilters] = useState({ search: '', roleId: '', status: '', application: '', oldestFirst: false });
  const [search, setSearch] = useState('');
  const [page, setPage] = useState(1);
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [viewing, setViewing] = useState(null);
  const abort = useRef(null);

  // Debounce the search box; every other filter applies at once.
  useEffect(() => {
    const t = setTimeout(() => {
      const s = search.trim();
      setFilters((f) => (f.search === s ? f : { ...f, search: s }));
      setPage((p) => (filters.search === s ? p : 1));
    }, 350);
    return () => clearTimeout(t);
  }, [search]);

  const load = useCallback(() => {
    abort.current?.abort();
    const controller = new AbortController();
    abort.current = controller;
    setError('');
    setData((d) => (d ? { ...d, loading: true } : d));
    arWorkbenchService.userEmails(labId, {
      // User invitation emails only on this screen.
      emailType: ['UserInvitation', 'UserInvitationResend'],
      search: filters.search, roleId: filters.roleId, status: filters.status, application: filters.application,
      oldestFirst: filters.oldestFirst || undefined, page, pageSize: PAGE_SIZE
    }, controller.signal)
      .then(setData)
      .catch((e) => { if (e.name !== 'AbortError') setError(e.message); });
  }, [labId, filters, page]);

  useEffect(() => { load(); return () => abort.current?.abort(); }, [load]);

  const set = (k, v) => { setFilters((f) => ({ ...f, [k]: v })); setPage(1); };
  const total = data?.total || 0;
  const from = total === 0 ? 0 : (page - 1) * PAGE_SIZE + 1;
  const to = Math.min(page * PAGE_SIZE, total);
  const newer = filters.oldestFirst ? 'Older' : 'Newer';
  const older = filters.oldestFirst ? 'Newer' : 'Older';

  return (
    <div className="arwb-card arwb-card-flush">
      <div className="arwb-filter-bar">
        <div className="arwb-field grow">
          <label htmlFor="em-search">Search</label>
          <input id="em-search" type="search" className="arwb-input" placeholder="Username, email, subject, sent by…" value={search} onChange={(e) => setSearch(e.target.value)} />
        </div>
        <div className="arwb-field">
          <label htmlFor="em-role">Role</label>
          <select id="em-role" className="arwb-select" value={filters.roleId} onChange={(e) => set('roleId', e.target.value)}>
            <option value="">All roles</option>
            {roles.map((r) => <option key={r.roleId} value={r.roleId}>{r.label}</option>)}
          </select>
        </div>
        <div className="arwb-field">
          <label htmlFor="em-status">Status</label>
          <select id="em-status" className="arwb-select" value={filters.status} onChange={(e) => set('status', e.target.value)}>
            <option value="">All</option>
            <option value="Sent">Sent</option>
            <option value="Failed">Failed</option>
          </select>
        </div>
        <div className="arwb-field">
          <label htmlFor="em-app">Application</label>
          <select id="em-app" className="arwb-select" value={filters.application} onChange={(e) => set('application', e.target.value)}>
            <option value="">Both</option>
            <option value="AR Workbench">AR Workbench</option>
            <option value="LRN Metrics">LRN Metrics</option>
          </select>
        </div>
        <div className="arwb-field">
          <label htmlFor="em-order">Order</label>
          <select id="em-order" className="arwb-select" value={filters.oldestFirst ? 'oldest' : 'recent'} onChange={(e) => set('oldestFirst', e.target.value === 'oldest')}>
            <option value="recent">Most recent first</option>
            <option value="oldest">Oldest first</option>
          </select>
        </div>
        <button type="button" className="arwb-btn arwb-btn-sm" onClick={load} title="Refresh"><Icon name="refresh" size={14} /></button>
      </div>

      {error && <div style={{ padding: '0 16px 12px' }}><ErrorBox message={error} onRetry={load} /></div>}
      {!data && !error && <Loading text="Loading sent emails…" />}
      {data && data.installed === false && (
        <div className="arwb-hint" style={{ padding: 24, textAlign: 'center' }}>The email log is not set up yet. Run LRN.ReportsApi/Sql/UserMail_Setup.sql on LRNMaster.</div>
      )}
      {data && data.installed !== false && (
        <>
          <div className="arwb-table-wrap" style={{ opacity: data.loading ? 0.6 : 1 }}>
            <table className="arwb-data-table">
              <thead>
                <tr><th>Sent</th><th>User</th><th>Roles</th><th>To</th><th>Application</th><th>Type</th><th>Status</th><th>Sent By</th><th /></tr>
              </thead>
              <tbody>
                {data.rows.map((m) => (
                  <tr key={m.emailLogId}>
                    <td style={{ whiteSpace: 'nowrap' }}>{fmt.dateTime(m.createdUtc)}</td>
                    <td className="mono">{m.userName || '—'}
                      {m.fullName && <div className="arwb-hint">{m.fullName}</div>}
                      {m.userExists === false && <div className="arwb-hint"><i>user deleted</i></div>}
                    </td>
                    <td>{m.roles ? <div className="arwb-chip-row">{m.roles.split(', ').map((r) => <span key={r} className="arwb-chip">{r.replace(/^AR Workbench - /, '')}</span>)}</div> : '—'}</td>
                    <td>{m.toAddress}</td>
                    <td style={{ whiteSpace: 'nowrap' }}>{m.application}</td>
                    <td style={{ whiteSpace: 'nowrap' }}>{TYPE_LABEL[m.emailType] || m.emailType}</td>
                    <td>
                      {m.status === 'Sent' ? <Badge className="arwb-badge-good">Sent</Badge> : <Badge className="arwb-badge-critical" title={m.errorMessage || ''}>Failed</Badge>}
                      {m.status !== 'Sent' && m.errorMessage && <div className="arwb-hint arwb-clamp-2" title={m.errorMessage}>{m.errorMessage}</div>}
                    </td>
                    <td className="arwb-hint">{m.sentBy || '—'}</td>
                    <td className="num">
                      <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => setViewing(m.emailLogId)}><Icon name="mail" size={14} /> View</button>
                    </td>
                  </tr>
                ))}
                {data.rows.length === 0 && <tr><td colSpan={9} className="arwb-hint" style={{ textAlign: 'center', padding: 24 }}>No emails match.</td></tr>}
              </tbody>
            </table>
          </div>
          <div className="arwb-table-footer">
            <span className="grow">{total === 0 ? '' : `${from}–${to} of ${fmt.count(total)} emails`}</span>
            <button type="button" className="arwb-btn arwb-btn-sm" disabled={page <= 1} onClick={() => setPage((p) => p - 1)}>{newer}</button>
            <button type="button" className="arwb-btn arwb-btn-sm" disabled={to >= total} onClick={() => setPage((p) => p + 1)}>{older}</button>
          </div>
        </>
      )}

      {viewing && <EmailViewModal emailLogId={viewing} onClose={() => setViewing(null)} />}
    </div>
  );
}
