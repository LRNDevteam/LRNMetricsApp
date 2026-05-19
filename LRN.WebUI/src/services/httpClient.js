import { REPORTS_API_BASE_URL } from '../config/apiConfig';
import { clearWorkflowJwt, ensureWorkflowJwt } from '../utils/auth';

const API_BASE_URL = REPORTS_API_BASE_URL;

function joinUrl(base, path) {
  const b = String(base || '').replace(/\/+$/, '');
  const p = String(path || '').replace(/^\/+/, '');
  return p ? `${b}/${p}` : b;
}

function appendWorkflowToken(url, token) {
  if (!token) return url;
  const separator = url.includes('?') ? '&' : '?';
  return `${url}${separator}__workflowToken=${encodeURIComponent(token)}`;
}

async function readError(response) {
  const contentType = response.headers.get('content-type') || '';
  if (contentType.toLowerCase().includes('application/json')) {
    const data = await response.json().catch(() => null);
    const reason = data?.reason ? ` ${data.reason}` : '';
    return data?.message ? `${data.message}${reason}` : data?.title || data?.error || JSON.stringify(data || {});
  }
  return (await response.text().catch(() => '')) || `${response.status} ${response.statusText}`;
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

  const url = appendWorkflowToken(joinUrl(API_BASE_URL, path), jwt);

  return fetch(url, {
    ...options,
    headers,
    credentials: 'include',
    cache: options.cache || 'no-store'
  });
}

export async function api(path, options = {}) {
  let token = await ensureWorkflowJwt();
  let response = await executeRequest(path, options, token);

  // Token expired/changed signature: refresh once only.
  if (response.status === 401 || response.status === 403) {
    clearWorkflowJwt();
    token = await ensureWorkflowJwt({ forceRefresh: true });
    response = await executeRequest(path, options, token);
  }

  if (!response.ok) {
    throw new Error((await readError(response)) || `API error ${response.status}`);
  }

  if (response.status === 204) return null;

  const contentType = response.headers.get('content-type') || '';
  if (contentType.toLowerCase().includes('application/json')) return response.json();
  return response.text();
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
