using System.Collections.Concurrent;
using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services;

public interface IDenialDashboardSnapshotRepository
{
    Task<IReadOnlyList<DenialDashboardSnapshotInfo>> GetSnapshotsAsync(int labId, bool includeArchived, CancellationToken ct);
    Task<DenialDashboardSnapshotFile?> GetSnapshotFileAsync(int labId, long snapshotId, CancellationToken ct);
    Task<bool> PeriodSnapshotExistsAsync(int labId, string periodType, DateTime periodStart, CancellationToken ct);

    /// <summary>Null when a weekly/monthly snapshot for that period already exists.</summary>
    Task<long?> InsertSnapshotAsync(int labId, DenialDashboardSnapshotInfo info, byte[] content, CancellationToken ct);

    Task<int> ArchiveSnapshotsAsync(int labId, IReadOnlyList<long> snapshotIds, CancellationToken ct);
}

/// <summary>
/// Denial Dashboard snapshots live in each lab's own database, beside the tables the workbook
/// summarizes - the same placement as dbo.DenialSummarySnapshot (a sibling feature on a different
/// page). Table created on first use so a lab does not need a migration before this works.
///
/// This repository only stores and retrieves the workbook bytes; LabMetricsDashboard builds them
/// (it owns DenialDashboardExcelExportBuilder) and calls the api/denial-dashboard/snapshots
/// endpoints, matching how this project's Denial Dashboard data access already works the other way
/// round: LabMetricsDashboard never opens a lab database connection directly.
/// </summary>
public sealed class SqlDenialDashboardSnapshotRepository : IDenialDashboardSnapshotRepository
{
    private static readonly ConcurrentDictionary<string, bool> SchemaReady = new(StringComparer.OrdinalIgnoreCase);

    private readonly IReadOnlyDictionary<int, string> _labConnectionsById;

    public SqlDenialDashboardSnapshotRepository(IConfiguration configuration)
    {
        var labItems = (configuration.GetSection("LabConfig:LabsID").Get<List<LabConfigItem>>() ?? [])
            .Where(x => x.Id > 0 && x.IsActive && !string.IsNullOrWhiteSpace(x.Name))
            .GroupBy(x => x.Id)
            .Select(g => g.First())
            .ToList();

        _labConnectionsById = labItems.ToDictionary(
            x => x.Id,
            x => LabConnectionResolver.Resolve(configuration, x.Id, x.Name, x.ConnectionKey));
    }

    public async Task<IReadOnlyList<DenialDashboardSnapshotInfo>> GetSnapshotsAsync(int labId, bool includeArchived, CancellationToken ct)
    {
        await using var conn = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand($"""
            SELECT {InfoColumns}
            FROM dbo.DenialDashboardSnapshot
            WHERE LabId = @LabId AND (@IncludeArchived = 1 OR IsArchived = 0)
            ORDER BY PeriodStart DESC, CreatedOn DESC, SnapshotId DESC;
            """, conn);
        cmd.Parameters.Add(new SqlParameter("@LabId", SqlDbType.Int) { Value = labId });
        cmd.Parameters.Add(new SqlParameter("@IncludeArchived", SqlDbType.Bit) { Value = includeArchived });

        var rows = new List<DenialDashboardSnapshotInfo>();
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) rows.Add(MapInfo(reader));
        return rows;
    }

    public async Task<DenialDashboardSnapshotFile?> GetSnapshotFileAsync(int labId, long snapshotId, CancellationToken ct)
    {
        await using var conn = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand("""
            SELECT FileName, Content
            FROM dbo.DenialDashboardSnapshot
            WHERE LabId = @LabId AND SnapshotId = @SnapshotId;
            """, conn);
        cmd.Parameters.Add(new SqlParameter("@LabId", SqlDbType.Int) { Value = labId });
        cmd.Parameters.Add(new SqlParameter("@SnapshotId", SqlDbType.BigInt) { Value = snapshotId });

        await using var reader = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct);
        if (!await reader.ReadAsync(ct)) return null;
        return new DenialDashboardSnapshotFile { FileName = reader.GetString(0), Content = (byte[])reader.GetValue(1) };
    }

    public async Task<bool> PeriodSnapshotExistsAsync(int labId, string periodType, DateTime periodStart, CancellationToken ct)
    {
        await using var conn = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand("""
            SELECT CASE WHEN EXISTS (
                SELECT 1 FROM dbo.DenialDashboardSnapshot
                WHERE LabId = @LabId AND PeriodType = @PeriodType AND PeriodStart = @PeriodStart
            ) THEN 1 ELSE 0 END;
            """, conn);
        cmd.Parameters.Add(new SqlParameter("@LabId", SqlDbType.Int) { Value = labId });
        cmd.Parameters.Add(new SqlParameter("@PeriodType", SqlDbType.NVarChar, 20) { Value = periodType });
        cmd.Parameters.Add(new SqlParameter("@PeriodStart", SqlDbType.Date) { Value = periodStart.Date });
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) == 1;
    }

    public async Task<long?> InsertSnapshotAsync(int labId, DenialDashboardSnapshotInfo info, byte[] content, CancellationToken ct)
    {
        await using var conn = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand("""
            INSERT dbo.DenialDashboardSnapshot
                (LabId, PeriodType, PeriodStart, PeriodEnd, FileName, Content, SizeBytes, CreatedBy)
            OUTPUT INSERTED.SnapshotId
            VALUES
                (@LabId, @PeriodType, @PeriodStart, @PeriodEnd, @FileName, @Content, @SizeBytes, @CreatedBy);
            """, conn);
        cmd.Parameters.Add(new SqlParameter("@LabId", SqlDbType.Int) { Value = labId });
        cmd.Parameters.Add(new SqlParameter("@PeriodType", SqlDbType.NVarChar, 20) { Value = info.PeriodType });
        cmd.Parameters.Add(new SqlParameter("@PeriodStart", SqlDbType.Date) { Value = info.PeriodStart.Date });
        cmd.Parameters.Add(new SqlParameter("@PeriodEnd", SqlDbType.Date) { Value = info.PeriodEnd.Date });
        cmd.Parameters.Add(new SqlParameter("@FileName", SqlDbType.NVarChar, 260) { Value = info.FileName });
        cmd.Parameters.Add(new SqlParameter("@Content", SqlDbType.VarBinary, -1) { Value = content });
        cmd.Parameters.Add(new SqlParameter("@SizeBytes", SqlDbType.BigInt) { Value = content.LongLength });
        cmd.Parameters.Add(new SqlParameter("@CreatedBy", SqlDbType.NVarChar, 200) { Value = (object?)info.CreatedBy ?? DBNull.Value });

        try
        {
            return Convert.ToInt64(await cmd.ExecuteScalarAsync(ct));
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            // UX_DenialDashboardSnapshot_Period: the period is already captured.
            return null;
        }
    }

    public async Task<int> ArchiveSnapshotsAsync(int labId, IReadOnlyList<long> snapshotIds, CancellationToken ct)
    {
        if (snapshotIds.Count == 0) return 0;

        await using var conn = await OpenLabAsync(labId, ct);
        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(ct);
        var archived = 0;

        foreach (var id in snapshotIds)
        {
            await using var cmd = new SqlCommand("""
                UPDATE dbo.DenialDashboardSnapshot
                SET IsArchived = 1, ArchivedOn = SYSUTCDATETIME()
                WHERE LabId = @LabId AND SnapshotId = @SnapshotId AND IsArchived = 0;
                """, conn, tx);
            cmd.Parameters.Add(new SqlParameter("@LabId", SqlDbType.Int) { Value = labId });
            cmd.Parameters.Add(new SqlParameter("@SnapshotId", SqlDbType.BigInt) { Value = id });
            archived += await cmd.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
        return archived;
    }

    private const string InfoColumns = """
        SnapshotId, LabId, PeriodType, PeriodStart, PeriodEnd, FileName, SizeBytes, IsArchived, ArchivedOn, CreatedOn, CreatedBy
        """;

    private static DenialDashboardSnapshotInfo MapInfo(SqlDataReader r) => new()
    {
        SnapshotId = r.GetInt64(0),
        LabId = r.GetInt32(1),
        PeriodType = r.GetString(2),
        PeriodStart = r.GetDateTime(3),
        PeriodEnd = r.GetDateTime(4),
        FileName = r.GetString(5),
        SizeBytes = r.GetInt64(6),
        IsArchived = r.GetBoolean(7),
        ArchivedOn = r.IsDBNull(8) ? null : r.GetDateTime(8),
        CreatedOn = r.GetDateTime(9),
        CreatedBy = r.IsDBNull(10) ? null : r.GetString(10)
    };

    private async Task<SqlConnection> OpenLabAsync(int labId, CancellationToken ct)
    {
        if (labId <= 0) throw new InvalidOperationException("LabId is required.");
        if (!_labConnectionsById.TryGetValue(labId, out var connectionString) || string.IsNullOrWhiteSpace(connectionString))
            throw new InvalidOperationException($"No lab database connection string is configured for LabId {labId}.");

        var conn = new SqlConnection(connectionString);
        try
        {
            await conn.OpenAsync(ct);
            var key = $"{conn.DataSource}|{conn.Database}";
            if (!SchemaReady.ContainsKey(key))
            {
                foreach (var statement in SchemaStatements)
                {
                    await using var ddl = new SqlCommand(statement, conn) { CommandTimeout = 120 };
                    await ddl.ExecuteNonQueryAsync(ct);
                }
                SchemaReady[key] = true;
            }
            return conn;
        }
        catch
        {
            await conn.DisposeAsync();
            throw;
        }
    }

    /// <summary>Keep in step with Sql/DenialDashboardSnapshot_Setup.sql.</summary>
    internal static readonly string[] SchemaStatements =
    [
        """
        IF OBJECT_ID('dbo.DenialDashboardSnapshot', 'U') IS NULL
        BEGIN
            CREATE TABLE dbo.DenialDashboardSnapshot
            (
                SnapshotId  bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialDashboardSnapshot PRIMARY KEY CLUSTERED,
                LabId       int             NOT NULL,
                PeriodType  nvarchar(20)    NOT NULL,
                PeriodStart date            NOT NULL,
                PeriodEnd   date            NOT NULL,
                FileName    nvarchar(260)   NOT NULL,
                Content     varbinary(max)  NOT NULL,
                SizeBytes   bigint          NOT NULL,
                IsArchived  bit             NOT NULL CONSTRAINT DF_DenialDashboardSnapshot_IsArchived DEFAULT 0,
                ArchivedOn  datetime2(0)    NULL,
                CreatedOn   datetime2(0)    NOT NULL CONSTRAINT DF_DenialDashboardSnapshot_CreatedOn DEFAULT SYSUTCDATETIME(),
                CreatedBy   nvarchar(200)   NULL,
                CONSTRAINT CK_DenialDashboardSnapshot_PeriodType CHECK (PeriodType IN (N'Weekly', N'Monthly', N'OnDemand'))
            );
        END;
        """,
        """
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_DenialDashboardSnapshot_Period' AND object_id = OBJECT_ID('dbo.DenialDashboardSnapshot'))
            CREATE UNIQUE NONCLUSTERED INDEX UX_DenialDashboardSnapshot_Period
            ON dbo.DenialDashboardSnapshot (LabId, PeriodType, PeriodStart)
            WHERE PeriodType IN (N'Weekly', N'Monthly');
        """,
        """
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialDashboardSnapshot_List' AND object_id = OBJECT_ID('dbo.DenialDashboardSnapshot'))
            CREATE NONCLUSTERED INDEX IX_DenialDashboardSnapshot_List
            ON dbo.DenialDashboardSnapshot (LabId, IsArchived, PeriodStart DESC)
            INCLUDE (PeriodType, PeriodEnd, FileName, SizeBytes, ArchivedOn, CreatedOn, CreatedBy);
        """
    ];

    private sealed class LabConfigItem
    {
        public int Id { get; set; }
        public string Name { get; set; } = string.Empty;
        public string ConnectionKey { get; set; } = string.Empty;
        public bool IsActive { get; set; } = true;
    }
}
