import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { useWorkbench } from './WorkbenchContext';

// Background exports - the Denial Workflow's Overall Download pattern (LRN.WebUI App.jsx +
// DenialWorkflowExportJobService). An Export button only queues a job on the API, which builds the
// file without a request clock; this provider polls every running job, downloads the file when it
// is ready and keeps the list behind the top bar's Downloads button. It lives in AppShell, so a job
// keeps running (and still downloads) while the user moves between pages.

const POLL_MS = 4000;
const ACTIVE = ['Queued', 'Running'];
export const isActiveJob = (job) => ACTIVE.includes(job?.status);

const ExportJobsContext = createContext(null);

export function ExportJobsProvider({ children }) {
  const { labId } = useWorkbench();
  const [jobs, setJobs] = useState([]);
  const [notice, setNotice] = useState(null);
  const [tick, setTick] = useState(() => Date.now());
  // Jobs this browser has seen running: those download automatically once they complete.
  const watched = useRef(new Set());
  const labRef = useRef(labId);
  labRef.current = labId;

  const merge = useCallback((job) => {
    if (!job?.jobId) return;
    setJobs((list) => [job, ...list.filter((j) => j.jobId !== job.jobId)]
      .sort((a, b) => new Date(b.createdOnUtc) - new Date(a.createdOnUtc)));
  }, []);

  const download = useCallback(async (job) => {
    try {
      await arWorkbenchService.downloadExport(labRef.current, job.jobId, job.fileName);
      merge({ ...job, status: 'Downloaded' });
    } catch (e) {
      setNotice({ kind: 'warning', text: e.message || 'The export file could not be downloaded. Please start the export again.' });
    }
  }, [merge]);

  // The Downloads list (running and recent jobs, including ones from before a page reload).
  const refresh = useCallback(async (signal) => {
    if (!labRef.current) return;
    try {
      const list = await arWorkbenchService.exportJobs(labRef.current, signal);
      (list || []).filter(isActiveJob).forEach((j) => watched.current.add(j.jobId));
      setJobs(list || []);
    } catch { /* the list is optional; Export buttons report their own errors */ }
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    refresh(controller.signal);
    return () => controller.abort();
  }, [labId, refresh]);

  const activeIds = jobs.filter(isActiveJob).map((j) => j.jobId).join(',');

  // Poll each running job; on Completed, save the file (once) and say so.
  useEffect(() => {
    if (!activeIds || !labId) return undefined;
    let cancelled = false;
    const check = async () => {
      for (const jobId of activeIds.split(',')) {
        try {
          const job = await arWorkbenchService.exportJob(labId, jobId);
          if (cancelled) return;
          merge(job);
          if (job.status === 'Completed' && watched.current.has(jobId)) {
            watched.current.delete(jobId);
            setNotice({ kind: 'good', text: `${job.scope} export is ready (${Number(job.rowCount || 0).toLocaleString()} rows). Your download should start now - use Downloads if it does not.` });
            download(job);
          } else if (['Failed', 'Cancelled'].includes(job.status) && watched.current.has(jobId)) {
            watched.current.delete(jobId);
            if (job.status === 'Failed') setNotice({ kind: 'warning', text: `${job.scope} export failed: ${job.message}` });
          }
        } catch (e) {
          if (cancelled) return;
          if (e.status === 404) {
            watched.current.delete(jobId);
            setJobs((list) => list.filter((j) => j.jobId !== jobId));
            setNotice({ kind: 'info', text: 'An export job expired. Please start the export again.' });
          }
        }
      }
    };
    check();
    const timer = setInterval(check, POLL_MS);
    return () => { cancelled = true; clearInterval(timer); };
  }, [activeIds, labId, merge, download]);

  // Elapsed time on running jobs.
  useEffect(() => {
    if (!activeIds) return undefined;
    const timer = setInterval(() => setTick(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [activeIds]);

  /**
   * Queue an export. start: () => Promise<job> (an arWorkbenchService.start*Export call).
   * Returns the job, or null when it could not be started (the reason is in the notice).
   */
  const startExport = useCallback(async (start) => {
    try {
      const job = await start();
      watched.current.add(job.jobId);
      merge(job);
      setNotice({
        kind: 'info',
        text: job.alreadyRunning
          ? job.message
          : `${job.scope} download is in progress. The file is being created in the background - you can keep working, and it will download automatically when it is ready.`
      });
      return job;
    } catch (e) {
      setNotice({ kind: 'warning', text: e.message || 'The export could not be started.' });
      return null;
    }
  }, [merge]);

  const cancel = useCallback(async (job) => {
    try {
      const result = await arWorkbenchService.cancelExport(labRef.current, job.jobId);
      watched.current.delete(job.jobId);
      if (result?.status === 'Deleted') setJobs((list) => list.filter((j) => j.jobId !== job.jobId));
      else {
        merge(result);
        setNotice({ kind: 'info', text: `${job.scope} export cancelled.` });
      }
    } catch (e) {
      setNotice({ kind: 'warning', text: e.message });
    }
  }, [merge]);

  const value = useMemo(() => ({
    jobs, tick, notice, setNotice, startExport, download, cancel, refresh,
    activeCount: jobs.filter(isActiveJob).length,
    // A page's Export button shows a spinner while its own export runs.
    isRunning: (scope) => jobs.some((j) => isActiveJob(j) && j.labId === labId && j.scope === scope)
  }), [jobs, tick, notice, startExport, download, cancel, refresh, labId]);

  return <ExportJobsContext.Provider value={value}>{children}</ExportJobsContext.Provider>;
}

export function useExportJobs() {
  const ctx = useContext(ExportJobsContext);
  if (!ctx) throw new Error('useExportJobs must be used inside ExportJobsProvider');
  return ctx;
}
