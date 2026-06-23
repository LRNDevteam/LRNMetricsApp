namespace ClaimLineCSVDataCapture.Services;

/// <summary>
/// Finds the latest Claim Level and Line Level CSV files under a lab's base path.
/// Searches recursively through year/month/week folder structures.
/// "Latest" = highest LastWriteTimeUtc among all matching files.
/// </summary>
public static class CsvFileResolver
{
    private static readonly string[] ClaimLevelKeywords     = ["Claim Level", "ClaimLevel"];
    private static readonly string[] LineLevelKeywords      = ["Line Level",  "LineLevel"];
    private static readonly string[] ClientPaidListKeywords = ["Client Paid List", "ClientPaidList"];

    /// <summary>
    /// Resolves the latest matching TransactionDetail Adjustment .xlsx file.
    /// The keyword is supplied by the caller (from lab config
    /// <c>Paths.TransactionDetailAdjustmentKeyword</c>), e.g. "TransactionDetail Adjustment".
    /// When <paramref name="searchPath"/> is null or empty the caller should pass
    /// the lab's <c>ServerMastersPath</c> as a fallback.
    /// </summary>
    public static (string FilePath, string WeekFolder)? ResolveLatestTransactionDetailAdjustmentWithDiag(
        string searchPath, string keyword,
        out ResolveFailureReason reason, out int totalCount, out int matchedCount)
        => ResolveLatestWithDiag(searchPath, [keyword], "*.xlsx", out reason, out totalCount, out matchedCount);

    /// <summary>
    /// Returns (filePath, weekFolder) for the latest CSV file matching the given keyword
    /// under <paramref name="basePath"/>, or null when none is found.
    /// weekFolder is the immediate parent folder name of the file.
    /// </summary>
    public static (string FilePath, string WeekFolder)? ResolveLatestClaimLevel(string basePath)
        => ResolveLatest(basePath, ClaimLevelKeywords);

    /// <summary>
    /// Returns (filePath, weekFolder) for the latest Line Level CSV file.
    /// </summary>
    public static (string FilePath, string WeekFolder)? ResolveLatestLineLevel(string basePath)
        => ResolveLatest(basePath, LineLevelKeywords);

    /// <summary>
    /// Describes why <see cref="ResolveLatestClaimLevel"/> or <see cref="ResolveLatestLineLevel"/>
    /// returned null, for diagnostic logging at the call site.
    /// </summary>
    public enum ResolveFailureReason { None, PathMissing, NoCsvFiles, NoKeywordMatch }

    /// <summary>
    /// Resolves the latest matching CSV and also returns the failure reason when null is returned.
    /// </summary>
    public static (string FilePath, string WeekFolder)? ResolveLatestClaimLevelWithDiag(
        string basePath, out ResolveFailureReason reason, out int totalCsvCount, out int matchedCsvCount)
        => ResolveLatestWithDiag(basePath, ClaimLevelKeywords, out reason, out totalCsvCount, out matchedCsvCount);

    /// <summary>
    /// Resolves the latest matching CSV and also returns the failure reason when null is returned.
    /// </summary>
    public static (string FilePath, string WeekFolder)? ResolveLatestLineLevelWithDiag(
        string basePath, out ResolveFailureReason reason, out int totalCsvCount, out int matchedCsvCount)
        => ResolveLatestWithDiag(basePath, LineLevelKeywords, out reason, out totalCsvCount, out matchedCsvCount);

    /// <summary>
    /// Resolves the latest matching ClientPaidList .xlsx file (RisingTides "Master" file)
    /// and also returns the failure reason when null is returned.
    /// Unlike Claim/Line Level (.csv), ClientPaidList arrives as an Excel workbook.
    /// </summary>
    public static (string FilePath, string WeekFolder)? ResolveLatestClientPaidListWithDiag(
        string basePath, out ResolveFailureReason reason, out int totalCount, out int matchedCount)
        => ResolveLatestWithDiag(basePath, ClientPaidListKeywords, "*.xlsx", out reason, out totalCount, out matchedCount);

    private static (string FilePath, string WeekFolder)? ResolveLatest(string basePath, string[] keywords)
        => ResolveLatestWithDiag(basePath, keywords, "*.csv", out _, out _, out _);

    private static (string FilePath, string WeekFolder)? ResolveLatestWithDiag(
        string basePath, string[] keywords,
        out ResolveFailureReason reason, out int totalCsvCount, out int matchedCsvCount)
        => ResolveLatestWithDiag(basePath, keywords, "*.csv", out reason, out totalCsvCount, out matchedCsvCount);

    private static (string FilePath, string WeekFolder)? ResolveLatestWithDiag(
        string basePath, string[] keywords, string searchPattern,
        out ResolveFailureReason reason, out int totalCount, out int matchedCount)
    {
        totalCount   = 0;
        matchedCount = 0;

        if (string.IsNullOrWhiteSpace(basePath) || !Directory.Exists(basePath))
        {
            reason = ResolveFailureReason.PathMissing;
            return null;
        }

        var allFiles = Directory
            .EnumerateFiles(basePath, searchPattern, SearchOption.AllDirectories)
            // Exclude Excel lock/temp files (e.g., "~$ClientPaidList.xlsx") created while a
            // workbook is open.
            .Where(f => !Path.GetFileName(f).StartsWith("~$", StringComparison.Ordinal))
            .ToList();

        totalCount = allFiles.Count;

        if (totalCount == 0)
        {
            reason = ResolveFailureReason.NoCsvFiles;
            return null;
        }

        var matched = allFiles
            .Where(f => keywords.Any(k => Path.GetFileName(f).Contains(k, StringComparison.OrdinalIgnoreCase)))
            .Select(f => new FileInfo(f))
            .ToList();

        matchedCount = matched.Count;

        if (matchedCount == 0)
        {
            reason = ResolveFailureReason.NoKeywordMatch;
            return null;
        }

        var latest = matched.MaxBy(fi => fi.LastWriteTimeUtc)!;
        reason = ResolveFailureReason.None;
        var weekFolder = Path.GetFileName(Path.GetDirectoryName(latest.FullName) ?? string.Empty);
        return (latest.FullName, weekFolder);
    }
}
