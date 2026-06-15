# Summary

Update the local metrics/auth base URL from `https://localhost:57996` to `https://localhost:44350` so `AUTH_TOKEN_URL` resolves to `https://localhost:44350/DenialWorkflow/AuthToken` during local Vite development.

# Current State Analysis

- `src/config/apiConfig.js`
  - `normalizeLocalhostPorts()` currently keeps `57996` instead of rewriting it to `44350`.
  - `resolveMetricsBase()` local fallback still returns `https://localhost:57996`.
  - `AUTH_TOKEN_URL` is derived from `LRN_METRICS_BASE_URL`, so it currently points at the old port whenever env/storage/fallback resolve to `57996`.
- `.env.development`
  - `VITE_LRN_METRICS_BASE_URL` is currently set to `https://localhost:57996`.
- `src/utils/auth.js`
  - Uses `AUTH_TOKEN_URL` from `src/config/apiConfig.js`, so no direct URL edit is needed here.

# Proposed Changes

## `src/config/apiConfig.js`

- Update `normalizeLocalhostPorts()` so any local value using `localhost:57996` or `127.0.0.1:57996` is rewritten to `44350`.
- Update the local fallback in `resolveMetricsBase()` from `https://localhost:57996` to `https://localhost:44350`.
- Keep the current precedence order unchanged:
  - env vars
  - `window.__LRN_METRICS_BASE`
  - `localStorage`
  - `sessionStorage`
  - localhost fallback

Why:
- This ensures the app resolves the new auth host consistently, including when an old localhost value is still present in config or browser storage.

How:
- Replace the hardcoded `57996` targets in the normalization and fallback logic with `44350`.

## `.env.development`

- Change `VITE_LRN_METRICS_BASE_URL` from `https://localhost:57996` to `https://localhost:44350`.

Why:
- This makes the default local Vite configuration point to the updated MVC/auth host.

How:
- Update the single env entry and keep `VITE_REPORTS_API_BASE_URL` unchanged.

# Assumptions & Decisions

- Scope is limited to the local auth/metrics base URL; no backend CORS or MVC code changes are included in this plan.
- The desired final auth endpoint is exactly:
  - `https://localhost:44350/DenialWorkflow/AuthToken`
- Existing browser storage may still contain `lrn.metrics.base`; after implementation, restart Vite and hard-refresh the browser so the updated config is applied cleanly.

# Verification Steps

- Confirm `src/config/apiConfig.js` contains `44350` in:
  - localhost normalization
  - localhost fallback for metrics base
- Confirm `.env.development` contains:
  - `VITE_LRN_METRICS_BASE_URL=https://localhost:44350`
- Run diagnostics to ensure no syntax errors were introduced.
- Restart `npm run dev`.
- In the browser network tab, verify the AuthToken request goes to:
  - `https://localhost:44350/DenialWorkflow/AuthToken`
- If the browser still uses the old value, clear or overwrite `localStorage/sessionStorage` key `lrn.metrics.base` and reload.
