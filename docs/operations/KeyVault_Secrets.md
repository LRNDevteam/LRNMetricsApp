# Azure Key Vault configuration

`ConnectionStrings:*` and `DenialWorkflowAuth:*` now load from **kv-lrnmetrics-prod** instead of
living in `appsettings.Local.json` on each server.

| | |
|---|---|
| Vault | `kv-lrnmetrics-prod` (`https://kv-lrnmetrics-prod.vault.azure.net/`) |
| Resource group | `lrn-reporting-apps`, region `eastus` |
| Subscription | `859e61e5-0b11-4d89-a735-92a9f7b787be` |
| Tenant | `b13b3679-23ed-440d-bb61-bef34ac2ddf3` |
| Authorization | **RBAC** (`enableRbacAuthorization: true`, `accessPolicies: []`) |

Wired into [LRN.ReportsApi/Program.cs](../../LRN.ReportsApi/Program.cs) and
[LabMetricsDashboard/Program.cs](../../LabMetricsDashboard/Program.cs) — the two apps that read these
settings. `LRN.ReportWorker` needs no change: it takes each lab's connection string from that lab's
config JSON, not from `ConnectionStrings`.

## Secret naming

The provider's default `KeyVaultSecretManager` maps `--` in a secret name to `:` in a configuration
key. Nothing in this repo does that translation, which makes it an undeclared contract between the
names typed into the vault and the keys the code reads — so it is pinned by
[KeyVaultSecretNamingTests](../../tests/LRN.ReportsApi.Tests/KeyVaultSecretNamingTests.cs), which runs
offline against the real `KeyVaultSecretManager`.

| Secret name in the vault | Configuration key | Read as |
|---|---|---|
| `ConnectionStrings--DefaultConnection` | `ConnectionStrings:DefaultConnection` | `GetConnectionString("DefaultConnection")` |
| `ConnectionStrings--NWLConnection` | `ConnectionStrings:NWLConnection` | `GetConnectionString("NWLConnection")` |
| `DenialWorkflowAuth--JwtSigningKey` | `DenialWorkflowAuth:JwtSigningKey` | `configuration["DenialWorkflowAuth:JwtSigningKey"]` |
| `ExternalApiClients--Clients--0--ClientId` | `ExternalApiClients:Clients:0:ClientId` | bound into `ExternalApiClientOptions` |

Indexed names merge by position across providers: the vault supplies `Clients[0]`'s `ClientId` and
`SecretHash` while `appsettings.json` supplies the same element's `DisplayName` and `Roles`, and
they combine into one client. That merge is covered by a test too — if it broke, the ETL client
would authenticate with no roles rather than fail outright.

## Precedence

Providers are added in this order, last one winning:

1. `appsettings.json` → `appsettings.{Environment}.json`
2. `appsettings.Local.json` (gitignored, per machine)
3. **Azure Key Vault**

The vault is deliberately last. Reversed, a stale connection string left behind in a server's
`appsettings.Local.json` would quietly outrank the vault's — the kind of drift that is very hard to
spot from the outside. Once a server is on the vault, delete the `ConnectionStrings` and
`DenialWorkflowAuth` blocks from its `appsettings.Local.json` rather than leaving them shadowed.

Secrets are read **once at startup**. There is no reload interval, on purpose: most repositories are
scoped and would pick a rotated value up mid-flight, but the payer-mapper repositories are
singletons holding the connection string they were constructed with — a live reload would leave the
app half on the old credential and half on the new. **Restart both apps after rotating anything.**

## Authentication

`DefaultAzureCredential`, so one build authenticates everywhere it is deployed: an assigned managed
identity in Azure, `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_CLIENT_SECRET` where a service
principal is used instead, or the developer's `az login` / Visual Studio account locally.

The identity needs **Key Vault Secrets User** on the vault. The vault uses RBAC, so adding an access
policy will not work:

```powershell
az role assignment create `
  --role "Key Vault Secrets User" `
  --assignee <identity-object-id> `
  --scope "/subscriptions/859e61e5-0b11-4d89-a735-92a9f7b787be/resourceGroups/lrn-reporting-apps/providers/Microsoft.KeyVault/vaults/kv-lrnmetrics-prod"
```

## Failure behaviour

If `KeyVault:Uri` is set and the vault cannot be read, **startup throws**. Booting anyway would mean
running with no connection strings and no JWT signing key, and every request would then fail deep
inside a repository reporting a missing connection string — pointing at the wrong thing entirely.
The thrown message names the vault and the RBAC role instead, with the credential error as its inner
exception.

`KeyVault:Uri` is also validated as an absolute `https` URI before use, because the value is
hand-maintained in `appsettings.json` and was briefly committed as `"https: //kv-..."` — a typo that
would otherwise have surfaced much later as a connection string that was simply absent.

## Running without the vault

Set `KeyVault:Uri` to an empty string in `appsettings.Local.json` (or `KeyVault__Uri` in the
environment). An empty or missing URI skips the provider entirely and the app runs on local
secrets — verified: the app starts normally with no vault access.

**`appsettings.Local.json` must never reach a server.** The Web SDK's default content glob was
publishing it, so a deployment would have carried a developer's copy of the production connection
strings *and* that machine's blank `KeyVault:Uri` — quietly switching Key Vault off on the server it
landed on, with no error to notice. Both web projects now set
`<Content Update="appsettings.Local.json" CopyToPublishDirectory="Never" />`; the file still lands in
the build output for local debugging. If you add a third app, carry that line over. The file is also
gitignored now, which the `Program.cs` comments had claimed all along without a rule to back it.

## Not yet migrated

These read `ConnectionStrings` from their own `appsettings.json` and were left alone:
`LRN.DenialDatabaseWorker`, `LRN.MasterFileProcessorWorker`, `LRN.PayerPolicyMapper`,
`LRN.AveragesImport`, `CaptureDataApp`, `ClaimLineCSVDataCapture`.
