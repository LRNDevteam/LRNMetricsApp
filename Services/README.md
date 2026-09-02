# Services

The worker services and shared libraries that sit under the `Services` solution folder.

| Project | What it is |
| --- | --- |
| `LRN.SharePointSynchronizer` | Windows Service: keeps server folders and SharePoint libraries in sync. |
| `LRN.SharePointUploader` | Windows Service: uploads report outputs to SharePoint, optionally writing an LRN step log. |
| `FolderRetentionCleanupWorker` | Windows Service: deletes files past the retention window. Holds no secrets. |
| `LRN.SharePointClient` | Shared library: Microsoft Graph SharePoint client, folder sync engine, Teams notifier. |
| `LRN.DataLibrary` | Shared library: EF Core context and repository for the LRN run/step/error log tables. |

## Configuration and secrets

Every `appsettings.json` in this folder holds **no secrets** and is safe to commit. Credentials and
connection strings come from Azure Key Vault at run time, the same vault and the same pattern as
[`LRN.MasterFileProcessorWorker`](../LRN.MasterFileProcessorWorker/README.md):

```
https://kv-lrnmetrics-prod.vault.azure.net/
```

Key Vault secret names cannot contain `:`, so they use `--` instead. The configuration provider maps
them back, which means a vault secret binds straight onto a configuration key. The provider is added
after `appsettings.json`, so a vault value always wins over it.

### LRN.SharePointSynchronizer

| Vault secret | Configuration key |
| --- | --- |
| `MasterFileProcessor--SharePoint--TenantId` | `MasterFileProcessor:SharePoint:TenantId` |
| `MasterFileProcessor--SharePoint--ClientId` | `MasterFileProcessor:SharePoint:ClientId` |
| `MasterFileProcessor--SharePoint--ClientSecret` | `MasterFileProcessor:SharePoint:ClientSecret` |

This service uses the same app registration, the same configuration section, and therefore the
**same three vault secrets** as `LRN.MasterFileProcessorWorker`. One rotation covers both.

### LRN.SharePointUploader

| Vault secret | Configuration key |
| --- | --- |
| `BillingFrequency--SharePoint--TenantId` | `BillingFrequency:SharePoint:TenantId` |
| `BillingFrequency--SharePoint--ClientId` | `BillingFrequency:SharePoint:ClientId` |
| `BillingFrequency--SharePoint--ClientSecret` | `BillingFrequency:SharePoint:ClientSecret` |
| `ConnectionStrings--LrnLogDb` | `ConnectionStrings:LrnLogDb` |

`ConnectionStrings--LrnLogDb` is only read when `LrnStepLog:Enabled` is `true`; startup throws if it
is enabled and the secret is missing.

`LRN.SharePointClient` resolves its SharePoint section in the order `BillingFrequency:SharePoint`,
then `MasterFileProcessor:SharePoint`, then `SharePoint`. This service's section exists (it carries
`Hostname`, `SitePath` and the upload paths), so the first match wins and its credentials must be
present under `BillingFrequency--SharePoint--*` — even though they are the same app registration as
the Synchronizer's. **Known wart:** the same credential therefore lives in the vault twice and both
copies have to be rotated together. Consolidating means moving this service onto the
`MasterFileProcessor:SharePoint` section, or teaching `AddLrnSharePointClient` to fall back per key
rather than per section.

### The secrets that are not in the vault

Both services' Teams incoming-webhook URLs are longer than the 256-character limit on the vault tags
these settings are managed through (296 and 265 characters), so they live in
`appsettings.Secrets.json` instead. That file is gitignored and is loaded **after** the vault, so
anything in it wins.

Copy each project's `appsettings.Secrets.example.json` to `appsettings.Secrets.json` and fill in the
URL. Nothing else belongs in that file — every other secret comes from the vault. A leftover
override there silently shadows the vault, including after a credential rotation.

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
$env:MasterFileProcessor__SharePoint__ClientSecret = "..."
$env:ConnectionStrings__LrnLogDb = "Server=...;Database=LRNMaster;..."
```

## Content root

Both services set `ContentRootPath` to `AppContext.BaseDirectory`. A Windows Service starts with its
working directory at `System32`, so without this neither `appsettings.json` nor
`appsettings.Secrets.json` is found once the service is installed.
