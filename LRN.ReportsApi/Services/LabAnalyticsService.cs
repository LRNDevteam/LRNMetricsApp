using ClosedXML.Excel;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services;

public interface ILabAnalyticsRepository
{
    Task<PagedResult<LabModeDto>> GetModesAsync(LabRateQuery query, CancellationToken ct);
    Task<PagedResult<LabMedianDto>> GetMediansAsync(LabRateQuery query, CancellationToken ct);
    Task<byte[]> ExportModesAsync(LabRateQuery query, CancellationToken ct);
    Task<byte[]> ExportMediansAsync(LabRateQuery query, CancellationToken ct);
    Task<IReadOnlyList<string>> GetModeFilterOptionsAsync(string? field, string? term, int? labId, CancellationToken ct);
    Task<IReadOnlyList<string>> GetMedianFilterOptionsAsync(string? field, string? term, int? labId, CancellationToken ct);
    Task<IReadOnlyList<MasterValueLabOption>> GetLabsAsync(CancellationToken ct);
}

/// <summary>
/// Read-only access to the dbo.LabModes and dbo.LabMedians reference tables in
/// LRNMaster for the Analytics &gt; Modes and Analytics &gt; Meridian list pages.
/// </summary>
public sealed class SqlLabAnalyticsRepository : ILabAnalyticsRepository
{
    private const int ExportRowCap = 100000;
    private const int FilterOptionCap = 100;

    private readonly string _connectionString;

    public SqlLabAnalyticsRepository(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing. It must point to LRNMaster.");
    }

    // ── table metadata ───────────────────────────────────────────────────────

    private const string ModeSelect = """
        PayerName, PanelName, CPTCode, AllowedAmount, InsurancePayment, DistinctAllowedPaymentCount,
        ModeAllowedAmount, ModeInsurancePaymentAmount, AllowedAmountPerUnitMode, InsurancePaymentPerUnitMode, LabName
        """;

    private const string MedianSelect = """
        PayerName, PanelName, CPTCode, AllowedAmount, InsurancePayment, DistinctAllowedPaymentCount,
        MedianAllowedAmount, MedianInsurancePaymentAmount, AllowedAmountPerUnitMedian, InsurancePaymentPerUnitMedian, LabName
        """;

    private static readonly Dictionary<string, string> ModeSortColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        ["payerName"] = "PayerName",
        ["panelName"] = "PanelName",
        ["cptCode"] = "CPTCode",
        ["allowedAmount"] = "AllowedAmount",
        ["insurancePayment"] = "InsurancePayment",
        ["distinctAllowedPaymentCount"] = "DistinctAllowedPaymentCount",
        ["modeAllowedAmount"] = "ModeAllowedAmount",
        ["modeInsurancePaymentAmount"] = "ModeInsurancePaymentAmount",
        ["allowedAmountPerUnitMode"] = "AllowedAmountPerUnitMode",
        ["insurancePaymentPerUnitMode"] = "InsurancePaymentPerUnitMode",
        ["labName"] = "LabName"
    };

    private static readonly Dictionary<string, string> MedianSortColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        ["payerName"] = "PayerName",
        ["panelName"] = "PanelName",
        ["cptCode"] = "CPTCode",
        ["allowedAmount"] = "AllowedAmount",
        ["insurancePayment"] = "InsurancePayment",
        ["distinctAllowedPaymentCount"] = "DistinctAllowedPaymentCount",
        ["medianAllowedAmount"] = "MedianAllowedAmount",
        ["medianInsurancePaymentAmount"] = "MedianInsurancePaymentAmount",
        ["allowedAmountPerUnitMedian"] = "AllowedAmountPerUnitMedian",
        ["insurancePaymentPerUnitMedian"] = "InsurancePaymentPerUnitMedian",
        ["labName"] = "LabName"
    };

    // Autocomplete: query-string field name -> real column (whitelist).
    private static readonly Dictionary<string, string> FilterFields = new(StringComparer.OrdinalIgnoreCase)
    {
        ["payerName"] = "PayerName",
        ["panelName"] = "PanelName",
        ["cptCode"] = "CPTCode"
    };

    private static LabModeDto MapMode(SqlDataReader r) => new()
    {
        PayerName = Str(r, "PayerName"),
        PanelName = Str(r, "PanelName"),
        CptCode = Str(r, "CPTCode"),
        AllowedAmount = Dec(r, "AllowedAmount"),
        InsurancePayment = Dec(r, "InsurancePayment"),
        DistinctAllowedPaymentCount = Int(r, "DistinctAllowedPaymentCount"),
        ModeAllowedAmount = Dec(r, "ModeAllowedAmount"),
        ModeInsurancePaymentAmount = Dec(r, "ModeInsurancePaymentAmount"),
        AllowedAmountPerUnitMode = Dec(r, "AllowedAmountPerUnitMode"),
        InsurancePaymentPerUnitMode = Dec(r, "InsurancePaymentPerUnitMode"),
        LabName = Str(r, "LabName") ?? string.Empty
    };

    private static LabMedianDto MapMedian(SqlDataReader r) => new()
    {
        PayerName = Str(r, "PayerName"),
        PanelName = Str(r, "PanelName"),
        CptCode = Str(r, "CPTCode"),
        AllowedAmount = Dec(r, "AllowedAmount"),
        InsurancePayment = Dec(r, "InsurancePayment"),
        DistinctAllowedPaymentCount = Int(r, "DistinctAllowedPaymentCount"),
        MedianAllowedAmount = Dec(r, "MedianAllowedAmount"),
        MedianInsurancePaymentAmount = Dec(r, "MedianInsurancePaymentAmount"),
        AllowedAmountPerUnitMedian = Dec(r, "AllowedAmountPerUnitMedian"),
        InsurancePaymentPerUnitMedian = Dec(r, "InsurancePaymentPerUnitMedian"),
        LabName = Str(r, "LabName") ?? string.Empty
    };

    private const string Money = "$#,##0.00";
    private const string Whole = "#,##0";

    private sealed record ExcelCol<T>(string Header, Func<T, object?> Value, string? Format = null);

    private static readonly ExcelCol<LabModeDto>[] ModeExcelColumns =
    {
        new("Payer Name", x => x.PayerName),
        new("Panel Name", x => x.PanelName),
        new("CPT Code", x => x.CptCode),
        new("Allowed Amount", x => x.AllowedAmount, Money),
        new("Insurance Payment", x => x.InsurancePayment, Money),
        new("Distinct Allowed Payment Count", x => x.DistinctAllowedPaymentCount, Whole),
        new("Mode Allowed Amount", x => x.ModeAllowedAmount, Money),
        new("Mode Insurance Payment", x => x.ModeInsurancePaymentAmount, Money),
        new("Allowed Amount / Unit (Mode)", x => x.AllowedAmountPerUnitMode, Money),
        new("Insurance Payment / Unit (Mode)", x => x.InsurancePaymentPerUnitMode, Money),
        new("Lab", x => x.LabName)
    };

    private static readonly ExcelCol<LabMedianDto>[] MedianExcelColumns =
    {
        new("Payer Name", x => x.PayerName),
        new("Panel Name", x => x.PanelName),
        new("CPT Code", x => x.CptCode),
        new("Allowed Amount", x => x.AllowedAmount, Money),
        new("Insurance Payment", x => x.InsurancePayment, Money),
        new("Distinct Allowed Payment Count", x => x.DistinctAllowedPaymentCount, Whole),
        new("Median Allowed Amount", x => x.MedianAllowedAmount, Money),
        new("Median Insurance Payment", x => x.MedianInsurancePaymentAmount, Money),
        new("Allowed Amount / Unit (Median)", x => x.AllowedAmountPerUnitMedian, Money),
        new("Insurance Payment / Unit (Median)", x => x.InsurancePaymentPerUnitMedian, Money),
        new("Lab", x => x.LabName)
    };

    // ── public surface ───────────────────────────────────────────────────────

    public Task<PagedResult<LabModeDto>> GetModesAsync(LabRateQuery query, CancellationToken ct)
        => QueryAsync(query, "dbo.LabModes", ModeSelect, ModeSortColumns, MapMode, 1000, ct);

    public Task<PagedResult<LabMedianDto>> GetMediansAsync(LabRateQuery query, CancellationToken ct)
        => QueryAsync(query, "dbo.LabMedians", MedianSelect, MedianSortColumns, MapMedian, 1000, ct);

    public async Task<byte[]> ExportModesAsync(LabRateQuery query, CancellationToken ct)
    {
        query.Page = 1;
        query.PageSize = ExportRowCap;
        var rows = (await QueryAsync(query, "dbo.LabModes", ModeSelect, ModeSortColumns, MapMode, ExportRowCap, ct)).Items;
        return BuildExcel("Lab Modes", ModeExcelColumns, rows);
    }

    public async Task<byte[]> ExportMediansAsync(LabRateQuery query, CancellationToken ct)
    {
        query.Page = 1;
        query.PageSize = ExportRowCap;
        var rows = (await QueryAsync(query, "dbo.LabMedians", MedianSelect, MedianSortColumns, MapMedian, ExportRowCap, ct)).Items;
        return BuildExcel("Lab Medians", MedianExcelColumns, rows);
    }

    public Task<IReadOnlyList<string>> GetModeFilterOptionsAsync(string? field, string? term, int? labId, CancellationToken ct)
        => GetFilterOptionsAsync("dbo.LabModes", field, term, labId, ct);

    public Task<IReadOnlyList<string>> GetMedianFilterOptionsAsync(string? field, string? term, int? labId, CancellationToken ct)
        => GetFilterOptionsAsync("dbo.LabMedians", field, term, labId, ct);

    public async Task<IReadOnlyList<MasterValueLabOption>> GetLabsAsync(CancellationToken ct)
    {
        var labs = new List<MasterValueLabOption>();
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT LabId, LabName FROM (
                SELECT DISTINCT LabId, LabName FROM dbo.LabModes
                UNION
                SELECT DISTINCT LabId, LabName FROM dbo.LabMedians
            ) x
            ORDER BY LabName, LabId;
            """, conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            labs.Add(new MasterValueLabOption { LabId = reader.GetInt32(0), LabName = reader.GetString(1) });
        return labs;
    }

    // ── internals ────────────────────────────────────────────────────────────

    private async Task<PagedResult<T>> QueryAsync<T>(LabRateQuery query, string table, string selectList,
        IReadOnlyDictionary<string, string> sortColumns, Func<SqlDataReader, T> map, int maxPageSize, CancellationToken ct)
    {
        query.Page = Math.Max(1, query.Page);
        query.PageSize = Math.Clamp(query.PageSize <= 0 ? 50 : query.PageSize, 10, maxPageSize);
        var where = BuildWhere(query, out var parameters);
        var orderBy = BuildOrderBy(query, sortColumns);
        var result = new PagedResult<T> { Page = query.Page, PageSize = query.PageSize };
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using (var count = new SqlCommand($"SELECT COUNT(1) FROM {table} WHERE {where};", conn))
        {
            count.Parameters.AddRange(Clone(parameters));
            result.TotalCount = Convert.ToInt32(await count.ExecuteScalarAsync(ct) ?? 0);
        }
        await using var cmd = new SqlCommand($"""
            SELECT {selectList}
            FROM {table}
            WHERE {where}
            ORDER BY {orderBy}
            OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;
            """, conn);
        cmd.Parameters.AddRange(Clone(parameters));
        cmd.Parameters.AddWithValue("@Offset", (query.Page - 1) * query.PageSize);
        cmd.Parameters.AddWithValue("@PageSize", query.PageSize);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) result.Items.Add(map(reader));
        return result;
    }

    private async Task<IReadOnlyList<string>> GetFilterOptionsAsync(string table, string? field, string? term, int? labId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(field) || !FilterFields.TryGetValue(field.Trim(), out var column))
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
            where.Add("LabId = @LabId");
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

    private static string BuildWhere(LabRateQuery q, out List<SqlParameter> p)
    {
        var parts = new List<string> { "1=1" };
        p = new List<SqlParameter>();
        AddLike(parts, p, "PayerName", q.PayerName);
        AddLike(parts, p, "PanelName", q.PanelName);
        AddLike(parts, p, "CPTCode", q.CptCode);
        if (q.LabId.HasValue)
        {
            parts.Add("LabId = @LabId");
            p.Add(new SqlParameter("@LabId", q.LabId.Value));
        }
        return string.Join(" AND ", parts);
    }

    private static string BuildOrderBy(LabRateQuery q, IReadOnlyDictionary<string, string> columns)
    {
        if (string.IsNullOrWhiteSpace(q.SortColumn) || !columns.TryGetValue(q.SortColumn.Trim(), out var column))
            return "PayerName ASC, PanelName ASC, CPTCode ASC";
        var direction = string.Equals(q.SortDirection, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC";
        return $"{column} {direction}";
    }

    private static void AddLike(List<string> parts, List<SqlParameter> p, string column, string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        var name = "@" + column;
        parts.Add($"{column} LIKE {name} ESCAPE '\\'");
        p.Add(new SqlParameter(name, LikePattern(value)));
    }

    private static string LikePattern(string value)
        => "%" + value.Trim()
            .Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("%", "\\%", StringComparison.Ordinal)
            .Replace("_", "\\_", StringComparison.Ordinal)
            .Replace("[", "\\[", StringComparison.Ordinal) + "%";

    private static SqlParameter[] Clone(IEnumerable<SqlParameter> source)
        => source.Select(x => new SqlParameter(x.ParameterName, x.Value)).ToArray();

    private static string? Str(SqlDataReader r, string c) => r.IsDBNull(r.GetOrdinal(c)) ? null : r.GetString(r.GetOrdinal(c));
    private static int? Int(SqlDataReader r, string c) => r.IsDBNull(r.GetOrdinal(c)) ? null : r.GetInt32(r.GetOrdinal(c));
    private static decimal? Dec(SqlDataReader r, string c) => r.IsDBNull(r.GetOrdinal(c)) ? null : r.GetDecimal(r.GetOrdinal(c));
}
