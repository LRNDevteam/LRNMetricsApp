using LabMetricsDashboard.Controllers;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.ViewModels;
using LRN.ProductionReports.Services;
using LRN.ReportWorker.Generators;

namespace LRN.SnapshotGenerator;

/// <summary>
/// A report page's Key Insights &amp; Highlights panel (LIS, Production, Collection): the loaded week's
/// active insights and the report's templates (<see cref="ReportInsightsSnapshotModel"/>, LabMetricsDashboard's
/// own type so its snapshot viewer binds it). Users write them in the live report, so they are captured on
/// LabMetricsDashboard's request (dbo.ReportSnapshotRequest) after each save or delete. Read-only: unlike the
/// page, it never archives the previous weeks' insights.
/// </summary>
public sealed class ReportInsightsSnapshotSource : IReportSnapshotSource
{
    private readonly LabSettings _labSettings;
    private readonly INotesRepository _notes;
    private readonly IProductionReportRepository _runInfo;
    private readonly string _notesReportName;

    private ReportInsightsSnapshotSource(string reportCode, string notesReportName,
        LabSettings labSettings, INotesRepository notes, IProductionReportRepository runInfo)
    {
        SnapshotReportCode = reportCode;
        _notesReportName = notesReportName;
        _labSettings = labSettings;
        _notes = notes;
        _runInfo = runInfo;
    }

    public string SnapshotReportCode { get; }

    /// <summary>One source per report panel, by its NotesController.AllowedReports name.</summary>
    public static void Register(IServiceCollection services)
    {
        services.AddSingleton<INotesRepository, SqlNotesRepository>();
        foreach (var (code, report) in new[]
                 {
                     (ReportSnapshotCodes.LisInsight, "LIS Report"),
                     (ReportSnapshotCodes.ProductionInsight, "Production Report"),
                     (ReportSnapshotCodes.CollectionInsight, "Collection Report")
                 })
            services.AddSingleton<IReportSnapshotSource>(sp => new ReportInsightsSnapshotSource(code, report,
                sp.GetRequiredService<LabSettings>(), sp.GetRequiredService<INotesRepository>(),
                sp.GetRequiredService<IProductionReportRepository>()));
    }

    public async Task<object?> LoadUnfilteredAsync(string labName, CancellationToken ct)
    {
        if (!_labSettings.Labs.TryGetValue(labName, out var labConfig) || string.IsNullOrWhiteSpace(labConfig.DbConnectionString))
            return null;
        var connStr = labConfig.DbConnectionString;
        if (!await _notes.IsFeatureAvailableAsync(connStr, ct)) return null;

        // The week the page dates its insights by: the run loaded in the lab database.
        var (weekFolder, runId) = await _runInfo.GetRunInfoAsync(connStr, ct);
        NotesController.TryParseWeekRangeText(weekFolder, out var start, out var end);

        var reportKeyId = await _notes.EnsureReportAsync(connStr, _notesReportName, ct);
        var templates = await _notes.GetTemplatesByReportAsync(connStr, reportKeyId, ct);
        foreach (var t in templates) t.ReportName = _notesReportName;
        var active = await _notes.GetActiveAsync(connStr, reportKeyId, start, ct: ct);

        return new ReportInsightsSnapshotModel
        {
            CurrentLab = labName,
            ReportName = _notesReportName,
            RunId = runId?.Trim(),
            WeekText = weekFolder?.Trim(),
            WeekStart = start,
            WeekEnd = end ?? start,
            Templates = templates.ToList(),
            Rows = ReportInsightsSnapshotModel.InWeek(active, start, weekFolder)
        };
    }
}
