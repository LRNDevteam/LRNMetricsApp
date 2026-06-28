import { REPORTS_API_BASE_URL } from '../config/apiConfig';
import { getJwt } from '../utils/auth';

let installed = false;

function send(payload) {
  try {
    const token = getJwt();
    fetch(`${REPORTS_API_BASE_URL}/client-logs`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}`, 'X-LRN-Workflow-Jwt': token } : {})
      },
      credentials: 'include',
      keepalive: true,
      body: JSON.stringify({
        level: payload.level || 'Error',
        message: String(payload.message || 'Unknown React error').slice(0, 4000),
        stack: String(payload.stack || '').slice(0, 12000),
        context: String(payload.context || '').slice(0, 2000),
        url: window.location.href,
        userAgent: navigator.userAgent
      })
    }).catch(() => {});
  } catch { }
}

export function logClientError(error, context = '') {
  send({ level: 'Error', message: error?.message || error, stack: error?.stack || '', context });
}

export function installClientLogging() {
  if (installed) return;
  installed = true;
  window.addEventListener('error', event => logClientError(event.error || event.message, 'window.error'));
  window.addEventListener('unhandledrejection', event => logClientError(event.reason, 'unhandledrejection'));
}
