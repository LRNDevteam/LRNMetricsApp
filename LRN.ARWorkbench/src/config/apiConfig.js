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

// Order: the deployment's config.js (public/config.js, editable after deploy) > the build's .env >
// host-based defaults. config.js is what lets one build serve Test and Production.
// Under `npm run dev` config.js is ignored: Vite serves public/config.js too, and its deployed-server
// URLs would send a local run to that server's login and API instead of .env.development's.
const runtime = import.meta.env.DEV ? {} : (window.LRN_AR_WORKBENCH_CONFIG || {});

// LabMetricsDashboard (MVC) owns login and issues the workflow JWT, exactly as for LRN.WebUI.
function resolveMetricsBase() {
  const configured = firstValue(runtime.lrnMetricsBaseUrl, window.__LRN_METRICS_BASE, import.meta.env.VITE_LRN_METRICS_BASE_URL);
  if (configured) return configured;
  if (isProdHost) return `${window.location.origin}/lrnAnalytics`;
  if (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') return 'https://localhost:44351';
  return `${window.location.origin}/lrnAnalytics`;
}

function resolveApiBase() {
  const configured = firstValue(runtime.apiBaseUrl, window.__LRN_AR_WORKBENCH_API_BASE, import.meta.env.VITE_AR_WORKBENCH_API_BASE_URL);
  if (configured) return configured;
  if (isProdHost) return `${window.location.origin}/lrnapi/api/ar-workbench`;
  if (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') return 'https://localhost:62408/api/ar-workbench';
  return `${window.location.origin}/lrnapi/api/ar-workbench`;
}

export const LRN_METRICS_BASE_URL = resolveMetricsBase();
export const AR_WORKBENCH_API_BASE_URL = resolveApiBase();

export const AUTH_TOKEN_URL = `${LRN_METRICS_BASE_URL}/DenialWorkflow/AuthToken`;
export const LOGIN_URL = firstValue(runtime.loginUrl) || `${LRN_METRICS_BASE_URL}/Account/Login`;
// Logout signs out of LRN Metrics (the same environment as the login) and lands on its login page.
export const LOGOUT_URL = firstValue(runtime.logoutUrl) || `${LRN_METRICS_BASE_URL}/DenialWorkflow/Logout`;
