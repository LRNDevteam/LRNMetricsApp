# Switch Auth URL To 44351 Plan

## Summary
- Update the WebUI local authentication configuration so React uses `https://localhost:44351` for `AuthToken`, login, and logout while running locally.
- Keep the reports API base unchanged.
- Align local error messaging with the intended IIS Express auth endpoint so users are not told to switch back to `57996`.

## Current State Analysis
- `src/config/apiConfig.js` is currently incorrect for the requested setup:
  - `normalizeLocalhostPorts()` rewrites `44351` to `57996`.
  - `resolveMetricsBase()` falls back to `https://localhost:57996` on localhost.
- `.env.development` is already correct and points `VITE_LRN_METRICS_BASE_URL` to `https://localhost:44351`.
- `LabMetricsDashboard/Properties/launchSettings.json` shows:
  - project profile HTTPS URL: `https://localhost:57996`
  - `IIS Express` SSL port: `44351`
- `LabMetricsDashboard/Program.cs` already allows the Vite dev origin `https://localhost:5173` for local cross-origin cookie-based `AuthToken` calls.
- `src/utils/auth.js` still emits an auth failure hint that centers `57996`, which conflicts with the requested `44351` setup.

## Proposed Changes

### 1. Fix local metrics base resolution
- File: `src/config/apiConfig.js`
- What:
  - Reverse the localhost normalization so stale `57996` values are normalized to `44351`, not the other way around.
  - Change the localhost fallback from `https://localhost:57996` to `https://localhost:44351`.
- Why:
  - This file currently overrides the correct `.env.development` intent and causes `AUTH_TOKEN_URL` to resolve to the wrong local port.
- How:
  - Update both `localhost` and `127.0.0.1` rewrite rules in `normalizeLocalhostPorts()`.
  - Update the `resolveMetricsBase()` localhost fallback.

### 2. Align local auth error guidance with 44351
- File: `src/utils/auth.js`
- What:
  - Update the local `Cannot call AuthToken...` helper text so it treats `44351` as the preferred target for this setup.
  - Remove or soften the current guidance that pushes users toward `57996` when the requested environment is IIS Express on `44351`.
- Why:
  - The current runtime message is misleading after the config switch and can cause users to undo the intended setup.
- How:
  - Adjust the `metricsHint` branch and surrounding string content so the message matches the chosen local auth profile.

### 3. Preserve existing local env values
- File: `.env.development`
- What:
  - No content change expected unless verification shows drift.
- Why:
  - The current value is already `VITE_LRN_METRICS_BASE_URL=https://localhost:44351`.
- How:
  - Re-read during execution and only edit if it no longer matches the requested port.

### 4. No MVC CORS code change unless verification disproves current state
- Files reviewed:
  - `LabMetricsDashboard/Program.cs`
  - `LabMetricsDashboard/Properties/launchSettings.json`
- What:
  - No code changes planned in MVC by default.
- Why:
  - CORS for `https://localhost:5173` is already present, and `44351` already exists as the IIS Express SSL port.
- How:
  - Only revisit MVC if execution-time verification shows the app is not actually running on `44351`.

## Assumptions & Decisions
- Decision: `https://localhost:44351` is the desired local auth base, matching the user request and the `IIS Express` SSL port.
- Decision: `LabMetricsDashboard` should be launched with the `IIS Express` profile when using this WebUI configuration.
- Assumption: The reports API remains on `https://localhost:62408/api/denialworkflow` and is not part of this auth-port change.
- Assumption: Browser storage may still contain an old `lrn.metrics.base` value; execution should verify and document the reset step if needed.

## Verification Steps
- Confirm `src/config/apiConfig.js` contains only `44351` for local metrics base resolution.
- Confirm `.env.development` still contains `VITE_LRN_METRICS_BASE_URL=https://localhost:44351`.
- Check diagnostics for edited WebUI files.
- Restart the Vite dev server so the env/config changes are applied.
- Verify the browser requests `https://localhost:44351/DenialWorkflow/AuthToken`.
- If the UI still shows `57996`, clear the override with:

```js
localStorage.setItem('lrn.metrics.base', 'https://localhost:44351');
sessionStorage.removeItem('lrn.metrics.base');
location.reload();
```

- If `AuthToken` still fails after the URL is corrected, verify `LabMetricsDashboard` is running under the `IIS Express` profile on `https://localhost:44351`.
