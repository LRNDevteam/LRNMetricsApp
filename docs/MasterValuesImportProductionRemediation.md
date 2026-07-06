# Master Values import production remediation

## Deployment configuration

Create a replacement Teams workflow/webhook and configure it outside source control:

```text
DenialWorkflowSupport__TeamsWebhookUrl=<replacement webhook URL>
```

The rejected webhook was removed from `LRN.ReportsApi/appsettings.json`. Restart the API after setting the environment variable.

API stdout is configured for:

```text
C:\LRN-Files\ApplicationFolder\DenialWorkFlow\Logs\stdout
```

From an elevated PowerShell session, grant the API app pool access (replace the example pool name):

```powershell
.\tools\Grant-LrnApiLogPermissions.ps1 -AppPoolName 'LRNApi'
```

## Before retrying a timed-out import

Run `LRN.ReportsApi/Sql/MasterValues_Insurance_Import_Audit.sql` against `LRNMaster`. Adjust `@ImportWindowStartUtc` to the failed request's UTC start time, review rows inserted or updated during that window, and resolve unexpected duplicates before uploading again.

After deployment, new insurance-payer imports use a temporary staging table, `SqlBulkCopy`, a serializable transaction, and set-based update/insert operations. A cancellation rolls back the complete database phase.
