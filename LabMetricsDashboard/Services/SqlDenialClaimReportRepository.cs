using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

public interface IDenialClaimReportRepository
{
    /// <summary>
    /// The aggregated denial groups the Monthly and Weekly summaries are built from, straight out
    /// of the lab's own dbo.ClaimLevelData.
    /// </summary>
    Task<IReadOnlyList<DenialSummaryGroup>> GetDenialSummaryAsync(string connectionString, CancellationToken ct);

    /// <summary>The insight rows on one tab - Current or Previous.</summary>
    Task<IReadOnlyList<DenialInsightRow>> GetInsightsAsync(string connectionString, string bucket, CancellationToken ct);

    /// <summary>Row counts per tab, without loading the rows.</summary>
    Task<IReadOnlyDictionary<string, int>> GetInsightCountsAsync(string connectionString, CancellationToken ct);

    /// <summary>Upsert by (Bucket, WeekStart, DenialCode, PayerName) - a template row's identity.</summary>
    Task<DenialInsightUploadResult> SaveInsightsAsync(string connectionString, IReadOnlyList<DenialInsightRow> rows, string userName, CancellationToken ct);

    /// <summary>Deletes one insight row by its id. Returns false when the row was already gone.</summary>
    Task<bool> DeleteInsightAsync(string connectionString, long id, CancellationToken ct);

    /// <summary>Replaces a whole tab's rows - used by an import, which is a full replace of that week.</summary>
    Task<int> ClearBucketAsync(string connectionString, string bucket, CancellationToken ct);

    /// <summary>Copies Current Week onto Previous Week, replacing whatever Previous held.</summary>
    Task<int> CopyCurrentToPreviousAsync(string connectionString, string userName, CancellationToken ct);

    /// <summary>
    /// Rolls the existing Current Week into Previous Week and archives anything beyond the retained
    /// weeks. Used by an import that is NOT replacing the current week.
    /// </summary>
    Task<DenialInsightRollResult> RollCurrentToPreviousAsync(string connectionString, string userName, CancellationToken ct);
}

/// <summary>What an import's roll-forward moved, reported back on the page.</summary>
public sealed record DenialInsightRollResult(int RolledToPrevious, int Archived);

/// <summary>
/// Denial Claim Report data access, straight against each lab's own database.
///
/// <para>Reads <c>dbo.ClaimLevelData</c> for the denial summaries, and owns
/// <c>dbo.DenialClaimLevelInsight</c>, the per-lab table holding the insight rows a client imports
/// and edits. The two stay distinct by design: importing insights never writes to, or recalculates,
/// claim-level data.</para>
///
/// <para>Column selection is probed rather than assumed - lab databases differ in which optional
/// ClaimLevelData columns they carry, so a lab missing one gets a blank for it instead of a failed
/// query.</para>
/// </summary>
public sealed class SqlDenialClaimReportRepository : IDenialClaimReportRepository
{
    private readonly ILogger<SqlDenialClaimReportRepository> _logger;

    public SqlDenialClaimReportRepository(ILogger<SqlDenialClaimReportRepository> logger) => _logger = logger;

    // ── Denial summary ────────────────────────────────────────────────────────

    public async Task<IReadOnlyList<DenialSummaryGroup>> GetDenialSummaryAsync(string connectionString, CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        if (!await TableExistsAsync(conn, "ClaimLevelData", ct)) return Array.Empty<DenialSummaryGroup>();

        var cols = await GetColumnsAsync(conn, "ClaimLevelData", ct);
        if (!cols.Contains("DenialCode")) return Array.Empty<DenialSummaryGroup>();

        // PayerName_Raw is the payer as the lab billed it, and it is the column the requirements
        // name for the Top Insurance rows. PayerName is the mapped/cleaned variant and is only a
        // fallback, for a lab whose claim-level table does not carry the raw one.
        var payerCol = FirstPresent(cols, "PayerName_Raw", "PayerName") ?? "DenialCode";
        var claimIdCol = FirstPresent(cols, "ClaimID", "ClaimId", "VisitNumber", "AccessionNo");

        // A lab that has not yet run the new claim-level import has neither derived column. The
        // summary still works - it falls back to the raw code and an empty description - rather than
        // showing the lab an error it cannot act on.
        var normalizedExpr = cols.Contains("DenialCodeNormalized")
            ? "LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(400), [DenialCodeNormalized]), '')))"
            : "LTRIM(RTRIM(CONVERT(nvarchar(400), [DenialCode])))";

        var descriptionExpr = cols.Contains("DenialDescription")
            ? "ISNULL(CONVERT(nvarchar(4000), [DenialDescription]), '')"
            : "CAST('' AS nvarchar(4000))";

        // COUNT(DISTINCT ClaimId) needs a claim identifier. Without one, every row is its own claim -
        // which is what COUNT(*) says, and is the honest answer for a table with no claim key.
        var claimCountExpr = claimIdCol is null
            ? "COUNT_BIG(1)"
            : $"COUNT(DISTINCT CONVERT(nvarchar(255), [{claimIdCol}]))";

        // TRY_CONVERT rather than CAST: a lab whose InsuranceBalance is stored as text with a
        // currency symbol would fail the whole query on CAST. TRY_CONVERT yields NULL, and NULL is
        // excluded by "> 0" - the same rows are kept, without the query ever erroring.
        var sql = $@"
SELECT  LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(255), [{payerCol}]), ''))) AS PayerName,
        {normalizedExpr}                                              AS DenialCodeNormalized,
        {descriptionExpr}                                             AS DenialDescription,
        TRY_CONVERT(date, [DenialDate])                               AS DenialDate,
        {claimCountExpr}                                              AS ClaimCount,
        SUM(TRY_CONVERT(decimal(18,2), [InsuranceBalance]))           AS InsuranceBalance
FROM    dbo.ClaimLevelData
WHERE   [DenialCode] IS NOT NULL
  AND   LTRIM(RTRIM(CONVERT(nvarchar(255), [DenialCode]))) <> ''
  AND   TRY_CONVERT(decimal(18,2), [InsuranceBalance]) > 0
GROUP BY LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(255), [{payerCol}]), ''))),
        {normalizedExpr},
        {descriptionExpr},
        TRY_CONVERT(date, [DenialDate]);";

        var rows = new List<DenialSummaryGroup>();
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 300 };
        await using var reader = await cmd.ExecuteReaderAsync(ct);

        while (await reader.ReadAsync(ct))
        {
            rows.Add(new DenialSummaryGroup
            {
                PayerName = reader.GetString(0),
                DenialCodeNormalized = reader.GetString(1),
                DenialDescription = reader.GetString(2),
                DenialDate = reader.IsDBNull(3) ? null : reader.GetDateTime(3),
                ClaimCount = reader.IsDBNull(4) ? 0 : Convert.ToInt32(reader.GetValue(4)),
                InsuranceBalance = reader.IsDBNull(5) ? 0m : reader.GetDecimal(5)
            });
        }

        return rows;
    }

    // ── Denial insights ───────────────────────────────────────────────────────

    private const string InsightTable = "dbo.DenialClaimLevelInsight";

    public async Task<IReadOnlyList<DenialInsightRow>> GetInsightsAsync(
        string connectionString, string bucket, CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await EnsureInsightTableAsync(conn, ct);

        var sql = $@"
SELECT Id, Bucket, WeekStart, SortOrder, DenialCode, DenialDescription, PayerName, NoOfDenials,
       TotalBalance, InsuranceBalance, ImpactPercentage, Observation, ActionCategory, Action,
       FeedbackResponse, Responsibility, DiscussionDate, ETA, ClosedDate, UpdatedOn, UpdatedBy
FROM {InsightTable}
WHERE Bucket = @Bucket
-- Newest week first, then the client's own ranking within the week. Previous Week draws a
-- separator each time WeekStart changes, so the rows have to arrive already grouped by week.
ORDER BY WeekStart DESC, SortOrder, InsuranceBalance DESC, DenialCode;";

        var rows = new List<DenialInsightRow>();
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        cmd.Parameters.Add("@Bucket", SqlDbType.NVarChar, 20).Value = DenialInsightBuckets.Normalize(bucket);

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var code = Text(reader, "DenialCode");
            rows.Add(new DenialInsightRow
            {
                Id = reader.GetInt64(reader.GetOrdinal("Id")),
                Bucket = Text(reader, "Bucket"),
                WeekStart = GetDate(reader, "WeekStart") ?? default,
                SortOrder = GetIntOrZero(reader, "SortOrder"),
                DenialCode = code,
                DenialCodeNormalized = DenialCodeKey.Normalize(code),
                DenialDescription = Text(reader, "DenialDescription"),
                PayerName = Text(reader, "PayerName"),
                NoOfDenials = GetIntOrZero(reader, "NoOfDenials"),
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

    public async Task<IReadOnlyDictionary<string, int>> GetInsightCountsAsync(string connectionString, CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await EnsureInsightTableAsync(conn, ct);

        var counts = new Dictionary<string, int>(StringComparer.Ordinal)
        {
            [DenialInsightBuckets.Current] = 0,
            [DenialInsightBuckets.Previous] = 0
        };

        var sql = $"SELECT Bucket, COUNT(1) FROM {InsightTable} GROUP BY Bucket;";

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            var bucket = reader.IsDBNull(0) ? DenialInsightBuckets.Current : reader.GetString(0);
            counts[bucket] = reader.GetInt32(1);
        }

        return counts;
    }

    public async Task<DenialInsightUploadResult> SaveInsightsAsync(
        string connectionString, IReadOnlyList<DenialInsightRow> rows, string userName, CancellationToken ct)
    {
        var result = new DenialInsightUploadResult();
        if (rows.Count == 0) return result;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await EnsureInsightTableAsync(conn, ct);

        // An edit carries the row's Id and updates that row. An import carries no Id and upserts on
        // (Bucket, WeekStart, DenialCode, PayerName), so re-importing the same workbook refreshes
        // those rows rather than stacking a second copy of the file.
        var sql = $@"
IF @Id > 0
BEGIN
    UPDATE {InsightTable}
    SET SortOrder = @SortOrder, DenialCode = @DenialCode, DenialDescription = @DenialDescription,
        PayerName = @PayerName, NoOfDenials = @NoOfDenials, TotalBalance = @TotalBalance,
        InsuranceBalance = @InsuranceBalance, ImpactPercentage = @ImpactPercentage,
        Observation = @Observation, ActionCategory = @ActionCategory, Action = @Action,
        FeedbackResponse = @FeedbackResponse, Responsibility = @Responsibility,
        DiscussionDate = @DiscussionDate, ETA = @Eta, ClosedDate = @ClosedDate,
        UpdatedOn = SYSUTCDATETIME(), UpdatedBy = @UpdatedBy
    WHERE Id = @Id;

    SELECT CAST(0 AS bit);
END
ELSE
BEGIN
    UPDATE {InsightTable}
    SET SortOrder = @SortOrder, DenialDescription = @DenialDescription,
        NoOfDenials = @NoOfDenials, TotalBalance = @TotalBalance,
        InsuranceBalance = @InsuranceBalance, ImpactPercentage = @ImpactPercentage,
        Observation = @Observation, ActionCategory = @ActionCategory, Action = @Action,
        FeedbackResponse = @FeedbackResponse, Responsibility = @Responsibility,
        DiscussionDate = @DiscussionDate, ETA = @Eta, ClosedDate = @ClosedDate,
        UpdatedOn = SYSUTCDATETIME(), UpdatedBy = @UpdatedBy
    WHERE Bucket = @Bucket AND WeekStart = @WeekStart
      AND DenialCode = @DenialCode AND ISNULL(PayerName, '') = ISNULL(@PayerName, '');

    IF @@ROWCOUNT = 0
    BEGIN
        INSERT {InsightTable}
            (Bucket, WeekStart, SortOrder, DenialCode, DenialDescription, PayerName, NoOfDenials,
             TotalBalance, InsuranceBalance, ImpactPercentage, Observation, ActionCategory, Action,
             FeedbackResponse, Responsibility, DiscussionDate, ETA, ClosedDate, UpdatedOn, UpdatedBy)
        VALUES
            (@Bucket, @WeekStart, @SortOrder, @DenialCode, @DenialDescription, @PayerName, @NoOfDenials,
             @TotalBalance, @InsuranceBalance, @ImpactPercentage, @Observation, @ActionCategory, @Action,
             @FeedbackResponse, @Responsibility, @DiscussionDate, @Eta, @ClosedDate, SYSUTCDATETIME(), @UpdatedBy);
        SELECT CAST(1 AS bit);
    END
    ELSE
        SELECT CAST(0 AS bit);
END";

        foreach (var row in rows)
        {
            if (string.IsNullOrWhiteSpace(row.DenialCode)) { result.Skipped++; continue; }

            try
            {
                await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
                cmd.Parameters.Add("@Id", SqlDbType.BigInt).Value = row.Id;
                cmd.Parameters.Add("@Bucket", SqlDbType.NVarChar, 20).Value = DenialInsightBuckets.Normalize(row.Bucket);
                cmd.Parameters.Add("@WeekStart", SqlDbType.Date).Value = row.WeekStart.Date;
                cmd.Parameters.Add("@SortOrder", SqlDbType.Int).Value = row.SortOrder;
                cmd.Parameters.Add("@DenialCode", SqlDbType.NVarChar, 100).Value = row.DenialCode.Trim();
                cmd.Parameters.Add("@DenialDescription", SqlDbType.NVarChar, 1000).Value = Db(row.DenialDescription);
                cmd.Parameters.Add("@PayerName", SqlDbType.NVarChar, 255).Value = Db(row.PayerName);
                cmd.Parameters.Add("@NoOfDenials", SqlDbType.Int).Value = row.NoOfDenials;
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

    public async Task<bool> DeleteInsightAsync(string connectionString, long id, CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await EnsureInsightTableAsync(conn, ct);

        await using var cmd = new SqlCommand($"DELETE FROM {InsightTable} WHERE Id = @Id;", conn) { CommandTimeout = 60 };
        cmd.Parameters.Add("@Id", SqlDbType.BigInt).Value = id;

        return await cmd.ExecuteNonQueryAsync(ct) > 0;
    }

    public async Task<int> ClearBucketAsync(string connectionString, string bucket, CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await EnsureInsightTableAsync(conn, ct);

        await using var cmd = new SqlCommand($"DELETE FROM {InsightTable} WHERE Bucket = @Bucket;", conn) { CommandTimeout = 120 };
        cmd.Parameters.Add("@Bucket", SqlDbType.NVarChar, 20).Value = DenialInsightBuckets.Normalize(bucket);

        return await cmd.ExecuteNonQueryAsync(ct);
    }

    /// <summary>
    /// Replaces Previous Week with a copy of Current Week.
    /// </summary>
    /// <remarks>
    /// Previous Week is cleared first, so it always holds exactly one week - the last one discussed -
    /// rather than accumulating. Current Week is left in place: the button copies, and the user is
    /// still working on that week. All of it runs in one transaction, so a failure part way cannot
    /// leave Previous emptied but not refilled.
    /// </remarks>
    public async Task<int> CopyCurrentToPreviousAsync(string connectionString, string userName, CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await EnsureInsightTableAsync(conn, ct);

        var sql = $@"
DELETE FROM {InsightTable} WHERE Bucket = 'Previous';

INSERT {InsightTable}
    (Bucket, WeekStart, SortOrder, DenialCode, DenialDescription, PayerName, NoOfDenials,
     TotalBalance, InsuranceBalance, ImpactPercentage, Observation, ActionCategory, Action,
     FeedbackResponse, Responsibility, DiscussionDate, ETA, ClosedDate, UpdatedOn, UpdatedBy)
SELECT 'Previous', WeekStart, SortOrder, DenialCode, DenialDescription, PayerName, NoOfDenials,
       TotalBalance, InsuranceBalance, ImpactPercentage, Observation, ActionCategory, Action,
       FeedbackResponse, Responsibility, DiscussionDate, ETA, ClosedDate, SYSUTCDATETIME(), @UpdatedBy
FROM   {InsightTable}
WHERE  Bucket = 'Current';

SELECT @@ROWCOUNT;";

        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(ct);
        try
        {
            await using var cmd = new SqlCommand(sql, conn, tx) { CommandTimeout = 300 };
            cmd.Parameters.Add("@UpdatedBy", SqlDbType.NVarChar, 200).Value = Db(userName);

            var copied = Convert.ToInt32(await cmd.ExecuteScalarAsync(ct) ?? 0);
            await tx.CommitAsync(ct);
            return copied;
        }
        catch
        {
            await tx.RollbackAsync(CancellationToken.None);
            throw;
        }
    }

    /// <summary>
    /// Moves the existing Current Week rows into Previous Week, then pushes anything past the
    /// retained window out to Archive. Run immediately before an import that is NOT replacing the
    /// current week, so the incoming workbook lands on an empty Current Week.
    /// </summary>
    /// <remarks>
    /// <para>Retention counts DISTINCT WEEKS, not days: the four most recent weeks present in
    /// Previous stay, everything older is archived. Counting weeks rather than measuring back from
    /// today means a lab that skips a week still keeps four real weeks of history instead of
    /// silently losing one to the calendar.</para>
    /// <para>Archived rows are kept, never deleted - a client's written observation is work, and
    /// falling out of the working view is not a reason to destroy it.</para>
    /// <para>One transaction: a failure part way cannot leave Current emptied but Previous not
    /// filled, which would lose a week of insights outright.</para>
    /// </remarks>
    public async Task<DenialInsightRollResult> RollCurrentToPreviousAsync(
        string connectionString, string userName, CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await EnsureInsightTableAsync(conn, ct);

        var sql = $@"
-- A week already sitting in Previous would collide with the incoming one on the unique index.
-- The newer Current row is the one being kept, so the stale duplicate goes first.
DELETE p
FROM   {InsightTable} AS p
JOIN   {InsightTable} AS c
       ON  c.Bucket = 'Current'
       AND c.WeekStart = p.WeekStart
       AND c.DenialCode = p.DenialCode
       AND ISNULL(c.PayerName, '') = ISNULL(p.PayerName, '')
WHERE  p.Bucket = 'Previous';

UPDATE {InsightTable}
SET    Bucket = 'Previous', UpdatedOn = SYSUTCDATETIME(), UpdatedBy = @UpdatedBy
WHERE  Bucket = 'Current';

SELECT @@ROWCOUNT;

-- Everything except the @Retain most recent weeks now in Previous.
UPDATE {InsightTable}
SET    Bucket = 'Archive', UpdatedOn = SYSUTCDATETIME(), UpdatedBy = @UpdatedBy
WHERE  Bucket = 'Previous'
  AND  WeekStart NOT IN (
           SELECT TOP (@Retain) WeekStart
           FROM   {InsightTable}
           WHERE  Bucket = 'Previous'
           GROUP BY WeekStart
           ORDER BY WeekStart DESC);

SELECT @@ROWCOUNT;";

        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(ct);
        try
        {
            await using var cmd = new SqlCommand(sql, conn, tx) { CommandTimeout = 300 };
            cmd.Parameters.Add("@UpdatedBy", SqlDbType.NVarChar, 200).Value = Db(userName);
            cmd.Parameters.Add("@Retain", SqlDbType.Int).Value = DenialInsightBuckets.PreviousWeeksRetained;

            await using var reader = await cmd.ExecuteReaderAsync(ct);

            var rolled = await ReadCountAsync(reader, ct);
            await reader.NextResultAsync(ct);
            var archived = await ReadCountAsync(reader, ct);

            await reader.CloseAsync();
            await tx.CommitAsync(ct);

            return new DenialInsightRollResult(rolled, archived);
        }
        catch
        {
            await tx.RollbackAsync(CancellationToken.None);
            throw;
        }
    }

    private static async Task<int> ReadCountAsync(SqlDataReader reader, CancellationToken ct) =>
        await reader.ReadAsync(ct) && !reader.IsDBNull(0) ? reader.GetInt32(0) : 0;

    /// <summary>
    /// The day the reporting week begins. Denial weeks run <b>Wednesday to Tuesday</b>, which is the
    /// lab's own reporting cycle rather than the calendar's - so a week reads "12 Aug - 18 Aug".
    /// </summary>
    private const DayOfWeek WeekStartsOn = DayOfWeek.Wednesday;

    /// <summary>
    /// The Wednesday that opens the week this date falls in. This is the week identity insights are
    /// stamped with and the weekly summary groups on, so both agree on where a week begins.
    /// </summary>
    public static DateTime WeekStartOf(DateTime date)
    {
        var d = date.Date;
        return d.AddDays(-(((int)d.DayOfWeek - (int)WeekStartsOn + 7) % 7));
    }

    private static async Task EnsureInsightTableAsync(SqlConnection conn, CancellationToken ct)
    {
        const string sql = """
            IF OBJECT_ID('dbo.DenialClaimLevelInsight', 'U') IS NULL
            BEGIN
                CREATE TABLE dbo.DenialClaimLevelInsight
                (
                    Id                BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClaimLevelInsight PRIMARY KEY,
                    Bucket            NVARCHAR(20)   NOT NULL CONSTRAINT DF_DCLI_Bucket DEFAULT 'Current',
                    WeekStart         DATE           NOT NULL CONSTRAINT DF_DCLI_WeekStart DEFAULT CAST(SYSUTCDATETIME() AS date),
                    SortOrder         INT            NOT NULL CONSTRAINT DF_DCLI_SortOrder DEFAULT 0,
                    DenialCode        NVARCHAR(100)  NOT NULL,
                    DenialDescription NVARCHAR(1000) NULL,
                    PayerName         NVARCHAR(255)  NULL,
                    NoOfDenials       INT            NOT NULL CONSTRAINT DF_DCLI_NoOfDenials DEFAULT 0,
                    TotalBalance      DECIMAL(18,2)  NOT NULL CONSTRAINT DF_DCLI_TotalBalance DEFAULT 0,
                    InsuranceBalance  DECIMAL(18,2)  NOT NULL CONSTRAINT DF_DCLI_InsuranceBalance DEFAULT 0,
                    ImpactPercentage  DECIMAL(18,2)  NOT NULL CONSTRAINT DF_DCLI_ImpactPercentage DEFAULT 0,
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

                CREATE UNIQUE INDEX UX_DenialClaimLevelInsight_Bucket_Week_Code_Payer
                    ON dbo.DenialClaimLevelInsight (Bucket, WeekStart, DenialCode, PayerName);
            END
            """;

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        await cmd.ExecuteNonQueryAsync(ct);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static string? FirstPresent(HashSet<string> cols, params string[] candidates) =>
        candidates.FirstOrDefault(cols.Contains);

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
            "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='dbo' AND TABLE_NAME=@Table;", conn);
        cmd.Parameters.AddWithValue("@Table", table);

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) cols.Add(reader.GetString(0));

        return cols;
    }

    private static object Db(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();

    private static string Text(SqlDataReader reader, string column)
    {
        var i = reader.GetOrdinal(column);
        return reader.IsDBNull(i) ? string.Empty : reader.GetValue(i)?.ToString()?.Trim() ?? string.Empty;
    }

    private static int GetIntOrZero(SqlDataReader reader, string column)
    {
        var i = reader.GetOrdinal(column);
        return reader.IsDBNull(i) ? 0 : Convert.ToInt32(reader.GetValue(i));
    }

    private static decimal GetDecimalOrZero(SqlDataReader reader, string column)
    {
        var i = reader.GetOrdinal(column);
        return reader.IsDBNull(i) ? 0m : Convert.ToDecimal(reader.GetValue(i));
    }

    private static DateTime? GetDate(SqlDataReader reader, string column)
    {
        var i = reader.GetOrdinal(column);
        return reader.IsDBNull(i) ? null : Convert.ToDateTime(reader.GetValue(i));
    }
}
