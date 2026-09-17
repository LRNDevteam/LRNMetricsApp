# Running the stack locally

Both apps run on a developer machine with no deployment step. If you have been deploying
in order to see a change, the cause is almost always the lab config folder — see
[The lab picker is empty](#the-lab-picker-is-empty).

## Start everything

```powershell
.\scripts\Start-LocalStack.ps1
```

That opens a window per app and the browser on the dashboard. Individually:

```powershell
.\scripts\Start-LocalStack.ps1 -Api          # just LRN.ReportsApi
.\scripts\Start-LocalStack.ps1 -Dashboard    # just LabMetricsDashboard
.\scripts\Start-LocalStack.ps1 -NoBrowser    # both, no browser
```

Or straight from the SDK / Visual Studio (F5 on either project works too):

```powershell
dotnet run --project LabMetricsDashboard\LabMetricsDashboard.csproj
dotnet run --project LRN.ReportsApi\LRN.ReportsApi.csproj
```

| App | URL | Notes |
|---|---|---|
| LabMetricsDashboard | https://localhost:57996 (http 57997) | LIS Summary, Denial Summary, Denial Workflow UI |
| LRN.ReportsApi | http://localhost:62409 (https 62408) | Swagger at `/swagger`, health at `/health` |

**Run the API alongside the dashboard.** The Denial Workflow screens and the Report
Control Board read from it, so with the API down those pages come up empty while the rest
of the site looks fine — which reads as "only works when deployed".

## What each app needs

### `appsettings.Local.json` (both apps, gitignored)

Holds every connection string, `DenialWorkflowAuth:JwtSigningKey` and `ImportApiKey`, and
blanks `KeyVault:Uri` so the app skips Azure Key Vault instead of failing on a machine with
no Azure credential. Without this file the app starts and then fails on any page that reads
data, usually as `DefaultConnection not configured`.

The dashboard's copy also carries:

- `DenialWorkflowApi:BaseUrl` → `http://localhost:62409`, instead of the tracked
  `https://localhost//LRNApi`, which is the deployed IIS path and 404s locally.
- `LabConfig:LabConfigFolder` → the local Configs folder, see below.

`JwtSigningKey` must be byte-identical in both apps. The dashboard issues the workflow
token and the API validates it; if they differ, every workflow request comes back 401 and
the user is bounced to the login page.

### Lab config folder

Each lab is a JSON file named after it — `Cove.json`, `NorthWest.json` — with a root
section matching the lab name, holding that lab's `DbConnectionString` and its `Enable*`
feature toggles. `LabConfig:Labs` in `appsettings.json` lists which ones load.

On this machine they live at:

```
C:\LRN-Files\ApplicationFolder\PredictionAnalysis_Automation\LabMetricsApplication\Configs\
```

`LRN.ReportsApi` already points there in its tracked `appsettings.json`. The dashboard's
tracked value is the **deploy server's** `E:\LRN-Data\...` path, so it has to be overridden
per machine in `appsettings.Local.json`:

```json
"LabConfig": {
  "LabConfigFolder": "C:\\LRN-Files\\ApplicationFolder\\PredictionAnalysis_Automation\\LabMetricsApplication\\Configs\\"
}
```

## Troubleshooting

### The lab picker is empty

This is the one that sends people back to deploying. The dashboard starts fine and the
login page renders, but no lab can be selected and every report is blank.

Startup logs it:

```
warn: Startup[0]
      Some lab config files were skipped due to missing/invalid JSON: Cove, NorthWest, ...
```

The folder in `LabConfig:LabConfigFolder` does not exist on this machine. Override it in
`appsettings.Local.json` as above and restart. Since the folder is checked at startup, a
missing one now also logs the folder by name.

### Denial Workflow or Report Control Board is empty

`LRN.ReportsApi` is not running, or `DenialWorkflowApi:BaseUrl` still points at the
deployed path. Check `http://localhost:62409/health` returns 200.

### Signed out immediately on a workflow screen

`DenialWorkflowAuth:JwtSigningKey` differs between the two `appsettings.Local.json` files.
Copy one into the other.

### `DefaultConnection not configured`

No `appsettings.Local.json`, or `KeyVault:Uri` is set on a machine without an Azure
credential. Blank the URI to fall back to the local secrets.

### A database is unreachable

The lab databases are on `ReportEngine\SQLEXPRESS`; `LRNMaster` and `NWL_LRN` are on the
Azure SQL managed instance. Both need network reach from your machine:

```powershell
Test-NetConnection ReportEngine -Port 1433
Test-NetConnection lrnanalytics-sqlmi.public.4e3a76f4ed99.database.windows.net -Port 3342
```

### HTTPS certificate warning

```powershell
dotnet dev-certs https --trust
```

## A caution on data

The per-lab configs point at the same databases the deployed site uses, so local runs read
real data and — for anything that writes, such as a Denial Insight import or save — write
to it as well. `LRNMaster` in particular holds users, menus and role mappings. Local is not
a sandbox; treat a write here as a write in production.
