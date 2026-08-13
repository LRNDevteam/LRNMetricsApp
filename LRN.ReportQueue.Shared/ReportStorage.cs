using System.Text.Json;

namespace LRN.ReportQueue.Shared;

/// <summary>Bound from "ReportStorage" config section (web + worker share the same values).</summary>
public sealed class ReportStorageOptions
{
    /// <summary>Root folder on the VM, e.g. E:\LRN-Data\GeneratedReports. Must be OUTSIDE the web root.</summary>
    public string RootPath { get; set; } = @"E:\LRN-Data\GeneratedReports";

    /// <summary>Days a completed report stays downloadable. Default: one week.</summary>
    public int RetentionDays { get; set; } = 7;
}

/// <summary>
/// Builds the canonical report file location:
///   {Root}\{ReportType}\{yyyy}\{MonthName}\{UserName}\{Lab}_{ReportType}_{timestamp}.xlsx
/// e.g. E:\LRN-Data\GeneratedReports\PayerPolicyValidation\2026\July\jsmith\Phi_Life_PayerPolicyValidation_20260717143020.xlsx
/// </summary>
public static class ReportFilePathBuilder
{
    public static (string FileName, string FullPath) Build(
        string rootPath, string reportType, string labName, string userName, DateTime now)
    {
        var fileName = $"{Sanitize(labName)}_{Sanitize(reportType)}_{now:yyyyMMddHHmmss}.xlsx";
        return (fileName, Path.Combine(Folder(rootPath, reportType, userName, now), fileName));
    }

    /// <summary>
    /// Same folder layout, but the caller supplies the file name — used by reports that name
    /// themselves after the run they came from
    /// (e.g. <c>LIS_NorthWest_R20260806NWL0103_07.23.2026-07.29.2026.xlsx</c>) so a downloaded
    /// file identifies its lab, run and week without being opened.
    /// </summary>
    public static (string FileName, string FullPath) BuildNamed(
        string rootPath, string reportType, string userName, DateTime now, string fileNameWithoutExtension)
    {
        var safe = SanitizeFileName(fileNameWithoutExtension);
        if (string.IsNullOrWhiteSpace(safe)) safe = $"{Sanitize(reportType)}_{now:yyyyMMddHHmmss}";
        var fileName = $"{safe}.xlsx";
        return (fileName, Path.Combine(Folder(rootPath, reportType, userName, now), fileName));
    }

    /// <summary>
    /// Joins the non-empty parts with "_" — a missing run id or week folder collapses out
    /// instead of leaving "__" in the middle of the name.
    /// </summary>
    public static string ComposeName(params string?[] parts) =>
        string.Join("_", parts
            .Select(p => SanitizeFileName(p ?? string.Empty))
            .Where(p => p.Length > 0));

    private static string Folder(string rootPath, string reportType, string userName, DateTime now) =>
        Path.Combine(
            rootPath,
            Sanitize(reportType),
            now.Year.ToString(),
            now.ToString("MMMM", System.Globalization.CultureInfo.InvariantCulture),
            Sanitize(userName));

    /// <summary>
    /// Keeps dots and dashes (week folders look like "07.23.2026 - 07.29.2026") but drops
    /// path separators and other characters Windows rejects, and collapses whitespace.
    /// Unlike <see cref="Sanitize"/> this is for a name PART, not a whole path segment.
    /// </summary>
    public static string SanitizeFileName(string value)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var chars = (value ?? string.Empty)
            .Select(c => invalid.Contains(c) ? '-' : c)
            .Where(c => c != '"')
            .ToArray();
        var collapsed = string.Join(" ", new string(chars).Split(' ', StringSplitOptions.RemoveEmptyEntries));
        return collapsed.Replace(" ", string.Empty).Trim('_', '-', '.');
    }

    /// <summary>Strips path separators / invalid chars so user or lab names can never escape the root.</summary>
    public static string Sanitize(string value)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var chars = value.Where(c => !invalid.Contains(c) && c != '.' && c != ' ').ToArray();
        var safe = new string(chars);
        return string.IsNullOrWhiteSpace(safe) ? "Unknown" : safe;
    }
}

/// <summary>
/// Minimal reader for the per-lab dashboard config files
/// ({LabConfigFolder}\{LabName}.json with a root section named after the lab) —
/// lets the worker resolve each lab's DbConnectionString without duplicating
/// connection strings in its own appsettings.
/// </summary>
public sealed class LabDbConfig
{
    public required string LabName { get; init; }
    public bool DbEnabled { get; init; }
    public string? DbConnectionString { get; init; }
}

public static class LabDbConfigLoader
{
    public static LabDbConfig? Load(string configFolder, string labName)
    {
        var path = Path.Combine(configFolder, $"{labName}.json");
        if (!File.Exists(path))
            return null;

        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        if (!doc.RootElement.TryGetProperty(labName, out var section))
            return null;

        return new LabDbConfig
        {
            LabName = labName,
            DbEnabled = section.TryGetProperty("DBEnabled", out var en) && en.ValueKind == JsonValueKind.True,
            DbConnectionString = section.TryGetProperty("DbConnectionString", out var cs)
                ? cs.GetString()
                : null,
        };
    }

    public static List<LabDbConfig> LoadAll(string configFolder, IEnumerable<string> labNames) =>
        labNames
            .Select(l => Load(configFolder, l))
            .Where(c => c is { DbEnabled: true } && !string.IsNullOrWhiteSpace(c.DbConnectionString))
            .Cast<LabDbConfig>()
            .ToList();
}
