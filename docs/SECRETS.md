# Secrets and configuration

No credential belongs in a file this repository tracks. Every secret is supplied at run time, and
the committed `appsettings.json` files carry only the shape of the setting so a reader can see what
the application expects.

This document exists because the alternative is guesswork. A missing secret used to surface as
"DefaultConnection not configured" on the first page that touched a database, which names the
symptom and not the cause.

## Where a secret can come from

In precedence order, lowest first. A later source overrides an earlier one.

| Source | Used by | Committed |
|---|---|---|
| `appsettings.json` | shape and non-secret defaults only | yes |
| `appsettings.Local.json` | a developer machine | no, gitignored |
| Azure Key Vault | every deployed environment | no |
| Environment variables | containers, CI, overrides | no |

Key Vault is read at startup when `KeyVault:Uri` is set. Blanking that value in
`appsettings.Local.json` skips the vault entirely and runs from local settings, which is how a
machine without vault access works.

## Naming

The three forms of the same setting differ only in their separator.

| Form | Example |
|---|---|
| Configuration key | `DenialWorkflowAuth:JwtSigningKey` |
| Key Vault secret | `DenialWorkflowAuth--JwtSigningKey` |
| Environment variable | `DenialWorkflowAuth__JwtSigningKey` |

The double underscore is .NET's own convention and the double hyphen is `AddAzureKeyVault`'s.
Neither needs custom code. Indexed names work the same way, so
`ExternalApiClients--Clients--0--ClientId` binds to `ExternalApiClients:Clients[0]:ClientId` and
merges with whatever `appsettings.json` already declares on that entry.

## What has to be set

### Both web applications

| Configuration key | Notes |
|---|---|
| `DenialWorkflowAuth:JwtSigningKey` | At least 32 characters. Must be **byte-identical** in LabMetricsDashboard and LRN.ReportsApi, or every workflow token fails to verify. |
| `DenialWorkflowAuth:ImportApiKey` | Authenticates the denial import worker. Compared in constant time. |
| `ConnectionStrings:DefaultConnection` | LRNMaster. |

Both applications now **refuse to start** outside Development when `JwtSigningKey` is absent or
under 32 characters. That is deliberate. The previous behaviour was to start cleanly and fail on
the first workflow request, which reads as a workflow bug rather than a deployment fault and can
survive a release unnoticed.

### Other connection strings

Set the ones the deployed component actually uses.

| Configuration key | Used by |
|---|---|
| `ConnectionStrings:LRNMaster` | CaptureDataApp, LRN.AveragesImport |
| `ConnectionStrings:DenialDatabase` | denial workflow |
| `ConnectionStrings:LabMetrics` | dashboard reporting |
| `ConnectionStrings:LrnLogDb` | process logging |
| `ConnectionStrings:<Lab>Connection` | one per lab, e.g. `CoveConnection`, `NWLConnection` |

Per-lab connections are resolved by name at run time from each lab's `LabDbConnectionKey` setting,
so adding a lab means adding a vault secret, not changing code.

### Workers

`LRN.MasterFileProcessorWorker` also reads `appsettings.Secrets.json`, which is gitignored and
absent on a clean clone. `appsettings.Secrets.example.json` is the tracked template. It holds the
SharePoint app registration and the Teams webhook.

## Connection string rules

Two settings are not negotiable in any environment other than a developer machine.

```
Encrypt=True;TrustServerCertificate=False;
```

`TrustServerCertificate=True` disables the certificate check, which turns an encrypted connection
into one that any machine positioned between the app and the database can read. It appears in this
repository only in `appsettings.Development.json`.

The committed strings name the server and the database but carry no `User ID` and no `Password`.
Supply the credential from the vault, either by overriding the whole connection string or by using
a managed identity.

## If a secret leaks

1. Rotate the value at its source first. A rotated key makes the exposed copy worthless, which
   nothing else on this list does.
2. Update every environment that uses it, including CI and any developer machine.
3. Only then rewrite git history, because history rewriting is slow, disruptive and useless while
   the old value still works.
4. Review the SQL Managed Instance audit logs and the Reports API logs for use of the exposed
   credential, and give the result to the Security and Compliance Officer.

Never paste a real secret into an issue, a pull request, a chat message or a log line. The
application logs mask query strings for this reason.
