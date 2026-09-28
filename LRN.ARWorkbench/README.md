# LRN AR Workbench

The new denial application. It is a React app, built with Vite, React 19, React Router and Bootstrap 5. Its backend is `LRN.ReportsApi` (`/api/ar-workbench`), and its data is the `arwb` schema in each lab database.

The Denial Workflow app (`LRN.WebUI`) and its `dbo.Denial*` tables are unchanged. The two apps run side by side.

The requirement is in `docs/Denial_WorkFlow/` (Build Reference, Developer Documentation, Open Items and Phases).

## Setup

1. **Database.** Run `LRNMaster_01_ArWorkbench_Roles_Access.sql` once in LRNMaster. Then run `LRN.ReportsApi/Sql/ArWorkbench` scripts 01 to 06 in each lab database. You can run `ArWorkbench_Lab_Database_Setup_Merged.sql` instead. Then run the first load:
   `EXEC arwb.usp_LoadClaimsFromSource @RunBy = N'you';`
   See that folder's README.
2. **API.** `LRN.ReportsApi` needs no configuration beyond what it already has. It uses the same `LabConfig:LabsID` and lab connection strings as the Denial Workflow.
3. **App.**
   ```
   npm install
   npm run dev        # https://localhost:5174 (with a cert in .certs/) or http://
   npm run build      # dist/, deploy with: npm run publish:prod  (DEPLOY_DIR, default C:\inetpub\wwwroot\ARWorkbench)
   ```

### Local debugging

Login and the JWT come from LabMetricsDashboard (`/DenialWorkflow/AuthToken`), the same way as for `LRN.WebUI`. The dev server uses port **5174**, so both apps can run at once. Add that origin to LabMetricsDashboard's `appsettings.Development.json`:

```json
"DenialWorkflowCors": { "AllowedOrigins": [ "https://localhost:5173", "https://localhost:5174" ] }
```

LRN.ReportsApi already allows `localhost:5174` in Development. Ports are set in `.env.development`.

## Access

- **Lab:** the JWT `lab_id` claims, or the user's lab list. Site admins can open every lab.
- **Roles:** 8 new roles from the mockup, stored in LRNMaster `dbo.Roles` with an `AR Workbench - ` prefix: System Administrator, RCM Manager, Senior AR Analyst / Team Lead, AR Agent, QA Reviewer, Client Viewer, Clinic Viewer and Provider Viewer. Existing LRN Metrics roles, including site Admin, give **no** workbench access.
- **Users:** the existing `dbo.LabUsers`, `dbo.UserRoles` and `dbo.UserLabs` tables. There is no workbench user table.
- **Permissions:** `dbo.RoleFeatureAccess` keys `ARWorkbench.*`, managed in the existing role feature admin screen. The API works out the mockup role (`admin`, `manager`, `lead`, `agent`, `qa` or `viewer`) from them.
- **Clinic or provider:** `dbo.ARWorkbenchUserScope` holds which clinic or provider a Clinic Viewer or Provider Viewer sees in each lab. If that isn't set, the user is refused rather than shown the whole lab.
- A user with no AR Workbench role gets a 403.
- The API applies scope in SQL on every claim query: clinic, provider, and the agent's own caseload. The UI never filters for security.

## Structure

```
src/
  config/navigation.js      NAV: one list drives the sidebar AND the route guard
  context/WorkbenchContext   labs, selected lab, /me (role, permissions, scope), master data, can(perm)
  services/                  auth (MVC AuthToken -> in-memory JWT), httpClient, arWorkbenchService (one fn per endpoint)
  components/AppShell        sidebar, lab picker, scope badge, nav count badges
  components/DataTable       shared table: server sort + paging, column show/hide, CSV of what is on screen
  pages/                     Dashboard, WorkQueue, ClaimDetail, DataProcessing, MasterData, Planned
```

A new screen has four parts: an entry in `NAV`, a page in `pages/`, an entry in `SCREENS` in `App.jsx`, and endpoint functions in `arWorkbenchService.js`.

## Built in this base

| Screen | Status |
|---|---|
| Dashboard | KPIs (denied claims, initial AR, recovered, remaining AR), the 12-queue tree with counts and remaining AR, and drill-through |
| Work Queue | Queue, sub-queue, status, category and search filters kept in the URL, server paging and sorting, column visibility, CSV |
| Claim workspace | Header badges, a 4-stage stepper, the named stage path for the category, and tabs: Overview (recovery), CPT/Line Detail, Denial Info, Follow-Ups, Activity Timeline |
| Data Processing | Runs `usp_LoadClaimsFromSource`, with run history and counts |
| Master File Maintenance | Read-only view of every list and of Fix/Resolution by status |

The other routes are in `NAV` but show a "planned" page with their build phase. They are Assignment, My Work, Follow-Up, QA, Agent Requests, CIP, Client CIP, Analytics, Reports, Audit and Users. The tables they need already exist.
