using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads Monthly Claim Volume data from <c>dbo.ClaimLevelData</c>.
/// Groups by PanelName × Year/Month(FirstBilledDate), counts unique ClaimIDs,
/// and sums ChargeAmount. Includes top-3 payer drill-down per panel.
/// </summary>
public sealed class SqlProductionReportRepository : IProductionReportRepository
{
    private readonly ILogger<SqlProductionReportRepository> _logger;

    public SqlProductionReportRepository(ILogger<SqlProductionReportRepository> logger)
        => _logger = logger;

    public async Task<ProductionReportResult> GetMonthlyClaimVolumeAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var whereClauses = new List<string>
        {
            "LTRIM(RTRIM(PayerName)) <> ''",
            "PayerName IS NOT NULL",
            "TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL",
            "YEAR(TRY_CAST(FirstBilledDate AS DATE)) > 1900"
        };
        var parameters = new List<SqlParameter>();

        if (filterPayerNames is { Count: > 0 })
        {
            var pNames = filterPayerNames.Select((n, i) => $"@fpn{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PayerName)) IN ({string.Join(",", pNames)})");
            for (int i = 0; i < filterPayerNames.Count; i++)
                parameters.Add(new SqlParameter($"@fpn{i}", filterPayerNames[i]));
        }

        if (filterPanelNames is { Count: > 0 })
        {
            var plNames = filterPanelNames.Select((n, i) => $"@fpl{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PanelName)) IN ({string.Join(",", plNames)})");
            for (int i = 0; i < filterPanelNames.Count; i++)
                parameters.Add(new SqlParameter($"@fpl{i}", filterPanelNames[i]));
        }

        if (filterFirstBillFrom.HasValue)
        {
            whereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) >= @fbFrom");
            parameters.Add(new SqlParameter("@fbFrom", SqlDbType.Date) { Value = filterFirstBillFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterFirstBillTo.HasValue)
        {
            whereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) <= @fbTo");
            parameters.Add(new SqlParameter("@fbTo", SqlDbType.Date) { Value = filterFirstBillTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        var whereStr = string.Join(" AND ", whereClauses);

        // Query 1: filter option lists (unfiltered)
        const string optionsSql = """
            SELECT DISTINCT LTRIM(RTRIM(PayerName)) FROM dbo.ClaimLevelData
            WHERE PayerName IS NOT NULL AND PayerName <> '' ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM(PanelName)) FROM dbo.ClaimLevelData
            WHERE PanelName IS NOT NULL AND PanelName <> '' ORDER BY 1;
            """;

        // Query 2: panel × month aggregation (unique claim count + sum charges)
        var pivotSql = $"""
            SELECT
                LTRIM(RTRIM(PanelName))                                 AS PanelName,
                LTRIM(RTRIM(PayerName))                                 AS PayerName,
                YEAR(TRY_CAST(FirstBilledDate AS DATE))                 AS BillYear,
                MONTH(TRY_CAST(FirstBilledDate AS DATE))                AS BillMonth,
                COUNT(DISTINCT ClaimID)                                  AS ClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS BilledCharges
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY
                LTRIM(RTRIM(PanelName)),
                LTRIM(RTRIM(PayerName)),
                YEAR(TRY_CAST(FirstBilledDate AS DATE)),
                MONTH(TRY_CAST(FirstBilledDate AS DATE))
            ORDER BY PanelName, PayerName, BillYear, BillMonth
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        // Read filter options
        var payerNames = new List<string>();
        var panelNames = new List<string>();

        await using (var optCmd = new SqlCommand(optionsSql, conn) { CommandTimeout = 180 })
        {
            await using var rdr = await optCmd.ExecuteReaderAsync(ct);
            while (await rdr.ReadAsync(ct)) payerNames.Add(rdr.GetString(0));
            await rdr.NextResultAsync(ct);
            while (await rdr.ReadAsync(ct)) panelNames.Add(rdr.GetString(0));
        }

        // Read pivot data
        var rawRows = new List<RawPivotRow>();
        await using (var pivCmd = new SqlCommand(pivotSql, conn))
        {
            pivCmd.CommandTimeout = 120;
            foreach (var p in parameters)
                pivCmd.Parameters.Add(CloneParameter(p));
            await using var rdr = await pivCmd.ExecuteReaderAsync(ct);
            while (await rdr.ReadAsync(ct))
            {
                rawRows.Add(new RawPivotRow(
                    rdr.GetString(0),
                    rdr.GetString(1),
                    rdr.GetInt32(2),
                    rdr.GetInt32(3),
                    rdr.GetInt32(4),
                    rdr.GetDecimal(5)));
            }
        }

        _logger.LogInformation("Production Report: {RawCount} raw pivot rows", rawRows.Count);

        return BuildResult(payerNames, panelNames, rawRows);
    }

    private static ProductionReportResult BuildResult(
        List<string> payerNames, List<string> panelNames, List<RawPivotRow> rawRows)
    {
        // Collect all distinct months and years
        var monthSet = new SortedSet<string>();
        var yearSet = new SortedSet<int>();
        foreach (var r in rawRows)
        {
            var monthKey = $"{r.BillYear:D4}-{r.BillMonth:D2}";
            monthSet.Add(monthKey);
            yearSet.Add(r.BillYear);
        }

        var months = monthSet.ToList();
        var years = yearSet.ToList();

        // Group by panel ? payer ? month
        var byPanel = rawRows
            .GroupBy(r => r.PanelName, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        var panelRows = new List<ProductionPanelRow>();

        foreach (var (panel, rows) in byPanel)
        {
            // Panel-level aggregation
            var panelByMonth = new Dictionary<string, ProductionMonthCell>();
            var panelByYear = new Dictionary<int, ProductionYearTotal>();

            foreach (var r in rows)
            {
                var mk = $"{r.BillYear:D4}-{r.BillMonth:D2}";
                if (panelByMonth.TryGetValue(mk, out var existing))
                    panelByMonth[mk] = new ProductionMonthCell(existing.ClaimCount + r.ClaimCount, existing.BilledCharges + r.BilledCharges);
                else
                    panelByMonth[mk] = new ProductionMonthCell(r.ClaimCount, r.BilledCharges);

                if (panelByYear.TryGetValue(r.BillYear, out var ey))
                    panelByYear[r.BillYear] = new ProductionYearTotal(ey.ClaimCount + r.ClaimCount, ey.BilledCharges + r.BilledCharges);
                else
                    panelByYear[r.BillYear] = new ProductionYearTotal(r.ClaimCount, r.BilledCharges);
            }

            int panelTotalClaims = panelByMonth.Values.Sum(c => c.ClaimCount);
            decimal panelTotalCharges = panelByMonth.Values.Sum(c => c.BilledCharges);

            // Top 3 payers by unique claim count for this panel
            var payerGroups = rows
                .GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
                .Select(g =>
                {
                    var payerByMonth = new Dictionary<string, ProductionMonthCell>();
                    var payerByYear = new Dictionary<int, ProductionYearTotal>();

                    foreach (var r in g)
                    {
                        var mk = $"{r.BillYear:D4}-{r.BillMonth:D2}";
                        if (payerByMonth.TryGetValue(mk, out var em))
                            payerByMonth[mk] = new ProductionMonthCell(em.ClaimCount + r.ClaimCount, em.BilledCharges + r.BilledCharges);
                        else
                            payerByMonth[mk] = new ProductionMonthCell(r.ClaimCount, r.BilledCharges);

                        if (payerByYear.TryGetValue(r.BillYear, out var ey))
                            payerByYear[r.BillYear] = new ProductionYearTotal(ey.ClaimCount + r.ClaimCount, ey.BilledCharges + r.BilledCharges);
                        else
                            payerByYear[r.BillYear] = new ProductionYearTotal(r.ClaimCount, r.BilledCharges);
                    }

                    int total = payerByMonth.Values.Sum(c => c.ClaimCount);
                    return new ProductionPayerDrillDown
                    {
                        PayerName = g.Key,
                        ByMonth = payerByMonth,
                        ByYear = payerByYear,
                        TotalClaims = total,
                        TotalCharges = payerByMonth.Values.Sum(c => c.BilledCharges),
                    };
                })
                .OrderByDescending(p => p.TotalClaims)
                .Take(3)
                .ToList();

            panelRows.Add(new ProductionPanelRow
            {
                PanelName = panel,
                ByMonth = panelByMonth,
                ByYear = panelByYear,
                TotalClaims = panelTotalClaims,
                TotalCharges = panelTotalCharges,
                TopPayers = payerGroups,
            });
        }

        // Sort panels by grand total descending
        panelRows = panelRows.OrderByDescending(p => p.TotalClaims).ToList();

        // Grand totals
        var grandByMonth = new Dictionary<string, ProductionMonthCell>();
        foreach (var p in panelRows)
        {
            foreach (var (mk, cell) in p.ByMonth)
            {
                if (grandByMonth.TryGetValue(mk, out var eg))
                    grandByMonth[mk] = new ProductionMonthCell(eg.ClaimCount + cell.ClaimCount, eg.BilledCharges + cell.BilledCharges);
                else
                    grandByMonth[mk] = new ProductionMonthCell(cell.ClaimCount, cell.BilledCharges);
            }
        }

        int grandTotalClaims = panelRows.Sum(p => p.TotalClaims);
        decimal grandTotalCharges = panelRows.Sum(p => p.TotalCharges);

        return new ProductionReportResult(
            payerNames, panelNames, months, years,
            panelRows, grandByMonth, grandTotalClaims, grandTotalCharges);
    }

    /// <summary>Strips a trailing ".00" decimal suffix from CPT code strings (e.g. "87798.00" ? "87798").</summary>
    private static string NormalizeCptCode(string raw)
        => raw.EndsWith(".00", StringComparison.Ordinal) ? raw[..^3] : raw;

    private static SqlParameter CloneParameter(SqlParameter source)
    {
        return new SqlParameter(source.ParameterName, source.SqlDbType)
        {
            Value = source.Value ?? DBNull.Value,
            Size = source.Size,
        };
    }

    private sealed record RawPivotRow(
        string PanelName,
        string PayerName,
        int BillYear,
        int BillMonth,
        int ClaimCount,
        decimal BilledCharges);

    // ?? Weekly Claim Volume ??????????????????????????????????????????????

    public async Task<WeeklyClaimVolumeResult> GetWeeklyClaimVolumeAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        // Determine the last 4 ISO weeks based on today
        var today = DateOnly.FromDateTime(DateTime.Today);
        var weekColumns = BuildLast4Weeks(today);
        var earliest = weekColumns[0].WeekStart;
        var latest = weekColumns[^1].WeekEnd;

        var whereClauses = new List<string>
        {
            "LTRIM(RTRIM(PayerName)) <> ''",
            "PayerName IS NOT NULL",
            "TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL",
            "TRY_CAST(FirstBilledDate AS DATE) >= @WeekStart",
            "TRY_CAST(FirstBilledDate AS DATE) <= @WeekEnd"
        };
        var parameters = new List<SqlParameter>
        {
            new("@WeekStart", SqlDbType.Date) { Value = earliest.ToDateTime(TimeOnly.MinValue) },
            new("@WeekEnd", SqlDbType.Date) { Value = latest.ToDateTime(TimeOnly.MinValue) },
        };

        if (filterPayerNames is { Count: > 0 })
        {
            var pNames = filterPayerNames.Select((n, i) => $"@wfpn{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PayerName)) IN ({string.Join(",", pNames)})");
            for (int i = 0; i < filterPayerNames.Count; i++)
                parameters.Add(new SqlParameter($"@wfpn{i}", filterPayerNames[i]));
        }

        if (filterPanelNames is { Count: > 0 })
        {
            var plNames = filterPanelNames.Select((n, i) => $"@wfpl{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PanelName)) IN ({string.Join(",", plNames)})");
            for (int i = 0; i < filterPanelNames.Count; i++)
                parameters.Add(new SqlParameter($"@wfpl{i}", filterPanelNames[i]));
        }

        if (filterFirstBillFrom.HasValue)
        {
            whereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) >= @wfbFrom");
            parameters.Add(new SqlParameter("@wfbFrom", SqlDbType.Date) { Value = filterFirstBillFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterFirstBillTo.HasValue)
        {
            whereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) <= @wfbTo");
            parameters.Add(new SqlParameter("@wfbTo", SqlDbType.Date) { Value = filterFirstBillTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        var whereStr = string.Join(" AND ", whereClauses);

        // Query: panel × payer × date aggregation within last 4 weeks
        var pivotSql = $"""
            SELECT
                LTRIM(RTRIM(PanelName))                                 AS PanelName,
                LTRIM(RTRIM(PayerName))                                 AS PayerName,
                TRY_CAST(FirstBilledDate AS DATE)                       AS BillDate,
                COUNT(DISTINCT ClaimID)                                  AS ClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS BilledCharges
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY
                LTRIM(RTRIM(PanelName)),
                LTRIM(RTRIM(PayerName)),
                TRY_CAST(FirstBilledDate AS DATE)
            ORDER BY PanelName, PayerName, BillDate
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        var rawRows = new List<RawWeeklyRow>();
        await using (var cmd = new SqlCommand(pivotSql, conn))
        {
            cmd.CommandTimeout = 120;
            foreach (var p in parameters)
                cmd.Parameters.Add(CloneParameter(p));
            await using var rdr = await cmd.ExecuteReaderAsync(ct);
            while (await rdr.ReadAsync(ct))
            {
                var billDate = DateOnly.FromDateTime(rdr.GetDateTime(2));
                rawRows.Add(new RawWeeklyRow(
                    rdr.GetString(0),
                    rdr.GetString(1),
                    billDate,
                    rdr.GetInt32(3),
                    rdr.GetDecimal(4)));
            }
        }

        _logger.LogInformation("Weekly Claim Volume: {RawCount} raw rows", rawRows.Count);

        return BuildWeeklyResult(weekColumns, rawRows);
    }

    /// <summary>Builds the last 4 complete ISO weeks ending before today's week.</summary>
    private static List<WeekColumn> BuildLast4Weeks(DateOnly today)
    {
        // Find the Monday of the current week
        int daysSinceMonday = ((int)today.DayOfWeek + 6) % 7;
        var currentWeekMonday = today.AddDays(-daysSinceMonday);

        var weeks = new List<WeekColumn>();
        for (int i = 4; i >= 1; i--)
        {
            var monday = currentWeekMonday.AddDays(-7 * i);
            var sunday = monday.AddDays(6);
            var isoWeek = System.Globalization.ISOWeek.GetWeekOfYear(monday.ToDateTime(TimeOnly.MinValue));
            var key = $"{monday.Year:D4}-W{isoWeek:D2}";
            weeks.Add(new WeekColumn(key, monday, sunday));
        }
        return weeks;
    }

    /// <summary>Resolves which week key a date belongs to.</summary>
    private static string? ResolveWeekKey(DateOnly date, List<WeekColumn> weeks)
    {
        foreach (var w in weeks)
        {
            if (date >= w.WeekStart && date <= w.WeekEnd)
                return w.Key;
        }
        return null;
    }

    private static WeeklyClaimVolumeResult BuildWeeklyResult(
        List<WeekColumn> weekColumns, List<RawWeeklyRow> rawRows)
    {
        // Assign each raw row to a week
        var assigned = rawRows
            .Select(r => (Row: r, WeekKey: ResolveWeekKey(r.BillDate, weekColumns)))
            .Where(x => x.WeekKey is not null)
            .ToList();

        var byPanel = assigned
            .GroupBy(x => x.Row.PanelName, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        var panelRows = new List<WeeklyPanelRow>();

        foreach (var (panel, entries) in byPanel)
        {
            var panelByWeek = new Dictionary<string, ProductionMonthCell>();

            foreach (var (row, weekKey) in entries)
            {
                if (panelByWeek.TryGetValue(weekKey!, out var existing))
                    panelByWeek[weekKey!] = new ProductionMonthCell(existing.ClaimCount + row.ClaimCount, existing.BilledCharges + row.BilledCharges);
                else
                    panelByWeek[weekKey!] = new ProductionMonthCell(row.ClaimCount, row.BilledCharges);
            }

            int panelTotalClaims = panelByWeek.Values.Sum(c => c.ClaimCount);
            decimal panelTotalCharges = panelByWeek.Values.Sum(c => c.BilledCharges);

            // Top 3 payers by unique claim count for this panel
            var payerGroups = entries
                .GroupBy(x => x.Row.PayerName, StringComparer.OrdinalIgnoreCase)
                .Select(g =>
                {
                    var payerByWeek = new Dictionary<string, ProductionMonthCell>();
                    foreach (var (row, weekKey) in g)
                    {
                        if (payerByWeek.TryGetValue(weekKey!, out var em))
                            payerByWeek[weekKey!] = new ProductionMonthCell(em.ClaimCount + row.ClaimCount, em.BilledCharges + row.BilledCharges);
                        else
                            payerByWeek[weekKey!] = new ProductionMonthCell(row.ClaimCount, row.BilledCharges);
                    }
                    int total = payerByWeek.Values.Sum(c => c.ClaimCount);
                    return new WeeklyPayerDrillDown
                    {
                        PayerName = g.Key,
                        ByWeek = payerByWeek,
                        TotalClaims = total,
                        TotalCharges = payerByWeek.Values.Sum(c => c.BilledCharges),
                    };
                })
                .OrderByDescending(p => p.TotalClaims)
                .Take(3)
                .ToList();

            panelRows.Add(new WeeklyPanelRow
            {
                PanelName = panel,
                ByWeek = panelByWeek,
                TotalClaims = panelTotalClaims,
                TotalCharges = panelTotalCharges,
                TopPayers = payerGroups,
            });
        }

        panelRows = panelRows.OrderByDescending(p => p.TotalClaims).ToList();

        // Grand totals by week
        var grandByWeek = new Dictionary<string, ProductionMonthCell>();
        foreach (var p in panelRows)
        {
            foreach (var (wk, cell) in p.ByWeek)
            {
                if (grandByWeek.TryGetValue(wk, out var eg))
                    grandByWeek[wk] = new ProductionMonthCell(eg.ClaimCount + cell.ClaimCount, eg.BilledCharges + cell.BilledCharges);
                else
                    grandByWeek[wk] = new ProductionMonthCell(cell.ClaimCount, cell.BilledCharges);
            }
        }

        int grandTotalClaims = panelRows.Sum(p => p.TotalClaims);
        decimal grandTotalCharges = panelRows.Sum(p => p.TotalCharges);

        return new WeeklyClaimVolumeResult(
            weekColumns, panelRows, grandByWeek, grandTotalClaims, grandTotalCharges);
    }

    private sealed record RawWeeklyRow(
        string PanelName,
        string PayerName,
        DateOnly BillDate,
        int ClaimCount,
        decimal BilledCharges);

    // ?? Coding ???????????????????????????????????????????????????????????

    public async Task<CodingResult> GetCodingAsync(
        string connectionString,
        List<string>? filterPanelNames = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var whereClauses = new List<string>
        {
            "(FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')"
        };
        var parameters = new List<SqlParameter>();

        if (filterPanelNames is { Count: > 0 })
        {
            var plNames = filterPanelNames.Select((n, i) => $"@cfpl{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PanelName)) IN ({string.Join(",", plNames)})");
            for (int i = 0; i < filterPanelNames.Count; i++)
                parameters.Add(new SqlParameter($"@cfpl{i}", filterPanelNames[i]));
        }

        var whereStr = string.Join(" AND ", whereClauses);

        var codingSql = $"""
            SELECT
                LTRIM(RTRIM(PanelName))                                 AS PanelName,
                ISNULL(LTRIM(RTRIM(CPTCodeXUnitsXModifier)), '')        AS CptCode,
                COUNT(DISTINCT ClaimID)                                  AS ClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS TotalCharges
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY
                LTRIM(RTRIM(PanelName)),
                ISNULL(LTRIM(RTRIM(CPTCodeXUnitsXModifier)), '')
            ORDER BY PanelName, CptCode
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        var rawRows = new List<RawCodingRow>();
        await using (var cmd = new SqlCommand(codingSql, conn))
        {
            cmd.CommandTimeout = 120;
            foreach (var p in parameters)
                cmd.Parameters.Add(CloneParameter(p));
            await using var rdr = await cmd.ExecuteReaderAsync(ct);
            while (await rdr.ReadAsync(ct))
            {
                rawRows.Add(new RawCodingRow(
                    rdr.IsDBNull(0) ? string.Empty : rdr.GetString(0),
                    rdr.IsDBNull(1) ? string.Empty : NormalizeCptCode(rdr.GetString(1)),
                    rdr.GetInt32(2),
                    rdr.GetDecimal(3)));
            }
        }

        _logger.LogInformation("Coding: {RawCount} raw rows", rawRows.Count);

        return BuildCodingResult(rawRows);
    }

    private static CodingResult BuildCodingResult(List<RawCodingRow> rawRows)
    {
        var byPanel = rawRows
            .GroupBy(r => r.PanelName, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        var panelRows = new List<CodingPanelRow>();

        foreach (var (panel, rows) in byPanel)
        {
            int panelClaims = rows.Sum(r => r.ClaimCount);
            decimal panelCharges = rows.Sum(r => r.TotalCharges);

            var cptRows = rows
                .Where(r => !string.IsNullOrWhiteSpace(r.CptCode))
                .Select(r => new CodingCptDrillDown
                {
                    CptCodeUnitsModifier = r.CptCode,
                    ClaimCount = r.ClaimCount,
                    TotalCharges = r.TotalCharges,
                })
                .OrderByDescending(c => c.ClaimCount)
                .ToList();

            panelRows.Add(new CodingPanelRow
            {
                PanelName = panel,
                ClaimCount = panelClaims,
                TotalCharges = panelCharges,
                CptRows = cptRows,
            });
        }

        panelRows = panelRows.OrderByDescending(p => p.ClaimCount).ToList();

        int grandClaims = panelRows.Sum(p => p.ClaimCount);
        decimal grandCharges = panelRows.Sum(p => p.TotalCharges);

        return new CodingResult(panelRows, grandClaims, grandCharges);
    }

    private sealed record RawCodingRow(
        string PanelName,
        string CptCode,
        int ClaimCount,
        decimal TotalCharges);

    // ?? Payer Breakdown ??????????????????????????????????????????????????

    public async Task<PayerBreakdownResult> GetPayerBreakdownAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var whereClauses = new List<string>
        {
            "LTRIM(RTRIM(PayerName)) <> ''",
            "PayerName IS NOT NULL",
            "TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL",
            "YEAR(TRY_CAST(ChargeEnteredDate AS DATE)) > 1900"
        };
        var parameters = new List<SqlParameter>();

        if (filterPayerNames is { Count: > 0 })
        {
            var pNames = filterPayerNames.Select((n, i) => $"@pbpn{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PayerName)) IN ({string.Join(",", pNames)})");
            for (int i = 0; i < filterPayerNames.Count; i++)
                parameters.Add(new SqlParameter($"@pbpn{i}", filterPayerNames[i]));
        }

        if (filterPanelNames is { Count: > 0 })
        {
            var plNames = filterPanelNames.Select((n, i) => $"@pbpl{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PanelName)) IN ({string.Join(",", plNames)})");
            for (int i = 0; i < filterPanelNames.Count; i++)
                parameters.Add(new SqlParameter($"@pbpl{i}", filterPanelNames[i]));
        }

        var whereStr = string.Join(" AND ", whereClauses);

        var pivotSql = $"""
            SELECT
                LTRIM(RTRIM(PayerName))                     AS PayerName,
                YEAR(TRY_CAST(ChargeEnteredDate AS DATE))   AS EnteredYear,
                MONTH(TRY_CAST(ChargeEnteredDate AS DATE))  AS EnteredMonth,
                COUNT(DISTINCT ClaimID)                      AS ClaimCount
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY
                LTRIM(RTRIM(PayerName)),
                YEAR(TRY_CAST(ChargeEnteredDate AS DATE)),
                MONTH(TRY_CAST(ChargeEnteredDate AS DATE))
            ORDER BY PayerName, EnteredYear, EnteredMonth
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        var rawRows = new List<RawPayerBreakdownRow>();
        await using (var cmd = new SqlCommand(pivotSql, conn))
        {
            cmd.CommandTimeout = 120;
            foreach (var p in parameters)
                cmd.Parameters.Add(CloneParameter(p));
            await using var rdr = await cmd.ExecuteReaderAsync(ct);
            while (await rdr.ReadAsync(ct))
            {
                rawRows.Add(new RawPayerBreakdownRow(
                    rdr.GetString(0),
                    rdr.GetInt32(1),
                    rdr.GetInt32(2),
                    rdr.GetInt32(3)));
            }
        }

        _logger.LogInformation("Payer Breakdown: {RawCount} raw rows", rawRows.Count);

        return BuildPayerBreakdownResult(rawRows);
    }

    private static PayerBreakdownResult BuildPayerBreakdownResult(List<RawPayerBreakdownRow> rawRows)
    {
        var monthSet = new SortedSet<string>();
        var yearSet = new SortedSet<int>();
        foreach (var r in rawRows)
        {
            monthSet.Add($"{r.EnteredYear:D4}-{r.EnteredMonth:D2}");
            yearSet.Add(r.EnteredYear);
        }

        var months = monthSet.ToList();
        var years = yearSet.ToList();

        var byPayer = rawRows
            .GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        var payerRows = new List<PayerBreakdownRow>();

        foreach (var (payer, rows) in byPayer)
        {
            var byMonth = new Dictionary<string, int>();
            var byYear = new Dictionary<int, int>();

            foreach (var r in rows)
            {
                var mk = $"{r.EnteredYear:D4}-{r.EnteredMonth:D2}";
                byMonth[mk] = byMonth.TryGetValue(mk, out var em) ? em + r.ClaimCount : r.ClaimCount;
                byYear[r.EnteredYear] = byYear.TryGetValue(r.EnteredYear, out var ey) ? ey + r.ClaimCount : r.ClaimCount;
            }

            payerRows.Add(new PayerBreakdownRow
            {
                PayerName = payer,
                ByMonth = byMonth,
                ByYear = byYear,
                GrandTotal = byMonth.Values.Sum(),
            });
        }

        payerRows = payerRows.OrderByDescending(p => p.GrandTotal).ToList();

        var grandByMonth = new Dictionary<string, int>();
        foreach (var p in payerRows)
        {
            foreach (var (mk, cnt) in p.ByMonth)
            {
                grandByMonth[mk] = grandByMonth.TryGetValue(mk, out var eg) ? eg + cnt : cnt;
            }
        }

        int grandTotal = payerRows.Sum(p => p.GrandTotal);

        return new PayerBreakdownResult(months, years, payerRows, grandByMonth, grandTotal);
    }

    private sealed record RawPayerBreakdownRow(
        string PayerName,
        int EnteredYear,
        int EnteredMonth,
        int ClaimCount);

    // ?? Payer X Panel ????????????????????????????????????????????????????

    public async Task<PayerPanelResult> GetPayerPanelAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var whereClauses = new List<string>
        {
            "LTRIM(RTRIM(PayerName)) <> ''",
            "PayerName IS NOT NULL",
            "TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL",
            "YEAR(TRY_CAST(ChargeEnteredDate AS DATE)) > 1900"
        };
        var parameters = new List<SqlParameter>();

        if (filterPayerNames is { Count: > 0 })
        {
            var pNames = filterPayerNames.Select((n, i) => $"@pxpn{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PayerName)) IN ({string.Join(",", pNames)})");
            for (int i = 0; i < filterPayerNames.Count; i++)
                parameters.Add(new SqlParameter($"@pxpn{i}", filterPayerNames[i]));
        }

        if (filterPanelNames is { Count: > 0 })
        {
            var plNames = filterPanelNames.Select((n, i) => $"@pxpl{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PanelName)) IN ({string.Join(",", plNames)})");
            for (int i = 0; i < filterPanelNames.Count; i++)
                parameters.Add(new SqlParameter($"@pxpl{i}", filterPanelNames[i]));
        }

        var whereStr = string.Join(" AND ", whereClauses);

        var pivotSql = $"""
            SELECT
                LTRIM(RTRIM(PayerName))                                 AS PayerName,
                LTRIM(RTRIM(PanelName))                                 AS PanelName,
                COUNT(DISTINCT ClaimID)                                  AS ClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS BilledCharges
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY
                LTRIM(RTRIM(PayerName)),
                LTRIM(RTRIM(PanelName))
            ORDER BY PayerName, PanelName
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        var rawRows = new List<RawPayerPanelRow>();
        await using (var cmd = new SqlCommand(pivotSql, conn))
        {
            cmd.CommandTimeout = 120;
            foreach (var p in parameters)
                cmd.Parameters.Add(CloneParameter(p));
            await using var rdr = await cmd.ExecuteReaderAsync(ct);
            while (await rdr.ReadAsync(ct))
            {
                rawRows.Add(new RawPayerPanelRow(
                    rdr.GetString(0),
                    rdr.IsDBNull(1) ? string.Empty : rdr.GetString(1),
                    rdr.GetInt32(2),
                    rdr.GetDecimal(3)));
            }
        }

        _logger.LogInformation("Payer X Panel: {RawCount} raw rows", rawRows.Count);

        return BuildPayerPanelResult(rawRows);
    }

    private static PayerPanelResult BuildPayerPanelResult(List<RawPayerPanelRow> rawRows)
    {
        var panelSet = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var r in rawRows)
        {
            if (!string.IsNullOrWhiteSpace(r.PanelName))
                panelSet.Add(r.PanelName);
        }

        var panelColumns = panelSet.ToList();

        var byPayer = rawRows
            .GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        var payerRows = new List<PayerPanelRow>();

        foreach (var (payer, rows) in byPayer)
        {
            var byPanel = new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase);

            foreach (var r in rows)
            {
                var key = string.IsNullOrWhiteSpace(r.PanelName) ? "(Blank)" : r.PanelName;
                if (byPanel.TryGetValue(key, out var existing))
                    byPanel[key] = new ProductionMonthCell(existing.ClaimCount + r.ClaimCount, existing.BilledCharges + r.BilledCharges);
                else
                    byPanel[key] = new ProductionMonthCell(r.ClaimCount, r.BilledCharges);
            }

            int totalClaims = byPanel.Values.Sum(c => c.ClaimCount);
            decimal totalCharges = byPanel.Values.Sum(c => c.BilledCharges);

            payerRows.Add(new PayerPanelRow
            {
                PayerName = payer,
                ByPanel = byPanel,
                GrandTotalClaims = totalClaims,
                GrandTotalCharges = totalCharges,
            });
        }

        payerRows = payerRows.OrderByDescending(p => p.GrandTotalClaims).ToList();

        var grandByPanel = new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in payerRows)
        {
            foreach (var (panel, cell) in p.ByPanel)
            {
                if (grandByPanel.TryGetValue(panel, out var eg))
                    grandByPanel[panel] = new ProductionMonthCell(eg.ClaimCount + cell.ClaimCount, eg.BilledCharges + cell.BilledCharges);
                else
                    grandByPanel[panel] = new ProductionMonthCell(cell.ClaimCount, cell.BilledCharges);
            }
        }

        int grandClaims = payerRows.Sum(p => p.GrandTotalClaims);
        decimal grandCharges = payerRows.Sum(p => p.GrandTotalCharges);

        return new PayerPanelResult(panelColumns, payerRows, grandByPanel, grandClaims, grandCharges);
    }

    private sealed record RawPayerPanelRow(
        string PayerName,
        string PanelName,
        int ClaimCount,
        decimal BilledCharges);

    // ?? Unbilled X Aging ?????????????????????????????????????????????????

    public async Task<UnbilledAgingResult> GetUnbilledAgingAsync(
        string connectionString,
        List<string>? filterPanelNames = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var whereClauses = new List<string>
        {
            "(FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')"
        };
        var parameters = new List<SqlParameter>();

        if (filterPanelNames is { Count: > 0 })
        {
            var plNames = filterPanelNames.Select((n, i) => $"@uapl{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PanelName)) IN ({string.Join(",", plNames)})");
            for (int i = 0; i < filterPanelNames.Count; i++)
                parameters.Add(new SqlParameter($"@uapl{i}", filterPanelNames[i]));
        }

        var whereStr = string.Join(" AND ", whereClauses);

        var agingSql = $"""
            SELECT
                LTRIM(RTRIM(PanelName))                                 AS PanelName,
                CASE
                    WHEN TRY_CAST(DaystoDOS AS INT) IS NULL THEN 'Current'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 30    THEN 'Current'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 60    THEN '30+'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 90    THEN '60+'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 120   THEN '90+'
                    ELSE '120+'
                END                                                     AS AgingBucket,
                COUNT(DISTINCT ClaimID)                                  AS ClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS BilledCharges
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY
                LTRIM(RTRIM(PanelName)),
                CASE
                    WHEN TRY_CAST(DaystoDOS AS INT) IS NULL THEN 'Current'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 30    THEN 'Current'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 60    THEN '30+'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 90    THEN '60+'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 120   THEN '90+'
                    ELSE '120+'
                END
            ORDER BY PanelName, AgingBucket
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        var rawRows = new List<RawUnbilledAgingRow>();
        await using (var cmd = new SqlCommand(agingSql, conn))
        {
            cmd.CommandTimeout = 120;
            foreach (var p in parameters)
                cmd.Parameters.Add(CloneParameter(p));
            await using var rdr = await cmd.ExecuteReaderAsync(ct);
            while (await rdr.ReadAsync(ct))
            {
                rawRows.Add(new RawUnbilledAgingRow(
                    rdr.IsDBNull(0) ? string.Empty : rdr.GetString(0),
                    rdr.GetString(1),
                    rdr.GetInt32(2),
                    rdr.GetDecimal(3)));
            }
        }

        _logger.LogInformation("Unbilled X Aging: {RawCount} raw rows", rawRows.Count);

        return BuildUnbilledAgingResult(rawRows);
    }

    private static UnbilledAgingResult BuildUnbilledAgingResult(List<RawUnbilledAgingRow> rawRows)
    {
        var byPanel = rawRows
            .GroupBy(r => r.PanelName, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        var panelRows = new List<UnbilledAgingRow>();

        foreach (var (panel, rows) in byPanel)
        {
            var byBucket = new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase);

            foreach (var r in rows)
            {
                if (byBucket.TryGetValue(r.AgingBucket, out var existing))
                    byBucket[r.AgingBucket] = new ProductionMonthCell(existing.ClaimCount + r.ClaimCount, existing.BilledCharges + r.BilledCharges);
                else
                    byBucket[r.AgingBucket] = new ProductionMonthCell(r.ClaimCount, r.BilledCharges);
            }

            int totalClaims = byBucket.Values.Sum(c => c.ClaimCount);
            decimal totalCharges = byBucket.Values.Sum(c => c.BilledCharges);

            panelRows.Add(new UnbilledAgingRow
            {
                PanelName = string.IsNullOrWhiteSpace(panel) ? "(Blank)" : panel,
                ByBucket = byBucket,
                GrandTotalClaims = totalClaims,
                GrandTotalCharges = totalCharges,
            });
        }

        panelRows = panelRows.OrderByDescending(p => p.GrandTotalClaims).ToList();

        var grandByBucket = new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in panelRows)
        {
            foreach (var (bk, cell) in p.ByBucket)
            {
                if (grandByBucket.TryGetValue(bk, out var eg))
                    grandByBucket[bk] = new ProductionMonthCell(eg.ClaimCount + cell.ClaimCount, eg.BilledCharges + cell.BilledCharges);
                else
                    grandByBucket[bk] = new ProductionMonthCell(cell.ClaimCount, cell.BilledCharges);
            }
        }

        int grandClaims = panelRows.Sum(p => p.GrandTotalClaims);
        decimal grandCharges = panelRows.Sum(p => p.GrandTotalCharges);

        return new UnbilledAgingResult(panelRows, grandByBucket, grandClaims, grandCharges);
    }

    private sealed record RawUnbilledAgingRow(
        string PanelName,
        string AgingBucket,
        int ClaimCount,
        decimal BilledCharges);

    // ?? CPT Breakdown ????????????????????????????????????????????????????

    public async Task<CptBreakdownResult> GetCptBreakdownAsync(
        string connectionString,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var whereClauses = new List<string>
        {
            "TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL",
            "YEAR(TRY_CAST(FirstBilledDate AS DATE)) > 1900"
        };
        var parameters = new List<SqlParameter>();

        if (filterFirstBillFrom.HasValue)
        {
            whereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) >= @cptFbFrom");
            parameters.Add(new SqlParameter("@cptFbFrom", SqlDbType.Date) { Value = filterFirstBillFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterFirstBillTo.HasValue)
        {
            whereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) <= @cptFbTo");
            parameters.Add(new SqlParameter("@cptFbTo", SqlDbType.Date) { Value = filterFirstBillTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        var whereStr = string.Join(" AND ", whereClauses);

        var sql = $"""
            SELECT
                LTRIM(RTRIM(CPTCode))                                       AS CptCode,
                YEAR(TRY_CAST(FirstBilledDate AS DATE))                     AS BilledYear,
                MONTH(TRY_CAST(FirstBilledDate AS DATE))                    AS BilledMonth,
                ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))),0)             AS TotalUnits,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)      AS BilledCharges
            FROM dbo.LineLevelData
            WHERE {whereStr}
              AND CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
            GROUP BY
                LTRIM(RTRIM(CPTCode)),
                YEAR(TRY_CAST(FirstBilledDate AS DATE)),
                MONTH(TRY_CAST(FirstBilledDate AS DATE))
            ORDER BY CptCode, BilledYear, BilledMonth
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        var rawRows = new List<RawCptBreakdownRow>();
        await using (var cmd = new SqlCommand(sql, conn))
        {
            cmd.CommandTimeout = 120;
            foreach (var p in parameters)
                cmd.Parameters.Add(CloneParameter(p));
            await using var rdr = await cmd.ExecuteReaderAsync(ct);
            while (await rdr.ReadAsync(ct))
            {
                rawRows.Add(new RawCptBreakdownRow(
                    NormalizeCptCode(rdr.GetString(0)),
                    rdr.GetInt32(1),
                    rdr.GetInt32(2),
                    rdr.GetDecimal(3),
                    rdr.GetDecimal(4)));
            }
        }

        _logger.LogInformation("CPT Breakdown: {RawCount} raw rows", rawRows.Count);

        return BuildCptBreakdownResult(rawRows);
    }

    private static CptBreakdownResult BuildCptBreakdownResult(List<RawCptBreakdownRow> rawRows)
    {
        var monthSet = new SortedSet<string>();
        var yearSet = new SortedSet<int>();
        foreach (var r in rawRows)
        {
            monthSet.Add($"{r.BilledYear:D4}-{r.BilledMonth:D2}");
            yearSet.Add(r.BilledYear);
        }

        var months = monthSet.ToList();
        var years = yearSet.ToList();

        var byCpt = rawRows
            .GroupBy(r => r.CptCode, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);

        var cptRows = new List<CptBreakdownRow>();

        foreach (var (cpt, rows) in byCpt)
        {
            var byMonth = new Dictionary<string, CptBreakdownCell>();
            var byYear = new Dictionary<int, CptBreakdownCell>();

            foreach (var r in rows)
            {
                var mk = $"{r.BilledYear:D4}-{r.BilledMonth:D2}";
                if (byMonth.TryGetValue(mk, out var em))
                    byMonth[mk] = new CptBreakdownCell(em.Units + r.TotalUnits, em.BilledCharges + r.BilledCharges);
                else
                    byMonth[mk] = new CptBreakdownCell(r.TotalUnits, r.BilledCharges);

                if (byYear.TryGetValue(r.BilledYear, out var ey))
                    byYear[r.BilledYear] = new CptBreakdownCell(ey.Units + r.TotalUnits, ey.BilledCharges + r.BilledCharges);
                else
                    byYear[r.BilledYear] = new CptBreakdownCell(r.TotalUnits, r.BilledCharges);
            }

            decimal totalUnits = byMonth.Values.Sum(c => c.Units);
            decimal totalCharges = byMonth.Values.Sum(c => c.BilledCharges);

            cptRows.Add(new CptBreakdownRow
            {
                CptCode = cpt,
                ByMonth = byMonth,
                ByYear = byYear,
                GrandTotalUnits = totalUnits,
                GrandTotalCharges = totalCharges,
            });
        }

        cptRows = cptRows.OrderByDescending(c => c.GrandTotalUnits).ToList();

        var grandByMonth = new Dictionary<string, CptBreakdownCell>();
        foreach (var c in cptRows)
        {
            foreach (var (mk, cell) in c.ByMonth)
            {
                if (grandByMonth.TryGetValue(mk, out var eg))
                    grandByMonth[mk] = new CptBreakdownCell(eg.Units + cell.Units, eg.BilledCharges + cell.BilledCharges);
                else
                    grandByMonth[mk] = new CptBreakdownCell(cell.Units, cell.BilledCharges);
            }
        }

        decimal grandUnits = cptRows.Sum(c => c.GrandTotalUnits);
        decimal grandCharges = cptRows.Sum(c => c.GrandTotalCharges);

        return new CptBreakdownResult(months, years, cptRows, grandByMonth, grandUnits, grandCharges);
    }

    private sealed record RawCptBreakdownRow(
        string CptCode,
        int BilledYear,
        int BilledMonth,
        decimal TotalUnits,
        decimal BilledCharges);

    // ?? Raw Data Export ??????????????????????????????????????????????

    /// <inheritdoc />
    public async Task<List<Dictionary<string, object?>>> GetClaimLevelDataExportAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default)
    {
        var (whereStr, parameters) = BuildExportFilters(filterPayerNames, filterPanelNames, filterFirstBillFrom, filterFirstBillTo, "ce");

        var sql = $"""
            SELECT [ClaimID],[AccessionNumber],[PayerName],[PayerType],[BillingProvider],[ReferringProvider],
                   [ClinicName],[SalesRepname],[PatientID],[PatientDOB],[DateofService],[ChargeEnteredDate],
                   [FirstBilledDate],[Panelname],[CPTCodeXUnitsXModifier],[POS],[TOS],[ChargeAmount],[AllowedAmount],
                   [InsurancePayment],[PatientPayment],[TotalPayments],[InsuranceAdjustments],[PatientAdjustments],
                   [TotalAdjustments],[InsuranceBalance],[PatientBalance],[TotalBalance],[CheckDate],[ClaimStatus],
                   [DenialCode],[ICDCode],[DaystoDOS],[RollingDays],[DaystoBill],[DaystoPost],[ICDPointer],[InsertedDateTime]
            FROM dbo.ClaimLevelData
            {whereStr}
            """;

        return await ExecuteExportQueryAsync(connectionString, sql, parameters, ct);
    }

    /// <inheritdoc />
    public async Task<List<Dictionary<string, object?>>> GetLineLevelDataExportAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        CancellationToken ct = default)
    {
        var (whereStr, parameters) = BuildExportFilters(filterPayerNames, filterPanelNames, filterFirstBillFrom, filterFirstBillTo, "le");

        var sql = $"""
            SELECT [ClaimID],[AccessionNumber],[PayerName],[PayerType],[BillingProvider],[ReferringProvider],
                   [ClinicName],[SalesRepname],[PatientID],[PatientDOB],[DateofService],[ChargeEnteredDate],
                   [FirstBilledDate],[Panelname],[CPTCode],[Units],[Modifier],[POS],[TOS],
                   [ChargeAmount],[ChargeAmountPerUnit],[AllowedAmount],[AllowedAmountPerUnit],
                   [InsurancePayment],[InsurancePaymentPerUnit],[PatientPayment],[PatientPaymentPerUnit],
                   [TotalPayments],[InsuranceAdjustments],[PatientAdjustments],[TotalAdjustments],
                   [InsuranceBalance],[PatientBalance],[PatientBalancePerUnit],[TotalBalance],
                   [CheckDate],[PostingDate],[ClaimStatus],[PayStatus],[DenialCode],[DenialDate],
                   [ICDCode],[DaystoDOS],[RollingDays],[DaystoBill],[DaystoPost],[ICDPointer]
            FROM dbo.LineLevelData
            {whereStr}
            """;

        return await ExecuteExportQueryAsync(connectionString, sql, parameters, ct);
    }

    private static (string WhereStr, List<SqlParameter> Parameters) BuildExportFilters(
        List<string>? filterPayerNames, List<string>? filterPanelNames,
        DateOnly? filterFirstBillFrom, DateOnly? filterFirstBillTo, string prefix)
    {
        var where = new List<string>();
        var parms = new List<SqlParameter>();

        if (filterPayerNames is { Count: > 0 })
        {
            var names = filterPayerNames.Select((n, i) => $"@{prefix}pn{i}").ToList();
            where.Add($"LTRIM(RTRIM(PayerName)) IN ({string.Join(",", names)})");
            for (int i = 0; i < filterPayerNames.Count; i++)
                parms.Add(new SqlParameter($"@{prefix}pn{i}", filterPayerNames[i]));
        }

        if (filterPanelNames is { Count: > 0 })
        {
            var names = filterPanelNames.Select((n, i) => $"@{prefix}pl{i}").ToList();
            where.Add($"LTRIM(RTRIM(PanelName)) IN ({string.Join(",", names)})");
            for (int i = 0; i < filterPanelNames.Count; i++)
                parms.Add(new SqlParameter($"@{prefix}pl{i}", filterPanelNames[i]));
        }

        if (filterFirstBillFrom.HasValue)
        {
            where.Add($"TRY_CAST(FirstBilledDate AS DATE) >= @{prefix}fbFrom");
            parms.Add(new SqlParameter($"@{prefix}fbFrom", SqlDbType.Date) { Value = filterFirstBillFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterFirstBillTo.HasValue)
        {
            where.Add($"TRY_CAST(FirstBilledDate AS DATE) <= @{prefix}fbTo");
            parms.Add(new SqlParameter($"@{prefix}fbTo", SqlDbType.Date) { Value = filterFirstBillTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        var whereStr = where.Count > 0 ? "WHERE " + string.Join(" AND ", where) : "";
        return (whereStr, parms);
    }

    private async Task<List<Dictionary<string, object?>>> ExecuteExportQueryAsync(
        string connectionString, string sql, List<SqlParameter> parameters, CancellationToken ct)
    {
        var rows = new List<Dictionary<string, object?>>();
        var sw = System.Diagnostics.Stopwatch.StartNew();

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 300 };
        foreach (var p in parameters)
            cmd.Parameters.Add(new SqlParameter(p.ParameterName, p.SqlDbType) { Value = p.Value });

        await using var r = await cmd.ExecuteReaderAsync(ct);
        var columns = Enumerable.Range(0, r.FieldCount).Select(i => r.GetName(i)).ToArray();

        while (await r.ReadAsync(ct))
        {
            var row = new Dictionary<string, object?>(columns.Length);
            for (int i = 0; i < columns.Length; i++)
                row[columns[i]] = r.IsDBNull(i) ? null : r.GetValue(i);
            rows.Add(row);
        }

        _logger.LogInformation("ProductionReport export query: rows={Count}, elapsed={Ms}ms",
            rows.Count, sw.ElapsedMilliseconds);

        return rows;
    }
}
