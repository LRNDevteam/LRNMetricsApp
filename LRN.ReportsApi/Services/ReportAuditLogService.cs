using System.Data;
using System.Globalization;
using System.Text;
using ClosedXML.Excel;
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
    /// <summary>
    /// The run's log as a formatted .xlsx: columns auto-sized to their content and the Log Message
    /// column wrapped, so a long message stays readable instead of a single runaway CSV column.
    /// </summary>
    Task<(byte[] Content, string FileName)> ExportLogsExcelAsync(ReportRunLogQuery query, CancellationToken ct);
    /// <summary>
    /// Pipeline failures from dbo.LRN_Error_Log for one run - the operational view (step, error code,
    /// recommended action, owning team), which the info log does not carry.
    /// </summary>
    Task<IReadOnlyList<PipelineErrorEntry>> GetPipelineErrorsAsync(string? runId, string? labName, CancellationToken ct);
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

/// <summary>One row of dbo.LRN_Error_Log - a failure raised by the report pipeline itself.</summary>
public sealed class PipelineErrorEntry
{
    public string? RunId { get; set; }
    public string? LabName { get; set; }
    public DateTime? ErrorTime { get; set; }
    public string? Severity { get; set; }
    public string? StepName { get; set; }
    public string? ErrorCode { get; set; }
    public string? ErrorSummary { get; set; }
    public string? MissingColumns { get; set; }
    public string? SheetName { get; set; }
    public string? FileName { get; set; }
    public string? RecommendedAction { get; set; }
    public string? OwnerTeam { get; set; }
    public string? TicketId { get; set; }
    public string? Status { get; set; }
    public string? SourceSystem { get; set; }
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

    public async Task<IReadOnlyList<PipelineErrorEntry>> GetPipelineErrorsAsync(string? runId, string? labName, CancellationToken ct)
    {
        var entries = new List<PipelineErrorEntry>();
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT  E.RunID, E.LabName, E.ErrorTimeIST, E.Severity, E.StepName, E.ErrorCode,
                    E.ErrorSummary, E.MissingColumns, E.SheetName, E.FileName,
                    E.RecommendedAction, E.OwnerTeam, E.TicketID, E.Status, E.SourceSystem
            FROM    dbo.LRN_Error_Log E
            WHERE  (@RunId   IS NULL OR E.RunID   = @RunId)
              AND  (@LabName IS NULL OR E.LabName = @LabName)
            ORDER BY E.ErrorTimeIST DESC;
            """, conn) { CommandTimeout = 30 };
        AddNullable(cmd, "@RunId", SqlDbType.VarChar, 30, Trim(runId));
        AddNullable(cmd, "@LabName", SqlDbType.VarChar, 120, Trim(labName));

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            entries.Add(new PipelineErrorEntry
            {
                RunId = ReadString(reader, 0),
                LabName = ReadString(reader, 1),
                ErrorTime = reader.IsDBNull(2) ? null : reader.GetDateTime(2),
                Severity = ReadString(reader, 3),
                StepName = ReadString(reader, 4),
                ErrorCode = ReadString(reader, 5),
                ErrorSummary = ReadString(reader, 6),
                MissingColumns = ReadString(reader, 7),
                SheetName = ReadString(reader, 8),
                FileName = ReadString(reader, 9),
                RecommendedAction = ReadString(reader, 10),
                OwnerTeam = ReadString(reader, 11),
                TicketId = ReadString(reader, 12),
                Status = ReadString(reader, 13),
                SourceSystem = ReadString(reader, 14)
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

    public async Task<(byte[] Content, string FileName)> ExportLogsExcelAsync(ReportRunLogQuery query, CancellationToken ct)
    {
        var entries = await GetLogsAsync(query, ct);

        using var workbook = new XLWorkbook();
        var ws = workbook.Worksheets.Add("Error Log");

        // Header row.
        for (var c = 0; c < LogCsvHeader.Length; c++)
            ws.Cell(1, c + 1).Value = LogCsvHeader[c];
        var header = ws.Row(1);
        header.Style.Font.Bold = true;
        header.Style.Fill.BackgroundColor = XLColor.FromHtml("#0e3460");
        header.Style.Font.FontColor = XLColor.White;
        header.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;

        var r = 2;
        foreach (var e in entries)
        {
            ws.Cell(r, 1).Value = e.ReportRunIdInfoLogId;
            ws.Cell(r, 2).Value = e.RunId;
            ws.Cell(r, 3).Value = e.ReportType ?? string.Empty;
            ws.Cell(r, 4).Value = e.SourceSystem ?? string.Empty;
            ws.Cell(r, 5).Value = e.LogType ?? string.Empty;
            ws.Cell(r, 6).Value = e.LogMessage ?? string.Empty;
            ws.Cell(r, 7).Value = e.SourceFileName ?? string.Empty;
            ws.Cell(r, 8).Value = e.CreatedOn?.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) ?? string.Empty;
            ws.Cell(r, 9).Value = e.CreatedBy ?? string.Empty;
            r++;
        }

        var used = ws.RangeUsed();
        if (used is not null)
        {
            used.Style.Alignment.Vertical = XLAlignmentVerticalValues.Top;
            used.Style.Border.BottomBorder = XLBorderStyleValues.Thin;
            used.Style.Border.BottomBorderColor = XLColor.FromHtml("#e2e8f0");
        }

        // Auto-size every column to its content, then cap so one long value can't create a runaway
        // column. The Log Message column (6) instead gets a fixed generous width + wrap, so long
        // messages flow onto multiple lines within the cell and each row grows to fit.
        ws.Columns().AdjustToContents();
        const int LogMessageColumn = 6;
        foreach (var column in ws.ColumnsUsed())
        {
            if (column.ColumnNumber() == LogMessageColumn)
            {
                column.Width = 90;
                column.Style.Alignment.WrapText = true;
            }
            else if (column.Width > 55)
            {
                column.Width = 55;
                column.Style.Alignment.WrapText = true;
            }
        }

        ws.SheetView.FreezeRows(1);
        if (r > 2) ws.Range(1, 1, r - 1, LogCsvHeader.Length).SetAutoFilter();

        using var ms = new MemoryStream();
        workbook.SaveAs(ms);

        var scope = string.IsNullOrWhiteSpace(query.RunId) ? "AllRuns" : SafeFilePart(query.RunId!);
        var kind = string.IsNullOrWhiteSpace(query.LogType) ? "AllLogs" : SafeFilePart(query.LogType!.Replace(",", "-"));
        var fileName = $"ReportAudit_{kind}_{scope}_{DateTime.Now:yyyyMMdd_HHmmss}.xlsx";
        return (ms.ToArray(), fileName);
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
