namespace ClaimLineCSVDataCapture.Services;

/// <summary>
/// Finds the latest Claim Level and Line Level CSV files under a lab's base path.
/// Searches recursively through year/month/week folder structures.
/// "Latest" = highest LastWriteTimeUtc among all matching files.
/// </summary>
public static class CsvFileResolver
{
    private const string ClaimLevelKeyword = "Claim Level";
    private const string LineLevelKeyword  = "Line Level";

    /// <summary>
    /// Returns (filePath, weekFolder) for the latest CSV file matching the given keyword
    /// under <paramref name="basePath"/>, or null when none is found.
    /// weekFolder is the immediate parent folder name of the file.
    /// </summary>
    public static (string FilePath, string WeekFolder)? ResolveLatestClaimLevel(string basePath)
        => ResolveLatest(basePath, ClaimLevelKeyword);

    /// <summary>
    /// Returns (filePath, weekFolder) for the latest Line Level CSV file.
    /// </summary>
    public static (string FilePath, string WeekFolder)? ResolveLatestLineLevel(string basePath)
        => ResolveLatest(basePath, LineLevelKeyword);

    private static (string FilePath, string WeekFolder)? ResolveLatest(string basePath, string keyword)
    {
        if (string.IsNullOrWhiteSpace(basePath) || !Directory.Exists(basePath))
            return null;

        var latest = Directory
            .EnumerateFiles(basePath, "*.csv", SearchOption.AllDirectories)
            .Where(f => Path.GetFileName(f).Contains(keyword, StringComparison.OrdinalIgnoreCase))
            .Select(f => new FileInfo(f))
            .MaxBy(fi => fi.LastWriteTimeUtc);

        if (latest is null) return null;

        var weekFolder = Path.GetFileName(Path.GetDirectoryName(latest.FullName) ?? string.Empty);
        return (latest.FullName, weekFolder);
    }
}
