using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace LRN.MasterFileProcessorWorker.Database;

/// <summary>One upstream run, as recorded in LRNMaster.dbo.LrnFileStatus.</summary>
public sealed record UpstreamRun(
    string RunId,
    string FileType,
    string ProcessStatus,
    string? WeekRange,
    string? Source,
    string? Output,
    DateTime? CompletedOn,
    string? ExecutionId);

/// <summary>Why a lab is or is not going to ingest this poll.</summary>
public sealed record SourceRunDecision(bool ShouldIngest, string? RunId, string Reason)
{
    public static SourceRunDecision Skip(string reason) => new(false, null, reason);
    public static SourceRunDecision Ingest(string runId, string reason) => new(true, runId, reason);
}

/// <summary>
/// The gate in front of a <c>LabDatabase</c>-sourced lab.
///
/// <para>
/// An upstream automation refreshes the lab's master tables and records one row per file type per
/// run in <c>LRNMaster.dbo.LrnFileStatus</c>. This worker only READS that table. Its own progress
/// keeps going to LRN_Run_Log / LRN_Step_Log / LineClaimFileLogs / ReportsWorkflowTracker as it
/// always has - two writers on one status table would race over the same RunID and FileType.
/// </para>
/// <para>
/// Two questions are asked before any data moves:
/// </para>
/// <list type="number">
///   <item>Is the newest run <c>Completed</c>? Anything else means the upstream pipeline is still
///   working or has failed, and its own documentation says a non-Completed output "should not be
///   consumed as final". Loading mid-refresh is how half a week's data gets published.</item>
///   <item>Have we already ingested that RunID? The destination truncates before loading, so a
///   repeat is not corrupting - but it re-reads and re-copies the full tables for nothing, on
///   every poll interval.</item>
/// </list>
/// <para>
/// The tables carry no run column, so the RunID is a gate and a lineage stamp rather than a
/// filter: whatever the tables hold IS that run's data, and the whole table is loaded.
/// </para>
/// </summary>
public sealed class LabSourceRunGate
{
    private readonly string _masterConnectionString;
    private readonly ILogger<LabSourceRunGate> _logger;

    /// <summary>What the upstream pipeline calls a finished, consumable run.</summary>
    private const string CompletedStatus = "Completed";

    /// <summary>Still running. A later poll picks it up; nothing is wrong.</summary>
    private const string InProgressStatus = "Inprogress";

    /// <summary>Marker table, in the LAB database beside the data it describes.</summary>
    private const string MarkerTable = "dbo.LrnSourceRunMarker";

    public LabSourceRunGate(IConfiguration configuration, ILogger<LabSourceRunGate> logger)
    {
        _masterConnectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("Missing DefaultConnection connection string (LRNMaster).");
        _logger = logger;
    }

    /// <summary>
    /// The newest run for this lab and file type, whatever its status. Returned even when it is
    /// not Completed so the caller can say WHY it is waiting rather than just going quiet.
    /// </summary>
    public async Task<UpstreamRun?> GetLatestRunAsync(int labId, string fileType, CancellationToken ct)
    {
        // Ordered by the identity, which is insertion order and therefore literally "the latest
        // entry". Ordering on the timestamps instead looked reasonable but is wrong: an Inprogress
        // row has no CompletedOn, so it falls back to StartedOn, and a run that started before an
        // earlier run finished would then rank BELOW that finished run - the gate would ingest
        // while the newer run was still rewriting the tables, which is the one thing it exists to
        // prevent.
        const string sql = @"
SELECT TOP (1)
    LrnFileId, RunID, FileType, ProcessStatus, WeekRange, [Source], [Output], CompletedOn, ExecutionId
FROM dbo.LrnFileStatus
WHERE LabID = @LabId
  AND UPPER(LTRIM(RTRIM(FileType))) = @FileType
ORDER BY LrnFileId DESC;";

        await using var con = new SqlConnection(_masterConnectionString);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 60 };
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@FileType", fileType.Trim().ToUpperInvariant());

        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (!await rd.ReadAsync(ct)) return null;

        return new UpstreamRun(
            RunId: rd["RunID"] as string ?? string.Empty,
            FileType: rd["FileType"] as string ?? fileType,
            ProcessStatus: rd["ProcessStatus"] as string ?? string.Empty,
            WeekRange: rd["WeekRange"] as string,
            Source: rd["Source"] as string,
            Output: rd["Output"] as string,
            CompletedOn: rd["CompletedOn"] as DateTime?,
            ExecutionId: rd["ExecutionId"]?.ToString());
    }

    /// <summary>
    /// Decides whether this lab should ingest now.
    ///
    /// <para>
    /// Readiness and progress are deliberately two different sets:
    /// </para>
    /// <list type="bullet">
    ///   <item><paramref name="requiredFileTypes"/> - every file type that must read Completed on
    ///   the SAME RunID before anything moves. That is <see cref="AllFileTypes"/>: an upstream run
    ///   is not finished until LIS, LINELEVEL and CLAIMLEVEL have all finished, and the three
    ///   tables are refreshed together, so a run half-done is a run whose tables are still
    ///   changing.</item>
    ///   <item><paramref name="ingestFileTypes"/> - what this lab actually loads, and therefore
    ///   what its marker tracks. Checking readiness and progress against one list would mean a lab
    ///   that does not load some file type could never advance that file type's marker, and would
    ///   re-ingest on every single poll for ever.</item>
    /// </list>
    /// </summary>
    public async Task<SourceRunDecision> DecideAsync(
        int labId,
        string labConnectionString,
        IReadOnlyList<string> requiredFileTypes,
        IReadOnlyList<string> ingestFileTypes,
        CancellationToken ct)
    {
        var runs = new List<UpstreamRun>();

        foreach (var fileType in requiredFileTypes)
        {
            var run = await GetLatestRunAsync(labId, fileType, ct);

            if (run is null)
                return SourceRunDecision.Skip($"no {fileType} row in LrnFileStatus for lab {labId}.");

            var status = run.ProcessStatus?.Trim() ?? string.Empty;

            if (!string.Equals(status, CompletedStatus, StringComparison.OrdinalIgnoreCase))
            {
                // Both are a skip, but they are different situations and the log should say which:
                // Inprogress resolves itself on a later poll, Failed needs somebody to look at it.
                //
                // A Failed latest run is deliberately NOT rolled back to the last Completed one.
                // The RunID gates but does not filter - the tables hold whatever the most recent
                // attempt left behind - so loading them under an older Completed RunID would
                // publish a failed run's contents labelled as a good one.
                var reason = string.Equals(status, InProgressStatus, StringComparison.OrdinalIgnoreCase)
                    ? $"latest {fileType} run {run.RunId} is still {InProgressStatus}; waiting for it to finish."
                    : $"latest {fileType} run {run.RunId} is '{status}', not '{CompletedStatus}'; "
                      + "waiting for a new Completed run rather than reading a failed one's tables.";

                return SourceRunDecision.Skip(reason);
            }

            runs.Add(run);
        }

        var runIds = runs.Select(r => r.RunId).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

        if (runIds.Count != 1)
        {
            return SourceRunDecision.Skip(
                "the latest Completed runs disagree across file types ("
                + string.Join(", ", runs.Select(r => $"{r.FileType}={r.RunId}"))
                + "). Waiting for one run to complete all of them.");
        }

        var runId = runIds[0];

        await EnsureMarkerTableAsync(labConnectionString, ct);

        foreach (var fileType in ingestFileTypes)
        {
            var last = await GetLastIngestedRunIdAsync(labConnectionString, labId, fileType, ct);

            // Any file type still behind means there is work to do, so the run goes ahead.
            if (!string.Equals(last, runId, StringComparison.OrdinalIgnoreCase))
            {
                return SourceRunDecision.Ingest(runId,
                    $"run {runId} is Completed for {string.Join(", ", requiredFileTypes)} "
                    + $"and not yet ingested ({fileType} last saw '{last ?? "nothing"}').");
            }
        }

        return SourceRunDecision.Skip($"run {runId} has already been ingested for every file type.");
    }

    /// <summary>Last upstream RunID ingested for this lab and file type, or null.</summary>
    public async Task<string?> GetLastIngestedRunIdAsync(
        string labConnectionString, int labId, string fileType, CancellationToken ct)
    {
        var sql = $@"
SELECT TOP (1) SourceRunId
FROM {MarkerTable}
WHERE LabId = @LabId AND FileType = @FileType;";

        await using var con = new SqlConnection(labConnectionString);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 60 };
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@FileType", fileType.Trim().ToUpperInvariant());

        var value = await cmd.ExecuteScalarAsync(ct);
        return value as string;
    }

    /// <summary>
    /// Records that this lab and file type are now at <paramref name="sourceRunId"/>.
    /// <para>
    /// Called only after the rows are committed. Marking before the load would let a failed run
    /// look ingested, and the next poll would skip it - the data would never arrive and nothing
    /// would say so.
    /// </para>
    /// </summary>
    public async Task MarkIngestedAsync(
        string labConnectionString, int labId, string fileType, string sourceRunId,
        string? workerRunId, long rowsLoaded, CancellationToken ct)
    {
        await EnsureMarkerTableAsync(labConnectionString, ct);

        var sql = $@"
MERGE {MarkerTable} AS target
USING (SELECT @LabId AS LabId, @FileType AS FileType) AS source
    ON target.LabId = source.LabId AND target.FileType = source.FileType
WHEN MATCHED THEN UPDATE SET
    SourceRunId = @SourceRunId,
    WorkerRunId = @WorkerRunId,
    RowsLoaded  = @RowsLoaded,
    IngestedOn  = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (LabId, FileType, SourceRunId, WorkerRunId, RowsLoaded)
    VALUES (@LabId, @FileType, @SourceRunId, @WorkerRunId, @RowsLoaded);";

        await using var con = new SqlConnection(labConnectionString);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 60 };
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@FileType", fileType.Trim().ToUpperInvariant());
        cmd.Parameters.AddWithValue("@SourceRunId", sourceRunId);
        cmd.Parameters.AddWithValue("@WorkerRunId", (object?)workerRunId ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RowsLoaded", rowsLoaded);

        await cmd.ExecuteNonQueryAsync(ct);

        _logger.LogInformation(
            "Lab {LabId} [{FileType}]: marked source run {RunId} as ingested ({Rows:N0} rows).",
            labId, fileType, sourceRunId, rowsLoaded);
    }

    /// <summary>
    /// Creates the marker table on first use. One row per (LabId, FileType) - this records where a
    /// lab has got to, not a history, so the unique index is the whole point.
    /// </summary>
    private static async Task EnsureMarkerTableAsync(string labConnectionString, CancellationToken ct)
    {
        var sql = $@"
IF OBJECT_ID('{MarkerTable}','U') IS NULL
BEGIN
    CREATE TABLE {MarkerTable}
    (
        MarkerId    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_LrnSourceRunMarker PRIMARY KEY,
        LabId       int           NOT NULL,
        FileType    nvarchar(30)  NOT NULL,
        SourceRunId nvarchar(60)  NOT NULL,
        WorkerRunId nvarchar(60)  NULL,
        RowsLoaded  bigint        NULL,
        IngestedOn  datetime2(0)  NOT NULL CONSTRAINT DF_LrnSourceRunMarker_IngestedOn DEFAULT SYSUTCDATETIME()
    );
    CREATE UNIQUE INDEX UX_LrnSourceRunMarker_Lab_FileType ON {MarkerTable} (LabId, FileType);
END;";

        await using var con = new SqlConnection(labConnectionString);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
        await cmd.ExecuteNonQueryAsync(ct);
    }

    /// <summary>File-type keys as LrnFileStatus spells them for Cove.</summary>
    public static class FileTypes
    {
        public const string LineLevel = "LINELEVEL";
        public const string ClaimLevel = "CLAIMLEVEL";
        public const string Lis = "LIS";
    }

    /// <summary>
    /// The three file types one upstream run produces. All must be Completed on the same RunID
    /// before the master file processor starts on it - the run is not finished until they are, and
    /// the tables the run fills are still being written while any of them is outstanding.
    /// </summary>
    public static readonly IReadOnlyList<string> AllFileTypes = new[]
    {
        FileTypes.Lis,
        FileTypes.LineLevel,
        FileTypes.ClaimLevel
    };
}
