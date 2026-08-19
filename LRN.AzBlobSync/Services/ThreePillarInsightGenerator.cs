using System.Text;
using System.Text.Json;
using LRN.AzBlobSync.Models;

namespace LRN.AzBlobSync.Services;

/// <summary>
/// Reads LIS/PMS/Cash from blob Beech_Tree_inputs, calls Foundry, writes
/// Beech_Tree_Outputs/{week}/insights.json and a local copy for the dashboard.
/// </summary>
public sealed class ThreePillarInsightGenerator
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private readonly BlobSyncOptions _blob;
    private readonly FoundryOptions _foundry;
    private readonly AzureBlobUploader _uploader;
    private readonly LatestFolderStateStore _stateStore;
    private readonly FoundryInsightClient _client;
    private readonly ILogger<ThreePillarInsightGenerator> _logger;

    public ThreePillarInsightGenerator(
        BlobSyncOptions blob,
        FoundryOptions foundry,
        AzureBlobUploader uploader,
        LatestFolderStateStore stateStore,
        FoundryInsightClient client,
        ILogger<ThreePillarInsightGenerator> logger)
    {
        _blob = blob;
        _foundry = foundry;
        _uploader = uploader;
        _stateStore = stateStore;
        _client = client;
        _logger = logger;
    }

    public async Task RunForLatestWeekAsync(CancellationToken ct)
    {
        if (!_foundry.Enabled)
        {
            _logger.LogInformation("[Foundry] Disabled in appsettings. Skipping insight generation.");
            return;
        }

        var week = await ResolveLatestWeekAsync(ct);
        if (string.IsNullOrWhiteSpace(week))
        {
            _logger.LogInformation("[Foundry] No latest week folder. Skipping insights.");
            return;
        }

        var window = string.IsNullOrWhiteSpace(_foundry.TrailingWindow) ? "m12" : _foundry.TrailingWindow.Trim();
        var inputPrefix = _blob.BlobPrefix.Trim().Trim('/');
        var lisPath = $"{inputPrefix}/{week}/{window}/LIS.json";
        var pmsPath = $"{inputPrefix}/{week}/{window}/PMS.json";
        var cashPath = $"{inputPrefix}/{week}/{window}/Cash.json";

        var lis = await _uploader.TryDownloadTextAsync(lisPath, ct);
        var pms = await _uploader.TryDownloadTextAsync(pmsPath, ct);
        var cash = await _uploader.TryDownloadTextAsync(cashPath, ct);
        if (lis is null || pms is null || cash is null)
        {
            _logger.LogWarning(
                "[Foundry] Missing blob input for '{Week}' {Window}. LIS={Lis} PMS={Pms} Cash={Cash}",
                week, window, lis is not null, pms is not null, cash is not null);
            return;
        }

        var promptPath = Path.Combine(AppContext.BaseDirectory, "Prompts", "threepillar-insights-system.txt");
        if (!File.Exists(promptPath))
            throw new FileNotFoundException("Insight system prompt not found.", promptPath);

        var systemPrompt = await File.ReadAllTextAsync(promptPath, ct);
        var userPrompt = BuildUserPrompt(week, lis, pms, cash);

        _logger.LogInformation("[Foundry] Generating insights for blob week '{Week}' ({Window}).", week, window);
        var json = await _client.CompleteJsonAsync(systemPrompt, userPrompt, ct);
        json = EnsureEnvelope(json, week);

        var outBlob = $"{_foundry.OutputBlobPrefix.Trim().Trim('/')}/{week}/insights.json";
        await _uploader.UploadTextAsync(outBlob, json, ct);

        if (!string.IsNullOrWhiteSpace(_blob.WatchPath))
        {
            var localDir = Path.Combine(_blob.WatchPath, week);
            Directory.CreateDirectory(localDir);
            var localPath = Path.Combine(localDir, "insights.json");
            await File.WriteAllTextAsync(localPath, json, new UTF8Encoding(false), ct);
            _logger.LogInformation("[Foundry] Wrote local {Path}", localPath);
        }
    }

    private async Task<string?> ResolveLatestWeekAsync(CancellationToken ct)
    {
        var prefix = _blob.BlobPrefix.Trim().Trim('/');
        var latestJson = await _uploader.TryDownloadTextAsync($"{prefix}/{AzureBlobUploader.LatestBlobName}", ct);
        if (!string.IsNullOrWhiteSpace(latestJson))
        {
            try
            {
                var state = JsonSerializer.Deserialize<LatestFolderState>(latestJson, JsonOpts);
                if (!string.IsNullOrWhiteSpace(state?.RecentFolderName))
                    return state.RecentFolderName.Trim();
            }
            catch (JsonException ex)
            {
                _logger.LogWarning(ex, "[Foundry] Could not parse blob latest-folder.json.");
            }
        }

        var local = _stateStore.Load().RecentFolderName?.Trim();
        return string.IsNullOrWhiteSpace(local) ? null : local;
    }

    private string BuildUserPrompt(string weekFolder, string lis, string pms, string cash)
    {
        var sb = new StringBuilder();
        sb.AppendLine("Lab: Beech_Tree");
        sb.AppendLine($"Week folder: {weekFolder}");
        sb.AppendLine($"Model / deployment: {_foundry.DeploymentName}");
        sb.AppendLine($"Trailing window: {_foundry.TrailingWindow}");
        sb.AppendLine();
        sb.AppendLine("LIS.json:");
        sb.AppendLine(ThreePillarJsonCompactor.Compact(lis));
        sb.AppendLine();
        sb.AppendLine("PMS.json:");
        sb.AppendLine(ThreePillarJsonCompactor.Compact(pms));
        sb.AppendLine();
        sb.AppendLine("Cash.json:");
        sb.AppendLine(ThreePillarJsonCompactor.Compact(cash));
        return sb.ToString();
    }

    private string EnsureEnvelope(string json, string weekFolder)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("sections", out _))
            throw new InvalidOperationException("Foundry JSON is missing a sections array.");

        using var ms = new MemoryStream();
        using (var writer = new Utf8JsonWriter(ms, new JsonWriterOptions { Indented = true }))
        {
            writer.WriteStartObject();
            WriteOrDefault(writer, root, "report_title", "Beech Tree Three-Pillar Insights");
            WriteOrDefault(writer, root, "report_period", weekFolder);
            WriteOrDefault(writer, root, "generated_at", DateTime.UtcNow.ToString("o"));
            WriteOrDefault(writer, root, "model_used", _foundry.DeploymentName);
            WriteOrDefault(writer, root, "lab_name", "Beech_Tree");
            if (root.TryGetProperty("headline", out var h) && h.ValueKind == JsonValueKind.String)
                writer.WriteString("headline", h.GetString());
            writer.WritePropertyName("sections");
            root.GetProperty("sections").WriteTo(writer);
            writer.WriteEndObject();
        }

        return Encoding.UTF8.GetString(ms.ToArray());
    }

    private static void WriteOrDefault(Utf8JsonWriter writer, JsonElement root, string name, string fallback)
    {
        var value = root.TryGetProperty(name, out var el) && el.ValueKind == JsonValueKind.String
            ? el.GetString()
            : fallback;
        writer.WriteString(name, string.IsNullOrWhiteSpace(value) ? fallback : value);
    }
}
