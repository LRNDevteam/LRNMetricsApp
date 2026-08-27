# Production Report Excel Pre-Generation Plan

**Version:** 1.0 · **Status:** Plan — not yet implemented · **Last reviewed:** 2026-08-16

> Distinct from [AsyncReportGeneration_Design.md](AsyncReportGeneration_Design.md), which covers the
> **on-demand queued** report path (`UserReqReports` + `LRN.ReportWorker`). This document covers
> **pre-generating** the no-filter Production Report workbook at ingestion time. Both may coexist.

## Goal

Pre-generate **NO-FILTER** Production Report Excel files from `ClaimLineCSVDataCapture` after:

1. Claim/Line CSV import succeeds.
2. DB insert succeeds.
3. ProductionSummary aggregate stored procedures finish.
4. CollectionSummary aggregate stored procedures finish.

`LabMetricsDashboard` behavior:

- No filters: download latest valid pre-generated Excel file.
- Any filters: keep existing on-demand Excel generation path.
- If no valid pre-generated file exists: fall back to existing on-demand generation.

This must be failure-safe and must not block or break the current ingestion process.

---

## Architecture

```text
ClaimLineCSVDataCapture
  CSV import
    -> DB insert ClaimLevelData / LineLevelData
    -> dashboard aggregate refresh
    -> lab production summary aggregate refresh
    -> lab collection summary aggregate refresh
    -> queue NO-FILTER Excel generation background task
       -> claim duplicate lock in lab DB
       -> mark export Queued/Running
       -> build workbook using shared LabMetricsDashboard export logic
       -> save .tmp file
       -> atomic rename to .xlsx
       -> mark export Succeeded with file path, size, hash
       -> mark old succeeded files Stale

LabMetricsDashboard
  ExportProductionReportExcel
    -> detect active filters
    -> if no filters:
         query lab DB for latest Succeeded non-stale export
         verify physical file exists and is not stale
         return PhysicalFile
         if invalid/missing: mark Missing/Stale and fallback to on-demand
       if filters:
         existing on-demand code path unchanged
```

---

## Shared Excel Logic

Current workbook creation lives in:

- `LabMetricsDashboard/Services/ProductionReportExcelExportBuilder.cs`
- `LabMetricsDashboard/Models/ProductionReportViewModel.cs`
- `LabMetricsDashboard/Services/IProductionReportRepository.cs`
- `LabMetricsDashboard/Services/SqlProductionReportRepository.cs`

Recommended extraction:

```text
LRN.ProductionReports
  Models/
    ProductionReportViewModel.cs
    ProductionReportResult DTOs
    RawDataSegment.cs
  Services/
    ProductionReportExcelExportBuilder.cs
    SqlProductionReportRepository.cs
    IProductionReportRepository.cs
    ExcelTheme.cs
```

Then reference this shared project from:

- `LabMetricsDashboard`
- `ClaimLineCSVDataCapture`

Avoid referencing `LabMetricsDashboard` from `ClaimLineCSVDataCapture`, because the dashboard targets `net9.0` and is a web app. Instead, extract shared reporting code to a class library, preferably `net8.0` so both apps can consume it.

---

## Database Design

Create this table in **each lab database** because each lab has a separate DB.

```sql
CREATE TABLE dbo.ProductionReportExcelExports
(
    ExportId            BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ProductionReportExcelExports PRIMARY KEY,
    LabName             NVARCHAR(128) NOT NULL,
    ReportType          NVARCHAR(64)  NOT NULL CONSTRAINT DF_ProductionReportExcelExports_ReportType DEFAULT ('ProductionReport'),
    FilterHash          CHAR(64)      NOT NULL,
    FilterJson          NVARCHAR(MAX) NOT NULL,
    RunId               NVARCHAR(128) NULL,
    WeekFolder          NVARCHAR(256) NULL,
    SourceClaimPath     NVARCHAR(1024) NULL,
    SourceLinePath      NVARCHAR(1024) NULL,
    OutputPath          NVARCHAR(1024) NULL,
    TempOutputPath      NVARCHAR(1024) NULL,
    Status              NVARCHAR(32) NOT NULL,
    StatusMessage       NVARCHAR(2000) NULL,
    FileSizeBytes       BIGINT NULL,
    FileSha256          CHAR(64) NULL,
    RequestedUtc        DATETIME2(0) NOT NULL CONSTRAINT DF_ProductionReportExcelExports_RequestedUtc DEFAULT SYSUTCDATETIME(),
    StartedUtc          DATETIME2(0) NULL,
    CompletedUtc        DATETIME2(0) NULL,
    LastCheckedUtc      DATETIME2(0) NULL,
    StaleAfterUtc       DATETIME2(0) NULL,
    IsCurrent           BIT NOT NULL CONSTRAINT DF_ProductionReportExcelExports_IsCurrent DEFAULT (0),
    AttemptCount        INT NOT NULL CONSTRAINT DF_ProductionReportExcelExports_AttemptCount DEFAULT (0),
    CreatedUtc          DATETIME2(0) NOT NULL CONSTRAINT DF_ProductionReportExcelExports_CreatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedUtc          DATETIME2(0) NOT NULL CONSTRAINT DF_ProductionReportExcelExports_UpdatedUtc DEFAULT SYSUTCDATETIME(),

    CONSTRAINT CK_ProductionReportExcelExports_Status CHECK
    (
        Status IN ('Queued', 'Running', 'Succeeded', 'Failed', 'SkippedDuplicate', 'Stale', 'Missing')
    )
);

CREATE UNIQUE INDEX UX_ProductionReportExcelExports_CurrentNoFilter
ON dbo.ProductionReportExcelExports(LabName, ReportType, FilterHash)
WHERE IsCurrent = 1 AND Status IN ('Queued', 'Running', 'Succeeded');

CREATE INDEX IX_ProductionReportExcelExports_LatestSucceeded
ON dbo.ProductionReportExcelExports(LabName, ReportType, FilterHash, Status, IsCurrent, CompletedUtc DESC)
INCLUDE (OutputPath, FileSizeBytes, FileSha256, StaleAfterUtc, RunId, WeekFolder);
```

### Filter hash values

For pre-generated no-filter Production Report:

```text
FilterJson = {}
FilterHash = SHA256("ProductionReport|NO_FILTER|v1")
```

Use a constant so dashboard and importer agree.

---

## Optional SQL Procedures

### Claim export lock / duplicate prevention

```sql
CREATE OR ALTER PROCEDURE dbo.usp_TryStartProductionReportExcelExport
    @LabName NVARCHAR(128),
    @ReportType NVARCHAR(64),
    @FilterHash CHAR(64),
    @FilterJson NVARCHAR(MAX),
    @RunId NVARCHAR(128) = NULL,
    @WeekFolder NVARCHAR(256) = NULL,
    @OutputPath NVARCHAR(1024),
    @TempOutputPath NVARCHAR(1024),
    @ExportId BIGINT OUTPUT,
    @CanRun BIT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRAN;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.ProductionReportExcelExports WITH (UPDLOCK, HOLDLOCK)
        WHERE LabName = @LabName
          AND ReportType = @ReportType
          AND FilterHash = @FilterHash
          AND IsCurrent = 1
          AND Status IN ('Queued', 'Running', 'Succeeded')
    )
    BEGIN
        SET @CanRun = 0;
        SET @ExportId = NULL;
        COMMIT;
        RETURN;
    END;

    UPDATE dbo.ProductionReportExcelExports
       SET IsCurrent = 0,
           Status = CASE WHEN Status = 'Succeeded' THEN 'Stale' ELSE Status END,
           UpdatedUtc = SYSUTCDATETIME()
     WHERE LabName = @LabName
       AND ReportType = @ReportType
       AND FilterHash = @FilterHash
       AND IsCurrent = 1;

    INSERT dbo.ProductionReportExcelExports
    (
        LabName,
        ReportType,
        FilterHash,
        FilterJson,
        RunId,
        WeekFolder,
        OutputPath,
        TempOutputPath,
        Status,
        IsCurrent,
        AttemptCount
    )
    VALUES
    (
        @LabName,
        @ReportType,
        @FilterHash,
        @FilterJson,
        @RunId,
        @WeekFolder,
        @OutputPath,
        @TempOutputPath,
        'Queued',
        1,
        0
    );

    SET @ExportId = SCOPE_IDENTITY();
    SET @CanRun = 1;

    COMMIT;
END;
```

### Mark running/succeeded/failed

```sql
CREATE OR ALTER PROCEDURE dbo.usp_UpdateProductionReportExcelExportStatus
    @ExportId BIGINT,
    @Status NVARCHAR(32),
    @StatusMessage NVARCHAR(2000) = NULL,
    @OutputPath NVARCHAR(1024) = NULL,
    @FileSizeBytes BIGINT = NULL,
    @FileSha256 CHAR(64) = NULL,
    @StaleAfterUtc DATETIME2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.ProductionReportExcelExports
       SET Status = @Status,
           StatusMessage = @StatusMessage,
           OutputPath = COALESCE(@OutputPath, OutputPath),
           FileSizeBytes = COALESCE(@FileSizeBytes, FileSizeBytes),
           FileSha256 = COALESCE(@FileSha256, FileSha256),
           StartedUtc = CASE WHEN @Status = 'Running' THEN SYSUTCDATETIME() ELSE StartedUtc END,
           CompletedUtc = CASE WHEN @Status IN ('Succeeded', 'Failed', 'SkippedDuplicate', 'Stale', 'Missing') THEN SYSUTCDATETIME() ELSE CompletedUtc END,
           StaleAfterUtc = COALESCE(@StaleAfterUtc, StaleAfterUtc),
           AttemptCount = CASE WHEN @Status = 'Running' THEN AttemptCount + 1 ELSE AttemptCount END,
           UpdatedUtc = SYSUTCDATETIME()
     WHERE ExportId = @ExportId;
END;
```

---

## C# Skeletons

### Shared constants

```csharp
namespace LRN.ProductionReports;

public static class ProductionReportExportKeys
{
    public const string ReportType = "ProductionReport";
    public const string NoFilterJson = "{}";
    public const string NoFilterHashInput = "ProductionReport|NO_FILTER|v1";

    public static string NoFilterHash => Sha256Hex(NoFilterHashInput);

    private static string Sha256Hex(string value)
    {
        var bytes = System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(bytes);
    }
}
```

---

### Export metadata model

```csharp
namespace LRN.ProductionReports;

public sealed record ProductionReportExcelExportRecord(
    long ExportId,
    string LabName,
    string ReportType,
    string FilterHash,
    string Status,
    string? OutputPath,
    long? FileSizeBytes,
    string? FileSha256,
    DateTime? CompletedUtc,
    DateTime? StaleAfterUtc,
    string? RunId,
    string? WeekFolder);
```

---

### Metadata repository interface

```csharp
namespace LRN.ProductionReports;

public interface IProductionReportExcelExportStore
{
    Task<StartExportResult> TryStartNoFilterExportAsync(
        string connectionString,
        string labName,
        string outputPath,
        string tempOutputPath,
        string? runId,
        string? weekFolder,
        CancellationToken cancellationToken);

    Task MarkRunningAsync(string connectionString, long exportId, CancellationToken cancellationToken);

    Task MarkSucceededAsync(
        string connectionString,
        long exportId,
        string outputPath,
        long fileSizeBytes,
        string fileSha256,
        DateTime staleAfterUtc,
        CancellationToken cancellationToken);

    Task MarkFailedAsync(
        string connectionString,
        long exportId,
        string message,
        CancellationToken cancellationToken);

    Task MarkMissingAsync(
        string connectionString,
        long exportId,
        string message,
        CancellationToken cancellationToken);

    Task<ProductionReportExcelExportRecord?> GetLatestNoFilterExportAsync(
        string connectionString,
        string labName,
        CancellationToken cancellationToken);
}

public sealed record StartExportResult(bool CanRun, long? ExportId);
```

---

### SQL metadata repository skeleton

```csharp
using Microsoft.Data.SqlClient;
using System.Data;

namespace LRN.ProductionReports;

public sealed class SqlProductionReportExcelExportStore : IProductionReportExcelExportStore
{
    public async Task<StartExportResult> TryStartNoFilterExportAsync(
        string connectionString,
        string labName,
        string outputPath,
        string tempOutputPath,
        string? runId,
        string? weekFolder,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(labName);

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand("dbo.usp_TryStartProductionReportExcelExport", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 60
        };

        cmd.Parameters.AddWithValue("@LabName", labName);
        cmd.Parameters.AddWithValue("@ReportType", ProductionReportExportKeys.ReportType);
        cmd.Parameters.AddWithValue("@FilterHash", ProductionReportExportKeys.NoFilterHash);
        cmd.Parameters.AddWithValue("@FilterJson", ProductionReportExportKeys.NoFilterJson);
        cmd.Parameters.AddWithValue("@RunId", (object?)runId ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@WeekFolder", (object?)weekFolder ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@OutputPath", outputPath);
        cmd.Parameters.AddWithValue("@TempOutputPath", tempOutputPath);

        var exportId = new SqlParameter("@ExportId", SqlDbType.BigInt) { Direction = ParameterDirection.Output };
        var canRun = new SqlParameter("@CanRun", SqlDbType.Bit) { Direction = ParameterDirection.Output };
        cmd.Parameters.Add(exportId);
        cmd.Parameters.Add(canRun);

        await cmd.ExecuteNonQueryAsync(cancellationToken);

        return new StartExportResult(
            CanRun: canRun.Value is bool value && value,
            ExportId: exportId.Value == DBNull.Value ? null : (long)exportId.Value);
    }

    // Implement MarkRunningAsync, MarkSucceededAsync, MarkFailedAsync, MarkMissingAsync
    // using dbo.usp_UpdateProductionReportExcelExportStatus.

    // Implement GetLatestNoFilterExportAsync using TOP (1) WHERE Status='Succeeded' AND IsCurrent=1.
}
```

---

### ClaimLineCSVDataCapture background export job

Because `ClaimLineCSVDataCapture` is currently a console-style app, do **not** block ingestion. Queue the work after aggregates complete and wait only at app shutdown if desired. If this project is converted to a Worker Service later, implement this as `BackgroundService`.

```csharp
namespace ClaimLineCSVDataCapture.Services;

public sealed class ProductionReportExcelBackgroundExporter
{
    private readonly IProductionReportRepository _productionReportRepository;
    private readonly IProductionReportExcelExportStore _exportStore;
    private readonly AppLogger _log;

    public ProductionReportExcelBackgroundExporter(
        IProductionReportRepository productionReportRepository,
        IProductionReportExcelExportStore exportStore,
        AppLogger log)
    {
        _productionReportRepository = productionReportRepository;
        _exportStore = exportStore;
        _log = log;
    }

    public Task QueueNoFilterExportAsync(
        LabConfig lab,
        string outputFolder,
        string? runId,
        string? weekFolder,
        CancellationToken cancellationToken)
    {
        return Task.Run(
            () => GenerateNoFilterExportAsync(lab, outputFolder, runId, weekFolder, cancellationToken),
            cancellationToken);
    }

    private async Task GenerateNoFilterExportAsync(
        LabConfig lab,
        string outputFolder,
        string? runId,
        string? weekFolder,
        CancellationToken cancellationToken)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(lab.DbConnectionString))
            {
                _log.Warn($"  [Prod Excel] Skipped � DbConnectionString missing for {lab.LabName}.");
                return;
            }

            Directory.CreateDirectory(outputFolder);

            var safeLabName = string.Join("_", lab.LabName.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries));
            var fileName = $"{safeLabName}_ProductionReport_NO_FILTER_{DateTime.UtcNow:yyyyMMddHHmmss}.xlsx";
            var finalPath = Path.Combine(outputFolder, fileName);
            var tempPath = finalPath + ".tmp";

            var start = await _exportStore.TryStartNoFilterExportAsync(
                lab.DbConnectionString,
                lab.LabName,
                finalPath,
                tempPath,
                runId,
                weekFolder,
                cancellationToken);

            if (!start.CanRun || start.ExportId is null)
            {
                _log.Info($"  [Prod Excel] Skipped duplicate/no-op for {lab.LabName}.");
                return;
            }

            await _exportStore.MarkRunningAsync(lab.DbConnectionString, start.ExportId.Value, cancellationToken);

            var monthlyTask = _productionReportRepository.GetMonthlyClaimVolumeAsync(lab.DbConnectionString, ct: cancellationToken);
            var weeklyTask = _productionReportRepository.GetWeeklyClaimVolumeAsync(lab.DbConnectionString, ct: cancellationToken);
            var codingTask = _productionReportRepository.GetCodingAsync(lab.DbConnectionString, ct: cancellationToken);
            var payerBreakdownTask = _productionReportRepository.GetPayerBreakdownAsync(lab.DbConnectionString, ct: cancellationToken);
            var payerPanelTask = _productionReportRepository.GetPayerPanelAsync(lab.DbConnectionString, ct: cancellationToken);
            var unbilledAgingTask = _productionReportRepository.GetUnbilledAgingAsync(lab.DbConnectionString, ct: cancellationToken);
            var cptTask = _productionReportRepository.GetCptBreakdownAsync(lab.DbConnectionString, ct: cancellationToken);
            var claimSegmentsTask = _productionReportRepository.GetClaimLevelDataExportSegmentsAsync(lab.DbConnectionString, ct: cancellationToken);
            var lineSegmentsTask = _productionReportRepository.GetLineLevelDataExportSegmentsAsync(lab.DbConnectionString, ct: cancellationToken);

            await Task.WhenAll(
                monthlyTask,
                weeklyTask,
                codingTask,
                payerBreakdownTask,
                payerPanelTask,
                unbilledAgingTask,
                cptTask,
                claimSegmentsTask,
                lineSegmentsTask);

            var vm = ProductionReportViewModelFactory.CreateNoFilter(
                lab.LabName,
                monthlyTask.Result,
                weeklyTask.Result,
                codingTask.Result,
                payerBreakdownTask.Result,
                payerPanelTask.Result,
                unbilledAgingTask.Result,
                cptTask.Result,
                weekFolder,
                runId);

            using var workbook = ProductionReportExcelExportBuilder.CreateWorkbook(
                vm,
                lab.LabName,
                claimSegmentsTask.Result,
                lineSegmentsTask.Result,
                weekFolder,
                runId);

            workbook.SaveAs(tempPath);

            if (File.Exists(finalPath))
                File.Delete(finalPath);

            File.Move(tempPath, finalPath);

            var fileInfo = new FileInfo(finalPath);
            var sha256 = FileHash.ComputeSha256(finalPath);

            await _exportStore.MarkSucceededAsync(
                lab.DbConnectionString,
                start.ExportId.Value,
                finalPath,
                fileInfo.Length,
                sha256,
                DateTime.UtcNow.AddDays(14),
                cancellationToken);

            _log.Info($"  [Prod Excel] Generated no-filter export: {finalPath}");
        }
        catch (OperationCanceledException)
        {
            _log.Warn($"  [Prod Excel] Cancelled for {lab.LabName}.");
        }
        catch (Exception ex)
        {
            _log.Error($"  [Prod Excel] Failed for {lab.LabName}: {ex.Message}");
        }
    }
}
```

---

### Hook point in `ClaimLineCSVDataCapture/Program.cs`

Add the queue call **after** the lab-specific production summary and collection summary refresh blocks, before `processedLabNames.Add(lab.LabName);`.

```csharp
try
{
    if (claimInserted && lineInserted)
    {
        var outputFolder = Path.Combine(lab.Output.Reports, "ProductionReports");
        var runInfo = db.GetLatestRunInfo();

        _ = productionReportExcelExporter.QueueNoFilterExportAsync(
            lab,
            outputFolder,
            runInfo.RunId,
            runInfo.WeekFolder,
            CancellationToken.None);
    }
}
catch (Exception ex)
{
    log.Error($"  [Prod Excel] Queue failed but ingestion will continue: {ex.Message}");
}
```

If the process exits immediately after the loop, keep a list of queued tasks and wait with a bounded timeout during shutdown:

```csharp
var exportTasks = new List<Task>();

// per lab
exportTasks.Add(productionReportExcelExporter.QueueNoFilterExportAsync(...));

// after all labs
await Task.WhenAll(exportTasks).WaitAsync(TimeSpan.FromMinutes(60));
```

Use this only if the scheduled task/runtime allows the process to stay alive long enough.

---

### Dashboard repository for pre-generated exports

```csharp
namespace LabMetricsDashboard.Services;

public interface IPreGeneratedProductionReportRepository
{
    Task<ProductionReportExcelExportRecord?> GetLatestNoFilterExportAsync(
        string connectionString,
        string labName,
        CancellationToken cancellationToken);

    Task MarkMissingAsync(
        string connectionString,
        long exportId,
        string message,
        CancellationToken cancellationToken);
}
```

---

### Dashboard no-filter detection

```csharp
private static bool HasProductionReportFilters(
    IReadOnlyCollection<string> filterPayerNames,
    IReadOnlyCollection<string> filterPanelNames,
    string? filterDosFrom,
    string? filterDosTo,
    string? filterFirstBillFrom,
    string? filterFirstBillTo,
    string? filterFirstBilledFrom,
    string? filterFirstBilledTo)
{
    return filterPayerNames.Count > 0
        || filterPanelNames.Count > 0
        || !string.IsNullOrWhiteSpace(filterDosFrom)
        || !string.IsNullOrWhiteSpace(filterDosTo)
        || !string.IsNullOrWhiteSpace(filterFirstBillFrom)
        || !string.IsNullOrWhiteSpace(filterFirstBillTo)
        || !string.IsNullOrWhiteSpace(filterFirstBilledFrom)
        || !string.IsNullOrWhiteSpace(filterFirstBilledTo);
}
```

---

### Dashboard export action change

At the beginning of `ExportProductionReportExcel`, after validating lab config and parsing filters:

```csharp
var hasFilters = HasProductionReportFilters(
    filterPayerNames,
    filterPanelNames,
    filterDosFrom,
    filterDosTo,
    filterFirstBillFrom,
    filterFirstBillTo,
    filterFirstBilledFrom,
    filterFirstBilledTo);

if (!hasFilters)
{
    var preGenerated = await _preGeneratedProductionReportRepo.GetLatestNoFilterExportAsync(
        connStr,
        selectedLab,
        ct);

    if (preGenerated?.OutputPath is not null)
    {
        if (System.IO.File.Exists(preGenerated.OutputPath)
            && preGenerated.StaleAfterUtc.GetValueOrDefault(DateTime.MaxValue) > DateTime.UtcNow)
        {
            _logger.LogInformation(
                "Serving pre-generated no-filter Production Report for lab {LabName}: {Path}",
                selectedLab,
                preGenerated.OutputPath);

            return PhysicalFile(
                preGenerated.OutputPath,
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                Path.GetFileName(preGenerated.OutputPath));
        }

        await _preGeneratedProductionReportRepo.MarkMissingAsync(
            connStr,
            preGenerated.ExportId,
            "Pre-generated file missing or stale; falling back to on-demand export.",
            ct);
    }

    _logger.LogWarning(
        "No valid pre-generated no-filter Production Report found for lab {LabName}; falling back to on-demand generation.",
        selectedLab);
}

// existing on-demand export code remains unchanged below this point
```

---

## Failure-Safe Behavior

Required behavior:

- Excel generation failure does **not** fail CSV import.
- Aggregate refresh failure keeps existing behavior: log and continue.
- Dashboard falls back to on-demand generation when:
  - no DB row exists,
  - status is not `Succeeded`,
  - file is missing,
  - file is stale,
  - file path is inaccessible.
- Duplicate prevention uses DB lock/index, not only filesystem checks.
- Write to `.tmp`, then atomic rename to `.xlsx`.
- Never expose `.tmp` files to dashboard.
- Mark old current files `Stale` when a new export succeeds.
- Optional cleanup job can delete stale physical files after retention days.

---

## Configuration

Add per-lab settings in both app config models if needed:

```json
{
  "ProductionReportExcel": {
    "EnablePreGeneration": true,
    "OutputFolder": "D:\\LRNReports\\ProductionReports",
    "RetentionDays": 14,
    "FallbackToOnDemand": true
  }
}
```

Recommended model:

```csharp
public sealed class ProductionReportExcelConfig
{
    public bool EnablePreGeneration { get; init; }
    public string? OutputFolder { get; init; }
    public int RetentionDays { get; init; } = 14;
    public bool FallbackToOnDemand { get; init; } = true;
}
```

Add this property to both lab config models:

```csharp
public ProductionReportExcelConfig? ProductionReportExcel { get; init; }
```

---

## Implementation Sequence

1. Extract shared production report Excel code to `LRN.ProductionReports`.
2. Add `ProductionReportExcelExports` table and procedures to every lab DB deployment script.
3. Add metadata repository.
4. Add background exporter in `ClaimLineCSVDataCapture`.
5. Queue exporter only when both claim and line inserts happened and aggregate refresh blocks have run.
6. Add dashboard pre-generated lookup.
7. Add fallback to existing on-demand path.
8. Add cleanup for stale files.
9. Validate with one lab DB before enabling for all labs.

---

## Testing Checklist

- First run with new files creates a DB row: `Queued -> Running -> Succeeded`.
- Dashboard no-filter download returns the pre-generated file.
- Dashboard filtered export still generates on demand.
- Missing physical file is marked `Missing` and dashboard falls back.
- Duplicate run for same lab/filter while current export exists is skipped.
- Failed export marks `Failed` and does not fail import.
- Refresh mode marks old file stale and creates a new current file.
- Each lab writes metadata only to that lab�s DB.
