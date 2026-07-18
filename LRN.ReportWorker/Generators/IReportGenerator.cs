using LRN.ReportQueue.Shared;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// One implementation per ReportType. Resolved by <see cref="ReportGeneratorFactory"/>
/// from UserReqReports.ReportType — adding a new report (ForecastingSummary,
/// ExecutiveSummary, ProductionReport, CollectionReport, LisSummary, …) means adding
/// one class + one DI registration; the queue/worker/UI pipeline is untouched.
/// </summary>
public interface IReportGenerator
{
    string ReportType { get; }

    /// <summary>
    /// Generates the workbook at <paramref name="targetPath"/> (write to *.tmp,
    /// then move — the queue row only points at fully written files).
    /// <paramref name="reportProgressAsync"/> receives 0–100 as rows are written;
    /// the caller throttles and persists it (feeds the badge progress %).
    /// </summary>
    Task<GeneratedReportFile> GenerateAsync(
        LabDbConfig lab, ClaimedReport job, string fileName, string targetPath,
        Func<byte, Task>? reportProgressAsync, CancellationToken ct);
}

public sealed class ReportGeneratorFactory
{
    private readonly Dictionary<string, IReportGenerator> _generators;

    public ReportGeneratorFactory(IEnumerable<IReportGenerator> generators) =>
        _generators = generators.ToDictionary(g => g.ReportType, StringComparer.OrdinalIgnoreCase);

    public IReportGenerator? Resolve(string reportType) =>
        _generators.GetValueOrDefault(reportType);
}
