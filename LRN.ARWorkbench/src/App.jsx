import { HashRouter, Navigate, Route, Routes } from 'react-router';
import AppShell from './components/AppShell';
import { ErrorBox, Loading } from './components/Status';
import { allows, REDIRECTS, ROUTES } from './config/navigation';
import { useWorkbench, WorkbenchProvider } from './context/WorkbenchContext';
import AssignmentPage from './pages/AssignmentPage';
import AuditPage from './pages/AuditPage';
import CipPage from './pages/CipPage';
import ClientCipPage from './pages/ClientCipPage';
import ClientsPage from './pages/ClientsPage';
import ClaimDetailPage from './pages/ClaimDetailPage';
import CodeMasterPage from './pages/CodeMasterPage';
import DashboardPage from './pages/DashboardPage';
import DataProcessingPage from './pages/DataProcessingPage';
import DenialCodeMasterPage from './pages/DenialCodeMasterPage';
import MasterDataPage from './pages/MasterDataPage';
import PlannedPage from './pages/PlannedPage';
import QaPage from './pages/QaPage';
import TflSettingsPage from './pages/TflSettingsPage';
import UsersPage from './pages/UsersPage';
import WorkQueuePage from './pages/WorkQueuePage';
import { FollowUpPage, MyWorkPage } from './pages/WorklistPage';

const SCREENS = {
  dashboard: DashboardPage,
  workqueue: WorkQueuePage,
  assignment: AssignmentPage,
  mywork: MyWorkPage,
  followup: FollowUpPage,
  users: UsersPage,
  qa: QaPage,
  audit: AuditPage,
  clients: ClientsPage,
  cip: CipPage,
  'client-cip': ClientCipPage,
  'data-processing': DataProcessingPage,
  // Master Values submenu: one page component serves several menu items, each a different view.
  'master-values': MasterDataPage,
  'denial-codes': DenialCodeMasterPage,
  'tfl-limits': TflSettingsPage,
  'code-master': CodeMasterPage
};

// Route access is checked against the same NAV list that builds the sidebar. The API enforces
// the same rules server-side; this guard only keeps the UI honest.
function Guard({ item }) {
  const { user } = useWorkbench();
  if (!allows(user, item)) {
    return <ErrorBox message={`Your role (${user?.roleLabel || 'unknown'}) cannot open ${item.label}.`} />;
  }
  const Screen = item.built ? SCREENS[item.screen || item.id] : null;
  // key: moving between two views of the same page starts that page fresh.
  return Screen ? <Screen key={item.id} view={item.view} /> : <PlannedPage item={item} />;
}

function Gate() {
  const { status, error, labs, setLabId, labId } = useWorkbench();

  if (status === 'loading') return <div style={{ padding: 24 }}><Loading text="Opening AR Workbench…" /></div>;
  if (status === 'error') {
    return (
      <div style={{ maxWidth: 640, margin: '0 auto', padding: '48px 16px' }}>
        <div className="arwb-sidebar-top" style={{ border: 0, padding: '0 0 16px' }}>
          <span className="arwb-brand-mark">LRN</span>
          <span className="arwb-brand-title-main">AR Workbench</span>
        </div>
        <ErrorBox message={error} />
        {labs.length > 1 && (
          <select className="arwb-select" style={{ width: 'auto' }} value={labId || ''} onChange={(e) => setLabId(Number(e.target.value))}>
            {labs.map((l) => <option key={l.labId} value={l.labId}>{l.labName}</option>)}
          </select>
        )}
      </div>
    );
  }

  return (
    <Routes>
      <Route element={<AppShell />}>
        {ROUTES.map((item) => (
          <Route key={item.id} path={item.path === '/' ? undefined : item.path} index={item.path === '/'} element={<Guard item={item} />} />
        ))}
        <Route path="/masters" element={<Navigate to={ROUTES.find((r) => r.group === 'masters')?.path || '/'} replace />} />
        {Object.entries(REDIRECTS).map(([from, to]) => <Route key={from} path={from} element={<Navigate to={to} replace />} />)}
        <Route path="/claims/:claimKey" element={<ClaimDetailPage />} />
        <Route path="*" element={<ErrorBox message="Page not found." />} />
      </Route>
    </Routes>
  );
}

export default function App() {
  return (
    <HashRouter>
      <WorkbenchProvider>
        <Gate />
      </WorkbenchProvider>
    </HashRouter>
  );
}
