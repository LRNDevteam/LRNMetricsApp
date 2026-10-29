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
| 25 VariantX | `VariantXConnection` | |
| 16 Elixir | `ElixirConnection` | `Elixir_LRN` |
| 18 Certus | `CertusConnection` | `Certus_LRN` |
| 23 NorthWest | `NWLConnection` | `NWL_LRN` |
| 24 Augustus Labs | `AugustusConnStr` | `Augustus_LRN` |
| 26 Analyze Pathology | `AnalyzePathologyConnStr` | `AnalyzePathology_LRN` (tables: `sql/AnalyzePathology/`) |
| 27 WellHealth | `WellHealthConnStr` | `WellHealth_LRN` |
| 28 CoreBio | `CoreBioConnStr` | `CoreBio_LRN` (tables: `Database/LRN.MasterFileProcessorWorker/CoreBio/`) |
| 29 TexasDiagnostic | `TexasDiagnosticConnStr` | `TexasDiagnostic_LRN` (tables: `Database/LRN.MasterFileProcessorWorker/TexasDiagnostic/`) |

A literal `LabDbConnectionString` / `LimsDbConnectionString` on a lab is no longer read.

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
