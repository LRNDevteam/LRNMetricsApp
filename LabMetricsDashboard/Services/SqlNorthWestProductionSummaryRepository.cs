using LRN.ProductionReports.Models;
using LRN.ProductionReports.Models;
using SharedCodingResult = LRN.ProductionReports.Services.CodingResult;
using SharedCptBreakdownResult = LRN.ProductionReports.Services.CptBreakdownResult;
using SharedPayerBreakdownResult = LRN.ProductionReports.Services.PayerBreakdownResult;
using SharedPayerPanelResult = LRN.ProductionReports.Services.PayerPanelResult;
using SharedProductionReportResult = LRN.ProductionReports.Services.ProductionReportResult;
using SharedRawDataSegment = LRN.ProductionReports.Services.RawDataSegment;
using SharedUnbilledAgingResult = LRN.ProductionReports.Services.UnbilledAgingResult;
using SharedWeeklyClaimVolumeResult = LRN.ProductionReports.Services.WeeklyClaimVolumeResult;
using HighestPayerBreakdownResult = LRN.ProductionReports.Services.HighestPayerBreakdownResult;
using System.Data;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads NorthWest production report data by calling the dbo.usp_GetNW_* stored procedures.
/// With all filter parameters null the SPs serve the pre-aggregated snapshot tables (fast path).
/// When any filter is supplied the SPs aggregate live from dbo.ClaimLevelData / dbo.LineLevelData.
/// </summary>
public sealed class SqlNorthWestProductionSummaryRepository : INorthWestProductionSummaryRepository
{
    private const int ExportSplitThreshold = 300_000;

    private readonly ILogger<SqlNorthWestProductionSummaryRepository> _logger;

    public SqlNorthWestProductionSummaryRepository(ILogger<SqlNorthWestProductionSummaryRepository> logger)
        => _logger = logger;

    // ?? Filter Options ????????????????????????????????????????????????????????
    /// <inheritdoc/>
    /// Prefers pre-aggregated <c>NW_PayerBreakdown</c> / <c>NW_PayerByPanel</c>
    /// (and falls back to <c>DashboardFilterLookup</c>) so Production Summary can open
    /// without scanning the full ClaimLevelData table. Live DISTINCT is last resort.
    public async Task<(List<string> PayerNames, List<string> PanelNames)> GetFilterOptionsAsync(
        string connectionString, CancellationToken ct = default)
    {
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            var fromAggregates = await TryGetFilterOptionsFromAggregatesAsync(conn, ct);
            if (fromAggregates is { PayerNames.Count: > 0 } or { PanelNames.Count: > 0 })
            {
                _logger.LogInformation(
                    "NW GetFilterOptionsAsync: using aggregates (payers={P}, panels={N}).",
                    fromAggregates.Value.PayerNames.Count, fromAggregates.Value.PanelNames.Count);
                return fromAggregates.Value;
            }

            _logger.LogWarning("NW GetFilterOptionsAsync: aggregates empty ? falling back to live ClaimLevelData DISTINCT.");
            return await GetFilterOptionsFromLiveAsync(conn, ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetFilterOptionsAsync failed.");
            return ([], []);
        }
    }

    private static async Task<(List<string> PayerNames, List<string> PanelNames)?> TryGetFilterOptionsFromAggregatesAsync(
        SqlConnection conn, CancellationToken ct)
    {
        // 1) Production snapshot tables (populated by usp_RefreshNW_Payer*)
        try
        {
            await using (var probe = new SqlCommand("""
                SELECT CASE WHEN OBJECT_ID('dbo.NW_PayerBreakdown','U') IS NOT NULL
                              AND EXISTS (SELECT 1 FROM dbo.NW_PayerBreakdown)
                             THEN 1 ELSE 0 END
                """, conn)
            { CommandTimeout = 15 })
            {
                var ok = Convert.ToInt32(await probe.ExecuteScalarAsync(ct)) == 1;
                if (ok)
                {
                    var payers = await ReadDistinctAsync(conn, """
                        SELECT DISTINCT LTRIM(RTRIM(PayerName))
                        FROM dbo.NW_PayerBreakdown
                        WHERE NULLIF(LTRIM(RTRIM(PayerName)), '') IS NOT NULL
                        ORDER BY 1
                        """, ct);
                    var panels = await ReadDistinctAsync(conn, """
                        SELECT DISTINCT LTRIM(RTRIM(PanelType))
                        FROM dbo.NW_PayerByPanel
                        WHERE NULLIF(LTRIM(RTRIM(PanelType)), '') IS NOT NULL
                        ORDER BY 1
                        """, ct);
                    if (payers.Count > 0 || panels.Count > 0)
                        return (payers, panels);
                }
            }
        }
        catch
        {
            // fall through
        }

        // 2) Dashboard filter lookup (populated by usp_RefreshDashboard)
        try
        {
            await using var probe = new SqlCommand("""
                SELECT CASE WHEN OBJECT_ID('dbo.DashboardFilterLookup','U') IS NOT NULL
                              AND EXISTS (SELECT 1 FROM dbo.DashboardFilterLookup)
                             THEN 1 ELSE 0 END
                """, conn)
            { CommandTimeout = 15 };
            var ok = Convert.ToInt32(await probe.ExecuteScalarAsync(ct)) == 1;
            if (!ok) return null;

            var payers = await ReadDistinctAsync(conn, """
                SELECT FilterValue FROM dbo.DashboardFilterLookup
                WHERE FilterType IN (N'PayerName', N'PayerName_Raw')
                  AND NULLIF(LTRIM(RTRIM(FilterValue)), '') IS NOT NULL
                ORDER BY FilterValue
                """, ct);
            var panels = await ReadDistinctAsync(conn, """
                SELECT FilterValue FROM dbo.DashboardFilterLookup
                WHERE FilterType IN (N'PanelType', N'PanelName')
                  AND NULLIF(LTRIM(RTRIM(FilterValue)), '') IS NOT NULL
                ORDER BY FilterValue
                """, ct);
            if (payers.Count > 0 || panels.Count > 0)
                return (payers, panels);
        }
        catch
        {
            // fall through
        }

        return null;
    }

    private static async Task<List<string>> ReadDistinctAsync(
        SqlConnection conn, string sql, CancellationToken ct)
    {
        var list = new List<string>();
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
        await using var rdr = await cmd.ExecuteReaderAsync(ct);
        while (await rdr.ReadAsync(ct))
            if (!rdr.IsDBNull(0)) list.Add(rdr.GetString(0));
        return list;
    }

    private static async Task<(List<string> PayerNames, List<string> PanelNames)> GetFilterOptionsFromLiveAsync(
        SqlConnection conn, CancellationToken ct)
    {
        const string sql = """
            SELECT DISTINCT LTRIM(RTRIM(PayerName_Raw))
            FROM   dbo.ClaimLevelData
            WHERE  NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
              AND  LTRIM(RTRIM(ClaimStatus)) NOT IN (
                       'Unbilled in Daq','Unbilled in Daq - PR',
                       'Unbilled in Webpm','Unbilled in Webpm - PR',
                       'Billed amount 0')
            ORDER BY 1;

            SELECT DISTINCT LTRIM(RTRIM(PanelType))
            FROM   dbo.ClaimLevelData
            WHERE  NULLIF(LTRIM(RTRIM(PanelType)), '') IS NOT NULL
              AND  LTRIM(RTRIM(ClaimStatus)) NOT IN (
                       'Unbilled in Daq','Unbilled in Daq - PR',
                       'Unbilled in Webpm','Unbilled in Webpm - PR',
                       'Billed amount 0')
            ORDER BY 1;
            """;

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 180 };
        await using var rdr = await cmd.ExecuteReaderAsync(ct);

        var payers = new List<string>();
        while (await rdr.ReadAsync(ct))
            if (!rdr.IsDBNull(0)) payers.Add(rdr.GetString(0));
        await rdr.NextResultAsync(ct);
        var panels = new List<string>();
        while (await rdr.ReadAsync(ct))
            if (!rdr.IsDBNull(0)) panels.Add(rdr.GetString(0));
        return (payers, panels);
    }

    // ?? Monthly Claim Volume ??????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<SharedProductionReportResult> GetMonthlyAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        // PayerRank = 0  ? panel-level total across ALL payers.
        // PayerRank 1..N ? ranked payer drill-down rows.
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand("dbo.usp_GetNW_MonthlyBilledProductionSummary", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddNWFilterParameters(cmd, filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var rdr = await cmd.ExecuteReaderAsync(ct);

            var panelMonth    = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var payerMonthMap = new Dictionary<string, Dictionary<string, Dictionary<string, (int c, decimal ch)>>>(StringComparer.OrdinalIgnoreCase);
            var payerRankMap  = new Dictionary<string, Dictionary<string, int>>(StringComparer.OrdinalIgnoreCase);
            var allMonths     = new SortedSet<string>();

            while (await rdr.ReadAsync(ct))
            {
                var panel   = rdr.GetString(0);
                var payer   = rdr.GetString(1);
                var rank    = (int)rdr.GetByte(2);
                var month   = rdr.GetString(3);
                var count   = rdr.GetInt32(4);
                var charges = rdr.GetDecimal(5);

                allMonths.Add(month);

                if (rank == 0)
                {
                    if (!panelMonth.TryGetValue(panel, out var pm)) panelMonth[panel] = pm = [];
                    pm[month] = (count, charges);
                    continue;
                }

                if (!payerMonthMap.TryGetValue(panel, out var payM)) payerMonthMap[panel] = payM = new(StringComparer.OrdinalIgnoreCase);
                if (!payM.TryGetValue(payer, out var mDict)) payM[payer] = mDict = [];
                mDict[month] = mDict.TryGetValue(month, out var md) ? (md.c + count, md.ch + charges) : (count, charges);

                if (!payerRankMap.TryGetValue(panel, out var rankD)) payerRankMap[panel] = rankD = new(StringComparer.OrdinalIgnoreCase);
                rankD[payer] = rank;
            }

            // Fallback: derive panel totals from drill-down rows when PayerRank=0 rows are absent.
            if (panelMonth.Count == 0)
            {
                foreach (var (panel, payM) in payerMonthMap)
                {
                    if (!panelMonth.TryGetValue(panel, out var pm)) panelMonth[panel] = pm = [];
                    foreach (var (_, mDict) in payM)
                        foreach (var (month, v) in mDict)
                            pm[month] = pm.TryGetValue(month, out var p0) ? (p0.c + v.c, p0.ch + v.ch) : v;
                }
            }

            var months       = allMonths.ToList();
            var years        = months.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
            var grandByMonth = new Dictionary<string, ProductionMonthCell>();
            var panelRows    = new List<ProductionPanelRow>();

            foreach (var (panel, pm) in panelMonth.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
            {
                var byMonth = pm.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));

                foreach (var (mk, cell) in byMonth)
                {
                    if (!grandByMonth.TryGetValue(mk, out var g)) grandByMonth[mk] = cell;
                    else grandByMonth[mk] = new ProductionMonthCell(g.ClaimCount + cell.ClaimCount, g.BilledCharges + cell.BilledCharges);
                }

                var topPayers = payerMonthMap.TryGetValue(panel, out var payM2) && payerRankMap.TryGetValue(panel, out var rankD)
                    ? payM2
                        .OrderBy(p => rankD.GetValueOrDefault(p.Key, 99))
                        .Take(3)
                        .Select(p => new ProductionPayerDrillDown
                        {
                            PayerName    = p.Key,
                            ByMonth      = p.Value.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch)),
                            ByYear       = p.Value.GroupBy(kv => int.Parse(kv.Key[..4])).ToDictionary(g => g.Key, g => new ProductionYearTotal(g.Sum(kv => kv.Value.c), g.Sum(kv => kv.Value.ch))),
                            TotalClaims  = p.Value.Values.Sum(v => v.c),
                            TotalCharges = p.Value.Values.Sum(v => v.ch),
                        })
                        .ToList()
                    : [];

                panelRows.Add(new ProductionPanelRow
                {
                    PanelName    = panel,
                    ByMonth      = byMonth,
                    ByYear       = pm.GroupBy(kv => int.Parse(kv.Key[..4])).ToDictionary(g => g.Key, g => new ProductionYearTotal(g.Sum(kv => kv.Value.c), g.Sum(kv => kv.Value.ch))),
                    TotalClaims  = byMonth.Values.Sum(c => c.ClaimCount),
                    TotalCharges = byMonth.Values.Sum(c => c.BilledCharges),
                    TopPayers    = topPayers,
                });
            }

        return new SharedProductionReportResult(
                [],
                panelRows.Select(p => p.PanelName).ToList(),
                months, years, panelRows,
                grandByMonth,
                grandByMonth.Values.Sum(c => c.ClaimCount),
                grandByMonth.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetMonthlyAsync failed.");
        return new SharedProductionReportResult([], [], [], [], [], new Dictionary<string, ProductionMonthCell>(), 0, 0m);
        }
    }

    // ?? Weekly Claim Volume ???????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<SharedWeeklyClaimVolumeResult> GetWeeklyAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand("dbo.usp_GetNW_WeeklyBilledProductionSummary", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddNWFilterParameters(cmd, filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var rdr = await cmd.ExecuteReaderAsync(ct);

            var weekCols     = new Dictionary<string, WeekColumn>();
            var panelWeek    = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var payerWeekMap = new Dictionary<string, Dictionary<string, Dictionary<string, (int c, decimal ch)>>>(StringComparer.OrdinalIgnoreCase);
            var payerRankMap = new Dictionary<string, Dictionary<string, int>>(StringComparer.OrdinalIgnoreCase);

            while (await rdr.ReadAsync(ct))
            {
                var panel     = rdr.GetString(0);
                var payer     = rdr.GetString(1);
                var rank      = (int)rdr.GetByte(2);
                var weekStart = DateOnly.FromDateTime(rdr.GetDateTime(3));
                var weekEnd   = DateOnly.FromDateTime(rdr.GetDateTime(4));
                var count     = rdr.GetInt32(6);
                var charges   = rdr.GetDecimal(7);
                var weekKey   = weekStart.ToString("yyyy-MM-dd");

                if (!weekCols.ContainsKey(weekKey))
                    weekCols[weekKey] = new WeekColumn(weekKey, weekStart, weekEnd);

                if (rank == 0)
                {
                    if (!panelWeek.TryGetValue(panel, out var pw)) panelWeek[panel] = pw = [];
                    pw[weekKey] = (count, charges);
                    continue;
                }

                if (!payerWeekMap.TryGetValue(panel, out var payW)) payerWeekMap[panel] = payW = new(StringComparer.OrdinalIgnoreCase);
                if (!payW.TryGetValue(payer, out var wDict)) payW[payer] = wDict = [];
                wDict[weekKey] = wDict.TryGetValue(weekKey, out var wd) ? (wd.c + count, wd.ch + charges) : (count, charges);

                if (!payerRankMap.TryGetValue(panel, out var rankD)) payerRankMap[panel] = rankD = new(StringComparer.OrdinalIgnoreCase);
                rankD[payer] = rank;
            }

            // Fallback when PayerRank=0 rows are absent.
            if (panelWeek.Count == 0)
            {
                foreach (var (panel, payW) in payerWeekMap)
                {
                    if (!panelWeek.TryGetValue(panel, out var pw)) panelWeek[panel] = pw = [];
                    foreach (var (_, wDict) in payW)
                        foreach (var (wk, v) in wDict)
                            pw[wk] = pw.TryGetValue(wk, out var p0) ? (p0.c + v.c, p0.ch + v.ch) : v;
                }
            }

            // Oldest ? newest (left ? right) to match UI convention.
            var columns     = weekCols.Values.OrderBy(w => w.WeekStart).ToList();
            var panelRows   = new List<WeeklyPanelRow>();
            var grandByWeek = new Dictionary<string, ProductionMonthCell>();

            foreach (var (panel, pw) in panelWeek.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
            {
                var byWeek = pw.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));

                foreach (var (wk, cell) in byWeek)
                {
                    if (!grandByWeek.TryGetValue(wk, out var g)) grandByWeek[wk] = cell;
                    else grandByWeek[wk] = new ProductionMonthCell(g.ClaimCount + cell.ClaimCount, g.BilledCharges + cell.BilledCharges);
                }

                var topPayers = payerWeekMap.TryGetValue(panel, out var payW2) && payerRankMap.TryGetValue(panel, out var rankD)
                    ? payW2
                        .OrderBy(p => rankD.GetValueOrDefault(p.Key, 99))
                        .Take(3)
                        .Select(p => new WeeklyPayerDrillDown
                        {
                            PayerName    = p.Key,
                            ByWeek       = p.Value.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch)),
                            TotalClaims  = p.Value.Values.Sum(v => v.c),
                            TotalCharges = p.Value.Values.Sum(v => v.ch),
                        })
                        .ToList()
                    : [];

                panelRows.Add(new WeeklyPanelRow
                {
                    PanelName    = panel,
                    ByWeek       = byWeek,
                    TotalClaims  = byWeek.Values.Sum(c => c.ClaimCount),
                    TotalCharges = byWeek.Values.Sum(c => c.BilledCharges),
                    TopPayers    = topPayers,
                });
            }

        return new SharedWeeklyClaimVolumeResult(
                columns, panelRows, grandByWeek,
                grandByWeek.Values.Sum(c => c.ClaimCount),
                grandByWeek.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetWeeklyAsync failed.");
        return new SharedWeeklyClaimVolumeResult([], [], new Dictionary<string, ProductionMonthCell>(), 0, 0m);
        }
    }

    // ?? Coding ???????????????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<SharedCodingResult> GetCodingAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand("dbo.usp_GetNW_CodingBreakdown", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddNWFilterParameters(cmd, filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);

            var panelMap = new Dictionary<string, (int c, decimal ch)>(StringComparer.OrdinalIgnoreCase);
            var cptMap   = new Dictionary<string, List<CodingCptDrillDown>>(StringComparer.OrdinalIgnoreCase);

            await using var rdr = await cmd.ExecuteReaderAsync(ct);

            // RS1: PanelName, ClaimCount, TotalCharges
            while (await rdr.ReadAsync(ct))
                panelMap[rdr.GetString(0)] = (rdr.GetInt32(1), rdr.GetDecimal(2));

            // RS2: PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges
            if (await rdr.NextResultAsync(ct))
            {
                while (await rdr.ReadAsync(ct))
                {
                    var panel = rdr.GetString(0);
                    if (!cptMap.TryGetValue(panel, out var list)) cptMap[panel] = list = [];
                    list.Add(new CodingCptDrillDown
                    {
                        CptCodeUnitsModifier = rdr.GetString(1),
                        ClaimCount           = rdr.GetInt32(2),
                        TotalCharges         = rdr.GetDecimal(3),
                    });
                }
            }

            var panelRows = panelMap
                .OrderByDescending(kv => kv.Value.ch)
                .Select(kv => new CodingPanelRow
                {
                    PanelName    = kv.Key,
                    ClaimCount   = kv.Value.c,
                    TotalCharges = kv.Value.ch,
                    CptRows      = cptMap.GetValueOrDefault(kv.Key) ?? [],
                })
                .ToList();

        return new SharedCodingResult(panelRows, panelRows.Sum(r => r.ClaimCount), panelRows.Sum(r => r.TotalCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetCodingAsync failed.");
        return new SharedCodingResult([], 0, 0m);
        }
    }

    // ?? Payer Breakdown ???????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<SharedPayerBreakdownResult> GetPayerBreakdownAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand("dbo.usp_GetNW_PayerBreakdown", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddNWFilterParameters(cmd, filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var rdr = await cmd.ExecuteReaderAsync(ct);

            var payerMonth = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var allMonths  = new SortedSet<string>();

            while (await rdr.ReadAsync(ct))
            {
                var payer   = rdr.GetString(0);
                var month   = rdr.GetString(1);
                var count   = rdr.GetInt32(2);
                var charges = ReadDecimalByNameOrIndex(rdr, 3, "TotalCharges", "ChargeAmount", "BilledCharges");

                allMonths.Add(month);
                if (!payerMonth.TryGetValue(payer, out var mm)) payerMonth[payer] = mm = [];
                var prev = mm.GetValueOrDefault(month);
                mm[month] = (prev.c + count, prev.ch + charges);
            }

            var months              = allMonths.ToList();
            var years               = months.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
            var grandByMonth        = new Dictionary<string, int>();
            var grandChargesByMonth = new Dictionary<string, decimal>();
            var payerRows           = new List<PayerBreakdownRow>();

            foreach (var (payer, mm) in payerMonth.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
            {
                var byYear = years.ToDictionary(
                    y => y,
                    y => mm.Where(kv => kv.Key.StartsWith($"{y:D4}")).Sum(kv => kv.Value.c));
                var byYearCharges = years.ToDictionary(
                    y => y,
                    y => mm.Where(kv => kv.Key.StartsWith($"{y:D4}")).Sum(kv => kv.Value.ch));

                foreach (var (mk, v) in mm)
                {
                    grandByMonth[mk]        = grandByMonth.GetValueOrDefault(mk) + v.c;
                    grandChargesByMonth[mk] = grandChargesByMonth.GetValueOrDefault(mk) + v.ch;
                }

                payerRows.Add(new PayerBreakdownRow
                {
                    PayerName         = payer,
                    ByMonth           = mm.ToDictionary(kv => kv.Key, kv => kv.Value.c),
                    ByYear            = byYear,
                    GrandTotal        = mm.Values.Sum(v => v.c),
                    ByMonthCharges    = mm.ToDictionary(kv => kv.Key, kv => kv.Value.ch),
                    ByYearCharges     = byYearCharges,
                    GrandTotalCharges = mm.Values.Sum(v => v.ch),
                });
            }

        return new SharedPayerBreakdownResult(
            months, years, payerRows, grandByMonth, grandByMonth.Values.Sum(),
            grandChargesByMonth, grandChargesByMonth.Values.Sum());
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetPayerBreakdownAsync failed.");
        return new SharedPayerBreakdownResult([], [], [], new Dictionary<string, int>(), 0);
        }
    }

    // ?? Panel Breakdown ???????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<SharedPayerBreakdownResult> GetPanelBreakdownAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            try
            {
                await using var cmd = new SqlCommand("dbo.usp_GetNW_PanelBreakdown", conn)
                {
                    CommandType    = CommandType.StoredProcedure,
                    CommandTimeout = 180,
                };
                AddNWFilterParameters(cmd, filterPayerNames, filterPanelNames,
                    filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo,
                    filterFirstBilledFrom, filterFirstBilledTo);
                await using var rdr = await cmd.ExecuteReaderAsync(ct);
                return await ReadPanelOrPayerBreakdownAsync(rdr, ct);
            }
            catch (SqlException ex) when (ex.Number is 2812 or 208)
            {
                _logger.LogWarning(ex,
                    "NW usp_GetNW_PanelBreakdown not deployed; using live ClaimLevelData query.");
            }

            await using var liveCmd = new SqlCommand(BuildNwPanelBreakdownLiveSql(), conn)
            {
                CommandTimeout = 180,
            };
            AddNWFilterParameters(liveCmd, filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var liveRdr = await liveCmd.ExecuteReaderAsync(ct);
            return await ReadPanelOrPayerBreakdownAsync(liveRdr, ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetPanelBreakdownAsync failed.");
            return new SharedPayerBreakdownResult([], [], [], new Dictionary<string, int>(), 0);
        }
    }

    private static async Task<SharedPayerBreakdownResult> ReadPanelOrPayerBreakdownAsync(
        SqlDataReader rdr, CancellationToken ct)
    {
        var rowMonth = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
        var allMonths = new SortedSet<string>();

        while (await rdr.ReadAsync(ct))
        {
            var name    = rdr.GetString(0);
            var month   = rdr.GetString(1);
            var count   = rdr.GetInt32(2);
            var charges = ReadDecimalByNameOrIndex(rdr, 3, "TotalCharges", "ChargeAmount", "BilledCharges");

            allMonths.Add(month);
            if (!rowMonth.TryGetValue(name, out var mm)) rowMonth[name] = mm = [];
            var prev = mm.GetValueOrDefault(month);
            mm[month] = (prev.c + count, prev.ch + charges);
        }

        var months              = allMonths.ToList();
        var years               = months.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
        var grandByMonth        = new Dictionary<string, int>();
        var grandChargesByMonth = new Dictionary<string, decimal>();
        var rows                = new List<PayerBreakdownRow>();

        foreach (var (name, mm) in rowMonth.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
        {
            var byYear = years.ToDictionary(
                y => y,
                y => mm.Where(kv => kv.Key.StartsWith($"{y:D4}")).Sum(kv => kv.Value.c));
            var byYearCharges = years.ToDictionary(
                y => y,
                y => mm.Where(kv => kv.Key.StartsWith($"{y:D4}")).Sum(kv => kv.Value.ch));

            foreach (var (mk, v) in mm)
            {
                grandByMonth[mk]        = grandByMonth.GetValueOrDefault(mk) + v.c;
                grandChargesByMonth[mk] = grandChargesByMonth.GetValueOrDefault(mk) + v.ch;
            }

            rows.Add(new PayerBreakdownRow
            {
                PayerName         = name,
                ByMonth           = mm.ToDictionary(kv => kv.Key, kv => kv.Value.c),
                ByYear            = byYear,
                GrandTotal        = mm.Values.Sum(v => v.c),
                ByMonthCharges    = mm.ToDictionary(kv => kv.Key, kv => kv.Value.ch),
                ByYearCharges     = byYearCharges,
                GrandTotalCharges = mm.Values.Sum(v => v.ch),
            });
        }

        return new SharedPayerBreakdownResult(
            months, years, rows, grandByMonth, grandByMonth.Values.Sum(),
            grandChargesByMonth, grandChargesByMonth.Values.Sum());
    }

    private static string BuildNwPanelBreakdownLiveSql() => """
        DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
        DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

        IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
            INSERT INTO @PayerList(Value)
            SELECT DISTINCT LTRIM(RTRIM(value))
            FROM STRING_SPLIT(@PayerNames, '|')
            WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

        IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
            INSERT INTO @PanelList(Value)
            SELECT DISTINCT LTRIM(RTRIM(value))
            FROM STRING_SPLIT(@PanelNames, '|')
            WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

        DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
        DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

        SELECT
            LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)), ''), 'Unknown'))) AS PanelName,
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')               AS BilledYearMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                    AS ClaimCount,
            ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)              AS TotalCharges
        FROM   dbo.ClaimLevelData
        WHERE  LTRIM(RTRIM(ClaimStatus)) NOT IN (
                   'Unbilled in Daq','Unbilled in Daq - PR',
                   'Unbilled in Webpm','Unbilled in Webpm - PR',
                   'Billed amount 0')
          AND  TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND  (
                   (TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
                    AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> '')
                OR TRY_CAST(EmedixSubmissionDate AS DATE) IS NOT NULL
               )
          AND  (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND  (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), 'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
          AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
          AND  (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
          AND  (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
          AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
          AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)), ''), 'Unknown'))),
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
        ORDER BY PanelName, BilledYearMonth
        """;

    // ?? Insight Daq / WebPM ???????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<SharedPayerBreakdownResult> GetInsightBreakdownAsync(
        string connectionString,
        string source,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        var sourceName = source.StartsWith("Web", StringComparison.OrdinalIgnoreCase) ? "Webpm" : "Daq";
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            try
            {
                await using var cmd = new SqlCommand("dbo.usp_GetNW_InsightBreakdown", conn)
                {
                    CommandType    = CommandType.StoredProcedure,
                    CommandTimeout = 180,
                };
                cmd.Parameters.Add(new SqlParameter("@Source", SqlDbType.NVarChar, 20) { Value = sourceName });
                AddNWFilterParameters(cmd, filterPayerNames, filterPanelNames,
                    filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo,
                    filterFirstBilledFrom, filterFirstBilledTo);
                await using var rdr = await cmd.ExecuteReaderAsync(ct);
                return TakeTopPayers(await ReadPanelOrPayerBreakdownAsync(rdr, ct), 10);
            }
            catch (SqlException ex) when (ex.Number is 2812 or 208)
            {
                _logger.LogWarning(ex,
                    "NW usp_GetNW_InsightBreakdown not deployed; using live ClaimLevelData query. Source={Source}",
                    sourceName);
            }

            await using var liveCmd = new SqlCommand(BuildNwInsightLiveSql(), conn)
            {
                CommandTimeout = 180,
            };
            liveCmd.Parameters.Add(new SqlParameter("@Source", SqlDbType.NVarChar, 20) { Value = sourceName });
            AddNWFilterParameters(liveCmd, filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var liveRdr = await liveCmd.ExecuteReaderAsync(ct);
            return TakeTopPayers(await ReadPanelOrPayerBreakdownAsync(liveRdr, ct), 10);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetInsightBreakdownAsync failed. Source={Source}", sourceName);
            return new SharedPayerBreakdownResult([], [], [], new Dictionary<string, int>(), 0);
        }
    }

    private static SharedPayerBreakdownResult TakeTopPayers(SharedPayerBreakdownResult result, int top)
    {
        if (result.PayerRows.Count <= top) return result;
        var topRows = result.PayerRows.Take(top).ToList();
        var names = topRows.Select(r => r.PayerName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var months = result.Months;
        var grandByMonth = months.ToDictionary(m => m, m => topRows.Sum(r => r.ByMonth.GetValueOrDefault(m)));
        var grandCharges = months.ToDictionary(m => m, m => topRows.Sum(r => r.ByMonthCharges.GetValueOrDefault(m)));
        return new SharedPayerBreakdownResult(
            months, result.Years, topRows, grandByMonth, grandByMonth.Values.Sum(),
            grandCharges, grandCharges.Values.Sum());
    }

    private static string BuildNwInsightLiveSql() => """
        DECLARE @SourceName NVARCHAR(20) =
            CASE WHEN UPPER(LTRIM(RTRIM(@Source))) LIKE 'WEBPM%' THEN N'Webpm' ELSE N'Daq' END;

        DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL);
        DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL);

        IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
            INSERT INTO @PayerList(Value)
            SELECT DISTINCT LTRIM(RTRIM(value))
            FROM STRING_SPLIT(@PayerNames, '|')
            WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

        IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
            INSERT INTO @PanelList(Value)
            SELECT DISTINCT LTRIM(RTRIM(value))
            FROM STRING_SPLIT(@PanelNames, '|')
            WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

        DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
        DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

        ;WITH Agg AS
        (
            SELECT
                LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
                FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
                COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
            FROM dbo.ClaimLevelData
            CROSS APPLY (
                SELECT LTRIM(RTRIM(ISNULL(dbo.GetAdditionalField(AdditionalFields, 'Source'), ''))) AS SourceValue
            ) src
            WHERE LTRIM(RTRIM(ClaimStatus)) NOT IN (
                      'Unbilled in Daq','Unbilled in Daq - PR',
                      'Unbilled in Webpm','Unbilled in Webpm - PR',
                      'Billed amount 0')
              AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
              AND (
                      (TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
                       AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> '')
                   OR TRY_CAST(EmedixSubmissionDate AS DATE) IS NOT NULL
                  )
              AND (
                      (@SourceName = N'Daq'   AND UPPER(src.SourceValue) LIKE 'DAQ%')
                   OR (@SourceName = N'Webpm' AND UPPER(src.SourceValue) LIKE 'WEBPM%')
                  )
              AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
              AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), 'Unknown'))) IN (SELECT Value FROM @PanelList))
              AND (@DosFrom          IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
              AND (@DosTo            IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
              AND (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
              AND (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
              AND (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
              AND (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
            GROUP BY
                LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
                FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
        ),
        Top10 AS
        (
            SELECT PayerName
            FROM (
                SELECT PayerName,
                       ROW_NUMBER() OVER (ORDER BY SUM(ClaimCount) DESC, PayerName) AS rn
                FROM Agg
                GROUP BY PayerName
            ) x
            WHERE rn <= 10
        )
        SELECT a.PayerName, a.BilledYearMonth, a.ClaimCount, a.TotalCharges
        FROM Agg a
        INNER JOIN Top10 t ON t.PayerName = a.PayerName
        ORDER BY a.PayerName, a.BilledYearMonth
        """;

    /// <inheritdoc/>
    public async Task<HighestPayerBreakdownResult> GetHighestPayerBreakdownAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            try
            {
                await using var cmd = new SqlCommand("dbo.usp_GetNW_HighestPayerBreakdown", conn)
                {
                    CommandType    = CommandType.StoredProcedure,
                    CommandTimeout = 180,
                };
                AddNWFilterParameters(cmd, filterPayerNames, filterPanelNames,
                    filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo,
                    filterFirstBilledFrom, filterFirstBilledTo);
                await using var rdr = await cmd.ExecuteReaderAsync(ct);
                return await ReadHighestPayerBreakdownAsync(rdr, ct);
            }
            catch (SqlException ex) when (ex.Number is 2812 or 208)
            {
                _logger.LogWarning(ex,
                    "NW usp_GetNW_HighestPayerBreakdown not deployed; using live ClaimLevelData query.");
            }

            await using var liveCmd = new SqlCommand(BuildNwHighestPayerLiveSql(), conn)
            {
                CommandTimeout = 180,
            };
            AddNWFilterParameters(liveCmd, filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var liveRdr = await liveCmd.ExecuteReaderAsync(ct);
            return await ReadHighestPayerBreakdownAsync(liveRdr, ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetHighestPayerBreakdownAsync failed.");
            return new HighestPayerBreakdownResult([], [], [], new Dictionary<string, ProductionMonthCell>(), 0, 0);
        }
    }

    private static async Task<HighestPayerBreakdownResult> ReadHighestPayerBreakdownAsync(
        SqlDataReader rdr, CancellationToken ct)
    {
        var data = new Dictionary<string, Dictionary<string, Dictionary<string, (int c, decimal ch)>>>(
            StringComparer.OrdinalIgnoreCase);
        var allMonths = new SortedSet<string>();

        while (await rdr.ReadAsync(ct))
        {
            var source  = rdr.GetString(0);
            var payer   = rdr.GetString(1);
            var month   = rdr.GetString(2);
            var count   = rdr.GetInt32(3);
            var charges = ReadDecimalByNameOrIndex(rdr, 4, "TotalCharges", "ChargeAmount", "BilledCharges");

            allMonths.Add(month);
            if (!data.TryGetValue(source, out var payers))
                data[source] = payers = new(StringComparer.OrdinalIgnoreCase);
            if (!payers.TryGetValue(payer, out var mm))
                payers[payer] = mm = [];
            var prev = mm.GetValueOrDefault(month);
            mm[month] = (prev.c + count, prev.ch + charges);
        }

        var months = allMonths.ToList();
        var years  = months.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
        var grandByMonth = new Dictionary<string, ProductionMonthCell>();
        var sourceRows = new List<ProductionPanelRow>();

        foreach (var (source, payers) in data.OrderByDescending(s => s.Value.Sum(p => p.Value.Values.Sum(v => v.c))))
        {
            var payerRows = new List<ProductionPayerDrillDown>();
            var sourceMonth = new Dictionary<string, (int c, decimal ch)>();

            foreach (var (payer, mm) in payers.OrderByDescending(p => p.Value.Values.Sum(v => v.c)))
            {
                foreach (var (mk, v) in mm)
                {
                    var prev = sourceMonth.GetValueOrDefault(mk);
                    sourceMonth[mk] = (prev.c + v.c, prev.ch + v.ch);
                }

                payerRows.Add(new ProductionPayerDrillDown
                {
                    PayerName    = payer,
                    ByMonth      = mm.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch)),
                    ByYear       = years.ToDictionary(
                        y => y,
                        y => new ProductionYearTotal(
                            mm.Where(kv => kv.Key.StartsWith($"{y:D4}")).Sum(kv => kv.Value.c),
                            mm.Where(kv => kv.Key.StartsWith($"{y:D4}")).Sum(kv => kv.Value.ch))),
                    TotalClaims  = mm.Values.Sum(v => v.c),
                    TotalCharges = mm.Values.Sum(v => v.ch),
                });
            }

            foreach (var (mk, v) in sourceMonth)
            {
                var g = grandByMonth.GetValueOrDefault(mk) ?? new ProductionMonthCell(0, 0m);
                grandByMonth[mk] = new ProductionMonthCell(g.ClaimCount + v.c, g.BilledCharges + v.ch);
            }

            sourceRows.Add(new ProductionPanelRow
            {
                PanelName    = source,
                ByMonth      = sourceMonth.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch)),
                ByYear       = years.ToDictionary(
                    y => y,
                    y => new ProductionYearTotal(
                        sourceMonth.Where(kv => kv.Key.StartsWith($"{y:D4}")).Sum(kv => kv.Value.c),
                        sourceMonth.Where(kv => kv.Key.StartsWith($"{y:D4}")).Sum(kv => kv.Value.ch))),
                TotalClaims  = sourceMonth.Values.Sum(v => v.c),
                TotalCharges = sourceMonth.Values.Sum(v => v.ch),
                TopPayers    = payerRows,
            });
        }

        return new HighestPayerBreakdownResult(
            months, years, sourceRows, grandByMonth,
            grandByMonth.Values.Sum(v => v.ClaimCount),
            grandByMonth.Values.Sum(v => v.BilledCharges));
    }

    private static string BuildNwHighestPayerLiveSql() => """
        DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL);
        DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL);

        IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
            INSERT INTO @PayerList(Value)
            SELECT DISTINCT LTRIM(RTRIM(value))
            FROM STRING_SPLIT(@PayerNames, '|')
            WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

        IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
            INSERT INTO @PanelList(Value)
            SELECT DISTINCT LTRIM(RTRIM(value))
            FROM STRING_SPLIT(@PanelNames, '|')
            WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

        DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
        DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

        SELECT
            CASE
                WHEN UPPER(src.SourceValue) LIKE 'DAQ%'   THEN N'Daq'
                WHEN UPPER(src.SourceValue) LIKE 'WEBPM%' THEN N'WebPM'
            END AS SourceName,
            ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), N'* none *') AS PayerName,
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount,
            ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
        FROM dbo.ClaimLevelData
        CROSS APPLY (
            SELECT LTRIM(RTRIM(ISNULL(dbo.GetAdditionalField(AdditionalFields, 'Source'), ''))) AS SourceValue
        ) src
        WHERE LTRIM(RTRIM(ClaimStatus)) NOT IN (
                  'Unbilled in Daq','Unbilled in Daq - PR',
                  'Unbilled in Webpm','Unbilled in Webpm - PR',
                  'Billed amount 0')
          AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND (
                  (TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
                   AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> '')
               OR TRY_CAST(EmedixSubmissionDate AS DATE) IS NOT NULL
              )
          AND (
                  UPPER(src.SourceValue) LIKE 'DAQ%'
               OR UPPER(src.SourceValue) LIKE 'WEBPM%'
              )
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList)
               OR ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), N'* none *') IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), 'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom          IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
          AND (@DosTo            IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
          AND (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
          AND (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
        GROUP BY
            CASE
                WHEN UPPER(src.SourceValue) LIKE 'DAQ%'   THEN N'Daq'
                WHEN UPPER(src.SourceValue) LIKE 'WEBPM%' THEN N'WebPM'
            END,
            ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), N'* none *'),
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
        ORDER BY SourceName, PayerName, BilledYearMonth
        """;

    // ?? Payer ? Panel ?????????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<SharedPayerPanelResult> GetPayerByPanelAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand("dbo.usp_GetNW_PayerByPanel", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddNWFilterParameters(cmd, filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var rdr = await cmd.ExecuteReaderAsync(ct);

            var payerPanel = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var allPanels  = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);

            while (await rdr.ReadAsync(ct))
            {
                var payer   = rdr.GetString(0);
                var panel   = rdr.GetString(1);
                var count   = rdr.GetInt32(2);
                var charges = rdr.GetDecimal(3);

                allPanels.Add(panel);
                if (!payerPanel.TryGetValue(payer, out var pp)) payerPanel[payer] = pp = new(StringComparer.OrdinalIgnoreCase);
                pp[panel] = (pp.GetValueOrDefault(panel).c + count, pp.GetValueOrDefault(panel).ch + charges);
            }

            var panelCols  = allPanels.ToList();
            var grandPanel = new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase);
            var payerRows  = new List<PayerPanelRow>();

            foreach (var (payer, pp) in payerPanel.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
            {
                var byPanel = pp.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));
                foreach (var (pk, cell) in byPanel)
                {
                    if (!grandPanel.TryGetValue(pk, out var g)) grandPanel[pk] = cell;
                    else grandPanel[pk] = new ProductionMonthCell(g.ClaimCount + cell.ClaimCount, g.BilledCharges + cell.BilledCharges);
                }
                payerRows.Add(new PayerPanelRow
                {
                    PayerName         = payer,
                    ByPanel           = byPanel,
                    GrandTotalClaims  = byPanel.Values.Sum(c => c.ClaimCount),
                    GrandTotalCharges = byPanel.Values.Sum(c => c.BilledCharges),
                });
            }

        return new SharedPayerPanelResult(
                panelCols, payerRows, grandPanel,
                grandPanel.Values.Sum(c => c.ClaimCount),
                grandPanel.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetPayerByPanelAsync failed.");
        return new SharedPayerPanelResult([], [], new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase), 0, 0m);
        }
    }

    // ?? Unbilled ? Aging ?????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<SharedUnbilledAgingResult> GetUnbilledAgingAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        // SP returns: PayerName, AgingBucket, ClaimCount, TotalCharges
        // PayerName is mapped to the PanelName slot in UnbilledAgingRow (NW convention).
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand("dbo.usp_GetNW_UnbilledAging", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddNWFilterParameters(cmd, filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var rdr = await cmd.ExecuteReaderAsync(ct);

            var rowBucket  = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var allBuckets = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);

            while (await rdr.ReadAsync(ct))
            {
                var payer   = rdr.GetString(0);
                var aging   = rdr.IsDBNull(1) ? "Unknown" : rdr.GetString(1);
                var count   = rdr.GetInt32(2);
                var charges = rdr.GetDecimal(3);

                allBuckets.Add(aging);
                if (!rowBucket.TryGetValue(payer, out var rb)) rowBucket[payer] = rb = new(StringComparer.OrdinalIgnoreCase);
                rb[aging] = (rb.GetValueOrDefault(aging).c + count, rb.GetValueOrDefault(aging).ch + charges);
            }

            var grandByBucket = new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase);
            var panelRows     = new List<UnbilledAgingRow>();

            foreach (var (payer, rb) in rowBucket.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
            {
                var byBucket = rb.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));
                foreach (var (bk, cell) in byBucket)
                {
                    if (!grandByBucket.TryGetValue(bk, out var g)) grandByBucket[bk] = cell;
                    else grandByBucket[bk] = new ProductionMonthCell(g.ClaimCount + cell.ClaimCount, g.BilledCharges + cell.BilledCharges);
                }
                panelRows.Add(new UnbilledAgingRow
                {
                    PanelName         = payer,   // NW: row key is PayerName mapped to PanelName slot
                    ByBucket          = byBucket,
                    GrandTotalClaims  = byBucket.Values.Sum(c => c.ClaimCount),
                    GrandTotalCharges = byBucket.Values.Sum(c => c.BilledCharges),
                });
            }

        return new SharedUnbilledAgingResult(
                panelRows, grandByBucket,
                grandByBucket.Values.Sum(c => c.ClaimCount),
                grandByBucket.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetUnbilledAgingAsync failed.");
        return new SharedUnbilledAgingResult([], new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase), 0, 0m);
        }
    }

    // ?? CPT Breakdown ?????????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<SharedCptBreakdownResult> GetCptBreakdownAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        // SP returns: CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
        // Billed Units is COUNT(Units), not SUM(Units). CPTCount is COUNT(*) of line rows.
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand("dbo.usp_GetNW_CPTBreakdown", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddNWFilterParameters(cmd, filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var rdr = await cmd.ExecuteReaderAsync(ct);

            var cptMonth  = new Dictionary<string, Dictionary<string, (decimal units, decimal ch, int claims)>>(StringComparer.OrdinalIgnoreCase);
            var allMonths = new SortedSet<string>();

            while (await rdr.ReadAsync(ct))
            {
                var payer      = rdr.GetString(0);
                var month      = rdr.GetString(1);
                var claimCount = rdr.GetInt32(2);           // CPTCount = COUNT(*) of line rows
                // Billed Units = COUNT(Units), not SUM(Units). CPTCount is the count of
                // unit/line rows already returned by the SP (snapshot and live).
                var units      = claimCount;
                var charges    = ReadDecimalByNameOrIndex(rdr, 4, "TotalCharges", "BilledCharges", "ChargeAmount");

                allMonths.Add(month);
                if (!cptMonth.TryGetValue(payer, out var mm)) cptMonth[payer] = mm = [];
                var prev = mm.GetValueOrDefault(month);
                mm[month] = (prev.units + units, prev.ch + charges, prev.claims + claimCount);
            }

            var months       = allMonths.ToList();
            var years        = months.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
            var grandByMonth = new Dictionary<string, CptBreakdownCell>();
            var cptRows      = new List<CptBreakdownRow>();

            foreach (var (payer, mm) in cptMonth.OrderByDescending(x => x.Value.Values.Sum(v => v.ch)))
            {
                var byMonth = mm.ToDictionary(kv => kv.Key,
                    kv => new CptBreakdownCell(kv.Value.units, kv.Value.ch, kv.Value.claims));
                var byYear  = years.ToDictionary(y => y, y =>
                {
                    var cells = mm.Where(kv => kv.Key.StartsWith($"{y:D4}")).Select(kv => kv.Value).ToList();
                    return new CptBreakdownCell(
                        cells.Sum(c => c.units),
                        cells.Sum(c => c.ch),
                        cells.Sum(c => c.claims));
                });

                foreach (var (mk, cell) in byMonth)
                {
                    if (!grandByMonth.TryGetValue(mk, out var g)) grandByMonth[mk] = cell;
                    else grandByMonth[mk] = new CptBreakdownCell(
                        g.Units + cell.Units, g.BilledCharges + cell.BilledCharges, g.ClaimCount + cell.ClaimCount);
                }

                cptRows.Add(new CptBreakdownRow
                {
                    CptCode           = payer,
                    ByMonth           = byMonth,
                    ByYear            = byYear,
                    GrandTotalUnits   = byMonth.Values.Sum(c => c.Units),
                    GrandTotalCharges = byMonth.Values.Sum(c => c.BilledCharges),
                    GrandTotalClaims  = byMonth.Values.Sum(c => c.ClaimCount),
                });
            }

        return new SharedCptBreakdownResult(
                months, years, cptRows, grandByMonth,
                grandByMonth.Values.Sum(c => c.Units),
                grandByMonth.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetCptBreakdownAsync failed.");
        return new SharedCptBreakdownResult([], [], [], new Dictionary<string, CptBreakdownCell>(), 0m, 0m);
        }
    }

    // ?? ClaimLevelData / LineLevelData raw export ??????????????????????????

    /// <inheritdoc/>
    public async Task<List<Dictionary<string, object?>>> GetClaimLevelDataExportAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        try
        {
            var (sql, parameters) = BuildNwClaimLevelExportQuery(
                filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);

            return await ExecuteNwExportQueryAsync(connectionString, sql, parameters, "ClaimLevelData", ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetClaimLevelDataExportAsync failed.");
            return [];
        }
    }

    /// <inheritdoc/>
    public Task<List<SharedRawDataSegment>> GetClaimLevelDataExportSegmentsAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var parts = BuildNwClaimLevelExportParts(
            filterPayerNames, filterPanelNames,
            filterDosFrom, filterDosTo,
            filterFirstBillFrom, filterFirstBillTo,
            filterFirstBilledFrom, filterFirstBilledTo);

        return GetNwRawDataExportSegmentsAsync(connectionString, "ClaimLevel", parts, ct);
    }

    /// <inheritdoc/>
    public Task<List<SharedRawDataSegment>> GetLineLevelDataExportSegmentsAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var parts = BuildNwLineLevelExportParts(
            filterPayerNames, filterPanelNames,
            filterDosFrom, filterDosTo,
            filterFirstBillFrom, filterFirstBillTo,
            filterFirstBilledFrom, filterFirstBilledTo);

        return GetNwRawDataExportSegmentsAsync(connectionString, "LineLevel", parts, ct);
    }

    /// <inheritdoc/>
    public async Task<List<Dictionary<string, object?>>> GetLineLevelDataExportAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        try
        {
            var (sql, parameters) = BuildNwLineLevelExportQuery(
                filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);

            return await ExecuteNwExportQueryAsync(connectionString, sql, parameters, "LineLevelData", ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetLineLevelDataExportAsync failed.");
            return [];
        }
    }

    // Builds the ClaimLevelData export SELECT with NW filter semantics.
    // NW-specific: filters on PanelType (not PanelName), PayerName_Raw, and excludes unbilled statuses.
    private static (string Sql, List<SqlParameter> Parameters) BuildNwClaimLevelExportQuery(
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        DateOnly? filterDosFrom,
        DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom,
        DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom,
        DateOnly? filterFirstBilledTo)
    {
        var parts = BuildNwClaimLevelExportParts(
            filterPayerNames, filterPanelNames,
            filterDosFrom, filterDosTo,
            filterFirstBillFrom, filterFirstBillTo,
            filterFirstBilledFrom, filterFirstBilledTo);

        var sql = $"""
            SELECT {parts.SelectColumns}
            FROM   {parts.FromClause}
            {parts.WhereClause}
            ORDER BY {parts.OrderBy}
            """;

        return (sql, parts.Parameters);
    }

    private static NwExportSqlParts BuildNwClaimLevelExportParts(
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        DateOnly? filterDosFrom,
        DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom,
        DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom,
        DateOnly? filterFirstBilledTo)
    {
        var where  = new List<string>
        {
            "LTRIM(RTRIM(c.ClaimStatus)) NOT IN " +
            "('Unbilled in Daq','Unbilled in Daq - PR','Unbilled in Webpm','Unbilled in Webpm - PR','Billed amount 0')"
        };
        var parms  = new List<SqlParameter>();

        AddNwInClause(where, parms, "LTRIM(RTRIM(c.PayerName_Raw))", "@xpn", filterPayerNames);
        AddNwInClause(where, parms, "LTRIM(RTRIM(c.PanelType))",     "@xpl", filterPanelNames);
        AddNwDateFiltersAliased(where, parms, "x", "c",
            filterDosFrom, filterDosTo,
            filterFirstBillFrom, filterFirstBillTo,
            filterFirstBilledFrom, filterFirstBilledTo);

        var whereStr = "WHERE " + string.Join(" AND ", where);
        var selectColumns = LabClaimLineColumnCatalog.ToAliasedSqlSelectList(
            LabClaimLineColumnCatalog.GetClaimColumns("NorthWest"), "c");

        return new NwExportSqlParts(
            selectColumns,
            "dbo.ClaimLevelData c",
            whereStr,
            parms,
            "c.ChargeEnteredDate",
            "TRY_CAST(c.ChargeEnteredDate AS DATE), c.PanelType, c.ClaimID");
    }

    // Builds the LineLevelData export SELECT with NW filter semantics.
    // Joins ClaimLevelData to apply the same ClaimStatus / PanelType exclusions.
    private static (string Sql, List<SqlParameter> Parameters) BuildNwLineLevelExportQuery(
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        DateOnly? filterDosFrom,
        DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom,
        DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom,
        DateOnly? filterFirstBilledTo)
    {
        var parts = BuildNwLineLevelExportParts(
            filterPayerNames, filterPanelNames,
            filterDosFrom, filterDosTo,
            filterFirstBillFrom, filterFirstBillTo,
            filterFirstBilledFrom, filterFirstBilledTo);

        var sql = $"""
            SELECT {parts.SelectColumns}
            FROM   {parts.FromClause}
            {parts.WhereClause}
            ORDER BY {parts.OrderBy}
            """;

        return (sql, parts.Parameters);
    }

    private static NwExportSqlParts BuildNwLineLevelExportParts(
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        DateOnly? filterDosFrom,
        DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom,
        DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom,
        DateOnly? filterFirstBilledTo)
    {
        var where  = new List<string>
        {
            "LTRIM(RTRIM(c.ClaimStatus)) NOT IN " +
            "('Unbilled in Daq','Unbilled in Daq - PR','Unbilled in Webpm','Unbilled in Webpm - PR','Billed amount 0')"
        };
        var parms  = new List<SqlParameter>();

        AddNwInClause(where, parms, "LTRIM(RTRIM(c.PayerName_Raw))", "@lxpn", filterPayerNames);
        AddNwInClause(where, parms, "LTRIM(RTRIM(c.PanelType))",     "@lxpl", filterPanelNames);
        AddNwDateFiltersAliased(where, parms, "lx", "c",
            filterDosFrom, filterDosTo,
            filterFirstBillFrom, filterFirstBillTo,
            filterFirstBilledFrom, filterFirstBilledTo);

        var whereStr = "WHERE " + string.Join(" AND ", where);
        var selectColumns = LabClaimLineColumnCatalog.ToAliasedSqlSelectList(
            LabClaimLineColumnCatalog.GetLineColumns("NorthWest"), "l");

        return new NwExportSqlParts(
            selectColumns,
            "dbo.LineLevelData l JOIN dbo.ClaimLevelData c ON l.ClaimID = c.ClaimID",
            whereStr,
            parms,
            "l.ChargeEnteredDate",
            "TRY_CAST(l.ChargeEnteredDate AS DATE), c.PanelType, l.ClaimID, l.CPTCode");
    }

    private async Task<List<SharedRawDataSegment>> GetNwRawDataExportSegmentsAsync(
        string connectionString,
        string baseSheetName,
        NwExportSqlParts parts,
        CancellationToken ct)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        _logger.LogInformation(
            "[ProdExcelExportSplit] NW SQL split START Sheet={Sheet} Threshold={Threshold:N0}",
            baseSheetName, ExportSplitThreshold);

        var totalRows = await ExecuteNwCountAsync(connectionString, parts, null, null, null, ct);
        _logger.LogInformation(
            "[ProdExcelExportSplit] NW SQL split total Sheet={Sheet} Rows={Rows:N0}",
            baseSheetName, totalRows);

        if (totalRows == 0)
        {
            _logger.LogInformation(
                "[ProdExcelExportSplit] NW SQL split DONE Sheet={Sheet} Segments=1 Empty=true ElapsedMs={Ms}",
                baseSheetName, sw.ElapsedMilliseconds);
        return [new SharedRawDataSegment(baseSheetName, [], [])];
        }

        if (totalRows <= ExportSplitThreshold)
        {
            var (cols, rows) = await ExecuteNwSegmentQueryAsync(connectionString, parts, null, null, null, null, null, ct);
            _logger.LogInformation(
                "[ProdExcelExportSplit] NW SQL split DONE Sheet={Sheet} Segments=1 Rows={Rows:N0} ElapsedMs={Ms}",
                baseSheetName, rows.Count, sw.ElapsedMilliseconds);
        return [new SharedRawDataSegment(baseSheetName, cols, rows)];
        }

        _logger.LogInformation(
            "[ProdExcelExportSplit] NW SQL period count START Sheet={Sheet} ? grouping by year/month in one pass",
            baseSheetName);

        var segments = new List<SharedRawDataSegment>();
        var usedSheetNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var periodCounts = await ExecuteNwPeriodCountsAsync(connectionString, parts, ct);

        _logger.LogInformation(
            "[ProdExcelExportSplit] NW SQL period count DONE Sheet={Sheet} Periods={Periods} Details=[{Details}]",
            baseSheetName,
            periodCounts.Count,
            string.Join(", ", periodCounts.Select(p => p.Year > 0 ? $"{p.Year:D4}-{p.Month:D2}({p.Rows:N0})" : $"Unknown({p.Rows:N0})")));

        foreach (var (year, month, rowCount) in periodCounts)
        {
            var yearLabel = year > 0 ? year.ToString() : "Unknown";
            var splitFilter = year > 0
                ? BuildNwMonthFilter(parts.SplitDateExpression)
                : BuildNwUnknownDateFilter(parts.SplitDateExpression);

            _logger.LogInformation(
                "[ProdExcelExportSplit] NW SQL period split Sheet={Sheet} Year={Year} Month={Month} Rows={Rows:N0}",
                baseSheetName, yearLabel, year > 0 ? month.ToString("D2") : "Unknown", rowCount);

            await AddNwPagedSegmentsAsync(
                connectionString,
                baseSheetName,
                parts,
                splitFilter,
                year > 0 ? year : null,
                year > 0 ? month : null,
                yearLabel,
                year > 0 ? month : null,
                rowCount,
                segments,
                usedSheetNames,
                ct);
        }

        _logger.LogInformation(
            "[ProdExcelExportSplit] NW SQL split DONE Sheet={Sheet} Segments={Segments} Rows={Rows:N0} ElapsedMs={Ms} Details=[{Details}]",
            baseSheetName,
            segments.Count,
            segments.Sum(s => s.Rows.Count),
            sw.ElapsedMilliseconds,
            string.Join(", ", segments.Select(s => $"'{s.SheetName}'({s.Rows.Count:N0})")));

        return segments;
    }

    private async Task AddNwPagedSegmentsAsync(
        string connectionString,
        string baseSheetName,
        NwExportSqlParts parts,
        string splitFilter,
        int? splitYear,
        int? splitMonth,
        string yearLabel,
        int? month,
        long rowCount,
        List<SharedRawDataSegment> segments,
        HashSet<string> usedSheetNames,
        CancellationToken ct)
    {
        var pageCount = Math.Max(1, (int)Math.Ceiling(rowCount / (double)ExportSplitThreshold));
        for (var page = 0; page < pageCount; page++)
        {
            var offset = page * ExportSplitThreshold;
            var partSuffix = pageCount > 1 ? $"_Part{page + 1}" : string.Empty;
            var requestedSheetName = month.HasValue
                ? $"{yearLabel}_{month.Value:D2}_{baseSheetName}{partSuffix}"
                : $"{yearLabel}_{baseSheetName}{partSuffix}";
            var sheetName = CreateNwUniqueSheetName(requestedSheetName, usedSheetNames);

            _logger.LogInformation(
                "[ProdExcelExportSplit] NW SQL segment query START Sheet={SheetName} Offset={Offset:N0} Take={Take:N0}",
                sheetName, offset, ExportSplitThreshold);

            var (cols, rows) = await ExecuteNwSegmentQueryAsync(
                connectionString, parts, splitFilter, splitYear, splitMonth, offset, ExportSplitThreshold, ct);

            _logger.LogInformation(
                "[ProdExcelExportSplit] NW SQL segment query DONE Sheet={SheetName} Rows={Rows:N0}",
                sheetName, rows.Count);

        segments.Add(new SharedRawDataSegment(sheetName, cols, rows));
        }
    }

    private async Task<long> ExecuteNwCountAsync(
        string connectionString,
        NwExportSqlParts parts,
        string? splitFilter,
        int? splitYear,
        int? splitMonth,
        CancellationToken ct)
    {
        var sql = $"SELECT COUNT_BIG(*) FROM {parts.FromClause} {AppendNwWhere(parts.WhereClause, splitFilter)}";
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 300 };
        AddClonedNwParameters(cmd, parts.Parameters);
        AddNwSplitParameters(cmd, splitFilter, splitYear, splitMonth, null, null);
        return Convert.ToInt64(await cmd.ExecuteScalarAsync(ct), System.Globalization.CultureInfo.InvariantCulture);
    }

    private async Task<List<(int Year, int Month, long Rows)>> ExecuteNwPeriodCountsAsync(
        string connectionString,
        NwExportSqlParts parts,
        CancellationToken ct)
    {
        var dateExpr = parts.SplitDateExpression;
        var sql = $"""
            SELECT
                CASE
                    WHEN TRY_CAST({dateExpr} AS DATE) IS NULL OR YEAR(TRY_CAST({dateExpr} AS DATE)) <= 1900 THEN 0
                    ELSE YEAR(TRY_CAST({dateExpr} AS DATE))
                END AS SplitYear,
                CASE
                    WHEN TRY_CAST({dateExpr} AS DATE) IS NULL OR YEAR(TRY_CAST({dateExpr} AS DATE)) <= 1900 THEN 0
                    ELSE MONTH(TRY_CAST({dateExpr} AS DATE))
                END AS SplitMonth,
                COUNT_BIG(*) AS TotalRows
            FROM {parts.FromClause}
            {parts.WhereClause}
            GROUP BY
                CASE
                    WHEN TRY_CAST({dateExpr} AS DATE) IS NULL OR YEAR(TRY_CAST({dateExpr} AS DATE)) <= 1900 THEN 0
                    ELSE YEAR(TRY_CAST({dateExpr} AS DATE))
                END,
                CASE
                    WHEN TRY_CAST({dateExpr} AS DATE) IS NULL OR YEAR(TRY_CAST({dateExpr} AS DATE)) <= 1900 THEN 0
                    ELSE MONTH(TRY_CAST({dateExpr} AS DATE))
                END
            ORDER BY SplitYear, SplitMonth
            """;

        var rows = new List<(int Year, int Month, long Rows)>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 300 };
        AddClonedNwParameters(cmd, parts.Parameters);
        await using var rdr = await cmd.ExecuteReaderAsync(ct);
        while (await rdr.ReadAsync(ct))
            rows.Add((rdr.GetInt32(0), rdr.GetInt32(1), rdr.GetInt64(2)));
        return rows;
    }

    private async Task<(string[] Columns, List<object?[]> Rows)> ExecuteNwSegmentQueryAsync(
        string connectionString,
        NwExportSqlParts parts,
        string? splitFilter,
        int? splitYear,
        int? splitMonth,
        int? offset,
        int? take,
        CancellationToken ct)
    {
        var pagingSql = offset.HasValue && take.HasValue
            ? $"ORDER BY {parts.OrderBy} OFFSET @splitOffset ROWS FETCH NEXT @splitTake ROWS ONLY"
            : $"ORDER BY {parts.OrderBy}";
        var sql = $"""
            SELECT {parts.SelectColumns}
            FROM {parts.FromClause}
            {AppendNwWhere(parts.WhereClause, splitFilter)}
            {pagingSql}
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 300 };
        AddClonedNwParameters(cmd, parts.Parameters);
        AddNwSplitParameters(cmd, splitFilter, splitYear, splitMonth, offset, take);
        return await ExecuteNwReaderToArraysAsync(cmd, ct);
    }

    private static string BuildNwMonthFilter(string dateExpression) =>
        $"YEAR(TRY_CAST({dateExpression} AS DATE)) = @splitYear AND MONTH(TRY_CAST({dateExpression} AS DATE)) = @splitMonth";

    private static string BuildNwUnknownDateFilter(string dateExpression) =>
        $"(TRY_CAST({dateExpression} AS DATE) IS NULL OR YEAR(TRY_CAST({dateExpression} AS DATE)) <= 1900)";

    private static string AppendNwWhere(string whereClause, string? extraFilter) =>
        string.IsNullOrWhiteSpace(extraFilter) ? whereClause : whereClause + " AND " + extraFilter;

    private static void AddClonedNwParameters(SqlCommand cmd, List<SqlParameter> parameters)
    {
        foreach (var p in parameters)
            cmd.Parameters.Add(new SqlParameter(p.ParameterName, p.SqlDbType) { Value = p.Value });
    }

    private static void AddNwSplitParameters(SqlCommand cmd, string? splitFilter, int? splitYear, int? splitMonth, int? offset, int? take)
    {
        if (!string.IsNullOrWhiteSpace(splitFilter) && splitFilter.Contains("@splitYear", StringComparison.Ordinal) && splitYear.HasValue)
            cmd.Parameters.Add(new SqlParameter("@splitYear", SqlDbType.Int) { Value = splitYear.Value });
        if (!string.IsNullOrWhiteSpace(splitFilter) && splitFilter.Contains("@splitMonth", StringComparison.Ordinal) && splitMonth.HasValue)
            cmd.Parameters.Add(new SqlParameter("@splitMonth", SqlDbType.Int) { Value = splitMonth.Value });
        if (offset.HasValue)
            cmd.Parameters.Add(new SqlParameter("@splitOffset", SqlDbType.Int) { Value = offset.Value });
        if (take.HasValue)
            cmd.Parameters.Add(new SqlParameter("@splitTake", SqlDbType.Int) { Value = take.Value });
    }

    private static string CreateNwUniqueSheetName(string requestedName, HashSet<string> usedSheetNames)
    {
        var baseName = requestedName.Trim();
        foreach (var invalid in new[] { ':', '\\', '/', '?', '*', '[', ']' })
            baseName = baseName.Replace(invalid, '_');

        if (string.IsNullOrWhiteSpace(baseName))
            baseName = "Sheet";

        var candidate = baseName.Length <= 31 ? baseName : baseName[..31];
        var suffix = 1;
        while (!usedSheetNames.Add(candidate))
        {
            var tail = $"_{suffix++}";
            var maxLength = 31 - tail.Length;
            candidate = (baseName.Length <= maxLength ? baseName : baseName[..maxLength]) + tail;
        }

        return candidate;
    }

    private sealed record NwExportSqlParts(
        string SelectColumns,
        string FromClause,
        string WhereClause,
        List<SqlParameter> Parameters,
        string SplitDateExpression,
        string OrderBy);

    // Executes an export SELECT and materialises results as row dictionaries.
    private async Task<List<Dictionary<string, object?>>> ExecuteNwExportQueryAsync(
        string connectionString, string sql,
        List<SqlParameter> parameters, string context, CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd  = new SqlCommand(sql, conn) { CommandTimeout = 300 };
        AddClonedNwParameters(cmd, parameters);
        var rows = await ExecuteNwReaderToDictionaryListAsync(cmd, ct);
        _logger.LogInformation("NW {Context} export: {Rows:N0} rows.", context, rows.Count);
        return rows;
    }

    private static async Task<List<Dictionary<string, object?>>> ExecuteNwReaderToDictionaryListAsync(SqlCommand cmd, CancellationToken ct)
    {
        var rows = new List<Dictionary<string, object?>>();
        await using var rdr  = await cmd.ExecuteReaderAsync(ct);
        var cols = Enumerable.Range(0, rdr.FieldCount).Select(i => rdr.GetName(i)).ToArray();
        while (await rdr.ReadAsync(ct))
        {
            var row = new Dictionary<string, object?>(cols.Length);
            for (int i = 0; i < cols.Length; i++)
                row[cols[i]] = rdr.IsDBNull(i) ? null : rdr.GetValue(i);
            rows.Add(row);
        }
        return rows;
    }

    private static async Task<(string[] Columns, List<object?[]> Rows)> ExecuteNwReaderToArraysAsync(SqlCommand cmd, CancellationToken ct)
    {
        await using var rdr = await cmd.ExecuteReaderAsync(ct);
        var cols = Enumerable.Range(0, rdr.FieldCount).Select(i => rdr.GetName(i)).ToArray();
        var rows = new List<object?[]>();
        while (await rdr.ReadAsync(ct))
        {
            var row = new object?[cols.Length];
            for (int i = 0; i < cols.Length; i++)
                row[i] = rdr.IsDBNull(i) ? null : rdr.GetValue(i);
            rows.Add(row);
        }
        return (cols, rows);
    }

    private static void AddNwInClause(
        List<string> where, List<SqlParameter> parms,
        string colExpr, string prefix, List<string>? values)
    {
        if (values is not { Count: > 0 }) return;
        var names = values.Select((_, i) => $"{prefix}_{i}").ToList();
        for (int i = 0; i < values.Count; i++)
            parms.Add(new SqlParameter(names[i], values[i]));
        where.Add($"{colExpr} IN ({string.Join(", ", names)})");
    }

    private static void AddNwDateFilters(
        List<string> where, List<SqlParameter> parms, string prefix,
        DateOnly? dosFrom, DateOnly? dosTo,
        DateOnly? fbFrom,  DateOnly? fbTo,
        DateOnly? fbldFrom, DateOnly? fbldTo)
    {
        AddNwDateRange(where, parms, "TRY_CAST(DateOfService AS DATE)",     $"@{prefix}dosf",  $"@{prefix}dost",  dosFrom,  dosTo);
        AddNwDateRange(where, parms, "TRY_CAST(ChargeEnteredDate AS DATE)", $"@{prefix}fbf",   $"@{prefix}fbt",   fbFrom,   fbTo);
        AddNwDateRange(where, parms, "TRY_CAST(FirstBilledDate AS DATE)",   $"@{prefix}fbldf", $"@{prefix}fbldt", fbldFrom, fbldTo);
    }

    private static void AddNwDateFiltersAliased(
        List<string> where, List<SqlParameter> parms, string prefix, string tableAlias,
        DateOnly? dosFrom, DateOnly? dosTo,
        DateOnly? fbFrom,  DateOnly? fbTo,
        DateOnly? fbldFrom, DateOnly? fbldTo)
    {
        AddNwDateRange(where, parms, $"TRY_CAST({tableAlias}.DateOfService AS DATE)",     $"@{prefix}dosf",  $"@{prefix}dost",  dosFrom,  dosTo);
        AddNwDateRange(where, parms, $"TRY_CAST({tableAlias}.ChargeEnteredDate AS DATE)", $"@{prefix}fbf",   $"@{prefix}fbt",   fbFrom,   fbTo);
        AddNwDateRange(where, parms, $"TRY_CAST({tableAlias}.FirstBilledDate AS DATE)",   $"@{prefix}fbldf", $"@{prefix}fbldt", fbldFrom, fbldTo);
    }

    private static void AddNwDateRange(
        List<string> where, List<SqlParameter> parms,
        string colExpr, string fromParam, string toParam,
        DateOnly? from, DateOnly? to)
    {
        if (from.HasValue)
        {
            where.Add($"{colExpr} >= {fromParam}");
            parms.Add(new SqlParameter(fromParam, System.Data.SqlDbType.Date) { Value = from.Value.ToDateTime(TimeOnly.MinValue) });
        }
        if (to.HasValue)
        {
            where.Add($"{colExpr} <= {toParam}");
            parms.Add(new SqlParameter(toParam, System.Data.SqlDbType.Date) { Value = to.Value.ToDateTime(TimeOnly.MinValue) });
        }
    }

    // ?? Shared parameter helper ???????????????????????????????????????????????
    // Adds the 8 standard filter parameters expected by every dbo.usp_GetNW_* read SP.
    // Passing all as NULL triggers the SP's no-filter snapshot branch.
    private static decimal ReadDecimalByNameOrIndex(System.Data.Common.DbDataReader rdr, int fallbackIndex, params string[] names)
    {
        for (var i = 0; i < rdr.FieldCount; i++)
        {
            var col = rdr.GetName(i);
            foreach (var name in names)
            {
                if (string.Equals(col, name, StringComparison.OrdinalIgnoreCase))
                    return rdr.IsDBNull(i) ? 0m : Convert.ToDecimal(rdr.GetValue(i), System.Globalization.CultureInfo.InvariantCulture);
            }
        }

        if (fallbackIndex >= 0 && fallbackIndex < rdr.FieldCount && !rdr.IsDBNull(fallbackIndex))
            return Convert.ToDecimal(rdr.GetValue(fallbackIndex), System.Globalization.CultureInfo.InvariantCulture);

        return 0m;
    }

    private static void AddNWFilterParameters(
        SqlCommand cmd,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null)
    {
        cmd.Parameters.Add(new SqlParameter("@PayerNames", SqlDbType.NVarChar, -1) { Value = JoinList(filterPayerNames) });
        cmd.Parameters.Add(new SqlParameter("@PanelNames", SqlDbType.NVarChar, -1) { Value = JoinList(filterPanelNames) });
        cmd.Parameters.Add(DateParam("@DosFrom",         filterDosFrom));
        cmd.Parameters.Add(DateParam("@DosTo",           filterDosTo));
        cmd.Parameters.Add(DateParam("@FirstBillFrom",   filterFirstBillFrom));
        cmd.Parameters.Add(DateParam("@FirstBillTo",     filterFirstBillTo));
        cmd.Parameters.Add(DateParam("@FirstBilledFrom", filterFirstBilledFrom));
        cmd.Parameters.Add(DateParam("@FirstBilledTo",   filterFirstBilledTo));

        static object JoinList(List<string>? values)
        {
            if (values is null || values.Count == 0) return DBNull.Value;
            var cleaned = values.Where(v => !string.IsNullOrWhiteSpace(v)).Select(v => v.Trim()).ToList();
            return cleaned.Count == 0 ? DBNull.Value : (object)string.Join('|', cleaned);
        }

        static SqlParameter DateParam(string name, DateOnly? value) =>
            new(name, SqlDbType.Date)
            {
                Value = value.HasValue ? value.Value.ToDateTime(TimeOnly.MinValue) : DBNull.Value,
            };
    }
}
