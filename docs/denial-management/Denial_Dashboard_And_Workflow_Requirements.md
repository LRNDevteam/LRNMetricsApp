# Denial Dashboard & Denial Workflow — Requirements Specification

| Field | Detail |
|---|---|
| Document Title | Denial Dashboard & Denial Workflow — Requirements Specification |
| Project | Denial Management (LRN Metrics Denial Dashboard + LRN Denial Workflow) |
| Status | v1.0 — **as-built**, describing the system as it stands |
| Date | September 3, 2026 |
| Relationship to the baseline | `Denial_Dashboard_Workflow_Requirements_v2.0.pdf` remains the agreed **baseline spec** — what the system was commissioned to do. This document records what it **actually does today**, including behaviour added since Rev 2.0 (the Lab User role, feature-level access, demo labs, lab scoping). Where the two disagree, the PDF states the intent and this document states the current build. |
| Related | `Denial_Database_Worker_Requirements.md` (upstream data build), `Denial_Agentic_AI_Development_Plan.md`, `docs/demo-lab/DemoLab_Setup.md` |

## 1. Overview & Purpose

Denial management is delivered through **two separate screens on two separate stacks**, sharing one
database per lab. This is deliberate and is the single most important thing to understand before
reading the rest of this document.

| | Denial Dashboard | Denial Workflow |
|---|---|---|
| Stack | ASP.NET MVC (Razor) inside LabMetricsDashboard | React SPA (`LRN.WebUI`) |
| Route | `/DenialDashboard` | `DenialWorkflowReactUrl`, opened in a new tab |
| Data access | `SqlDenialRecordRepository` → lab DB | `LRN.ReportsApi` → `SqlDenialWorkflowRepository` → lab DB |
| Purpose | **Analysis.** What was denied, why, how much, and how it trends. | **Action.** Who is working each claim, what they did, and what happens next. |
| Audience | Managers and analysts reviewing denial performance | AR Reviewers and AR Managers working the queue |

Both read the same per-lab tables (`DenialTaskBoard`, `DenialLineItem`, `ClaimLevelData`), so figures
agree — but they answer different questions and have different permission models. A change to one does
**not** automatically apply to the other.

### 1.1 Scope

This document specifies the two screens as built: navigation, per-role visibility, the actions each
role may perform, and the access-control model behind them. It does not cover how denial data is
produced — that is `Denial_Database_Worker_Requirements.md`.

## 2. Roles & Permissions

Roles are held in `LRNMaster.dbo.Roles` and assigned per user in `dbo.UserRoles`. Role matching in
code is **normalised** — punctuation and case are stripped — so `AR Manager`, `ARManager` and
`AR-Manager` all resolve to the same role.

| Role | Denial Dashboard | Denial Workflow | Writes |
|---|---|---|---|
| Admin / LRN Admin | All tabs | All screens | All |
| AR Manager | Denial Insight, Task Board, Line Item | Manager queues, assignment, write-off approval, external escalation | Assign, update, escalate, verify |
| AR Reviewer / AR Analyst | Task Board, Line Item | My Worklist (own claims only) | Update own tasks, respond to escalation |
| Client Manager | Not applicable | Claim View (read-only) + Respond Escalation | Escalation responses only |
| Account Manager | Not applicable | Claim View (read-only) + Respond Escalation | Escalation responses only |
| Lab User | Not applicable | Claim View (read-only) | **None** |
| Everyone else | Dashboard, Weekly, Monthly, Filter Panel, Task Board, SLA Tracker, Denial Insight, Line Item | Per menu grant | Per role |

### 2.1 Read-only roles

Three roles are read-only, but not identically:

- **Client Manager / Account Manager** — read-only on the claim queues, but they are the *target* of
  external escalations, so they retain a "Respond Escalation" queue and may submit a response, add
  comments on Client-Info-Pending escalations, and upload supporting documents for claims escalated
  to their role.
- **Lab User** — the lab's own staff, watching their claims. Stricter: **no write path at all**, and
  no escalation queues, since they never act on one. Every write endpoint refuses the role outright
  (`IsLabUserRole` / `DenyWriteForLabUser`), and the UI hides the controls. Hiding the buttons is not
  the boundary — the API is.

Lab Users **may** export claim data. Exporting is reading; the restriction is on changing data.

### 2.2 AR Reviewer scoping

An AR Reviewer sees only claims assigned to them. Scope is applied server-side from the JWT
(`ScopeRowsForReviewer`), never from a query-string role — a reviewer cannot widen their own scope by
editing the request.

## 3. Access Control

Four independent mechanisms gate these screens. All four must pass.

### 3.1 Menu grant

Navigation is database-driven (`dbo.MenuItems` + `dbo.UserRoleMenu`, managed in **Admin → Menu
Master** and **Admin → Role Menu Mapping**). `MenuAccessFilter` enforces it server-side: a route that
belongs to the menu master but is not in the user's role menu returns Access Denied, so typing the URL
directly does not bypass the navbar.

Routes **not** in the menu master (AJAX endpoints, exports, partial loads) are never blocked.
Admins bypass menu enforcement entirely.

### 3.2 Feature grant

Screen elements that are not navbar items — the reimbursement chat icon in the header, the shortcut
inside the help bubble — are granted per role in `dbo.RoleFeatureAccess`, edited under **Other screen
access** on the Role Menu Mapping page. Three states:

| Setting | Behaviour |
|---|---|
| Default (no row) | Follows the role's menu access to the screen behind it |
| Enabled | Shown, and the screen it opens is granted |
| Disabled | Hidden regardless of menu access |

Across a user's roles, any role that enables a feature wins.

### 3.3 Lab assignment

A user sees only the labs assigned to them in **Admin → Assign User Labs** (`dbo.UserLabs`). Admins
see every lab, except labs listed in `LabConfig:DemoLabs`, which appear only for users explicitly
assigned them.

Lab scope reaches the React app through the JWT's `labs` claim, which becomes `lab_id` / `lab_name`
claims in the API. The API scopes from those claims, not from the request.

### 3.4 Lab registration

A lab must be registered in **both** LRNMaster registries or the screens fail in different ways:

| Table | Used by | Failure if missing |
|---|---|---|
| `dbo.Labs` | Canonical LabId across the application | Lab id mismatches between dashboard and API |
| `dbo.LRNMetricsLab` | Denial Dashboard + Denial Workflow lab resolution; carries `ConnectionKey` | API cannot open a connection for the lab — Claim Assignment renders empty |

The lab's own rows must carry the **same LabId** as the registration. Every claim-scoped query filters
`[LabId] = @LabId`; queries without that filter (task counts, SLA counts, balances, classification
rows) will still return data, so a LabId mismatch presents as a *half-populated* dashboard rather than
an empty one. See `docs/demo-lab/DemoLab_Setup.md` for a worked example.

Connection strings resolve in this order (`LabConnectionResolver`): `ConnectionStrings:Lab_{labId}` →
`{LabConfigFolder}\<LabName>.json` → `ConnectionKey` → known-name map → fuzzy scan. In practice the
per-lab JSON file supplies it, which is why a new lab needs no `ConnectionStrings` entry and no Key
Vault secret.

## 4. Denial Dashboard (MVC)

### 4.1 Global filters

A filter bar applies across tabs: date range, payer, denial code, classification, action category,
priority, status, clinic, sales rep, referring provider. Selections persist across tab switches.
Autocomplete options are served per lab by `GetFilterAutocompleteOptions`.

### 4.2 Tabs by role

Tab visibility is decided in the view from the user's role. Three sets:

| Role | Tabs |
|---|---|
| AR Reviewer (not manager) | Task Board, Line Item |
| AR Manager | Denial Insight, Task Board, Line Item |
| All other roles | Dashboard, Weekly Breakdown, Monthly Breakdown, Filter Panel, *Denial Input*, Task Board, SLA Tracker, Denial Insight, Line Item |

*Denial Input appears only when enabled for the lab.*

### 4.3 Tab requirements

| Tab | Purpose |
|---|---|
| **Dashboard** | KPI tiles and status/workflow summaries. Workflow Status Summary is sourced from what the Denial Workflow app writes, so users without access to that app can still see where work sits. |
| **Weekly / Monthly Breakdown** | Denial volume and balance pivoted by week / month. |
| **Filter Panel** | Insight panels — Task Status, Priority, and related breakdowns with claim counts, balance and rate bars. |
| **Denial Input** | The raw denial input rows for the current Run Id. Per-lab toggle. |
| **Task Board** | Task-level grid. Supports CSV download and CSV upload for bulk status updates. |
| **SLA Tracker** | Claims by SLA state, with breach counts. |
| **Denial Insight** | Denial-code/payer insight rows with reviewer assignment (AR Manager and Admin only). |
| **Line Item** | CPT line-level detail grid, paged and column-filterable via AJAX. |

### 4.4 Actions

| Action | Roles | Endpoint |
|---|---|---|
| Assign reviewers from Denial Insight | Admin, AR Manager | `AssignInsightReviewersOverall` |
| Update a reviewer task | Admin, AR Reviewer | `UpdateReviewerTask` |
| Bulk update reviewer tasks | Admin, AR Manager | `UpdateReviewerTasksOverall` |
| Export to Excel | Per lab access | `ExportToExcel` |
| Download / upload Task Board CSV | Admin, AR Manager, AR Reviewer | `DownloadTaskBoardCsv` / `UploadTaskBoardCsv` |

All state-changing actions are `POST` with antiforgery validation.

### 4.5 Presentation

- All tables share one visual language: navy sticky header, white body with a faint zebra, visible
  hover, and Excel-style grid lines.
- Numeric columns are right-aligned with tabular figures so digits align vertically.
- Currency is normal ink. Red is reserved for genuine exceptions, not for every balance.
- Wide tables scroll horizontally inside their own frame; the page body never scrolls sideways.

## 5. Denial Workflow (React)

### 5.1 Navigation

| Screen | Available to |
|---|---|
| Denial Dashboard (role-specific) | All |
| Aging Dashboard | All |
| Claim View / Claim Assignment | Admin, AR Manager, Client Manager, Account Manager, Lab User |
| My Worklist | AR Reviewer, Admin |
| Escalation Queue | Read-only roles other than external managers and Lab User |
| Denial Mapper | Admin, AR Manager, Client/Account Manager, Lab User, Viewer |
| Denial Action Master / Action Code Verification | AR Manager, Admin |
| Reports, Uploads & Downloads, Contact Support | All |
| Admin Setup | Admin |

The nav label changes with permission: **Claim Assignment** for roles that can assign, **Claim View**
for those that cannot.

Deep links are validated against the role. A reviewer linking to `#claims` lands on My Worklist; a Lab
User linking to `#myworklist`, `#escalations` or `#verification` lands on Claim View. A redirect always
surfaces a message rather than silently swapping the page.

### 5.2 Queues by role

| Role | Queues |
|---|---|
| AR Reviewer | Worklist, SLA in 3 Days, Follow-ups Due, Payer Follow-up Required, Pending Documentation, Pending Payer Response, Escalated Claims, Escalation Response, Closed, All Claims |
| AR Manager | New, Unassigned, SLA At Risk, Assigned, Payer Follow-up Required, Pending Documentation, Pending Payer Response, Internal Escalation, External Escalation, External Response, Write Off Approval, Closed, All Claims |
| Client / Account Manager | New, Unassigned, Assigned, Respond Escalation, Closed, All Claims |
| Lab User | New, Unassigned, Assigned, Closed, All Claims |

The AR Manager has no "Escalation Response" queue: a responded internal escalation returns to the
manager's **Assigned** queue, while the reviewer sees it under **Escalation Response**. The manager's
response tab is **External Response**, holding Client/Account Manager responses only.

### 5.3 Claim lifecycle

Canonical line statuses: New, Unassigned, Assigned, Payer Follow-up Required, Pending Payer Response,
Pending Documentation, Write-Off Pending Approval, Escalated to AR Manager, External Escalation,
Rework, Closed.

A claim sits in exactly one queue at a time; queue counts are the same values behind the sidebar
badges. AR Analysts may only select from a restricted status set.

### 5.4 Write permissions

| Action | Allowed roles |
|---|---|
| Assign claims / assign by insight | Admin, AR Manager |
| Update task status | Admin, AR Manager, AR Reviewer |
| Add comments / notes | All except Lab User; Client Manager limited to Client-Info-Pending escalations |
| Upload / delete claim documents | All except Lab User; external managers limited to claims escalated to their role |
| Submit / update escalation | Admin, AR Manager, AR Reviewer |
| Respond to escalation | Admin, AR Manager, Client Manager, Account Manager |
| External escalation | Admin, AR Manager |
| Verification decision | All except Lab User |
| CSV upload | Admin, AR Manager, AR Reviewer |
| Export / download | Admin, AR Manager, AR Reviewer, Client Manager, Account Manager, Lab User |

### 5.5 Validation

Status changes enforce field requirements:

| Status | Required |
|---|---|
| Payer Follow-up Required | Follow-up reason, expected response date |
| Pending Payer Response | Expected response date, action completed confirmed |
| Pending Documentation | Documentation type, expected response date |
| Write-Off Pending Approval | Actual outcome |

## 6. Authentication & Session

The React app is not separately authenticated. It calls `/DenialWorkflow/AuthToken` on the dashboard,
which issues a short-lived HS256 JWT carrying user name, display name, roles and assigned labs. The API
validates that token and derives **all** scoping from it.

`/DenialWorkflow/Logout` clears the dashboard session and returns to login. Both endpoints are outside
menu enforcement so the React app keeps working regardless of menu configuration.

## 7. Non-Functional Requirements

| Area | Requirement |
|---|---|
| Menu cache | 30 minutes; 1 minute when the API is unreachable. Invalidated on any Menu Master / Role Menu Mapping save. |
| Fail-open | If the menu or feature API is unavailable, access checks allow the request and log a warning. Availability must not take the application down. |
| Fail-closed | Lab scoping is the exception: a user with no lab assignments sees **no** data, never all data. |
| Lab connections | Resolved once at API startup and cached. Registering a lab requires an API restart. |
| Export ceiling | 1,048,575 rows (Excel sheet limit). Long exports run through the report queue rather than in-request. |
| Uploads | 100 MB per request, 10 files per upload, 25 MB per document. |
| Audit | Every task update, assignment, escalation and verification writes to `DenialTaskHistory` with the acting user. |

## 8. Known Gaps

1. **The MVC Denial Dashboard has no view-only mode.** Its Tasks and Verification tabs render edit
   controls for every role; only the POST handlers refuse. Lab Users are redirected away from the page
   rather than shown a read-only version.
2. **`decide-verification` has no role guard** beyond the Lab User refusal — any other authenticated
   token may post a verification decision. Restricting it to Admin / AR Manager / AR Reviewer is a
   one-line change that has not been made because it would alter existing behaviour.
3. **Free-text fields are not classified.** Reviewer comments, note text and escalation comments accept
   anything typed, including identifiers. This matters when cloning a lab for demo use.
4. **Two lab registries** (`dbo.Labs`, `dbo.LRNMetricsLab`) must be kept in step by hand. There is no
   constraint or job reconciling them.
5. **Lab-name spelling drifts between tables** (`PCR Labs of America` vs `PCRLabsofAmerica` vs
   `PCR_Labs_Of_America`). Matching is normalised in code, but the underlying data is inconsistent.
