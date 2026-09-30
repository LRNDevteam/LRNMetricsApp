function cleanBase(value) {
  return String(value || '').trim().replace(/\/+$/, '');
}

function firstValue(...values) {
  for (const value of values) {
    const cleaned = cleanBase(value);
    if (cleaned) return cleaned;
  }
  return '';
}

const isProdHost =
  window.location.hostname === 'www.lrnanalytics.com' ||
  window.location.hostname === 'lrnanalytics.com';

// LabMetricsDashboard (MVC) owns login and issues the workflow JWT, exactly as for LRN.WebUI.
function resolveMetricsBase() {
  const configured = firstValue(import.meta.env.VITE_LRN_METRICS_BASE_URL, window.__LRN_METRICS_BASE);
  if (configured) return configured;
  if (isProdHost) return `${window.location.origin}/lrnAnalytics`;
  if (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') return 'https://localhost:44351';
  return `${window.location.origin}/lrnAnalytics`;
}

function resolveApiBase() {
  const configured = firstValue(import.meta.env.VITE_AR_WORKBENCH_API_BASE_URL, window.__LRN_AR_WORKBENCH_API_BASE);
  if (configured) return configured;
  if (isProdHost) return `${window.location.origin}/lrnapi/api/ar-workbench`;
  if (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') return 'https://localhost:62408/api/ar-workbench';
  return `${window.location.origin}/lrnapi/api/ar-workbench`;
}

export const LRN_METRICS_BASE_URL = resolveMetricsBase();
export const AR_WORKBENCH_API_BASE_URL = resolveApiBase();

export const AUTH_TOKEN_URL = `${LRN_METRICS_BASE_URL}/DenialWorkflow/AuthToken`;
export const LOGIN_URL = `${LRN_METRICS_BASE_URL}/Account/Login`;
export const LOGOUT_URL = `${LRN_METRICS_BASE_URL}/DenialWorkflow/Logout`;
