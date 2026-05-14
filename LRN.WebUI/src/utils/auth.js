import { AUTH_TOKEN_URL, LOGIN_URL } from '../config/apiConfig';

const TOKEN_KEYS = ['lrn.workflow.jwt'];
const LEGACY_TOKEN_KEYS = ['lrn.jwt', 'lrnMetrics.jwt', 'access_token', 'jwtToken', 'token', 'authToken'];

let authTokenPromise = null;
let redirectStarted = false;

function isLocalReactHost() {
  return window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1';
}

function cleanToken(token) {
  return String(token || '').replace(/^Bearer\s+/i, '').trim();
}

function allTokenKeys() {
  return [...TOKEN_KEYS, ...LEGACY_TOKEN_KEYS];
}

export function getJwt() {
  for (const key of allTokenKeys()) {
    const value = localStorage.getItem(key) || sessionStorage.getItem(key);
    const token = cleanToken(value);
    if (token) return token;
  }
  return '';
}

export function setWorkflowJwt(token) {
  const clean = cleanToken(token);
  if (!clean) return;
  localStorage.setItem('lrn.workflow.jwt', clean);
  sessionStorage.setItem('lrn.workflow.jwt', clean);
}

export function clearWorkflowJwt() {
  for (const key of allTokenKeys()) {
    localStorage.removeItem(key);
    sessionStorage.removeItem(key);
  }
}

export function parseJwt(token) {
  try {
    const clean = cleanToken(token);
    if (!clean) return {};
    const payload = clean.split('.')[1];
    if (!payload) return {};
    const normalized = payload.replace(/-/g, '+').replace(/_/g, '/');
    const padded = normalized.padEnd(normalized.length + ((4 - normalized.length % 4) % 4), '=');
    return JSON.parse(atob(padded));
  } catch {
    return {};
  }
}

export function isJwtValid(token, skewSeconds = 60) {
  const claims = parseJwt(token);
  const exp = Number(claims.exp || 0);
  if (!exp) return false;
  return exp > Math.floor(Date.now() / 1000) + skewSeconds;
}

export function claimRole(claims = {}) {
  const value =
    claims.role ||
    claims.roles ||
    claims['http://schemas.microsoft.com/ws/2008/06/identity/claims/role'];

  if (Array.isArray(value)) return value[0] || '';
  return value || '';
}

export function claimRoles(claims = {}) {
  const value =
    claims.roles ||
    claims.role ||
    claims['http://schemas.microsoft.com/ws/2008/06/identity/claims/role'];

  if (Array.isArray(value)) return value;
  return value ? [value] : [];
}

export function claimUser(claims = {}) {
  return (
    claims.name ||
    claims.userName ||
    claims.UserName ||
    claims.preferred_username ||
    claims.unique_name ||
    claims.upn ||
    claims.email ||
    claims.sub ||
    claims['http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name'] ||
    ''
  );
}

export function claimDisplayName(claims = {}) {
  return claims.display_name || claims.displayName || claims.DisplayName || claimUser(claims);
}

function currentReturnUrl() {
  const loginOrigin = (() => {
    try { return new URL(LOGIN_URL).origin; } catch { return window.location.origin; }
  })();

  // Same-origin production: keep a normal local ReturnUrl.
  if (loginOrigin === window.location.origin) {
    return `${window.location.pathname}${window.location.search}${window.location.hash}` || '/';
  }

  // Local Vite debug is cross-origin. Keep the full React URL so login can come back
  // when the MVC login action allows it. If it does not, user can reopen React after login.
  return window.location.href;
}

export function getLoginUrl() {
  return `${LOGIN_URL}?ReturnUrl=${encodeURIComponent(currentReturnUrl())}`;
}

export function redirectToMetricsLogin() {
  if (redirectStarted) return;
  redirectStarted = true;
  clearWorkflowJwt();
  window.location.replace(getLoginUrl());
}

async function readAuthError(response) {
  const contentType = response.headers.get('content-type') || '';
  if (contentType.toLowerCase().includes('application/json')) {
    const data = await response.json().catch(() => null);
    return data?.message || data?.title || data?.error || JSON.stringify(data || {});
  }
  return (await response.text().catch(() => '')) || `Auth token error ${response.status}`;
}

export async function ensureWorkflowJwt(options = {}) {
  const forceRefresh = options.forceRefresh === true;
  const current = getJwt();

  if (!forceRefresh && isJwtValid(current)) return current;

  if (!authTokenPromise) {
    authTokenPromise = fetch(AUTH_TOKEN_URL, {
      method: 'GET',
      credentials: 'include',
      cache: 'no-store',
      headers: { Accept: 'application/json' }
    })
      .then(async (response) => {
        if (response.status === 401 || response.status === 403) {
          if (isLocalReactHost()) {
            throw new Error(
              'AuthToken returned Unauthorized from MVC. You are logged in when opening the URL directly, ' +
              'but the LRN.Auth cookie is not being sent from React localhost. Rebuild/restart LabMetricsDashboard with the updated Program.cs, then delete the old LRN.Auth cookie and login again.'
            );
          }
          redirectToMetricsLogin();
          throw new Error('Login required. Redirecting to LRN Metrics login.');
        }

        if (response.status === 404) {
          throw new Error(`AuthToken URL not found: ${AUTH_TOKEN_URL}. Check VITE_LRN_METRICS_BASE_URL.`);
        }

        if (!response.ok) {
          throw new Error(await readAuthError(response));
        }

        const contentType = response.headers.get('content-type') || '';
        if (!contentType.toLowerCase().includes('application/json')) {
          redirectToMetricsLogin();
          throw new Error('AuthToken returned HTML instead of JSON. Login cookie was not accepted.');
        }

        const data = await response.json();
        const token = data.token || data.Token || data.accessToken || data.AccessToken || data.jwt || data.Jwt;
        if (!token) throw new Error('AuthToken response did not contain token/accessToken.');

        setWorkflowJwt(token);
        return cleanToken(token);
      })
      .catch((error) => {
        if (isLocalReactHost() && (error instanceof TypeError || String(error?.message || '').includes('Failed to fetch'))) {
          throw new Error(
            `Cannot call AuthToken from React localhost. Check CORS and local HTTPS. Auth URL: ${AUTH_TOKEN_URL}. ` +
            'Use the updated LabMetricsDashboard Program.cs, restart MVC, and ensure the Vite origin http://localhost:5173 is allowed.'
          );
        }
        throw error;
      })
      .finally(() => {
        authTokenPromise = null;
      });
  }

  return authTokenPromise;
}
