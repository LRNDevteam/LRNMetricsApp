using LRN.ProductionReports.Models;
using LRN.ProductionReports.Models;
using SharedCodingResult = LRN.ProductionReports.Services.CodingResult;
using SharedCptBreakdownResult = LRN.ProductionReports.Services.CptBreakdownResult;
using SharedPayerBreakdownResult = LRN.ProductionReports.Services.PayerBreakdownResult;
using SharedPayerPanelResult = LRN.ProductionReports.Services.PayerPanelResult;
using SharedProductionReportResult = LRN.ProductionReports.Services.ProductionReportResult;
using SharedUnbilledAgingResult = LRN.ProductionReports.Services.UnbilledAgingResult;
using SharedWeeklyClaimVolumeResult = LRN.ProductionReports.Services.WeeklyClaimVolumeResult;
using System.Data;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads Augustus Labs production report aggregates from the SP-populated output tables.
/// Used by the "Production Summary Report" page when no filters are active.
/// Falls back to <see cref="IProductionReportRepository"/> when filters are applied.
/// </summary>
public sealed class SqlAugustusProductionSummaryRepository : IAugustusProductionSummaryRepository
{
    private readonly ILogger<SqlAugustusProductionSummaryRepository> _logger;

    public SqlAugustusProductionSummaryRepository(ILogger<SqlAugustusProductionSummaryRepository> logger)
        => _logger = logger;

    // ?? Filter Options ??????????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<(List<string> PayerNames, List<string> PanelNames)> GetFilterOptionsAsync(
        string connectionString, CancellationToken ct = default)
    {
        // Augustus filter: FirstBilledDate IS NOT NULL + ChargeEnteredDate IS NOT NULL.
        // Uses PanelNew (not PanelType). No ClaimStatus exclusion.
        const string sql = """
            SELECT DISTINCT LTRIM(RTRIM(PayerName_Raw))
            FROM   dbo.ClaimLevelData
            WHERE  TRY_CAST(FirstBilledDate   AS DATE) IS NOT NULL
              AND  TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
            ORDER BY 1;

            SELECT DISTINCT LTRIM(RTRIM(PanelNew))
            FROM   dbo.ClaimLevelData
            WHERE  NULLIF(LTRIM(RTRIM(PanelNew)), '') IS NOT NULL
              AND  TRY_CAST(FirstBilledDate   AS DATE) IS NOT NULL
              AND  TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
            ORDER BY 1;
            """;

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand(sql, conn) { CommandTimeout = 60 };
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

            var payers = new List<string>();
            while (await rdr.ReadAsync(ct))
                if (!rdr.IsDBNull(0)) payers.Add(rdr.GetString(0));
            await rdr.NextResultAsync(ct);
            var panels = new List<string>();
            while (await rdr.ReadAsync(ct)) panels.Add(rdr.GetString(0));

            return (payers, panels);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Aug GetFilterOptionsAsync failed.");
            return ([], []);
        }
    }

    // ?? Monthly Claim Volume ????????????????????????????????????????????????????
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
        // Always route through dbo.usp_GetAug_MonthlyBilledProductionSummary so the SP
        // owns the SQL surface. With all filter params NULL, the SP serves rows from the
        // pre-aggregated dbo.Aug_MonthlyBilledProductionSummary snapshot table.
        // Output schema:
        //   PayerRank = 0  -> panel-level total across ALL payers (panel row).
        //   PayerRank 1..N -> ranked payer drill-down sub-rows.
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand("dbo.usp_GetAug_MonthlyBilledProductionSummary", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddAugFilterParameters(cmd,
                filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

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
                    // Panel-level total row from the SP.
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

            // Fallback: if the snapshot pre-dates the PayerRank=0 panel-total rows,
            // derive panel totals by summing the rank>0 drill-down rows.
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

            var months   = allMonths.ToList();
            var years    = months.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
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

                var topPayers = payerMonthMap.TryGetValue(panel, out var payM) && payerRankMap.TryGetValue(panel, out var rankD)
                    ? payM
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
                months,
                years,
                panelRows,
                grandByMonth,
                grandByMonth.Values.Sum(c => c.ClaimCount),
                grandByMonth.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Aug GetMonthlyAsync failed.");
            return new SharedProductionReportResult([], [], [], [], [], new Dictionary<string, ProductionMonthCell>(), 0, 0m);
        }
    }

    // ?? Weekly Claim Volume ?????????????????????????????????????????????????????
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
        // Always route through dbo.usp_GetAug_WeeklyBilledProductionSummary; with all
        // filter params NULL the SP serves rows from dbo.Aug_WeeklyBilledProductionSummary.
        // PayerRank semantics match the monthly SP (0 = panel total, 1..N = drilldowns).
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand("dbo.usp_GetAug_WeeklyBilledProductionSummary", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddAugFilterParameters(cmd,
                filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

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

            // Fallback when the snapshot has no PayerRank=0 rows.
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

            // Sort weeks oldest -> newest (left -> right) so the most recent
            // week (closest to today / "end date") is rendered on the right,
            // matching the BeechTree/Cove/Elixir/PCR/Rising_Tides Weekly tables.
            var columns   = weekCols.Values.OrderBy(w => w.WeekStart).ToList();
            var panelRows = new List<WeeklyPanelRow>();
            var grandByWeek = new Dictionary<string, ProductionMonthCell>();

            foreach (var (panel, pw) in panelWeek.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
            {
                var byWeek = pw.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));

                foreach (var (wk, cell) in byWeek)
                {
                    if (!grandByWeek.TryGetValue(wk, out var g)) grandByWeek[wk] = cell;
                    else grandByWeek[wk] = new ProductionMonthCell(g.ClaimCount + cell.ClaimCount, g.BilledCharges + cell.BilledCharges);
                }

                var topPayers = payerWeekMap.TryGetValue(panel, out var payW) && payerRankMap.TryGetValue(panel, out var rankD)
                    ? payW
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
                columns,
                panelRows,
                grandByWeek,
                grandByWeek.Values.Sum(c => c.ClaimCount),
                grandByWeek.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Aug GetWeeklyAsync failed.");
            return new SharedWeeklyClaimVolumeResult([], [], new Dictionary<string, ProductionMonthCell>(), 0, 0m);
        }
    }

    // ?? Coding ??????????????????????????????????????????????????????????????????
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
        // Always route through dbo.usp_GetAug_CodingBreakdown which returns two result
        // sets (panel summary + CPT detail). With NULL filters it serves the snapshot.
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand("dbo.usp_GetAug_CodingBreakdown", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddAugFilterParameters(cmd,
                filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);

            var panelMap = new Dictionary<string, (int c, decimal ch)>(StringComparer.OrdinalIgnoreCase);
            var cptMap   = new Dictionary<string, List<CodingCptDrillDown>>(StringComparer.OrdinalIgnoreCase);

            await using var rdr = await cmd.ExecuteReaderAsync(ct);

            // Result set 1: panel summary (PanelName, ClaimCount, TotalCharges)
            while (await rdr.ReadAsync(ct))
                panelMap[rdr.GetString(0)] = (rdr.GetInt32(1), rdr.GetDecimal(2));

            // Result set 2: CPT detail (PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges)
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
            _logger.LogError(ex, "Aug GetCodingAsync failed.");
            return new SharedCodingResult([], 0, 0m);
        }
    }

    // ?? Payer Breakdown ?????????????????????????????????????????????????????????
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
        // Always route through dbo.usp_GetAug_PayerBreakdown.
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand("dbo.usp_GetAug_PayerBreakdown", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddAugFilterParameters(cmd,
                filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

            var payerMonth = new Dictionary<string, Dictionary<string, int>>(StringComparer.OrdinalIgnoreCase);
            var allMonths  = new SortedSet<string>();

            while (await rdr.ReadAsync(ct))
            {
                var payer = rdr.GetString(0);
                var month = rdr.GetString(1);
                var count = rdr.GetInt32(2);

                allMonths.Add(month);
                if (!payerMonth.TryGetValue(payer, out var mm)) payerMonth[payer] = mm = [];
                mm[month] = mm.GetValueOrDefault(month) + count;
            }

            var months    = allMonths.ToList();
            var years     = months.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
            var grandByMonth = new Dictionary<string, int>();
            var payerRows = new List<PayerBreakdownRow>();

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

        return new SharedPayerBreakdownResult(months, years, payerRows, grandByMonth, grandByMonth.Values.Sum());
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Aug GetPayerBreakdownAsync failed.");
        return new SharedPayerBreakdownResult([], [], [], new Dictionary<string, int>(), 0);
        }
    }

    // ?? Payer × Panel ???????????????????????????????????????????????????????????
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
        // Always route through dbo.usp_GetAug_PayerByPanel.
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand("dbo.usp_GetAug_PayerByPanel", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddAugFilterParameters(cmd,
                filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

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
                panelCols,
                payerRows,
                grandPanel,
                grandPanel.Values.Sum(c => c.ClaimCount),
                grandPanel.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Aug GetPayerByPanelAsync failed.");
        return new SharedPayerPanelResult([], [], new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase), 0, 0m);
        }
    }

    // ?? Unbilled × Aging ????????????????????????????????????????????????????????
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
        // Always route through dbo.usp_GetAug_UnbilledAging.
        // SP returns: PanelName, AgingBucket, ClaimCount, TotalCharges.
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand("dbo.usp_GetAug_UnbilledAging", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddAugFilterParameters(cmd,
                filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

            var rowBucket  = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var allBuckets = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);

            while (await rdr.ReadAsync(ct))
            {
                var panel   = rdr.GetString(0);
                var aging   = rdr.IsDBNull(1) ? "Unknown" : rdr.GetString(1);
                var count   = rdr.GetInt32(2);
                var charges = rdr.GetDecimal(3);

                allBuckets.Add(aging);
                if (!rowBucket.TryGetValue(panel, out var rb)) rowBucket[panel] = rb = new(StringComparer.OrdinalIgnoreCase);
                rb[aging] = (rb.GetValueOrDefault(aging).c + count, rb.GetValueOrDefault(aging).ch + charges);
            }

            var grandByBucket = new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase);
            var panelRows     = new List<UnbilledAgingRow>();

            foreach (var (panel, rb) in rowBucket.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
            {
                var byBucket = rb.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));
                foreach (var (bk, cell) in byBucket)
                {
                    if (!grandByBucket.TryGetValue(bk, out var g)) grandByBucket[bk] = cell;
                    else grandByBucket[bk] = new ProductionMonthCell(g.ClaimCount + cell.ClaimCount, g.BilledCharges + cell.BilledCharges);
                }

                panelRows.Add(new UnbilledAgingRow
                {
                    PanelName         = panel,
                    ByBucket          = byBucket,
                    GrandTotalClaims  = byBucket.Values.Sum(c => c.ClaimCount),
                    GrandTotalCharges = byBucket.Values.Sum(c => c.BilledCharges),
                });
            }

        return new SharedUnbilledAgingResult(
                panelRows,
                grandByBucket,
                grandByBucket.Values.Sum(c => c.ClaimCount),
                grandByBucket.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Aug GetUnbilledAgingAsync failed.");
        return new SharedUnbilledAgingResult([], new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase), 0, 0m);
        }
    }

    // ?? CPT Breakdown ???????????????????????????????????????????????????????????
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
        // The CPT tab in the controller always uses the live query path; this method
        // surfaces the pre-aggregated data for completeness, routed through
        // dbo.usp_GetAug_CPTBreakdown to keep a single SQL surface.
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand("dbo.usp_GetAug_CPTBreakdown", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddAugFilterParameters(cmd,
                filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

            var cptMonth  = new Dictionary<string, Dictionary<string, (decimal u, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var allMonths = new SortedSet<string>();

            while (await rdr.ReadAsync(ct))
            {
                var cpt     = rdr.GetString(0);
                var month   = rdr.GetString(1);
                var units   = rdr.GetDecimal(2);   // CPTCount stored in CPTCount column
                var charges = rdr.GetDecimal(4);

                allMonths.Add(month);
                if (!cptMonth.TryGetValue(cpt, out var mm)) cptMonth[cpt] = mm = [];
                mm[month] = (mm.GetValueOrDefault(month).u + units, mm.GetValueOrDefault(month).ch + charges);
            }

            var months = allMonths.ToList();
            var years  = months.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
            var grandByMonth = new Dictionary<string, CptBreakdownCell>();
            var cptRows      = new List<CptBreakdownRow>();

            foreach (var (cpt, mm) in cptMonth.OrderBy(x => x.Key))
            {
                var byMonth = mm.ToDictionary(kv => kv.Key, kv => new CptBreakdownCell(kv.Value.u, kv.Value.ch));
                foreach (var (mk, cell) in byMonth)
                {
                    if (!grandByMonth.TryGetValue(mk, out var g)) grandByMonth[mk] = cell;
                    else grandByMonth[mk] = new CptBreakdownCell(g.Units + cell.Units, g.BilledCharges + cell.BilledCharges);
                }

                cptRows.Add(new CptBreakdownRow
                {
                    CptCode           = cpt,
                    ByMonth           = byMonth,
                    GrandTotalUnits   = byMonth.Values.Sum(c => c.Units),
                    GrandTotalCharges = byMonth.Values.Sum(c => c.BilledCharges),
                });
            }

        return new SharedCptBreakdownResult(
                months,
                years,
                cptRows,
                grandByMonth,
                grandByMonth.Values.Sum(c => c.Units),
                grandByMonth.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Aug GetCptBreakdownAsync failed.");
        return new SharedCptBreakdownResult([], [], [], new Dictionary<string, CptBreakdownCell>(), 0m, 0m);
        }
    }

    // (Year-total helpers are inlined as LINQ at the call sites above.)

    // Adds the filter parameters expected by every dbo.usp_GetAug_* read SP.
    // When all values are null the SP takes its no-filter branch and returns snapshot rows.
    // When any value is supplied the SP aggregates live from dbo.ClaimLevelData.
    private static void AddAugFilterParameters(
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
