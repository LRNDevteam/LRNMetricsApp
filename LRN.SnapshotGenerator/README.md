# LRN.SnapshotGenerator

Windows service ("LRN - Snapshot Generator") that keeps a weekly Parquet snapshot of each lab's
LRN Metrics page reports, so earlier weeks stay readable after the lab's tables move on.

| Report | ReportCode | Captured when ReportsWorkflowTracker shows Success for |
| --- | --- | --- |
| Executive Summary | `EXECSUMMARY` | `Executive Summary` |
| LIS Summary | `LISSUMMARY` | `LIS Summary` |
| Production Summary | `PRODSUMMARY` | `Production Summary` |
| Collection Summary | `COLLSUMMARY` | `Collection Summary` |
| Denial Summary | `DENIALSUMMARY` | `Denial Report` |
| Denial Insight tab (uploaded) | `DENIALINSIGHT` | no tracker report: each Denial Insight import, row edit, delete or copy |

The Line Level, Claim Level and LIMS tables are snapshotted by the master file processor (step 88);
both services write into the same run folder and the same LRNMaster index.

## What each report holds

- **Executive Summary:** the main grid. For labs with highlight tabs, those tabs are the Production,
  Collection, LIMS and Denial pages of the same run, showing only some of their tabs. They are captured
  as those reports (`PRODSUMMARY`, ...) with the Executive Summary, unless already captured for the run.
  The Executive Summary display copy lists them under `HighlightTabs`. The tab list comes from
  `ExecutiveSummaryHighlightsExcel.HighlightTabs`, which the page itself also uses.
- **LIS Summary:** the summary pivot and key metrics only. The line-level LIMS data is the master data
  snapshot (`LIMS`), so it is not repeated.
- **Denial Summary:** tiles, Monthly, Weekly and the Denial List / Plan Type / Facility tabs, with the
  lab's own week start, date and balance column (`LabConfig` in appsettings.json). The Denial Insight
  rows are left out: they are the client's upload, so they are `DENIALINSIGHT`.
- **Denial Insight:** the Current Week and Previous Week rows. LabMetricsDashboard writes a request to
  `dbo.ReportSnapshotRequest` on every import, row edit, delete and Copy to Previous Week. The tab is
  captured for the run the lab database holds once the request has been quiet for
  `RequestSettleSeconds`, so a burst of edits is one snapshot. The latest capture of the week replaces
  the earlier one.
- **Key Insights (`LISINSIGHT`, `PRODINSIGHT`, `COLLINSIGHT`):** the LIS, Production and Collection pages'
  Key Insights & Highlights panel: the loaded week's active insights and the report's templates
  (`ReportInsightsSnapshotModel`). Users write them in the live report, so they are captured the Denial
  Insight way: `NotesController` files a request on every insight save or delete, and the panel is
  captured for the run the lab database holds once it has been quiet. The capture only reads; it never
  archives earlier weeks' insights as the page does.

## Re-running a week

- **A re-run gets a new RunId.** After the new run's master data snapshot succeeds, retention deletes
  the earlier run of the same week: all of its files in the container, then its index rows. The
  generated reports are captured again for the new RunId when they show Success.
  - The Denial Insight snapshot is the client's upload and is not regenerated. So before the old run
    is deleted, a request is filed and the tab is captured again under the new run.
  - If the new run's snapshot fails, the earlier run is kept.
- **The same RunId again:** every file under the run's prefix is deleted before the new files are
  written, so nothing stale or unindexed is left in the container.

## Report logic changes

Each report's display copy records the logic it was produced with:
- the LRN Metrics build;
- every stored procedure, view and function of the lab database the report ran, found from SqlClient's
  own events, plus what those call, five levels deep, each with a SHA-256 of its definition.

The next week's snapshot is compared with it. A difference is logged as a warning and shown on the
snapshot page, e.g. `Changed: dbo.usp_GetTD_LisSummary (modified 2026-11-04 09:12 UTC)`.

A snapshot is never recomputed. When a report gains a new split, the snapshots from then on have it and
the earlier ones keep the data and logic version they were taken with.

## Display copy (for showing a past week in the page's own UI)

`<RunId>_<WeekRange>_<REPORTCODE>_PageModel.json.gz` (ResultSetName `PageModel`) is the page's own view
model as gzip JSON:
- `ModelType` names the .NET type, e.g. `LabMetricsDashboard.Models.PhiExecutiveSummaryViewModel`.
- `Model` binds back to that type, so the page's existing views can render it.
- The envelope also carries the run, the trigger, `Logic`, `LogicChanges` and `HighlightTabs`.

Enums are written as names. A view model property added later is absent in older files and binds as its
default. Views must treat such a property as "not in that week's report", not as zero.

The JSON settings (`ReportSnapshotJson.Options`, including value tuples such as the Executive Summary's
`(Year, Month)` columns) and the Denial Insight model live in LabMetricsDashboard, so the writer and the
viewer cannot drift apart.

## Viewing a snapshot

LRN Metrics, **Master Values > Report Snapshots**, lists the runs by lab. Open a run, then any file opens
in a new window (`ReportSnapshotViewerController`):
- **Open report** (the PageModel file): the report's own page views, bound to that week's view model, in
  snapshot mode. Shown read-only, with no menu, filters or exports, the Key Insights as captured for the
  week (never the live notes), and a banner with the lab,
  week, Run ID and capture time. The lazy tabs load from the snapshot, never from the lab database, and
  any other request from the page is blocked.
  - The Executive Summary's highlight tabs frame the same run's Production, Collection, LIS and Denial
    snapshots.
  - The Denial Summary shows the run's Denial Insight snapshot as its Denial Insight tab. It has no
    Claim Level tab, because that is live claim data.
- **Open data** (any Parquet file, report sections and Line Level / Claim Level / LIMS alike): a paged
  table, 500 rows per page.

Only these view model types are bound (`ReportPageSnapshotReader`); a file naming another type is refused.

The page is for the labs' own users as well as LRN staff: the lab chosen in the header's lab selector, its
last 6 weeks, the latest run of a re-run week only, scoped to the user's assigned labs. **Master Data
Snapshots** stays the full log (every run and file, Parquet included) for the snapshot admins.

- **Data columns** (Line Level, Claim Level, LIS Data): the week's master data files as paged tables. These
  three are open to the lab's own users; the report sections' Parquet files stay admin-only.
- **Key Insights** (the lightbulb in a LIS / Production / Collection cell): the week's saved insights on their
  own. The report snapshot itself shows the same insights in its Key Insights panel. Both are read-only: no
  Add Insight, edit, delete or archive, and the live notes are never read. A week without a capture shows
  "No insights were saved for this week".

- **Compare** (a row's Compare button, `MasterValues/ReportSnapshotCompare`): two weeks of one report side by
  side, each the real report page, with the two kept on the same tab and scroll position. **Changes** lists every
  table of the report with the rows matched by label, the change and %, and a paired bar chart per table.
  Headline totals show above both views. The tables come from the view models (`ReportSnapshotComparer`), so a
  column a report gains later is compared too.
- **Download** (a report's download button): queued as `ReportSnapshot` in the lab's report queue and built
  by LRN.ReportWorker with the report's own Excel builder from the snapshot. The file appears in the Reports
  panel like any other download. Summary sheets only: the raw extracts are the master data snapshots, and the
  Insights sheet, the Executive Summary highlight tabs and the Denial claim-level sheet read today's data, so
  they are left out.

**LRN.ReportWorker needs** (for downloads): `KeyVault:VaultUri` in its appsettings.json, with the server's managed
identity granted **Key Vault Secrets User** on that vault and **Storage Blob Data Reader** on the container. The
worker loads only the `MasterDataSnapshot--*` secrets from it, never the connection strings.

**The web app needs:**
- the same Key Vault secrets as this service, `MasterDataSnapshot--BlobServiceUri` and
  `MasterDataSnapshot--ContainerName`, in its own vault;
- **Storage Blob Data Reader** on the container for its managed identity (read only);
- the menu item, from `Database/LRN.ReportsApi/DynamicMenu_Setup.sql`.

## How a snapshot is taken

1. Every `ReportSnapshot:PollMinutes` it reads `LRNMaster.dbo.ReportsWorkflowTracker` for each enabled
   lab's reports that show **Success**, within `LookbackDays`. The tracker's timestamp column is looked up
   at start (first of UpdatedOn, ModifiedOn, ..., CompletedOn, CreatedOn); the log names the one used.
2. It skips a report already captured for that Success: same RunId and the same tracker timestamp as
   the capture stored. A re-run of the report writes a new timestamp and is captured again. The
   timestamp is only compared with itself, never with a clock, because writers stamp it in IST or UTC.
   A Success the service has just seen is captured once it has seen it for `SettleMinutes` (by its own
   clock), so in practice on the next poll.
3. **Stale check.** A page always reads the lab's *current* tables. So the report is captured only while
   the RunId is still the run loaded in the lab database (`dbo.ClaimLevelData.RunId`). An older run is
   logged once as superseded and skipped.
4. It loads the page's data **with no filters** through LRN.ReportWorker's own generator for that
   report. That is the same code the page and the queued Excel export run, so each lab's own stored
   procedures, variants and fallbacks apply. No stored-procedure list is kept here.
5. Each grid or tab of the page becomes one Parquet file:

   ```
   <container>/<Lab>/<RunId>_<WeekRange>_<REPORTCODE>_<Section>.parquet
   e.g. lrn-report-snapshots/TexasDiagnostic/R20261028TXD0377_10.16.2026-10.22.2026_COLLSUMMARY_Top5ReimbursementPct.parquet
   ```

   How a page becomes sections (`ViewModelSections`):
   - **`Summary`:** the page's totals and labels, in one row.
   - **A list of rows:** one table, with a month pivot kept as one column per month (`ByMonth.2026-09.ClaimCount`).
   - **Child rows:** their own table, linked back by `ParentRow`.
   - **Left out:** filter controls and dropdown lists.

   The raw claim and line extracts of the Excel exports are not repeated here. Those are the master
   data snapshots.
6. Each file is checked and recorded:
   - its row count is read back from the file's footer;
   - it is hashed (SHA-256), uploaded, and indexed in `dbo.ReportSnapshotFile`.

   The run row in `dbo.ReportSnapshotRun` is the master file processor's when it exists. Otherwise it is
   created here. The run is marked `Success`; an error the master step left on the row stays visible.
7. **Retention** is the same as the master data: `MasterDataSnapshot:KeepWeeks` / `KeepMonthEnd`, for the
   whole run. Keep both services' values equal.

A failed report is logged and retried on the next poll; it never blocks the other reports or labs.

## Per-lab configuration: `Labs\<LabKey>.json`

```json
{
  "LabId": 29,                    // LRNMaster LabId (tracker / LRN_Run_Log)
  "LabKey": "TexasDiagnostic",    // the lab's LRN Metrics key (ReportWorker:Labs, its per-lab config JSON)
  "Enabled": false,
  "Reports": {
    "ExecutiveSummary":  { "Enabled": true, "TrackerReportName": "Executive Summary" },
    "LisSummary":        { "Enabled": true, "TrackerReportName": "LIS Summary" },
    "ProductionSummary": { "Enabled": true, "TrackerReportName": "Production Summary" },
    "CollectionSummary": { "Enabled": true, "TrackerReportName": "Collection Summary" },
    "DenialSummary":     { "Enabled": true, "TrackerReportName": "Denial Report" },
    "DenialInsight":     { "Enabled": true },  // no tracker name: captured on upload
    "LisInsight":        { "Enabled": true },  // Key Insights: captured on each save or delete
    "ProductionInsight": { "Enabled": true },
    "CollectionInsight": { "Enabled": true }
  }
}
```

**A new lab** needs only:
- its LRN Metrics pages working (its per-lab config JSON and stored procedures);
- its key in `ReportWorker:Labs`;
- one file here.

The file is re-read on every poll, so you don't need to restart the service. A report the lab doesn't
have in LRN Metrics is logged as "not available". Set that report's `Enabled` to `false`.

## Setup

1. **LRNMaster:** run `Database/LRN.MasterFileProcessorWorker/Create_ReportSnapshots.sql` (the same index,
   plus `dbo.ReportSnapshotRequest` for the Denial Insight uploads). Run it again where it was already run.
2. **Key Vault** (`kv-lrnmetrics-prod`, or `lrn-testapp-kv` with `DOTNET_ENVIRONMENT=Test` set on the
   service): `ConnectionStrings--DefaultConnection`, `MasterDataSnapshot--BlobServiceUri`,
   `MasterDataSnapshot--ContainerName`.
3. **Access for the server's managed identity:**
   - **Key Vault Secrets User** on the vault;
   - **Storage Blob Data Contributor** on the container.
4. **Settings:**
   - `ReportWorker:LabConfigFolder` and `Labs` the same as LRN.ReportWorker's;
   - `LabConfig:DenialSummaryWeekRange` / `DenialSummaryDateColumn` / `DenialSummaryBalanceColumn` the same
     as LabMetricsDashboard's appsettings.json;
   - `ReportSnapshot:Enabled` set to `true`, and `"Enabled": true` in each lab file.
5. **Install and start the service:** `sc create "LRN - Snapshot Generator" binPath="<folder>\LRN.SnapshotGenerator.exe" start= auto`, then start it.

## Commands

- `LRN.SnapshotGenerator.exe --selftest`: converts a sample page model to Parquet and reads it back.
  No database or storage needed.
- `LRN.SnapshotGenerator.exe --once`: one tracker poll and every pending upload request, not waiting for
  requests to settle, then exits. Use it to test a lab without waiting.

Snapshots are listed in LRN Metrics under **Master Values > Master Data Snapshots**.
