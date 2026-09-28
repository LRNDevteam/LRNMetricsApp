import { HashRouter, Route, Routes } from 'react-router';
import AppShell from './components/AppShell';
import { ErrorBox, Loading } from './components/Status';
import { NAV } from './config/navigation';
import { useWorkbench, WorkbenchProvider } from './context/WorkbenchContext';
import ClaimDetailPage from './pages/ClaimDetailPage';
import DashboardPage from './pages/DashboardPage';
import DataProcessingPage from './pages/DataProcessingPage';
import MasterDataPage from './pages/MasterDataPage';
import PlannedPage from './pages/PlannedPage';
import WorkQueuePage from './pages/WorkQueuePage';

const SCREENS = {
  dashboard: DashboardPage,
  workqueue: WorkQueuePage,
  'data-processing': DataProcessingPage,
  settings: MasterDataPage
};

// Route access is checked against the same NAV list that builds the sidebar. The API enforces
// the same rules server-side; this guard only keeps the UI honest.
function Guard({ item }) {
  const { user } = useWorkbench();
  if (!item.roles.includes(user?.roleCode)) {
    return <ErrorBox message={`Your role (${user?.roleLabel || 'unknown'}) cannot open ${item.label}.`} />;
  }
  const Screen = item.built ? SCREENS[item.id] : null;
  return Screen ? <Screen /> : <PlannedPage item={item} />;
}

function Gate() {
  const { status, error, labs, setLabId, labId } = useWorkbench();

  if (status === 'loading') return <div className="p-4"><Loading text="Opening AR Workbench…" /></div>;
  if (status === 'error') {
    return (
      <div className="container py-5" style={{ maxWidth: 640 }}>
        <h1 className="h4 mb-3">AR Workbench</h1>
        <ErrorBox message={error} />
        {labs.length > 1 && (
          <select className="form-select form-select-sm w-auto" value={labId || ''} onChange={(e) => setLabId(Number(e.target.value))}>
            {labs.map((l) => <option key={l.labId} value={l.labId}>{l.labName}</option>)}
          </select>
        )}
      </div>
    );
  }

  return (
    <Routes>
      <Route element={<AppShell />}>
        {NAV.map((item) => (
          <Route key={item.id} path={item.path === '/' ? undefined : item.path} index={item.path === '/'} element={<Guard item={item} />} />
        ))}
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
