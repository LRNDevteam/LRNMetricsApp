using System.Data;
using LRN.AveragesImport.Core.Configuration;
using LRN.AveragesImport.Core.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LRN.AveragesImport.Core.Services;

public interface IAverageAggregateReader
{
    /// <summary>SOP v1.1 §1 — dbo.LineLevelData, per WindowBasis + WindowType + CPT + Panel + Payer.</summary>
    Task<IReadOnlyList<CptAverageRecord>> ReadCptAveragesAsync(LabRunInfo run, CancellationToken ct);

    /// <summary>SOP v1.1 §2 — dbo.ClaimLevelData, per WindowBasis + WindowType + Panel + Payer.</summary>
    Task<IReadOnlyList<PanelAverageRecord>> ReadPanelAveragesAsync(LabRunInfo run, CancellationToken ct);

    /// <summary>"Database.dbo.Table" for logging — never includes credentials.</summary>
    string DescribeSource(LabRunInfo run, string fileType);
}

/// <summary>
/// Computes the CPT- and panel-level averages directly from the lab database,
/// replacing the CSV files the worker used to read.
///
/// The two levels no longer share a query: SOP v1.1 §1 reads dbo.LineLevelData and
/// its per-unit amount columns, while §2 reads dbo.ClaimLevelData, whose amounts are
/// whole-claim ("AllowedAmount", "InsurancePayment") and whose counts are distinct
/// claims rather than line items. The tables also disagree on the status column —
/// line level has PayStatus, claim level only ClaimStatus — and on its vocabulary,
/// which is why the status literals differ between the two statements.
///
/// Both tables store every value as NVARCHAR, so each numeric/date column goes
/// through TRY_CAST; a row that fails a cast simply drops out of that one statistic
/// (SQL aggregates ignore NULLs) rather than failing the batch.
/// </summary>
public sealed class AverageAggregateReader : IAverageAggregateReader
{
    private readonly ILogger<AverageAggregateReader> _logger;
    private readonly IOptions<ImportSettings> _settings;

    public AverageAggregateReader(ILogger<AverageAggregateReader> logger, IOptions<ImportSettings> settings)
    {
        _logger = logger;
        _settings = settings;
    }

    // ── Shared SOP v1.1 window rules ─────────────────────────────────────────

    /// <summary>
    /// SOP v1.1 steps 2-4: every row is classified twice, once off Days to DOS and
    /// once off Days to Bill. Each basis is an independent set of output rows, tagged
    /// by WindowBasis — the SOP never filters on both windows at once.
    /// A row whose day count will not cast is dropped from that basis only, so a bad
    /// DaystoBill does not cost the row its DOS classification.
    /// </summary>
    private const string BasisApply = """
                CROSS APPLY (VALUES
                    ('DOS',    TRY_CAST({0}.DaystoDOS  AS INT)),
                    ('Billed', TRY_CAST({0}.DaystoBill AS INT))
                ) AS b(WindowBasis, Days)
        """;

    /// <summary>
    /// SOP v1.1 steps 5-9. The 30/60/90 bands are written as bare "&lt;= n" and so are
    /// cumulative: a row 20 days old belongs to Rolling 30, Rolling 60 AND Rolling 90,
    /// which is what makes "Rolling 90 Days" a true trailing-90-day figure. Steps 8-9
    /// are bounded ("between 91 to 180", "&gt;180"), so Rolling 180 and YTD do NOT
    /// contain the shorter windows. One source row therefore produces at most three
    /// window rows per basis, and per (basis, window) key it appears exactly once.
    /// </summary>
    private const string WindowJoin = """
                CROSS JOIN (VALUES
                    ('Rolling 30 Days'), ('Rolling 60 Days'), ('Rolling 90 Days'),
                    ('Rolling 180 Days'), ('YTD')
                ) AS w(WindowType)
        """;

    private const string WindowPredicate = """
                    b.Days IS NOT NULL
                  AND ((w.WindowType = 'Rolling 30 Days'  AND b.Days <= 30)
                    OR (w.WindowType = 'Rolling 60 Days'  AND b.Days <= 60)
                    OR (w.WindowType = 'Rolling 90 Days'  AND b.Days <= 90)
                    OR (w.WindowType = 'Rolling 180 Days' AND b.Days BETWEEN 91 AND 180)
                    OR (w.WindowType = 'YTD'              AND b.Days > 180))
        """;

    // ── §1 CPT level, from dbo.LineLevelData ─────────────────────────────────

    /// <summary>
    /// IsScored carries the v1.1 exclusion rule, which is now conditional: No Response
    /// is excluded from the amount statistics only in the 30-day window (steps 2 and 4
    /// of each metric) and included in every other window (steps 3 and 5). The four
    /// counts (§1.1.7-§1.1.10) are specified with no exclusion at all and so run over
    /// every row.
    ///
    /// Median/mode need the whole partition, so they are computed as window functions
    /// before the GROUP BY and collapsed with MAX(), safe because the value is constant
    /// within a partition. Mode ranks by frequency descending then value ascending so a
    /// tie always resolves the same way; NULL amounts get a COUNT of 0 and sort last.
    ///
    /// Status literals are the values that actually occur in LineLevelData.PayStatus —
    /// there is no 'Fully Denied'/'Fully Adjusted' at line level.
    /// </summary>
    private const string CptSqlTemplate = """
        ;WITH src AS (
            SELECT
                b.WindowBasis,
                w.WindowType,
                NULLIF(LTRIM(RTRIM(l.LabName)), '')           AS LabName,
                NULLIF(LTRIM(RTRIM(l.CPTCode)), '')           AS CptCode,
                NULLIF(LTRIM(RTRIM(l.Panelname)), '')         AS PanelName,
                NULLIF(LTRIM(RTRIM(l.Payer_Common_Code)), '') AS PayerCommonCode,
                NULLIF(LTRIM(RTRIM(l.PayerName)), '')         AS PayerDisplayName,
                TRY_CAST(l.Global_Payer_ID AS INT)            AS GlobalPayerId,
                LTRIM(RTRIM(ISNULL(l.PayStatus, '')))         AS PayStatus,
                CASE WHEN w.WindowType = 'Rolling 30 Days'
                      AND LTRIM(RTRIM(ISNULL(l.PayStatus, ''))) = 'No Response'
                     THEN 0 ELSE 1 END                        AS IsScored,
                TRY_CAST(l.Units                   AS INT)           AS Units,
                TRY_CAST(l.ChargeAmountPerUnit     AS DECIMAL(18,4)) AS ChargeAmount,
                TRY_CAST(l.AllowedAmountPerUnit    AS DECIMAL(18,4)) AS AllowedAmount,
                TRY_CAST(l.InsurancePaymentPerUnit AS DECIMAL(18,4)) AS PaidAmount,
                TRY_CAST(l.PatientPaymentPerUnit   AS DECIMAL(18,4)) AS PatientPaidAmount,
                TRY_CAST(l.PatientBalancePerUnit   AS DECIMAL(18,4)) AS PatientResponsibility,
                TRY_CAST(l.DateofService           AS DATE)          AS DateofService
            FROM dbo.LineLevelData l
        {BASISAPPLY}
        {WINDOWJOIN}
            WHERE
        {WINDOWPREDICATE}
              AND l.RunId = @RunId
              AND NULLIF(LTRIM(RTRIM(l.CPTCode)), '') IS NOT NULL
        ),
        scoped AS (
            SELECT
                s.*,
                CASE WHEN s.IsScored = 1 THEN s.AllowedAmount END AS ScoredAllowed,
                CASE WHEN s.IsScored = 1 THEN s.PaidAmount    END AS ScoredPaid
            FROM src s
        ),
        tagged AS (
            SELECT
                c.*,
                COUNT(c.ScoredAllowed) OVER (PARTITION BY {KEY}, c.ScoredAllowed) AS AllowedFreq,
                COUNT(c.ScoredPaid)    OVER (PARTITION BY {KEY}, c.ScoredPaid)    AS PaidFreq,
                PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY c.ScoredAllowed)
                    OVER (PARTITION BY {KEY}) AS MedianAllowedAmount,
                PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY c.ScoredPaid)
                    OVER (PARTITION BY {KEY}) AS MedianPaidAmount,
                PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY c.ScoredPaid)
                    OVER (PARTITION BY {KEY}) AS P25PaidAmount,
                PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY c.ScoredPaid)
                    OVER (PARTITION BY {KEY}) AS P75PaidAmount
            FROM scoped c
        ),
        ranked AS (
            SELECT
                t.*,
                FIRST_VALUE(t.ScoredAllowed) OVER (
                    PARTITION BY {KEY}
                    ORDER BY t.AllowedFreq DESC, t.ScoredAllowed
                    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS ModeAllowedAmount,
                FIRST_VALUE(t.ScoredPaid) OVER (
                    PARTITION BY {KEY}
                    ORDER BY t.PaidFreq DESC, t.ScoredPaid
                    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS ModePaidAmount
            FROM tagged t
        )
        SELECT
            MAX(LabName)                                                     AS LabName,
            WindowBasis, WindowType, CptCode, PanelName,
            PayerCommonCode, PayerDisplayName, GlobalPayerId,
            MIN(DateofService)                                               AS StartDate,
            MAX(DateofService)                                               AS EndDate,
            CAST(GETDATE() AS DATE)                                          AS AsOfDateTime,
            MAX(DateofService)                                               AS LastSeenDOS,
            CAST(ROUND(AVG(CASE WHEN IsScored = 1
                                THEN CAST(Units AS DECIMAL(18,4)) END), 0) AS INT)          AS AvgUnits,
            CAST(AVG(CASE WHEN IsScored = 1 THEN ChargeAmount END)          AS DECIMAL(18,2)) AS AvgChargeAmount,
            CAST(AVG(ScoredPaid)                                            AS DECIMAL(18,2)) AS AvgPaidAmount,
            CAST(AVG(ScoredAllowed)                                         AS DECIMAL(18,2)) AS AvgAllowedAmount,
            CAST(AVG(CASE WHEN IsScored = 1 THEN PatientPaidAmount END)     AS DECIMAL(18,2)) AS AvgPatientPaidAmount,
            CAST(AVG(CASE WHEN IsScored = 1 THEN PatientResponsibility END) AS DECIMAL(18,2)) AS AvgPatientResponsibility,
            CAST(MAX(MedianAllowedAmount)                                   AS DECIMAL(18,2)) AS MedianAllowedAmount,
            CAST(MAX(MedianPaidAmount)                                      AS DECIMAL(18,2)) AS MedianPaidAmount,
            CAST(MAX(ModeAllowedAmount)                                     AS DECIMAL(18,2)) AS ModeAllowedAmount,
            CAST(MAX(ModePaidAmount)                                        AS DECIMAL(18,2)) AS ModePaidAmount,
            CAST(MAX(P25PaidAmount)                                         AS DECIMAL(18,2)) AS P25PaidAmount,
            CAST(MAX(P75PaidAmount)                                         AS DECIMAL(18,2)) AS P75PaidAmount,
            COUNT(*)                                                                       AS TotalLineCount,
            SUM(CASE WHEN PayStatus = 'Paid'     THEN 1 ELSE 0 END)                        AS PaidLineCount,
            SUM(CASE WHEN PayStatus = 'Denied'   THEN 1 ELSE 0 END)                        AS DeniedLineCount,
            SUM(CASE WHEN PayStatus = 'Adjusted' THEN 1 ELSE 0 END)                        AS AdjustedLineCount
        FROM ranked
        GROUP BY {KEY}
        ORDER BY WindowBasis, WindowType, CptCode, PanelName;
        """;

    // ── §2 Panel level, from dbo.ClaimLevelData ──────────────────────────────

    /// <summary>
    /// Same window and exclusion rules as §1, over claim rows. Three differences the
    /// source table forces: the amounts are whole-claim columns (§2.1.1/§2.1.2 name
    /// "AllowedAmount" and "InsurancePayment"), the status column is ClaimStatus —
    /// ClaimLevelData has no PayStatus — and its vocabulary is the "Fully …" variants,
    /// so the SOP's "Pay Status = Paid" reads as ClaimStatus = 'Fully Paid'.
    /// The counts are distinct ClaimIDs per §2.1.7-§2.1.10.
    /// </summary>
    private const string PanelSqlTemplate = """
        ;WITH src AS (
            SELECT
                b.WindowBasis,
                w.WindowType,
                NULLIF(LTRIM(RTRIM(c.LabName)), '')   AS LabName,
                {PANELEXPR} AS PanelName,
                NULLIF(LTRIM(RTRIM(c.Global_Payer_ID)), '') AS PayerId,
                NULLIF(LTRIM(RTRIM(c.PayerName)), '') AS PayerDisplayName,
                NULLIF(LTRIM(RTRIM(c.ClaimID)), '')   AS ClaimID,
                LTRIM(RTRIM(ISNULL(c.ClaimStatus, ''))) AS ClaimStatus,
                CASE WHEN w.WindowType = 'Rolling 30 Days'
                      AND LTRIM(RTRIM(ISNULL(c.ClaimStatus, ''))) = 'No Response'
                     THEN 0 ELSE 1 END                AS IsScored,
                TRY_CAST(c.ChargeAmount     AS DECIMAL(18,4)) AS ChargeAmount,
                TRY_CAST(c.AllowedAmount    AS DECIMAL(18,4)) AS AllowedAmount,
                TRY_CAST(c.InsurancePayment AS DECIMAL(18,4)) AS PaidAmount,
                TRY_CAST(c.PatientPayment   AS DECIMAL(18,4)) AS PatientPaidAmount,
                TRY_CAST(c.PatientBalance   AS DECIMAL(18,4)) AS PatientResponsibility,
                TRY_CAST(c.DateofService    AS DATE)          AS DateofService
            FROM dbo.ClaimLevelData c
        {BASISAPPLY}
        {WINDOWJOIN}
            WHERE
        {WINDOWPREDICATE}
              AND c.RunId = @RunId
              AND {PANELEXPR} IS NOT NULL
        ),
        scoped AS (
            SELECT
                s.*,
                CASE WHEN s.IsScored = 1 THEN s.AllowedAmount END AS ScoredAllowed,
                CASE WHEN s.IsScored = 1 THEN s.PaidAmount    END AS ScoredPaid
            FROM src s
        ),
        tagged AS (
            SELECT
                c.*,
                COUNT(c.ScoredAllowed) OVER (PARTITION BY {KEY}, c.ScoredAllowed) AS AllowedFreq,
                COUNT(c.ScoredPaid)    OVER (PARTITION BY {KEY}, c.ScoredPaid)    AS PaidFreq,
                PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY c.ScoredAllowed)
                    OVER (PARTITION BY {KEY}) AS MedianAllowedAmount,
                PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY c.ScoredPaid)
                    OVER (PARTITION BY {KEY}) AS MedianPaidAmount,
                PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY c.ScoredPaid)
                    OVER (PARTITION BY {KEY}) AS P25PaidAmount,
                PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY c.ScoredPaid)
                    OVER (PARTITION BY {KEY}) AS P75PaidAmount
            FROM scoped c
        ),
        ranked AS (
            SELECT
                t.*,
                FIRST_VALUE(t.ScoredAllowed) OVER (
                    PARTITION BY {KEY}
                    ORDER BY t.AllowedFreq DESC, t.ScoredAllowed
                    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS ModeAllowedAmount,
                FIRST_VALUE(t.ScoredPaid) OVER (
                    PARTITION BY {KEY}
                    ORDER BY t.PaidFreq DESC, t.ScoredPaid
                    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS ModePaidAmount
            FROM tagged t
        )
        SELECT
            MAX(LabName)                                                     AS LabName,
            WindowBasis, WindowType, PanelName, PayerId, PayerDisplayName,
            MIN(DateofService)                                               AS StartDate,
            MAX(DateofService)                                               AS EndDate,
            CAST(GETDATE() AS DATE)                                          AS AsOfDateTime,
            MAX(DateofService)                                               AS LastSeenDOS,
            CAST(AVG(CASE WHEN IsScored = 1 THEN ChargeAmount END)          AS DECIMAL(18,2)) AS AvgChargeAmount,
            CAST(AVG(ScoredPaid)                                            AS DECIMAL(18,2)) AS AvgPaidAmount,
            CAST(AVG(ScoredAllowed)                                         AS DECIMAL(18,2)) AS AvgAllowedAmount,
            CAST(AVG(CASE WHEN IsScored = 1 THEN PatientPaidAmount END)     AS DECIMAL(18,2)) AS AvgPatientPaidAmount,
            CAST(AVG(CASE WHEN IsScored = 1 THEN PatientResponsibility END) AS DECIMAL(18,2)) AS AvgPatientResponsibility,
            CAST(MAX(MedianAllowedAmount)                                   AS DECIMAL(18,2)) AS MedianAllowedAmount,
            CAST(MAX(MedianPaidAmount)                                      AS DECIMAL(18,2)) AS MedianPaidAmount,
            CAST(MAX(ModeAllowedAmount)                                     AS DECIMAL(18,2)) AS ModeAllowedAmount,
            CAST(MAX(ModePaidAmount)                                        AS DECIMAL(18,2)) AS ModePaidAmount,
            CAST(MAX(P25PaidAmount)                                         AS DECIMAL(18,2)) AS P25PaidAmount,
            CAST(MAX(P75PaidAmount)                                         AS DECIMAL(18,2)) AS P75PaidAmount,
            COUNT(DISTINCT ClaimID)                                                        AS TotalClaimCount,
            COUNT(DISTINCT CASE WHEN ClaimStatus = 'Fully Paid'     THEN ClaimID END)      AS PaidClaimCount,
            COUNT(DISTINCT CASE WHEN ClaimStatus = 'Fully Denied'   THEN ClaimID END)      AS DeniedClaimCount,
            COUNT(DISTINCT CASE WHEN ClaimStatus = 'Fully Adjusted' THEN ClaimID END)      AS AdjustedClaimCount
        FROM ranked
        GROUP BY {KEY}
        ORDER BY WindowBasis, WindowType, PanelName;
        """;

    private static readonly string CptSql = Build(
        CptSqlTemplate, "l",
        "WindowBasis, WindowType, CptCode, PanelName, PayerCommonCode, PayerDisplayName, GlobalPayerId");

    private static readonly string PanelSql = Build(
        PanelSqlTemplate, "c",
        "WindowBasis, WindowType, PanelName, PayerId, PayerDisplayName");

    private static string Build(string template, string sourceAlias, string key) => template
        .Replace("{BASISAPPLY}", string.Format(BasisApply, sourceAlias))
        .Replace("{WINDOWJOIN}", WindowJoin)
        .Replace("{WINDOWPREDICATE}", WindowPredicate)
        .Replace("{KEY}", key);

    /// <summary>
    /// Claim-level panel columns, in the order they should be preferred.
    ///
    /// Panelname is the column every lab maps and is what §2 means. InHealth is the
    /// exception: its claim rows leave Panelname empty on all of them and carry the panel
    /// in PanelNameBasedOnCPT instead — a lab-specific column added by an ALTER, populated
    /// on 100% of rows, whose values match its line-level panels exactly. Without the
    /// fallback the panel aggregate for that lab filters every row away and reports
    /// Skipped, which is exactly what it did.
    ///
    /// PanelNameLIS is deliberately not in the chain: it is only ~77% populated for
    /// InHealth, so PanelNameBasedOnCPT already covers every row, and adding a third
    /// source would let two rows of the same claim set take their panel from different
    /// columns.
    /// </summary>
    private static readonly string[] ClaimPanelColumnPreference = { "Panelname", "PanelNameBasedOnCPT" };

    /// <summary>
    /// Only the columns that exist in this lab's ClaimLevelData are referenced — naming an
    /// absent column would make the statement invalid for every other lab. Detection is one
    /// cheap catalog read per lab per cycle.
    /// </summary>
    private async Task<string> BuildPanelSqlAsync(SqlConnection connection, CancellationToken ct)
    {
        const string sql = @"
SELECT name FROM sys.columns
WHERE object_id = OBJECT_ID('dbo.ClaimLevelData') AND name IN ('Panelname', 'PanelNameBasedOnCPT');";

        var present = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        await using (var command = new SqlCommand(sql, connection) { CommandTimeout = 60 })
        await using (var reader = await command.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
                present.Add(reader.GetString(0));
        }

        var columns = ClaimPanelColumnPreference.Where(present.Contains).ToArray();
        if (columns.Length == 0)
        {
            // Let the aggregation run and return nothing; WarnIfStaleAsync then reports
            // what the table actually holds rather than failing on an unknown column.
            _logger.LogWarning(
                "dbo.ClaimLevelData has none of the known panel columns ({Candidates}) — the panel aggregate will be empty",
                string.Join(", ", ClaimPanelColumnPreference));
            columns = new[] { ClaimPanelColumnPreference[0] };
        }
        else if (columns.Length > 1)
        {
            _logger.LogInformation("Claim-level panel resolved from {Columns} (first non-blank wins)",
                string.Join(" -> ", columns));
        }

        var trimmed = columns.Select(c => $"NULLIF(LTRIM(RTRIM(c.{c})), '')");
        var expression = columns.Length == 1 ? trimmed.Single() : $"COALESCE({string.Join(", ", trimmed)})";

        return PanelSql.Replace("{PANELEXPR}", expression);
    }

    // ── Reads ────────────────────────────────────────────────────────────────

    public Task<IReadOnlyList<CptAverageRecord>> ReadCptAveragesAsync(LabRunInfo run, CancellationToken ct)
        => ReadAsync(run, FileTypes.CptAverage, (_, _) => Task.FromResult(CptSql), reader => new CptAverageRecord
        {
            LabName = GetString(reader, "LabName") ?? run.LabName,
            WindowBasis = GetString(reader, "WindowBasis"),
            WindowType = GetString(reader, "WindowType"),
            CptCode = GetString(reader, "CptCode"),
            PanelName = GetString(reader, "PanelName"),
            PayerCommonCode = GetString(reader, "PayerCommonCode"),
            PayerDisplayName = GetString(reader, "PayerDisplayName"),
            GlobalPayerId = GetInt(reader, "GlobalPayerId"),
            StartDate = GetDate(reader, "StartDate"),
            EndDate = GetDate(reader, "EndDate"),
            AsOfDateTime = GetDate(reader, "AsOfDateTime"),
            LastSeenDos = GetDate(reader, "LastSeenDOS"),
            AvgUnits = GetInt(reader, "AvgUnits"),
            AvgChargeAmountPerUnit = GetDecimal(reader, "AvgChargeAmount"),
            AvgPaidAmountPerUnit = GetDecimal(reader, "AvgPaidAmount"),
            AvgAllowedAmountPerUnit = GetDecimal(reader, "AvgAllowedAmount"),
            AvgPatientPaidAmountPerUnit = GetDecimal(reader, "AvgPatientPaidAmount"),
            AvgPatientResponsibilityPerUnit = GetDecimal(reader, "AvgPatientResponsibility"),
            MedianAllowedAmount = GetDecimal(reader, "MedianAllowedAmount"),
            MedianPaidAmount = GetDecimal(reader, "MedianPaidAmount"),
            ModeAllowedAmount = GetDecimal(reader, "ModeAllowedAmount"),
            ModePaidAmount = GetDecimal(reader, "ModePaidAmount"),
            P25PaidAmount = GetDecimal(reader, "P25PaidAmount"),
            P75PaidAmount = GetDecimal(reader, "P75PaidAmount"),
            TotalLineCount = GetInt(reader, "TotalLineCount"),
            PaidLineCount = GetInt(reader, "PaidLineCount"),
            DeniedLineCount = GetInt(reader, "DeniedLineCount"),
            AdjustedLineCount = GetInt(reader, "AdjustedLineCount")
        }, ct);

    public Task<IReadOnlyList<PanelAverageRecord>> ReadPanelAveragesAsync(LabRunInfo run, CancellationToken ct)
        => ReadAsync(run, FileTypes.PanelAverage, BuildPanelSqlAsync, reader => new PanelAverageRecord
        {
            LabName = GetString(reader, "LabName") ?? run.LabName,
            WindowBasis = GetString(reader, "WindowBasis"),
            WindowType = GetString(reader, "WindowType"),
            PanelName = GetString(reader, "PanelName"),
            PayerId = GetString(reader, "PayerId"),
            PayerDisplayName = GetString(reader, "PayerDisplayName"),
            StartDate = GetDate(reader, "StartDate"),
            EndDate = GetDate(reader, "EndDate"),
            AsOfDateTime = GetDate(reader, "AsOfDateTime"),
            LastSeenDos = GetDate(reader, "LastSeenDOS"),
            AvgChargeAmount = GetDecimal(reader, "AvgChargeAmount"),
            AvgPaidAmount = GetDecimal(reader, "AvgPaidAmount"),
            AvgAllowedAmount = GetDecimal(reader, "AvgAllowedAmount"),
            AvgPatientPaidAmount = GetDecimal(reader, "AvgPatientPaidAmount"),
            AvgPatientResponsibility = GetDecimal(reader, "AvgPatientResponsibility"),
            MedianAllowedAmount = GetDecimal(reader, "MedianAllowedAmount"),
            MedianPaidAmount = GetDecimal(reader, "MedianPaidAmount"),
            ModeAllowedAmount = GetDecimal(reader, "ModeAllowedAmount"),
            ModePaidAmount = GetDecimal(reader, "ModePaidAmount"),
            P25PaidAmount = GetDecimal(reader, "P25PaidAmount"),
            P75PaidAmount = GetDecimal(reader, "P75PaidAmount"),
            TotalLineCount = GetInt(reader, "TotalClaimCount"),
            PaidLineCount = GetInt(reader, "PaidClaimCount"),
            DeniedLineCount = GetInt(reader, "DeniedClaimCount"),
            AdjustedLineCount = GetInt(reader, "AdjustedClaimCount")
        }, ct);

    private async Task<IReadOnlyList<T>> ReadAsync<T>(
        LabRunInfo run,
        string aggregate,
        Func<SqlConnection, CancellationToken, Task<string>> sqlFactory,
        Func<SqlDataReader, T> project,
        CancellationToken ct)
    {
        var records = new List<T>();
        var source = DescribeSource(run, aggregate);

        await using var connection = new SqlConnection(run.ConnectionString);
        await connection.OpenAsync(ct);

        // The panel statement is shaped per lab, so it needs the open connection first.
        var sql = await sqlFactory(connection, ct);

        await using (var command = new SqlCommand(sql, connection)
        {
            CommandType = CommandType.Text,
            CommandTimeout = _settings.Value.AggregateCommandTimeoutSeconds
        })
        {
            command.Parameters.Add("@RunId", SqlDbType.NVarChar, 500).Value = run.RunId;

            await using var reader = await command.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                records.Add(project(reader));
        }

        if (records.Count == 0)
            await WarnIfStaleAsync(connection, run, aggregate, source, ct);

        _logger.LogInformation("Aggregated {Rows} {Aggregate} row(s) from {Source} for {LabName} (LabId {LabId}, RunId {RunId})",
            records.Count, aggregate, source, run.LabName, run.LabId, run.RunId);

        return records;
    }

    /// <summary>
    /// Zero rows usually means the capture process has not loaded this run into the lab
    /// database yet — each lab table holds exactly one run and is replaced wholesale, so
    /// it can still be sitting on the previous one. Naming the run the table actually
    /// holds turns a silent empty result into an obvious "waiting for capture".
    ///
    /// Only runs on the empty path, so the extra scan never costs a healthy cycle.
    /// </summary>
    private async Task WarnIfStaleAsync(
        SqlConnection connection, LabRunInfo run, string aggregate, string source, CancellationToken ct)
    {
        var table = aggregate == FileTypes.CptAverage ? "dbo.LineLevelData" : "dbo.ClaimLevelData";

        try
        {
            await using var command = new SqlCommand(
                $"SELECT TOP (5) RunId, COUNT(*) AS Rows FROM {table} GROUP BY RunId ORDER BY COUNT(*) DESC;",
                connection) { CommandTimeout = _settings.Value.AggregateCommandTimeoutSeconds };

            var present = new List<string>();
            await using var reader = await command.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                present.Add($"{(reader.IsDBNull(0) ? "(null)" : reader.GetString(0))}={reader.GetInt32(1)} rows");

            if (present.Count == 0)
                _logger.LogWarning("{Source} is empty — nothing to aggregate for {LabName} run {RunId}",
                    source, run.LabName, run.RunId);
            else
                _logger.LogWarning(
                    "{Source} holds no rows for run {RunId} (it currently holds {Present}) — the capture process has not " +
                    "loaded this run yet; {LabName} will be retried next cycle",
                    source, run.RunId, string.Join("; ", present), run.LabName);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not inspect {Source} to explain the empty {Aggregate} result for {LabName}",
                source, aggregate, run.LabName);
        }
    }

    public string DescribeSource(LabRunInfo run, string fileType)
    {
        var table = fileType == FileTypes.CptAverage ? "dbo.LineLevelData" : "dbo.ClaimLevelData";
        try
        {
            var database = new SqlConnectionStringBuilder(run.ConnectionString).InitialCatalog;
            return string.IsNullOrWhiteSpace(database) ? table : $"{database}.{table}";
        }
        catch (ArgumentException)
        {
            // Malformed connection string — opening it will report the real problem.
            return table;
        }
    }

    private static string? GetString(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
    }

    private static int? GetInt(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : reader.GetInt32(ordinal);
    }

    private static decimal? GetDecimal(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : reader.GetDecimal(ordinal);
    }

    private static DateTime? GetDate(SqlDataReader reader, string column)
    {
        var ordinal = reader.GetOrdinal(column);
        return reader.IsDBNull(ordinal) ? null : reader.GetDateTime(ordinal);
    }
}
