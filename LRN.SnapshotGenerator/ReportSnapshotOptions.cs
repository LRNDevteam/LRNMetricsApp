using System.Text.Json;
using System.Text.Json.Serialization;

namespace LRN.SnapshotGenerator;

/// <summary>Service switches, section <c>ReportSnapshot</c> in appsettings.json.</summary>
public sealed class ReportSnapshotOptions
{
    public const string SectionName = "ReportSnapshot";

    /// <summary>Master switch. Off until the storage, the LRNMaster index and the labs are set up.</summary>
    public bool Enabled { get; set; }

    /// <summary>How often ReportsWorkflowTracker is checked for newly successful reports.</summary>
    public int PollMinutes { get; set; } = 15;

    /// <summary>Folder of the per-lab JSON files (one per lab); relative = the service folder.</summary>
    public string LabsFolder { get; set; } = "Labs";

    /// <summary>Only tracker rows updated within this many days are considered.</summary>
    public int LookbackDays { get; set; } = 14;

    /// <summary>Delay after a lab's report turns Success before it is captured, so a report still settling is not caught mid-write.</summary>
    public int SettleMinutes { get; set; } = 5;

    /// <summary>How often dbo.ReportSnapshotRequest is checked (Denial Insight uploads and edits).</summary>
    public int RequestPollSeconds { get; set; } = 60;

    /// <summary>A request is captured once it has been quiet this long, so a burst of row edits is one snapshot.</summary>
    public int RequestSettleSeconds { get; set; } = 120;

    /// <summary>A requested capture that keeps failing is closed as Failed after this many tries.</summary>
    public int RequestMaxAttempts { get; set; } = 5;

    /// <summary>ReportsWorkflowTracker.ReportName this service reports each run's snapshot under; empty = no tracker row.</summary>
    public string TrackerReportName { get; set; } = "Report Snapshot";
}

/// <summary>
/// One lab's snapshot settings: <c>Labs\{LabKey}.json</c>. A new lab needs only a new file - its
/// reports are read through the same code as its LRN Metrics pages, so the stored procedures each
/// report runs come from the page's own per-lab rules, never from this file.
/// </summary>
public sealed class LabSnapshotConfig
{
    /// <summary>LRNMaster LabId, as ReportsWorkflowTracker / LRN_Run_Log record it.</summary>
    public int LabId { get; set; }

    /// <summary>The lab's key in LRN Metrics / LRN.ReportWorker (the per-lab config JSON name), e.g. TexasDiagnostic.</summary>
    public string LabKey { get; set; } = "";

    public bool Enabled { get; set; }

    /// <summary>Keyed by report: ExecutiveSummary, LisSummary, ProductionSummary, CollectionSummary, DenialSummary, DenialInsight.</summary>
    public Dictionary<string, LabReportSnapshotConfig> Reports { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Where the file came from, for log messages.</summary>
    [JsonIgnore]
    public string SourceFile { get; set; } = "";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true
    };

    /// <summary>Every *.json in <paramref name="folder"/>; a file that does not parse is reported, not fatal.</summary>
    public static (List<LabSnapshotConfig> Labs, List<string> Errors) LoadAll(string folder)
    {
        var labs = new List<LabSnapshotConfig>();
        var errors = new List<string>();
        if (!Directory.Exists(folder))
        {
            errors.Add($"Labs folder not found: {folder}");
            return (labs, errors);
        }

        foreach (var file in Directory.EnumerateFiles(folder, "*.json").OrderBy(f => f, StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                var lab = JsonSerializer.Deserialize<LabSnapshotConfig>(File.ReadAllText(file), JsonOptions);
                if (lab is null || lab.LabId <= 0 || string.IsNullOrWhiteSpace(lab.LabKey))
                {
                    errors.Add($"{Path.GetFileName(file)}: LabId and LabKey are required.");
                    continue;
                }
                lab.Reports = new Dictionary<string, LabReportSnapshotConfig>(lab.Reports, StringComparer.OrdinalIgnoreCase);
                lab.SourceFile = Path.GetFileName(file);
                labs.Add(lab);
            }
            catch (JsonException ex)
            {
                errors.Add($"{Path.GetFileName(file)}: {ex.Message}");
            }
        }
        return (labs, errors);
    }
}

public sealed class LabReportSnapshotConfig
{
    public bool Enabled { get; set; } = true;

    /// <summary>
    /// The ReportsWorkflowTracker.ReportName whose Success for a RunId triggers this snapshot. Not used by
    /// DenialInsight, which is captured when the tab is uploaded or edited.
    /// </summary>
    public string TrackerReportName { get; set; } = "";
}

/// <summary>The page reports: config key, ReportSnapshotFile.ReportCode and what triggers the capture.</summary>
public static class SnapshotReports
{
    /// <param name="DefaultTrackerReportName">The tracker report whose Success triggers it; null = captured on request (upload).</param>
    public sealed record Definition(string Key, string ReportCode, string? DefaultTrackerReportName)
    {
        public bool OnRequest => DefaultTrackerReportName is null;
    }

    public static readonly IReadOnlyList<Definition> All =
    [
        new("ExecutiveSummary", LRN.ReportWorker.Generators.ReportSnapshotCodes.ExecutiveSummary, "Executive Summary"),
        new("LisSummary", LRN.ReportWorker.Generators.ReportSnapshotCodes.LisSummary, "LIS Summary"),
        new("ProductionSummary", LRN.ReportWorker.Generators.ReportSnapshotCodes.ProductionSummary, "Production Summary"),
        new("CollectionSummary", LRN.ReportWorker.Generators.ReportSnapshotCodes.CollectionSummary, "Collection Summary"),
        new("DenialSummary", LRN.ReportWorker.Generators.ReportSnapshotCodes.DenialSummary, "Denial Report"),
        new("DenialInsight", LRN.ReportWorker.Generators.ReportSnapshotCodes.DenialInsight, null)
    ];

    public static Definition? ByCode(string reportCode) =>
        All.FirstOrDefault(d => string.Equals(d.ReportCode, reportCode, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// The Executive Summary page's highlight tabs for a lab (LabMetricsDashboard's own list), as the
    /// reports that hold them - captured with the Executive Summary for the same run.
    /// </summary>
    public static List<SnapshotHighlightTab> ExecutiveSummaryHighlights(string labKey) =>
        LabMetricsDashboard.Services.ExecutiveSummaryHighlightsExcel.HighlightTabs(labKey)
            .Select(t => new SnapshotHighlightTab(t.Title, t.Report switch
            {
                "Production" => LRN.ReportWorker.Generators.ReportSnapshotCodes.ProductionSummary,
                "Collection" => LRN.ReportWorker.Generators.ReportSnapshotCodes.CollectionSummary,
                "Lims" => LRN.ReportWorker.Generators.ReportSnapshotCodes.LisSummary,
                "Denial" => LRN.ReportWorker.Generators.ReportSnapshotCodes.DenialSummary,
                _ => throw new InvalidOperationException($"Unknown Executive Summary highlight report '{t.Report}'.")
            }, t.EmbedTabs))
            .ToList();
}
