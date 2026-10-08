import { useEffect, useRef, useState } from 'react';
import { NavLink, Outlet, useLocation } from 'react-router';
import ChangePasswordModal from './ChangePasswordModal';
import { Notice } from './Status';
import { LOGOUT_URL } from '../config/apiConfig';
import { navForUser, ROUTES } from '../config/navigation';
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
  const item = ROUTES.find((n) => n.path === pathname);
  if (!item) return { title: '', subtitle: '' };
  return { title: item.groupLabel ? `${item.groupLabel} · ${item.label}` : item.label, subtitle: item.subtitle };
}

const HIDDEN_KEY = 'lrn.arwb.nav.hidden';
const COLLAPSED_GROUPS_KEY = 'lrn.arwb.nav.collapsedGroups';
const readStored = (key, fallback) => { try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; } };
const writeStored = (key, value) => { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* per-session only */ } };
// Same breakpoint as the CSS that turns the sidebar into a slide-in drawer.
const isDrawer = () => window.matchMedia('(max-width: 980px)').matches;

function NavItem({ item, count }) {
  return (
    <NavLink to={item.path} end={item.path === '/'} className={({ isActive }) => `arwb-nav-item ${isActive ? 'active' : ''}`}
      title={item.built ? item.label : `${item.label} (planned - phase ${item.phase})`}>
      {item.icon && <span className="arwb-nav-ic"><Icon name={item.icon} /></span>}
      <span className="arwb-nav-label">{item.label}</span>
      {count > 0 && <span className="arwb-nav-count">{fmt.count(count)}</span>}
      {!item.built && !(count > 0) && <span className="arwb-planned-dot" />}
    </NavLink>
  );
}

/** The mockup's app shell: white sidebar (brand mark, icon nav, count pills) and a sticky topbar. */
export default function AppShell() {
  const { labs, labId, setLabId, user } = useWorkbench();
  const location = useLocation();
  const [counts, setCounts] = useState({});
  const [navOpen, setNavOpen] = useState(false);              // phone / tablet drawer
  const [navHidden, setNavHidden] = useState(() => readStored(HIDDEN_KEY, false)); // desktop: sidebar hidden
  const [collapsed, setCollapsed] = useState(() => readStored(COLLAPSED_GROUPS_KEY, []));
  const [userMenuOpen, setUserMenuOpen] = useState(false);
  const [changingPassword, setChangingPassword] = useState(false);
  const [accountNotice, setAccountNotice] = useState(null);
  const userMenuRef = useRef(null);

  // The account menu closes on an outside click or Escape.
  useEffect(() => {
    if (!userMenuOpen) return undefined;
    const onDown = (e) => { if (userMenuRef.current && !userMenuRef.current.contains(e.target)) setUserMenuOpen(false); };
    const onKey = (e) => { if (e.key === 'Escape') setUserMenuOpen(false); };
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => { document.removeEventListener('mousedown', onDown); document.removeEventListener('keydown', onKey); };
  }, [userMenuOpen]);

  function toggleNav() {
    if (isDrawer()) { setNavOpen((v) => !v); return; }
    setNavHidden((v) => { writeStored(HIDDEN_KEY, !v); return !v; });
  }

  function toggleGroup(id) {
    setCollapsed((prev) => {
      const next = prev.includes(id) ? prev.filter((g) => g !== id) : [...prev, id];
      writeStored(COLLAPSED_GROUPS_KEY, next);
      return next;
    });
  }

  // Nav badges come from the same queue summary the dashboard reads, so a badge and the screen
  // behind it always agree.
  useEffect(() => {
    if (!labId || !user) return undefined;
    const controller = new AbortController();
    arWorkbenchService.queues(labId, controller.signal)
      .then((s) => setCounts({ unassignedOpen: s.unassignedOpen, awaitingQa: s.awaitingQa, refollowupDue: s.refollowupDue, agentRequestsPending: s.agentRequestsPending }))
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
    <div className={`arwb-shell${navHidden ? ' nav-hidden' : ''}`}>
      <aside className={`arwb-sidebar ${navOpen ? 'open' : ''}`} aria-label="Main menu" id="arwb-sidebar">
        <div className="arwb-sidebar-top">
          <div className="arwb-brand-mark">LRN</div>
          <div>
            <div className="arwb-brand-title-main">AR Workbench</div>
            <div className="arwb-brand-title-sub">Denial &amp; Insurance AR</div>
          </div>
          <button type="button" className="arwb-icon-btn ms-auto" onClick={toggleNav} aria-label="Hide menu" title="Hide menu">
            <Icon name="close" />
          </button>
        </div>
        <nav className="arwb-nav-list">
          {items.map((item) => {
            if (!item.children) return <NavItem key={item.id} item={item} count={item.countKey ? counts[item.countKey] : 0} />;

            // A group: a toggle with its children beneath. The group holding the current page
            // always shows it, so the active item is never hidden inside a collapsed group.
            const inGroup = item.children.some((c) => c.path === location.pathname);
            const open = inGroup || !collapsed.includes(item.id);
            return (
              <div key={item.id}>
                <button type="button" className={`arwb-nav-item arwb-nav-group-btn${inGroup ? ' in-group' : ''}`} aria-expanded={open}
                  aria-controls={`nav-${item.id}`} onClick={() => { if (!inGroup) toggleGroup(item.id); }} title={item.label}>
                  <span className="arwb-nav-ic"><Icon name={item.icon} /></span>
                  <span className="arwb-nav-label">{item.label}</span>
                  <span className={`arwb-nav-chev${open ? ' open' : ''}`}><Icon name="chevronDown" size={15} /></span>
                </button>
                {open && (
                  <div className="arwb-nav-sub" id={`nav-${item.id}`}>
                    {item.children.map((child) => <NavItem key={child.id} item={{ ...child, built: item.built, phase: item.phase }} count={0} />)}
                  </div>
                )}
              </div>
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
          <button type="button" className="arwb-icon-btn" onClick={toggleNav} aria-controls="arwb-sidebar"
            aria-label={navHidden ? 'Show menu' : 'Hide or show menu'} title={navHidden ? 'Show menu' : 'Hide menu'}>
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
            <div className="arwb-user-menu" ref={userMenuRef}>
              <button type="button" className="arwb-user-chip arwb-user-chip-btn" onClick={() => setUserMenuOpen((v) => !v)}
                aria-haspopup="menu" aria-expanded={userMenuOpen} title="Account">
                <span className="arwb-user-avatar">{initials(user?.displayName)}</span>
                <span className="lh-sm arwb-user-chip-text">
                  <span className="arwb-u-name">{user?.displayName}</span><br />
                  <span className="arwb-u-role">{user?.roleLabel}</span>
                </span>
                <Icon name="chevronDown" size={14} />
              </button>
              {userMenuOpen && (
                <div className="arwb-popover right arwb-user-dropdown" role="menu">
                  <div className="arwb-user-dropdown-head">
                    <b>{user?.displayName}</b>
                    <span className="arwb-hint">{user?.userName}</span>
                  </div>
                  <button type="button" role="menuitem" className="arwb-menu-item" onClick={() => { setUserMenuOpen(false); setChangingPassword(true); }}>
                    <Icon name="key" size={15} /> Change password
                  </button>
                  <button type="button" role="menuitem" className="arwb-menu-item" onClick={logout}>
                    <Icon name="logout" size={15} /> Sign out
                  </button>
                </div>
              )}
            </div>
            <button type="button" className="arwb-btn arwb-btn-ghost arwb-btn-sm" onClick={logout} title="Sign out">
              <Icon name="logout" size={15} /><span className="d-none d-md-inline">Sign out</span>
            </button>
          </div>
        </header>
        <main className="arwb-view-container">
          <Notice notice={accountNotice} onClose={() => setAccountNotice(null)} />
          {user?.clientActive === false && (
            <div className="arwb-alert" role="status" style={{ marginBottom: 14 }}>
              <span className="grow">This client is <b>deactivated</b> in the AR Workbench: only administrators can open it, and the nightly snapshot skips it. Reactivate it in Client Management.</span>
            </div>
          )}
          <Outlet />
        </main>
      </div>
      {changingPassword && (
        <ChangePasswordModal onClose={() => setChangingPassword(false)}
          onChanged={(message) => { setChangingPassword(false); setAccountNotice({ kind: 'good', text: message }); }} />
      )}
    </div>
  );
}
