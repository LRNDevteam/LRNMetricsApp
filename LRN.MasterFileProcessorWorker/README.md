# LRN Master File Processor

A Windows Service (`LRN - Master File Processor`) that, on a timer, pulls each lab's weekly master
workbook from SharePoint, validates it, exports standardized line-level and claim-level CSVs, bulk
copies them into that lab's database, and publishes reports and logs back to SharePoint and Teams.

This project is **self-contained**: it has no `ProjectReference` to any other project in the
repository, and it can be built, published and deployed on its own.

```
dotnet build    services/LRN.MasterFileProcessorWorker
dotnet run   --project services/LRN.MasterFileProcessorWorker -- --selftest
dotnet publish  services/LRN.MasterFileProcessorWorker -c Release
```

## Command-line entry points

| Argument | What it does |
| --- | --- |
| *(none)* | Runs the service loop: poll → download → validate → export → bulk copy → publish. |
| `--selftest` | Runs the built-in bulk-copy self-tests. No database, no config, no test framework. |
| `--diagnose` | Preflight check: verifies config, lab mappings, `LabMaster` and the target tables without processing a file. |

## Layout

| Folder | Contents |
| --- | --- |
| `Program.cs` | Host, configuration (including Key Vault) and DI registration. |
| `MasterFileProcessorWorker.cs` | The hosted service: the end-to-end run for every configured lab. |
| `Configuration/` | `ImportOptions` (the `MasterFileProcessor` section, including `Labs[]`) and `ProcessLogOptions`. |
| `SharePoint/` | Microsoft Graph client: find the current week's file, download it, upload outputs and logs. |
| `ExcelValidation/` | Header-versus-JSON-schema validation for incoming workbooks. |
| `Excel/` | Raw and standardized CSV export, the insurance master reader, XLSX sanity check. |
| `BulkLoad/` | Line-level / claim-level `SqlBulkCopy` pipeline, lab mappings, LIMS master import, self-tests. |
| `ModeMedian/` | Mode / median payment report: repositories, workbook writer, publisher. |
| `Snapshots/` | Step 88: weekly Parquet snapshots of the Line Level, Claim Level and LIMS tables, their LRNMaster index, and retention. |
| `ProcessLogging/` | `LRN_Run_Log` / `LRN_Step_Log` / `LRN_Error_Log` writers (SQL, CSV, daily workbook) and file-status tracking. |
| `Logging/` | log4net-backed `ILoggerService`, the application log file that only carries our own messages. |
| `Notifications/` | Teams webhook and Graph email notifiers. |
| `Security/` | HIPAA controls: PHI redaction for every log sink, SQL connection policy, lab-database guard, file-name guard, temp-file sweep. |
| `Schemas/` | Per-lab column schemas and field mappings. Copied to the output folder. |
| `sql/` | Table and stored-procedure scripts. Reference only - never copied to the output folder. |
| `Sample/` | Sample workbooks and verification queries. Reference only. |

Types under `Configuration/`, `Excel/`, `ModeMedian/` and `ProcessLogging/` sit in the global
namespace, which is the convention this project already used; the rest are namespaced under
`LRN.MasterFileProcessorWorker.*`.

## Configuration and secrets

`appsettings.json` holds **no secrets** and is safe to commit. Every secret comes from Azure Key
Vault at run time. There is no secrets file: `appsettings.Secrets.json` is no longer read.

| Server | `DOTNET_ENVIRONMENT` | Vault (`KeyVault:VaultUri`) |
| --- | --- | --- |
| Production | unset | `https://kv-lrnmetrics-prod.vault.azure.net/` (`appsettings.json`) |
| Test | `Test` (machine environment variable) | `https://lrn-testapp-kv.vault.azure.net/` (`appsettings.Test.json`) |

Key Vault secret names cannot contain `:`, so they use `--` instead. The configuration provider maps
them back, which means a vault secret binds straight onto a configuration key:

| Vault secret | Configuration key |
| --- | --- |
| `ConnectionStrings--DefaultConnection` | `ConnectionStrings:DefaultConnection` |
| `ConnectionStrings--ElixirConnection` | `ConnectionStrings:ElixirConnection` |
| `MasterFileProcessor--SharePoint--TenantId` | `MasterFileProcessor:SharePoint:TenantId` |
| `MasterFileProcessor--SharePoint--ClientId` | `MasterFileProcessor:SharePoint:ClientId` |
| `MasterFileProcessor--SharePoint--ClientSecret` | `MasterFileProcessor:SharePoint:ClientSecret` |
| `ConnectionStrings--<LabDbConnectionKey>` | each lab's own database (table below) |
| `Notifications--Teams--WebhookUrl` | `Notifications:Teams:WebhookUrl` |
| `MasterDataSnapshot--BlobServiceUri` | `MasterDataSnapshot:BlobServiceUri` (snapshot storage account URL) |
| `MasterDataSnapshot--ContainerName` | `MasterDataSnapshot:ContainerName` (snapshot container) |

The vault provider is added after `appsettings.json`, so a vault value always wins over it.

### Per-lab databases

`ConnectionStrings:DefaultConnection` is the `LRNMaster` database. Each lab additionally names the
vault secret holding its own database, via `LabDbConnectionKey` in its `MasterFileProcessor:Labs[]`
entry - `"LabDbConnectionKey": "CoveConnection"` reads the secret `ConnectionStrings--CoveConnection`.
Every step (LIMS import, line/claim bulk copy, AR Workbench sync, snapshots) resolves the lab's
database this one way, and a missing secret fails that lab with a message naming the secret - it
never falls back to LRNMaster:

| Lab | `LabDbConnectionKey` | Database |
| --- | --- | --- |
| 2 Inhealth DTR | `InHealthConn` | `InHealthDTRLRN` |
| 4 Cove | `CoveConnection` | `CoveLRN` |
| 6 PCR Dx AL | `PCRALConnection` | `PCRAL_LRN` |
| 7 PCR Dx CO | `PCRDxConnection` | `PCRCO_LRN` |
| 9 Rising Tides | `RisingTidesConnStr` | `RisingTides` |
| 10 Beech Tree | `BeechTreeConnStr` | `BeechTree_LRN` |
| 12 Phi Life | `PhiLifeConnStr` | `PhiLife_LRN` |
| 13 PCR Labs of America | `PCRLOAConnStr` | `PCRLOA_LRN` |
| 25 VariantX | `VariantXConnection` | `VariantX_LRN` |
| 16 Elixir | `ElixirConnection` | `Elixir_LRN` |
| 18 Certus | `CertusConnection` | `Certus_LRN` |
| 23 NorthWest | `NWLConnection` | `NWL_LRN` |
| 24 Augustus Labs | `AugustusConnStr` | `Augustus_LRN` |
| 26 Analyze Pathology | `AnalyzePathologyConnStr` | `AnalyzePathology` (tables: `sql/AnalyzePathology/`) |
| 27 WellHealth | `WellHealthConnStr` | `WellHealth` |
| 28 CoreBio | `CoreBioConnStr` | `CoreBio` (tables: `Database/LRN.MasterFileProcessorWorker/CoreBio/`) |
| 29 TexasDiagnostic | `TexasDiagnosticConnStr` | `TexasDiagnostic` (tables: `Database/LRN.MasterFileProcessorWorker/TexasDiagnostic/`) |

A literal `LabDbConnectionString` / `LimsDbConnectionString` on a lab is no longer read.

The Database column is also the `DatabaseName` in the lab's `*FieldMappings.json`, and it is enforced:
every load refuses a connection that reaches any other database (see [HIPAA controls](#hipaa-controls),
MF-05). The names above were checked against `kv-lrnmetrics-prod` with `--diagnose` in Nov 2026. A lab
moved to a new database needs its mapping file changed in the same release as its vault secret.

### Authenticating to the vault

Access uses `DefaultAzureCredential`:

* **On the server** - the service's managed identity.
* **Locally** - your `az login` / Visual Studio sign-in.

The vaults have RBAC authorization enabled, so that identity needs the **Key Vault Secrets User**
role on `kv-lrnmetrics-prod` (production) or `lrn-testapp-kv` (test). Without it, startup fails when
the first secret is read.

### Running without the vault

Set `KeyVault:VaultUri` to `""` and supply the same keys through environment variables or user
secrets, for example:

```powershell
$env:ConnectionStrings__DefaultConnection = "Server=...;Database=LRNMaster;..."
$env:MasterFileProcessor__SharePoint__ClientSecret = "..."
```

`--selftest` needs neither the vault nor a database.

## Cove column mapping

Cove's line- and claim-level data come from `dbo.Cove_Line_Level_Billing_Master` and
`dbo.Cove_Claim_Level_Billing_Master`, whose column names are the "New ... Master" column of
`Sample/Cove_ColumMapping_NewMasterReports_v1.1.xlsx` (Deepak's mapping). The config was checked
against that file in Sep 2026 by running `StandardCsvExporter` over the tables' real headers.

Every row the file marks **Mapped** or **Required** matches the load, with these decisions:

| File says | Load does | Why |
|---|---|---|
| Claim `Claim Level Denial Code` -> `DenialCode` | Same (was `Denial Code` before Sep 2026) | Set in `Cove_ClaimLevel.schema.json` |
| Line `TotalBalance` -> `TotalBalance` | Same (was computed as Patient + Insurance balance) | Set in `Cove_LineLevel.schema.json` |
| Claim `Claim Level CPT` -> `CPTCodeXUnitsXModifier` | Source goes to `CPTCodeXUnitsXModifierOrginal`; `CPTCodeXUnitsXModifier` is the line-level roll-up | Kept consistent with every other lab |
| Line `UID` -> `LineLevelUID` | `UID` -> `UID`; `LineLevelUID` computed | Join key for the Denial worker and dashboards |
| `InsertedDateTime` required | Filled by the table default, not the mapping | - |

Columns the file marks **Unmapped / N/A / Not Required** (for example `ClinicName`, `SalesRepname`,
`ClaimUID`, `TotalWO`, `T_F`, `PlanName`, the deposit dates, `Created/Updated On/By`) are still
loaded on purpose: Clinic Summary, Sales Rep Summary, the Denial worker and the dashboards read them.

## Uploaded master files (AR Workbench > Master File Upload)

For a client whose master file never reaches the SharePoint master folder (a lab that takes only the
AR Workbench), or a one-off load for any lab, the master data can be uploaded in the AR Workbench
instead. The user downloads the **standard template** (one workbook: `Instructions`, `Claim Level`,
`Line Level`), maps their data into it and uploads it with the week it belongs to.

| Piece | Where |
| --- | --- |
| Template columns (the one definition) | `Schemas/StandardUpload/StandardUpload_ClaimLevel.schema.json`, `..._LineLevel.schema.json`. Headers are the common column names; `Required` drives validation. `LRN.ReportsApi` links the same two files to build the downloadable template and its upload check. |
| Stored upload | `LRNMaster.dbo.MasterFileUpload` (`Database/LRN.MasterFileProcessorWorker/Create_MasterFileUploads.sql`, after `Create_RerunRequests.sql`) |
| Queue | the usual `dbo.MasterFileProcessorRerunRequest` row, with `UploadId` set |

A claimed request with an `UploadId` changes only how the run **gets** its workbook (trigger type
`Upload` in `LRN_Run_Log`):

* Step 10 reads the upload row instead of searching SharePoint; step 15 does not apply; step 20 writes
  the stored workbook to the same local path a download would use.
* Validation, RAW export and standardization use the template schemas as the lab schema (and the
  template's sheet names), whatever the lab's own schema is.
* No LIMS master and no client-paid file (an upload has no SharePoint week folder); step 130 has no
  SharePoint item to move. A LabDatabase lab's table gate and table export are off for that run.
* Everything else is unchanged: insurance-master payer normalization, denial enrichment, the
  `dbo.LineLevelData` / `dbo.ClaimLevelData` bulk load, the AR Workbench sync (step 87), snapshots,
  output CSVs and their SharePoint upload, the archive copy, Teams notifications.
* The week the user picked becomes a synthetic path `AR Workbench Upload/<Lab>/<yyyy>/<MM.Month>/<MM.dd.yyyy - MM.dd.yyyy>/<file>`,
  so year, month and week folders, output names and the snapshot week range come out as for a
  SharePoint file of that week.
* HIPAA: `FileContent` is set to NULL when the run ends, success or failure (the archive keeps the
  processed copy, as for every master file). A failed upload is fixed and uploaded again.

Every configured lab accepts an upload. A lab with **no** SharePoint master folder is configured with
`"MasterDataSource": "Upload"`: the schedule skips it silently (no run log, no "no file found" Teams
message), and a plain Run Master File Load for it is closed as SKIPPED. Onboarding such a lab needs
the same pieces as any other lab, minus SharePoint:

1. Its database with `dbo.LineLevelData` / `dbo.ClaimLevelData` (and the AR Workbench scripts), an
   active `LabMaster` row, and its Key Vault connection secret.
2. A `Schemas/LabMappings/<Lab>FieldMappings.json` with its `LabId` and `DatabaseName`.
3. A `MasterFileProcessor:Labs` entry, e.g.
   `{ "LabId": 30, "LabName": "NewClient", "MasterDataSource": "Upload", "LabDbConnectionKey": "NewClientConnStr", "ArWorkbenchEnabled": true }`.

A request for a lab that is not in `Labs` is closed as SKIPPED with that reason, and its upload is cleared.

## Master data snapshots (step 88)

Design: [`docs/master-file-processor/LRN_Report_Snapshots_Parquet_Storage_Implementation.pdf`](../docs/master-file-processor/LRN_Report_Snapshots_Parquet_Storage_Implementation.pdf).

After a lab's weekly run has loaded its tables (step 20 LIMS, step 85 line/claim, step 87 AR
Workbench), step 88 writes each table that **loaded in this run** to one Parquet file:

```
<container>/<LabName>/<RunId>_<WeekRange>_LINELEVEL.parquet
                     /<RunId>_<WeekRange>_CLAIMLEVEL.parquet
                     /<RunId>_<WeekRange>_LIMS.parquet
e.g. report-snapshots/Beech_Tree/R20260213BTL0001_02.06.2026-02.12.2026_LINELEVEL.parquet
```

`LabName` is the lab's configured name with spaces as underscores (the same prefix the line/claim
CSVs use), and `WeekRange` is the week folder with its spaces removed.

Each file is checked (footer row count = rows read), hashed (SHA-256), uploaded, and recorded in
`LRNMaster.dbo.ReportSnapshotRun` / `dbo.ReportSnapshotFile`. Then retention keeps the latest
successful run of each of the last `KeepWeeks` week folders (plus the last run of each of the last
`KeepMonthEnd` months, if set) and deletes the rest, files first, then rows. A re-run of a week
replaces that week's snapshot. A level that skipped or failed is not snapshotted, because its table
still holds last week's rows. A snapshot failure is a WARNING (`SNAPSHOT_FAILED` in
`LRN_Error_Log`) and never fails the run. To retry, re-run the lab.

To turn it on:

1. Run `Database/LRN.MasterFileProcessorWorker/Create_ReportSnapshots.sql` in LRNMaster.
2. Create a storage account with a **private** container, and give the service's managed identity
   **Storage Blob Data Contributor**. (Or set `Storage` to `LocalFolder` to write to a disk or share.)
3. Add the vault secrets `MasterDataSnapshot--BlobServiceUri` (e.g.
   `https://<account>.blob.core.windows.net`) and `MasterDataSnapshot--ContainerName` (e.g.
   `report-snapshots`). Both are left blank in `appsettings.json` on purpose.
4. Under `MasterDataSnapshot` in `appsettings.json`, set `KeepWeeks` and `Enabled: true`.
5. For each lab to snapshot, set `"MasterDataSnapshotEnabled": true` in its `MasterFileProcessor:Labs`
   entry. Every lab carries the key, set to `false`; a lab without it is treated as `false`.

To inspect a file, download it with Azure Storage Explorer and open it with DuckDB:
`SELECT * FROM 'R20260213BTL0001_02.06.2026-02.12.2026_LINELEVEL.parquet' LIMIT 20;`

## HIPAA controls

Implements the `LRN.MasterFileProcessorWorker` rows of
[`docs/security/LRN HIPAA Compliance Checklist.pdf`](../docs/security/LRN%20HIPAA%20Compliance%20Checklist.pdf)
(section 2) that code can satisfy, and Wave 4 tasks W4-2 / W4-6 of
[`LRN_HIPAA_Platform_Implementation.md`](../docs/security/LRN_HIPAA_Platform_Implementation.md).
`--diagnose` section **1c** reports the ones that depend on configuration or the server.

| Row | Control | Where |
| --- | --- | --- |
| MF-05 | Before any write, the lab's connection must reach the database named by `DatabaseName` in its `*FieldMappings.json`. Checked on the connection string before the `LineClaimFileLogs` row and every LIMS / lab-database access, and again on the open connection before `TRUNCATE`. A mismatch fails the run: `LAB_ROUTING_MISMATCH` in `LRN_Error_Log`, Teams notified, nothing written. | `Security/LabDatabaseGuard.cs` |
| MF-07, CC-18 | No row values in any log. Exception text that quotes a cell (`The given value '…'`, `Truncated value: '…'`, duplicate key values, parse errors, SSNs) is scrubbed before it reaches `LRN_Run/Step/Error_Log` (SQL, CSV, workbook), `ReportRunIdInfoLog`, `ReportsWorkflowTracker`, `LineClaimFileLogs`, the rerun queue, the file-status and master-processor CSVs, the log4net file, the Windows event log and Teams. `LRN_Error_Log.RowExample` is always written empty. A malformed CSV line is reported by number, never by content. | `Security/PhiRedactor.cs`, `Security/RedactingLoggerProvider.cs` |
| CC-08, MF-04 | At startup every `ConnectionStrings:*` value is checked. `Encrypt=False` is switched on in memory; `TrustServerCertificate=True` and an `sa` login are logged. `Security:SqlConnectionPolicy = Enforce` refuses to start while any remain; it ships as `Warn` because the vault secrets still have both (see below). | `Security/SqlConnectionPolicy.cs`, `Program.cs` |
| MF-02, MF-03 | A run's downloaded workbook and RAW CSVs are deleted in `finally` if the run did not finish (a finished run has already archived / deleted them). An hourly sweep removes temp copies older than 24 h: `LRN-RAWFILE` (not `Archive`), `~staging_*`, `*.download`, Mode/Median temp workbooks, snapshot `*.parquet` work files. `--diagnose` fails a data folder that Everyone / Users / Authenticated Users can read. | `Security/TempFileJanitor.cs`, `MasterFileProcessorWorker.cs` |
| MF-08 | A master file whose name or SharePoint path carries an SSN-shaped value or a 9+ digit number that is not a date is refused before download (`PHI_IN_FILE_NAME`); the message never repeats the name. `Security:RejectPhiInFileNames`. | `Security/PhiFileNameGuard.cs` |
| MF-01 | SharePoint authenticates with a certificate when the vault holds `MasterFileProcessor--SharePoint--ClientCertificate` (import it as a Key Vault *certificate*), falling back to the client secret with a warning. | `SharePoint/SharePointDownloader.cs` |
| MF-12 | The bulk-copy completion entry in `ReportRunIdInfoLog` records rows in the table, rows in the CSV and the CSV's SHA-256. A count mismatch already rolls the load back. | `BulkLoad/LineClaimImportService.cs` |
| MF-06 | No staging tables exist: line/claim loads `TRUNCATE` and bulk copy inside one transaction. | `BulkLoad/LineClaimBulkLoader.cs` |
| MF-09 | `RowHash` (SHA-256 of the hashed business columns) is for change detection only. It is **not** de-identification: the inputs are low-entropy, so a hash can be matched back to a patient by anyone who can guess them. Never expose it as a substitute identifier. | `BulkLoad/RowHasher.cs` |

### Where PHI rests (W4-2)

| Location | Holds | Kept |
| --- | --- | --- |
| Each lab's database (`LineLevelData`, `ClaimLevelData`, `LIMSMaster`, `ARWB_*`) | Current week's claims and lines | Replaced every run (MF-13); earlier weeks remain in SQL backups |
| `C:\LRN-Files\Automation\LRN-RAWFILE\<month>\<week>\` | Downloaded workbook, RAW CSV exports | Duration of the run; swept after 24 h |
| `C:\LRN-Files\Automation\LRN-RAWFILE\Archive\…` | Every processed workbook | Indefinitely - moves to Blob in Wave 4 (W4-3) |
| `C:\LRN-Files\Automation\LRN-Input\<lab>\<year>\<month>\<week>\` (+ `Obsolete\`) | Published standardized CSVs, the raw master copy, LIMS / client-paid files | Indefinitely - read by the downstream watcher; retention to be decided (D1) |
| `…\LRN-Input\<lab>\~staging_<RunId>\` | Work-in-progress outputs | Duration of the run; swept after 24 h |
| `C:\LRN-Files\Automation\LRN-Output\Mode`, `\Median` | Mode/median payment workbooks (aggregates by CPT/payer) | Indefinitely |
| `%TEMP%` (Mode/Median temp, `LRN-Snapshots\`) | Work files | Duration of the step; swept after 24 h |
| Snapshot container (`MasterDataSnapshot`) | Weekly Parquet copies of the three tables | `KeepWeeks` (5) |
| `logs\`, `Logs\`, `…\Logs\Master File Processor` | Run/step/error logs | No row values; file and SharePoint paths only |

### Still open for this worker

These need infrastructure or a decision, not code:

* **CC-10 / G10 - rotate credentials.** The SQL `sqladmin` and `sa` passwords, the SharePoint client
  secret and the Teams webhook URL were committed to git in the past (`appsettings.Secrets.json`
  history). Rotate all of them, then decide D6 (history rewrite).
* **CC-08 / MF-04 - fix the vault secrets.** Every connection string has `TrustServerCertificate=True`,
  and nine production labs connect to `ReportEngine\SQLEXPRESS` as `sa`. Give each a least-privilege
  login (or managed identity on SQL MI), install a trusted certificate on SQL Express, then set
  `Security:SqlConnectionPolicy` to `Enforce`.
* **MF-02 - folder ACLs and disk encryption.** Remove `Authenticated Users` from `C:\LRN-Files\Automation`
  and confirm BitLocker on the volume (W4-1).
* **MF-01 - `Sites.Selected`.** Grant the app registration `Sites.Selected` on the one site and remove
  any tenant-wide `Sites.*` permission, then import the certificate.
* **MF-10 - snapshot container.** Private access, a 5-week lifecycle rule and soft delete are storage
  account settings. Blob names hold the lab, RunId and week - no patient identifiers.
* **MF-11 - service account.** Run the service under a gMSA or low-privilege account.
* **MF-13 - retention.** Earlier weeks remain in SQL backups; document the backup retention.
* **CC-17 - PhiAccessAudit.** The shared table belongs with the API work; this worker's own access is
  already recorded per RunId in `LRN_Run_Log` / `ReportRunIdInfoLog`.

## Notifications

Both channels are **off**. Each has exactly one switch in `appsettings.json`:

| Channel | Switch | State | Notes |
| --- | --- | --- | --- |
| Teams | `Notifications:Teams:Enabled` | `true` | Webhook URL comes from the vault secret `Notifications--Teams--WebhookUrl`. |
| Email | `Notifications:Email:Enabled` | `false` | Graph `sendMail`; the send is not implemented yet. |

SMTP has been removed - `MailKit` is gone and so is `SmtpEmailNotifier`, because the tenant is
retiring SMTP. [`Notifications/GraphEmailNotifier.cs`](Notifications/GraphEmailNotifier.cs) is the
replacement seam: `IEmailNotifier`, `EmailNotification` and `EmailOptions` are all in place, and
only the Graph `sendMail` call itself is left to write. While `Enabled` is `false` the notifier is
never reached; if it is switched on before the call is written, it logs a warning and drops the
message rather than throwing.

Sending mail through Graph needs the **Mail.Send** application permission on the app registration,
in addition to the SharePoint permissions it already has.
