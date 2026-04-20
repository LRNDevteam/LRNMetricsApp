namespace CodingMasterGenerator.Services;

/// <summary>
/// Finds the latest Claim Level and Line Level CSV files under a lab's ServerMastersPath
/// by walking all sub-folders. "Latest" = highest LastWriteTimeUtc among all matching files.
/// </summary>
public static class CsvFileResolver
{
    private const string LineLevelKeyword = "Line Level";
    private const string ClaimLevelKeyword = "Claim Level";

    /// <summary>
    /// Returns (filePath, weekFolder) for the latest Line Level CSV, or null when none is found.
    /// weekFolder is the immediate parent folder name of the file.
    /// </summary>
    public static (string FilePath, string WeekFolder)? ResolveLatestLineLevel(string serverMastersPath)
        => ResolveLatest(serverMastersPath, LineLevelKeyword);

    /// <summary>
    /// Returns (filePath, weekFolder) for the latest Claim Level CSV, or null when none is found.
    /// weekFolder is the immediate parent folder name of the file.
    /// </summary>
    public static (string FilePath, string WeekFolder)? ResolveLatestClaimLevel(string serverMastersPath)
        => ResolveLatest(serverMastersPath, ClaimLevelKeyword);

    /// <summary>
    /// Extracts the RunId from a CSV filename — the text before the first underscore.
    /// E.g. "20260312R0550_NorthWest_Line Level_03.02.2026 to 03.08.2026.csv" ? "20260312R0550".
    /// </summary>
    public static string ExtractRunId(string filePath)
    {
        var fileName = Path.GetFileNameWithoutExtension(filePath);
        var idx = fileName.IndexOf('_');
        return idx > 0 ? fileName[..idx] : fileName;
    }

    /// <summary>
    /// Scans the output folder for existing CodingMaster Excel files and returns
    /// the RunId embedded in the latest one, or null if none exist.
    /// Expected filename pattern: {LabName}_CodingMaster_{RunId}_{timestamp}.xlsx
    /// </summary>
    public static string? FindExistingRunId(string outputFolder, string labName)
    {
        if (string.IsNullOrWhiteSpace(outputFolder) || !Directory.Exists(outputFolder))
            return null;

        var prefix = $"{labName}_CodingMaster_";

        var latest = Directory
            .EnumerateFiles(outputFolder, "*.xlsx", SearchOption.TopDirectoryOnly)
            .Where(f => Path.GetFileName(f).StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            .Select(f => new FileInfo(f))
            .MaxBy(fi => fi.LastWriteTimeUtc);

        if (latest is null) return null;

        // Filename: {LabName}_CodingMaster_{RunId}_{timestamp}.xlsx
        var name = Path.GetFileNameWithoutExtension(latest.Name);
        var afterPrefix = name[prefix.Length..];
        var underscoreIdx = afterPrefix.IndexOf('_');
        return underscoreIdx > 0 ? afterPrefix[..underscoreIdx] : afterPrefix;
    }

    private static (string FilePath, string WeekFolder)? ResolveLatest(string serverMastersPath, string keyword)
    {
        if (string.IsNullOrWhiteSpace(serverMastersPath) || !Directory.Exists(serverMastersPath))
            return null;

        var latest = Directory
            .EnumerateFiles(serverMastersPath, "*.csv", SearchOption.AllDirectories)
            .Where(f => Path.GetFileName(f).Contains(keyword, StringComparison.OrdinalIgnoreCase))
            .Select(f => new FileInfo(f))
            .MaxBy(fi => fi.LastWriteTimeUtc);

        if (latest is null) return null;

        var weekFolder = Path.GetFileName(Path.GetDirectoryName(latest.FullName) ?? string.Empty);
        return (latest.FullName, weekFolder);
    }
}
