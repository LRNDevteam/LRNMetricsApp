using System.IO.Compression;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LRN.SnapshotGenerator;

/// <summary>An Executive Summary highlight tab: another report of the same run, showing only <see cref="EmbedTabs"/>.</summary>
public sealed record SnapshotHighlightTab(string Title, string ReportCode, string? EmbedTabs);

/// <summary>
/// The display copy of a report snapshot: <c>&lt;run prefix&gt;&lt;REPORTCODE&gt;_PageModel.json.gz</c>,
/// indexed with ResultSetName <c>PageModel</c>. It holds the page's own view model exactly as the page
/// rendered it, so LRN Metrics can show a past week through the page's existing views, tabs and layout.
/// The Parquet files of the same report are the same data as tables, for querying.
/// <para>
/// <see cref="ModelType"/> and <see cref="Logic"/> say what produced it. A view model gains properties as
/// a report changes; an older snapshot simply lacks them, so it is shown as it was - never recomputed.
/// </para>
/// </summary>
public sealed class ReportPageSnapshot
{
    public const string FormatName = "LRN.ReportPageSnapshot";
    public const int CurrentFormatVersion = 1;
    public const string ResultSetName = "PageModel";

    public string Format { get; set; } = FormatName;
    public int FormatVersion { get; set; } = CurrentFormatVersion;
    public string ReportCode { get; set; } = "";
    public string LabKey { get; set; } = "";
    public string LabName { get; set; } = "";
    public string RunId { get; set; } = "";
    public string WeekFolder { get; set; } = "";
    public DateTime CapturedOnUtc { get; set; }

    /// <summary>What triggered it: the tracker report name, or the upload / edit for a requested snapshot.</summary>
    public string Trigger { get; set; } = "";

    /// <summary>The tracker row's timestamp this capture was taken for; a new one means the report re-ran.</summary>
    public string? TrackerStamp { get; set; }

    /// <summary>The view model's .NET type, e.g. LabMetricsDashboard.Models.PhiExecutiveSummaryViewModel.</summary>
    public string ModelType { get; set; } = "";

    public ReportLogicVersion Logic { get; set; } = new();

    /// <summary>How <see cref="Logic"/> differs from the lab's previous snapshot of this report.</summary>
    public List<string> LogicChanges { get; set; } = [];

    /// <summary>Executive Summary only: its highlight tabs, captured as their own reports of the same run.</summary>
    public List<SnapshotHighlightTab> HighlightTabs { get; set; } = [];

    public object? Model { get; set; }

    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        ReferenceHandler = ReferenceHandler.IgnoreCycles,
        NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals,
        Converters = { new JsonStringEnumConverter() }
    };

    /// <summary>Writes the gzip JSON to <paramref name="path"/>.</summary>
    public async Task WriteAsync(string path, CancellationToken ct)
    {
        await using var file = File.Create(path);
        await using var gzip = new GZipStream(file, CompressionLevel.Optimal);
        await JsonSerializer.SerializeAsync(gzip, this, JsonOptions, ct);
    }

    /// <summary>Reads one back with the model as a JsonElement (the self-test; the viewer binds it to <see cref="ModelType"/>).</summary>
    public static async Task<ReportPageSnapshot?> ReadAsync(string path, CancellationToken ct)
    {
        await using var file = File.OpenRead(path);
        await using var gzip = new GZipStream(file, CompressionMode.Decompress);
        return await JsonSerializer.DeserializeAsync<ReportPageSnapshot>(gzip, JsonOptions, ct);
    }

    /// <summary>ReportSnapshotFile.SchemaJson of the PageModel row: everything but the model, for the index and the next week's comparison.</summary>
    public string IndexJson() => JsonSerializer.Serialize(new PageModelIndexInfo
    {
        FormatVersion = FormatVersion,
        ModelType = ModelType,
        Trigger = Trigger,
        TrackerStamp = TrackerStamp,
        Logic = Logic,
        LogicChanges = LogicChanges,
        HighlightTabs = HighlightTabs
    }, JsonOptions);
}

/// <summary>The SchemaJson of a PageModel file row.</summary>
public sealed class PageModelIndexInfo
{
    public int FormatVersion { get; set; }
    public string ModelType { get; set; } = "";
    public string Trigger { get; set; } = "";
    public string? TrackerStamp { get; set; }
    public ReportLogicVersion Logic { get; set; } = new();
    public List<string> LogicChanges { get; set; } = [];
    public List<SnapshotHighlightTab> HighlightTabs { get; set; } = [];

    public static PageModelIndexInfo? Parse(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try { return JsonSerializer.Deserialize<PageModelIndexInfo>(json, ReportPageSnapshot.JsonOptions); }
        catch (JsonException) { return null; }
    }
}
