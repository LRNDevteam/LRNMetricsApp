using ClosedXML.Excel;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services;

public interface ICptLookupRepository
{
    Task<LookupResult<CptLookupRow>> GetCptAsync(LookupQuery query, CancellationToken ct);
    Task<LookupResult<PanelLookupRow>> GetPanelAsync(LookupQuery query, CancellationToken ct);
    Task<byte[]> ExportCptAsync(LookupQuery query, CancellationToken ct);
    Task<byte[]> ExportPanelAsync(LookupQuery query, CancellationToken ct);
    Task<IReadOnlyList<string>> GetCptOptionsAsync(string? field, string? term, int? labId, CancellationToken ct);
    Task<IReadOnlyList<string>> GetPanelOptionsAsync(string? field, string? term, int? labId, CancellationToken ct);
    Task<IReadOnlyList<MasterValueLabOption>> GetLabsAsync(CancellationToken ct);
    /// <summary>Every window a given CPT/panel/payer combination has data for — powers the drill-down comparison.</summary>
    Task<IReadOnlyList<CptLookupRow>> GetCptWindowsAsync(int labId, string cptCode, string? panelName, string? payer, CancellationToken ct);
    Task<IReadOnlyList<PanelLookupRow>> GetPanelWindowsAsync(int labId, string panelName, string? payer, CancellationToken ct);
}

/// <summary>
/// Read-only access to the four LRNMaster tables behind the CPT &amp; Panel Lookup
/// screen: dbo.CPTAverage, dbo.PanelAverage, dbo.LabModes and dbo.LabMedians.
///
/// Two things about the source data drive the shape of the SQL here:
///
/// 1. LabModes/LabMedians hold one row per observed allowed/payment amount, not
///    one row per key — a single lab+CPT+panel+payer+window can have 500+ rows.
///    The mode/median columns repeat the same value on every one of those rows,
///    so the CTEs collapse them with MAX() and GROUP BY. Joining the raw tables
///    would multiply every CPTAverage row by the observation count.
///
/// 2. The payer columns only partly line up: CPTAverage.PayerDisplayName matches
///    a LabModes.PayerName for roughly half of the distinct payers, and both
///    sides carry NULLs. The join is therefore a LEFT JOIN with NULL-safe payer
///    matching — a CPT row with no mode/median rate is expected and renders as
///    an em dash rather than disappearing from the grid.
/// </summary>
public sealed class SqlCptLookupRepository : ICptLookupRepository
{
    private const int ExportRowCap = 100000;
    private const int FilterOptionCap = 100;
    private const int MaxPageSize = 1000;

    private readonly string _connectionString;

    public SqlCptLookupRepository(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing. It must point to LRNMaster.");
    }

    /// <summary>
    /// Builds against an explicit LRNMaster connection instead of ConnectionStrings:DefaultConnection.
    /// LRN.ReportWorker uses this: it has no master connection string of its own and instead reads
    /// LRNMaster through the shared queue lab's own DbConnectionString.
    /// </summary>
    public SqlCptLookupRepository(string connectionString)
    {
        _connectionString = string.IsNullOrWhiteSpace(connectionString)
            ? throw new ArgumentException("A LRNMaster connection string is required.", nameof(connectionString))
            : connectionString;
    }

    // ── SQL fragments ────────────────────────────────────────────────────────

    // MAX() is safe: the mode/median value is constant within a key (verified —
    // every key groups to exactly one distinct ModeAllowedAmount).
    //
    // CptKey exists because the two sources spell the same code differently:
    // CPTAverage strips the spaces ("80307ATI-ATITOXSCREEN") while LabModes keeps
    // them ("80307 ATI - ATI TOX SCREEN"). Removing every space and upper-casing
    // makes them comparable; joining on the raw column loses real matches.
    //
    // Each rate is resolved in two steps. The payer-specific CTE is preferred; when
    // that misses — the payer names in LabModes only partly overlap CPTAverage's —
    // the lab-wide CTE supplies the rate for the same lab + CPT + panel + window with
    // the payer ignored. The row reports which one it used via ModeMatch/MedianMatch
    // so a lab-wide figure is never silently passed off as the payer's own rate.
    // The fallback lifts coverage from 4,218 to 7,027 rows, against a hard ceiling of
    // 7,098 (the rows whose lab has any LabModes data at all).
    /// <summary>
    /// The four rate CTEs, WITHOUT the leading <c>WITH</c> so callers can compose them with
    /// other CTEs.
    ///
    /// <paramref name="scopedToLab"/> pushes <c>WHERE LabId = @LabId</c> into each base-table
    /// scan. That is provably equivalent whenever the outer query also filters
    /// <c>a.LabID = @LabId</c>: every join predicate includes <c>LabId = a.LabID</c>, so a CTE
    /// row for another lab could never join anyway. Without it, one page of one lab aggregates
    /// the whole of LabModes and LabMedians four times over.
    /// </summary>
    private static string RateCteBody(bool scopedToLab)
    {
        var labFilter = scopedToLab ? "WHERE LabId = @LabId" : "";

        return $"""
        mode_payer AS (
            SELECT LabId, REPLACE(UPPER(CPTCode), ' ', '') AS CptKey, PanelName, RollingDays, PayerName,
                   MAX(ModeAllowedAmount)           AS ModeAllowedAmount,
                   MAX(ModeInsurancePaymentAmount)  AS ModeInsurancePaymentAmount,
                   MAX(AllowedAmountPerUnitMode)    AS AllowedAmountPerUnitMode,
                   MAX(InsurancePaymentPerUnitMode) AS InsurancePaymentPerUnitMode
            FROM dbo.LabModes
            {labFilter}
            GROUP BY LabId, REPLACE(UPPER(CPTCode), ' ', ''), PanelName, RollingDays, PayerName
        ),
        mode_lab AS (
            SELECT LabId, REPLACE(UPPER(CPTCode), ' ', '') AS CptKey, PanelName, RollingDays,
                   MAX(ModeAllowedAmount)           AS ModeAllowedAmount,
                   MAX(ModeInsurancePaymentAmount)  AS ModeInsurancePaymentAmount,
                   MAX(AllowedAmountPerUnitMode)    AS AllowedAmountPerUnitMode,
                   MAX(InsurancePaymentPerUnitMode) AS InsurancePaymentPerUnitMode
            FROM dbo.LabModes
            {labFilter}
            GROUP BY LabId, REPLACE(UPPER(CPTCode), ' ', ''), PanelName, RollingDays
        ),
        median_payer AS (
            SELECT LabId, REPLACE(UPPER(CPTCode), ' ', '') AS CptKey, PanelName, RollingDays, PayerName,
                   MAX(MedianAllowedAmount)             AS MedianAllowedAmount,
                   MAX(MedianInsurancePaymentAmount)    AS MedianInsurancePaymentAmount,
                   MAX(AllowedAmountPerUnitMedian)      AS AllowedAmountPerUnitMedian,
                   MAX(InsurancePaymentPerUnitMedian)   AS InsurancePaymentPerUnitMedian
            FROM dbo.LabMedians
            {labFilter}
            GROUP BY LabId, REPLACE(UPPER(CPTCode), ' ', ''), PanelName, RollingDays, PayerName
        ),
        median_lab AS (
            SELECT LabId, REPLACE(UPPER(CPTCode), ' ', '') AS CptKey, PanelName, RollingDays,
                   MAX(MedianAllowedAmount)             AS MedianAllowedAmount,
                   MAX(MedianInsurancePaymentAmount)    AS MedianInsurancePaymentAmount,
                   MAX(AllowedAmountPerUnitMedian)      AS AllowedAmountPerUnitMedian,
                   MAX(InsurancePaymentPerUnitMedian)   AS InsurancePaymentPerUnitMedian
            FROM dbo.LabMedians
            {labFilter}
            GROUP BY LabId, REPLACE(UPPER(CPTCode), ' ', ''), PanelName, RollingDays
        )
        """;
    }

    /// <summary>The rate joins alone, so the driving table can be either CPTAverage or one page of it.</summary>
    private const string CptJoins = """
        LEFT JOIN mode_payer mp
               ON mp.LabId       = a.LabID
              AND mp.CptKey      = REPLACE(UPPER(a.CPTCode), ' ', '')
              AND ISNULL(mp.PanelName, '') = ISNULL(a.PanelName, '')
              AND mp.RollingDays = a.WindowType
              AND ISNULL(mp.PayerName, '') = ISNULL(a.PayerDisplayName, '')
        LEFT JOIN mode_lab ml
               ON ml.LabId       = a.LabID
              AND ml.CptKey      = REPLACE(UPPER(a.CPTCode), ' ', '')
              AND ISNULL(ml.PanelName, '') = ISNULL(a.PanelName, '')
              AND ml.RollingDays = a.WindowType
        LEFT JOIN median_payer dp
               ON dp.LabId       = a.LabID
              AND dp.CptKey      = REPLACE(UPPER(a.CPTCode), ' ', '')
              AND ISNULL(dp.PanelName, '') = ISNULL(a.PanelName, '')
              AND dp.RollingDays = a.WindowType
              AND ISNULL(dp.PayerName, '') = ISNULL(a.PayerDisplayName, '')
        LEFT JOIN median_lab dl
               ON dl.LabId       = a.LabID
              AND dl.CptKey      = REPLACE(UPPER(a.CPTCode), ' ', '')
              AND ISNULL(dl.PanelName, '') = ISNULL(a.PanelName, '')
              AND dl.RollingDays = a.WindowType
        """;

    private const string CptFrom = $"""
        FROM dbo.CPTAverage a
        {CptJoins}
        """;

    /// <summary>The same joins, driven by one page of CPTAverage rather than all of it.</summary>
    private const string CptFromPage = $"""
        FROM page a
        {CptJoins}
        """;

    /// <summary>
    /// True when the sort needs a joined rate value, which forces the joins to run before
    /// paging. Every other sort is on a CPTAverage column, so the page can be taken first.
    /// </summary>
    private static bool SortsOnJoinedRate(string orderBy, params string[] aliases) =>
        aliases.Any(alias => orderBy.Contains(alias, StringComparison.Ordinal));

    /// <summary>The CPT page query. Separated from the I/O so its SQL can be inspected and parsed in isolation.</summary>
    private static string BuildCptPageSql(string where, string orderBy, bool scoped, bool pageFirst) => pageFirst
        ? $"""
        WITH page AS (
            SELECT *
            FROM dbo.CPTAverage a
            WHERE {where}
            ORDER BY {orderBy}
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY
        ),
        {RateCteBody(scoped)}
        SELECT {CptSelect}
        {CptFromPage}
        ORDER BY {orderBy};
        """
        : $"""
        WITH {RateCteBody(scoped)}
        SELECT {CptSelect}
        {CptFrom}
        WHERE {where}
        ORDER BY {orderBy}
        OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
        """;

    /// <summary>The Panel page query. Same split, same reason.</summary>
    private static string BuildPanelPageSql(string where, string orderBy, bool scoped, bool pageFirst) => pageFirst
        ? $"""
        WITH page AS (
            SELECT *
            FROM dbo.PanelAverage p
            WHERE {where}
            ORDER BY {orderBy}
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY
        ),
        {PanelModeCteBody(scoped)}
        SELECT {PanelSelect}
        {PanelFromPage}
        ORDER BY {orderBy};
        """
        : $"""
        WITH {PanelModeCteBody(scoped)}
        SELECT {PanelSelect}
        {PanelFrom}
        WHERE {where}
        ORDER BY {orderBy}
        OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
        """;

    // Expression fragments reused by the SELECT list and the sort whitelist, so a
    // column and its sort always resolve the payer/lab fallback the same way.
    private const string ModeAllowedExpr = "COALESCE(mp.ModeAllowedAmount, ml.ModeAllowedAmount)";
    private const string ModePaidExpr = "COALESCE(mp.ModeInsurancePaymentAmount, ml.ModeInsurancePaymentAmount)";
    private const string ModeAllowedUnitExpr = "COALESCE(mp.AllowedAmountPerUnitMode, ml.AllowedAmountPerUnitMode)";
    private const string ModePaidUnitExpr = "COALESCE(mp.InsurancePaymentPerUnitMode, ml.InsurancePaymentPerUnitMode)";
    private const string MedianAllowedExpr = "COALESCE(dp.MedianAllowedAmount, dl.MedianAllowedAmount)";
    private const string MedianPaidExpr = "COALESCE(dp.MedianInsurancePaymentAmount, dl.MedianInsurancePaymentAmount)";
    private const string MedianAllowedUnitExpr = "COALESCE(dp.AllowedAmountPerUnitMedian, dl.AllowedAmountPerUnitMedian)";
    private const string MedianPaidUnitExpr = "COALESCE(dp.InsurancePaymentPerUnitMedian, dl.InsurancePaymentPerUnitMedian)";

    private const string CptSelect = $"""
        a.LabID, a.LabName, a.CPTCode, a.PanelName, a.PayerDisplayName, a.PayerCommonCode,
        a.Global_Payer_ID, a.WindowType, a.StartDate, a.EndDate, a.AsOfDateTime,
        a.AvgUnits, a.AvgChargeAmountPerUnit, a.AvgAllowedAmountPerUnit, a.AvgPaidAmountPerUnit,
        a.AvgPatientResponsibilityPerUnit, a.MedianPaidAmount, a.P25PaidAmount, a.P75PaidAmount,
        a.PaidLineCount, a.TotalLineCount, a.DeniedLineCount, a.AdjustedLineCount,
        {ModeAllowedExpr}       AS ModeAllowedAmount,
        {ModePaidExpr}          AS ModeInsurancePaymentAmount,
        {ModeAllowedUnitExpr}   AS AllowedAmountPerUnitMode,
        {ModePaidUnitExpr}      AS InsurancePaymentPerUnitMode,
        {MedianAllowedExpr}     AS MedianAllowedAmount,
        {MedianPaidExpr}        AS MedianInsurancePaymentAmount,
        {MedianAllowedUnitExpr} AS AllowedAmountPerUnitMedian,
        {MedianPaidUnitExpr}    AS InsurancePaymentPerUnitMedian,
        CASE WHEN mp.ModeAllowedAmount   IS NOT NULL THEN 'payer'
             WHEN ml.ModeAllowedAmount   IS NOT NULL THEN 'lab'   END AS ModeMatch,
        CASE WHEN dp.MedianAllowedAmount IS NOT NULL THEN 'payer'
             WHEN dl.MedianAllowedAmount IS NOT NULL THEN 'lab'   END AS MedianMatch
        """;

    // Panel-level modes. LabModes is CPT-level, so a panel figure has to aggregate
    // across the panel's CPT codes: MAX() collapses each CPT to its single mode, then
    // AVG() averages those. AVG — not SUM — because PanelAverage's own amounts are
    // per-line averages: summing the CPT modes overshoots the matching PanelAverage
    // row by 5-12x, while the average lands in the same range. ModeCptCount is
    // returned so the grid can show how many CPTs a panel figure rests on.
    /// <summary>Panel mode CTEs without the leading <c>WITH</c>. See <see cref="RateCteBody"/> for why the lab filter is safe.</summary>
    private static string PanelModeCteBody(bool scopedToLab) => $"""
        cpt_mode AS (
            SELECT LabId, PanelName, RollingDays, PayerName, REPLACE(UPPER(CPTCode), ' ', '') AS CptKey,
                   MAX(ModeAllowedAmount)          AS ModeAllowed,
                   MAX(ModeInsurancePaymentAmount) AS ModePaid
            FROM dbo.LabModes
            {(scopedToLab ? "WHERE LabId = @LabId" : "")}
            GROUP BY LabId, PanelName, RollingDays, PayerName, REPLACE(UPPER(CPTCode), ' ', '')
        ),
        panel_mode_payer AS (
            SELECT LabId, PanelName, RollingDays, PayerName,
                   AVG(ModeAllowed) AS ModeAllowedAmount,
                   AVG(ModePaid)    AS ModeInsurancePaymentAmount,
                   COUNT(*)         AS ModeCptCount
            FROM cpt_mode
            GROUP BY LabId, PanelName, RollingDays, PayerName
        ),
        panel_mode_lab AS (
            SELECT LabId, PanelName, RollingDays,
                   AVG(ModeAllowed) AS ModeAllowedAmount,
                   AVG(ModePaid)    AS ModeInsurancePaymentAmount,
                   COUNT(*)         AS ModeCptCount
            FROM cpt_mode
            GROUP BY LabId, PanelName, RollingDays
        )
        """;

    private const string PanelJoins = """
        LEFT JOIN panel_mode_payer pmp
               ON pmp.LabId       = p.LabId
              AND ISNULL(pmp.PanelName, '') = ISNULL(p.PanelName, '')
              AND pmp.RollingDays = p.WindowType
              AND ISNULL(pmp.PayerName, '') = ISNULL(p.PayerDisplayName, '')
        LEFT JOIN panel_mode_lab pml
               ON pml.LabId       = p.LabId
              AND ISNULL(pml.PanelName, '') = ISNULL(p.PanelName, '')
              AND pml.RollingDays = p.WindowType
        """;

    private const string PanelFrom = $"""
        FROM dbo.PanelAverage p
        {PanelJoins}
        """;

    private const string PanelFromPage = $"""
        FROM page p
        {PanelJoins}
        """;

    private const string PanelModeAllowedExpr = "COALESCE(pmp.ModeAllowedAmount, pml.ModeAllowedAmount)";
    private const string PanelModePaidExpr = "COALESCE(pmp.ModeInsurancePaymentAmount, pml.ModeInsurancePaymentAmount)";
    private const string PanelModeCountExpr = "COALESCE(pmp.ModeCptCount, pml.ModeCptCount)";

    private const string PanelSelect = $"""
        p.LabId, p.LabName, p.PanelName, p.PayerID, p.PayerDisplayName, p.WindowType,
        p.StartDate, p.EndDate, p.AsOfDateTime,
        p.AvgChargeAmount, p.AvgAllowedAmount, p.AvgPaidAmount, p.AvgPatientResponsibility,
        p.MedianPaidAmount, p.P25PaidAmount, p.P75PaidAmount,
        p.PaidLineCount, p.TotalLineCount, p.DeniedLineCount, p.AdjustedLineCount,
        {PanelModeAllowedExpr} AS ModeAllowedAmount,
        {PanelModePaidExpr}    AS ModeInsurancePaymentAmount,
        {PanelModeCountExpr}   AS ModeCptCount,
        CASE WHEN pmp.ModeAllowedAmount IS NOT NULL THEN 'payer'
             WHEN pml.ModeAllowedAmount IS NOT NULL THEN 'lab' END AS ModeMatch
        """;

    private static readonly Dictionary<string, string> CptSortColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        ["cptCode"] = "a.CPTCode",
        ["panelName"] = "a.PanelName",
        ["payerDisplayName"] = "a.PayerDisplayName",
        ["windowType"] = "a.WindowType",
        ["labName"] = "a.LabName",
        ["avgUnits"] = "a.AvgUnits",
        ["avgChargeAmountPerUnit"] = "a.AvgChargeAmountPerUnit",
        ["avgAllowedAmountPerUnit"] = "a.AvgAllowedAmountPerUnit",
        ["avgPaidAmountPerUnit"] = "a.AvgPaidAmountPerUnit",
        ["medianPaidAmount"] = "a.MedianPaidAmount",
        ["paidLineCount"] = "a.PaidLineCount",
        ["totalLineCount"] = "a.TotalLineCount",
        ["deniedLineCount"] = "a.DeniedLineCount",
        ["modeAllowedAmount"] = ModeAllowedExpr,
        ["modeInsurancePaymentAmount"] = ModePaidExpr,
        ["allowedAmountPerUnitMode"] = ModeAllowedUnitExpr,
        ["insurancePaymentPerUnitMode"] = ModePaidUnitExpr,
        ["medianAllowedAmount"] = MedianAllowedExpr,
        ["medianInsurancePaymentAmount"] = MedianPaidExpr,
        ["allowedAmountPerUnitMedian"] = MedianAllowedUnitExpr,
        ["insurancePaymentPerUnitMedian"] = MedianPaidUnitExpr,
        // Sorting by a computed rate needs the expression, not an alias.
        ["denialRate"] = "CASE WHEN ISNULL(a.TotalLineCount,0) > 0 THEN (CAST(ISNULL(a.DeniedLineCount,0) AS DECIMAL(18,4)) * 100) / a.TotalLineCount END"
    };

    private static readonly Dictionary<string, string> PanelSortColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        ["panelName"] = "p.PanelName",
        ["payerId"] = "p.PayerID",
        ["payerDisplayName"] = "p.PayerDisplayName",
        ["windowType"] = "p.WindowType",
        ["labName"] = "p.LabName",
        ["avgChargeAmount"] = "p.AvgChargeAmount",
        ["avgAllowedAmount"] = "p.AvgAllowedAmount",
        ["avgPaidAmount"] = "p.AvgPaidAmount",
        ["medianPaidAmount"] = "p.MedianPaidAmount",
        ["p25PaidAmount"] = "p.P25PaidAmount",
        ["p75PaidAmount"] = "p.P75PaidAmount",
        ["paidLineCount"] = "p.PaidLineCount",
        ["totalLineCount"] = "p.TotalLineCount",
        ["deniedLineCount"] = "p.DeniedLineCount",
        ["modeAllowedAmount"] = PanelModeAllowedExpr,
        ["modeInsurancePaymentAmount"] = PanelModePaidExpr,
        ["modeCptCount"] = PanelModeCountExpr,
        ["denialRate"] = "CASE WHEN ISNULL(p.TotalLineCount,0) > 0 THEN (CAST(ISNULL(p.DeniedLineCount,0) AS DECIMAL(18,4)) * 100) / p.TotalLineCount END"
    };

    // Autocomplete field -> real column, per tab (whitelist; never interpolated from user input).
    private static readonly Dictionary<string, string> CptFilterFields = new(StringComparer.OrdinalIgnoreCase)
    {
        ["cptCode"] = "CPTCode",
        ["panelName"] = "PanelName",
        ["payer"] = "PayerDisplayName"
    };

    private static readonly Dictionary<string, string> PanelFilterFields = new(StringComparer.OrdinalIgnoreCase)
    {
        ["panelName"] = "PanelName",
        ["payer"] = "PayerDisplayName"
    };

    // ── public surface ───────────────────────────────────────────────────────

    public async Task<LookupResult<CptLookupRow>> GetCptAsync(LookupQuery query, CancellationToken ct)
    {
        Normalise(query, MaxPageSize);
        var where = BuildCptWhere(query, out var parameters);
        var orderBy = BuildOrderBy(query, CptSortColumns, "a.CPTCode ASC, a.PanelName ASC, a.WindowType ASC");

        var result = new LookupResult<CptLookupRow> { Page = query.Page, PageSize = query.PageSize };

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);

        var scoped = query.LabId.HasValue;

        // Count and KPI totals in one round trip — the KPI row describes every matching row,
        // not just the page currently on screen.
        //
        // No rate CTEs here: every aggregate reads CPTAverage and so does every filter, and
        // each rate CTE groups by exactly the columns it joins on, so the LEFT JOINs are 1:1
        // and cannot change a COUNT, an AVG or a SUM. Computing them was pure waste — it
        // aggregated LabModes and LabMedians four times to produce numbers it discarded.
        await using (var summary = new SqlCommand($"""
            SELECT COUNT(1),
                   AVG(a.AvgAllowedAmountPerUnit),
                   AVG(a.AvgPaidAmountPerUnit),
                   SUM(CAST(ISNULL(a.DeniedLineCount,0) AS BIGINT)),
                   SUM(CAST(ISNULL(a.TotalLineCount,0) AS BIGINT))
            FROM dbo.CPTAverage a
            WHERE {where};
            """, conn))
        {
            summary.Parameters.AddRange(Clone(parameters));
            summary.CommandTimeout = 120;
            await using var reader = await summary.ExecuteReaderAsync(ct);
            if (await reader.ReadAsync(ct)) ReadSummary(reader, result);
        }

        // Take the page from CPTAverage FIRST, then join rates to those rows only. Joining
        // before paging made every request hash the whole aggregated rate set against the whole
        // filtered table to then throw away all but one page. Only a sort on a joined rate
        // column has to keep the old order, because the sort key does not exist until the join.
        var pageFirst = !SortsOnJoinedRate(orderBy, "mp.", "ml.", "dp.", "dl.");

        await using var cmd = new SqlCommand(BuildCptPageSql(where, orderBy, scoped, pageFirst), conn);
        cmd.Parameters.AddRange(Clone(parameters));
        cmd.Parameters.AddWithValue("@Offset", (query.Page - 1) * query.PageSize);
        cmd.Parameters.AddWithValue("@PageSize", query.PageSize);
        cmd.CommandTimeout = 120;

        await using var rows = await cmd.ExecuteReaderAsync(ct);
        while (await rows.ReadAsync(ct)) result.Items.Add(MapCpt(rows));
        return result;
    }

    public async Task<LookupResult<PanelLookupRow>> GetPanelAsync(LookupQuery query, CancellationToken ct)
    {
        Normalise(query, MaxPageSize);
        var where = BuildPanelWhere(query, out var parameters);
        var orderBy = BuildOrderBy(query, PanelSortColumns, "p.PanelName ASC, p.PayerDisplayName ASC, p.WindowType ASC");

        var result = new LookupResult<PanelLookupRow> { Page = query.Page, PageSize = query.PageSize };

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);

        // The summary needs no mode CTEs — it only aggregates PanelAverage's own columns.
        await using (var summary = new SqlCommand($"""
            SELECT COUNT(1),
                   AVG(p.AvgAllowedAmount),
                   AVG(p.AvgPaidAmount),
                   SUM(CAST(ISNULL(p.DeniedLineCount,0) AS BIGINT)),
                   SUM(CAST(ISNULL(p.TotalLineCount,0) AS BIGINT))
            FROM dbo.PanelAverage p
            WHERE {where};
            """, conn))
        {
            summary.Parameters.AddRange(Clone(parameters));
            summary.CommandTimeout = 120;
            await using var reader = await summary.ExecuteReaderAsync(ct);
            if (await reader.ReadAsync(ct)) ReadSummary(reader, result);
        }

        // Same shape as the CPT tab: page PanelAverage first, then join modes to that page.
        var scoped = query.LabId.HasValue;
        var pageFirst = !SortsOnJoinedRate(orderBy, "pmp.", "pml.");

        await using var cmd = new SqlCommand(BuildPanelPageSql(where, orderBy, scoped, pageFirst), conn);
        cmd.Parameters.AddRange(Clone(parameters));
        cmd.Parameters.AddWithValue("@Offset", (query.Page - 1) * query.PageSize);
        cmd.Parameters.AddWithValue("@PageSize", query.PageSize);
        cmd.CommandTimeout = 120;

        await using var rows = await cmd.ExecuteReaderAsync(ct);
        while (await rows.ReadAsync(ct)) result.Items.Add(MapPanel(rows));
        return result;
    }

    public async Task<IReadOnlyList<CptLookupRow>> GetCptWindowsAsync(
        int labId, string cptCode, string? panelName, string? payer, CancellationToken ct)
    {
        var parts = new List<string> { "a.LabID = @LabId", "a.CPTCode = @CptCode" };
        var parameters = new List<SqlParameter>
        {
            new("@LabId", labId),
            new("@CptCode", cptCode)
        };
        AddExact(parts, parameters, "a.PanelName", "@PanelName", panelName);
        AddExact(parts, parameters, "a.PayerDisplayName", "@Payer", payer);

        var items = new List<CptLookupRow>();
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand($"""
            WITH {RateCteBody(scopedToLab: true)}
            SELECT {CptSelect}
            {CptFrom}
            WHERE {string.Join(" AND ", parts)}
            ORDER BY a.WindowType;
            """, conn);
        cmd.Parameters.AddRange(parameters.ToArray());
        cmd.CommandTimeout = 120;
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) items.Add(MapCpt(reader));
        return items;
    }

    public async Task<IReadOnlyList<PanelLookupRow>> GetPanelWindowsAsync(
        int labId, string panelName, string? payer, CancellationToken ct)
    {
        var parts = new List<string> { "p.LabId = @LabId", "p.PanelName = @PanelName" };
        var parameters = new List<SqlParameter>
        {
            new("@LabId", labId),
            new("@PanelName", panelName)
        };
        AddExact(parts, parameters, "p.PayerDisplayName", "@Payer", payer);

        var items = new List<PanelLookupRow>();
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand($"""
            WITH {PanelModeCteBody(scopedToLab: true)}
            SELECT {PanelSelect}
            {PanelFrom}
            WHERE {string.Join(" AND ", parts)}
            ORDER BY p.WindowType;
            """, conn);
        cmd.Parameters.AddRange(parameters.ToArray());
        cmd.CommandTimeout = 120;
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) items.Add(MapPanel(reader));
        return items;
    }

    /// <summary>Row ceiling for one export. Exposed so LRN.ReportWorker can report truncation.</summary>
    public static int MaxExportRows => ExportRowCap;

    public async Task<byte[]> ExportCptAsync(LookupQuery query, CancellationToken ct)
        => BuildCptExcel(await ReadCptExportRowsAsync(query, ct));

    public async Task<byte[]> ExportPanelAsync(LookupQuery query, CancellationToken ct)
        => BuildPanelExcel(await ReadPanelExportRowsAsync(query, ct));

    // Read and build are split so the background generator in LRN.ReportWorker can count the
    // rows it wrote (and notice it hit the cap) while still producing byte-identical workbooks
    // to the synchronous endpoint — the column set lives here only.
    public async Task<IReadOnlyList<CptLookupRow>> ReadCptExportRowsAsync(LookupQuery query, CancellationToken ct)
    {
        query.Page = 1;
        query.PageSize = ExportRowCap;
        return (await GetCptAsync(query, ct)).Items;
    }

    public async Task<IReadOnlyList<PanelLookupRow>> ReadPanelExportRowsAsync(LookupQuery query, CancellationToken ct)
    {
        query.Page = 1;
        query.PageSize = ExportRowCap;
        return (await GetPanelAsync(query, ct)).Items;
    }

    public static byte[] BuildCptExcel(IReadOnlyList<CptLookupRow> rows)
        => BuildExcel("CPT Lookup", CptExcelColumns, rows);

    public static byte[] BuildPanelExcel(IReadOnlyList<PanelLookupRow> rows)
        => BuildExcel("Panel Lookup", PanelExcelColumns, rows);

    public Task<IReadOnlyList<string>> GetCptOptionsAsync(string? field, string? term, int? labId, CancellationToken ct)
        => GetOptionsAsync("dbo.CPTAverage", CptFilterFields, "LabID", field, term, labId, ct);

    public Task<IReadOnlyList<string>> GetPanelOptionsAsync(string? field, string? term, int? labId, CancellationToken ct)
        => GetOptionsAsync("dbo.PanelAverage", PanelFilterFields, "LabId", field, term, labId, ct);

    /// <summary>
    /// Labs that have averages data. LabName is not unique across the source
    /// tables (two different LabIds both spell themselves "NorthWest"), so the
    /// id stays the value and the name is only the label.
    /// </summary>
    public async Task<IReadOnlyList<MasterValueLabOption>> GetLabsAsync(CancellationToken ct)
    {
        var labs = new List<MasterValueLabOption>();
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT LabId, MAX(LabName) AS LabName FROM (
                SELECT DISTINCT LabID AS LabId, LabName FROM dbo.CPTAverage   WHERE LabID IS NOT NULL
                UNION
                SELECT DISTINCT LabId,          LabName FROM dbo.PanelAverage WHERE LabId IS NOT NULL
            ) x
            GROUP BY LabId
            ORDER BY LabName, LabId;
            """, conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            labs.Add(new MasterValueLabOption
            {
                LabId = reader.GetInt32(0),
                LabName = reader.IsDBNull(1) ? $"Lab {reader.GetInt32(0)}" : reader.GetString(1)
            });
        return labs;
    }

    // ── internals ────────────────────────────────────────────────────────────

    private static void Normalise(LookupQuery q, int maxPageSize)
    {
        q.Page = Math.Max(1, q.Page);
        q.PageSize = Math.Clamp(q.PageSize <= 0 ? 50 : q.PageSize, 10, maxPageSize);
    }

    private static void ReadSummary<T>(SqlDataReader reader, LookupResult<T> result)
    {
        result.TotalCount = reader.IsDBNull(0) ? 0 : reader.GetInt32(0);
        var denied = reader.IsDBNull(3) ? 0L : reader.GetInt64(3);
        var total = reader.IsDBNull(4) ? 0L : reader.GetInt64(4);
        result.Summary = new LookupSummary
        {
            RowCount = result.TotalCount,
            AvgAllowed = reader.IsDBNull(1) ? null : Math.Round(reader.GetDecimal(1), 2),
            AvgPaid = reader.IsDBNull(2) ? null : Math.Round(reader.GetDecimal(2), 2),
            DenialRate = total > 0 ? Math.Round(denied * 100m / total, 1) : null
        };
    }

    private static string BuildCptWhere(LookupQuery q, out List<SqlParameter> p)
    {
        var parts = new List<string> { "1=1" };
        p = new List<SqlParameter>();
        AddLike(parts, p, "a.CPTCode", "@CptCode", q.CptCode);
        AddLike(parts, p, "a.PanelName", "@PanelName", q.PanelName);
        AddLike(parts, p, "a.PayerDisplayName", "@Payer", q.Payer);
        AddExact(parts, p, "a.WindowType", "@WindowType", q.WindowType);
        if (q.LabId.HasValue)
        {
            parts.Add("a.LabID = @LabId");
            p.Add(new SqlParameter("@LabId", q.LabId.Value));
        }
        return string.Join(" AND ", parts);
    }

    private static string BuildPanelWhere(LookupQuery q, out List<SqlParameter> p)
    {
        var parts = new List<string> { "1=1" };
        p = new List<SqlParameter>();
        AddLike(parts, p, "p.PanelName", "@PanelName", q.PanelName);
        AddLike(parts, p, "p.PayerDisplayName", "@Payer", q.Payer);
        AddExact(parts, p, "p.WindowType", "@WindowType", q.WindowType);
        if (q.LabId.HasValue)
        {
            parts.Add("p.LabId = @LabId");
            p.Add(new SqlParameter("@LabId", q.LabId.Value));
        }
        return string.Join(" AND ", parts);
    }

    private static string BuildOrderBy(LookupQuery q, IReadOnlyDictionary<string, string> columns, string fallback)
    {
        if (string.IsNullOrWhiteSpace(q.SortColumn) || !columns.TryGetValue(q.SortColumn.Trim(), out var column))
            return fallback;
        var direction = string.Equals(q.SortDirection, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC";
        return $"{column} {direction}";
    }

    private async Task<IReadOnlyList<string>> GetOptionsAsync(
        string table, IReadOnlyDictionary<string, string> fields, string labColumn,
        string? field, string? term, int? labId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(field) || !fields.TryGetValue(field.Trim(), out var column))
            return Array.Empty<string>();

        var where = new List<string> { $"{column} IS NOT NULL", $"{column} <> ''" };
        var parameters = new List<SqlParameter>();
        if (!string.IsNullOrWhiteSpace(term))
        {
            where.Add($"{column} LIKE @Term ESCAPE '\\'");
            parameters.Add(new SqlParameter("@Term", LikePattern(term)));
        }
        if (labId.HasValue)
        {
            where.Add($"{labColumn} = @LabId");
            parameters.Add(new SqlParameter("@LabId", labId.Value));
        }

        var values = new List<string>();
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand($"""
            SELECT DISTINCT TOP ({FilterOptionCap}) {column}
            FROM {table}
            WHERE {string.Join(" AND ", where)}
            ORDER BY {column};
            """, conn);
        cmd.Parameters.AddRange(parameters.ToArray());
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) values.Add(reader.GetString(0));
        return values;
    }

    private static void AddLike(List<string> parts, List<SqlParameter> p, string column, string name, string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        parts.Add($"{column} LIKE {name} ESCAPE '\\'");
        p.Add(new SqlParameter(name, LikePattern(value)));
    }

    private static void AddExact(List<string> parts, List<SqlParameter> p, string column, string name, string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        parts.Add($"{column} = {name}");
        p.Add(new SqlParameter(name, value.Trim()));
    }

    private static string LikePattern(string value)
        => "%" + value.Trim()
            .Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("%", "\\%", StringComparison.Ordinal)
            .Replace("_", "\\_", StringComparison.Ordinal)
            .Replace("[", "\\[", StringComparison.Ordinal) + "%";

    private static SqlParameter[] Clone(IEnumerable<SqlParameter> source)
        => source.Select(x => new SqlParameter(x.ParameterName, x.Value)).ToArray();

    private static CptLookupRow MapCpt(SqlDataReader r) => new()
    {
        LabId = Int(r, "LabID"),
        LabName = Str(r, "LabName"),
        CptCode = Str(r, "CPTCode"),
        PanelName = Str(r, "PanelName"),
        PayerDisplayName = Str(r, "PayerDisplayName"),
        PayerCommonCode = Str(r, "PayerCommonCode"),
        GlobalPayerId = Int(r, "Global_Payer_ID"),
        WindowType = Str(r, "WindowType"),
        StartDate = Date(r, "StartDate"),
        EndDate = Date(r, "EndDate"),
        AsOfDate = Date(r, "AsOfDateTime"),
        AvgUnits = Int(r, "AvgUnits"),
        AvgChargeAmountPerUnit = Dec(r, "AvgChargeAmountPerUnit"),
        AvgAllowedAmountPerUnit = Dec(r, "AvgAllowedAmountPerUnit"),
        AvgPaidAmountPerUnit = Dec(r, "AvgPaidAmountPerUnit"),
        AvgPatientResponsibilityPerUnit = Dec(r, "AvgPatientResponsibilityPerUnit"),
        MedianPaidAmount = Dec(r, "MedianPaidAmount"),
        P25PaidAmount = Dec(r, "P25PaidAmount"),
        P75PaidAmount = Dec(r, "P75PaidAmount"),
        PaidLineCount = Int(r, "PaidLineCount"),
        TotalLineCount = Int(r, "TotalLineCount"),
        DeniedLineCount = Int(r, "DeniedLineCount"),
        AdjustedLineCount = Int(r, "AdjustedLineCount"),
        ModeAllowedAmount = Dec(r, "ModeAllowedAmount"),
        ModeInsurancePaymentAmount = Dec(r, "ModeInsurancePaymentAmount"),
        AllowedAmountPerUnitMode = Dec(r, "AllowedAmountPerUnitMode"),
        InsurancePaymentPerUnitMode = Dec(r, "InsurancePaymentPerUnitMode"),
        MedianAllowedAmount = Dec(r, "MedianAllowedAmount"),
        MedianInsurancePaymentAmount = Dec(r, "MedianInsurancePaymentAmount"),
        AllowedAmountPerUnitMedian = Dec(r, "AllowedAmountPerUnitMedian"),
        InsurancePaymentPerUnitMedian = Dec(r, "InsurancePaymentPerUnitMedian"),
        ModeMatch = Str(r, "ModeMatch"),
        MedianMatch = Str(r, "MedianMatch")
    };

    private static PanelLookupRow MapPanel(SqlDataReader r) => new()
    {
        LabId = Int(r, "LabId"),
        LabName = Str(r, "LabName"),
        PanelName = Str(r, "PanelName"),
        PayerId = Str(r, "PayerID"),
        PayerDisplayName = Str(r, "PayerDisplayName"),
        WindowType = Str(r, "WindowType"),
        StartDate = Date(r, "StartDate"),
        EndDate = Date(r, "EndDate"),
        AsOfDate = Date(r, "AsOfDateTime"),
        AvgChargeAmount = Dec(r, "AvgChargeAmount"),
        AvgAllowedAmount = Dec(r, "AvgAllowedAmount"),
        AvgPaidAmount = Dec(r, "AvgPaidAmount"),
        AvgPatientResponsibility = Dec(r, "AvgPatientResponsibility"),
        MedianPaidAmount = Dec(r, "MedianPaidAmount"),
        P25PaidAmount = Dec(r, "P25PaidAmount"),
        P75PaidAmount = Dec(r, "P75PaidAmount"),
        PaidLineCount = Int(r, "PaidLineCount"),
        TotalLineCount = Int(r, "TotalLineCount"),
        DeniedLineCount = Int(r, "DeniedLineCount"),
        AdjustedLineCount = Int(r, "AdjustedLineCount"),
        ModeAllowedAmount = Dec(r, "ModeAllowedAmount"),
        ModeInsurancePaymentAmount = Dec(r, "ModeInsurancePaymentAmount"),
        ModeCptCount = Int(r, "ModeCptCount"),
        ModeMatch = Str(r, "ModeMatch")
    };

    private const string Money = "$#,##0.00";
    private const string Whole = "#,##0";
    private const string Rate = "0.0\"%\"";

    private sealed record ExcelCol<T>(string Header, Func<T, object?> Value, string? Format = null);

    private static readonly ExcelCol<CptLookupRow>[] CptExcelColumns =
    {
        new("Lab", x => x.LabName),
        new("CPT Code", x => x.CptCode),
        new("Panel", x => x.PanelName),
        new("Payer", x => x.PayerDisplayName),
        new("Payer Code", x => x.PayerCommonCode),
        new("Window", x => x.WindowType),
        new("Start Date", x => x.StartDate?.ToString("yyyy-MM-dd")),
        new("End Date", x => x.EndDate?.ToString("yyyy-MM-dd")),
        new("Avg Units", x => x.AvgUnits, Whole),
        new("Avg Charge / Unit", x => x.AvgChargeAmountPerUnit, Money),
        new("Avg Allowed / Unit", x => x.AvgAllowedAmountPerUnit, Money),
        new("Avg Paid / Unit", x => x.AvgPaidAmountPerUnit, Money),
        new("Median Paid", x => x.MedianPaidAmount, Money),
        new("P25 Paid", x => x.P25PaidAmount, Money),
        new("P75 Paid", x => x.P75PaidAmount, Money),
        new("Mode Allowed", x => x.ModeAllowedAmount, Money),
        new("Mode Insurance Paid", x => x.ModeInsurancePaymentAmount, Money),
        new("Allowed / Unit (Mode)", x => x.AllowedAmountPerUnitMode, Money),
        new("Insurance Paid / Unit (Mode)", x => x.InsurancePaymentPerUnitMode, Money),
        new("Mode Source", x => MatchLabel(x.ModeMatch)),
        new("Median Allowed", x => x.MedianAllowedAmount, Money),
        new("Median Insurance Paid", x => x.MedianInsurancePaymentAmount, Money),
        new("Allowed / Unit (Median)", x => x.AllowedAmountPerUnitMedian, Money),
        new("Insurance Paid / Unit (Median)", x => x.InsurancePaymentPerUnitMedian, Money),
        new("Median Source", x => MatchLabel(x.MedianMatch)),
        new("Paid Lines", x => x.PaidLineCount, Whole),
        new("Total Lines", x => x.TotalLineCount, Whole),
        new("Denied Lines", x => x.DeniedLineCount, Whole),
        new("Denial Rate", x => x.DenialRate, Rate)
    };

    private static readonly ExcelCol<PanelLookupRow>[] PanelExcelColumns =
    {
        new("Lab", x => x.LabName),
        new("Panel", x => x.PanelName),
        new("Payer ID", x => x.PayerId),
        new("Payer", x => x.PayerDisplayName),
        new("Window", x => x.WindowType),
        new("Start Date", x => x.StartDate?.ToString("yyyy-MM-dd")),
        new("End Date", x => x.EndDate?.ToString("yyyy-MM-dd")),
        new("Avg Charge", x => x.AvgChargeAmount, Money),
        new("Avg Allowed", x => x.AvgAllowedAmount, Money),
        new("Avg Paid", x => x.AvgPaidAmount, Money),
        new("Avg Patient Responsibility", x => x.AvgPatientResponsibility, Money),
        new("Median Paid", x => x.MedianPaidAmount, Money),
        new("P25 Paid", x => x.P25PaidAmount, Money),
        new("P75 Paid", x => x.P75PaidAmount, Money),
        new("Mode Allowed (avg of CPT modes)", x => x.ModeAllowedAmount, Money),
        new("Mode Insurance Paid (avg of CPT modes)", x => x.ModeInsurancePaymentAmount, Money),
        new("Mode CPT Count", x => x.ModeCptCount, Whole),
        new("Mode Source", x => MatchLabel(x.ModeMatch)),
        new("Paid Lines", x => x.PaidLineCount, Whole),
        new("Total Lines", x => x.TotalLineCount, Whole),
        new("Denied Lines", x => x.DeniedLineCount, Whole),
        new("Denial Rate", x => x.DenialRate, Rate)
    };

    /// <summary>Spells out the payer/lab fallback in exports, where a tooltip cannot.</summary>
    private static string? MatchLabel(string? match) => match switch
    {
        "payer" => "Payer-specific",
        "lab" => "Lab-wide (no payer match)",
        _ => null
    };

    private static byte[] BuildExcel<T>(string sheetName, IReadOnlyList<ExcelCol<T>> cols, IReadOnlyList<T> rows)
    {
        using var workbook = new XLWorkbook();
        var ws = workbook.Worksheets.Add(sheetName);

        for (var c = 0; c < cols.Count; c++) ws.Cell(1, c + 1).Value = cols[c].Header;
        var header = ws.Range(1, 1, 1, cols.Count);
        header.Style.Font.Bold = true;
        header.Style.Font.FontColor = XLColor.White;
        header.Style.Fill.BackgroundColor = XLColor.FromHtml("#1F2937");

        for (var r = 0; r < rows.Count; r++)
        {
            for (var c = 0; c < cols.Count; c++)
            {
                var cell = ws.Cell(r + 2, c + 1);
                switch (cols[c].Value(rows[r]))
                {
                    case null: break;
                    case decimal d: cell.Value = d; break;
                    case int i: cell.Value = i; break;
                    case var v: cell.Value = v.ToString(); break;
                }
                if (cols[c].Format is { } format) cell.Style.NumberFormat.Format = format;
            }
        }

        ws.SheetView.FreezeRows(1);
        ws.RangeUsed()?.SetAutoFilter();
        // AdjustToContents over huge exports is slow; sizing on a sample keeps it fast.
        ws.Columns(1, cols.Count).AdjustToContents(1, Math.Min(rows.Count + 1, 250));

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private static string? Str(SqlDataReader r, string c) => r.IsDBNull(r.GetOrdinal(c)) ? null : r.GetString(r.GetOrdinal(c));
    private static int? Int(SqlDataReader r, string c) => r.IsDBNull(r.GetOrdinal(c)) ? null : r.GetInt32(r.GetOrdinal(c));
    private static decimal? Dec(SqlDataReader r, string c) => r.IsDBNull(r.GetOrdinal(c)) ? null : r.GetDecimal(r.GetOrdinal(c));
    private static DateTime? Date(SqlDataReader r, string c) => r.IsDBNull(r.GetOrdinal(c)) ? null : r.GetDateTime(r.GetOrdinal(c));
}
