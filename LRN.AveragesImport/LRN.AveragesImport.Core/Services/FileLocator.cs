using System.Globalization;
using LRN.AveragesImport.Core.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LRN.AveragesImport.Core.Services;

public interface IFileLocator
{
    /// <summary>
    /// Finds the CSV for a given run/lab/file type, searching recursively under the lab's
    /// year folder (derived from the RunId's yyyyMMdd prefix), falling back to the whole
    /// lab folder. Returns null (with a warning logged) when nothing importable is found.
    /// </summary>
    string? FindFile(string folderName, string runId, string fileType);
}

public sealed class FileLocator : IFileLocator
{
    private readonly ILogger<FileLocator> _logger;
    private readonly IOptions<ImportSettings> _settings;

    public FileLocator(ILogger<FileLocator> logger, IOptions<ImportSettings> settings)
    {
        _logger = logger;
        _settings = settings;
    }

    public string? FindFile(string folderName, string runId, string fileType)
    {
        var labRoot = Path.Combine(_settings.Value.BasePath, folderName);
        if (!Directory.Exists(labRoot))
        {
            _logger.LogWarning("Lab folder not found: {LabRoot} (RunId {RunId})", labRoot, runId);
            return null;
        }

        // RunId starts with yyyyMMdd — use its year to narrow the search.
        var searchRoot = labRoot;
        if (runId.Length >= 8 &&
            DateTime.TryParseExact(runId[..8], "yyyyMMdd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var runDate))
        {
            var yearFolder = Path.Combine(labRoot, runDate.Year.ToString(CultureInfo.InvariantCulture));
            if (Directory.Exists(yearFolder))
                searchRoot = yearFolder;
        }

        var matches = Search(searchRoot, runId, fileType);
        if (matches.Length == 0 && !searchRoot.Equals(labRoot, StringComparison.OrdinalIgnoreCase))
            matches = Search(labRoot, runId, fileType);

        var csvFiles = matches.Where(f => f.EndsWith(".csv", StringComparison.OrdinalIgnoreCase)).ToArray();
        if (csvFiles.Length == 0)
        {
            var xlsx = matches.FirstOrDefault(f => f.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase));
            if (xlsx is not null)
            {
                _logger.LogWarning(
                    "Found only .xlsx for RunId {RunId} {FileType} ({File}) — xlsx is not yet supported, skipping",
                    runId, fileType, xlsx);
            }
            else
            {
                _logger.LogWarning("No {FileType} file found for RunId {RunId} under {SearchRoot}",
                    fileType, runId, searchRoot);
            }
            return null;
        }

        if (csvFiles.Length > 1)
        {
            var newest = csvFiles.OrderByDescending(File.GetLastWriteTimeUtc).First();
            _logger.LogWarning(
                "Multiple {FileType} files found for RunId {RunId} ({Count}); using most recent: {File}",
                fileType, runId, csvFiles.Length, newest);
            return newest;
        }

        return csvFiles[0];
    }

    private static string[] Search(string root, string runId, string fileType)
    {
        var csv = Directory.GetFiles(root, $"{runId}_*_{fileType}_*.csv", SearchOption.AllDirectories);
        var xlsx = Directory.GetFiles(root, $"{runId}_*_{fileType}_*.xlsx", SearchOption.AllDirectories);
        return csv.Concat(xlsx).ToArray();
    }
}
