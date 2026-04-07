namespace CaptureDataApp.Services;

/// <summary>
/// Finds the latest CodingValidated Excel report under a Reports root folder.
/// Works with any nesting depth: flat, yyyy\month\week, or mixed.
/// "Latest" = highest LastWriteTimeUtc among all matching files.
/// </summary>
public static class ReportFileResolver
{
    private const string ReportKeyword = "CodingValidated";

    /// <summary>
    /// Returns (filePath, weekFolder) for the latest CodingValidated report
    /// under <paramref name="reportsRoot"/>, or null when none is found.
    /// weekFolder is the immediate parent folder name of the file.
    /// </summary>
    public static (string FilePath, string WeekFolder)? ResolveLatest(string reportsRoot)
    {
        if (string.IsNullOrWhiteSpace(reportsRoot) || !Directory.Exists(reportsRoot))
            return null;

        var latest = Directory
            .EnumerateFiles(reportsRoot, "*.xlsx", SearchOption.AllDirectories)
            .Where(f => Path.GetFileName(f).Contains(ReportKeyword, StringComparison.OrdinalIgnoreCase))
            .Select(f => new FileInfo(f))
            .MaxBy(fi => fi.LastWriteTimeUtc);

        if (latest is null) return null;

        var weekFolder = Path.GetFileName(Path.GetDirectoryName(latest.FullName) ?? string.Empty);
        return (latest.FullName, weekFolder);
    }
}
