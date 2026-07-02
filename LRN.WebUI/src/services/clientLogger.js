import { REPORTS_API_BASE_URL } from '../config/apiConfig';
import { getJwt } from '../utils/auth';

let installed = false;

// Dev-tooling noise (e.g. Vite's HMR client losing its WebSocket) is not an application error and
// floods this logger with dozens of identical reports per minute if left unfiltered.
const IGNORED_MESSAGE_PATTERNS = [/WebSocket closed without opened/i];

// Dedup + rate-limit: the same underlying failure (a dropped websocket, a recurring render error)
// can fire the global error/unhandledrejection handlers many times in a row. Without this, each
// occurrence was an independent network call to /client-logs, which piled up requests fast enough
// to be mistaken for the cause of a slow/hanging page rather than a symptom of one.
const RECENT_MESSAGE_WINDOW_MS = 10_000;
const MAX_LOGS_PER_MINUTE = 10;
const recentMessages = new Map();
let windowStart = Date.now();
let windowCount = 0;

function shouldSend(message) {
  if (IGNORED_MESSAGE_PATTERNS.some(pattern => pattern.test(message))) return false;

  const now = Date.now();
  if (now - windowStart > 60_000) { windowStart = now; windowCount = 0; }
  if (windowCount >= MAX_LOGS_PER_MINUTE) return false;

  const lastSeen = recentMessages.get(message);
  if (lastSeen && now - lastSeen < RECENT_MESSAGE_WINDOW_MS) return false;
  recentMessages.set(message, now);
  windowCount += 1;
  return true;
}

function send(payload) {
  try {
    const message = String(payload.message || 'Unknown React error').slice(0, 4000);
    if (!shouldSend(message)) return;

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
        message,
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
