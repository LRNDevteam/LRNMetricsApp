using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

public sealed class AnalysisRangeService : IAnalysisRangeService
{
    private readonly ILogger<AnalysisRangeService> _logger;

    public AnalysisRangeService(ILogger<AnalysisRangeService> logger)
        => _logger = logger;

    /// <inheritdoc />
    public async Task<AnalysisRangeInfo> GetAsync(string connectionString, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(connectionString))
            return AnalysisRangeInfo.Empty;

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            // Prefer LineClaimFileLogs (same source as Production Report).
            var fromLogs = await TryReadAsync(conn, @"
IF OBJECT_ID('dbo.LineClaimFileLogs','U') IS NULL RETURN;
SELECT TOP 1
       CAST(WeekFolder AS NVARCHAR(200)),
       CAST(RunId AS NVARCHAR(50)),
       InsertedDateTime
FROM dbo.LineClaimFileLogs
WHERE NULLIF(LTRIM(RTRIM(CAST(RunId AS NVARCHAR(50)))), '') IS NOT NULL
ORDER BY CAST(RunId AS NVARCHAR(50)) DESC, FileLogId DESC;", ct);
            if (fromLogs.HasAny)
                return fromLogs;

            // Fallback: latest ClaimLevelData row.
            return await TryReadAsync(conn, @"
IF OBJECT_ID('dbo.ClaimLevelData','U') IS NULL RETURN;
IF COL_LENGTH('dbo.ClaimLevelData','RunId') IS NULL RETURN;
SELECT TOP 1
       CAST(WeekFolder AS NVARCHAR(200)),
       CAST(RunId AS NVARCHAR(50)),
       TRY_CONVERT(datetime, InsertedDateTime)
FROM dbo.ClaimLevelData
WHERE NULLIF(LTRIM(RTRIM(CAST(RunId AS NVARCHAR(50)))), '') IS NOT NULL
ORDER BY CAST(RunId AS NVARCHAR(50)) DESC;", ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to read analysis-range banner from LineClaimFileLogs / ClaimLevelData.");
            return AnalysisRangeInfo.Empty;
        }
    }

    private static async Task<AnalysisRangeInfo> TryReadAsync(
        SqlConnection conn, string sql, CancellationToken ct)
    {
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
        await using var rdr = await cmd.ExecuteReaderAsync(ct);
        if (!await rdr.ReadAsync(ct))
            return AnalysisRangeInfo.Empty;

        return new AnalysisRangeInfo
        {
            WeekFolder = rdr.IsDBNull(0) ? null : rdr.GetString(0),
            RunId = rdr.IsDBNull(1) ? null : rdr.GetString(1),
            InsertedDateTime = rdr.FieldCount > 2 && !rdr.IsDBNull(2) ? rdr.GetDateTime(2) : null,
        };
    }
}
