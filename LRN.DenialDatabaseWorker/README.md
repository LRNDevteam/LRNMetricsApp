# DenialDatabaseProcessorWorker (.NET 8)

What it does (per LAB):

**Output columns**: includes ALL original PayerPolicy columns (same order) + new columns (DenialCode_Original, DenialCode_Normalized, validation flags, Status Action Code, Task Guidance). The DenialCode column itself is replaced with the normalized value.

1. Loads the denial source:
   - **Denial rows come from SQL, not from a file.** For every lab, the worker reads
     `[<LabDatabase>].[dbo].[PayerValidationReport]` where `PayStatus = 'Denied'`
     (table/status configurable via `PayerValidationReportTable` / `DeniedPayStatus`).
     The upstream process no longer publishes `*_Payer_Policy_ValidationReport.xlsx`.
     SQL columns are re-keyed to the old Excel header names, so all downstream mapping is unchanged.
   - **The RunId comes from LRNMaster, not from the lab table.** The worker calls
     `dbo.sp_GetRecentSuccessRunByLab @LabName` for the lab's most recent run with
     `OverallStatus = 'SUCCESS'`, then checks that run exists in the lab's own database
     (`SELECT COUNT(1) FROM PayerValidationReport WHERE RunId = @RunId`). Count 0 means this
     lab has nothing for the run and it is recorded as `Skipped`; count > 0 means import.
     A lab with no successful run at all is skipped silently — there is no RunId to log under.
   - WeekFolder and SourceFullPath still supply the folder structure that used to be parsed out
     of the workbook file name and path. With `ProcessLatestRunOnly = true` only that RunId's rows
     are read; a RunId already present in `dbo.DenialAnalysisRunLog` is skipped.
   - ClaimActionMapper is still an Excel file (must contain a denial prefix column like
     "Denial Code_Prefix" / "Denial code_prefix" and the mapping columns)
2. Normalizes `PayerPolicyFile.DenialCode`:
   - split by comma
   - uppercase
   - remove spaces and '-' (e.g., "CO 55", "CO-56" -> "CO55", "CO56")
   - remove these "generic" codes anywhere they appear:
     PR1, CO1, PI1, PR2, CO2, PI2, PR3, CO3, PI3, PR45, CO45, PI45, PR253, CO253, PI253
3. Enriches each PayerPolicy row by mapping denial codes against ClaimActionMapper:
   - For each denial code (after split + normalize), match against ClaimActionMapper.Denail code_prefix
   - Collect distinct values per column and join with comma for:
     Denial Description, Denial Classification, Denial Type,
     Payer Policy Validation Required, CPT Validation Required, ICD Validation Required,
     Frequency Validation Required, Gender Validation Required, MUE Validation Required,
     Payability, Status Action Code, Recommended Action, Task Guidance
4. Copies the result into the LAB database (this is the primary output):
   DenialInsight, DenialLineItem and DenialTaskBoard, plus a RunLog row in LRNMaster.
5. Optionally outputs the export package per lab (xlsx + line-item csv + zip):
   <OutputRoot>\<LabName>\<Year>\<Month>\<Week>\<RunId>_<LabName>_DenialAnalysisReport_<Week>.zip
   **Off by default.** Controlled by `DenialDatabaseProcessor:GenerateOutputFiles`; when false the
   worker performs the SQL copy only and writes no files. `UploadOutputsToSharePoint` gates the
   SharePoint upload of that package and is ignored when `GenerateOutputFiles` is false.
6. Step-by-step CSV logging:
   Log columns:
   LabName,LabId,StepDescription,LogType,PayerPolicyFilePath,ClaimActionMapperFilePath,ErrorInfo,LogDateTime,OutputPath
   (PayerPolicyFilePath now holds the SQL source label, e.g.
   `NWL_LRN.dbo.PayerValidationReport (RunId=..., PayStatus=Denied, Rows=...)`)
7. Optional SharePoint upload (Graph API):
   Upload to: <SharePointUploadPath base folder>/<LABNAME>/<Month>/<MMDDYYYY>/LabName_DenialDatabase_MMDDYYYY.xlsx

---

## Run logging & workflow tracker (LRNMaster)

Every lab pass records what it did and how it finished, always through stored procedures —
never by writing the tables directly. This is what the report dashboard reads.

| Step | What | Class | Procedure |
|------|------|-------|-----------|
| 1 | Get the RunId to work under | `RecentSuccessRunProvider` | `dbo.sp_GetRecentSuccessRunByLab` |
| 2 | Stop if already done for that RunId | `ReportsWorkflowTrackerRepository.IsAlreadySuccessfulAsync` | `SELECT` on `dbo.ReportsWorkflowTracker` (filtered on `Status = 'Success'`, so a failed run can be retried) |
| 3 | Progress trail + mark `InProgress` | `ReportRunIdInfoLogger` | `dbo.usp_ReportRunIdInfoLog_Insert` |
| 4 | Record the outcome | `ReportsWorkflowTrackerRepository.UpsertAsync` | `dbo.usp_ReportsWorkflowTracker_Upsert` |

Statuses come from `WorkflowStatus`, log types from `RunLogType`, report names from
`WorkflowReportNames` — use the constants, so a rename is a compile error rather than a
runtime rejection. The upsert is idempotent (one row per RunId + Lab + Report) and is called
twice by design: `InProgress` at the start, then the final status.

Outcomes this worker writes:

| Status | When |
|--------|------|
| `Success` | Denial tables loaded. `@RowCount` is the DenialLineItem row count. |
| `Skipped` | The run has no rows in the lab's `PayerValidationReport`, no `Denied` rows, or is already in `dbo.DenialAnalysisRunLog`. Always with a reason in `@Remarks`. |
| `Failed` | The pass threw. One line in `@Remarks`; the full exception goes to the info log as `LogType = 'Error'`. |

Both classes swallow their own failures and fall back to the worker's log — a logging outage
costs a log row, not a night's processing. Never put patient data in a log message: counts,
file names, table names and durations only.

Settings (`DenialDatabaseProcessor` section):

| Key | Default | Notes |
|-----|---------|-------|
| `ReportName` | `Denial Report` | Must match `dbo.ReportTypeMaster` character for character. |
| `ReportLogCreatedBy` | `Denial Database Processor` | `@CreatedBy` — the process identity, never a person. |
| `RecentSuccessRunProcedure` | `dbo.sp_GetRecentSuccessRunByLab` | Step 1 lookup. |
| `SqlCommandTimeoutSeconds` | `600` | Command timeout for the lab copy path. ADO.NET's implicit 30s is far too short for a large lab — see below. `0` means no timeout. |

### "Execution Timeout Expired" on one lab

Seen in production on Certus (August 2026), traced to
`DenialTaskBoardRepository.GetExistingTasksAsync`. Three things were wrong at once, all fixed:

- it ran on ADO.NET's implicit **30 second** timeout while everything around it was unlimited;
- it selected **all 34 columns** — including `ICDCodes` and `DenialValidity`, both
  `NVARCHAR(MAX)` — for every task row the lab had ever accumulated, when `TaskBoardBuilder`
  reads only six fields. It now selects ten narrow columns;
- nothing indexed `DenialTaskBoard (LabId)`, so it scanned the base table.

It surfaces on the biggest lab first because that read grows with everything the lab has ever
accumulated, not with the size of the current run. If it comes back, check in order:

1. **Which statement.** The full exception is in `dbo.ReportRunIdInfoLog`
   (`LogType = 'Error'`, filtered by RunId), in `dbo.LRN_Error_Log`, and in the step CSV. The
   stack tells you whether it was the task-board read, the denied-row read, or the reconcile.
2. **How much data.** `SELECT COUNT(1) FROM dbo.DenialTaskBoard WHERE LabId = <LabId>` and the
   same for `DenialLineItem` / `PayerValidationReport WHERE RunId = '<RunId>'`, run in the
   **lab** database.
3. **Indexes.** `Sql_Add_Denial_Performance_Indexes.sql` has the supporting indexes for this
   path, with the sizing queries at the bottom. Review before applying — raising the timeout
   stops the exception, indexes are what make it fast.

Checking a run:

```sql
SELECT RunId, LabName, ReportName, Status, [RowCount], StartedOn, CompletedOn, Remarks
FROM   dbo.ReportsWorkflowTracker
WHERE  RunId = 'R20260805INH0073'
ORDER  BY ReportName;

SELECT LogType, LogMessage, CreatedOn
FROM   dbo.ReportRunIdInfoLog
WHERE  RunId = 'R20260805INH0073' AND ReportType = 'Denial Report'
ORDER  BY ReportRunIdInfoLogId;
```

A correctly instrumented pass shows a `Start`, at least one `Info`, an `End`, and exactly one
tracker row that is no longer `InProgress`.

---

## Run locally
```bash
dotnet restore
dotnet run
```

## Install as Windows Service
Publish:
```bash
dotnet publish -c Release -r win-x64 --self-contained false
```

Create service:
```powershell
sc.exe create "LRN - Denial Database Processor" binPath= "C:\path\to\DenialDatabaseProcessorWorker.exe"
sc.exe start  "LRN - Denial Database Processor"
```

---

## Configuration and secrets

`appsettings.json` holds **no secrets** and is safe to commit. Every secret comes from Azure Key
Vault at run time, the same vault and the same pattern as
[`LRN.MasterFileProcessorWorker`](../LRN.MasterFileProcessorWorker/README.md):

```
https://kv-lrnmetrics-prod.vault.azure.net/
```

Key Vault secret names cannot contain `:`, so they use `--` instead. The configuration provider maps
them back, which means a vault secret binds straight onto a configuration key. The provider is added
after `appsettings.json`, so a vault value always wins over it.

| Vault secret | Configuration key |
| --- | --- |
| `ConnectionStrings--DenialDatabase` | `ConnectionStrings:DenialDatabase` |
| `DenialDatabaseProcessor--SharePoint--TenantId` | `DenialDatabaseProcessor:SharePoint:TenantId` |
| `DenialDatabaseProcessor--SharePoint--ClientId` | `DenialDatabaseProcessor:SharePoint:ClientId` |
| `DenialDatabaseProcessor--SharePoint--ClientSecret` | `DenialDatabaseProcessor:SharePoint:ClientSecret` |

`ConnectionStrings--DenialDatabase` is the `LRNMaster` database — the same connection the Master File
Processor reads from `ConnectionStrings--DefaultConnection`. **Known wart:** the same connection
string therefore lives in the vault under two names and both have to be rotated together.
Consolidating means renaming the key at the six `GetConnectionString("DenialDatabase")` call sites.

### Per-lab databases

`appsettings.json` carries no lab connection strings. Each `Labs[]` entry instead names the vault
secret holding its own database, via `LabDbConnectionKey`; `Program.cs` resolves it at startup, once
the vault provider is in place. These are the **same per-lab secrets the Master File Processor uses**,
so none had to be created:

| Lab | `LabId` | `LabDbConnectionKey` | Database |
| --- | --- | --- | --- |
| Inhealth_DTR | 2 | `InHealthConn` | `InHealthDTRLRN` |
| Cove | 4 | `CoveConnection` | `CoveLRN` |
| PCR_Dx_AL | 7 | `PCRALConnection` | `PCRAL_LRN` |
| PCR_Dx_CO | 8 | `PCRDxConnection` | `PCRCO_LRN` |
| Rising Tides | 9 | `RisingTidesConnStr` | `RisingTides` |
| Beech_Tree | 10 | `BeechTreeConnStr` | `BeechTree_LRN` |
| Phi Life | 12 | `PhiLifeConnStr` | `PhiLife_LRN` |
| PCR Labs of America | 13 | `PCRLOAConnStr` | `PCRLOA_LRN` |
| Elixir | 16 | `ElixirConnection` | `Elixir_LRN` |
| Certus | 18 | `CertusConnection` | `Certus_LRN` |
| Augustus Labs | 19 | `AugustusConnStr` | `Augustus_LRN` |
| NorthWest | 20 | `NWLConnection` | `NWL_LRN` |

Startup throws, naming the lab and the missing secret, if a key cannot be resolved. A literal
`LabConnectionString` in configuration still wins over the vault — use that only for a throwaway
local override, never in a committed file.

> The `LabId` values above are this worker's own and **disagree with the Master File Processor's**
> for four labs: PCR_Dx_AL (6 there), PCR_Dx_CO (7), Augustus Labs (24) and NorthWest (23). The
> mapping above was made by database name, which is unambiguous. Worth reconciling separately — it
> was not touched here.

### The one secret that is not in the vault

The Teams incoming-webhook URL is 265 characters, longer than the 256-character limit on the vault
tags these settings are managed through, so it lives in `appsettings.Secrets.json` instead. That file
is gitignored and is loaded **after** the vault, so anything in it wins.

Copy [`appsettings.Secrets.example.json`](appsettings.Secrets.example.json) to
`appsettings.Secrets.json` and fill in the URL. Nothing else belongs in that file — every other
secret comes from the vault.

> `TeamsNotificationOptions` is **not bound** in `Program.cs`, so `TeamsNotification:*` is read by
> nothing and the notifier is inert whatever the config says. Pre-existing; left alone here, because
> binding it would start sending Teams messages that are not being sent today.

### Authenticating to the vault

Access uses `DefaultAzureCredential`:

* **On the server** — the service's managed identity.
* **Locally** — your `az login` / Visual Studio sign-in.

The vault has RBAC authorization enabled, so that identity needs the **Key Vault Secrets User** role
on `kv-lrnmetrics-prod`. Without it, startup fails when the first secret is read.

### Running without the vault

Set `KeyVault:VaultUri` to `""` and supply the same keys through environment variables or user
secrets, for example:

```powershell
$env:ConnectionStrings__DenialDatabase = "Server=...;Initial Catalog=LRNMaster;..."
$env:ConnectionStrings__CoveConnection = "Server=...;Initial Catalog=CoveLRN;..."
$env:DenialDatabaseProcessor__SharePoint__ClientSecret = "..."
```

---

## SharePoint upload configuration (Graph)
Set in appsettings.json:
- DenialDatabaseProcessor:SharePoint:Enabled = true
- SiteUrl (e.g. https://tenant.sharepoint.com/sites/SiteName)

TenantId, ClientId and ClientSecret come from Key Vault — see **Configuration and secrets** above.

Permissions needed for the app registration (typical):
- Microsoft Graph -> Application permissions -> Sites.ReadWrite.All (or Sites.Selected if you prefer tighter)
Then grant admin consent.

> NOTE: Your `SharePointUploadPath` is a "AllItems.aspx?id=..." link. The worker automatically extracts the folder from the `id=` query string and uploads into that library folder.


## Mapping format update
- When a PayerPolicy row has multiple denial codes (e.g., CO55,CO56), mapped columns are written as `CODE - Value` pairs joined with comma+space.
  Example: `CO55 - Description A, CO56 - Description B`
- Current ClaimActionMapper mappings are applied only where **Denial Type = Claim Level Denial**.
