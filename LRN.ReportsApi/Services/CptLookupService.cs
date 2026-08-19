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

    /// <summary>Timeout for a normal UI page.</summary>
    private const int PageTimeoutSeconds = 120;

    /// <summary>
    /// Timeout for an export read. An unfiltered export is up to <see cref="ExportRowCap"/> rows
    /// across every lab, payer and window, which does not finish in the page timeout. Safe to be
    /// this generous because the export runs queued in LRN.ReportWorker, not inside a request.
    /// </summary>
    private const int ExportTimeoutSeconds = 1800;
    private const int FilterOptionCap = 100;
    internal const int MaxPageSize = 1000;

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
    //
    // Both lookups read ONE table. dbo.CPTAverage and dbo.PanelAverage each carry their
    // own mode and median columns, written by LRN.AveragesImport from the lab's line and
    // claim data, so there is nothing to join.
    //
    // This previously joined dbo.LabModes and dbo.LabMedians through four aggregating
    // CTEs. That was removed for two reasons: the figures are now duplicated on the
    // averages row itself, and the join did not scale. A CTE is inlined rather than
    // materialised, and the optimiser put the aggregation on the inner side of a nested
    // loop, so a 394k-row heap was re-aggregated once per page row — measured at 58s for
    // a single 500-row panel page against 524ms for the same CTEs evaluated once. Reading
    // the columns directly makes the page a plain indexed range scan.
    //
    // Gone with the joins: the per-unit mode/median columns (they only ever existed in
    // LabModes/LabMedians), ModeMatch/MedianMatch (no payer-vs-lab fallback remains — the
    // value belongs to the row), and ModeCptCount (panel modes are no longer an average
    // of per-CPT modes).

    private const string CptFrom = "FROM dbo.CPTAverage a";

    /// <summary>The same projection driven by one page of CPTAverage rather than all of it.</summary>
    private const string CptFromPage = "FROM page a";

    /// <summary>The CPT page query. Separated from the I/O so its SQL can be inspected and parsed in isolation.</summary>
    private static string BuildCptPageSql(string where, string orderBy) => $"""
        SELECT {CptSelect}
        {CptFrom}
        WHERE {where}
        ORDER BY {orderBy}
        OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
        """;

    /// <summary>The Panel page query. Same shape.</summary>
    private static string BuildPanelPageSql(string where, string orderBy) => $"""
        SELECT {PanelSelect}
        {PanelFrom}
        WHERE {where}
        ORDER BY {orderBy}
        OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
        """;

    // MedianPaidAmount is projected twice on purpose: the grid labels it "Median paid" and
    // the mode/median block labels the same figure "Median ins. paid". One column, two
    // names the UI already uses.
    private const string CptSelect = """
        a.LabID, a.LabName, a.CPTCode, a.PanelName, a.PayerDisplayName, a.PayerCommonCode,
        a.Global_Payer_ID, a.WindowType, a.WindowBasis, a.StartDate, a.EndDate, a.AsOfDateTime,
        a.AvgUnits, a.AvgChargeAmountPerUnit, a.AvgAllowedAmountPerUnit, a.AvgPaidAmountPerUnit,
        a.AvgPatientResponsibilityPerUnit, a.AvgPatientPaidAmountPerUnit,
        a.MedianPaidAmount, a.P25PaidAmount, a.P75PaidAmount,
        a.PaidLineCount, a.TotalLineCount, a.DeniedLineCount, a.AdjustedLineCount,
        a.ModeAllowedAmount,
        a.ModePaidAmount     AS ModeInsurancePaymentAmount,
        a.MedianAllowedAmount,
        a.MedianPaidAmount   AS MedianInsurancePaymentAmount
        """;

    private const string PanelFrom = "FROM dbo.PanelAverage p";

    private const string PanelFromPage = "FROM page p";

    private const string PanelSelect = """
        p.LabId, p.LabName, p.PanelName, p.PayerID, p.PayerDisplayName, p.WindowType, p.WindowBasis,
        p.StartDate, p.EndDate, p.AsOfDateTime,
        p.AvgChargeAmount, p.AvgAllowedAmount, p.AvgPaidAmount, p.AvgPatientResponsibility,
        p.AvgPatientPaidAmount,
        p.MedianPaidAmount, p.P25PaidAmount, p.P75PaidAmount,
        p.PaidLineCount, p.TotalLineCount, p.DeniedLineCount, p.AdjustedLineCount,
        p.ModeAllowedAmount,
        p.ModePaidAmount     AS ModeInsurancePaymentAmount,
        p.MedianAllowedAmount
        """;

    private static readonly Dictionary<string, string> CptSortColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        ["cptCode"] = "a.CPTCode",
        ["panelName"] = "a.PanelName",
        ["payerDisplayName"] = "a.PayerDisplayName",
        ["windowType"] = "a.WindowType",
        ["windowBasis"] = "a.WindowBasis",
        ["labName"] = "a.LabName",
        ["avgUnits"] = "a.AvgUnits",
        ["startDate"] = "a.StartDate",
        ["endDate"] = "a.EndDate",
        ["avgChargeAmountPerUnit"] = "a.AvgChargeAmountPerUnit",
        ["avgAllowedAmountPerUnit"] = "a.AvgAllowedAmountPerUnit",
        ["avgPaidAmountPerUnit"] = "a.AvgPaidAmountPerUnit",
        ["avgPatientResponsibilityPerUnit"] = "a.AvgPatientResponsibilityPerUnit",
        ["avgPatientPaidAmountPerUnit"] = "a.AvgPatientPaidAmountPerUnit",
        ["medianPaidAmount"] = "a.MedianPaidAmount",
        ["p25PaidAmount"] = "a.P25PaidAmount",
        ["p75PaidAmount"] = "a.P75PaidAmount",
        ["paidLineCount"] = "a.PaidLineCount",
        ["totalLineCount"] = "a.TotalLineCount",
        ["deniedLineCount"] = "a.DeniedLineCount",
        ["adjustedLineCount"] = "a.AdjustedLineCount",
        // Plain CPTAverage columns now, so every sort is indexable rather than a sort
        // over a joined expression.
        ["modeAllowedAmount"] = "a.ModeAllowedAmount",
        ["modeInsurancePaymentAmount"] = "a.ModePaidAmount",
        ["medianAllowedAmount"] = "a.MedianAllowedAmount",
        ["medianInsurancePaymentAmount"] = "a.MedianPaidAmount",
        // Sorting by a computed rate needs the expression, not an alias.
        ["denialRate"] = "CASE WHEN ISNULL(a.TotalLineCount,0) > 0 THEN (CAST(ISNULL(a.DeniedLineCount,0) AS DECIMAL(18,4)) * 100) / a.TotalLineCount END"
    };

    private static readonly Dictionary<string, string> PanelSortColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        ["panelName"] = "p.PanelName",
        ["payerId"] = "p.PayerID",
        ["payerDisplayName"] = "p.PayerDisplayName",
        ["windowType"] = "p.WindowType",
        ["windowBasis"] = "p.WindowBasis",
        ["labName"] = "p.LabName",
        ["startDate"] = "p.StartDate",
        ["endDate"] = "p.EndDate",
        ["avgPatientResponsibility"] = "p.AvgPatientResponsibility",
        ["avgPatientPaidAmount"] = "p.AvgPatientPaidAmount",
        ["adjustedLineCount"] = "p.AdjustedLineCount",
        ["avgChargeAmount"] = "p.AvgChargeAmount",
        ["avgAllowedAmount"] = "p.AvgAllowedAmount",
        ["avgPaidAmount"] = "p.AvgPaidAmount",
        ["medianPaidAmount"] = "p.MedianPaidAmount",
        ["p25PaidAmount"] = "p.P25PaidAmount",
        ["p75PaidAmount"] = "p.P75PaidAmount",
        ["paidLineCount"] = "p.PaidLineCount",
        ["totalLineCount"] = "p.TotalLineCount",
        ["deniedLineCount"] = "p.DeniedLineCount",
        ["modeAllowedAmount"] = "p.ModeAllowedAmount",
        ["modeInsurancePaymentAmount"] = "p.ModePaidAmount",
        ["medianAllowedAmount"] = "p.MedianAllowedAmount",
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

    public Task<LookupResult<CptLookupRow>> GetCptAsync(LookupQuery query, CancellationToken ct)
        => GetCptAsync(query, MaxPageSize, PageTimeoutSeconds, ct);

    /// <summary>
    /// <paramref name="maxPageSize"/> is passed in rather than always being MaxPageSize because
    /// the export needs a whole workbook in one read. Clamping it to the UI's 1,000-row page
    /// limit silently truncated every export to 1,000 rows.
    /// </summary>
    private async Task<LookupResult<CptLookupRow>> GetCptAsync(
        LookupQuery query, int maxPageSize, int commandTimeoutSeconds, CancellationToken ct)
    {
        Normalise(query, maxPageSize);
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
            summary.CommandTimeout = commandTimeoutSeconds;
            await using var reader = await summary.ExecuteReaderAsync(ct);
            if (await reader.ReadAsync(ct)) ReadSummary(reader, result);
        }

        // One table, so the page is a straight ORDER BY + OFFSET/FETCH. The old page-first /
        // join-first split existed only to keep the rate joins off the whole filtered set;
        // with no joins left there is nothing to order around.
        await using var cmd = new SqlCommand(BuildCptPageSql(where, orderBy), conn);
        cmd.Parameters.AddRange(Clone(parameters));
        cmd.Parameters.AddWithValue("@Offset", (query.Page - 1) * query.PageSize);
        cmd.Parameters.AddWithValue("@PageSize", query.PageSize);
        cmd.CommandTimeout = commandTimeoutSeconds;

        await using var rows = await cmd.ExecuteReaderAsync(ct);
        while (await rows.ReadAsync(ct)) result.Items.Add(MapCpt(rows));
        return result;
    }

    public Task<LookupResult<PanelLookupRow>> GetPanelAsync(LookupQuery query, CancellationToken ct)
        => GetPanelAsync(query, MaxPageSize, PageTimeoutSeconds, ct);

    /// <summary>See the CPT overload — the export reads far beyond one UI page.</summary>
    private async Task<LookupResult<PanelLookupRow>> GetPanelAsync(
        LookupQuery query, int maxPageSize, int commandTimeoutSeconds, CancellationToken ct)
    {
        Normalise(query, maxPageSize);
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
            summary.CommandTimeout = commandTimeoutSeconds;
            await using var reader = await summary.ExecuteReaderAsync(ct);
            if (await reader.ReadAsync(ct)) ReadSummary(reader, result);
        }

        // Same shape as the CPT tab: a single-table page, no joins.
        await using var cmd = new SqlCommand(BuildPanelPageSql(where, orderBy), conn);
        cmd.Parameters.AddRange(Clone(parameters));
        cmd.Parameters.AddWithValue("@Offset", (query.Page - 1) * query.PageSize);
        cmd.Parameters.AddWithValue("@PageSize", query.PageSize);
        cmd.CommandTimeout = commandTimeoutSeconds;

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
            SELECT {CptSelect}
            {CptFrom}
            WHERE {string.Join(" AND ", parts)}
            ORDER BY a.WindowType;
            """, conn);
        cmd.Parameters.AddRange(parameters.ToArray());
        cmd.CommandTimeout = PageTimeoutSeconds;
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
            SELECT {PanelSelect}
            {PanelFrom}
            WHERE {string.Join(" AND ", parts)}
            ORDER BY p.WindowType;
            """, conn);
        cmd.Parameters.AddRange(parameters.ToArray());
        cmd.CommandTimeout = PageTimeoutSeconds;
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
        // ExportRowCap, not MaxPageSize: routing through the public overload clamped the export
        // to the UI's 1,000-row page limit, so every export silently lost everything after row 1,000.
        return (await GetCptAsync(query, ExportRowCap, ExportTimeoutSeconds, ct)).Items;
    }

    public async Task<IReadOnlyList<PanelLookupRow>> ReadPanelExportRowsAsync(LookupQuery query, CancellationToken ct)
    {
        query.Page = 1;
        query.PageSize = ExportRowCap;
        return (await GetPanelAsync(query, ExportRowCap, ExportTimeoutSeconds, ct)).Items;
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

    /// <summary>Internal so the export's page-size contract can be regression-tested.</summary>
    internal static void Normalise(LookupQuery q, int maxPageSize)
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
        WindowBasis = Str(r, "WindowBasis"),
        StartDate = Date(r, "StartDate"),
        EndDate = Date(r, "EndDate"),
        AsOfDate = Date(r, "AsOfDateTime"),
        AvgUnits = Int(r, "AvgUnits"),
        AvgChargeAmountPerUnit = Dec(r, "AvgChargeAmountPerUnit"),
        AvgAllowedAmountPerUnit = Dec(r, "AvgAllowedAmountPerUnit"),
        AvgPaidAmountPerUnit = Dec(r, "AvgPaidAmountPerUnit"),
        AvgPatientResponsibilityPerUnit = Dec(r, "AvgPatientResponsibilityPerUnit"),
        AvgPatientPaidAmountPerUnit = Dec(r, "AvgPatientPaidAmountPerUnit"),
        MedianPaidAmount = Dec(r, "MedianPaidAmount"),
        P25PaidAmount = Dec(r, "P25PaidAmount"),
        P75PaidAmount = Dec(r, "P75PaidAmount"),
        PaidLineCount = Int(r, "PaidLineCount"),
        TotalLineCount = Int(r, "TotalLineCount"),
        DeniedLineCount = Int(r, "DeniedLineCount"),
        AdjustedLineCount = Int(r, "AdjustedLineCount"),
        ModeAllowedAmount = Dec(r, "ModeAllowedAmount"),
        ModeInsurancePaymentAmount = Dec(r, "ModeInsurancePaymentAmount"),
        MedianAllowedAmount = Dec(r, "MedianAllowedAmount"),
        MedianInsurancePaymentAmount = Dec(r, "MedianInsurancePaymentAmount")
    };

    private static PanelLookupRow MapPanel(SqlDataReader r) => new()
    {
        LabId = Int(r, "LabId"),
        LabName = Str(r, "LabName"),
        PanelName = Str(r, "PanelName"),
        PayerId = Str(r, "PayerID"),
        PayerDisplayName = Str(r, "PayerDisplayName"),
        WindowType = Str(r, "WindowType"),
        WindowBasis = Str(r, "WindowBasis"),
        StartDate = Date(r, "StartDate"),
        EndDate = Date(r, "EndDate"),
        AsOfDate = Date(r, "AsOfDateTime"),
        AvgChargeAmount = Dec(r, "AvgChargeAmount"),
        AvgAllowedAmount = Dec(r, "AvgAllowedAmount"),
        AvgPaidAmount = Dec(r, "AvgPaidAmount"),
        AvgPatientResponsibility = Dec(r, "AvgPatientResponsibility"),
        AvgPatientPaidAmount = Dec(r, "AvgPatientPaidAmount"),
        MedianPaidAmount = Dec(r, "MedianPaidAmount"),
        P25PaidAmount = Dec(r, "P25PaidAmount"),
        P75PaidAmount = Dec(r, "P75PaidAmount"),
        PaidLineCount = Int(r, "PaidLineCount"),
        TotalLineCount = Int(r, "TotalLineCount"),
        DeniedLineCount = Int(r, "DeniedLineCount"),
        AdjustedLineCount = Int(r, "AdjustedLineCount"),
        ModeAllowedAmount = Dec(r, "ModeAllowedAmount"),
        ModeInsurancePaymentAmount = Dec(r, "ModeInsurancePaymentAmount"),
        MedianAllowedAmount = Dec(r, "MedianAllowedAmount")
    };

    private const string Money = "$#,##0.00";
    private const string Whole = "#,##0";
    private const string Rate = "0.0\"%\"";

    private sealed record ExcelCol<T>(string Header, Func<T, object?> Value, string? Format = null);

    // Leading columns match the grid's left-to-right order so the workbook reads the same as the
    // screen. The mode/median rates follow: they are not in the CPT grid, but Excel is where the
    // analysis happens, so dropping them from the file would lose data the export already carried.
    private static readonly ExcelCol<CptLookupRow>[] CptExcelColumns =
    {
        new("CPT Code", x => x.CptCode),
        new("Lab Name", x => x.LabName),
        new("Payer Name", x => x.PayerDisplayName),
        new("Panel Name", x => x.PanelName),
        new("Avg Units", x => x.AvgUnits, Whole),
        new("Window Type", x => x.WindowType),
        new("Window Basis", x => x.WindowBasis),
        new("Start DOS", x => x.StartDate?.ToString("yyyy-MM-dd")),
        new("End DOS", x => x.EndDate?.ToString("yyyy-MM-dd")),
        new("Paid Lines", x => x.PaidLineCount, Whole),
        new("Avg Charge / Unit", x => x.AvgChargeAmountPerUnit, Money),
        new("Avg Paid / Unit", x => x.AvgPaidAmountPerUnit, Money),
        new("Avg Allowed / Unit", x => x.AvgAllowedAmountPerUnit, Money),
        new("Avg Patient Responsibility / Unit", x => x.AvgPatientResponsibilityPerUnit, Money),
        new("Avg Patient Paid / Unit", x => x.AvgPatientPaidAmountPerUnit, Money),
        new("Median Paid", x => x.MedianPaidAmount, Money),
        new("P25 Paid", x => x.P25PaidAmount, Money),
        new("P75 Paid", x => x.P75PaidAmount, Money),
        new("Total Lines", x => x.TotalLineCount, Whole),
        new("Denied Lines", x => x.DeniedLineCount, Whole),
        new("Adjusted Lines", x => x.AdjustedLineCount, Whole),
        new("Payer Code", x => x.PayerCommonCode),
        new("Mode Allowed", x => x.ModeAllowedAmount, Money),
        new("Mode Insurance Paid", x => x.ModeInsurancePaymentAmount, Money),
        new("Median Allowed", x => x.MedianAllowedAmount, Money),
        new("Median Insurance Paid", x => x.MedianInsurancePaymentAmount, Money),
        // Line counts moved up into the grid-order block above; only the derived rate is left here.
        new("Denial Rate", x => x.DenialRate, Rate)
    };

    // Mirrors the panel grid's left-to-right order, with the mode columns kept at the end for the
    // same reason as the CPT sheet — see CptExcelColumns.
    private static readonly ExcelCol<PanelLookupRow>[] PanelExcelColumns =
    {
        new("Panel Name", x => x.PanelName),
        new("Lab Name", x => x.LabName),
        new("Payer Name", x => x.PayerDisplayName),
        new("Payer ID", x => x.PayerId),
        new("Window Type", x => x.WindowType),
        new("Window Basis", x => x.WindowBasis),
        new("Start DOS", x => x.StartDate?.ToString("yyyy-MM-dd")),
        new("End DOS", x => x.EndDate?.ToString("yyyy-MM-dd")),
        new("Paid Lines", x => x.PaidLineCount, Whole),
        new("Avg Charge", x => x.AvgChargeAmount, Money),
        new("Avg Paid", x => x.AvgPaidAmount, Money),
        new("Avg Allowed", x => x.AvgAllowedAmount, Money),
        new("Avg Patient Responsibility", x => x.AvgPatientResponsibility, Money),
        new("Avg Patient Paid", x => x.AvgPatientPaidAmount, Money),
        new("Median Paid", x => x.MedianPaidAmount, Money),
        new("P25 Paid", x => x.P25PaidAmount, Money),
        new("P75 Paid", x => x.P75PaidAmount, Money),
        new("Total Lines", x => x.TotalLineCount, Whole),
        new("Denied Lines", x => x.DeniedLineCount, Whole),
        new("Adjusted Lines", x => x.AdjustedLineCount, Whole),
        new("Mode Allowed", x => x.ModeAllowedAmount, Money),
        new("Mode Insurance Paid", x => x.ModeInsurancePaymentAmount, Money),
        new("Median Allowed", x => x.MedianAllowedAmount, Money),
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
