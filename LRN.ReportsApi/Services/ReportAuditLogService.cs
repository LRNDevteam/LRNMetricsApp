using System.Data;
using System.Globalization;
using System.Text;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services;

/// <summary>
/// Report Audit Log: every report run (one row per RunId) with the per-report-type status pivoted
/// across the columns, plus the run's info log.
///
/// Both reads go through the LRNMaster stored procedures that own this data - the pivot column list
/// is built from dbo.ReportTypeMaster at execution time, so the report columns are discovered from
/// the result set here rather than hardcoded.
/// </summary>
public interface IReportAuditLogService
{
    Task<ReportAuditPivotResult> GetRunsAsync(ReportAuditQuery query, CancellationToken ct);
    Task<IReadOnlyList<ReportRunLogEntry>> GetLogsAsync(ReportRunLogQuery query, CancellationToken ct);
    Task<(byte[] Content, string FileName)> ExportLogsAsync(ReportRunLogQuery query, CancellationToken ct);
}

public sealed class ReportAuditQuery
{
    public string? RunId { get; set; }
    public int? LabId { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    /// <summary>All | Latest | LatestSuccess - see usp_ReportsWorkflowTracker_Pivot.</summary>
    public string? Mode { get; set; }
    public bool IncludeInactiveReports { get; set; }
}

public sealed class ReportRunLogQuery
{
    public string? RunId { get; set; }
    /// <summary>'Error', a comma list such as 'Error,Warning', or null for every type.</summary>
    public string? LogType { get; set; }
    public string? ReportType { get; set; }
    public string? SourceSystem { get; set; }
    public DateTime? FromDate { get; set; }
    public DateTime? ToDate { get; set; }
    public bool Newest { get; set; }
}

/// <summary>One report run. <see cref="Statuses"/> is keyed by the report-type column name.</summary>
public sealed class ReportAuditRunRow
{
    public string RunId { get; set; } = string.Empty;
    public string? Lab { get; set; }
    /// <summary>As formatted by the proc (MM/dd/yyyy).</summary>
    public string? SyncedOn { get; set; }
    /// <summary>Parsed form of <see cref="SyncedOn"/> so the grid can sort on it.</summary>
    public DateTime? SyncedOnDate { get; set; }
    public string? Week { get; set; }
    public Dictionary<string, string?> Statuses { get; set; } = new(StringComparer.Ordinal);
    public int SuccessCount { get; set; }
    public int FailedCount { get; set; }
    public int SkippedCount { get; set; }
    public int NotRunCount { get; set; }
    public int ErrorLogCount { get; set; }
    public int TotalLogCount { get; set; }
}

public sealed class ReportAuditPivotResult
{
    /// <summary>Report-type columns in the order the proc emitted them (ReportTypeMaster.DisplayOrder).</summary>
    public List<string> ReportColumns { get; set; } = new();
    public List<ReportAuditRunRow> Rows { get; set; } = new();
}

public sealed class ReportRunLogEntry
{
    public long ReportRunIdInfoLogId { get; set; }
    public string RunId { get; set; } = string.Empty;
    public string? ReportType { get; set; }
    public string? SourceSystem { get; set; }
    public string? LogType { get; set; }
    public string? LogMessage { get; set; }
    public string? SourceFileName { get; set; }
    public DateTime? CreatedOn { get; set; }
    public string? CreatedBy { get; set; }
}

public sealed class ReportAuditLogService : IReportAuditLogService
{
    // Fixed leading columns of usp_ReportsWorkflowTracker_Pivot; everything after these is a report type.
    private const string ColLab = "Lab";
    private const string ColSyncedOn = "Synced on";
    private const string ColRunId = "RunID";
    private const string ColWeek = "Week";
    private static readonly HashSet<string> FixedColumns = new(StringComparer.OrdinalIgnoreCase)
        { ColLab, ColSyncedOn, ColRunId, ColWeek };

    private static readonly string[] LogCsvHeader =
        { "Log Id", "Run Id", "Report Type", "Source System", "Log Type", "Log Message", "Source File Name", "Created On", "Created By" };

    private readonly string _connectionString;

    public ReportAuditLogService(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing. It must point to LRNMaster.");
    }

    public async Task<ReportAuditPivotResult> GetRunsAsync(ReportAuditQuery query, CancellationToken ct)
    {
        var result = new ReportAuditPivotResult();
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);

        await using (var cmd = new SqlCommand("dbo.usp_ReportsWorkflowTracker_Pivot", conn) { CommandType = CommandType.StoredProcedure })
        {
            AddNullable(cmd, "@RunId", SqlDbType.VarChar, 30, Trim(query.RunId));
            AddNullable(cmd, "@LabId", SqlDbType.Int, 0, query.LabId);
            AddNullable(cmd, "@FromDate", SqlDbType.Date, 0, query.FromDate?.Date);
            AddNullable(cmd, "@ToDate", SqlDbType.Date, 0, query.ToDate?.Date);
            cmd.Parameters.Add("@IncludeInactiveReports", SqlDbType.Bit).Value = query.IncludeInactiveReports;
            cmd.Parameters.Add("@Mode", SqlDbType.VarChar, 20).Value = NormalizeMode(query.Mode);

            await using var reader = await cmd.ExecuteReaderAsync(ct);

            // Column order matters: the report columns are rendered in exactly this order.
            var reportOrdinals = new List<(int Ordinal, string Name)>();
            for (var i = 0; i < reader.FieldCount; i++)
            {
                var name = reader.GetName(i);
                if (FixedColumns.Contains(name)) continue;
                reportOrdinals.Add((i, name));
                result.ReportColumns.Add(name);
            }

            var labOrdinal = TryOrdinal(reader, ColLab);
            var syncedOrdinal = TryOrdinal(reader, ColSyncedOn);
            var runIdOrdinal = TryOrdinal(reader, ColRunId);
            var weekOrdinal = TryOrdinal(reader, ColWeek);

            while (await reader.ReadAsync(ct))
            {
                var row = new ReportAuditRunRow
                {
                    RunId = ReadString(reader, runIdOrdinal) ?? string.Empty,
                    Lab = ReadString(reader, labOrdinal),
                    SyncedOn = ReadString(reader, syncedOrdinal),
                    Week = ReadString(reader, weekOrdinal)
                };
                row.SyncedOnDate = ParseSyncedOn(row.SyncedOn);

                foreach (var (ordinal, name) in reportOrdinals)
                {
                    var status = ReadString(reader, ordinal);
                    row.Statuses[name] = status;
                    if (string.IsNullOrWhiteSpace(status)) row.NotRunCount++;
                    else if (status.Equals("Success", StringComparison.OrdinalIgnoreCase)) row.SuccessCount++;
                    else if (status.Equals("Failed", StringComparison.OrdinalIgnoreCase)) row.FailedCount++;
                    else if (status.Equals("Skipped", StringComparison.OrdinalIgnoreCase)) row.SkippedCount++;
                }

                result.Rows.Add(row);
            }
        }

        await ApplyLogCountsAsync(conn, result.Rows, query, ct);
        return result;
    }

    /// <summary>
    /// Per-run log counts, so the grid can show how many entries the Error Log link will actually
    /// download (and disable it when there are none). Aggregated straight off the log table -
    /// usp_ReportRunIdInfoLog_Get only summarizes a single run per call, which would be one round
    /// trip per row.
    /// </summary>
    private static async Task ApplyLogCountsAsync(SqlConnection conn, List<ReportAuditRunRow> rows, ReportAuditQuery query, CancellationToken ct)
    {
        if (rows.Count == 0) return;

        var counts = new Dictionary<string, (int Errors, int Total)>(StringComparer.OrdinalIgnoreCase);
        await using (var cmd = new SqlCommand("""
            SELECT  L.RunId,
                    SUM(CASE WHEN L.LogType = 'Error' THEN 1 ELSE 0 END) AS ErrorCount,
                    COUNT(*)                                             AS TotalCount
            FROM    dbo.ReportRunIdInfoLog L
            WHERE  (@RunId    IS NULL OR L.RunId      = @RunId)
              AND  (@FromDate IS NULL OR L.CreatedOn >= @FromDate)
              AND  (@ToDate   IS NULL OR L.CreatedOn  < DATEADD(DAY, 1, @ToDate))
            GROUP BY L.RunId;
            """, conn))
        {
            AddNullable(cmd, "@RunId", SqlDbType.VarChar, 30, Trim(query.RunId));
            AddNullable(cmd, "@FromDate", SqlDbType.Date, 0, query.FromDate?.Date);
            AddNullable(cmd, "@ToDate", SqlDbType.Date, 0, query.ToDate?.Date);

            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                var runId = reader.IsDBNull(0) ? null : reader.GetString(0);
                if (string.IsNullOrWhiteSpace(runId)) continue;
                counts[runId] = (reader.GetInt32(1), reader.GetInt32(2));
            }
        }

        foreach (var row in rows)
        {
            if (!counts.TryGetValue(row.RunId, out var c)) continue;
            row.ErrorLogCount = c.Errors;
            row.TotalLogCount = c.Total;
        }
    }

    public async Task<IReadOnlyList<ReportRunLogEntry>> GetLogsAsync(ReportRunLogQuery query, CancellationToken ct)
    {
        var entries = new List<ReportRunLogEntry>();
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("dbo.usp_ReportRunIdInfoLog_Get", conn) { CommandType = CommandType.StoredProcedure };
        AddNullable(cmd, "@RunId", SqlDbType.VarChar, 30, Trim(query.RunId));
        AddNullable(cmd, "@LogType", SqlDbType.VarChar, 200, Trim(query.LogType));
        AddNullable(cmd, "@ReportType", SqlDbType.VarChar, 100, Trim(query.ReportType));
        AddNullable(cmd, "@SourceSystem", SqlDbType.VarChar, 100, Trim(query.SourceSystem));
        AddNullable(cmd, "@FromDate", SqlDbType.Date, 0, query.FromDate?.Date);
        AddNullable(cmd, "@ToDate", SqlDbType.Date, 0, query.ToDate?.Date);
        cmd.Parameters.Add("@Newest", SqlDbType.Bit).Value = query.Newest;
        cmd.Parameters.Add("@IncludeSummary", SqlDbType.Bit).Value = false;

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            entries.Add(new ReportRunLogEntry
            {
                ReportRunIdInfoLogId = reader.IsDBNull(0) ? 0 : Convert.ToInt64(reader.GetValue(0), CultureInfo.InvariantCulture),
                RunId = ReadString(reader, 1) ?? string.Empty,
                ReportType = ReadString(reader, 2),
                SourceSystem = ReadString(reader, 3),
                LogType = ReadString(reader, 4),
                LogMessage = ReadString(reader, 5),
                SourceFileName = ReadString(reader, 6),
                CreatedOn = reader.IsDBNull(7) ? null : reader.GetDateTime(7),
                CreatedBy = ReadString(reader, 8)
            });
        }
        return entries;
    }

    public async Task<(byte[] Content, string FileName)> ExportLogsAsync(ReportRunLogQuery query, CancellationToken ct)
    {
        var entries = await GetLogsAsync(query, ct);

        var csv = new StringBuilder();
        csv.Append(string.Join(',', LogCsvHeader.Select(Csv))).Append("\r\n");
        foreach (var e in entries)
        {
            csv.Append(string.Join(',',
                Csv(e.ReportRunIdInfoLogId.ToString(CultureInfo.InvariantCulture)),
                Csv(e.RunId),
                Csv(e.ReportType),
                Csv(e.SourceSystem),
                Csv(e.LogType),
                Csv(e.LogMessage),
                Csv(e.SourceFileName),
                Csv(e.CreatedOn?.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture)),
                Csv(e.CreatedBy))).Append("\r\n");
        }

        var scope = string.IsNullOrWhiteSpace(query.RunId) ? "AllRuns" : SafeFilePart(query.RunId!);
        var kind = string.IsNullOrWhiteSpace(query.LogType) ? "AllLogs" : SafeFilePart(query.LogType!.Replace(",", "-"));
        var fileName = $"ReportAudit_{kind}_{scope}_{DateTime.Now:yyyyMMdd_HHmmss}.csv";

        // BOM so Excel opens the UTF-8 message text (which carries non-ASCII characters) correctly.
        return (Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(csv.ToString())).ToArray(), fileName);
    }

    private static string NormalizeMode(string? mode)
    {
        var value = Trim(mode);
        return value is null ? "All"
            : value.Equals("Latest", StringComparison.OrdinalIgnoreCase) ? "Latest"
            : value.Equals("LatestSuccess", StringComparison.OrdinalIgnoreCase) ? "LatestSuccess"
            : "All";
    }

    private static DateTime? ParseSyncedOn(string? value)
        => DateTime.TryParseExact(value, "MM/dd/yyyy", CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed)
            ? parsed
            : null;

    private static int TryOrdinal(SqlDataReader reader, string name)
    {
        for (var i = 0; i < reader.FieldCount; i++)
            if (string.Equals(reader.GetName(i), name, StringComparison.OrdinalIgnoreCase)) return i;
        return -1;
    }

    private static string? ReadString(SqlDataReader reader, int ordinal)
        => ordinal < 0 || reader.IsDBNull(ordinal) ? null : Convert.ToString(reader.GetValue(ordinal), CultureInfo.InvariantCulture);

    private static string? Trim(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static void AddNullable(SqlCommand cmd, string name, SqlDbType type, int size, object? value)
    {
        var parameter = size > 0 ? cmd.Parameters.Add(name, type, size) : cmd.Parameters.Add(name, type);
        parameter.Value = value ?? DBNull.Value;
    }

    /// <summary>
    /// Always quoted, embedded quotes doubled. A leading =, +, - or @ is prefixed with a single
    /// quote so a log message is never evaluated as a formula when the file is opened in Excel.
    /// </summary>
    private static string Csv(string? value)
    {
        var text = (value ?? string.Empty).Replace("\"", "\"\"");
        if (text.Length > 0 && (text[0] is '=' or '+' or '-' or '@')) text = "'" + text;
        return $"\"{text}\"";
    }

    private static string SafeFilePart(string value)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var cleaned = new string(value.Where(c => !invalid.Contains(c) && c != ' ').ToArray());
        return string.IsNullOrWhiteSpace(cleaned) ? "Run" : cleaned[..Math.Min(cleaned.Length, 40)];
    }
}
