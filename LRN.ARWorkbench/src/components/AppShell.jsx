import { useEffect, useState } from 'react';
import { NavLink, Outlet, useLocation } from 'react-router';
import { LOGOUT_URL } from '../config/apiConfig';
import { NAV, navForUser } from '../config/navigation';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { clearJwt } from '../services/auth';
import { fmt } from '../utils/format';
import Icon from './Icon';

function ScopeBadge({ access, roleCode, labName }) {
  if (!access) return null;
  // Client level is the whole lab; only a viewer is shown that boundary (as in the mockup).
  if (access.level === 'client' && (roleCode !== 'viewer' || !labName)) return null;
  const label = access.level === 'clinic' ? `Clinic: ${access.clinic}`
    : access.level === 'provider' ? `Provider: ${access.provider}`
    : `Client: ${labName}`;
  // A scoped user always sees the boundary they are held to, not just an enforced filter.
  return <span className="arwb-badge arwb-badge-accent" title="Your access is limited to this scope">{label}</span>;
}

function initials(name) {
  return String(name || '?').split(/\s+/).filter(Boolean).slice(0, 2).map((p) => p[0].toUpperCase()).join('');
}

// Topbar title / subtitle for the current route (the mockup's VIEW_META).
function viewMeta(pathname) {
  if (pathname.startsWith('/claims/')) return { title: 'Claim Workspace', subtitle: 'Recovery, CPT lines, denial detail, follow-ups and activity' };
  const item = NAV.find((n) => n.path === pathname);
  return item ? { title: item.label, subtitle: item.subtitle } : { title: '', subtitle: '' };
}

/** The mockup's app shell: white sidebar (brand mark, icon nav, count pills) and a sticky topbar. */
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
  const meta = viewMeta(location.pathname);
  const labName = labs.find((l) => l.labId === labId)?.labName;

  function logout() {
    clearJwt();
    window.location.href = LOGOUT_URL;
  }

  return (
    <div className="arwb-shell">
      <aside className={`arwb-sidebar ${navOpen ? 'open' : ''}`} aria-label="Main menu">
        <div className="arwb-sidebar-top">
          <div className="arwb-brand-mark">LRN</div>
          <div>
            <div className="arwb-brand-title-main">AR Workbench</div>
            <div className="arwb-brand-title-sub">Denial &amp; Insurance AR</div>
          </div>
          <button type="button" className="arwb-icon-btn arwb-only-mobile ms-auto" onClick={() => setNavOpen(false)} aria-label="Close menu">
            <Icon name="close" />
          </button>
        </div>
        <nav className="arwb-nav-list">
          {items.map((item) => {
            const count = item.countKey ? counts[item.countKey] : 0;
            return (
              <NavLink key={item.id} to={item.path} end={item.path === '/'} className={({ isActive }) => `arwb-nav-item ${isActive ? 'active' : ''}`}
                title={item.built ? item.label : `${item.label} (planned - phase ${item.phase})`}>
                <span className="arwb-nav-ic"><Icon name={item.icon} /></span>
                <span className="arwb-nav-label">{item.label}</span>
                {count > 0 && <span className="arwb-nav-count">{fmt.count(count)}</span>}
                {!item.built && !(count > 0) && <span className="arwb-planned-dot" />}
              </NavLink>
            );
          })}
        </nav>
        <div className="arwb-sidebar-foot">
          <div className="arwb-data-refresh-note">
            {labName ? `Lab: ${labName}` : 'No lab selected'}<br />Signed in as {user?.userName}
          </div>
        </div>
      </aside>
      {navOpen && <div className="arwb-sidebar-scrim" onClick={() => setNavOpen(false)} />}

      <div className="arwb-main">
        <header className="arwb-topbar">
          <button type="button" className="arwb-icon-btn arwb-only-mobile" onClick={() => setNavOpen(true)} aria-label="Open menu">
            <Icon name="menu" />
          </button>
          <div className="arwb-topbar-title">
            <h1>{meta.title}</h1>
            {meta.subtitle && <div className="arwb-view-subtitle">{meta.subtitle}</div>}
          </div>
          <div className="arwb-topbar-actions">
            <div className="arwb-client-scope">
              {labs.length > 1 ? (
                <select aria-label="Lab" value={labId || ''} onChange={(e) => setLabId(Number(e.target.value))}>
                  {labs.map((l) => <option key={l.labId} value={l.labId}>{l.labName}</option>)}
                </select>
              ) : labName && <span className="arwb-badge arwb-badge-accent">{labName}</span>}
            </div>
            <ScopeBadge access={user?.access} roleCode={user?.roleCode} labName={labName} />
            <div className="arwb-user-chip">
              <span className="arwb-user-avatar">{initials(user?.displayName)}</span>
              <span className="lh-sm">
                <span className="arwb-u-name">{user?.displayName}</span><br />
                <span className="arwb-u-role">{user?.roleLabel}</span>
              </span>
            </div>
            <button type="button" className="arwb-btn arwb-btn-ghost arwb-btn-sm" onClick={logout} title="Sign out">
              <Icon name="logout" size={15} /><span className="d-none d-md-inline">Sign out</span>
            </button>
          </div>
        </header>
        <main className="arwb-view-container">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
