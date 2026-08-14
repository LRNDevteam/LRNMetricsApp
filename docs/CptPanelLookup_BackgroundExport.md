# CPT & Panel Lookup — background export

## Why this changed

The **Export to Excel** button on `Analytics > CPT & Panel Lookup` used to download
synchronously: the dashboard called `GET /api/analytics/{cpt|panel}-lookup/export` on
LRN.ReportsApi, which had to run the lookup query *and* build the whole workbook inside a
single HTTP request.

An unfiltered export (no lab, no window) does not finish inside the dashboard's 120-second
`HttpClient` timeout, so the user got an exception instead of a file:

```
System.Threading.Tasks.TaskCanceledException: The request was canceled due to the
configured HttpClient.Timeout of 120 seconds elapsing
   at LabMetricsDashboard.Services.LabAnalyticsApiClient.ExportAsync(...) line 78
   at LabMetricsDashboard.Controllers.AnalyticsController.ExportCpt(...) line 76
```

The export now runs as a queued background report in **LRN.ReportWorker**, like the
Production, Collection, LIS and Denial downloads. There is no request clock, and the file
lands in the user's **Reports** panel.

## The shared LRNMaster queue lab

Every other queued report belongs to one lab, and `dbo.UserReqReports` lives in that lab's
database. CPT & Panel Lookup does not fit that shape:

* its data is in **LRNMaster** (`CPTAverage`, `PanelAverage`, `LabModes`, `LabMedians`), and
* its Lab filter is **optional** — the unfiltered export spans every lab.

So the job is queued against a shared pseudo-lab, `ReportQueueLabs.Master` (`"LRNMaster"`),
whose `DbConnectionString` points at LRNMaster. That is also how the connection reaches
LRN.ReportWorker: it arrives on the claimed job's own lab config, exactly like every other
report. **No connection string was added to `LRN.ReportWorker/appsettings.json`.**

The shared lab is deliberately **not** listed in `LabConfig:Labs`. Controllers build their
lab pickers from `LabSettings.Labs.Keys`, so listing it there would offer "LRNMaster" as a
selectable lab on every dashboard. `UserReportService` loads it separately from its own JSON
and treats it as a queue-only lab.

## Deployment steps

1. **Create `{LabConfigFolder}\LRNMaster.json`** on both the web server and the report-worker
   server, in the same folder as the other lab configs
   (`LabConfig:LabConfigFolder` / `ReportWorker:LabConfigFolder`):

   ```json
   {
     "LRNMaster": {
       "DBEnabled": true,
       "DbConnectionString": "Server=...;Database=LRNMaster;..."
     }
   }
   ```

2. **Deploy the report-queue objects to LRNMaster** — the same `dbo.UserReqReports` table and
   queue stored procedures each lab database already has. Without them the queue call fails
   with SQL error 208 / 2812.

3. `LRNMaster` is already added to `ReportWorker:Labs` in
   [LRN.ReportWorker/appsettings.json](../LRN.ReportWorker/appsettings.json) (a lab **name**
   list, not a connection string), and `Analytics:SharedReportLab` is set in
   [LabMetricsDashboard/appsettings.json](../LabMetricsDashboard/appsettings.json).
   Nothing further to change unless the lab is renamed.

4. Publish **LRN.ReportWorker** and **LabMetricsDashboard**.

### If step 1 or 2 is skipped

Nothing breaks. `UserReportService` logs a warning at startup, `BackgroundExportEnabled`
comes through as `false`, and the page falls back to the old direct download — which still
works for filtered exports and still times out for unfiltered ones.

## What was added

| Project | Change |
|---|---|
| `LRN.ReportQueue.Shared` | `ReportTypes.CptLookup` / `PanelLookup`, `ReportQueueLabs.Master`, `CptLookupReportFilters` |
| `LRN.ReportsApi` | `SqlCptLookupRepository(string connectionString)` ctor; `ReadCptExportRowsAsync` / `ReadPanelExportRowsAsync` split out from the export methods; `BuildCptExcel` / `BuildPanelExcel` / `MaxExportRows` exposed |
| `LRN.ReportWorker` | Project reference to `LRN.ReportsApi`; `Generators/CptLookupReportGenerator.cs` registered once per tab |
| `LabMetricsDashboard` | `AnalyticsController.QueueExport`; `UserReportService.SharedReportLab` + queue-lab fan-out; `UserReportsController.Queue` mappings; export button queues instead of downloading |

The workbook is byte-identical to the synchronous one — the column definitions live only in
`SqlCptLookupRepository`, and the worker calls the same builders.

## Known limits

* `SqlCptLookupRepository.MaxExportRows` is still **100,000**. It is a ClosedXML memory guard,
  not a filter. Backgrounding removed the *timeout*, not the cap. When an export hits it the
  generator logs a warning naming the cap, so a truncated workbook is visible in the worker log
  rather than silent. Raising it means moving this export to the streaming `OpenXmlRowStreamer`
  path that LIS Summary uses.
* Output file name is `CptLookup_<Scope>[_<Window>].xlsx` / `PanelLookup_…`, where `<Scope>` is
  the lab name, `Lab<id>` when the name could not be resolved, or `AllLabs` when unfiltered.
