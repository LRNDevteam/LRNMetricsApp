import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { arWorkbenchService } from '../services/arWorkbenchService';

const WorkbenchContext = createContext(null);
const LAB_KEY = 'lrn.arwb.labId';

function readStoredLab() {
  try { return Number(localStorage.getItem(LAB_KEY)) || 0; } catch { return 0; }
}

function storeLab(labId) {
  try { localStorage.setItem(LAB_KEY, String(labId)); } catch { /* storage blocked: lab choice is per-session only */ }
}

/**
 * App-wide state: the labs the user can open, the selected lab, and the signed-in user's
 * workbench context for that lab (role, permissions, access scope) from /me.
 * can(perm) is the single permission check every screen uses - never a role-name comparison.
 */
export function WorkbenchProvider({ children }) {
  const [labs, setLabs] = useState([]);
  const [labId, setLabIdState] = useState(0);
  const [user, setUser] = useState(null);
  const [masterData, setMasterData] = useState(null);
  const [status, setStatus] = useState('loading'); // loading | ready | error
  const [error, setError] = useState('');

  useEffect(() => {
    let cancelled = false;
    arWorkbenchService.labs()
      .then((list) => {
        if (cancelled) return;
        const sorted = [...(list || [])].sort((a, b) => String(a.labName).localeCompare(String(b.labName)));
        setLabs(sorted);
        const stored = readStoredLab();
        const initial = sorted.find((l) => l.labId === stored)?.labId || sorted[0]?.labId || 0;
        if (!initial) {
          setStatus('error');
          setError('You do not have access to any lab. Ask an administrator for lab access.');
          return;
        }
        setLabIdState(initial);
      })
      .catch((e) => {
        if (cancelled) return;
        setStatus('error');
        setError(e.message);
      });
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    if (!labId) return undefined;
    let cancelled = false;
    setStatus('loading');
    setError('');
    Promise.all([arWorkbenchService.me(labId), arWorkbenchService.masterData(labId)])
      .then(([me, master]) => {
        if (cancelled) return;
        setUser(me);
        setMasterData(master);
        setStatus('ready');
      })
      .catch((e) => {
        if (cancelled) return;
        setUser(null);
        setMasterData(null);
        setStatus('error');
        setError(e.message);
      });
    return () => { cancelled = true; };
  }, [labId]);

  const setLabId = useCallback((id) => {
    storeLab(id);
    setLabIdState(id);
  }, []);

  const can = useCallback((perm) => Boolean(user?.permissions?.[perm]), [user]);

  // After a Master File Maintenance change, so every screen's dropdowns offer the new lists.
  const reloadMasterData = useCallback(async () => {
    if (!labId) return;
    try { setMasterData(await arWorkbenchService.masterData(labId)); } catch { /* keep the lists already loaded */ }
  }, [labId]);

  const value = useMemo(() => ({
    labs, labId, setLabId, user, masterData, reloadMasterData, status, error, can,
    lab: labs.find((l) => l.labId === labId) || null
  }), [labs, labId, setLabId, user, masterData, reloadMasterData, status, error, can]);

  return <WorkbenchContext.Provider value={value}>{children}</WorkbenchContext.Provider>;
}

export function useWorkbench() {
  const ctx = useContext(WorkbenchContext);
  if (!ctx) throw new Error('useWorkbench must be used inside WorkbenchProvider');
  return ctx;
}
