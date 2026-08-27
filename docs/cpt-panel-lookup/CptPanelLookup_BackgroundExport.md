# CPT & Panel Lookup — background export

**Version:** 1.0 · **Status:** Implemented, pending the deployment steps below · **Last reviewed:** 2026-08-16

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

Until **both** of these are done the page falls back to the old direct download. That fallback
is silent by design, so "the export still downloads on the page" is the symptom of a missing step
here, not of a code problem.

1. **Create `{LabConfigFolder}\LRNMaster.json`** on both the web server and the report-worker
   server, in the same folder as the other lab configs
   (`LabConfig:LabConfigFolder` / `ReportWorker:LabConfigFolder`). A ready copy is in
   [LRNMaster.json](LRNMaster.json) — set the connection string for the target
   environment:

   ```json
   {
     "LRNMaster": {
       "DBEnabled": true,
       "LineClaimEnable": false,
       "DbConnectionString": "Server=...;Initial Catalog=LRNMaster;..."
     }
   }
   ```

   The root property **must** equal the file name (`LRNMaster`) — `LabDbConfigLoader.Load`
   looks the section up by lab name and returns null otherwise.

2. **Deploy the report-queue objects to LRNMaster.** As of this writing LRNMaster has
   `CPTAverage` and `PanelAverage` but **no** `UserReqReports` and no queue procedures, so this
   step is required. Run all three, in order, against LRNMaster — they are idempotent:

   ```
   SQL_Scripts/UserReqReports/01_UserReqReports_Schema.sql
   SQL_Scripts/UserReqReports/02_UserReqReports_Procs.sql
   SQL_Scripts/UserReqReports/03_Add_ProgressPercent.sql
   ```

   Without them the queue call fails with SQL error 208 / 2812. `AnalyticsController.QueueExport`
   catches exactly those two and returns 400, which the page treats as "queue unavailable" and
   falls back to the direct download — so the user still gets a file, just a synchronous one.

   Verify with:

   ```sql
   SELECT (SELECT COUNT(*) FROM sys.tables     WHERE name = 'UserReqReports')  AS QueueTable,
          (SELECT COUNT(*) FROM sys.procedures WHERE name LIKE '%UserReqReport%') AS QueueProcs;
   ```

3. `LRNMaster` is already added to `ReportWorker:Labs` in
   [LRN.ReportWorker/appsettings.json](../../LRN.ReportWorker/appsettings.json) (a lab **name**
   list, not a connection string), and `Analytics:SharedReportLab` is set in
   [LabMetricsDashboard/appsettings.json](../../LabMetricsDashboard/appsettings.json).
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

## The 1,000-row truncation (fixed)

Exports returned only 1,000 rows regardless of filters. `ExportCptAsync` set
`PageSize = ExportRowCap` and then called the public `GetCptAsync`, which starts with
`Normalise(query, MaxPageSize)` — clamping it straight back to the UI's 1,000-row page limit. The
workbook looked complete, so nothing surfaced the loss.

The read now takes its ceiling from the caller: `ReadCptExportRowsAsync` / `ReadPanelExportRowsAsync`
normalise against `ExportRowCap` instead of `MaxPageSize`, and use a 1,800s command timeout rather
than the 120s page timeout, since a full unfiltered read is far heavier than a page. Guarded by
[CptLookupExportPagingTests](../../tests/LRN.ReportsApi.Tests/CptLookupExportPagingTests.cs), which also
asserts the export cap stays above the page limit — if the two ever converge, exports truncate again.

This affected the synchronous download too, so it was never specific to the queued path.

## The 100,000-row truncation (fixed)

The same loss at a different ceiling: with the paging bug gone, exports stopped at `ExportRowCap`,
which was 100,000. `CPTAverage` / `PanelAverage` are around 300k rows, so every unfiltered export
came down as a third of the table in a workbook that opened cleanly and looked complete.

`ExportRowCap` is now **1,048,575** — Excel's own per-sheet limit (1,048,576 rows, one of them the
header), so it is no longer a number anyone has to tune against table growth; only a filter shortens
an export now.

`BuildExcel` had to hold up at that scale, since a full extract is ~300k rows x ~27 columns:

* number formats are applied once per **column**, before any data cell exists, and inherited by the
  cells written after. They were being assigned per cell, resolving a style eight million times —
  including for the empty cells the writer skipped.
* the autofilter range is stated explicitly instead of derived from `RangeUsed()`, which scans the
  whole sheet to find its own bounds.
* column widths are still sized off the first 250 rows only.

ClosedXML still holds the whole workbook graph in memory, so a full 300k-row export is the heaviest
thing the worker builds. `MaxConcurrentReports` bounds the worst case. If these tables grow past
roughly a million rows the fix is not a bigger cap — it is moving this generator to the streaming
`OpenXmlRowStreamer` path that LIS Summary uses.

## Known limits

* `SqlCptLookupRepository.MaxExportRows` is Excel's sheet limit, not a filter. When an export hits
  it the generator logs a warning naming the cap, so a truncated workbook is visible in the worker
  log rather than silent.
* Output file name is `CptLookup_<Scope>[_<Window>].xlsx` / `PanelLookup_…`, where `<Scope>` is
  the lab name, `Lab<id>` when the name could not be resolved, or `AllLabs` when unfiltered.
