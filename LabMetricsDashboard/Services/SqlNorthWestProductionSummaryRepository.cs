using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads NorthWest production report aggregates from the SP-populated output tables.
/// Used by the "Production Summary Report" page when no filters are active.
/// Falls back to <see cref="IProductionReportRepository"/> when filters are applied.
/// </summary>
public sealed class SqlNorthWestProductionSummaryRepository : INorthWestProductionSummaryRepository
{
    private readonly ILogger<SqlNorthWestProductionSummaryRepository> _logger;

    public SqlNorthWestProductionSummaryRepository(ILogger<SqlNorthWestProductionSummaryRepository> logger)
        => _logger = logger;

    // ?? Filter Options ??????????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<(List<string> PayerNames, List<string> PanelNames)> GetFilterOptionsAsync(
        string connectionString, CancellationToken ct = default)
    {
        // Query distinct values from the live table using the same ClaimStatus exclusion
        // filter as the SPs so the dropdowns exactly match what the aggregate tables show.
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

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand(sql, conn) { CommandTimeout = 60 };
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

            var payers = new List<string>();
            while (await rdr.ReadAsync(ct)) payers.Add(rdr.GetString(0));
            await rdr.NextResultAsync(ct);
            var panels = new List<string>();
            while (await rdr.ReadAsync(ct)) panels.Add(rdr.GetString(0));

            return (payers, panels);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetFilterOptionsAsync failed.");
            return ([], []);
        }
    }

    // ?? Monthly Claim Volume ????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<ProductionReportResult> GetMonthlyAsync(string connectionString, CancellationToken ct = default)
    {
        const string sql = """
            SELECT PanelType AS PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
            FROM   dbo.NW_MonthlyBilledProductionSummary
            ORDER  BY PanelName, BilledYearMonth, PayerRank
            """;

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand(sql, conn) { CommandTimeout = 120 };
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

            // panel ? month ? (count, charges)
            var panelMonth   = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            // panel ? payer ? month ? (count, charges)
            var payerMonthMap = new Dictionary<string, Dictionary<string, Dictionary<string, (int c, decimal ch)>>>(StringComparer.OrdinalIgnoreCase);
            var payerRankMap  = new Dictionary<string, Dictionary<string, int>>(StringComparer.OrdinalIgnoreCase);
            var allMonths     = new SortedSet<string>();

            while (await rdr.ReadAsync(ct))
            {
                var panel   = rdr.GetString(0);
                var payer   = rdr.GetString(1);
                var rank    = (int)rdr.GetByte(2);   // TINYINT maps to byte, not short
                var month   = rdr.GetString(3);
                var count   = rdr.GetInt32(4);
                var charges = rdr.GetDecimal(5);

                allMonths.Add(month);

                // panel totals
                if (!panelMonth.TryGetValue(panel, out var pm)) panelMonth[panel] = pm = new();
                if (!pm.TryGetValue(month, out var pt)) pm[month] = (count, charges);
                else pm[month] = (pt.c + count, pt.ch + charges);

                // payer drill-down
                if (!payerMonthMap.TryGetValue(panel, out var payM)) payerMonthMap[panel] = payM = new(StringComparer.OrdinalIgnoreCase);
                if (!payM.TryGetValue(payer, out var mDict)) payM[payer] = mDict = new();
                if (!mDict.TryGetValue(month, out var md)) mDict[month] = (count, charges);
                else mDict[month] = (md.c + count, md.ch + charges);

                if (!payerRankMap.TryGetValue(panel, out var rankD)) payerRankMap[panel] = rankD = new(StringComparer.OrdinalIgnoreCase);
                rankD[payer] = rank;
            }

            var months    = allMonths.ToList();
            var years     = months.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
            var panelRows = new List<ProductionPanelRow>();

            // grand totals
            var grandByMonth = new Dictionary<string, ProductionMonthCell>();

            foreach (var (panel, pm) in panelMonth.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
            {
                var byMonth = pm.ToDictionary(
                    kv => kv.Key,
                    kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));

                var byYear = BuildYearTotals(pm, years);

                // accumulate grand totals
                foreach (var (mk, cell) in byMonth)
                {
                    if (!grandByMonth.TryGetValue(mk, out var g)) grandByMonth[mk] = cell;
                    else grandByMonth[mk] = new ProductionMonthCell(g.ClaimCount + cell.ClaimCount, g.BilledCharges + cell.BilledCharges);
                }

                // top payers
                var topPayers = new List<ProductionPayerDrillDown>();
                if (payerMonthMap.TryGetValue(panel, out var payM) && payerRankMap.TryGetValue(panel, out var rankD))
                {
                    foreach (var (payer, mDict) in payM.OrderBy(p => rankD.GetValueOrDefault(p.Key, 99)))
                    {
                        topPayers.Add(new ProductionPayerDrillDown
                        {
                            PayerName    = payer,
                            ByMonth      = mDict.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch)),
                            ByYear       = BuildYearTotals(mDict, years),
                            TotalClaims  = mDict.Values.Sum(v => v.c),
                            TotalCharges = mDict.Values.Sum(v => v.ch),
                        });
                    }
                }

                panelRows.Add(new ProductionPanelRow
                {
                    PanelName    = panel,
                    ByMonth      = byMonth,
                    ByYear       = byYear,
                    TotalClaims  = byMonth.Values.Sum(c => c.ClaimCount),
                    TotalCharges = byMonth.Values.Sum(c => c.BilledCharges),
                    TopPayers    = topPayers,
                });
            }

            return new ProductionReportResult(
                [],
                panelRows.Select(p => p.PanelName).ToList(),
                months,
                years,
                panelRows,
                grandByMonth,
                grandByMonth.Values.Sum(c => c.ClaimCount),
                grandByMonth.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetMonthlyAsync failed.");
            return new ProductionReportResult([], [], [], [], [], new Dictionary<string, ProductionMonthCell>(), 0, 0m);
        }
    }

    // ?? Weekly Claim Volume ?????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<WeeklyClaimVolumeResult> GetWeeklyAsync(string connectionString, CancellationToken ct = default)
    {
        const string sql = """
            SELECT PanelType AS PanelName, PayerName, PayerRank,
                   WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
            FROM   dbo.NW_WeeklyBilledProductionSummary
            ORDER  BY WeekStart DESC, PanelName, PayerRank
            """;

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand(sql, conn) { CommandTimeout = 120 };
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

            var weekCols     = new Dictionary<string, WeekColumn>();
            var panelWeek    = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var payerWeekMap = new Dictionary<string, Dictionary<string, Dictionary<string, (int c, decimal ch)>>>(StringComparer.OrdinalIgnoreCase);
            var payerRankMap = new Dictionary<string, Dictionary<string, int>>(StringComparer.OrdinalIgnoreCase);

            while (await rdr.ReadAsync(ct))
            {
                var panel     = rdr.GetString(0);
                var payer     = rdr.GetString(1);
                var rank      = (int)rdr.GetByte(2);   // TINYINT maps to byte, not short
                var weekStart = DateOnly.FromDateTime(rdr.GetDateTime(3));
                var weekEnd   = DateOnly.FromDateTime(rdr.GetDateTime(4));
                var label     = rdr.GetString(5);
                var count     = rdr.GetInt32(6);
                var charges   = rdr.GetDecimal(7);
                var weekKey   = weekStart.ToString("yyyy-MM-dd");

                if (!weekCols.ContainsKey(weekKey))
                    weekCols[weekKey] = new WeekColumn(weekKey, weekStart, weekEnd);

                if (!panelWeek.TryGetValue(panel, out var pw)) panelWeek[panel] = pw = new();
                if (!pw.TryGetValue(weekKey, out var pt)) pw[weekKey] = (count, charges);
                else pw[weekKey] = (pt.c + count, pt.ch + charges);

                if (!payerWeekMap.TryGetValue(panel, out var payW)) payerWeekMap[panel] = payW = new(StringComparer.OrdinalIgnoreCase);
                if (!payW.TryGetValue(payer, out var wDict)) payW[payer] = wDict = new();
                if (!wDict.TryGetValue(weekKey, out var wd)) wDict[weekKey] = (count, charges);
                else wDict[weekKey] = (wd.c + count, wd.ch + charges);

                if (!payerRankMap.TryGetValue(panel, out var rankD)) payerRankMap[panel] = rankD = new(StringComparer.OrdinalIgnoreCase);
                rankD[payer] = rank;
            }

            var columns      = weekCols.Values.OrderByDescending(w => w.WeekStart).ToList();
            var panelRows    = new List<WeeklyPanelRow>();
            var grandByWeek  = new Dictionary<string, ProductionMonthCell>();

            foreach (var (panel, pw) in panelWeek.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
            {
                var byWeek = pw.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));

                foreach (var (wk, cell) in byWeek)
                {
                    if (!grandByWeek.TryGetValue(wk, out var g)) grandByWeek[wk] = cell;
                    else grandByWeek[wk] = new ProductionMonthCell(g.ClaimCount + cell.ClaimCount, g.BilledCharges + cell.BilledCharges);
                }

                var topPayers = new List<WeeklyPayerDrillDown>();
                if (payerWeekMap.TryGetValue(panel, out var payW) && payerRankMap.TryGetValue(panel, out var rankD))
                {
                    foreach (var (payer, wDict) in payW.OrderBy(p => rankD.GetValueOrDefault(p.Key, 99)))
                    {
                        topPayers.Add(new WeeklyPayerDrillDown
                        {
                            PayerName    = payer,
                            ByWeek       = wDict.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch)),
                            TotalClaims  = wDict.Values.Sum(v => v.c),
                            TotalCharges = wDict.Values.Sum(v => v.ch),
                        });
                    }
                }

                panelRows.Add(new WeeklyPanelRow
                {
                    PanelName    = panel,
                    ByWeek       = byWeek,
                    TotalClaims  = byWeek.Values.Sum(c => c.ClaimCount),
                    TotalCharges = byWeek.Values.Sum(c => c.BilledCharges),
                    TopPayers    = topPayers,
                });
            }

            return new WeeklyClaimVolumeResult(
                columns,
                panelRows,
                grandByWeek,
                grandByWeek.Values.Sum(c => c.ClaimCount),
                grandByWeek.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetWeeklyAsync failed.");
            return new WeeklyClaimVolumeResult([], [], new Dictionary<string, ProductionMonthCell>(), 0, 0m);
        }
    }

    // ?? Coding ??????????????????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<CodingResult> GetCodingAsync(string connectionString, CancellationToken ct = default)
    {
        const string panelSql  = "SELECT PanelName, ClaimCount, TotalCharges FROM dbo.NW_CodingPanelSummary ORDER BY TotalCharges DESC";
        const string detailSql = "SELECT PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges FROM dbo.NW_CodingCPTDetail ORDER BY PanelName, TotalCharges DESC";

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            // Panel totals
            var panelMap = new Dictionary<string, (int c, decimal ch)>(StringComparer.OrdinalIgnoreCase);
            await using (var cmd = new SqlCommand(panelSql, conn) { CommandTimeout = 120 })
            await using (var rdr = await cmd.ExecuteReaderAsync(ct))
            {
                while (await rdr.ReadAsync(ct))
                    panelMap[rdr.GetString(0)] = (rdr.GetInt32(1), rdr.GetDecimal(2));
            }

            // CPT detail
            var cptMap = new Dictionary<string, List<CodingCptDrillDown>>(StringComparer.OrdinalIgnoreCase);
            await using (var cmd = new SqlCommand(detailSql, conn) { CommandTimeout = 120 })
            await using (var rdr = await cmd.ExecuteReaderAsync(ct))
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

            return new CodingResult(panelRows, panelRows.Sum(r => r.ClaimCount), panelRows.Sum(r => r.TotalCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetCodingAsync failed.");
            return new CodingResult([], 0, 0m);
        }
    }

    // ?? Payer Breakdown ?????????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<PayerBreakdownResult> GetPayerBreakdownAsync(string connectionString, CancellationToken ct = default)
    {
        const string sql = """
            SELECT PayerName, BilledYearMonth, ClaimCount
            FROM   dbo.NW_PayerBreakdown
            ORDER  BY PayerName, BilledYearMonth
            """;

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand(sql, conn) { CommandTimeout = 120 };
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

            var payerMonth = new Dictionary<string, Dictionary<string, int>>(StringComparer.OrdinalIgnoreCase);
            var allMonths  = new SortedSet<string>();

            while (await rdr.ReadAsync(ct))
            {
                var payer = rdr.GetString(0);
                var month = rdr.GetString(1);
                var count = rdr.GetInt32(2);

                allMonths.Add(month);
                if (!payerMonth.TryGetValue(payer, out var mm)) payerMonth[payer] = mm = new();
                mm[month] = mm.GetValueOrDefault(month) + count;
            }

            var months     = allMonths.ToList();
            var years      = months.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
            var grandByMonth = new Dictionary<string, int>();
            var payerRows  = new List<PayerBreakdownRow>();

            foreach (var (payer, mm) in payerMonth.OrderByDescending(x => x.Value.Values.Sum()))
            {
                var byYear = years.ToDictionary(y => y, y => mm.Where(kv => kv.Key.StartsWith($"{y:D4}")).Sum(kv => kv.Value));

                foreach (var (mk, cnt) in mm)
                    grandByMonth[mk] = grandByMonth.GetValueOrDefault(mk) + cnt;

                payerRows.Add(new PayerBreakdownRow
                {
                    PayerName  = payer,
                    ByMonth    = mm,
                    ByYear     = byYear,
                    GrandTotal = mm.Values.Sum(),
                });
            }

            return new PayerBreakdownResult(
                months,
                years,
                payerRows,
                grandByMonth,
                grandByMonth.Values.Sum());
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetPayerBreakdownAsync failed.");
            return new PayerBreakdownResult([], [], [], new Dictionary<string, int>(), 0);
        }
    }

    // ?? Payer × Panel ???????????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<PayerPanelResult> GetPayerByPanelAsync(string connectionString, CancellationToken ct = default)
    {
        const string sql = """
            SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
            FROM   dbo.NW_PayerByPanel
            ORDER  BY PayerName, PanelName
            """;

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand(sql, conn) { CommandTimeout = 120 };
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

            var payerPanel  = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var allPanels   = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);

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

            var panelCols   = allPanels.ToList();
            var grandPanel  = new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase);
            var payerRows   = new List<PayerPanelRow>();

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

            return new PayerPanelResult(
                panelCols,
                payerRows,
                grandPanel,
                grandPanel.Values.Sum(c => c.ClaimCount),
                grandPanel.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetPayerByPanelAsync failed.");
            return new PayerPanelResult([], [], new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase), 0, 0m);
        }
    }

    // ?? Unbilled × Aging ????????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<UnbilledAgingResult> GetUnbilledAgingAsync(string connectionString, CancellationToken ct = default)
    {
        const string sql = """
            SELECT PayerName, Aging, ClaimCount, TotalCharges
            FROM   dbo.NW_UnbilledAging
            ORDER  BY PayerName, Aging
            """;

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand(sql, conn) { CommandTimeout = 120 };
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

            // Row key = PayerName (mapped to PanelName slot in the shared model)
            var rowBucket   = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var allBuckets  = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);

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
                    PanelName         = payer,   // row key mapped to PanelName slot
                    ByBucket          = byBucket,
                    GrandTotalClaims  = byBucket.Values.Sum(c => c.ClaimCount),
                    GrandTotalCharges = byBucket.Values.Sum(c => c.BilledCharges),
                });
            }

            return new UnbilledAgingResult(
                panelRows,
                grandByBucket,
                grandByBucket.Values.Sum(c => c.ClaimCount),
                grandByBucket.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetUnbilledAgingAsync failed.");
            return new UnbilledAgingResult([], new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase), 0, 0m);
        }
    }

    // ?? CPT Breakdown ???????????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<CptBreakdownResult> GetCptBreakdownAsync(string connectionString, CancellationToken ct = default)
    {
        const string sql = """
            SELECT PayerName, BilledYearMonth, CPTCount, TotalCharges
            FROM   dbo.NW_CPTBreakdown
            ORDER  BY PayerName, BilledYearMonth
            """;

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand(sql, conn) { CommandTimeout = 120 };
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

            var cptMonth  = new Dictionary<string, Dictionary<string, (decimal units, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var allMonths = new SortedSet<string>();

            while (await rdr.ReadAsync(ct))
            {
                var payer   = rdr.GetString(0);
                var month   = rdr.GetString(1);
                var units   = (decimal)rdr.GetInt32(2);   // CPTCount ? units
                var charges = rdr.GetDecimal(3);

                allMonths.Add(month);
                if (!cptMonth.TryGetValue(payer, out var mm)) cptMonth[payer] = mm = new();
                var prev = mm.GetValueOrDefault(month);
                mm[month] = (prev.units + units, prev.ch + charges);
            }

            var months   = allMonths.ToList();
            var years    = months.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
            var grandByMonth = new Dictionary<string, CptBreakdownCell>();
            var cptRows  = new List<CptBreakdownRow>();

            foreach (var (payer, mm) in cptMonth.OrderByDescending(x => x.Value.Values.Sum(v => v.ch)))
            {
                var byMonth = mm.ToDictionary(kv => kv.Key, kv => new CptBreakdownCell(kv.Value.units, kv.Value.ch));
                var byYear  = years.ToDictionary(y => y, y =>
                {
                    var cells = mm.Where(kv => kv.Key.StartsWith($"{y:D4}")).Select(kv => kv.Value).ToList();
                    return new CptBreakdownCell(cells.Sum(c => c.units), cells.Sum(c => c.ch));
                });

                foreach (var (mk, cell) in byMonth)
                {
                    if (!grandByMonth.TryGetValue(mk, out var g)) grandByMonth[mk] = cell;
                    else grandByMonth[mk] = new CptBreakdownCell(g.Units + cell.Units, g.BilledCharges + cell.BilledCharges);
                }

                cptRows.Add(new CptBreakdownRow
                {
                    CptCode            = payer,   // row key = PayerName
                    ByMonth            = byMonth,
                    ByYear             = byYear,
                    GrandTotalUnits    = byMonth.Values.Sum(c => c.Units),
                    GrandTotalCharges  = byMonth.Values.Sum(c => c.BilledCharges),
                });
            }

            return new CptBreakdownResult(
                months,
                years,
                cptRows,
                grandByMonth,
                grandByMonth.Values.Sum(c => c.Units),
                grandByMonth.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "NW GetCptBreakdownAsync failed.");
            return new CptBreakdownResult([], [], [], new Dictionary<string, CptBreakdownCell>(), 0m, 0m);
        }
    }

    // ?? Helpers ?????????????????????????????????????????????????????????????????

    private static Dictionary<int, ProductionYearTotal> BuildYearTotals(
        Dictionary<string, (int c, decimal ch)> byMonth, IEnumerable<int> years) =>
        years.ToDictionary(y => y, y =>
        {
            var cells = byMonth.Where(kv => kv.Key.StartsWith($"{y:D4}")).Select(kv => kv.Value).ToList();
            return new ProductionYearTotal(cells.Sum(c => c.c), cells.Sum(c => c.ch));
        });
}
