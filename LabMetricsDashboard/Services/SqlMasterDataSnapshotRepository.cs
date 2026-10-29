using System.Data;
using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

public interface IMasterDataSnapshotRepository
{
    /// <summary>Null when LRNMaster has no snapshot tables yet (Create_ReportSnapshots.sql not run).</summary>
    Task<IReadOnlyList<MasterDataSnapshotRunRow>?> GetRunsAsync(CancellationToken ct);

    Task<IReadOnlyList<MasterDataSnapshotFileRow>> GetFilesAsync(long snapshotRunId, CancellationToken ct);
}

/// <summary>
/// Master Values > Master Data Snapshots: reads the index the master file processor writes after each
/// weekly run (step 88) - LRNMaster.dbo.ReportSnapshotRun (one row per lab + RunId) and
/// dbo.ReportSnapshotFile (one row per Parquet file in the Blob container). The index is exactly what
/// the container holds: the worker records a file only after uploading it, and retention deletes the
/// files before their rows. Read-only.
/// </summary>
public sealed class SqlMasterDataSnapshotRepository : IMasterDataSnapshotRepository
{
    private readonly string _connectionString;

    public SqlMasterDataSnapshotRepository(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("DefaultConnection is not configured (LRNMaster).");
    }

    public async Task<IReadOnlyList<MasterDataSnapshotRunRow>?> GetRunsAsync(CancellationToken ct)
    {
        // The tables are named only inside sp_executesql, so the batch compiles on a database without them.
        const string sql = @"
IF OBJECT_ID(N'dbo.ReportSnapshotRun', N'U') IS NULL OR OBJECT_ID(N'dbo.ReportSnapshotFile', N'U') IS NULL
BEGIN
    SELECT CAST(0 AS bit) AS Installed;
    RETURN;
END;
SELECT CAST(1 AS bit) AS Installed;
EXEC sp_executesql N'
SELECT r.SnapshotRunId, r.LabId, r.LabName, r.RunId, r.WeekFolder, r.SnapshotDate, r.Status, r.ErrorMessage,
       r.CreatedOn, r.CompletedOn, r.BlobPrefix,
       COUNT(f.SnapshotFileId) AS Files, ISNULL(SUM(f.[RowCount]), 0) AS TotalRows, ISNULL(SUM(f.SizeBytes), 0) AS TotalBytes,
       -- One entry per report: a page report (LRN.SnapshotGenerator) has one file per section.
       -- FOR XML PATH rather than STRING_AGG, which LRNMaster rejects here (Msg 8116 on its separator).
       STUFF((SELECT DISTINCT N'','' + c.ReportCode
              FROM dbo.ReportSnapshotFile c WHERE c.SnapshotRunId = r.SnapshotRunId
              FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 1, N'''') AS ReportCodes
FROM dbo.ReportSnapshotRun r
LEFT JOIN dbo.ReportSnapshotFile f ON f.SnapshotRunId = r.SnapshotRunId
GROUP BY r.SnapshotRunId, r.LabId, r.LabName, r.RunId, r.WeekFolder, r.SnapshotDate, r.Status, r.ErrorMessage,
         r.CreatedOn, r.CompletedOn, r.BlobPrefix
ORDER BY r.LabName, r.SnapshotDate DESC, r.CreatedOn DESC;';";

        await using var conn = new SqlConnection(_connectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        await conn.OpenAsync(ct);
        await using var r = await cmd.ExecuteReaderAsync(ct);

        if (!await r.ReadAsync(ct) || !r.GetBoolean(0)) return null;
        await r.NextResultAsync(ct);

        var rows = new List<MasterDataSnapshotRunRow>();
        while (await r.ReadAsync(ct))
        {
            rows.Add(new MasterDataSnapshotRunRow
            {
                SnapshotRunId = r.GetInt64(0),
                LabId = r.GetInt32(1),
                LabName = r.GetString(2),
                RunId = r.GetString(3),
                WeekFolder = r.GetString(4),
                SnapshotDate = r.GetDateTime(5),
                Status = r.GetString(6),
                ErrorMessage = r.IsDBNull(7) ? null : r.GetString(7),
                CreatedOn = r.GetDateTime(8),
                CompletedOn = r.IsDBNull(9) ? null : r.GetDateTime(9),
                BlobPrefix = r.IsDBNull(10) ? null : r.GetString(10),
                Files = r.GetInt32(11),
                TotalRows = r.GetInt64(12),
                TotalBytes = r.GetInt64(13),
                ReportCodes = r.IsDBNull(14) ? [] : r.GetString(14).Split(',', StringSplitOptions.RemoveEmptyEntries)
            });
        }
        return rows;
    }

    public async Task<IReadOnlyList<MasterDataSnapshotFileRow>> GetFilesAsync(long snapshotRunId, CancellationToken ct)
    {
        const string sql = @"
SELECT f.SnapshotFileId, f.ReportCode, f.ResultSetName, f.BlobPath, f.[RowCount], f.SizeBytes, f.ContentSha256,
       f.SchemaJson, f.SchemaVersion, f.CreatedOn
FROM dbo.ReportSnapshotFile f
WHERE f.SnapshotRunId = @Id
ORDER BY f.ReportCode, f.ResultSetName;";

        await using var conn = new SqlConnection(_connectionString);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@Id", SqlDbType.BigInt).Value = snapshotRunId;
        await conn.OpenAsync(ct);
        await using var r = await cmd.ExecuteReaderAsync(ct);

        var rows = new List<MasterDataSnapshotFileRow>();
        while (await r.ReadAsync(ct))
        {
            var row = new MasterDataSnapshotFileRow
            {
                SnapshotFileId = r.GetInt64(0),
                ReportCode = r.GetString(1),
                ResultSetName = r.GetString(2),
                BlobPath = r.GetString(3),
                RowCount = r.GetInt64(4),
                SizeBytes = r.GetInt64(5),
                ContentSha256 = r.GetString(6),
                SchemaVersion = r.GetInt32(8),
                CreatedOn = r.GetDateTime(9)
            };
            if (row.ResultSetName == PageModelResultSet)
                ReadPageModelInfo(r.GetString(7), row);
            else
                row.Columns = CountColumns(r.GetString(7));
            rows.Add(row);
        }
        return rows;
    }

    /// <summary>ResultSetName of LRN.SnapshotGenerator's display copy of a report (the page's view model as JSON).</summary>
    public const string PageModelResultSet = "PageModel";

    // A PageModel row's SchemaJson: {Trigger, Logic: {AppVersion, Objects: [...]}, LogicChanges: [...], ...}.
    private static void ReadPageModelInfo(string schemaJson, MasterDataSnapshotFileRow row)
    {
        try
        {
            using var doc = JsonDocument.Parse(schemaJson);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return;
            if (root.TryGetProperty("Trigger", out var trigger) && trigger.ValueKind == JsonValueKind.String)
                row.Trigger = trigger.GetString();
            if (root.TryGetProperty("Logic", out var logic) && logic.ValueKind == JsonValueKind.Object
                && logic.TryGetProperty("Objects", out var objects) && objects.ValueKind == JsonValueKind.Array)
                row.LogicObjects = objects.GetArrayLength();
            if (root.TryGetProperty("LogicChanges", out var changes) && changes.ValueKind == JsonValueKind.Array)
                row.LogicChanges = changes.EnumerateArray()
                    .Where(c => c.ValueKind == JsonValueKind.String)
                    .Select(c => c.GetString()!)
                    .ToList();
        }
        catch (JsonException)
        {
            // An unreadable entry shows as a plain file.
        }
    }

    // SchemaJson is the worker's [{name, sourceName, type, ...}] array: one entry per Parquet column.
    private static int? CountColumns(string schemaJson)
    {
        try
        {
            using var doc = JsonDocument.Parse(schemaJson);
            return doc.RootElement.ValueKind == JsonValueKind.Array ? doc.RootElement.GetArrayLength() : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

public sealed class MasterDataSnapshotRunRow
{
    public long SnapshotRunId { get; set; }
    public int LabId { get; set; }
    public string LabName { get; set; } = "";
    public string RunId { get; set; } = "";
    /// <summary>The SharePoint week folder, e.g. 10.16.2026 - 10.22.2026.</summary>
    public string WeekFolder { get; set; } = "";
    /// <summary>The week's end date: the data is as of this day.</summary>
    public DateTime SnapshotDate { get; set; }
    /// <summary>InProgress | Success | Failed.</summary>
    public string Status { get; set; } = "";
    public string? ErrorMessage { get; set; }
    public DateTime CreatedOn { get; set; }
    public DateTime? CompletedOn { get; set; }
    public string? BlobPrefix { get; set; }
    public int Files { get; set; }
    public long TotalRows { get; set; }
    public long TotalBytes { get; set; }
    public string[] ReportCodes { get; set; } = [];
}

public sealed class MasterDataSnapshotFileRow
{
    public long SnapshotFileId { get; set; }
    /// <summary>LINELEVEL | CLAIMLEVEL | LIMS (master data), or a page report: EXECSUMMARY, ..., DENIALINSIGHT.</summary>
    public string ReportCode { get; set; } = "";
    public string ResultSetName { get; set; } = "";
    /// <summary>Path inside the snapshot container, e.g. TexasDiagnostic/R..._10.16.2026-10.22.2026_LIMS.parquet.</summary>
    public string BlobPath { get; set; } = "";
    public long RowCount { get; set; }
    public long SizeBytes { get; set; }
    public string ContentSha256 { get; set; } = "";
    public int? Columns { get; set; }
    public int SchemaVersion { get; set; }
    public DateTime CreatedOn { get; set; }

    // PageModel (display copy) rows only.
    /// <summary>What triggered the capture: the tracker report's Success, or the upload / edit.</summary>
    public string? Trigger { get; set; }
    /// <summary>How many stored procedures / views / functions of the lab database the report ran.</summary>
    public int? LogicObjects { get; set; }
    /// <summary>How the report logic differs from the lab's previous snapshot of this report.</summary>
    public List<string> LogicChanges { get; set; } = [];
}
