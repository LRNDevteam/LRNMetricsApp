# Database scripts

Every SQL script in the repository lives here, in one folder per project. The project folders hold only application code; their former script folders (`Sql\`, `SqlScripts\`, `sql\`, `Database\`, `Sample\SelectScript\`) were moved here unchanged, with history kept.

| Folder | Was | Scripts for |
|---|---|---|
| `CaptureDataApp\` | `CaptureDataApp\Sql\` | Coding capture tables, aggregates and validation procedures |
| `ClaimLineCSVDataCapture\` | `ClaimLineCSVDataCapture\Sql\` | Claim/line tables, TVPs and bulk-insert procedures, and the per-lab report procedures (one sub-folder per lab: `Augustus\`, `BeechTree\`, `Cove\`, ...) |
| `LabMetricsDashboard\` | `LabMetricsDashboard\Sql\` and `LabMetricsDashboard\SqlScripts\` | Dashboard procedures, menus, denial category master, demo lab; `ClaimLineDetails_SPs\`, `LIMSScript\`, `Select_Script\` |
| `LRN.AveragesImport\` | `LRN.AveragesImport\Database\` | Averages import tables and report-type rows |
| `LRN.DenialDatabaseWorker\` | `LRN.DenialDatabaseWorker\Sql\` | Denial worker re-run requests, notification and mail queues |
| `LRN.MasterFileProcessorWorker\` | `LRN.MasterFileProcessorWorker\sql\` and `Sample\SelectScript\` | Process logs, file status, LIMS master, re-run requests; per-lab setup (`AnalyzePathology\`, `WellHealth\`, `CoreBio\`, `TexasDiagnostic\`); `SelectScript\` reference queries |
| `LRN.ProductionReports\` | `LRN.ProductionReports\Sql\` | Production report procedures |
| `LRN.ReportsApi\` | `LRN.ReportsApi\Sql\` | Denial Workflow, Denial Mapper, Payer Master, user mail, menus; `ArReports\`, `DenialChanges\`, and `ArWorkbench\` (see below) |
| `PredictionAnalysisApp\` | `PredictionAnalysisApp\Database\` | Prediction tables and procedures |
| `Shared\` | `SQL_Scripts\` and the root `Sql\` | Scripts not owned by one project: Denial Workflow object bundles, executive summary drill-through, notes insights, user report queue |

## AR Workbench

`LRN.ReportsApi\ArWorkbench\` separates the two databases:

```
1_RUN_IN_LRNMASTER_ARWB_Setup.sql      run first, once, in LRNMaster
2_RUN_IN_EACH_LAB_DB_ARWB_Setup.sql    run second, in every lab database
LRNMaster\                             source scripts merged into file 1
LabDatabase\                           source scripts merged into file 2 (00 destructive and 08 optional run on their own)
```

Edit the source scripts, then run `Build-MergedScripts.ps1` in that folder to regenerate the two merged files. Details: [`LRN.ReportsApi/ArWorkbench/README.md`](LRN.ReportsApi/ArWorkbench/README.md).

## Adding a script

Put it under `Database\<Project>\` (a lab-specific script under that project's lab sub-folder), number it in run order, and say in its header which database it runs in (LRNMaster or the lab database).
