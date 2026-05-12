export function getJwt() {
  const keys = ['lrn.jwt', 'lrnMetrics.jwt', 'access_token', 'jwtToken', 'token', 'authToken'];
  for (const k of keys) { const v = localStorage.getItem(k) || sessionStorage.getItem(k); if (v) return v.replace(/^Bearer\s+/i, ''); }
  return '';
}
export function parseJwt(token) {
  try { const payload = token.split('.')[1]; return JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/'))); } catch { return {}; }
}
export function claimRole(claims) { const r = claims.role || claims.roles || claims['http://schemas.microsoft.com/ws/2008/06/identity/claims/role']; return Array.isArray(r) ? r[0] : (r || 'AR Manager'); }
export function claimUser(claims) { return claims.name || claims.preferred_username || claims.unique_name || claims.upn || claims.email || claims['http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name'] || ''; }
