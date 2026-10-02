import { AR_WORKBENCH_API_BASE_URL } from '../config/apiConfig';
import { clearJwt, ensureJwt } from './auth';

export class ApiError extends Error {
  constructor(message, status = 0, correlationId = '') {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.correlationId = correlationId;
  }
}

function joinUrl(base, path) {
  return `${String(base).replace(/\/+$/, '')}/${String(path || '').replace(/^\/+/, '')}`;
}

export function qs(params = {}) {
  const search = new URLSearchParams();
  Object.entries(params).forEach(([key, value]) => {
    // false is sent: sortDesc=false must reach the API, whose default is true.
    if (value === undefined || value === null || value === '') return;
    // Lists repeat the key (?payer=A&payer=B), which ASP.NET binds to List<string>.
    if (Array.isArray(value)) { value.forEach((v) => { if (v !== '' && v != null) search.append(key, v); }); return; }
    search.append(key, value);
  });
  const text = search.toString();
  return text ? `?${text}` : '';
}

async function send(path, options, token) {
  const headers = new Headers(options.headers || {});
  headers.set('Accept', 'application/json');
  if (options.body && !(options.body instanceof FormData)) headers.set('Content-Type', 'application/json');
  if (token) {
    headers.set('Authorization', `Bearer ${token}`);
    headers.set('X-LRN-Workflow-Jwt', token);
  }
  return fetch(joinUrl(AR_WORKBENCH_API_BASE_URL, path), { ...options, headers, credentials: 'include', cache: 'no-store' });
}

async function toError(response) {
  const correlationId = response.headers.get('x-correlation-id') || '';
  let message = `${response.status} ${response.statusText}`;
  if ((response.headers.get('content-type') || '').includes('application/json')) {
    const data = await response.json().catch(() => null);
    if (data?.message) message = data.message;
    else if (data?.title) message = data.title;
  }
  if (response.status >= 500) {
    message = 'Something went wrong. Please contact admin support.' + (correlationId ? ` Error ID: ${correlationId}` : '');
  }
  return new ApiError(message, response.status, correlationId);
}

async function request(path, options) {
  let token = await ensureJwt();
  let response = await send(path, options, token);

  // Expired or rotated token: refresh once. A 403 from the workbench is a real "no access"
  // answer (lab or role), so it is not retried.
  if (response.status === 401) {
    clearJwt();
    token = await ensureJwt({ forceRefresh: true });
    response = await send(path, options, token);
  }

  if (!response.ok) throw await toError(response);
  return response;
}

export async function api(path, options = {}) {
  const response = await request(path, options);
  if (response.status === 204) return null;
  return (response.headers.get('content-type') || '').includes('application/json') ? response.json() : response.text();
}

// A file download (Excel export / template): the bearer token rules out a plain link, so fetch it
// and save the blob under the server's file name.
export async function downloadFile(path, fallbackName) {
  const response = await request(path, {});
  const disposition = response.headers.get('content-disposition') || '';
  const match = /filename\*=UTF-8''([^;]+)|filename="?([^";]+)"?/i.exec(disposition);
  const fileName = match ? decodeURIComponent(match[1] || match[2]) : fallbackName;
  const url = URL.createObjectURL(await response.blob());
  const a = document.createElement('a');
  a.href = url;
  a.download = fileName;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
