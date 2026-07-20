# LRN Averages Import Worker Service

.NET 8 Worker Service that imports weekly lab average CSV files (CptAverage / PanelAverage)
into the `LRNMaster` SQL Server database. Runs one import cycle immediately on startup and
then every `ImportSettings:IntervalMinutes` (default 60).

## How a cycle works

1. Calls the existing stored procedure `sp_GetRecentSuccessRunByLab` and keeps only rows
   with `OverallStatus = 'SUCCESS'`.
2. Resolves each SP `LabName` (e.g. `Augustus Labs`) against `ImportSettings:Labs`, which
   supplies the numeric `LabId` and on-disk `FolderName` (e.g. `Augustus`). SP labs with
   no config entry are logged as warnings and skipped; configured labs with no SP row are
   logged at info level.
3. For each mapped lab, searches
   `<BasePath>\<FolderName>\<year>` recursively (year derived from the RunId's `yyyyMMdd`
   prefix; falls back to the whole lab folder) for
   `{RunId}_*_CptAverage_*.csv` and `{RunId}_*_PanelAverage_*.csv`.
   `.xlsx` matches are detected but skipped with a warning (not yet supported).
4. Per file type, imports atomically (see below). A missing file type or a failed lab is
   logged and never stops the remaining files/labs.

### Dedup / replace logic

- Before importing, the service checks `AverageImportLog` for a `Success` row with the same
  `RunId + LabId + FileType`. If found, the file is **skipped** ("already imported").
  A previous `Failed` row does **not** block a retry.
- The import itself is one SQL transaction:
  1. `DELETE FROM CPTAverage / PanelAverage WHERE LabID/LabId = @LabId` (full replace per lab)
  2. `SqlBulkCopy` of all parsed rows (batch size `BulkCopyBatchSize`, explicit column mappings)
  3. `INSERT` of the `Success` row into `AverageImportLog`
- On any error the transaction rolls back (target table left untouched) and a `Failed` row
  is written to `AverageImportLog` outside the transaction.

### CSV parsing notes

- In both files the first column is named `LabID` but contains the lab **name**; it is mapped
  to the `LabName` column. The numeric `LabID`/`LabId` always comes from the config mapping.
- Dates are `M/d/yyyy`; blanks become `NULL`. `AvgUnits` may arrive as a decimal string and
  is rounded to int. Rows that fail to parse are logged with line number and skipped; a file
  aborts (and is logged as `Failed`) once bad rows exceed `MaxBadRowsPerFile` (default 50).

## Build

```powershell
cd LRN.AveragesImport
dotnet build -c Release
```

## Database setup

Run once against `LRNMaster` (the only new object; target tables and the SP already exist):

```
Database\01_AverageImportLog.sql
```

## Configuration

Edit `LRN.AveragesImport.Worker\appsettings.json`:

- `ConnectionStrings:LRNMaster` — SQL Server connection string.
- `ImportSettings:BasePath` — root of the averages output folders.
- `ImportSettings:Labs` — **fill in the real lab list.** `LabName` must match the SP output
  (compared case-insensitively), `FolderName` is the disk folder / filename segment, and
  `LabId` is the numeric id written to the target tables.

## Install as a Windows Service

```powershell
dotnet publish LRN.AveragesImport.Worker -c Release -o C:\Services\LRN.AveragesImport

sc.exe create "LRN Averages Import Service" binPath= "C:\Services\LRN.AveragesImport\LRN.AveragesImport.Worker.exe" start= auto
sc.exe description "LRN Averages Import Service" "Imports weekly lab average CSVs into LRNMaster"
sc.exe start "LRN Averages Import Service"
```

Uninstall:

```powershell
sc.exe stop "LRN Averages Import Service"
sc.exe delete "LRN Averages Import Service"
```

Logs are written to `logs\averages-import-<date>.log` next to the executable (rolling daily,
30 days retained) and to the console when run interactively (`dotnet run`).

## Project layout

```
LRN.AveragesImport.sln
├── LRN.AveragesImport.Worker/   host: DI wiring, PeriodicTimer loop (AveragesImportWorker)
├── LRN.AveragesImport.Core/
│   ├── Models/                  LabRunInfo, CptAverageRecord, PanelAverageRecord, ImportResult
│   ├── Csv/                     CsvHelper class maps + blank-to-null type converters
│   ├── Services/                LabRunProvider, FileLocator, CsvReaderService, ImportService
│   └── Data/                    SqlConnectionFactory
└── Database/01_AverageImportLog.sql
```

`ImportService` accepts already-parsed records plus a `LabRunInfo`, so parsing and DB work
are independently unit-testable.
