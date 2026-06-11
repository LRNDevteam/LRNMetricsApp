using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;
using System.Diagnostics;

namespace LabMetricsDashboard.Services;

public sealed class SqlPhiExecutiveSummaryRepository
{
    private readonly ILogger<SqlPhiExecutiveSummaryRepository> _logger;

    private static readonly List<string> RowOrder =
    [
        "A",
        "B","B1","B2","B3","B4","B5","B6","B7","B8","B9","B10",
        "B11","B12","B13","B14","B15","B16","B17","B18","B19","B20",
        "B21","B22","B23","B24","B25","B26","B27","B28","B29","B30","B31",
        "C",
        "D","D-Recv","D-BRR","D-Coll",
        "E",
        "F","F-AMD","F-Bill",
        "G","G-Bill","G-AMD",
        "H","H-AMD","H-Bill",
        "I","I-AMD","I-Bill",
        "J","K",
        "L","L-Recv","L-Coll",
        "M","N","O","P",
        "Q","S","T","U","V","W","X","Y1","Y2","Y3",
        "Z","AA","AB","AC","AD","AE","AG","AH","AI1",
        "AJ","AK","AL",
    ];

    public SqlPhiExecutiveSummaryRepository(ILogger<SqlPhiExecutiveSummaryRepository> logger)
        => _logger = logger;

    /// <summary>Checks whether a stored procedure exists in the target database.</summary>
    public async Task<bool> StoredProcedureExistsAsync(
        string connectionString, string spName, CancellationToken ct = default)
    {
        try
        {
            // Strip schema prefix for OBJECT_ID check
            var name = spName.Contains('.') ? spName[(spName.IndexOf('.') + 1)..] : spName;
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(
                "SELECT CASE WHEN OBJECT_ID(@sp, 'P') IS NOT NULL THEN 1 ELSE 0 END;", conn)
                { CommandTimeout = 10 };
            cmd.Parameters.AddWithValue("@sp", spName);
            var result = await cmd.ExecuteScalarAsync(ct);
            return result is 1 or (object)1L or "1";
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Calls the given SP and returns a fully-assembled view model.
    /// </summary>
    public async Task<PhiExecutiveSummaryViewModel> GetExecutiveSummaryAsync(
        string connectionString,
        string spName,
        List<string> availableLabs,
        string selectedLab,
        int? yearFrom,
        int? yearTo,
        int? monthFrom,
        int? monthTo,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var vm = new PhiExecutiveSummaryViewModel
        {
            AvailableLabs     = availableLabs,
            SelectedLab       = selectedLab,
            SelectedYearFrom  = yearFrom,
            SelectedYearTo    = yearTo,
            SelectedMonthFrom = monthFrom,
            SelectedMonthTo   = monthTo,
        };

        var sw = Stopwatch.StartNew();
        try
        {
            var rawRows = new List<(string RowCode, string Category, string Description, int BillYear, int BillMonth, decimal MetricValue)>();

            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(spName, conn)
            {
                CommandType    = System.Data.CommandType.StoredProcedure,
                CommandTimeout = 120,
            };
            cmd.Parameters.AddWithValue("@YearFrom",  (object?)yearFrom  ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@YearTo",    (object?)yearTo    ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@MonthFrom", (object?)monthFrom ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@MonthTo",   (object?)monthTo   ?? DBNull.Value);

            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                rawRows.Add((
                    reader.GetString(0),
                    reader.GetString(1),
                    reader.GetString(2),
                    reader.GetInt32(3),
                    reader.GetInt32(4),
                    reader.GetDecimal(5)
                ));
            }

            _logger.LogInformation("ExecutiveSummary '{Lab}' SP={Sp}: {N} rows in {Ms}ms",
                selectedLab, spName, rawRows.Count, sw.ElapsedMilliseconds);

            if (rawRows.Count == 0)
                return vm;

            var rowDict   = new Dictionary<string, ExecSummaryRow>(StringComparer.OrdinalIgnoreCase);
            var periodSet = new SortedSet<(int Year, int Month)>(
                Comparer<(int Year, int Month)>.Create((a, b) =>
                    a.Year != b.Year ? a.Year.CompareTo(b.Year) : a.Month.CompareTo(b.Month)));
            var yearSet = new SortedSet<int>();

            foreach (var (rowCode, category, description, billYear, billMonth, metricValue) in rawRows)
            {
                if (!rowDict.TryGetValue(rowCode, out var row))
                {
                    row = new ExecSummaryRow
                    {
                        RowCode     = rowCode,
                        Category    = category,
                        Description = description,
                    };
                    rowDict[rowCode] = row;
                }
                row.ValuesByYearMonth[(billYear, billMonth)] = metricValue;
                if (billYear != 0) { periodSet.Add((billYear, billMonth)); yearSet.Add(billYear); }
            }

            var columns = periodSet.ToList();
            columns.Add((0, 0));

            vm.YearMonthColumns = columns;
            vm.AvailableYears   = yearSet.ToList();

            var orderIndex = RowOrder
                .Select((code, idx) => (code, idx))
                .ToDictionary(t => t.code, t => t.idx, StringComparer.OrdinalIgnoreCase);

            vm.Rows = rowDict.Values
                .OrderBy(r => orderIndex.TryGetValue(r.RowCode, out var idx) ? idx : 9999)
                .ThenBy(r => r.RowCode)
                .ToList();

            return vm;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "ExecutiveSummary query failed for lab '{Lab}' SP='{Sp}'.", selectedLab, spName);
            vm.ErrorMessage = $"Failed to load Executive Summary data: {ex.Message}";
            return vm;
        }
    }

    // Keep old method name for backward compat during transition
    public Task<PhiExecutiveSummaryViewModel> GetPhiExecutiveSummaryAsync(
        string connectionString, List<string> availableLabs, string selectedLab,
        int? yearFrom, int? yearTo, int? monthFrom, int? monthTo, CancellationToken ct = default)
        => GetExecutiveSummaryAsync(connectionString, "dbo.usp_GetPhi_ExecutiveSummary",
            availableLabs, selectedLab, yearFrom, yearTo, monthFrom, monthTo, ct);

    public async Task<List<int>> GetAvailableYearsAsync(
        string connectionString, CancellationToken ct = default)
    {
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(
                "SELECT DISTINCT YEAR(TRY_CAST(DateofService AS DATE)) FROM dbo.ClaimLevelData " +
                "WHERE DateofService IS NOT NULL ORDER BY 1 DESC;",
                conn) { CommandTimeout = 30 };
            await using var r = await cmd.ExecuteReaderAsync(ct);
            var years = new List<int>();
            while (await r.ReadAsync(ct))
                if (!r.IsDBNull(0)) years.Add(r.GetInt32(0));
            return years;
        }
        catch { return []; }
    }
}
