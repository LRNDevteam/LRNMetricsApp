using System.Collections.Concurrent;
using System.Data;
using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using LabMetricsDashboard.Services.ReportSnapshots;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services.RevenueAnalysis;

public interface IRevenueAnalysisService
{
    /// <summary>Starts building a dashboard in the background (or reuses today's identical one).</summary>
    RevenueAnalysisJob Start(RevenueAnalysisRequest request);

    RevenueAnalysisJob? GetJob(string jobId);

    RevenueAnalysisMeta? GetMeta(string token);

    /// <summary>Path of the stored page (gzip-compressed HTML), or null when it has expired.</summary>
    string? GetFilePath(string token);

    /// <summary>The lab's dashboards still on disk, newest first.</summary>
    IReadOnlyList<RevenueAnalysisMeta> ListForLab(string labKey);
}

/// <summary>
/// Builds Revenue Analysis dashboards: reads one lab's Claim Level and Line Level data - live from
/// the lab database or from a weekly Parquet snapshot - and writes the report team's dashboard page
/// filled with it (<see cref="RevenueAnalysisHtmlWriter"/>).
/// <para>A build reads every claim in the DOS window, so it runs as a background job the launcher
/// page polls rather than inside the request. At most <c>RevenueAnalysis:MaxConcurrentBuilds</c>
/// (default 2) run at once. Pages are stored gzip-compressed under <c>RevenueAnalysis:OutputFolder</c>
/// (default %TEMP%\LabMetricsDashboard\RevenueAnalysis) for <c>RevenueAnalysis:RetentionHours</c>
/// (default 24), and a request identical to one already built today reuses it.</para>
/// </summary>
public sealed class RevenueAnalysisService : IRevenueAnalysisService
{
    private static readonly JsonSerializerOptions MetaJson = new() { WriteIndented = true };

    private readonly IServiceScopeFactory _scopes;
    private readonly IConfiguration _configuration;
    private readonly ILogger<RevenueAnalysisService> _logger;
    private readonly ConcurrentDictionary<string, RevenueAnalysisJob> _jobs = new();
    private readonly SemaphoreSlim _gate;
    private readonly string _folder;

    public RevenueAnalysisService(IServiceScopeFactory scopes, IConfiguration configuration, ILogger<RevenueAnalysisService> logger)
    {
        _scopes = scopes;
        _configuration = configuration;
        _logger = logger;
        _gate = new SemaphoreSlim(Math.Max(1, configuration.GetValue("RevenueAnalysis:MaxConcurrentBuilds", 2)));

        var folder = configuration["RevenueAnalysis:OutputFolder"];
        _folder = string.IsNullOrWhiteSpace(folder)
            ? Path.Combine(Path.GetTempPath(), "LabMetricsDashboard", "RevenueAnalysis")
            : folder;
        Directory.CreateDirectory(_folder);
    }

    private int MaxClaims => Math.Max(1000, _configuration.GetValue("RevenueAnalysis:MaxClaims", 600_000));
    private TimeSpan Retention => TimeSpan.FromHours(Math.Max(1, _configuration.GetValue("RevenueAnalysis:RetentionHours", 24)));
    private int CommandTimeoutSeconds => Math.Max(60, _configuration.GetValue("RevenueAnalysis:CommandTimeoutSeconds", 900));

    // ---------------------------------------------------------------- jobs
    public RevenueAnalysisJob Start(RevenueAnalysisRequest request)
    {
        PruneJobs();
        var job = new RevenueAnalysisJob { LabKey = request.LabKey, RequestedBy = request.RequestedBy };
        _jobs[job.Id] = job;

        if (!request.Refresh && FindReusable(request) is { } existing)
        {
            job.Token = existing.Token;
            job.Reused = true;
            job.Message = $"Reusing the dashboard built at {existing.GeneratedOnUtc.ToLocalTime():h:mm tt} today.";
            job.State = RevenueAnalysisJobState.Done;
            return job;
        }

        _ = Task.Run(() => RunAsync(job, request));
        return job;
    }

    public RevenueAnalysisJob? GetJob(string jobId) =>
        !string.IsNullOrWhiteSpace(jobId) && _jobs.TryGetValue(jobId, out var job) ? job : null;

    private void PruneJobs()
    {
        var cutoff = DateTime.UtcNow.AddHours(-6);
        foreach (var (id, job) in _jobs)
            if (job.StartedUtc < cutoff && job.State is RevenueAnalysisJobState.Done or RevenueAnalysisJobState.Failed)
                _jobs.TryRemove(id, out _);
    }

    private async Task RunAsync(RevenueAnalysisJob job, RevenueAnalysisRequest request)
    {
        // A build outlives the request that started it; give it its own bound instead.
        using var cts = new CancellationTokenSource(TimeSpan.FromMinutes(30));
        var ct = cts.Token;
        var sw = Stopwatch.StartNew();
        string? tempPath = null;

        try
        {
            job.Message = "Waiting for a free build slot…";
            await _gate.WaitAsync(ct);
            try
            {
                job.State = RevenueAnalysisJobState.Running;
                CleanupExpired();

                using var scope = _scopes.CreateScope();
                var sp = scope.ServiceProvider;

                job.Message = "Loading denial and fee-schedule masters…";
                var (denials, nonCollectible, cptDesc, masterWarnings) = await LoadMastersAsync(sp, ct);

                var data = new RevenueAnalysisDataset(request.DosFrom, request.DosTo, MaxClaims);
                data.Warnings.AddRange(masterWarnings);
                string sourceLabel, sourceShort;

                if (request.Source == RevenueAnalysisSourceKind.Live)
                {
                    if (string.IsNullOrWhiteSpace(request.ConnectionString))
                        throw new InvalidOperationException("No database connection is configured for this lab.");
                    job.Message = "Reading Claim Level data from the lab database…";
                    await ReadLiveAsync(request.ConnectionString, "ClaimLevelData", RaColumns.ClaimLevel, request.DosFrom, request.DosTo, 0,
                        data.BeginClaims, data.AddClaim, ct);
                    job.Message = $"Reading Line Level data for {data.Claims.Count:N0} claims…";
                    // Lines are matched to claims by ClaimID; the SQL window is widened a month each way so a
                    // line dated a little apart from its claim is still read.
                    await ReadLiveAsync(request.ConnectionString, "LineLevelData", RaColumns.LineLevel, request.DosFrom, request.DosTo, 31,
                        data.BeginLines, data.AddLine, ct);
                    sourceLabel = "Live lab database — Claim & Line Level masters";
                    sourceShort = "Live lab database";
                }
                else
                {
                    var (claimBytes, lineBytes, label, shortLabel) = await LoadSnapshotFilesAsync(sp, request, job, ct);
                    job.Message = "Reading the Claim Level snapshot…";
                    await ParquetTableReader.ReadAllRowsAsync(claimBytes, RaColumns.ClaimLevel, data.BeginClaims, data.AddClaim, ct);
                    claimBytes = [];
                    job.Message = $"Reading the Line Level snapshot for {data.Claims.Count:N0} claims…";
                    await ParquetTableReader.ReadAllRowsAsync(lineBytes, RaColumns.LineLevel, data.BeginLines, data.AddLine, ct);
                    sourceLabel = label;
                    sourceShort = shortLabel;
                }

                if (data.Claims.Count == 0)
                    throw new InvalidOperationException("No claims fall in this date-of-service window for this source.");

                job.Message = $"Writing the dashboard ({data.Claims.Count:N0} claims, {data.Lines.Count:N0} lines)…";
                var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
                var finalPath = HtmlPath(token);
                tempPath = finalPath + ".tmp";

                var ctx = new RevenueAnalysisWriteContext
                {
                    LabName = request.LabDisplayName,
                    SourceLabel = sourceLabel,
                    SourceShort = sourceShort,
                    FileTag = FileTag(request.LabDisplayName),
                    GeneratedOn = DateTime.Today,
                    DenialMaster = denials,
                    NonCollectible = nonCollectible,
                    CptDescriptions = cptDesc,
                };

                long uncompressed;
                await using (var file = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
                {
                    await using (var gz = new GZipStream(file, CompressionLevel.Optimal, leaveOpen: true))
                    await using (var counter = new CountingStream(gz))
                    {
                        await RevenueAnalysisHtmlWriter.WriteAsync(counter, data, ctx, ct);
                        uncompressed = counter.BytesWritten;
                    }
                }
                File.Move(tempPath, finalPath, overwrite: true);
                tempPath = null;

                var dosDays = data.Claims.Where(c => c.Dos is not null).Select(c => c.Dos!.Value).ToList();
                var meta = new RevenueAnalysisMeta
                {
                    Token = token,
                    CacheKey = request.CacheKey,
                    LabKey = request.LabKey,
                    LabDisplayName = request.LabDisplayName,
                    Source = request.Source,
                    SnapshotRunId = request.SnapshotRunId,
                    SourceLabel = sourceLabel,
                    DosFrom = request.DosFrom,
                    DosTo = request.DosTo,
                    DataDosMin = dosDays.Count > 0 ? RaValue.FromDays(dosDays.Min()) : null,
                    DataDosMax = dosDays.Count > 0 ? RaValue.FromDays(dosDays.Max()) : null,
                    Claims = data.Claims.Count,
                    Lines = data.Lines.Count,
                    DuplicateClaimsSkipped = data.DuplicateClaims,
                    UnmatchedLinesSkipped = data.UnmatchedLines,
                    CompressedBytes = new FileInfo(finalPath).Length,
                    UncompressedBytes = uncompressed,
                    GeneratedOnUtc = DateTime.UtcNow,
                    GeneratedBy = request.RequestedBy,
                    Seconds = Math.Round(sw.Elapsed.TotalSeconds, 1),
                    Warnings = data.Warnings,
                };
                if (data.DuplicateClaims > 0)
                    meta.Warnings.Add($"{data.DuplicateClaims:N0} duplicate ClaimID row(s) were skipped (first row kept).");
                await File.WriteAllTextAsync(MetaPath(token), JsonSerializer.Serialize(meta, MetaJson), ct);

                job.Token = token;
                job.Message = $"Ready: {meta.Claims:N0} claims, {meta.Lines:N0} lines in {meta.Seconds:N0}s.";
                job.State = RevenueAnalysisJobState.Done;
                _logger.LogInformation(
                    "Revenue Analysis built for {Lab} ({Source}) by {User}: {Claims} claims, {Lines} lines, {Mb:N1} MB, {Seconds}s.",
                    request.LabKey, request.Source, request.RequestedBy, meta.Claims, meta.Lines, meta.UncompressedBytes / 1048576.0, meta.Seconds);
            }
            finally
            {
                _gate.Release();
            }
        }
        catch (Exception ex)
        {
            if (tempPath is not null) TryDelete(tempPath);
            job.Error = ex switch
            {
                OperationCanceledException => "The build took longer than 30 minutes and was stopped. Narrow the date-of-service window.",
                SqlException sql when sql.Number == 208 => "This lab's database has no ClaimLevelData / LineLevelData table.",
                SqlException sql => "Database error: " + sql.Message,
                InvalidOperationException => ex.Message,
                _ => "The dashboard could not be built: " + ex.Message,
            };
            job.Message = job.Error;
            job.State = RevenueAnalysisJobState.Failed;
            _logger.LogError(ex, "Revenue Analysis build failed for {Lab} ({Source}).", request.LabKey, request.Source);
        }
    }

    // ---------------------------------------------------------------- sources
    /// <summary>
    /// Streams the wanted columns (those the table has) of dbo.<paramref name="table"/> for the DOS
    /// window. Dates are NVARCHAR in the lab tables, hence TRY_CONVERT; rows it cannot read are
    /// dropped by the window filter in <see cref="RevenueAnalysisDataset"/> as well.
    /// </summary>
    private async Task ReadLiveAsync(string connectionString, string table, IReadOnlyList<string> wanted,
        DateOnly? from, DateOnly? to, int widenDays,
        Action<IReadOnlyList<string>> begin, Action<object?[]> row, CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        var existing = new List<string>();
        await using (var probe = new SqlCommand($"SELECT TOP (0) * FROM dbo.[{table}];", conn) { CommandTimeout = 60 })
        await using (var r = await probe.ExecuteReaderAsync(CommandBehavior.SchemaOnly, ct))
        {
            for (int i = 0; i < r.FieldCount; i++) existing.Add(r.GetName(i));
        }

        var existingSet = new HashSet<string>(existing, StringComparer.OrdinalIgnoreCase);
        var columns = wanted.Where(existingSet.Contains)
            .Select(w => existing.First(e => string.Equals(e, w, StringComparison.OrdinalIgnoreCase)))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (columns.Count == 0) throw new InvalidOperationException($"dbo.{table} has none of the expected columns.");

        var dosColumn = RaColumns.Dos.Select(a => existing.FirstOrDefault(e => string.Equals(e, a, StringComparison.OrdinalIgnoreCase)))
            .FirstOrDefault(x => x is not null);

        var sql = $"SELECT {string.Join(", ", columns.Select(c => "[" + c.Replace("]", "]]") + "]"))} FROM dbo.[{table}]";
        await using var cmd = new SqlCommand { Connection = conn, CommandTimeout = CommandTimeoutSeconds };
        if (dosColumn is not null && (from is not null || to is not null))
        {
            var dosExpr = $"TRY_CONVERT(date, [{dosColumn}])";
            var where = new List<string>();
            if (from is { } f)
            {
                where.Add($"{dosExpr} >= @From");
                cmd.Parameters.Add("@From", SqlDbType.Date).Value = f.AddDays(-widenDays).ToDateTime(TimeOnly.MinValue);
            }
            if (to is { } t)
            {
                where.Add($"{dosExpr} <= @To");
                cmd.Parameters.Add("@To", SqlDbType.Date).Value = t.AddDays(widenDays).ToDateTime(TimeOnly.MinValue);
            }
            sql += " WHERE " + string.Join(" AND ", where);
        }
        cmd.CommandText = sql + ";";

        await using var reader = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct);
        var names = Enumerable.Range(0, reader.FieldCount).Select(reader.GetName).ToList();
        begin(names);
        var values = new object?[reader.FieldCount];
        var count = 0;
        while (await reader.ReadAsync(ct))
        {
            for (int i = 0; i < values.Length; i++)
            {
                var v = reader.GetValue(i);
                values[i] = v is DBNull ? null : v;
            }
            row(values);
            if ((++count & 0x3FFF) == 0) ct.ThrowIfCancellationRequested();
        }
    }

    private static async Task<(byte[] Claims, byte[] Lines, string Label, string Short)> LoadSnapshotFilesAsync(
        IServiceProvider sp, RevenueAnalysisRequest request, RevenueAnalysisJob job, CancellationToken ct)
    {
        if (request.SnapshotRunId is not { } runId) throw new InvalidOperationException("No snapshot week was chosen.");
        var index = sp.GetRequiredService<IMasterDataSnapshotRepository>();
        var store = sp.GetRequiredService<IReportSnapshotFileStore>();

        job.Message = "Finding the week's Claim Level and Line Level snapshot files…";
        var files = await index.GetFilesAsync(runId, ct);
        MasterDataSnapshotFileRow? Pick(string code) => files
            .Where(f => string.Equals(f.ReportCode, code, StringComparison.OrdinalIgnoreCase)
                        && string.Equals(f.ResultSetName, "Data", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(f => f.CreatedOn).FirstOrDefault();

        var claimFile = Pick("CLAIMLEVEL") ?? throw new InvalidOperationException("That snapshot week has no Claim Level file.");
        var lineFile = Pick("LINELEVEL") ?? throw new InvalidOperationException("That snapshot week has no Line Level file.");

        // The run must belong to the lab being built: a hand-edited run id must not reach another lab's data.
        var detail = await index.GetFileAsync(claimFile.SnapshotFileId, ct)
                     ?? throw new InvalidOperationException("The snapshot file is no longer indexed.");
        if (!LabMatches(detail.LabName, request.LabKey, request.LabDisplayName))
            throw new InvalidOperationException("That snapshot belongs to a different lab.");

        job.Message = $"Downloading the Claim Level snapshot ({claimFile.SizeBytes / 1048576.0:N1} MB)…";
        var claims = await store.ReadAsync(claimFile.BlobPath, ct);
        job.Message = $"Downloading the Line Level snapshot ({lineFile.SizeBytes / 1048576.0:N1} MB)…";
        var lines = await store.ReadAsync(lineFile.BlobPath, ct);

        var label = $"Weekly snapshot — week {detail.WeekFolder} (as of {detail.SnapshotDate:MM/dd/yyyy})";
        return (claims, lines, label, $"Snapshot {detail.SnapshotDate:MM/dd/yyyy}");
    }

    /// <summary>True when a snapshot run's lab name is the lab being built (same normalisation as the Report Board).</summary>
    public static bool LabMatches(string? snapshotLabName, string labKey, string? labDisplayName)
    {
        var token = ReportCatalog.LabToken(snapshotLabName);
        return token.Length > 0
               && (token == ReportCatalog.LabToken(labKey) || token == ReportCatalog.LabToken(labDisplayName));
    }

    private async Task<(Dictionary<string, (string, string)> Denials, HashSet<string> NonCollectible,
        Dictionary<string, string> CptDesc, List<string> Warnings)> LoadMastersAsync(IServiceProvider sp, CancellationToken ct)
    {
        var warnings = new List<string>();
        var denials = new Dictionary<string, (string, string)>(StringComparer.OrdinalIgnoreCase);
        var nonCollectible = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var cptDesc = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        try
        {
            var repo = sp.GetRequiredService<IDenialCategoryMasterRepository>();
            foreach (var row in await repo.GetCategoriesAsync(ct))
            {
                var key = DenialCodeKey.Normalize(row.DenialCode);
                if (key.Length > 0) denials.TryAdd(key, ((row.Description ?? "").Trim(), (row.ActionCategory ?? "").Trim()));
            }
            foreach (var row in await repo.GetNonCollectibleAsync(ct))
            {
                var key = DenialCodeKey.Normalize(row.DenialCode);
                if (key.Length > 0) nonCollectible.Add(key);
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Denial category master unavailable for Revenue Analysis.");
            warnings.Add("The Denial Category Master could not be read - denial categories show as uncategorized.");
        }

        try
        {
            var fees = sp.GetRequiredService<IFeeScheduleRepository>();
            foreach (var row in await fees.GetAllAsync(ct))
                if (!string.IsNullOrWhiteSpace(row.ShortDescription))
                    cptDesc.TryAdd(row.Hcpcs.Trim().ToUpperInvariant(), row.ShortDescription.Trim());
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Fee schedule unavailable for Revenue Analysis CPT descriptions.");
            warnings.Add("The Fee Schedule could not be read - CPT codes show without descriptions.");
        }

        return (denials, nonCollectible, cptDesc, warnings);
    }

    // ---------------------------------------------------------------- store
    private string HtmlPath(string token) => Path.Combine(_folder, token + ".html.gz");
    private string MetaPath(string token) => Path.Combine(_folder, token + ".json");

    private static bool IsToken(string? token) =>
        token is { Length: 32 } && token.All(Uri.IsHexDigit);

    public RevenueAnalysisMeta? GetMeta(string token)
    {
        if (!IsToken(token)) return null;
        var path = MetaPath(token);
        if (!File.Exists(path) || !File.Exists(HtmlPath(token))) return null;
        try
        {
            return JsonSerializer.Deserialize<RevenueAnalysisMeta>(File.ReadAllText(path));
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Unreadable Revenue Analysis metadata {Path}.", path);
            return null;
        }
    }

    public string? GetFilePath(string token)
    {
        if (!IsToken(token)) return null;
        var path = HtmlPath(token);
        return File.Exists(path) ? path : null;
    }

    public IReadOnlyList<RevenueAnalysisMeta> ListForLab(string labKey)
    {
        var cutoff = DateTime.UtcNow - Retention;
        return Directory.EnumerateFiles(_folder, "*.json")
            .Select(p => GetMeta(Path.GetFileNameWithoutExtension(p)))
            .Where(m => m is not null && m.GeneratedOnUtc >= cutoff
                        && string.Equals(m.LabKey, labKey, StringComparison.OrdinalIgnoreCase))
            .Select(m => m!)
            .OrderByDescending(m => m.GeneratedOnUtc)
            .Take(10)
            .ToList();
    }

    private RevenueAnalysisMeta? FindReusable(RevenueAnalysisRequest request) =>
        ListForLab(request.LabKey).FirstOrDefault(m => m.CacheKey == request.CacheKey);

    private void CleanupExpired()
    {
        var cutoff = DateTime.UtcNow - Retention;
        foreach (var file in Directory.EnumerateFiles(_folder))
        {
            try
            {
                if (File.GetLastWriteTimeUtc(file) < cutoff) File.Delete(file);
            }
            catch (IOException)
            {
                // In use (being served); the next build tries again.
            }
        }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private static string FileTag(string labName)
    {
        var tag = new string(labName.ToLowerInvariant().Select(c => char.IsLetterOrDigit(c) ? c : '_').ToArray()).Trim('_');
        while (tag.Contains("__", StringComparison.Ordinal)) tag = tag.Replace("__", "_", StringComparison.Ordinal);
        return tag.Length == 0 ? "lab" : tag;
    }

    /// <summary>Counts the uncompressed bytes written through it.</summary>
    private sealed class CountingStream(Stream inner) : Stream
    {
        public long BytesWritten { get; private set; }
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => BytesWritten; set => throw new NotSupportedException(); }
        public override void Flush() => inner.Flush();
        public override Task FlushAsync(CancellationToken cancellationToken) => inner.FlushAsync(cancellationToken);
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) { inner.Write(buffer, offset, count); BytesWritten += count; }
        public override void Write(ReadOnlySpan<byte> buffer) { inner.Write(buffer); BytesWritten += buffer.Length; }
        public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
        {
            await inner.WriteAsync(buffer, cancellationToken);
            BytesWritten += buffer.Length;
        }
        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
    }
}
