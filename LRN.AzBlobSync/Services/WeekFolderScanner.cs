using LRN.AzBlobSync.Models;

namespace LRN.AzBlobSync.Services;

public sealed class WeekFolderScanner
{
    public static readonly string[] RequiredNames = ["LIS.json", "PMS.json", "Cash.json"];

    private readonly BlobSyncOptions _options;
    private readonly ILogger<WeekFolderScanner> _logger;

    public WeekFolderScanner(BlobSyncOptions options, ILogger<WeekFolderScanner> logger)
    {
        _options = options;
        _logger = logger;
    }

    public IReadOnlyList<DirectoryInfo> ListWeekFolders()
    {
        var root = _options.WatchPath;
        if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
            return [];

        return Directory.GetDirectories(root)
            .Select(p => new DirectoryInfo(p))
            .Where(d => !d.Name.StartsWith('.'))
            .OrderByDescending(d => WeekSortKey(d.Name))
            .ThenByDescending(d => d.LastWriteTimeUtc)
            .ToList();
    }

    /// <summary>Later week-range end date sorts first. Names like 07.31.2026 - 08.06.2026.</summary>
    public static DateTime WeekSortKey(string weekFolderName)
    {
        var parts = weekFolderName.Split('-', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        var end = parts.Length > 0 ? parts[^1] : weekFolderName;
        if (DateTime.TryParseExact(end, ["MM.dd.yyyy", "M.d.yyyy", "MM.dd.yy"],
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.None, out var dt))
            return dt;
        return DateTime.MinValue;
    }

    /// <summary>
    /// A week folder is ready when at least one month window (usually m12)
    /// contains LIS.json, PMS.json, and Cash.json, files are not still being
    /// written, and no .tmp files remain.
    /// </summary>
    public bool TryGetReadyJsonFiles(DirectoryInfo weekFolder, out List<FileInfo> jsonFiles, out string reason)
    {
        jsonFiles = [];
        reason = string.Empty;

        var required = (_options.RequiredJsonFiles.Count > 0 ? _options.RequiredJsonFiles : RequiredNames.ToList())
            .Select(n => n.Trim())
            .Where(n => n.Length > 0)
            .ToArray();

        var tmpFiles = weekFolder.EnumerateFiles("*.tmp", SearchOption.AllDirectories).ToList();
        if (tmpFiles.Count > 0)
        {
            reason = $"{tmpFiles.Count} .tmp file(s) still present";
            return false;
        }

        var allJson = weekFolder.EnumerateFiles("*.json", SearchOption.AllDirectories)
            .Where(f => !f.Name.Equals("latest-folder.json", StringComparison.OrdinalIgnoreCase))
            .ToList();

        var groups = allJson
            .GroupBy(f => f.DirectoryName ?? string.Empty, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var completeGroups = groups
            .Where(g => required.All(req =>
                g.Any(f => f.Name.Equals(req, StringComparison.OrdinalIgnoreCase))))
            .ToList();

        if (completeGroups.Count == 0)
        {
            var found = string.Join(", ", allJson.Select(f => f.Name).Distinct(StringComparer.OrdinalIgnoreCase));
            reason = $"waiting for {string.Join(", ", required)} (found: {(found.Length == 0 ? "none" : found)})";
            return false;
        }

        jsonFiles = completeGroups.SelectMany(g => g).DistinctBy(f => f.FullName).ToList();

        var settle = TimeSpan.FromSeconds(Math.Max(1, _options.SettleSeconds));
        var newest = jsonFiles.Max(f => f.LastWriteTimeUtc);
        var age = DateTime.UtcNow - newest;
        if (age < settle)
        {
            reason = $"files still settling ({age.TotalSeconds:0.0}s < {settle.TotalSeconds:0}s)";
            jsonFiles = [];
            return false;
        }

        if (jsonFiles.Any(IsLocked))
        {
            reason = "one or more JSON files are still locked";
            jsonFiles = [];
            return false;
        }

        _logger.LogDebug(
            "[BlobSync] Week '{Week}' ready with {Count} JSON file(s).",
            weekFolder.Name, jsonFiles.Count);
        return true;
    }

    public static string Fingerprint(IEnumerable<FileInfo> files)
    {
        var parts = files
            .OrderBy(f => f.FullName, StringComparer.OrdinalIgnoreCase)
            .Select(f => $"{f.Name}|{f.Length}|{f.LastWriteTimeUtc:O}");
        return string.Join(";", parts);
    }

    private static bool IsLocked(FileInfo file)
    {
        try
        {
            using var stream = file.Open(FileMode.Open, FileAccess.Read, FileShare.Read);
            return false;
        }
        catch (IOException)
        {
            return true;
        }
    }
}
