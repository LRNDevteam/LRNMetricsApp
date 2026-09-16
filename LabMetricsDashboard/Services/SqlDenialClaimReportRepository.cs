using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

public interface IDenialClaimReportRepository
{
    /// <summary>Denied claims straight from the lab's own dbo.ClaimLevelData - the system-of-record dataset.</summary>
    Task<IReadOnlyList<DenialClaimRow>> GetDenialClaimsAsync(string connectionString, CancellationToken ct);

    /// <summary>
    /// The four-step description cascade: the lab's own Denial-Action master then the Super Master,
    /// each matched on the raw code before the normalized one.
    /// </summary>
    Task<DenialDescriptionLookup> GetDescriptionsAsync(string connectionString, string? masterConnectionString, CancellationToken ct);

    /// <summary>The insight rows on one tab - Current, Previous or Archive.</summary>
    Task<IReadOnlyList<DenialInsightClaimLevelRow>> GetInsightsAsync(string connectionString, string bucket, CancellationToken ct);

    /// <summary>Upsert by (Bucket, WeekStart, DenialCode, PayerName) - a template row's identity.</summary>
    Task<DenialInsightUploadResult> SaveInsightsAsync(string connectionString, IReadOnlyList<DenialInsightClaimLevelRow> rows, string userName, CancellationToken ct);

    /// <summary>Copies Current Week into Previous Week and archives anything past the 4-week window.</summary>
    Task<DenialInsightCopyResult> CopyCurrentToPreviousAsync(string connectionString, string userName, CancellationToken ct);
}

/// <summary>
/// Denial Claim Report data access, straight against each lab's own database.
///
/// Reads <c>dbo.ClaimLevelData</c> for the denied claims every summary metric is calculated from,
/// and owns <c>dbo.DenialInsightClaimLevel</c>, the per-lab table holding the insight rows a client
/// imports and edits. The two stay distinct by design: importing insights never writes to, or
/// recalculates, claim-level data.
///
/// Column selection is probed rather than assumed - lab databases differ in which optional
/// ClaimLevelData columns they carry, so a lab missing one gets NULL for it instead of a failed query.
/// </summary>
public sealed class SqlDenialClaimReportRepository : IDenialClaimReportRepository
{
    private readonly ILogger<SqlDenialClaimReportRepository> _logger;

    public SqlDenialClaimReportRepository(ILogger<SqlDenialClaimReportRepository> logger) => _logger = logger;

    public async Task<IReadOnlyList<DenialClaimRow>> GetDenialClaimsAsync(string connectionString, CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        if (!await TableExistsAsync(conn, "ClaimLevelData", ct)) return Array.Empty<DenialClaimRow>();

        var cols = await GetColumnsAsync(conn, "ClaimLevelData", ct);
        if (!cols.Contains("DenialCode")) return Array.Empty<DenialClaimRow>();

        string Str(string alias, params string[] candidates)
        {
            var match = candidates.FirstOrDefault(cols.Contains);
            return match is null
                ? $"CAST('' AS nvarchar(255)) AS [{alias}]"
                : $"ISNULL(CONVERT(nvarchar(255), [{match}]), '') AS [{alias}]";
        }
        string Money(string alias, params string[] candidates)
        {
            var match = candidates.FirstOrDefault(cols.Contains);
            return match is null
                ? $"CAST(0 AS decimal(18,2)) AS [{alias}]"
                : $"ISNULL(TRY_CONVERT(decimal(18,2), [{match}]), 0) AS [{alias}]";
        }
        string Date(string alias, params string[] candidates)
        {
            var match = candidates.FirstOrDefault(cols.Contains);
            return match is null
                ? $"CAST(NULL AS date) AS [{alias}]"
                : $"TRY_CONVERT(date, [{match}]) AS [{alias}]";
        }

        var sql = $@"
SELECT
    {Str("ClaimId", "ClaimID", "VisitNumber", "AccessionNo")},
    {Str("DenialCode", "DenialCode")},
    {Str("NormalizedDenialCodeRaw", "DenialCodeNormalized", "NormalizedDenialCode")},
    {Str("DenialDescription", "DenialDescription", "DenialDesc")},
    {Str("DenialClassification", "DenialClassification", "DenialType")},
    {Str("PayerName", "PayerName_Raw", "PayerName")},
    {Str("PayerNameNormalizedRaw", "PayerNameNormalized", "PayerName_Normalized")},
    {Date("DenialDate", "DenialDate")},
    {Str("DeniedWeek", "DeniedWeek", "DenialWeek", "Denied Week")},
    {Money("InsuranceBalance", "InsuranceBalance")},
    {Money("TotalBalance", "TotalBalance")},
    {Money("BilledAmount", "BilledAmount")},
    {Str("CptCode", "CPTCode", "CptCode")},
    {Str("PanelName", "PanelName", "PanelType", "PanelNew")},
    {Date("DateOfService", "DateOfService")}
FROM dbo.ClaimLevelData
WHERE [DenialCode] IS NOT NULL AND LTRIM(RTRIM(CONVERT(nvarchar(255), [DenialCode]))) <> '';";

        var rows = new List<DenialClaimRow>();
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 300 };
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var payerName = reader.GetString(reader.GetOrdinal("PayerName"));
            var storedNormalized = reader.GetString(reader.GetOrdinal("PayerNameNormalizedRaw"));
            var denialCode = reader.GetString(reader.GetOrdinal("DenialCode"));

            // The Master File Processor writes NormalizedDenialCode during the claim-level import,
            // and it is the better value: it handles a multi-code cell ("CO10, CO189" -> "10, 189"),
            // which the single-code fallback below cannot. The fallback keeps a lab that has not yet
            // run the new import working, rather than showing it blank codes.
            var storedDenialNormalized = reader.GetString(reader.GetOrdinal("NormalizedDenialCodeRaw"));

            rows.Add(new DenialClaimRow
            {
                ClaimId = reader.GetString(reader.GetOrdinal("ClaimId")),
                DenialCode = denialCode,
                DenialCodeNormalized = string.IsNullOrWhiteSpace(storedDenialNormalized)
                    ? DenialCodeKey.Normalize(denialCode)
                    : storedDenialNormalized,
                DenialDescription = reader.GetString(reader.GetOrdinal("DenialDescription")),
                DenialClassification = reader.GetString(reader.GetOrdinal("DenialClassification")),
                PayerName = string.IsNullOrWhiteSpace(payerName) ? storedNormalized : payerName,
                PayerNameNormalized = DenialCodeKey.NormalizePayer(
                    string.IsNullOrWhiteSpace(storedNormalized) ? payerName : storedNormalized),
                DenialDate = GetDate(reader, "DenialDate"),
                DeniedWeek = reader.GetString(reader.GetOrdinal("DeniedWeek")),
                InsuranceBalance = reader.GetDecimal(reader.GetOrdinal("InsuranceBalance")),
                TotalBalance = reader.GetDecimal(reader.GetOrdinal("TotalBalance")),
                BilledAmount = reader.GetDecimal(reader.GetOrdinal("BilledAmount")),
                CptCode = reader.GetString(reader.GetOrdinal("CptCode")),
                PanelName = reader.GetString(reader.GetOrdinal("PanelName")),
                DateOfService = GetDate(reader, "DateOfService")
            });
        }

        return rows;
    }

    /// <summary>
    /// Builds the four-step description cascade the requirements define: the lab's own
    /// Denial-Action master then the Denial-Action Super Master, each matched on the raw code
    /// before the normalized one.
    /// </summary>
    public async Task<DenialDescriptionLookup> GetDescriptionsAsync(
        string connectionString, string? masterConnectionString, CancellationToken ct)
    {
        var lookup = new DenialDescriptionLookup();

        // The lab's own Denial-Action master. Absent on a lab that has never imported a classifier,
        // which is normal - the Super Master covers it.
        try
        {
            await using var labConn = new SqlConnection(connectionString);
            await labConn.OpenAsync(ct);
            await ReadDescriptionsAsync(labConn, "DenialCodeMaster", isActiveFiltered: false,
                lookup.AddLab, ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "The lab's own DenialCodeMaster could not be read for descriptions.");
        }

        if (!string.IsNullOrWhiteSpace(masterConnectionString))
        {
            try
            {
                await using var masterConn = new SqlConnection(masterConnectionString);
                await masterConn.OpenAsync(ct);
                await ReadDescriptionsAsync(masterConn, "DenialMapperSuperMaster", isActiveFiltered: true,
                    lookup.AddSuper, ct);
            }
            catch (Exception ex)
            {
                // A master lookup outage costs descriptions, not the report.
                _logger.LogWarning(ex, "Denial descriptions could not be read from the Super Master.");
            }
        }

        return lookup;
    }

    /// <summary>
    /// Reads DenialCode/DenialDescription out of one master table, or does nothing when that table
    /// is not present. A missing master is an expected state, not an error.
    /// </summary>
    private static async Task ReadDescriptionsAsync(
        SqlConnection conn, string table, bool isActiveFiltered,
        Action<string, string> add, CancellationToken ct)
    {
        if (!await TableExistsAsync(conn, table, ct)) return;

        // IsActive exists on the Super Master but not on every lab's DenialCodeMaster, so the filter
        // is only applied where the caller knows the column is there.
        var activeFilter = isActiveFiltered ? "AND IsActive = 1" : string.Empty;

        var sql = $@"
SELECT DenialCode, DenialDescription
FROM dbo.[{table}]
WHERE DenialCode IS NOT NULL AND LTRIM(RTRIM(DenialCode)) <> ''
  AND DenialDescription IS NOT NULL AND LTRIM(RTRIM(DenialDescription)) <> ''
  {activeFilter};";

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            if (reader.IsDBNull(0) || reader.IsDBNull(1)) continue;
            add(reader.GetString(0), reader.GetString(1));
        }
    }

    /// <summary>
    /// The insight rows on one tab. <paramref name="bucket"/> is Current, Previous or Archive -
    /// see <see cref="DenialInsightBuckets"/>.
    /// </summary>
    public async Task<IReadOnlyList<DenialInsightClaimLevelRow>> GetInsightsAsync(
        string connectionString, string bucket, CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await EnsureInsightTableAsync(conn, ct);

        const string sql = @"
SELECT Id, Bucket, WeekStart, DenialCode, DenialDescription, PayerName, NoOfDenials, NoOfClaims,
       TotalBalance, InsuranceBalance, ImpactPercentage, Observation, ActionCategory, Action,
       FeedbackResponse, Responsibility, DiscussionDate, ETA, ClosedDate, UpdatedOn, UpdatedBy
FROM dbo.DenialInsightClaimLevel
WHERE Bucket = @Bucket
ORDER BY WeekStart DESC, InsuranceBalance DESC, DenialCode;";

        var rows = new List<DenialInsightClaimLevelRow>();
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        cmd.Parameters.Add("@Bucket", SqlDbType.NVarChar, 20).Value = DenialInsightBuckets.Normalize(bucket);

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var code = Text(reader, "DenialCode");
            rows.Add(new DenialInsightClaimLevelRow
            {
                Id = reader.GetInt64(reader.GetOrdinal("Id")),
                Bucket = Text(reader, "Bucket"),
                WeekStart = GetDate(reader, "WeekStart") ?? default,
                DenialCode = code,
                DenialCodeNormalized = DenialCodeKey.Normalize(code),
                DenialDescription = Text(reader, "DenialDescription"),
                PayerName = Text(reader, "PayerName"),
                NoOfDenials = GetIntOrZero(reader, "NoOfDenials"),
                NoOfClaims = GetIntOrZero(reader, "NoOfClaims"),
                TotalBalance = GetDecimalOrZero(reader, "TotalBalance"),
                InsuranceBalance = GetDecimalOrZero(reader, "InsuranceBalance"),
                ImpactPercentage = GetDecimalOrZero(reader, "ImpactPercentage"),
                // Sanitized again on read: a row written directly in SQL must not reach a browser raw.
                ObservationHtml = DenialInsightRichText.Sanitize(Text(reader, "Observation")),
                ActionCategory = Text(reader, "ActionCategory"),
                ActionHtml = DenialInsightRichText.Sanitize(Text(reader, "Action")),
                FeedbackResponse = Text(reader, "FeedbackResponse"),
                Responsibility = Text(reader, "Responsibility"),
                DiscussionDate = GetDate(reader, "DiscussionDate"),
                Eta = GetDate(reader, "ETA"),
                ClosedDate = GetDate(reader, "ClosedDate"),
                UpdatedOn = GetDate(reader, "UpdatedOn"),
                UpdatedBy = Text(reader, "UpdatedBy")
            });
        }

        return rows;
    }

    public async Task<DenialInsightUploadResult> SaveInsightsAsync(string connectionString, IReadOnlyList<DenialInsightClaimLevelRow> rows, string userName, CancellationToken ct)
    {
        var result = new DenialInsightUploadResult();
        if (rows.Count == 0) return result;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await EnsureInsightTableAsync(conn, ct);

        // Upsert on (Bucket, WeekStart, DenialCode, PayerName): re-uploading the same workbook for
        // the same week updates those rows in place rather than stacking a second copy of the file's
        // contents, while a different week is a genuinely separate set of insights.
        const string sql = @"
UPDATE dbo.DenialInsightClaimLevel
SET DenialDescription = @DenialDescription,
    NoOfDenials = @NoOfDenials,
    NoOfClaims = @NoOfClaims,
    TotalBalance = @TotalBalance,
    InsuranceBalance = @InsuranceBalance,
    ImpactPercentage = @ImpactPercentage,
    Observation = @Observation,
    ActionCategory = @ActionCategory,
    Action = @Action,
    FeedbackResponse = @FeedbackResponse,
    Responsibility = @Responsibility,
    DiscussionDate = @DiscussionDate,
    ETA = @Eta,
    ClosedDate = @ClosedDate,
    UpdatedOn = SYSUTCDATETIME(),
    UpdatedBy = @UpdatedBy
WHERE Bucket = @Bucket AND WeekStart = @WeekStart
  AND DenialCode = @DenialCode AND ISNULL(PayerName, '') = ISNULL(@PayerName, '');

IF @@ROWCOUNT = 0
BEGIN
    INSERT dbo.DenialInsightClaimLevel
        (Bucket, WeekStart, DenialCode, DenialDescription, PayerName, NoOfDenials, NoOfClaims,
         TotalBalance, InsuranceBalance, ImpactPercentage, Observation, ActionCategory, Action,
         FeedbackResponse, Responsibility, DiscussionDate, ETA, ClosedDate, UpdatedOn, UpdatedBy)
    VALUES
        (@Bucket, @WeekStart, @DenialCode, @DenialDescription, @PayerName, @NoOfDenials, @NoOfClaims,
         @TotalBalance, @InsuranceBalance, @ImpactPercentage, @Observation, @ActionCategory, @Action,
         @FeedbackResponse, @Responsibility, @DiscussionDate, @Eta, @ClosedDate, SYSUTCDATETIME(), @UpdatedBy);
    SELECT CAST(1 AS bit);
END
ELSE
    SELECT CAST(0 AS bit);";

        foreach (var row in rows)
        {
            if (string.IsNullOrWhiteSpace(row.DenialCode)) { result.Skipped++; continue; }

            try
            {
                await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
                cmd.Parameters.Add("@Bucket", SqlDbType.NVarChar, 20).Value = DenialInsightBuckets.Normalize(row.Bucket);
                cmd.Parameters.Add("@WeekStart", SqlDbType.Date).Value = row.WeekStart.Date;
                cmd.Parameters.Add("@DenialCode", SqlDbType.NVarChar, 100).Value = row.DenialCode.Trim();
                cmd.Parameters.Add("@DenialDescription", SqlDbType.NVarChar, 1000).Value = Db(row.DenialDescription);
                cmd.Parameters.Add("@PayerName", SqlDbType.NVarChar, 255).Value = Db(row.PayerName);
                cmd.Parameters.Add("@NoOfDenials", SqlDbType.Int).Value = row.NoOfDenials;
                cmd.Parameters.Add("@NoOfClaims", SqlDbType.Int).Value = row.NoOfClaims;
                cmd.Parameters.Add("@TotalBalance", SqlDbType.Decimal).Value = row.TotalBalance;
                cmd.Parameters.Add("@InsuranceBalance", SqlDbType.Decimal).Value = row.InsuranceBalance;
                cmd.Parameters.Add("@ImpactPercentage", SqlDbType.Decimal).Value = row.ImpactPercentage;
                cmd.Parameters.Add("@Observation", SqlDbType.NVarChar, -1).Value = Db(row.ObservationHtml);
                cmd.Parameters.Add("@ActionCategory", SqlDbType.NVarChar, 500).Value = Db(row.ActionCategory);
                cmd.Parameters.Add("@Action", SqlDbType.NVarChar, -1).Value = Db(row.ActionHtml);
                cmd.Parameters.Add("@FeedbackResponse", SqlDbType.NVarChar, -1).Value = Db(row.FeedbackResponse);
                cmd.Parameters.Add("@Responsibility", SqlDbType.NVarChar, 255).Value = Db(row.Responsibility);
                cmd.Parameters.Add("@DiscussionDate", SqlDbType.Date).Value = (object?)row.DiscussionDate?.Date ?? DBNull.Value;
                cmd.Parameters.Add("@Eta", SqlDbType.Date).Value = (object?)row.Eta?.Date ?? DBNull.Value;
                cmd.Parameters.Add("@ClosedDate", SqlDbType.Date).Value = (object?)row.ClosedDate?.Date ?? DBNull.Value;
                cmd.Parameters.Add("@UpdatedBy", SqlDbType.NVarChar, 200).Value = Db(userName);

                var inserted = Convert.ToBoolean(await cmd.ExecuteScalarAsync(ct));
                if (inserted) result.Inserted++; else result.Updated++;
            }
            catch (SqlException ex)
            {
                _logger.LogError(ex, "Denial insight row {Code}/{Payer} could not be saved.", row.DenialCode, row.PayerName);
                result.Errors.Add($"{row.DenialCode}: {ex.Message}");
            }
        }

        return result;
    }

    /// <summary>
    /// Copies the Current Week insights into Previous Week, then rolls anything in Previous older
    /// than the retention window into Archive.
    /// </summary>
    /// <remarks>
    /// <para>A COPY, not a move: the Current Week rows stay exactly where they are. The button is
    /// named "Copy Data to Previous Week" and the user is still working on that week, so removing
    /// what they are looking at would be the wrong reading of it. Re-clicking is therefore safe -
    /// the copy upserts onto the same (Previous, WeekStart, code, payer) rows.</para>
    /// <para>All of it runs in one transaction, so a failure part way through cannot leave rows
    /// copied but not archived.</para>
    /// </remarks>
    public async Task<DenialInsightCopyResult> CopyCurrentToPreviousAsync(
        string connectionString, string userName, CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await EnsureInsightTableAsync(conn, ct);

        // Anything whose week is older than this has left the "latest 4 weeks" window.
        var archiveBefore = WeekStartOf(DateTime.Today).AddDays(-7 * DenialInsightBuckets.PreviousWeeksRetained);

        const string sql = @"
UPDATE p
SET    p.DenialDescription = c.DenialDescription,
       p.NoOfDenials = c.NoOfDenials, p.NoOfClaims = c.NoOfClaims,
       p.TotalBalance = c.TotalBalance, p.InsuranceBalance = c.InsuranceBalance,
       p.ImpactPercentage = c.ImpactPercentage,
       p.Observation = c.Observation, p.ActionCategory = c.ActionCategory, p.Action = c.Action,
       p.FeedbackResponse = c.FeedbackResponse, p.Responsibility = c.Responsibility,
       p.DiscussionDate = c.DiscussionDate, p.ETA = c.ETA, p.ClosedDate = c.ClosedDate,
       p.UpdatedOn = SYSUTCDATETIME(), p.UpdatedBy = @UpdatedBy
FROM   dbo.DenialInsightClaimLevel AS p
JOIN   dbo.DenialInsightClaimLevel AS c
       ON  c.Bucket = 'Current'
       AND c.WeekStart = p.WeekStart
       AND c.DenialCode = p.DenialCode
       AND ISNULL(c.PayerName, '') = ISNULL(p.PayerName, '')
WHERE  p.Bucket = 'Previous';

SELECT @@ROWCOUNT;

INSERT dbo.DenialInsightClaimLevel
    (Bucket, WeekStart, DenialCode, DenialDescription, PayerName, NoOfDenials, NoOfClaims,
     TotalBalance, InsuranceBalance, ImpactPercentage, Observation, ActionCategory, Action,
     FeedbackResponse, Responsibility, DiscussionDate, ETA, ClosedDate, UpdatedOn, UpdatedBy)
SELECT 'Previous', c.WeekStart, c.DenialCode, c.DenialDescription, c.PayerName, c.NoOfDenials,
       c.NoOfClaims, c.TotalBalance, c.InsuranceBalance, c.ImpactPercentage, c.Observation,
       c.ActionCategory, c.Action, c.FeedbackResponse, c.Responsibility, c.DiscussionDate,
       c.ETA, c.ClosedDate, SYSUTCDATETIME(), @UpdatedBy
FROM   dbo.DenialInsightClaimLevel AS c
WHERE  c.Bucket = 'Current'
  AND  NOT EXISTS (
           SELECT 1 FROM dbo.DenialInsightClaimLevel AS p
           WHERE p.Bucket = 'Previous' AND p.WeekStart = c.WeekStart
             AND p.DenialCode = c.DenialCode
             AND ISNULL(p.PayerName, '') = ISNULL(c.PayerName, ''));

SELECT @@ROWCOUNT;

-- Past the retention window: Previous keeps the latest 4 weeks, the rest becomes Archive.
-- A row already in Archive for that week would collide on the unique index, so it is removed
-- rather than duplicated - Archive holds one copy of each week, which is what it is for.
DELETE a
FROM   dbo.DenialInsightClaimLevel AS a
JOIN   dbo.DenialInsightClaimLevel AS p
       ON  p.Bucket = 'Previous' AND p.WeekStart < @ArchiveBefore
       AND p.WeekStart = a.WeekStart AND p.DenialCode = a.DenialCode
       AND ISNULL(p.PayerName, '') = ISNULL(a.PayerName, '')
WHERE  a.Bucket = 'Archive';

UPDATE dbo.DenialInsightClaimLevel
SET    Bucket = 'Archive', UpdatedOn = SYSUTCDATETIME(), UpdatedBy = @UpdatedBy
WHERE  Bucket = 'Previous' AND WeekStart < @ArchiveBefore;

SELECT @@ROWCOUNT;";

        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(ct);
        try
        {
            await using var cmd = new SqlCommand(sql, conn, tx) { CommandTimeout = 300 };
            cmd.Parameters.Add("@UpdatedBy", SqlDbType.NVarChar, 200).Value = Db(userName);
            cmd.Parameters.Add("@ArchiveBefore", SqlDbType.Date).Value = archiveBefore;

            await using var reader = await cmd.ExecuteReaderAsync(ct);

            var updated = await ReadCountAsync(reader, ct);
            await reader.NextResultAsync(ct);
            var inserted = await ReadCountAsync(reader, ct);
            await reader.NextResultAsync(ct);
            var archived = await ReadCountAsync(reader, ct);

            await reader.CloseAsync();
            await tx.CommitAsync(ct);

            return new DenialInsightCopyResult { Inserted = inserted, Updated = updated, Archived = archived };
        }
        catch
        {
            await tx.RollbackAsync(CancellationToken.None);
            throw;
        }
    }

    private static async Task<int> ReadCountAsync(SqlDataReader reader, CancellationToken ct) =>
        await reader.ReadAsync(ct) && !reader.IsDBNull(0) ? reader.GetInt32(0) : 0;

    /// <summary>Monday of the week the date falls in - the week identity insights are stamped with.</summary>
    public static DateTime WeekStartOf(DateTime date)
    {
        var d = date.Date;
        return d.AddDays(-(((int)d.DayOfWeek + 6) % 7));
    }

    private static async Task EnsureInsightTableAsync(SqlConnection conn, CancellationToken ct)
    {
        const string sql = """
            IF OBJECT_ID('dbo.DenialInsightClaimLevel', 'U') IS NULL
            BEGIN
                CREATE TABLE dbo.DenialInsightClaimLevel
                (
                    Id                BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialInsightClaimLevel PRIMARY KEY,
                    Bucket            NVARCHAR(20)   NOT NULL CONSTRAINT DF_DICL_Bucket DEFAULT 'Current',
                    WeekStart         DATE           NOT NULL CONSTRAINT DF_DICL_WeekStart DEFAULT CAST(SYSUTCDATETIME() AS date),
                    DenialCode        NVARCHAR(100)  NOT NULL,
                    DenialDescription NVARCHAR(1000) NULL,
                    PayerName         NVARCHAR(255)  NULL,
                    NoOfDenials       INT            NOT NULL CONSTRAINT DF_DICL_NoOfDenials DEFAULT 0,
                    NoOfClaims        INT            NOT NULL CONSTRAINT DF_DICL_NoOfClaims DEFAULT 0,
                    TotalBalance      DECIMAL(18,2)  NOT NULL CONSTRAINT DF_DICL_TotalBalance DEFAULT 0,
                    InsuranceBalance  DECIMAL(18,2)  NOT NULL CONSTRAINT DF_DICL_InsuranceBalance DEFAULT 0,
                    ImpactPercentage  DECIMAL(18,2)  NOT NULL CONSTRAINT DF_DICL_ImpactPercentage DEFAULT 0,
                    Observation       NVARCHAR(MAX)  NULL,
                    ActionCategory    NVARCHAR(500)  NULL,
                    Action            NVARCHAR(MAX)  NULL,
                    FeedbackResponse  NVARCHAR(MAX)  NULL,
                    Responsibility    NVARCHAR(255)  NULL,
                    DiscussionDate    DATE           NULL,
                    ETA               DATE           NULL,
                    ClosedDate        DATE           NULL,
                    UpdatedOn         DATETIME2(3)   NULL,
                    UpdatedBy         NVARCHAR(200)  NULL
                );
            END

            -- A lab that took the first version of this table has neither column yet. Added rather
            -- than recreated, so any insights it already holds survive - they become Current Week
            -- of the week they were imported in, which is where they were being shown anyway.
            IF COL_LENGTH('dbo.DenialInsightClaimLevel', 'Bucket') IS NULL
                ALTER TABLE dbo.DenialInsightClaimLevel
                    ADD Bucket NVARCHAR(20) NOT NULL CONSTRAINT DF_DICL_Bucket DEFAULT 'Current';

            IF COL_LENGTH('dbo.DenialInsightClaimLevel', 'WeekStart') IS NULL
                ALTER TABLE dbo.DenialInsightClaimLevel
                    ADD WeekStart DATE NOT NULL CONSTRAINT DF_DICL_WeekStart DEFAULT CAST(SYSUTCDATETIME() AS date);

            -- The old index keyed on (DenialCode, PayerName) alone, which would now reject the same
            -- denial appearing in two different weeks. Replaced, not dropped: the tab and the week
            -- are part of a row's identity.
            IF EXISTS (SELECT 1 FROM sys.indexes
                       WHERE object_id = OBJECT_ID('dbo.DenialInsightClaimLevel')
                         AND name = 'UX_DenialInsightClaimLevel_Code_Payer')
                DROP INDEX UX_DenialInsightClaimLevel_Code_Payer ON dbo.DenialInsightClaimLevel;

            IF NOT EXISTS (SELECT 1 FROM sys.indexes
                           WHERE object_id = OBJECT_ID('dbo.DenialInsightClaimLevel')
                             AND name = 'UX_DenialInsightClaimLevel_Bucket_Week_Code_Payer')
                CREATE UNIQUE INDEX UX_DenialInsightClaimLevel_Bucket_Week_Code_Payer
                    ON dbo.DenialInsightClaimLevel (Bucket, WeekStart, DenialCode, PayerName);
            """;

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static async Task<bool> TableExistsAsync(SqlConnection conn, string table, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("SELECT CASE WHEN OBJECT_ID('dbo.' + @Table, 'U') IS NULL THEN 0 ELSE 1 END", conn);
        cmd.Parameters.AddWithValue("@Table", table);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) == 1;
    }

    private static async Task<HashSet<string>> GetColumnsAsync(SqlConnection conn, string table, CancellationToken ct)
    {
        var cols = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        await using var cmd = new SqlCommand(
            "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = @Table", conn);
        cmd.Parameters.AddWithValue("@Table", table);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) cols.Add(reader.GetString(0));
        return cols;
    }

    private static object Db(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();
    private static string Text(SqlDataReader r, string name) { var i = r.GetOrdinal(name); return r.IsDBNull(i) ? string.Empty : r.GetValue(i)?.ToString() ?? string.Empty; }
    private static DateTime? GetDate(SqlDataReader r, string name) { var i = r.GetOrdinal(name); return r.IsDBNull(i) ? null : r.GetDateTime(i); }
    private static int GetIntOrZero(SqlDataReader r, string name) { var i = r.GetOrdinal(name); return r.IsDBNull(i) ? 0 : Convert.ToInt32(r.GetValue(i)); }
    private static decimal GetDecimalOrZero(SqlDataReader r, string name) { var i = r.GetOrdinal(name); return r.IsDBNull(i) ? 0m : Convert.ToDecimal(r.GetValue(i)); }
}
