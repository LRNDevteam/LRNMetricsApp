using System.IO.Compression;
using System.Text.Json;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.ViewModels;
using Microsoft.Extensions.Caching.Memory;

namespace LabMetricsDashboard.Services.ReportSnapshots;

/// <summary>
/// The display copy of one report snapshot (<c>..._&lt;REPORTCODE&gt;_PageModel.json.gz</c>, ResultSetName
/// PageModel), as LRN.SnapshotGenerator wrote it: the envelope, plus the page's own view model bound back
/// to its type so the report's existing views render it.
/// </summary>
public sealed class ReportPageSnapshotFile
{
    public string Format { get; set; } = "";
    public int FormatVersion { get; set; }
    public string ReportCode { get; set; } = "";
    public string LabKey { get; set; } = "";
    public string LabName { get; set; } = "";
    public string RunId { get; set; } = "";
    public string WeekFolder { get; set; } = "";
    public DateTime CapturedOnUtc { get; set; }
    public string Trigger { get; set; } = "";
    public string ModelType { get; set; } = "";
    public List<string> LogicChanges { get; set; } = [];
    public List<ReportPageSnapshotHighlightTab> HighlightTabs { get; set; } = [];
    public JsonElement Model { get; set; }

    /// <summary>
    /// The view model, bound to <see cref="ModelType"/>. A new instance on every read: the views and the
    /// viewer set page state on it, so two windows must never share one.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public object? BoundModel { get; private set; }

    /// <summary>A copy of this envelope with a freshly bound model.</summary>
    public ReportPageSnapshotFile Bind()
    {
        var type = ReportPageSnapshotReader.ModelTypeFor(ModelType)
                   ?? throw new NotSupportedException($"This snapshot holds a {ModelType}, which the snapshot viewer does not show.");
        var copy = (ReportPageSnapshotFile)MemberwiseClone();
        copy.BoundModel = Model.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null
            ? null
            : Model.Deserialize(type, ReportSnapshotJson.Options);
        return copy;
    }
}

public sealed record ReportPageSnapshotHighlightTab(string Title, string ReportCode, string? EmbedTabs);

public interface IReportPageSnapshotReader
{
    /// <summary>The snapshot file <paramref name="snapshotFileId"/> (its index row's BlobPath), bound; cached for a while.</summary>
    Task<ReportPageSnapshotFile> ReadAsync(long snapshotFileId, string blobPath, CancellationToken ct);
}

public sealed class ReportPageSnapshotReader : IReportPageSnapshotReader
{
    /// <summary>
    /// The view model types a snapshot may hold. Only these are bound: a ModelType string from the file
    /// never picks an arbitrary .NET type.
    /// </summary>
    private static readonly IReadOnlyDictionary<string, Type> ModelTypes = new Dictionary<string, Type>(StringComparer.Ordinal)
    {
        [typeof(PhiExecutiveSummaryViewModel).FullName!] = typeof(PhiExecutiveSummaryViewModel),
        [typeof(LisSummaryResult).FullName!] = typeof(LisSummaryResult),
        [typeof(LRN.ProductionReports.Models.ProductionReportViewModel).FullName!] = typeof(LRN.ProductionReports.Models.ProductionReportViewModel),
        [typeof(CollectionSummaryViewModel).FullName!] = typeof(CollectionSummaryViewModel),
        [typeof(DenialClaimReportViewModel).FullName!] = typeof(DenialClaimReportViewModel),
        [typeof(DenialInsightSnapshotModel).FullName!] = typeof(DenialInsightSnapshotModel),
        [typeof(ReportInsightsSnapshotModel).FullName!] = typeof(ReportInsightsSnapshotModel),
        // Denial Insight snapshots taken before the type moved into LabMetricsDashboard.
        ["LRN.SnapshotGenerator.DenialInsightSnapshotModel"] = typeof(DenialInsightSnapshotModel),
    };

    public static Type? ModelTypeFor(string? modelType) =>
        modelType is not null && ModelTypes.TryGetValue(modelType, out var type) ? type : null;

    private readonly IReportSnapshotFileStore _store;
    private readonly IMemoryCache _cache;

    public ReportPageSnapshotReader(IReportSnapshotFileStore store, IMemoryCache cache)
    {
        _store = store;
        _cache = cache;
    }

    public async Task<ReportPageSnapshotFile> ReadAsync(long snapshotFileId, string blobPath, CancellationToken ct)
    {
        // The parsed file is cached (the report's lazy tabs each ask for it; a file never changes under its
        // id), the model is bound per read.
        var key = $"rps|{snapshotFileId}";
        if (!_cache.TryGetValue(key, out ReportPageSnapshotFile? page) || page is null)
        {
            var bytes = await _store.ReadAsync(blobPath, ct);
            page = Parse(bytes);
            _cache.Set(key, page, new MemoryCacheEntryOptions
            {
                SlidingExpiration = TimeSpan.FromMinutes(20),
                AbsoluteExpirationRelativeToNow = TimeSpan.FromHours(2),
                Size = Math.Max(1, bytes.Length / 1024)
            });
        }
        return page.Bind();
    }

    /// <summary>Gzip JSON to the envelope (model unbound); throws when the type is not one the viewer shows.</summary>
    public static ReportPageSnapshotFile Parse(byte[] gzipJson)
    {
        using var input = new MemoryStream(gzipJson, writable: false);
        using var gzip = new GZipStream(input, CompressionMode.Decompress);
        var page = JsonSerializer.Deserialize<ReportPageSnapshotFile>(gzip, ReportSnapshotJson.Options)
                   ?? throw new InvalidDataException("The snapshot file is empty.");
        if (ModelTypeFor(page.ModelType) is null)
            throw new NotSupportedException($"This snapshot holds a {page.ModelType}, which the snapshot viewer does not show.");
        return page;
    }
}
