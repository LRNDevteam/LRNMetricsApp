# AR Workbench — SQL scripts

Database objects for the AR Workbench, the new denial application (React app `LRN.ARWorkbench`, API `/api/ar-workbench` in `LRN.ReportsApi`). They implement the **AR Workbench Developer Handoff & Requirements v1.1**.

Every table, view, procedure and function is in `dbo` and named `ARWB_<Name>`. The old `arwb` schema is retired; script 00 removes it.

There are two sets of scripts:

- **LRNMaster, once per environment:** `LRNMaster_01` to `LRNMaster_03`.
- **Each lab database** (the one that holds `dbo.ClaimLevelData` and `dbo.LineLevelData`): scripts 00 to 09. The Denial Workflow tables (`dbo.DenialTaskBoard`, `dbo.DenialClaimNotes`, `dbo.DenialCodeMaster` and the rest) are not changed.

## Quick setup: two files

| Order | File | Run in |
|---|---|---|
| 1 | `ARWB_LRNMaster_Setup_Merged.sql` (LRNMaster_01, 02, 03) | LRNMaster, once per environment |
| 2 | `ARWB_Lab_Database_Setup_Merged.sql` (01–07 and 09) | each lab database |
| 3 | `EXEC dbo.ARWB_usp_LoadClaimsFromSource @RunBy = N'your.name';` (or Data Processing › Run) | each lab database |

Both are idempotent, so re-running them (for example after an update) is safe. They are **generated** by `Build-MergedScripts.ps1` from the numbered scripts: edit the numbered scripts, then run `.\Build-MergedScripts.ps1` in this folder. Left out of the merged files on purpose: `00` (destructive), `08` (optional index on a source table) and `RUN_InHealth_Initial_Setup.sql`.

## Data grain

- **Every claim** in the claim-level master file is synced, denied or not. There is no denial filter.
- **Every line** in the line-level file is synced for those claims, denied or not. Each line's denial codes are split into `ARWB_ClaimLineDenial`, one row per code, for the per-CPT expand in Claim Detail.
- The curated `ClaimLevelData.DenialCode` column decides whether a claim is denied and what its **primary denial** is (handoff 4.1). The first code written there is the primary. Line-level denials are for follow-up support only and do not drive queue placement.
- Lists, queues and counts are always claims, never lines.
- ClaimIDs that appear only in `LineLevelData` are not loaded. They are counted in `ARWB_RefreshRun.LineOnlyClaims`.

## Runbook: InHealth (first lab)

`RUN_InHealth_Initial_Setup.sql` runs everything below in order for LRNMaster and InHealth (`InHealthDTRLRN`, LabId 2), switching database per step, then shows verification queries. Open it in SSMS with **Query > SQLCMD Mode** on, check `ScriptDir` at the top, and execute. It stops at the first error. For the next lab, copy it and change `LabDb` and `LabId`; step 1 (LRNMaster) can stay, since it is idempotent.

## Run order

| # | Script | Database | What it does |
|---|---|---|---|
| M1 | `LRNMaster_01_ARWB_Roles_Access.sql` | LRNMaster | The 8 AR Workbench roles in `dbo.Roles`, their `ARWorkbench.*` grants in `dbo.RoleFeatureAccess`, and `dbo.ARWB_UserScope`. It moves rows out of the old `dbo.ARWorkbenchUserScope` and drops that table. |
| M2 | `LRNMaster_02_ARWB_DenialCodeMaster.sql` | LRNMaster | The central Denial Code Master (`dbo.ARWB_DenialCodeMaster`: description, action category, Denial Mapper attributes, non-collectible flag per code without its CO/PR/PI/OA prefix), seeded from `DenialCodes&Categorization_Master.xlsx`. |
| M3 | `LRNMaster_03_ARWB_ClientSetting.sql` | LRNMaster | Client (lab) activation for Client Management (`dbo.ARWB_ClientSetting` and its history). |
| 00 | `00_ARWB_Drop_Existing_Objects.sql` | lab | **Destructive.** Drops the legacy `arwb` schema and all its objects, plus any `dbo.ARWB_*` object, so 01–07 rebuild from clean. All workbench data is deleted. Source and Denial Workflow tables are not touched. |
| 01 | `01_ARWB_Tables.sql` | lab | All 32 `ARWB_` tables and their indexes |
| 02 | `02_ARWB_Functions.sql` | lab | Parsers for the `nvarchar` source columns, the denial-code normalizer and splitter, and the key-list parser |
| 03 | `03_ARWB_MasterData_Seed.sql` | lab | Queue taxonomy, master lists, workflow templates, TFL limits, settings, the starter denial-code map |
| 04 | `04_ARWB_ClaimState_Procedure.sql` | lab | `ARWB_usp_PriceClaimLines` (Revenue Expectation per line) and `ARWB_usp_RecalculateClaimState`, the one implementation of the lifecycle rules and queue precedence |
| 05 | `05_ARWB_LoadFromSource_Procedure.sql` | lab | `ARWB_usp_LoadClaimsFromSource`: the weekly sync, including the re-sync rules |
| 06 | `06_ARWB_Workflow_Procedures.sql` | lab | Denial insights, Process Automatic Adjustments, Mark as Posted, nightly queue snapshot |
| 07 | `07_ARWB_Views.sql` | lab | `ARWB_vw_ClaimWorklist`, `ARWB_vw_ClaimLineDetail`, `ARWB_vw_DenialInsight` |
| 08 | `08_ARWB_Optional_SourceIndex.sql` | lab | **Optional.** An index on `dbo.LineLevelData(ClaimID)`. This is the only script that touches a `dbo` source table, and it only adds an index. |
| 09 | `09_ARWB_Legacy_Cip_Conversion.sql` | lab | `ARWB_usp_ConvertLegacyEscalations`: converts the Denial Workflow's external escalations / Account Manager responses into CIP cases (run from CIP Escalations › Convert). Read-only on the Denial Workflow tables. |

`ARWB_Lab_Database_Setup_Merged.sql` is scripts 01 to 07 and 09 in one file, and `ARWB_LRNMaster_Setup_Merged.sql` is LRNMaster_01 to 03. Both are generated by `Build-MergedScripts.ps1`, so edit the numbered scripts and regenerate. Scripts 00 and 08 are deliberately left out.

Scripts 01 to 09 are idempotent. Script 03 only inserts rows that are missing, so a re-run keeps Master File Maintenance edits. The scripts need SQL Server 2016 SP1 or later and do not use `STRING_SPLIT`, `STRING_AGG` or `GREATEST`.

## First load and schedules

```sql
EXEC dbo.ARWB_usp_LoadClaimsFromSource @RunBy = N'your.name', @Note = N'Initial load';   -- weekly, after the master file refresh
EXEC dbo.ARWB_usp_SnapshotQueues;                                                          -- nightly: recalculates, then snapshots queues
EXEC dbo.ARWB_usp_LoadClaimsFromSource @ReprocessAll = 1;   -- after changing the denial map, NC / Auto-Adjust lists, ranking or fee schedule
```

## Denial code format (handoff 4.2)

`ARWB_tvf_NormalizeDenialCode` gives the form used for every mapping and lookup:

| Raw | Normalized | Group | Type |
|---|---|---|---|
| `PR 204`, `CO-204`, `CO204` | `204` | PR / CO | CARC |
| `N57`, `M127`, `MA130` | unchanged | — | RARC |

The raw value is kept (`PrimaryDenialCodeRaw`, `ARWB_ClaimLineDenial.DenialCodeRaw`) for display only. Master lists (`NON_COLLECTIBLE_CODE`, `AUTO_ADJUST_CODE`, `ARWB_DenialCodeCategoryMap`, `ARWB_DenialCodeRank`) hold normalized codes.

## Queue precedence (`ARWB_usp_RecalculateClaimState`, handoff 18.3)

First match wins:

1. Awaiting QA → `submittedqa`
2. QA Rejected → `qarejected`
3. Auto-adjusted or write-off approved, not yet posted, and the master still shows a balance → `autoadj` / `autoadj_system` or `autoadj_writeoff`
4. Completed with no insurance balance → the financial state (step 8)
5. Completed with an open CIP case → `escalation`
6. Completed with a new denial since it was worked → `refollowup` / `refollowup_newdenials`
7. Completed and re-follow-up due → `refollowup` / `refollowup_unresolved`; otherwise `completed`. A CIP case returned with a client reply, with the claim back in Assigned → `cipresponse`
8. Financial state, where Ins Bal is `RemainingAR`, which is 0 once nullified:
   - Ins Bal 0 and patient balance > 0 → `patientar` (denials ignored)
   - Ins Bal 0 and patient balance 0 → `closed_paid` if paid, else `closed_adjusted`
   - insurance payment > 0 → `partial_collectible` / `partial_noncollectible`
   - denial present → `denied_collectible` / `denied_noncollectible`
   - adjustment > 0 → `partialadj_collectible`
   - otherwise → `nonresponded_collectible`

Non-collectible means the **primary** code is on `NON_COLLECTIBLE_CODE`. `ARWB_ArQueue` flags each queue as `IsPriority` (needs agent work), `IsRestricted` (admin, manager and lead only: Closed, Patient AR, Non-Collectible) and `IsAutoRouted` (feeds the Work Queue).

## Financial fields (handoff 7)

| Field | Rule |
|---|---|
| `RevenueExpectation` | Sum of line `RevenueExpectation`, which is the `ARWB_CptFeeSchedule` rate × units. 0 when there is no rate; `IsRevenueRateMissing` flags it. |
| `PotentialRecovery` | Revenue Expectation − (insurance payment + patient payment + patient balance), floor 0 |
| `RecoveryStatus` | `No Recovery` (financially closed with nothing paid; interim definition), `In Progress` (all three 0), `Fully Recovered` (total ≥ Revenue Expectation), otherwise `Partially Recovered` |
| `RecoveredAmount` | Insurance payments on lines whose payment date (`CheckDate`, else `PostingDate`) is after the claim's denial date. For claims without a denial, it counts from the date the claim entered the workbench. |
| `RemainingAR` | Insurance balance, or 0 once auto-adjusted or write-off approved |

## Weekly re-sync rules (`ARWB_usp_LoadClaimsFromSource`, handoff 5)

| When the primary denial changes on a sync and the claim is… | What happens |
|---|---|
| Assigned, not yet worked, and the new code is Non-Collectible | Back to Unassigned, out of the agent's queue; the agent is notified |
| Assigned, not yet worked, other codes | Updated silently |
| Submitted for QA, QA Rejected or Completed | `NewDenialSinceWork = 1`. A Completed claim is unassigned now and shows in Re-Follow-Up – New Denials. One still in QA gets there once QA completes; **the API must clear the agent on that approval**. The manager is notified. |

In addition:

- An auto-adjusted or write-off-approved claim still open in the master is flagged `IsAdjustmentNotPosted` and returned to Auto Adjustments; the agent and the managers are notified. Once the master shows it posted, posting is confirmed automatically.
- Every change writes an `ARWB_ClaimActivity` row (System / ETL) with previous → new values.
- Workflow state (assignment, follow-ups, QA, CIP) is never overwritten, except by the rules above.
- All writes of one sync are a single transaction.

## Tables

| Area | Tables |
|---|---|
| Master data | `MasterListItem`, `DenialCodeCategoryMap`, `DenialCodeRank`, `DenialCategoryAction`, `FixResolutionByStatus`, `WorkflowTemplate`, `WorkflowTemplateStage`, `DenialCategoryTemplate`, `TflThreshold`, `CptFeeSchedule`, `ArQueue`, `AppSetting` |
| Claims | `RefreshRun`, `Claim`, `ClaimLine`, `ClaimLineDenial`, `ClaimFinancialHistory`, `ClaimActivity` |
| Work | `ClaimFollowUp`, `ClaimQaReview` (the database refuses self-approval), `AgentRequest` (reason category required), `AssignmentBatch`, `AssignmentBatchClaim`, `SavedView`, `Notification` |
| CIP | `CipCase` (created as `Awaiting QA`, released to `Pending Approval` by QA), `CipCaseHistory` |
| Documents | `Document` (Azure Blob metadata; the file is not in SQL), `DocumentAccessLog` |
| Insights and trends | `DenialInsight`, `DenialInsightClaim`, `QueueSnapshot` |

All of these carry the `ARWB_` prefix. `CipAttachment` (files in `varbinary`) is replaced by `ARWB_Document`.

## Users and roles

User management uses the existing LRNMaster tables: `dbo.LabUsers`, `dbo.UserLabs`, `dbo.UserRoles` → `dbo.Roles`, and `dbo.RoleFeatureAccess` (keys `ARWorkbench.*`). Only the 8 roles named `AR Workbench - …` grant access.

The one workbench table there is `dbo.ARWB_UserScope`. It holds the clinic or provider a Clinic Viewer or Provider Viewer sees, one row per user per lab. The value must match `ClaimLevelData.ClinicName` or `ReferringProvider` exactly, and a viewer with no row for a lab is refused.

| Role in `dbo.Roles` | Mockup role | Permissions |
|---|---|---|
| AR Workbench - System Administrator | admin | everything |
| AR Workbench - RCM Manager | manager | assign, work claims, QA, approve CIP, audit |
| AR Workbench - Senior AR Analyst / Team Lead | lead | assign, work claims, QA, **approve CIP** (session decision) |
| AR Workbench - AR Agent | agent | work own claims |
| AR Workbench - QA Reviewer | qa | QA decisions |
| AR Workbench - Client / Clinic / Provider Viewer | viewer | read only, scoped |

The API derives the mockup role from the permissions: ManageUsers → admin, Approve + ViewAudit → manager, Assign → lead, QaDecide → qa, EditClaim → agent, otherwise viewer.

## Open items reflected as settings or starter data

- **Starter lists:** `NON_COLLECTIBLE_CODE`, `AUTO_ADJUST_CODE`, `ESCALATION_REASON`, `REASSIGNMENT_REASON` and the denial-code → category map are starter data; the business owner is delivering the final lists.
- **Primary denial source:** `PrimaryDenialSource = CuratedColumn`. Switch it to `Ranking` once `ARWB_DenialCodeRank` holds the delivered hierarchy. `PrimaryDenialFallbackToLine = 0`.
- **Auto-adjust lists:** `AutoAdjustIncludesNonCollectible = 0`. Whether the Auto-Adjust and Non-Collectible lists are one list or two is still open.
- **Revenue Expectation:** the rate source is open; `ARWB_CptFeeSchedule` starts empty, so Revenue Expectation is 0 until it is loaded.
- **Aging basis:** `AgingBasis = DateOfService`; `DenialDate` is the alternative.
- **Follow-ups:** `NextFollowUpDefaultDays = 45`. Whether an agent may override the date is open.
- **Attachments:** `AttachmentMaxBytes` = 15 MB (10 vs 15 MB is open).
- **Priority:** High at a remaining AR of $500 or more, or TFL at risk; Medium at $100 or more. The rule is still open.
