using System.Data;
using System.Text.RegularExpressions;
using LRN.CpuMonitor.Models;
using Microsoft.Data.SqlClient;

namespace LRN.CpuMonitor.Services;

/// <summary>
/// Attributes SQL Server CPU to a caller. The engine runs every database, session and
/// query inside one process, so <c>sqlservr.exe</c> sitting at 90% says nothing about
/// the cause on its own -- only the request DMVs do.
/// </summary>
public sealed partial class SqlActivityProbe : ISqlActivityProbe
{
    /// <summary>
    /// Ordered by CPU consumed so far. <c>host_process_id</c> is the column that
    /// matters most: it is the caller's PID on <c>host_name</c>, which turns "SQL
    /// Server is busy" into a named process on a named machine.
    /// </summary>
    private const string TopCpuRequestsSql = """
        SELECT TOP (@TopN)
               r.session_id,
               s.login_name,
               s.host_name,
               s.program_name,
               s.client_interface_name,
               s.host_process_id,
               DB_NAME(r.database_id) AS database_name,
               r.command,
               r.cpu_time,
               r.total_elapsed_time,
               r.logical_reads,
               r.writes,
               r.wait_type,
               r.blocking_session_id,
               SUBSTRING(t.text,
                         (r.statement_start_offset / 2) + 1,
                         ((CASE r.statement_end_offset
                                WHEN -1 THEN DATALENGTH(t.text)
                                ELSE r.statement_end_offset
                            END - r.statement_start_offset) / 2) + 1) AS statement_text
        FROM sys.dm_exec_requests AS r
        INNER JOIN sys.dm_exec_sessions AS s
                ON s.session_id = r.session_id
        OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
        WHERE r.session_id <> @@SPID
          AND s.is_user_process = 1
        ORDER BY r.cpu_time DESC;
        """;

    /// <summary>The server is by definition overloaded when this runs, so fail fast.</summary>
    private const int CommandTimeoutSeconds = 15;

    private const int MaxStatementLength = 2000;

    private readonly ILogger<SqlActivityProbe> _logger;

    public SqlActivityProbe(ILogger<SqlActivityProbe> logger)
    {
        _logger = logger;
    }

    public async Task<IReadOnlyList<SqlRequestActivity>> GetTopCpuRequestsAsync(
        string connectionString,
        int topN,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            _logger.LogInformation(
                "SQL Server breached the CPU threshold but no SqlConnectionString is configured, "
                    + "so the request cannot be attributed to a caller");
            return [];
        }

        try
        {
            await using var connection = new SqlConnection(connectionString);
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);

            await using var command = new SqlCommand(TopCpuRequestsSql, connection)
            {
                CommandTimeout = CommandTimeoutSeconds,
            };
            command.Parameters.Add("@TopN", SqlDbType.Int).Value = Math.Clamp(topN, 1, 50);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);

            var requests = new List<SqlRequestActivity>();

            while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
            {
                requests.Add(new SqlRequestActivity(
                    SessionId: reader.GetInt16(0),
                    LoginName: ReadString(reader, 1),
                    HostName: ReadString(reader, 2),
                    ProgramName: ReadString(reader, 3),
                    ClientInterface: ReadString(reader, 4),
                    HostProcessId: ReadNullableInt(reader, 5),
                    DatabaseName: ReadString(reader, 6),
                    Command: ReadString(reader, 7),
                    CpuTimeMs: ReadInt64(reader, 8),
                    ElapsedMs: ReadInt64(reader, 9),
                    LogicalReads: ReadInt64(reader, 10),
                    Writes: ReadInt64(reader, 11),
                    WaitType: ReadString(reader, 12),
                    BlockingSessionId: ReadNullableInt16(reader, 13),
                    StatementText: Condense(ReadString(reader, 14))));
            }

            return requests;
        }
        catch (SqlException ex)
        {
            // A missing VIEW SERVER STATE grant is a far more common cause here than an
            // actual outage, so the message points at it directly.
            _logger.LogWarning(
                ex,
                "Could not read SQL Server request DMVs (error {Number}); the monitor login needs VIEW SERVER STATE",
                ex.Number);
            return [];
        }
        catch (Exception ex) when (ex is InvalidOperationException or TimeoutException)
        {
            _logger.LogWarning(ex, "SQL Server did not respond to the CPU attribution query in time");
            return [];
        }
    }

    private static string ReadString(SqlDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? "" : reader.GetValue(ordinal).ToString() ?? "";

    private static long ReadInt64(SqlDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? 0 : Convert.ToInt64(reader.GetValue(ordinal));

    private static int? ReadNullableInt(SqlDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? null : Convert.ToInt32(reader.GetValue(ordinal));

    private static short? ReadNullableInt16(SqlDataReader reader, int ordinal) =>
        reader.IsDBNull(ordinal) ? null : Convert.ToInt16(reader.GetValue(ordinal));

    /// <summary>
    /// Flattens a query onto one line so it stays readable in a log record.
    /// </summary>
    private static string Condense(string statement)
    {
        if (string.IsNullOrWhiteSpace(statement))
        {
            return "(unavailable)";
        }

        var condensed = WhitespaceRuns().Replace(statement, " ").Trim();

        return condensed.Length <= MaxStatementLength
            ? condensed
            : condensed[..MaxStatementLength] + " ...(truncated)";
    }

    [GeneratedRegex(@"\s+")]
    private static partial Regex WhitespaceRuns();
}
