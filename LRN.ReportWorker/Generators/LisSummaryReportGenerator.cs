using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ReportQueue.Shared;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Async LIMS Master export — the two-sheet LIS workbook the LIS Summary page used to
/// build inline:
///   • "LIS Summary"  — the month/year pivot, straight from ILisSummaryRepository
///                      (same query the page renders), written with ClosedXML;
///   • "LIMS Master"  — the FULL line-level dbo.LIMSMaster extract for the same filters,
///                      streamed row-by-row with OpenXml so million-row labs export
///                      without the 1,048,575-row cap the synchronous action needed.
///
/// The line-level sheet also carries one extra column per property found in
/// LIMSMaster.AdditionalFields (e.g. NPI, ParentCompany, lastTest_Year …): the repository
/// discovers the key set across the whole filtered range and selects each one with
/// JSON_VALUE, so the JSON blob arrives as real columns rather than raw text.
/// </summary>
public sealed class LisSummaryReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.LisSummary;

    /// <summary>Sheet the line-level rows land on — same tab name the page's export used.</summary>
    private const string LineSheetName = "LIMS Master";

    private readonly LabSettings _labSettings;
    private readonly ILisSummaryRepository _repo;
    private readonly ILogger<LisSummaryReportGenerator> _logger;

    public LisSummaryReportGenerator(
        LabSettings labSettings,
        ILisSummaryRepository repo,
        ILogger<LisSummaryReportGenerator> logger)
    {
        _labSettings = labSettings;
        _repo        = repo;
        _logger      = logger;
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        if (!_labSettings.Labs.TryGetValue(job.LabName, out var labConfig))
            throw new InvalidOperationException($"Lab '{job.LabName}' is not configured.");
        if (!labConfig.LineClaimEnable || string.IsNullOrWhiteSpace(labConfig.DbConnectionString))
            throw new InvalidOperationException($"LIS Summary is not available for '{job.LabName}'.");

        var connStr = labConfig.DbConnectionString;
        var f = LisSummaryReportFilters.FromJson(job.FilterDetailsJson);

        // Same date semantics as the page: InHealth only tracks the collected date.
        var dateType = job.LabName.Contains("InHealth", StringComparison.OrdinalIgnoreCase)
            ? "Collected"
            : f.EffectiveDateType;
        var dateFrom = ParseDate(f.DateFrom);
        var dateTo   = ParseDate(f.DateTo);

        async Task Progress(byte pct)
        {
            if (reportProgressAsync is not null) await reportProgressAsync(pct);
        }

        var summary = await _repo.GetLisSummaryAsync(
            connStr, job.LabName, f.LabId, dateType, dateFrom, dateTo,
            f.Panel, f.Clinic, f.RefPhy, f.SalesRep, f.Collector, ct);
        await Progress(10);

        // Resolves the line-level SELECT + the AdditionalFields columns; the key
        // discovery scans the whole filtered range, so this can take a while on big labs.
        var plan = await _repo.BuildLineDataExportPlanAsync(
            connStr, job.LabName, dateType, dateFrom, dateTo,
            f.Panel, f.Clinic, f.RefPhy, f.SalesRep, f.Collector, ct);
        await Progress(18);

        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        var tempPath = targetPath + ".tmp";
        int lineRows;
        try
        {
            WriteSummarySheet(tempPath, summary, job.LabName, dateType, dateFrom, dateTo, f);
            await Progress(22);

            var total = Math.Max(1, plan.TotalRows);
            lineRows = await OpenXmlRowStreamer.AppendSqlSheetsToWorkbookAsync(
                tempPath, connStr, plan.DataSql, plan.Parameters.ToList(), LineSheetName,
                done => Progress((byte)(22 + Math.Min(73, done * 73L / total))), ct);

            File.Move(tempPath, targetPath, overwrite: true);
        }
        catch
        {
            try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { }
            throw;
        }

        await Progress(98);

        var size = new FileInfo(targetPath).Length;
        _logger.LogInformation(
            "LisSummary {ReportId} [{Lab}]: {Rows:N0} LIMS Master rows, {Extra} AdditionalFields column(s) [{Keys}], {Size:N0} bytes → {Path}",
            job.ReportId, job.LabName, lineRows, plan.AdditionalFieldKeys.Count,
            string.Join(", ", plan.AdditionalFieldKeys), size, targetPath);

        return new GeneratedReportFile(fileName, targetPath, size, lineRows);
    }

    /// <summary>
    /// Writes the workbook with ONLY the "LIS Summary" tab. The builder's own
    /// "LIMS Master" placeholder is dropped so the streamed sheet can take that name —
    /// ClosedXML would hold every line row in memory and OOM on a large lab.
    /// </summary>
    private static void WriteSummarySheet(
        string tempPath,
        LisSummaryResult summary,
        string labName,
        string dateType,
        DateOnly? dateFrom,
        DateOnly? dateTo,
        LisSummaryReportFilters f)
    {
        using var wb = LisSummaryExcelExportBuilder.CreateWorkbook(
            summary, lineData: null, labName, dateType, dateFrom, dateTo,
            f.Panel, f.Clinic, f.RefPhy, f.SalesRep, f.Collector);

        foreach (var placeholder in wb.Worksheets
                     .Where(ws => ws.Name.Equals(LineSheetName, StringComparison.OrdinalIgnoreCase))
                     .ToList())
            placeholder.Delete();

        using var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None);
        wb.SaveAs(fs);
    }

    private static DateOnly? ParseDate(string? value) =>
        DateOnly.TryParse(value, out var d) && d != default ? d : null;
}
