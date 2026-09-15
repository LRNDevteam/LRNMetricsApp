using System.Collections.Concurrent;
using System.Data;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services;

public interface IDenialSummaryRepository
{
    IReadOnlyList<(int LabId, string LabName)> GetConfiguredLabs();
    Task<IReadOnlyList<DenialSummaryObservation>> GetObservationsAsync(int labId, CancellationToken ct);
    Task<DenialSummaryObservationSaveResult> SaveObservationAsync(int labId, DenialSummaryObservationRequest request, string userName, CancellationToken ct);
    Task<IReadOnlyList<DenialSummarySnapshotInfo>> GetSnapshotsAsync(int labId, bool includeArchived, CancellationToken ct);
    Task<DenialSummarySnapshotFile?> GetSnapshotFileAsync(int labId, long snapshotId, CancellationToken ct);
    Task<bool> PeriodSnapshotExistsAsync(int labId, string periodType, DateTime periodStart, CancellationToken ct);

    /// <summary>Null when a weekly/monthly snapshot for that period already exists (another pass or instance got there first).</summary>
    Task<long?> InsertSnapshotAsync(int labId, DenialSummarySnapshotInfo info, byte[] content, CancellationToken ct);

    Task<int> ArchiveSnapshotsAsync(int labId, IReadOnlyList<long> snapshotIds, CancellationToken ct);
}

/// <summary>
/// Observations and snapshots live in each lab's own database, beside the denial tables they
/// describe - the same placement as dbo.DenialCodeMaster. Both tables are created on first use so a
/// lab does not have to run a migration before the page works; Sql/DenialSummary_Setup.sql is the
/// same DDL for DBAs who prefer to apply it ahead of the deploy.
/// </summary>
public sealed class SqlDenialSummaryRepository : IDenialSummaryRepository
{
    private static readonly ConcurrentDictionary<string, bool> SchemaReady = new(StringComparer.OrdinalIgnoreCase);

    private readonly IReadOnlyList<(int LabId, string LabName)> _labs;
    private readonly IReadOnlyDictionary<int, string> _labConnectionsById;

    public SqlDenialSummaryRepository(IConfiguration configuration)
    {
        var labItems = (configuration.GetSection("LabConfig:LabsID").Get<List<LabConfigItem>>() ?? [])
            .Where(x => x.Id > 0 && x.IsActive && !string.IsNullOrWhiteSpace(x.Name))
            .GroupBy(x => x.Id)
            .Select(g => g.First())
            .ToList();

        _labs = labItems.Select(x => (x.Id, x.Name.Trim())).ToList();
        _labConnectionsById = labItems.ToDictionary(
            x => x.Id,
            x => LabConnectionResolver.Resolve(configuration, x.Id, x.Name, x.ConnectionKey));
    }

    public IReadOnlyList<(int LabId, string LabName)> GetConfiguredLabs() => _labs;

    public async Task<IReadOnlyList<DenialSummaryObservation>> GetObservationsAsync(int labId, CancellationToken ct)
    {
        await using var conn = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand($"""
            SELECT {ObservationColumns}
            FROM dbo.DenialSummaryObservation
            WHERE LabId = @LabId
            ORDER BY SummaryType, SummaryKey;
            """, conn);
        cmd.Parameters.Add(new SqlParameter("@LabId", SqlDbType.Int) { Value = labId });

        var rows = new List<DenialSummaryObservation>();
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) rows.Add(MapObservation(reader));
        return rows;
    }

    public async Task<DenialSummaryObservationSaveResult> SaveObservationAsync(int labId, DenialSummaryObservationRequest request, string userName, CancellationToken ct)
    {
        byte[]? expectedVersion = null;
        if (!string.IsNullOrWhiteSpace(request.Version))
        {
            try { expectedVersion = Convert.FromBase64String(request.Version); }
            catch (FormatException) { return new DenialSummaryObservationSaveResult { Conflict = true }; }
        }

        // UPDLOCK+HOLDLOCK makes check-then-write atomic: two managers saving the same row at once
        // cannot both pass the version check, and a brand-new row cannot be inserted twice.
        const string sql = """
            SET XACT_ABORT ON;
            BEGIN TRAN;

            DECLARE @Current binary(8) =
                (SELECT RowVer FROM dbo.DenialSummaryObservation WITH (UPDLOCK, HOLDLOCK)
                 WHERE LabId = @LabId AND SummaryType = @SummaryType AND SummaryKey = @SummaryKey);

            IF (@Current IS NULL AND @Version IS NOT NULL)
               OR (@Current IS NOT NULL AND (@Version IS NULL OR @Current <> @Version))
            BEGIN
                ROLLBACK;
                SELECT CAST(0 AS bit) AS Saved;
                RETURN;
            END;

            IF @Current IS NULL
                INSERT dbo.DenialSummaryObservation
                    (LabId, SummaryType, SummaryKey, ObservationHtml, ResponsiblePerson, ObservationDate,
                     TargetDate, FollowUpDate, CompletedDate, CreatedBy)
                VALUES
                    (@LabId, @SummaryType, @SummaryKey, @ObservationHtml, @ResponsiblePerson, @ObservationDate,
                     @TargetDate, @FollowUpDate, @CompletedDate, @UserName);
            ELSE
                UPDATE dbo.DenialSummaryObservation
                SET ObservationHtml = @ObservationHtml,
                    ResponsiblePerson = @ResponsiblePerson,
                    ObservationDate = @ObservationDate,
                    TargetDate = @TargetDate,
                    FollowUpDate = @FollowUpDate,
                    CompletedDate = @CompletedDate,
                    UpdatedOn = SYSUTCDATETIME(),
                    UpdatedBy = @UserName
                WHERE LabId = @LabId AND SummaryType = @SummaryType AND SummaryKey = @SummaryKey;

            COMMIT;
            SELECT CAST(1 AS bit) AS Saved;
            """;

        await using var conn = await OpenLabAsync(labId, ct);
        bool saved;
        await using (var cmd = new SqlCommand(sql, conn))
        {
            cmd.Parameters.Add(new SqlParameter("@LabId", SqlDbType.Int) { Value = labId });
            cmd.Parameters.Add(new SqlParameter("@SummaryType", SqlDbType.NVarChar, 40) { Value = request.SummaryType });
            cmd.Parameters.Add(new SqlParameter("@SummaryKey", SqlDbType.NVarChar, 255) { Value = request.SummaryKey });
            cmd.Parameters.Add(new SqlParameter("@ObservationHtml", SqlDbType.NVarChar, -1) { Value = DbValue(request.ObservationHtml) });
            cmd.Parameters.Add(new SqlParameter("@ResponsiblePerson", SqlDbType.NVarChar, 200) { Value = DbValue(request.ResponsiblePerson) });
            cmd.Parameters.Add(DateParam("@ObservationDate", request.ObservationDate));
            cmd.Parameters.Add(DateParam("@TargetDate", request.TargetDate));
            cmd.Parameters.Add(DateParam("@FollowUpDate", request.FollowUpDate));
            cmd.Parameters.Add(DateParam("@CompletedDate", request.CompletedDate));
            cmd.Parameters.Add(new SqlParameter("@UserName", SqlDbType.NVarChar, 200) { Value = userName });
            cmd.Parameters.Add(new SqlParameter("@Version", SqlDbType.Binary, 8) { Value = (object?)expectedVersion ?? DBNull.Value });
            saved = Convert.ToBoolean(await cmd.ExecuteScalarAsync(ct));
        }

        var current = await ReadObservationAsync(conn, labId, request.SummaryType, request.SummaryKey, ct);
        return new DenialSummaryObservationSaveResult { Saved = saved, Conflict = !saved, Observation = current };
    }

    public async Task<IReadOnlyList<DenialSummarySnapshotInfo>> GetSnapshotsAsync(int labId, bool includeArchived, CancellationToken ct)
    {
        await using var conn = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand($"""
            SELECT {SnapshotInfoColumns}
            FROM dbo.DenialSummarySnapshot
            WHERE LabId = @LabId AND (@IncludeArchived = 1 OR IsArchived = 0)
            ORDER BY PeriodStart DESC, CreatedOn DESC, SnapshotId DESC;
            """, conn);
        cmd.Parameters.Add(new SqlParameter("@LabId", SqlDbType.Int) { Value = labId });
        cmd.Parameters.Add(new SqlParameter("@IncludeArchived", SqlDbType.Bit) { Value = includeArchived });

        var rows = new List<DenialSummarySnapshotInfo>();
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) rows.Add(MapSnapshot(reader));
        return rows;
    }

    public async Task<DenialSummarySnapshotFile?> GetSnapshotFileAsync(int labId, long snapshotId, CancellationToken ct)
    {
        await using var conn = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand("""
            SELECT FileName, Content
            FROM dbo.DenialSummarySnapshot
            WHERE LabId = @LabId AND SnapshotId = @SnapshotId;
            """, conn);
        cmd.Parameters.Add(new SqlParameter("@LabId", SqlDbType.Int) { Value = labId });
        cmd.Parameters.Add(new SqlParameter("@SnapshotId", SqlDbType.BigInt) { Value = snapshotId });

        await using var reader = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct);
        if (!await reader.ReadAsync(ct)) return null;
        var fileName = reader.GetString(0);
        var content = (byte[])reader.GetValue(1);
        return new DenialSummarySnapshotFile { FileName = fileName, Content = content };
    }

    public async Task<bool> PeriodSnapshotExistsAsync(int labId, string periodType, DateTime periodStart, CancellationToken ct)
    {
        await using var conn = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand("""
            SELECT CASE WHEN EXISTS (
                SELECT 1 FROM dbo.DenialSummarySnapshot
                WHERE LabId = @LabId AND PeriodType = @PeriodType AND PeriodStart = @PeriodStart
            ) THEN 1 ELSE 0 END;
            """, conn);
        cmd.Parameters.Add(new SqlParameter("@LabId", SqlDbType.Int) { Value = labId });
        cmd.Parameters.Add(new SqlParameter("@PeriodType", SqlDbType.NVarChar, 20) { Value = periodType });
        cmd.Parameters.Add(DateParam("@PeriodStart", periodStart));
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) == 1;
    }

    public async Task<long?> InsertSnapshotAsync(int labId, DenialSummarySnapshotInfo info, byte[] content, CancellationToken ct)
    {
        await using var conn = await OpenLabAsync(labId, ct);
        await using var cmd = new SqlCommand("""
            INSERT dbo.DenialSummarySnapshot
                (LabId, PeriodType, PeriodStart, PeriodEnd, FileName, Content, SizeBytes, TotalClaims, TotalInsuranceBalance, CreatedBy)
            OUTPUT INSERTED.SnapshotId
            VALUES
                (@LabId, @PeriodType, @PeriodStart, @PeriodEnd, @FileName, @Content, @SizeBytes, @TotalClaims, @TotalInsuranceBalance, @CreatedBy);
            """, conn);
        cmd.Parameters.Add(new SqlParameter("@LabId", SqlDbType.Int) { Value = labId });
        cmd.Parameters.Add(new SqlParameter("@PeriodType", SqlDbType.NVarChar, 20) { Value = info.PeriodType });
        cmd.Parameters.Add(DateParam("@PeriodStart", info.PeriodStart));
        cmd.Parameters.Add(DateParam("@PeriodEnd", info.PeriodEnd));
        cmd.Parameters.Add(new SqlParameter("@FileName", SqlDbType.NVarChar, 260) { Value = info.FileName });
        cmd.Parameters.Add(new SqlParameter("@Content", SqlDbType.VarBinary, -1) { Value = content });
        cmd.Parameters.Add(new SqlParameter("@SizeBytes", SqlDbType.BigInt) { Value = content.LongLength });
        cmd.Parameters.Add(new SqlParameter("@TotalClaims", SqlDbType.Int) { Value = info.TotalClaims });
        cmd.Parameters.Add(new SqlParameter("@TotalInsuranceBalance", SqlDbType.Decimal) { Precision = 18, Scale = 2, Value = info.TotalInsuranceBalance });
        cmd.Parameters.Add(new SqlParameter("@CreatedBy", SqlDbType.NVarChar, 200) { Value = DbValue(info.CreatedBy) });

        try
        {
            return Convert.ToInt64(await cmd.ExecuteScalarAsync(ct));
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            // UX_DenialSummarySnapshot_Period: the period is already captured.
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
                UPDATE dbo.DenialSummarySnapshot
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

    private const string ObservationColumns = """
        SummaryType, SummaryKey, ObservationHtml, ResponsiblePerson, ObservationDate, TargetDate,
        FollowUpDate, CompletedDate, CreatedOn, CreatedBy, UpdatedOn, UpdatedBy, RowVer
        """;

    private const string SnapshotInfoColumns = """
        SnapshotId, LabId, PeriodType, PeriodStart, PeriodEnd, FileName, SizeBytes, TotalClaims,
        TotalInsuranceBalance, IsArchived, ArchivedOn, CreatedOn, CreatedBy
        """;

    private static async Task<DenialSummaryObservation?> ReadObservationAsync(SqlConnection conn, int labId, string summaryType, string summaryKey, CancellationToken ct)
    {
        await using var cmd = new SqlCommand($"""
            SELECT {ObservationColumns}
            FROM dbo.DenialSummaryObservation
            WHERE LabId = @LabId AND SummaryType = @SummaryType AND SummaryKey = @SummaryKey;
            """, conn);
        cmd.Parameters.Add(new SqlParameter("@LabId", SqlDbType.Int) { Value = labId });
        cmd.Parameters.Add(new SqlParameter("@SummaryType", SqlDbType.NVarChar, 40) { Value = summaryType });
        cmd.Parameters.Add(new SqlParameter("@SummaryKey", SqlDbType.NVarChar, 255) { Value = summaryKey });
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? MapObservation(reader) : null;
    }

    private static DenialSummaryObservation MapObservation(SqlDataReader r) => new()
    {
        SummaryType = r.GetString(0),
        SummaryKey = r.GetString(1),
        // Sanitized again on read: a row written directly in SQL must not reach the browser raw.
        ObservationHtml = r.IsDBNull(2) ? null : DenialSummaryHtml.Sanitize(r.GetString(2)),
        ResponsiblePerson = r.IsDBNull(3) ? null : r.GetString(3),
        ObservationDate = r.IsDBNull(4) ? null : r.GetDateTime(4),
        TargetDate = r.IsDBNull(5) ? null : r.GetDateTime(5),
        FollowUpDate = r.IsDBNull(6) ? null : r.GetDateTime(6),
        CompletedDate = r.IsDBNull(7) ? null : r.GetDateTime(7),
        CreatedOn = r.GetDateTime(8),
        CreatedBy = r.IsDBNull(9) ? null : r.GetString(9),
        UpdatedOn = r.IsDBNull(10) ? null : r.GetDateTime(10),
        UpdatedBy = r.IsDBNull(11) ? null : r.GetString(11),
        Version = Convert.ToBase64String((byte[])r.GetValue(12))
    };

    private static DenialSummarySnapshotInfo MapSnapshot(SqlDataReader r) => new()
    {
        SnapshotId = r.GetInt64(0),
        LabId = r.GetInt32(1),
        PeriodType = r.GetString(2),
        PeriodStart = r.GetDateTime(3),
        PeriodEnd = r.GetDateTime(4),
        FileName = r.GetString(5),
        SizeBytes = r.GetInt64(6),
        TotalClaims = r.GetInt32(7),
        TotalInsuranceBalance = r.GetDecimal(8),
        IsArchived = r.GetBoolean(9),
        ArchivedOn = r.IsDBNull(10) ? null : r.GetDateTime(10),
        CreatedOn = r.GetDateTime(11),
        CreatedBy = r.IsDBNull(12) ? null : r.GetString(12)
    };

    private async Task<SqlConnection> OpenLabAsync(int labId, CancellationToken ct)
    {
        if (labId <= 0) throw new InvalidOperationException("LabId is required.");
        if (!_labConnectionsById.TryGetValue(labId, out var connectionString) || string.IsNullOrWhiteSpace(connectionString))
            throw new InvalidOperationException($"No lab database connection string is configured for LabId {labId}. Add LabConfig:LabsID and a matching ConnectionStrings entry.");

        var conn = new SqlConnection(connectionString);
        try
        {
            await conn.OpenAsync(ct);
            var key = $"{conn.DataSource}|{conn.Database}";
            if (!SchemaReady.ContainsKey(key))
            {
                // One command per statement: an index is not compiled in the same batch as the
                // CREATE TABLE it depends on.
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

    private static SqlParameter DateParam(string name, DateTime? value)
        => new(name, SqlDbType.Date) { Value = value.HasValue ? value.Value.Date : DBNull.Value };

    private static object DbValue(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();

    /// <summary>Keep in step with Sql/DenialSummary_Setup.sql.</summary>
    internal static readonly string[] SchemaStatements =
    [
        """
        IF OBJECT_ID('dbo.DenialSummaryObservation', 'U') IS NULL
        BEGIN
            CREATE TABLE dbo.DenialSummaryObservation
            (
                LabId             int            NOT NULL,
                SummaryType       nvarchar(40)   NOT NULL,
                SummaryKey        nvarchar(255)  NOT NULL,
                ObservationHtml   nvarchar(max)  NULL,
                ResponsiblePerson nvarchar(200)  NULL,
                ObservationDate   date           NULL,
                TargetDate        date           NULL,
                FollowUpDate      date           NULL,
                CompletedDate     date           NULL,
                CreatedOn         datetime2(0)   NOT NULL CONSTRAINT DF_DenialSummaryObservation_CreatedOn DEFAULT SYSUTCDATETIME(),
                CreatedBy         nvarchar(200)  NULL,
                UpdatedOn         datetime2(0)   NULL,
                UpdatedBy         nvarchar(200)  NULL,
                RowVer            rowversion     NOT NULL,
                CONSTRAINT PK_DenialSummaryObservation PRIMARY KEY CLUSTERED (LabId, SummaryType, SummaryKey)
            );
        END;
        """,
        """
        IF OBJECT_ID('dbo.DenialSummarySnapshot', 'U') IS NULL
        BEGIN
            CREATE TABLE dbo.DenialSummarySnapshot
            (
                SnapshotId            bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialSummarySnapshot PRIMARY KEY CLUSTERED,
                LabId                 int             NOT NULL,
                PeriodType            nvarchar(20)    NOT NULL,
                PeriodStart           date            NOT NULL,
                PeriodEnd             date            NOT NULL,
                FileName              nvarchar(260)   NOT NULL,
                Content               varbinary(max)  NOT NULL,
                SizeBytes             bigint          NOT NULL,
                TotalClaims           int             NOT NULL CONSTRAINT DF_DenialSummarySnapshot_TotalClaims DEFAULT 0,
                TotalInsuranceBalance decimal(18,2)   NOT NULL CONSTRAINT DF_DenialSummarySnapshot_TotalIns DEFAULT 0,
                IsArchived            bit             NOT NULL CONSTRAINT DF_DenialSummarySnapshot_IsArchived DEFAULT 0,
                ArchivedOn            datetime2(0)    NULL,
                CreatedOn             datetime2(0)    NOT NULL CONSTRAINT DF_DenialSummarySnapshot_CreatedOn DEFAULT SYSUTCDATETIME(),
                CreatedBy             nvarchar(200)   NULL,
                CONSTRAINT CK_DenialSummarySnapshot_PeriodType CHECK (PeriodType IN (N'Weekly', N'Monthly', N'OnDemand'))
            );
        END;
        """,
        """
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_DenialSummarySnapshot_Period' AND object_id = OBJECT_ID('dbo.DenialSummarySnapshot'))
            CREATE UNIQUE NONCLUSTERED INDEX UX_DenialSummarySnapshot_Period
            ON dbo.DenialSummarySnapshot (LabId, PeriodType, PeriodStart)
            WHERE PeriodType IN (N'Weekly', N'Monthly');
        """,
        """
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialSummarySnapshot_List' AND object_id = OBJECT_ID('dbo.DenialSummarySnapshot'))
            CREATE NONCLUSTERED INDEX IX_DenialSummarySnapshot_List
            ON dbo.DenialSummarySnapshot (LabId, IsArchived, PeriodStart DESC)
            INCLUDE (PeriodType, PeriodEnd, FileName, SizeBytes, TotalClaims, TotalInsuranceBalance, ArchivedOn, CreatedOn, CreatedBy);
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
