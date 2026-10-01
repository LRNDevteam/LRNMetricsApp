# LRN AR Workbench

The new denial application. It is a React app, built with Vite, React 19, React Router and Bootstrap 5. Its backend is `LRN.ReportsApi` (`/api/ar-workbench`), and its data is the `dbo.ARWB_*` tables in each lab database.

It replaces the old Denial Workflow React app (`LRN.WebUI`). LabMetricsDashboard's Denial Workflow menu link and post-login redirect (`DenialWorkflowReactUrl`) now open this app. The `dbo.Denial*` tables are unchanged.

The requirement is in `docs/Denial_WorkFlow/` (Build Reference, Developer Documentation, Open Items and Phases).

## Setup

1. **Database.** Run `LRNMaster_01_ARWB_Roles_Access.sql` once in LRNMaster. In each lab database, run `00_ARWB_Drop_Existing_Objects.sql` (removes the old `arwb` schema and all workbench data), then scripts 01 to 07 of `LRN.ReportsApi/Sql/ArWorkbench`. You can run `ARWB_Lab_Database_Setup_Merged.sql` instead of 01 to 07. Then run the first load:
   `EXEC dbo.ARWB_usp_LoadClaimsFromSource @RunBy = N'you';`
   See that folder's README.
2. **API.** `LRN.ReportsApi` needs no configuration beyond what it already has. It uses the same `LabConfig:LabsID` and lab connection strings as the Denial Workflow.
3. **App.**
   ```
   npm install
   npm run dev        # https://localhost:5174 (with a cert in .certs/) or http://
   npm run build      # dist/, deploy with: npm run publish:prod  (DEPLOY_DIR, default C:\inetpub\wwwroot\ARWorkbench)
   ```

### Local debugging

Login and the JWT come from LabMetricsDashboard (`/DenialWorkflow/AuthToken`). The dev server uses port **5174**, which LabMetricsDashboard's `appsettings.Development.json` already allows (`DenialWorkflowCors:AllowedOrigins`) and links to (`DenialWorkflowReactUrl`). LRN.ReportsApi already allows `localhost:5174` in Development. Ports are set in `.env.development`.

Run over HTTPS so the dashboard's `SameSite=None; Secure` login cookie reaches AuthToken. Export the trusted .NET dev certificate once (`.certs/` is git-ignored):

```
dotnet dev-certs https --export-path .certs/localhost.pem --format Pem --no-password
```

Start LabMetricsDashboard (IIS Express, https://localhost:44351) and LRN.ReportsApi (https://localhost:62408), then log in at the dashboard and open https://localhost:5174.

## Access

- **Lab:** the JWT `lab_id` claims, or the user's lab list. The token lists every lab for Super Admin (and Admin / LRN Admin), and only the assigned labs (`dbo.UserLabs`) for everyone else, Lab Admin included.
- **Site admins:** Super Admin (and Admin / LRN Admin) and Lab Admin open **every page** with every permission and the whole lab, in the labs above, with no AR Workbench role needed (`/me` returns `siteAdmin: true`).
- **Roles:** 8 new roles from the mockup, stored in LRNMaster `dbo.Roles` with an `AR Workbench - ` prefix: System Administrator, RCM Manager, Senior AR Analyst / Team Lead, AR Agent, QA Reviewer, Client Viewer, Clinic Viewer and Provider Viewer. Other LRN Metrics roles give **no** workbench access.
- **Users:** the existing `dbo.LabUsers`, `dbo.UserRoles` and `dbo.UserLabs` tables. There is no workbench user table.
- **Permissions:** `dbo.RoleFeatureAccess` keys `ARWorkbench.*`, managed in the existing role feature admin screen. The API works out the mockup role (`admin`, `manager`, `lead`, `agent`, `qa` or `viewer`) from them.
- **Clinic or provider:** `dbo.ARWB_UserScope` holds which clinic or provider a Clinic Viewer or Provider Viewer sees in each lab. If that isn't set, the user is refused rather than shown the whole lab.
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
| Data Processing | Runs `ARWB_usp_LoadClaimsFromSource`, with run history and counts |
| Master File Maintenance | Read-only view of every list and of Fix/Resolution by status |

The other routes are in `NAV` but show a "planned" page with their build phase. They are Assignment, My Work, Follow-Up, QA, Agent Requests, CIP, Client CIP, Analytics, Reports, Audit and Users. The tables they need already exist.
