using System.Text.Json;
using System.Text.RegularExpressions;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Locates the most-recent insight JSON file for a specific lab inside
/// <see cref="LabCsvConfig.InsightPath"/> (searched recursively) and parses it
/// into a <see cref="PredictionInsight"/> ready for display.
///
/// Resolution order (first match wins):
///   1. Latest file whose <b>path</b> contains the lab name <b>AND</b> whose name contains "insights"
///   2. Latest file whose name contains "insights" anywhere under InsightPath (fallback)
///
/// Returns <c>null</c> when the path is missing, empty, or no matching file is found.
/// </summary>
public sealed class PredictionInsightLoader
{
    private readonly ILogger<PredictionInsightLoader> _logger;

    public PredictionInsightLoader(ILogger<PredictionInsightLoader> logger)
    {
        _logger = logger;
    }

    /// <summary>
    /// Recursively searches <paramref name="insightPath"/> for the latest insights JSON
    /// belonging to <paramref name="labName"/> and returns the parsed insight, or <c>null</c>.
    /// </summary>
    public PredictionInsight? Load(string? insightPath, string? labName = null)
    {
        if (string.IsNullOrWhiteSpace(insightPath))
            return null;

        if (!Directory.Exists(insightPath))
        {
            _logger.LogWarning("InsightPath does not exist: {Path}", insightPath);
            return null;
        }

        // Enumerate all *.json files whose name contains "insights"
        var candidates = Directory
            .EnumerateFiles(insightPath, "*.json", SearchOption.AllDirectories)
            .Where(f => Path.GetFileName(f).Contains("insights", StringComparison.OrdinalIgnoreCase))
            .ToList();

        if (candidates.Count == 0)
        {
            _logger.LogInformation("No insights JSON found in: {Path}", insightPath);
            return null;
        }

        // 1. Prefer a file whose full path contains the lab name (lab-specific subfolder)
        string? file = null;
        if (!string.IsNullOrWhiteSpace(labName))
        {
            file = candidates
                .Where(f => f.Contains(labName, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault();
        }

        // 2. Fallback: pick the globally latest insights file
        file ??= candidates
            .OrderByDescending(File.GetLastWriteTimeUtc)
            .First();

        _logger.LogInformation("Loading insight file for '{Lab}': {File}", labName ?? "(any)", file);

        try
        {
            var json = File.ReadAllText(file);
            return Parse(json, Path.GetFileName(file));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to read/parse insight file: {File}", file);
            return null;
        }
    }

    // ?? parser ??????????????????????????????????????????????????????????????

    private static readonly JsonDocumentOptions _lenientOpts = new()
    {
        AllowTrailingCommas = true,
        CommentHandling     = JsonCommentHandling.Skip,
    };

    private static PredictionInsight Parse(string outerJson, string fileName)
    {
        using var outer = JsonDocument.Parse(outerJson, _lenientOpts);
        var root = outer.RootElement;

        var reportTitle  = GetString(root, "report_title");
        var reportPeriod = GetString(root, "report_period");
        var generatedAt  = GetString(root, "generated_at");
        var modelUsed    = GetString(root, "model_used");

        // Support two formats:
        //   (a) Clean format — "sections" array lives directly at the root
        //   (b) AI raw format — sections are embedded in a "raw_response" code-fence string
        IReadOnlyList<InsightSection> sections;
        if (root.TryGetProperty("sections", out var sectionsEl))
            sections = ParseSectionsElement(sectionsEl);
        else
            sections = ParseRawResponse(GetString(root, "raw_response"));

        return new PredictionInsight
        {
            ReportTitle    = reportTitle,
            ReportPeriod   = reportPeriod,
            GeneratedAt    = generatedAt,
            ModelUsed      = modelUsed,
            Sections       = sections,
            SourceFileName = fileName,
        };
    }

    /// <summary>
    /// Extracts sections from an AI raw_response code-fence string.
    /// Strips the markdown fence, tolerates trailing commas and JS comments, then delegates to
    /// <see cref="ParseSectionsElement"/>.
    /// </summary>
    private static IReadOnlyList<InsightSection> ParseRawResponse(string rawResponse)
    {
        if (string.IsNullOrWhiteSpace(rawResponse))
            return [];

        // Strip ```json … ``` fence
        var fenceMatch = Regex.Match(rawResponse, @"```json\s*([\s\S]*?)```", RegexOptions.IgnoreCase);
        var innerJson  = fenceMatch.Success ? fenceMatch.Groups[1].Value : rawResponse;

        innerJson = StripComments(innerJson);
        innerJson = FixTrailingCommas(innerJson);
        innerJson = FixBrokenBulletArrays(innerJson);

        var opts = new JsonDocumentOptions
        {
            AllowTrailingCommas = true,
            CommentHandling     = JsonCommentHandling.Skip,
        };

        try
        {
            using var doc = JsonDocument.Parse(innerJson, opts);
            if (!doc.RootElement.TryGetProperty("sections", out var sectionsEl))
                return [];
            return ParseSectionsElement(sectionsEl);
        }
        catch
        {
            return [];
        }
    }

    /// <summary>Parses a "sections" JSON array element into a list of <see cref="InsightSection"/>.</summary>
    private static IReadOnlyList<InsightSection> ParseSectionsElement(JsonElement sectionsEl)
    {
        var result = new List<InsightSection>();
        foreach (var s in sectionsEl.EnumerateArray())
        {
            var subsections = new List<InsightSubsection>();

            if (s.TryGetProperty("subsections", out var subsEl))
            {
                foreach (var sub in subsEl.EnumerateArray())
                {
                    // ?? Format A: subsection is a plain string ????????????????
                    // e.g. "subsections": ["The model shows 99% accuracy...", ...]
                    // Treat the string as a single bullet with no separate title.
                    if (sub.ValueKind == JsonValueKind.String)
                    {
                        var text = sub.GetString() ?? string.Empty;
                        if (text.StartsWith("- ", StringComparison.Ordinal))
                            text = text[2..];
                        subsections.Add(new InsightSubsection
                        {
                            Title   = string.Empty,
                            Bullets = [text],
                        });
                        continue;
                    }

                    // ?? Format B: subsection is an object ?????????????????????
                    // e.g. "subsections": [{ "subsection_title": "...", "bullets": [...] }]
                    if (sub.ValueKind == JsonValueKind.Object)
                    {
                        var bullets = new List<string>();
                        if (sub.TryGetProperty("bullets", out var bulletsEl))
                        {
                            foreach (var b in bulletsEl.EnumerateArray())
                            {
                                var text = b.GetString() ?? string.Empty;
                                if (text.StartsWith("- ", StringComparison.Ordinal))
                                    text = text[2..];
                                bullets.Add(text);
                            }
                        }
                        subsections.Add(new InsightSubsection
                        {
                            Title   = GetString(sub, "subsection_title"),
                            Bullets = bullets,
                        });
                    }
                }
            }

            result.Add(new InsightSection
            {
                SectionNumber = s.TryGetProperty("section_number", out var numEl) ? numEl.GetInt32() : 0,
                Title         = GetString(s, "section_title"),
                Subsections   = subsections,
            });
        }
        return result;
    }

    private static string GetString(JsonElement el, string key) =>
        el.TryGetProperty(key, out var v) ? v.GetString() ?? string.Empty : string.Empty;

    // Remove JS-style // comments from a JSON string
    private static string StripComments(string json) =>
        Regex.Replace(json, @"//[^\n]*", string.Empty);

    // Remove trailing commas before } or ]
    private static string FixTrailingCommas(string json) =>
        Regex.Replace(json, @",\s*([}\]])", "$1");

    // Remove lines that are only a stray `"]` (broken bullet array continuation from AI output)
    // e.g.  "bullets": ["item1"],\n          "extra]"\n  — strips the orphaned line
    private static string FixBrokenBulletArrays(string json) =>
        Regex.Replace(json, @"^\s*""[^""]*\]""\s*$", string.Empty, RegexOptions.Multiline);
}
