# Denial SQL Script Inventory

This folder now has two clean deployment entry points:

- `Denial_Master_Database_Setup_Merged.sql`: run once in `LRNMaster` / the Reports API `DefaultConnection` database.
- `Denial_Lab_Database_Setup_Merged.sql`: run in each lab/customer database.

The original scripts are retained as migration history and as source sections for the merged files.

| File | Classification | Merged Into | Notes |
| --- | --- | --- | --- |
| `DenialMapper_Setup.sql` | Master database | `Denial_Master_Database_Setup_Merged.sql` | Creates mapper super-master and mapper audit log used by `DenialMapperService` via the default connection. |
| `DenialMapper_PushAudit_Setup.sql` | Master database | `Denial_Master_Database_Setup_Merged.sql` | Creates push audit tables used for cross-lab mapper notifications and confirmations. |
| `DenialWorkflow_Setup.sql` | Lab database | `Denial_Lab_Database_Setup_Merged.sql` | Base workflow lookup/history/verification objects and task-board compatibility columns. |
| `DenialTaskBoard_Update.sql` | Lab database | `Denial_Lab_Database_Setup_Merged.sql` | Normalized claim id and core claim-view lookup indexes. |
| `DenialCodeMaster_CreateTable_Indexes.sql` | Lab database | `Denial_Lab_Database_Setup_Merged.sql` | `SqlDenialCodeMasterRepository` opens the selected lab connection, so this belongs in each lab database. |
| `DenialWorkflow_ClaimNotes_Documents.sql` | Lab database | `Denial_Lab_Database_Setup_Merged.sql` | Claim notes and document metadata tables. |
| `DenialWorkflow_MyWorklist_Escalations.sql` | Lab database | `Denial_Lab_Database_Setup_Merged.sql` | Base escalation history table. |
| `DenialClosedClaimsHistory_Setup.sql` | Lab database | `Denial_Lab_Database_Setup_Merged.sql` | Closed claim display and closed claim audit tables. |
| `DenialWorkflow_StatusModel_ManagerReview_20260604.sql` | Lab database | `Denial_Lab_Database_Setup_Merged.sql` | Manager review status columns, status backfill, and status indexes. |
| `DenialWorkflow_Performance_And_Verification_Columns.sql` | Lab database | `Denial_Lab_Database_Setup_Merged.sql` | Verification compatibility columns and earlier workflow indexes. |
| `DenialCodeActionChangeVerification_Setup.sql` | Lab database | `Denial_Lab_Database_Setup_Merged.sql` | Action-change verification batch tables and recount procedure. |
| `DenialMapper_Lab_Setup.sql` | Lab database | `Denial_Lab_Database_Setup_Merged.sql` | Lab copy/override tables for mapper pushes. |
| `DenialWorkflow_ClaimUID_ClaimView_Optimization.sql` | Lab database | `Denial_Lab_Database_Setup_Merged.sql` | ClaimUID-aware claim assignment/view performance indexes. |
| `DenialWorkflow_AllTables_Performance_Indexes.sql` | Lab database | `Denial_Lab_Database_Setup_Merged.sql` | Canonical broad performance index pack for workflow tables. |
| `DenialWorkflow_ClaimStatus_Precedence_RoleFilters.sql` | Lab database | `Denial_Lab_Database_Setup_Merged.sql` | Additive indexes for queue/status precedence and role filters. |
| `DenialWorkflow_Modern_UI_Index_Verification.sql` | Lab database | `Denial_Lab_Database_Setup_Merged.sql` | Additive modern UI indexes not fully covered by older setup scripts. |
| `DenialWorkflow_400k_Performance_Indexes.sql` | Superseded lab performance patch | Not merged | Earlier focused index pack. Covered by the broader all-table and ClaimUID optimization scripts; kept for historical reference. |
| `DenialWorkflow_Loading_Optimization_Indexes.sql` | Superseded lab performance patch | Not merged | Earlier dashboard/loading index pack. Covered by the broader all-table and ClaimUID optimization scripts; kept for historical reference. |
| `DenialWorkflow_Index_Maintenance.sql` | Lab maintenance utility | Not merged | Run manually after large imports or during maintenance windows. It reorganizes/rebuilds indexes and updates stats, so it should not be part of first-time setup. |
| `DenialWorkflow_NorthWest_AllTables_Create.sql` | Destructive lab clone/reset | Not merged | SQLCMD-only destructive rebuild script generated from Northwest. Keep separate and run only with `AllowDestructiveReset=YES` after backup. |
| `DenialWorkflow_Clone_NorthWest_Validation.sql` | Lab validation utility | Not merged | SQLCMD validation script for rebuilt target labs. Run after setup/clone with `ExpectedLabId` set. |
| `DenialMapper_PushAudit_ManualValidation.md` | Documentation | Not merged | Manual validation instructions, not executable SQL. |

## Deployment Order

1. Run `Denial_Master_Database_Setup_Merged.sql` once in `LRNMaster`.
2. Run `Denial_Lab_Database_Setup_Merged.sql` in every configured lab database.
3. Optionally run `DenialWorkflow_Clone_NorthWest_Validation.sql` for a rebuilt lab.
4. Optionally run `DenialWorkflow_Index_Maintenance.sql` after heavy imports or bulk updates.
