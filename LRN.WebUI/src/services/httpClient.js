import { API_BASE } from '../config/apiConfig';
import { getJwt } from '../utils/auth';

export async function api(path, options = {}) {
  const token = getJwt();
  const response = await fetch(`${API_BASE}${path}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(options.headers || {})
    }
  });
  if (!response.ok) throw new Error(await response.text() || `API error ${response.status}`);
  return response.json();
}

export function qs(obj) {
  const p = new URLSearchParams();
  Object.entries(obj).forEach(([k, v]) => { if (v !== undefined && v !== null && v !== '') p.append(k, v); });
  return p.toString();
}
