import { useEffect, useState } from 'react';
import { NavLink, Outlet, useLocation } from 'react-router';
import { LOGOUT_URL } from '../config/apiConfig';
import { navForUser } from '../config/navigation';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { clearJwt } from '../services/auth';
import { fmt } from '../utils/format';

function ScopeBadge({ access, roleCode, labName }) {
  if (!access) return null;
  // Client level is the whole lab; only a viewer is shown that boundary (as in the mockup).
  if (access.level === 'client' && (roleCode !== 'viewer' || !labName)) return null;
  const label = access.level === 'clinic' ? `Clinic: ${access.clinic}`
    : access.level === 'provider' ? `Provider: ${access.provider}`
    : `Client: ${labName}`;
  // A scoped user always sees the boundary they are held to, not just an enforced filter.
  return <span className="badge text-bg-warning ms-2" title="Your access is limited to this scope"><i className="bi bi-funnel me-1" />{label}</span>;
}

export default function AppShell() {
  const { labs, labId, setLabId, user } = useWorkbench();
  const location = useLocation();
  const [counts, setCounts] = useState({});
  const [navOpen, setNavOpen] = useState(false);

  // Nav badges come from the same queue summary the dashboard reads, so a badge and the screen
  // behind it always agree.
  useEffect(() => {
    if (!labId || !user) return undefined;
    const controller = new AbortController();
    arWorkbenchService.queues(labId, controller.signal)
      .then((s) => setCounts({ unassignedOpen: s.unassignedOpen, awaitingQa: s.awaitingQa, refollowupDue: s.refollowupDue }))
      .catch(() => { /* badges are optional; the page itself reports errors */ });
    return () => controller.abort();
  }, [labId, user, location.pathname]);

  useEffect(() => { setNavOpen(false); }, [location.pathname]);

  const items = navForUser(user);

  function logout() {
    clearJwt();
    window.location.href = LOGOUT_URL;
  }

  return (
    <div className="arwb-shell">
      <aside className={`arwb-sidebar ${navOpen ? 'open' : ''}`}>
        <div className="arwb-brand">
          <i className="bi bi-clipboard2-pulse" />
          <div>
            <div className="arwb-brand-title">AR Workbench</div>
            <div className="arwb-brand-sub">Denial &amp; AR Management</div>
          </div>
        </div>
        <nav className="arwb-nav">
          {items.map((item) => (
            <NavLink key={item.id} to={item.path} end={item.path === '/'} className={({ isActive }) => `arwb-nav-link ${isActive ? 'active' : ''}`}>
              <i className={`bi bi-${item.icon}`} />
              <span className="flex-grow-1">{item.label}</span>
              {item.countKey && counts[item.countKey] > 0 && <span className="badge rounded-pill text-bg-light">{fmt.count(counts[item.countKey])}</span>}
              {!item.built && <span className="arwb-planned-dot" title={`Planned - phase ${item.phase}`} />}
            </NavLink>
          ))}
        </nav>
      </aside>

      <div className="arwb-main">
        <header className="arwb-topbar">
          <button type="button" className="btn btn-sm btn-outline-secondary d-lg-none" onClick={() => setNavOpen((v) => !v)} aria-label="Menu">
            <i className="bi bi-list" />
          </button>
          <div className="d-flex align-items-center gap-2 flex-wrap">
            <label htmlFor="arwb-lab" className="text-secondary small mb-0">Lab</label>
            <select id="arwb-lab" className="form-select form-select-sm arwb-lab-select" value={labId || ''} onChange={(e) => setLabId(Number(e.target.value))}>
              {labs.map((l) => <option key={l.labId} value={l.labId}>{l.labName}</option>)}
            </select>
            <ScopeBadge access={user?.access} roleCode={user?.roleCode} labName={labs.find((l) => l.labId === labId)?.labName} />
          </div>
          <div className="ms-auto d-flex align-items-center gap-3">
            <div className="text-end lh-sm d-none d-sm-block">
              <div className="fw-semibold small">{user?.displayName}</div>
              <div className="text-secondary small">{user?.roleLabel}</div>
            </div>
            <button type="button" className="btn btn-sm btn-outline-secondary" onClick={logout} title="Sign out"><i className="bi bi-box-arrow-right" /></button>
          </div>
        </header>
        <main className="arwb-content">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
