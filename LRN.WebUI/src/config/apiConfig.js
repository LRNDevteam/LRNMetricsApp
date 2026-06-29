function cleanBase(value) {
  return String(value || '').trim().replace(/\/+$/, '');
}

function normalizeLocalhostPorts(value) {
  const v = cleanBase(value);
  if (!v) return '';
  return v
    .replace(/^https?:\/\/localhost:57996(?=\/|$)/i, 'https://localhost:44351')
    .replace(/^https?:\/\/127\.0\.0\.1:57996(?=\/|$)/i, 'https://127.0.0.1:44351');
}

function firstValue(...values) {
  for (const value of values) {
    const cleaned = normalizeLocalhostPorts(value);
    if (cleaned) return cleaned;
  }
  return '';
}

const isProdHost =
  window.location.hostname === 'www.lrnanalytics.com' ||
  window.location.hostname === 'lrnanalytics.com';

function resolveMetricsBase() {
  // IMPORTANT: explicit config must win first. This is required for local Vite debug.
  const configured = firstValue(
    import.meta.env.VITE_LRN_METRICS_BASE_URL,
    import.meta.env.VITE_LRN_METRICS_BASE,
    window.__LRN_METRICS_BASE,
    localStorage.getItem('lrn.metrics.base'),
    sessionStorage.getItem('lrn.metrics.base')
  );
  if (configured) return configured;

  if (isProdHost) return `${window.location.origin}/lrnAnalytics`;

  if (window.location.pathname.toLowerCase().startsWith('/lrnanalytics')) {
    return `${window.location.origin}/lrnAnalytics`;
  }

  // Last local fallback only. Prefer .env.development.
  if (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') {
    return 'https://localhost:44351';
  }

  return `${window.location.origin}/lrnAnalytics`;
}

function resolveReportsApiBase() {
  // IMPORTANT: explicit config must win first. This is required for local Vite debug.
  const configured = firstValue(
    import.meta.env.VITE_REPORTS_API_BASE_URL,
    import.meta.env.VITE_DENIAL_API_BASE,
    window.__LRN_DENIAL_API_BASE,
    localStorage.getItem('lrn.denial.api.base'),
    sessionStorage.getItem('lrn.denial.api.base')
  );
  if (configured) return configured;

  if (isProdHost) return `${window.location.origin}/lrnapi/api/denialworkflow`;

  // Last local fallback only. Prefer .env.development.
  if (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') {
    return 'https://localhost:5058/api/denialworkflow';
  }

  return `${window.location.origin}/lrnapi/api/denialworkflow`;
}

export const LRN_METRICS_BASE_URL = resolveMetricsBase();
export const REPORTS_API_BASE_URL = resolveReportsApiBase();

// Backward-compatible export used by some existing files.
export const API_BASE = REPORTS_API_BASE_URL;

export const AUTH_TOKEN_URL = `${LRN_METRICS_BASE_URL}/DenialWorkflow/AuthToken`;
export const LOGIN_URL = `${LRN_METRICS_BASE_URL}/Account/Login`;

export const LOGOUT_URL = `${LRN_METRICS_BASE_URL}/DenialWorkflow/Logout`;
