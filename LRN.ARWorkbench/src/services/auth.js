import { AUTH_TOKEN_URL, LOGIN_URL } from '../config/apiConfig';

// Same token flow as LRN.WebUI: the MVC session cookie buys a short-lived JWT from AuthToken,
// held in memory only (never localStorage), refreshed on expiry or on a 401 from the API.
let jwt = '';
let pending = null;
let redirectStarted = false;

function cleanToken(token) {
  return String(token || '').replace(/^Bearer\s+/i, '').trim();
}

export function parseJwt(token) {
  try {
    const payload = cleanToken(token).split('.')[1];
    if (!payload) return {};
    const normalized = payload.replace(/-/g, '+').replace(/_/g, '/');
    const padded = normalized.padEnd(normalized.length + ((4 - (normalized.length % 4)) % 4), '=');
    return JSON.parse(atob(padded));
  } catch {
    return {};
  }
}

function isValid(token, skewSeconds = 60) {
  const exp = Number(parseJwt(token).exp || 0);
  return exp > Math.floor(Date.now() / 1000) + skewSeconds;
}

export function clearJwt() {
  jwt = '';
}

export function currentClaims() {
  return parseJwt(jwt);
}

export function redirectToLogin() {
  if (redirectStarted) return;
  redirectStarted = true;
  clearJwt();
  let sameOrigin = false;
  try { sameOrigin = new URL(LOGIN_URL).origin === window.location.origin; } catch { /* keep false */ }
  const returnUrl = sameOrigin
    ? `${window.location.pathname}${window.location.search}${window.location.hash}`
    : window.location.href;
  window.location.replace(`${LOGIN_URL}?ReturnUrl=${encodeURIComponent(returnUrl)}`);
}

export async function ensureJwt({ forceRefresh = false } = {}) {
  if (!forceRefresh && isValid(jwt)) return jwt;
  if (!pending) {
    pending = fetch(AUTH_TOKEN_URL, { method: 'GET', credentials: 'include', cache: 'no-store', headers: { Accept: 'application/json' } })
      .then(async (response) => {
        if (response.status === 401 || response.status === 403) {
          redirectToLogin();
          throw new Error('Login required. Redirecting to LRN Metrics login.');
        }
        if (!response.ok) throw new Error(`AuthToken failed (${response.status}). Auth URL: ${AUTH_TOKEN_URL}`);
        if (!(response.headers.get('content-type') || '').toLowerCase().includes('application/json')) {
          redirectToLogin();
          throw new Error('AuthToken returned HTML instead of JSON. Login cookie was not accepted.');
        }
        const data = await response.json();
        const token = cleanToken(data.token || data.Token || data.accessToken || data.AccessToken || data.jwt || data.Jwt);
        if (!token) throw new Error('AuthToken response did not contain a token.');
        jwt = token;
        return token;
      })
      .catch((error) => {
        if (error instanceof TypeError) {
          throw new Error(
            `Cannot reach AuthToken at ${AUTH_TOKEN_URL}. For local debug, run LabMetricsDashboard on https://localhost:44351 ` +
            'and add this origin (https://localhost:5174) to DenialWorkflowCors:AllowedOrigins in its appsettings.'
          );
        }
        throw error;
      })
      .finally(() => { pending = null; });
  }
  return pending;
}
