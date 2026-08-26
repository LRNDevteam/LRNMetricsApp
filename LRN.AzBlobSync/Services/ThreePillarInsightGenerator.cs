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

    public Task RunForLatestWeekAsync(CancellationToken ct)
    {
        var week = _stateStore.Load().RecentFolderName?.Trim();
        if (string.IsNullOrWhiteSpace(week))
        {
            _logger.LogInformation("[Foundry] No latest week folder. Skipping insights.");
            return Task.CompletedTask;
        }

        return RunForWeekAsync(week, ct);
    }

    /// <summary>
    /// Generates insights for one uploaded week. Called only after that week's inputs were copied to blob.
    /// </summary>
    public async Task RunForWeekAsync(string weekFolder, CancellationToken ct)
    {
        if (!_foundry.Enabled)
        {
            _logger.LogInformation("[Foundry] Disabled in appsettings. Skipping insight generation.");
            return;
        }

        weekFolder = weekFolder.Trim();
        if (string.IsNullOrWhiteSpace(weekFolder))
        {
            _logger.LogInformation("[Foundry] Empty week folder. Skipping insights.");
            return;
        }

        var window = string.IsNullOrWhiteSpace(_foundry.TrailingWindow) ? "m12" : _foundry.TrailingWindow.Trim();
        var inputPrefix = _blob.BlobPrefix.Trim().Trim('/');
        var lisPath = $"{inputPrefix}/{weekFolder}/{window}/LIS.json";
        var pmsPath = $"{inputPrefix}/{weekFolder}/{window}/PMS.json";
        var cashPath = $"{inputPrefix}/{weekFolder}/{window}/Cash.json";

        var lis = await _uploader.TryDownloadTextAsync(lisPath, ct);
        var pms = await _uploader.TryDownloadTextAsync(pmsPath, ct);
        var cash = await _uploader.TryDownloadTextAsync(cashPath, ct);
        if (lis is null || pms is null || cash is null)
        {
            _logger.LogWarning(
                "[Foundry] Missing blob input for '{Week}' {Window}. LIS={Lis} PMS={Pms} Cash={Cash}",
                weekFolder, window, lis is not null, pms is not null, cash is not null);
            return;
        }

        var promptPath = Path.Combine(AppContext.BaseDirectory, "Prompts", "threepillar-insights-system.txt");
        if (!File.Exists(promptPath))
            throw new FileNotFoundException("Insight system prompt not found.", promptPath);

        var systemPrompt = await File.ReadAllTextAsync(promptPath, ct);
        var userPrompt = BuildUserPrompt(weekFolder, lis, pms, cash);

        _logger.LogInformation(
            "[Foundry] Generating insights for blob week '{Week}' ({Window}) — overwrites existing insights.json if present.",
            weekFolder, window);
        var json = await _client.CompleteJsonAsync(systemPrompt, userPrompt, ct);
        json = NormalizeInsightEnvelope(json, weekFolder);

        var outBlob = $"{_foundry.OutputBlobPrefix.Trim().Trim('/')}/{weekFolder}/insights.json";
        await _uploader.UploadTextAsync(outBlob, json, ct);

        if (!string.IsNullOrWhiteSpace(_blob.WatchPath))
        {
            var localDir = Path.Combine(_blob.WatchPath, weekFolder);
            Directory.CreateDirectory(localDir);
            var localPath = Path.Combine(localDir, "insights.json");
            await File.WriteAllTextAsync(localPath, json, new UTF8Encoding(false), ct);
            _logger.LogInformation("[Foundry] Wrote local {Path}", localPath);
        }
    }

    private string BuildUserPrompt(string weekFolder, string lis, string pms, string cash)
    {
        var sb = new StringBuilder();
        sb.AppendLine("Lab: Beech_Tree");
        sb.AppendLine($"Week folder: {weekFolder}");
        sb.AppendLine($"Model / deployment: {_foundry.DeploymentName}");
        sb.AppendLine($"Trailing window: {_foundry.TrailingWindow}");
        sb.AppendLine();
        sb.AppendLine("Generate ONE combined insights JSON for all three pillars below.");
        sb.AppendLine("Use each file's charts[].graphTitle exactly as section_title.");
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

    /// <summary>
    /// Accepts either the new pillars[] shape or legacy root sections[], and always
    /// persists a dashboard-friendly root sections[] (plus pillars when present).
    /// </summary>
    private string NormalizeInsightEnvelope(string json, string weekFolder)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
            throw new InvalidOperationException("Foundry JSON root must be an object.");

        var hasPillars = root.TryGetProperty("pillars", out var pillarsEl)
                         && pillarsEl.ValueKind == JsonValueKind.Array
                         && pillarsEl.GetArrayLength() > 0;
        var hasSections = root.TryGetProperty("sections", out var sectionsEl)
                          && sectionsEl.ValueKind == JsonValueKind.Array
                          && sectionsEl.GetArrayLength() > 0;

        if (!hasPillars && !hasSections)
            throw new InvalidOperationException("Foundry JSON is missing both pillars[] and sections[].");

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

            CopyNumberIfPresent(writer, root, "trailing_months");
            CopyNumberIfPresent(writer, root, "day_window");
            if (root.TryGetProperty("scope", out var scope) && scope.ValueKind == JsonValueKind.String)
                writer.WriteString("scope", scope.GetString());

            // Keep original pillars when model returned them.
            if (hasPillars)
            {
                writer.WritePropertyName("pillars");
                pillarsEl.WriteTo(writer);
            }

            // Dashboard Insight tab reads root sections[].
            writer.WritePropertyName("sections");
            if (hasPillars)
                WriteFlattenedSectionsFromPillars(writer, pillarsEl);
            else
                WriteNormalizedLegacySections(writer, sectionsEl);

            writer.WriteEndObject();
        }

        var normalized = Encoding.UTF8.GetString(ms.ToArray());
        _logger.LogInformation(
            "[Foundry] Normalized insights envelope for '{Week}' (pillars={HasPillars}, sectionsFlattened=true).",
            weekFolder, hasPillars);
        return normalized;
    }

    private static void WriteFlattenedSectionsFromPillars(Utf8JsonWriter writer, JsonElement pillarsEl)
    {
        writer.WriteStartArray();
        var sectionNumber = 0;
        foreach (var pillar in pillarsEl.EnumerateArray())
        {
            var pillarLabel = pillar.TryGetProperty("pillar_section", out var ps) && ps.ValueKind == JsonValueKind.String
                ? ps.GetString()
                : pillar.TryGetProperty("pillar", out var p) && p.ValueKind == JsonValueKind.String
                    ? p.GetString()
                    : "Pillar";

            if (!pillar.TryGetProperty("sections", out var secs) || secs.ValueKind != JsonValueKind.Array)
                continue;

            foreach (var sec in secs.EnumerateArray())
            {
                sectionNumber++;
                var title = GetString(sec, "section_title");
                if (string.IsNullOrWhiteSpace(title))
                    title = $"Section {sectionNumber}";

                var displayTitle = string.IsNullOrWhiteSpace(pillarLabel)
                    ? title
                    : $"{pillarLabel}: {title}";

                var subtitle = GetString(sec, "subtitle");
                var insights = ReadStringArray(sec, "insights");
                if (insights.Count == 0)
                    insights = ReadBulletsFromSubsections(sec);

                writer.WriteStartObject();
                writer.WriteNumber("section_number",
                    sec.TryGetProperty("section_number", out var sn) && sn.TryGetInt32(out var snVal)
                        ? snVal
                        : sectionNumber);
                writer.WriteString("section_title", displayTitle);
                writer.WritePropertyName("subsections");
                writer.WriteStartArray();
                writer.WriteStartObject();
                writer.WriteString("subsection_title",
                    string.IsNullOrWhiteSpace(subtitle) ? "Insights" : subtitle);
                writer.WritePropertyName("bullets");
                writer.WriteStartArray();
                foreach (var bullet in insights)
                    writer.WriteStringValue(bullet);
                writer.WriteEndArray();
                writer.WriteEndObject();
                writer.WriteEndArray();
                writer.WriteEndObject();
            }
        }
        writer.WriteEndArray();
    }

    private static void WriteNormalizedLegacySections(Utf8JsonWriter writer, JsonElement sectionsEl)
    {
        writer.WriteStartArray();
        foreach (var sec in sectionsEl.EnumerateArray())
        {
            writer.WriteStartObject();
            if (sec.TryGetProperty("section_number", out var sn) && sn.TryGetInt32(out var snVal))
                writer.WriteNumber("section_number", snVal);
            else
                writer.WriteNumber("section_number", 0);

            writer.WriteString("section_title", GetString(sec, "section_title"));

            writer.WritePropertyName("subsections");
            writer.WriteStartArray();

            if (sec.TryGetProperty("subsections", out var subs) && subs.ValueKind == JsonValueKind.Array)
            {
                foreach (var sub in subs.EnumerateArray())
                    sub.WriteTo(writer);
            }
            else
            {
                var insights = ReadStringArray(sec, "insights");
                writer.WriteStartObject();
                writer.WriteString("subsection_title",
                    string.IsNullOrWhiteSpace(GetString(sec, "subtitle")) ? "Insights" : GetString(sec, "subtitle"));
                writer.WritePropertyName("bullets");
                writer.WriteStartArray();
                foreach (var bullet in insights)
                    writer.WriteStringValue(bullet);
                writer.WriteEndArray();
                writer.WriteEndObject();
            }

            writer.WriteEndArray();
            writer.WriteEndObject();
        }
        writer.WriteEndArray();
    }

    private static List<string> ReadStringArray(JsonElement parent, string name)
    {
        var list = new List<string>();
        if (!parent.TryGetProperty(name, out var arr) || arr.ValueKind != JsonValueKind.Array)
            return list;
        foreach (var item in arr.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String)
                continue;
            var text = (item.GetString() ?? string.Empty).Trim();
            if (text.StartsWith("- ", StringComparison.Ordinal))
                text = text[2..].Trim();
            if (text.Length > 0)
                list.Add(text);
        }
        return list;
    }

    private static List<string> ReadBulletsFromSubsections(JsonElement sec)
    {
        var list = new List<string>();
        if (!sec.TryGetProperty("subsections", out var subs) || subs.ValueKind != JsonValueKind.Array)
            return list;
        foreach (var sub in subs.EnumerateArray())
        {
            if (sub.ValueKind == JsonValueKind.String)
            {
                var text = (sub.GetString() ?? string.Empty).Trim();
                if (text.StartsWith("- ", StringComparison.Ordinal))
                    text = text[2..].Trim();
                if (text.Length > 0)
                    list.Add(text);
                continue;
            }
            if (sub.ValueKind != JsonValueKind.Object)
                continue;
            list.AddRange(ReadStringArray(sub, "bullets"));
        }
        return list;
    }

    private static string GetString(JsonElement el, string key)
        => el.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? string.Empty
            : string.Empty;

    private static void WriteOrDefault(Utf8JsonWriter writer, JsonElement root, string name, string fallback)
    {
        var value = root.TryGetProperty(name, out var el) && el.ValueKind == JsonValueKind.String
            ? el.GetString()
            : fallback;
        writer.WriteString(name, string.IsNullOrWhiteSpace(value) ? fallback : value);
    }

    private static void CopyNumberIfPresent(Utf8JsonWriter writer, JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var el))
            return;
        if (el.ValueKind == JsonValueKind.Number && el.TryGetInt32(out var i))
            writer.WriteNumber(name, i);
        else if (el.ValueKind == JsonValueKind.Number && el.TryGetDouble(out var d))
            writer.WriteNumber(name, d);
    }
}
