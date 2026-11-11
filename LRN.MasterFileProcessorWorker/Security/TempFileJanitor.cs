using System.Text.RegularExpressions;
using LRN.MasterFileProcessorWorker.Logging;
using LRN.MasterFileProcessorWorker.Snapshots;
using Microsoft.Extensions.Options;

namespace LRN.MasterFileProcessorWorker.Security;

/// <summary>Settings for <see cref="TempFileJanitor"/>, section <c>Security:TempFiles</c>.</summary>
public sealed class TempFileOptions
{
    public const string SectionName = "Security:TempFiles";

    /// <summary>Master switch for the sweep. The per-run deletes in the worker happen either way.</summary>
    public bool SweepEnabled { get; set; } = true;

    /// <summary>A temp file older than this is an orphan: no run lasts this long.</summary>
    public int MaxAgeHours { get; set; } = 24;

    /// <summary>How often the sweep runs. It is cheap, but there is no reason to walk the folders every poll.</summary>
    public int SweepIntervalMinutes { get; set; } = 60;
}

/// <summary>
/// HIPAA checklist MF-03: a scheduled sweep for temp files a run left behind.
/// <para>
/// Each run already removes its own temp files in a <c>finally</c>. This catches what that cannot: a
/// service stopped or a machine restarted mid-run, a delete refused because a scanner held the file,
/// and files from before the per-run cleanup existed. Every one of these files is a full or partial
/// copy of a lab's claims, so leaving it on disk is leaving PHI on disk.
/// </para>
/// <para>
/// It only ever deletes the temp shapes this worker creates - never a published week-folder output,
/// never <c>LRN-RAWFILE\Archive</c>, never a log:
/// </para>
/// <list type="bullet">
///   <item><c>&lt;ReportOutputsRoot&gt;\LRN-RAWFILE\</c> (Archive excluded): the downloaded workbook and the
///         <c>*_RAW.csv</c> exports of a run that did not finish.</item>
///   <item><c>~staging_*</c> folders under each lab folder of <c>WatchFolder</c>.</item>
///   <item><c>*.download</c> partial downloads under <c>WatchFolder</c> and <c>LRN-RAWFILE</c>.</item>
///   <item>The Mode/Median temp workbooks (<c>&lt;guid&gt;_Median.xlsx</c> / <c>_Mode.xlsx</c>) in the temp folder.</item>
///   <item><c>*.parquet</c> in the snapshot work folder (<c>MasterDataSnapshot:WorkFolder</c>, default <c>%TEMP%\LRN-Snapshots</c>).</item>
/// </list>
/// </summary>
public sealed class TempFileJanitor
{
    private static readonly Regex ModeMedianTemp = new(@"^[0-9a-f]{32}_(Median|Mode)\.xlsx$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private readonly TempFileOptions _options;
    private readonly ImportOptions _import;
    private readonly MasterDataSnapshotOptions _snapshot;
    private readonly ILoggerService _fileLog;
    private readonly ILogger<TempFileJanitor> _logger;

    private DateTime _lastSweepUtc = DateTime.MinValue;

    public TempFileJanitor(
        IOptions<TempFileOptions> options,
        IOptions<ImportOptions> import,
        IOptions<MasterDataSnapshotOptions> snapshot,
        ILoggerService fileLog,
        ILogger<TempFileJanitor> logger)
    {
        _options = options.Value ?? new TempFileOptions();
        _import = import.Value;
        _snapshot = snapshot.Value ?? new MasterDataSnapshotOptions();
        _fileLog = fileLog;
        _logger = logger;
    }

    /// <summary>Sweeps when the interval has passed since the last sweep. Never throws.</summary>
    public void SweepIfDue()
    {
        if (!_options.SweepEnabled)
            return;

        var now = DateTime.UtcNow;
        if (now - _lastSweepUtc < TimeSpan.FromMinutes(Math.Max(1, _options.SweepIntervalMinutes)))
            return;

        _lastSweepUtc = now;

        try
        {
            var removed = Sweep(now - TimeSpan.FromHours(Math.Max(1, _options.MaxAgeHours)));

            if (removed > 0)
            {
                _logger.LogInformation("Temp file sweep removed {Count} orphaned item(s) older than {Hours}h.", removed, _options.MaxAgeHours);
                _fileLog.Info($"Temp file sweep removed {removed} orphaned item(s) older than {_options.MaxAgeHours}h.");
            }
        }
        catch (Exception ex)
        {
            // A sweep that fails is retried next interval; it must never take a run down with it.
            _logger.LogWarning(ex, "Temp file sweep failed.");
            _fileLog.Warn($"Temp file sweep failed: {ex.Message}");
        }
    }

    /// <summary>Deletes every orphan last written before <paramref name="cutoffUtc"/>. Returns how many went.</summary>
    public int Sweep(DateTime cutoffUtc)
    {
        var removed = 0;

        if (!string.IsNullOrWhiteSpace(_import.ReportOutputsRoot))
        {
            var rawRoot = Path.Combine(_import.ReportOutputsRoot, "LRN-RAWFILE");
            var archive = Path.Combine(rawRoot, "Archive");

            removed += DeleteFiles(rawRoot, "*", cutoffUtc, skipUnder: archive,
                keep: _import.KeepRawCsvExports ? f => f.EndsWith("_RAW.csv", StringComparison.OrdinalIgnoreCase) : null);
        }

        if (!string.IsNullOrWhiteSpace(_import.WatchFolder) && Directory.Exists(_import.WatchFolder))
        {
            foreach (var labFolder in SafeEnumerateDirectories(_import.WatchFolder))
            {
                foreach (var staging in SafeEnumerateDirectories(labFolder, "~staging_*"))
                {
                    if (Directory.GetLastWriteTimeUtc(staging) < cutoffUtc && TryDeleteDirectory(staging))
                        removed++;
                }
            }

            removed += DeleteFiles(_import.WatchFolder, "*.download", cutoffUtc);
        }

        foreach (var file in SafeEnumerateFiles(Path.GetTempPath(), "*.xlsx", SearchOption.TopDirectoryOnly))
        {
            if (ModeMedianTemp.IsMatch(Path.GetFileName(file)) && TryDeleteFileOlderThan(file, cutoffUtc))
                removed++;
        }

        var snapshotWork = string.IsNullOrWhiteSpace(_snapshot.WorkFolder)
            ? Path.Combine(Path.GetTempPath(), "LRN-Snapshots")
            : _snapshot.WorkFolder;

        // Parquet only: WorkFolder is configurable and may be shared with other things.
        removed += DeleteFiles(snapshotWork, "*.parquet", cutoffUtc);

        return removed;
    }

    private int DeleteFiles(string root, string pattern, DateTime cutoffUtc, string? skipUnder = null,
        Func<string, bool>? keep = null)
    {
        if (!Directory.Exists(root))
            return 0;

        var removed = 0;
        var skip = skipUnder is null ? null : Path.GetFullPath(skipUnder).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;

        foreach (var file in SafeEnumerateFiles(root, pattern, SearchOption.AllDirectories))
        {
            if (skip is not null && Path.GetFullPath(file).StartsWith(skip, StringComparison.OrdinalIgnoreCase))
                continue;

            if (keep?.Invoke(file) == true)
                continue;

            if (TryDeleteFileOlderThan(file, cutoffUtc))
                removed++;
        }

        return removed;
    }

    private bool TryDeleteFileOlderThan(string file, DateTime cutoffUtc)
    {
        try
        {
            if (File.GetLastWriteTimeUtc(file) >= cutoffUtc)
                return false;

            File.Delete(file);
            _fileLog.Info($"Temp file sweep: deleted {file}");
            return true;
        }
        catch (Exception ex)
        {
            _fileLog.Warn($"Temp file sweep: could not delete {file}: {ex.Message}");
            return false;
        }
    }

    private bool TryDeleteDirectory(string folder)
    {
        try
        {
            Directory.Delete(folder, recursive: true);
            _fileLog.Info($"Temp file sweep: deleted {folder}");
            return true;
        }
        catch (Exception ex)
        {
            _fileLog.Warn($"Temp file sweep: could not delete {folder}: {ex.Message}");
            return false;
        }
    }

    private static IEnumerable<string> SafeEnumerateFiles(string root, string pattern, SearchOption option)
    {
        try
        {
            return Directory.Exists(root)
                ? Directory.EnumerateFiles(root, pattern, new EnumerationOptions
                {
                    RecurseSubdirectories = option == SearchOption.AllDirectories,
                    IgnoreInaccessible = true
                }).ToList()
                : Enumerable.Empty<string>();
        }
        catch (IOException) { return Enumerable.Empty<string>(); }
        catch (UnauthorizedAccessException) { return Enumerable.Empty<string>(); }
    }

    private static IEnumerable<string> SafeEnumerateDirectories(string root, string pattern = "*")
    {
        try
        {
            return Directory.EnumerateDirectories(root, pattern, SearchOption.TopDirectoryOnly).ToList();
        }
        catch (IOException) { return Enumerable.Empty<string>(); }
        catch (UnauthorizedAccessException) { return Enumerable.Empty<string>(); }
    }
}
