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
        var folder = Path.Combine(
            rootPath,
            Sanitize(reportType),
            now.Year.ToString(),
            now.ToString("MMMM", System.Globalization.CultureInfo.InvariantCulture),
            Sanitize(userName));
        return (fileName, Path.Combine(folder, fileName));
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
