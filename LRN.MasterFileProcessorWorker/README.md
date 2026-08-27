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
Vault at run time:

```
https://kv-lrnmetrics-prod.vault.azure.net/
```

Key Vault secret names cannot contain `:`, so they use `--` instead. The configuration provider maps
them back, which means a vault secret binds straight onto a configuration key:

| Vault secret | Configuration key |
| --- | --- |
| `ConnectionStrings--DefaultConnection` | `ConnectionStrings:DefaultConnection` |
| `ConnectionStrings--ElixirConnection` | `ConnectionStrings:ElixirConnection` |
| `MasterFileProcessor--SharePoint--TenantId` | `MasterFileProcessor:SharePoint:TenantId` |
| `MasterFileProcessor--SharePoint--ClientId` | `MasterFileProcessor:SharePoint:ClientId` |
| `MasterFileProcessor--SharePoint--ClientSecret` | `MasterFileProcessor:SharePoint:ClientSecret` |

The vault provider is added after `appsettings.json`, so a vault value always wins over it.

### The one secret that is not in the vault

The Teams incoming-webhook URL is longer than the 256-character limit on the vault tags these
settings are managed through, so it lives in `appsettings.Secrets.json` instead. That file is
gitignored and is loaded **after** the vault, so anything in it wins.

Copy [`appsettings.Secrets.example.json`](appsettings.Secrets.example.json) to
`appsettings.Secrets.json` and fill in the URL. Nothing else belongs in that file - every other
secret comes from the vault.

### Per-lab databases

`ConnectionStrings:DefaultConnection` is the `LRNMaster` database. Each lab additionally names the
vault secret holding its own database, via `LabDbConnectionKey` in its `MasterFileProcessor:Labs[]`
entry:

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
| 16 Elixir | `ElixirConnection` | `Elixir_LRN` |
| 18 Certus | `CertusConnection` | `Certus_LRN` |
| 23 NorthWest | `NWLConnection` | `NWL_LRN` |
| 24 Augustus Labs | `AugustusConnStr` | `Augustus_LRN` |

A lab may instead carry a literal `LabDbConnectionString`, which takes precedence - use that only
for a throwaway local override, never in a committed file.

### Authenticating to the vault

Access uses `DefaultAzureCredential`:

* **On the server** - the service's managed identity.
* **Locally** - your `az login` / Visual Studio sign-in.

The vault has RBAC authorization enabled, so that identity needs the **Key Vault Secrets User** role
on `kv-lrnmetrics-prod`. Without it, startup fails when the first secret is read.

### Running without the vault

Set `KeyVault:VaultUri` to `""` and supply the same keys through environment variables or user
secrets, for example:

```powershell
$env:ConnectionStrings__DefaultConnection = "Server=...;Database=LRNMaster;..."
$env:MasterFileProcessor__SharePoint__ClientSecret = "..."
```

`--selftest` needs neither the vault nor a database.

## Notifications

Both channels are **off**. Each has exactly one switch in `appsettings.json`:

| Channel | Switch | State | Notes |
| --- | --- | --- | --- |
| Teams | `Notifications:Teams:Enabled` | `false` | Webhook URL comes from `appsettings.Secrets.json`. |
| Email | `Notifications:Email:Enabled` | `false` | Graph `sendMail`; the send is not implemented yet. |

SMTP has been removed - `MailKit` is gone and so is `SmtpEmailNotifier`, because the tenant is
retiring SMTP. [`Notifications/GraphEmailNotifier.cs`](Notifications/GraphEmailNotifier.cs) is the
replacement seam: `IEmailNotifier`, `EmailNotification` and `EmailOptions` are all in place, and
only the Graph `sendMail` call itself is left to write. While `Enabled` is `false` the notifier is
never reached; if it is switched on before the call is written, it logs a warning and drops the
message rather than throwing.

Sending mail through Graph needs the **Mail.Send** application permission on the app registration,
in addition to the SharePoint permissions it already has.
