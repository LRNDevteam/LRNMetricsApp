using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LRN.ReportQueue.Shared;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Async Denial Summary export (the DenialClaimReport page's Download button):
///   • "Monthly Summary", "Weekly Summary", "Denial Insight" — the page's own three sheets,
///     loaded and styled by the dashboard's DenialClaimReportExcelBuilder, so the file and the
///     screen are built by the same code;
///   • "Denial Claim Level" — every denied claim with an insurance balance outstanding, with the
///     lab's claim-level columns including DenialCodeNormalized and DenialDescription, streamed
///     row-by-row with OpenXml so a large lab does not have to fit in memory.
/// </summary>
public sealed class DenialSummaryReportGenerator : IReportGenerator
{
    public string ReportType => ReportTypes.DenialSummary;

    private readonly LabSettings _labSettings;
    private readonly SqlDenialClaimReportRepository _repo;
    private readonly ReportStorageOptions _storage;
    private readonly ILogger<DenialSummaryReportGenerator> _logger;

    public DenialSummaryReportGenerator(
        LabSettings labSettings,
        SqlDenialClaimReportRepository repo,
        Microsoft.Extensions.Options.IOptions<ReportStorageOptions> storage,
        ILogger<DenialSummaryReportGenerator> logger)
    {
        _labSettings = labSettings;
        _repo        = repo;
        _storage     = storage.Value;
        _logger      = logger;
    }

    public async Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct)
    {
        if (!_labSettings.Labs.TryGetValue(job.LabName, out var labConfig)
            || string.IsNullOrWhiteSpace(labConfig.DbConnectionString))
            throw new InvalidOperationException($"Denial Summary is not available for '{job.LabName}'.");

        var connStr = labConfig.DbConnectionString;
        var f = DenialSummaryReportFilters.FromJson(job.FilterDetailsJson);

        async Task Progress(byte pct)
        {
            if (reportProgressAsync is not null) await reportProgressAsync(pct);
        }

        var model = await DenialClaimReportExcelBuilder.LoadAsync(
            _repo, connStr, job.LabName, f.Bucket,
            f.ParsedWeekStartsOn ?? SqlDenialClaimReportRepository.DefaultWeekStartsOn, f.DateColumn, f.BalanceColumn, ct);
        await Progress(20);

        var claimQuery = await _repo.BuildDeniedClaimExportQueryAsync(
            connStr, LabClaimLineColumnCatalog.GetClaimColumns(job.LabName), f.BalanceColumn, ct);

        // DenialSummary_<Lab>_<RunId>_<Week>.xlsx — the page sends its run and week; the claim
        // table's own are the fallback, so the name is filled in either way.
        (fileName, targetPath) = ReportFilePathBuilder.BuildNamed(
            _storage.RootPath, job.ReportType, job.RequestedBy, DateTime.Now,
            ReportFilePathBuilder.ComposeName("DenialSummary", job.LabName,
                f.RunId ?? model.RunId, f.WeekFolder ?? model.WeekRange));

        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        var tempPath = targetPath + ".tmp";
        var claimRows = 0;
        try
        {
            using (var wb = DenialClaimReportExcelBuilder.Build(model))
            {
                // No claim table or no DenialCode: say so on the sheet rather than leave it out.
                if (claimQuery is null)
                    DenialClaimReportExcelBuilder.AddClaimLevelSheet(wb, claims: null);

                using var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None);
                wb.SaveAs(fs);
            }
            await Progress(30);

            if (claimQuery is not null)
            {
                // TotalClaims counts distinct claims, which is close to the row count; it only
                // drives the progress bar, so near enough is fine.
                var expected = Math.Max(1, model.TotalClaims);
                claimRows = await OpenXmlRowStreamer.AppendSqlSheetsToWorkbookAsync(
                    tempPath, connStr, claimQuery.Sql, new List<SqlParameter>(),
                    DenialClaimReportExcelBuilder.ClaimLevelSheetName,
                    done => Progress((byte)(30 + Math.Min(65, done * 65L / expected))), ct);
            }

            File.Move(tempPath, targetPath, overwrite: true);
        }
        catch
        {
            try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch { /* ignore */ }
            throw;
        }

        await Progress(98);

        var size = new FileInfo(targetPath).Length;
        _logger.LogInformation(
            "DenialSummary {ReportId} [{Lab}]: {Rows:N0} denied claim row(s), {Columns} column(s), {Size:N0} bytes → {Path}",
            job.ReportId, job.LabName, claimRows, claimQuery?.Columns.Count ?? 0, size, targetPath);

        return new GeneratedReportFile(fileName, targetPath, size, claimRows);
    }
}
