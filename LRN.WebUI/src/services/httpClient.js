import { REPORTS_API_BASE_URL } from '../config/apiConfig';
import { clearWorkflowJwt, ensureWorkflowJwt } from '../utils/auth';
import { logClientError } from './clientLogger';

const API_BASE_URL = REPORTS_API_BASE_URL;
export const GENERIC_WORKFLOW_ERROR = 'Issue happened. Please contact admin support.';

export class DenialWorkflowError extends Error {
  constructor(message = GENERIC_WORKFLOW_ERROR, options = {}) {
    super(message);
    this.name = 'DenialWorkflowError';
    this.correlationId = options.correlationId || '';
    this.supportEmails = Array.isArray(options.supportEmails) ? options.supportEmails : [];
    this.safeForUser = options.safeForUser !== false;
  }
}

function joinUrl(base, path) {
  const b = String(base || '').replace(/\/+$/, '');
  const p = String(path || '').replace(/^\/+/, '');
  return p ? `${b}/${p}` : b;
}

async function readError(response) {
  const requestId =
    response.headers.get('x-correlation-id') ||
    response.headers.get('x-request-id') ||
    response.headers.get('traceparent') ||
    '';
  const contentType = response.headers.get('content-type') || '';
  let message = '';
  if (contentType.toLowerCase().includes('application/json')) {
    const data = await response.json().catch(() => null);
    const supportEmails = data?.supportEmails || data?.SupportEmails || [];
    const reason = data?.reason ? ` ${data.reason}` : '';
    const correlationId = data?.correlationId || data?.CorrelationId || data?.traceId || data?.traceID || requestId;
    if (response.status >= 500 || supportEmails.length) {
      return new DenialWorkflowError(GENERIC_WORKFLOW_ERROR, { correlationId, supportEmails });
    }
    message = data?.message ? `${data.message}${reason}` : data?.title || data?.error || JSON.stringify(data || {});
    if (correlationId && !String(message).toLowerCase().includes('error id')) {
      return `${message || 'Unable to load claims. Please retry.'} If the issue continues, contact support with Error ID: ${correlationId}`;
    }
    return message;
  }
  message = (await response.text().catch(() => '')) || `${response.status} ${response.statusText}`;
  if (response.status >= 500) {
    return new DenialWorkflowError(GENERIC_WORKFLOW_ERROR, { correlationId: requestId });
  }
  return requestId ? `${message} If the issue continues, contact support with Error ID: ${requestId}` : message;
}

async function executeRequest(path, options = {}, jwt = '') {
  const headers = new Headers(options.headers || {});

  if (!headers.has('Accept')) headers.set('Accept', 'application/json');

  // Do not set JSON content-type for FormData uploads. Browser must add multipart boundary.
  if (options.body && !(options.body instanceof FormData) && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json');
  }

  if (jwt) {
    headers.set('Authorization', `Bearer ${jwt}`);
    headers.set('X-LRN-Workflow-Jwt', jwt);
    headers.set('X-Authorization', `Bearer ${jwt}`);
  }

  const url = joinUrl(API_BASE_URL, path);

  return fetch(url, {
    ...options,
    headers,
    credentials: 'include',
    cache: options.cache || 'no-store'
  });
}

export async function api(path, options = {}) {
  let token;
  let response;
  try {
    token = await ensureWorkflowJwt();
    // #region debug-point C:api-start
    fetch("http://127.0.0.1:7777/event",{method:"POST",body:JSON.stringify({sessionId:"metrics-auth-failure",runId:"pre",hypothesisId:"C",location:"src/services/httpClient.js:api:start",msg:"[DEBUG] API request starting",data:{path,method:options?.method||'GET',hasToken:Boolean(token)},ts:Date.now()})}).catch(()=>{});
    // #endregion
    response = await executeRequest(path, options, token);

    // Token expired/changed signature: refresh once only.
    if (response.status === 401 || response.status === 403) {
      // #region debug-point C:api-retry-auth
      fetch("http://127.0.0.1:7777/event",{method:"POST",body:JSON.stringify({sessionId:"metrics-auth-failure",runId:"pre",hypothesisId:"C",location:"src/services/httpClient.js:api:retry-auth",msg:"[DEBUG] API request got auth retry status",data:{path,status:response.status},ts:Date.now()})}).catch(()=>{});
      // #endregion
      clearWorkflowJwt();
      token = await ensureWorkflowJwt({ forceRefresh: true });
      response = await executeRequest(path, options, token);
    }
  } catch (err) {
    // #region debug-point C:api-catch
    fetch("http://127.0.0.1:7777/event",{method:"POST",body:JSON.stringify({sessionId:"metrics-auth-failure",runId:"pre",hypothesisId:"C",location:"src/services/httpClient.js:api:catch",msg:"[DEBUG] API request failed before response",data:{path,method:options?.method||'GET',message:err?.message||String(err||''),name:err?.name||'',safeForUser:err?.safeForUser,correlationId:err?.correlationId||''},ts:Date.now()})}).catch(()=>{});
    // #endregion
    logClientError(err, `API request failed before response: ${path}`);
    if (err?.message && String(err.message).toLowerCase().includes('login')) throw err;
    throw new DenialWorkflowError(GENERIC_WORKFLOW_ERROR);
  }

  if (!response.ok) {
    // #region debug-point C:api-non-ok
    fetch("http://127.0.0.1:7777/event",{method:"POST",body:JSON.stringify({sessionId:"metrics-auth-failure",runId:"pre",hypothesisId:"C",location:"src/services/httpClient.js:api:non-ok",msg:"[DEBUG] API response non-ok",data:{path,status:response.status,statusText:response.statusText},ts:Date.now()})}).catch(()=>{});
    // #endregion
    const error = await readError(response);
    logClientError(error instanceof Error ? error : new Error(String(error || `API error ${response.status}`)), `API ${response.status}: ${path}`);
    throw error instanceof Error ? error : new Error(error || `API error ${response.status}`);
  }

  if (response.status === 204) return null;

  const contentType = response.headers.get('content-type') || '';
  if (contentType.toLowerCase().includes('application/json')) return response.json();
  return response.text();
}

export async function apiUrl(path) {
  const token = await ensureWorkflowJwt();
  const response = await executeRequest(path, { headers: { Accept: '*/*' } }, token);

  if (!response.ok) {
    const error = await readError(response);
    throw error instanceof Error ? error : new Error(error || `API download error ${response.status}`);
  }

  const blob = await response.blob();
  return URL.createObjectURL(blob);
}

// Backward-compatible export names used by existing files.
export const apiFetch = api;
export { API_BASE_URL };

export function qs(obj = {}) {
  const params = new URLSearchParams();
  Object.entries(obj || {}).forEach(([key, value]) => {
    if (Array.isArray(value)) {
      const joined = value.filter(v => v !== undefined && v !== null && v !== '').join('¬');
      if (joined) params.append(key, joined);
      return;
    }
    if (value !== undefined && value !== null && value !== '') params.append(key, value);
  });
  return params.toString();
}
