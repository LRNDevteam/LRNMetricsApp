using LRN.ReportQueue.Shared;
using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Async CPT &amp; Panel Lookup export. The page used to download this straight from
/// GET /api/analytics/{cpt|panel}-lookup/export, which meant the whole workbook had to be
/// queried AND built inside one HTTP request — an unfiltered export (no lab, no window)
/// reliably blew past the dashboard's 120s HttpClient timeout and the user got a
/// TaskCanceledException instead of a file. Queued here, the same work has no request clock.
///
/// This report is NOT per-lab. It reads LRNMaster (CPTAverage / PanelAverage) and its
/// Lab filter is optional, so it is queued against the shared
/// <see cref="ReportQueueLabs.Master"/> entry — whose DbConnectionString IS LRNMaster.
/// That is also how the connection reaches this service without adding one to appsettings:
/// it arrives on the claimed job's own lab config, same as every other queued report.
///
/// One class serves both tabs; <see cref="ReportType"/> is fixed per registered instance,
/// so Program.cs registers it twice — once for CptLookup, once for PanelLookup.
/// </summary>
public sealed class CptLookupReportGenerator : IReportGenerator
{
    public string ReportType { get; }

    private readonly bool _panelMode;
    private readonly ReportStorageOptions _storage;
    private readonly ILogger<CptLookupReportGenerator> _logger;

    private CptLookupReportGenerator(
        string reportType, bool panelMode,
        IOptions<ReportStorageOptions> storage,
        ILogger<CptLookupReportGenerator> logger)
    {
        ReportType = reportType;
        _panelMode = panelMode;
        _storage   = storage.Value;
        _logger    = logger;
    }

    public static CptLookupReportGenerator ForCpt(
        IOptions<ReportStorageOptions> storage, ILogger<CptLookupReportGenerator> logger)
        => new(ReportTypes.CptLookup, panelMode: false, storage, logger);

    public static CptLookupReportGenerator ForPanel(
        IOptions<ReportStorageOptions> storage, ILogger<CptLookupReportGenerator> logger)
        => new(ReportTypes.PanelLookup, panelMode: true, storage, logger);

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(lab.DbConnectionString))
            throw new InvalidOperationException(
                $"Queue lab '{job.LabName}' has no DbConnectionString. CPT & Panel Lookup reads LRNMaster, " +
                $"so it must be queued against a lab config whose connection points there (see ReportQueueLabs.Master).");

        var f = CptLookupReportFilters.FromJson(job.FilterDetailsJson);
        var query = new LookupQuery
        {
            CptCode       = NullIfBlank(f.CptCode),
            PanelName     = NullIfBlank(f.PanelName),
            Payer         = NullIfBlank(f.Payer),
            WindowType    = NullIfBlank(f.WindowType),
            LabId         = f.LabId,
            SortColumn    = NullIfBlank(f.SortColumn),
            SortDirection = NullIfBlank(f.SortDirection),
        };

        async Task Progress(byte pct)
        {
            if (reportProgressAsync is not null) await reportProgressAsync(pct);
        }

        await Progress(5);

        // The lookup queries are the slow part; the workbook build is comparatively quick.
        var repo = new SqlCptLookupRepository(lab.DbConnectionString);
        int rowCount;
        byte[] bytes;
        if (_panelMode)
        {
            var rows = await repo.ReadPanelExportRowsAsync(query, ct);
            await Progress(75);
            rowCount = rows.Count;
            bytes    = SqlCptLookupRepository.BuildPanelExcel(rows);
        }
        else
        {
            var rows = await repo.ReadCptExportRowsAsync(query, ct);
            await Progress(75);
            rowCount = rows.Count;
            bytes    = SqlCptLookupRepository.BuildCptExcel(rows);
        }
        await Progress(90);

        // <CPT|Panel>Lookup_<Lab>.xlsx — "AllLabs" when the export was not scoped to one,
        // which is the case the synchronous download could never finish.
        var scope = string.IsNullOrWhiteSpace(f.LabName)
            ? (f.LabId is null ? "AllLabs" : $"Lab{f.LabId}")
            : f.LabName;
        (fileName, targetPath) = ReportFilePathBuilder.BuildNamed(
            _storage.RootPath, job.ReportType, job.RequestedBy, DateTime.Now,
            ReportFilePathBuilder.ComposeName(
                _panelMode ? "PanelLookup" : "CptLookup", scope, NullIfBlank(f.WindowType)));

        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        var tempPath = targetPath + ".tmp";
        try
        {
            await File.WriteAllBytesAsync(tempPath, bytes, ct);
            File.Move(tempPath, targetPath, overwrite: true);
        }
        catch
        {
            try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { }
            throw;
        }

        await Progress(98);

        // The row cap is a memory guard, not a filter — say so rather than shipping a
        // silently short workbook.
        if (rowCount >= SqlCptLookupRepository.MaxExportRows)
            _logger.LogWarning(
                "{Type} {ReportId}: hit the {Cap:N0}-row export cap — the workbook is truncated. Narrow the filters for a complete extract.",
                job.ReportType, job.ReportId, SqlCptLookupRepository.MaxExportRows);

        _logger.LogInformation(
            "{Type} {ReportId} [{Scope}]: {Rows:N0} rows, {Size:N0} bytes → {Path}",
            job.ReportType, job.ReportId, scope, rowCount, bytes.Length, targetPath);

        return new GeneratedReportFile(fileName, targetPath, bytes.Length, rowCount);
    }

    private static string? NullIfBlank(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value;
}
