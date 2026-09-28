# AR Workbench — SQL scripts

Database objects for the AR Workbench, the new denial application (React app `LRN.ARWorkbench`, API `/api/ar-workbench` in `LRN.ReportsApi`).

There are two sets of scripts:

- **LRNMaster, once per environment:** `LRNMaster_01_ArWorkbench_Roles_Access.sql`. User management uses the existing LRNMaster tables (see [Users and roles](#users-and-roles)).
- **Each lab database** (the one that holds `dbo.ClaimLevelData` and `dbo.LineLevelData`): scripts 01 to 07. Every object lives in a new `arwb` schema. The Denial Workflow tables (`dbo.DenialTaskBoard`, `dbo.DenialClaimNotes`, `dbo.DenialCodeMaster` and the rest) are not changed.

## Run order

| # | Script | Database | What it does |
|---|---|---|---|
| M1 | `LRNMaster_01_ArWorkbench_Roles_Access.sql` | LRNMaster | Creates the 8 AR Workbench roles in `dbo.Roles`, grants their `ARWorkbench.*` permissions in `dbo.RoleFeatureAccess`, and creates `dbo.ARWorkbenchUserScope` |
| 01 | `01_ArWorkbench_Schema_Tables.sql` | lab | `arwb` schema, all 23 tables, indexes |
| 02 | `02_ArWorkbench_Functions.sql` | lab | Parsers for the `nvarchar` source columns (money, dates, text) |
| 03 | `03_ArWorkbench_MasterData_Seed.sql` | lab | Queue taxonomy, master lists, workflow templates, TFL limits, settings, a starter denial-code map |
| 04 | `04_ArWorkbench_ClaimState_Procedure.sql` | lab | `arwb.usp_RecalculateClaimState`: the one implementation of the lifecycle rules and the 12-queue classification |
| 05 | `05_ArWorkbench_LoadFromSource_Procedure.sql` | lab | `arwb.usp_LoadClaimsFromSource`: the Data Processing refresh |
| 06 | `06_ArWorkbench_Views.sql` | lab | `arwb.vw_ClaimWorklist`, the read shape the API uses |
| 07 | `07_ArWorkbench_Optional_SourceIndex.sql` | lab | **Optional.** Adds an index on `dbo.LineLevelData(ClaimID)`. This is the only lab script that touches a `dbo` table, and it only adds an index. |

`ArWorkbench_Lab_Database_Setup_Merged.sql` is scripts 01 to 06 in one file. It is generated from the numbered scripts, so edit those and regenerate the merged file.

Every script is idempotent, so you can run it again. Script 03 only inserts rows that are missing, so running it again does not overwrite changes made in Master File Maintenance.

The scripts need SQL Server 2016 SP1 or later. They do not use `STRING_SPLIT`, `STRING_AGG` or `GREATEST`, and were tested at compatibility level 130.

## First load

```sql
EXEC arwb.usp_LoadClaimsFromSource @RunBy = N'your.name', @Note = N'Initial load';
```

## Users and roles

The AR Workbench starts fresh with **8 roles of its own**, taken from the mockup's sign-in roster. It does **not** use any existing LRN Metrics role (Admin, AR Manager, AR Reviewer, Client Manager and so on). Those roles have no workbench permissions, and the API reads only roles whose name starts with `AR Workbench - `. That includes the site Admin role: it gets no special access to the workbench.

The roles live in the existing LRNMaster user tables, so users are set up in the existing user admin screens:

| What | Where |
|---|---|
| The user | `dbo.LabUsers`, matched on `UserName` or `Email` against the JWT name |
| Labs they can open | `dbo.UserLabs` |
| Their AR Workbench role | `dbo.UserRoles` → one of the 8 roles below in `dbo.Roles` |
| What each role may do | `dbo.RoleFeatureAccess`, keys `ARWorkbench.*`. These appear in the existing role feature admin screen. |
| The clinic or provider a Clinic Viewer or Provider Viewer sees | `dbo.ARWorkbenchUserScope`, the one new table, with one row per user per lab |

| Role in `dbo.Roles` | Mockup role | Permissions | Sees |
|---|---|---|---|
| AR Workbench - System Administrator | admin | everything | whole lab |
| AR Workbench - RCM Manager | manager | assign, work claims, QA, approvals, audit | whole lab |
| AR Workbench - Senior AR Analyst / Team Lead | lead | assign, work claims, QA | whole lab |
| AR Workbench - AR Agent | agent | work claims | own assigned claims only |
| AR Workbench - QA Reviewer | qa | QA decisions | whole lab |
| AR Workbench - Client Viewer | viewer | read only | whole lab (client) |
| AR Workbench - Clinic Viewer | viewer | read only | one clinic |
| AR Workbench - Provider Viewer | viewer | read only | one referring provider |

The `AR Workbench - ` prefix keeps these apart from other applications' roles in the shared `dbo.Roles` table. The workbench screens show the names without it.

A user with more than one AR Workbench role gets every permission those roles grant. The mockup role is worked out from those permissions, highest first:

- Manage users → admin
- Approve → manager
- Assign → lead
- QA → qa
- Work claims → agent
- Otherwise → viewer

The widest scope also wins: any role that isn't limited to a clinic or provider gives the whole lab. A user with no AR Workbench role gets a 403.

To set up a Clinic Viewer in a lab:

```sql
-- 1. Give the role (or use the existing user admin screen)
INSERT INTO dbo.UserRoles (LabUserID, RoleID)
SELECT u.LabUserID, r.RoleID FROM dbo.LabUsers u, dbo.Roles r
WHERE u.UserName = N'renee.k' AND r.RoleName = N'AR Workbench - Clinic Viewer';

-- 2. Say which clinic, per lab (must match ClaimLevelData.ClinicName exactly)
INSERT INTO dbo.ARWorkbenchUserScope (LabUserID, LabId, ClinicName, CreatedBy)
SELECT LabUserID, 13, N'Northgate Orthopedic Associates', N'admin' FROM dbo.LabUsers WHERE UserName = N'renee.k';
```

A Provider Viewer works the same way, using `ProviderName` (which must match `ClaimLevelData.ReferringProvider`). A Clinic or Provider Viewer with no row for a lab is refused in that lab. They are never shown the whole lab by default.
Columns that record a user in the lab tables (`AssignedAgentUser`, `CreatedBy`, `ReviewedBy` and so on) hold `dbo.LabUsers.UserName`.

## How data gets in

`usp_LoadClaimsFromSource` does the following:

1. It takes the latest `ClaimLevelData` row for each `ClaimID`, and keeps only claims whose `DenialCode` is not null or blank.
2. A claim that is already in the workbench keeps refreshing even after the source clears its denial code. Without this, a denial the payer later pays would drop out instead of showing as recovered.
3. It inserts new claims and freezes their `Initial*` financials. It updates changed claims (detected by a hash of the source columns). For unchanged claims it only records the run.
4. It never overwrites workflow state: assignment, follow-ups, QA and CIP.
5. It keeps claims that are no longer in the feed, with `IsInCurrentSource = 0`.
6. It writes `arwb.ClaimFinancialHistory` for new and changed claims. Recovered amount is read against this history.
7. It writes a system `ClaimActivity` row: "Claim Identified" for new claims and "Source Data Updated" for changed ones. Because every claim has at least one row, "days since last touch" works for claims nobody has touched.
8. It loads CPT lines from `LineLevelData`, using only the latest line file per claim. It reloads lines only for claims whose line set changed.
9. It fills `DenialReason` from the lab's existing `dbo.DenialCodeMaster` when that table exists (read-only).
10. It runs `usp_RecalculateClaimState` for every claim.

Only one refresh runs at a time per lab (`sp_getapplock`). A refresh is refused if `ClaimLevelData` is empty, because otherwise a load caught mid-import would mark every claim as removed.

## Derived rules (`usp_RecalculateClaimState`)

| Field | Rule |
|---|---|
| `RemainingAR` | `InsuranceBalance`, or 0 once written off |
| `RecoveredAmount` | Insurance payment now minus insurance payment at first identification (never below 0) |
| `IsFinanciallyClosed` | `RemainingAR` and `PatientBalance` both at or below 0.005 |
| `IsWorkComplete` | Financially closed, or `WorkflowStatus = 'Completed'` |
| `IsOpenInsuranceAR` | `RemainingAR` above 0.005. This is **not** the opposite of `IsWorkComplete`. |
| `IsRefollowupDue` | Worked before, and either 45+ days since the last follow-up or the next follow-up date has passed |
| `IsNonCollectible` | Any of the claim's codes is on the `NON_COLLECTIBLE_CODE` list |
| `ArQueueId` / `ArSubQueueId` | Priority order: Awaiting QA → QA Rejected → Completed (financial state / CIP pending / re-follow-up / completed) → CIP response received → financial state |

Call it after any claim change the API makes (`@ClaimKey`), and nightly with no arguments so aging, TFL and re-follow-up move forward with the calendar.

Thresholds are stored in `arwb.AppSetting`: 45 untouched days, 45 re-follow-up days, a 0.005 balance epsilon, the TFL window, and the priority amounts.

## Tables

| Area | Tables |
|---|---|
| Security | None in the lab database. See [Users and roles](#users-and-roles). |
| Master data | `MasterListItem`, `DenialCodeCategoryMap`, `FixResolutionByStatus`, `WorkflowTemplate`, `WorkflowTemplateStage`, `DenialCategoryTemplate`, `TflThreshold`, `ArQueue`, `AppSetting` |
| Claims | `RefreshRun`, `Claim`, `ClaimLine`, `ClaimFinancialHistory`, `ClaimActivity` |
| Work | `ClaimFollowUp`, `ClaimQaReview` (the database refuses self-approval), `AgentRequest`, `AssignmentBatch`, `AssignmentBatchClaim`, `SavedView` |
| CIP | `CipCase`, `CipCaseHistory`, `CipAttachment` |

## Decisions to review before go-live

- **Starter denial-code map.** Script 03 maps common CARC codes to the 11 denial categories. Operations should review it. Codes that are not mapped go to `Other`.
- **Expected payment** is `AllowedAmount`. Underpayment is allowed minus insurance paid, and only counts once the payer has paid something.
- **Priority**: High when Remaining AR is at least $500 or TFL is at risk, Medium when at least $100, otherwise Low. `PriorityOverride` wins over the calculated value.
- **TFL deadline** is date of service plus the limit for the financial class. The limit is matched on `ClaimLevelData.PayerType`, with 180 days as the default.
- **CIP attachment limit** is 5 MB per file, 3 files. The 250 KB limit in the demo was a browser-storage limit.
- **Client-level access** covers the whole lab, because each lab database is one client, and `dbo.UserLabs` already controls it. The Client Viewer role sees the whole lab. Clinic access matches `ClinicName` and provider access matches `ReferringProvider`.
- **Roles are a fresh start:** only the 8 `AR Workbench - ` roles grant access. Existing users need one of them assigned before they can open the workbench, and that includes site admins.
