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
/// Generic implementation of <see cref="ILabProductionSummaryRepository"/> that reads
/// from the pre-aggregated SP output tables for any lab configured via
/// <see cref="LabSummaryTableConfig"/>.
/// Covers: Certus, Cove, Elixir, PCRLabsofAmerica, Beech_Tree, Rising_Tides.
/// </summary>
public sealed class SqlLabProductionSummaryRepository : ILabProductionSummaryRepository
{
    private readonly ILogger<SqlLabProductionSummaryRepository> _logger;
    private readonly LabSummaryTableConfig _cfg;

    public SqlLabProductionSummaryRepository(
        ILogger<SqlLabProductionSummaryRepository> logger,
        LabSummaryTableConfig cfg)
    {
        _logger = logger;
        _cfg    = cfg;
    }

    /// <inheritdoc/>
    public bool SupportsFilteredMonthlyWeeklySp => _cfg.SupportsFilteredMonthlyWeeklySp;

    /// <inheritdoc/>
    public bool IsCertus => string.Equals(_cfg.Prefix, "Cert_", StringComparison.OrdinalIgnoreCase);

    // ?? Filter Options ????????????????????????????????????????????????????
    /// <inheritdoc/>
    public async Task<(List<string> PayerNames, List<string> PanelNames)> GetFilterOptionsAsync(
        string connectionString, CancellationToken ct = default)
    {
        const string sql = """
            SELECT DISTINCT LTRIM(RTRIM(PayerName_Raw))
            FROM   dbo.ClaimLevelData
            WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
            ORDER BY 1;

            SELECT DISTINCT LTRIM(RTRIM(Panelname))
            FROM   dbo.ClaimLevelData
            WHERE  NULLIF(LTRIM(RTRIM(Panelname)), '') IS NOT NULL
              AND  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
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
            _logger.LogError(ex, "[{Prefix}] GetFilterOptionsAsync failed.", _cfg.Prefix);
            return ([], []);
        }
    }

    // ?? Monthly Claim Volume ??????????????????????????????????????????????
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
        // Single SP per lab (naming convention: usp_Get{Prefix}MonthlyBilledProductionSummary).
        // When no filter params are supplied the SP serves rows from the pre-aggregated
        // snapshot table; when any filter is supplied the SP aggregates live from
        // dbo.ClaimLevelData using the same filter semantics. Output schema is identical:
        //   PayerRank = 0  -> panel-level totals across ALL payers (panel row).
        //   PayerRank 1..N -> top payer drill-down sub-rows.
        var spName = $"dbo.usp_Get{_cfg.Prefix}MonthlyBilledProductionSummary";

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand(spName, conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddProductionFilterParameters(
                cmd,
                filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

            var panelMonth    = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var payerMonthMap = new Dictionary<string, Dictionary<string, Dictionary<string, (int c, decimal ch)>>>(StringComparer.OrdinalIgnoreCase);
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
                    // PayerRank 0 = panel-level total across ALL payers.
                    if (!panelMonth.TryGetValue(panel, out var pm)) panelMonth[panel] = pm = [];
                    pm[month] = (count, charges);
                }
                else
                {
                    // PayerRank 1-3 = top payer drill-down.
                    if (!payerMonthMap.TryGetValue(panel, out var payM)) payerMonthMap[panel] = payM = new(StringComparer.OrdinalIgnoreCase);
                    if (!payM.TryGetValue(payer, out var mDict)) payM[payer] = mDict = [];
                    mDict[month] = mDict.TryGetValue(month, out var m0) ? (m0.c + count, m0.ch + charges) : (count, charges);
                }
            }

            var months       = allMonths.ToList();
            var years        = months.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
            var grandByMonth = new Dictionary<string, ProductionMonthCell>();
            var panelRows    = new List<ProductionPanelRow>();


            // Fallback: if the SP table pre-dates the PayerRank=0 change (no all-payer
            // totals rows yet), derive panel totals by summing the PayerRank 1-3 rows.
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

            foreach (var (panel, pm) in panelMonth.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
            {
                var byMonth = pm.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));

                foreach (var (mk, cell) in byMonth)
                {
                    if (!grandByMonth.TryGetValue(mk, out var g)) grandByMonth[mk] = cell;
                    else grandByMonth[mk] = new ProductionMonthCell(g.ClaimCount + cell.ClaimCount, g.BilledCharges + cell.BilledCharges);
                }

                // Top 3 payers ranked by total claim count across all months.
                var topPayers = payerMonthMap.TryGetValue(panel, out var payM)
                    ? payM
                        .Select(kv => (Payer: kv.Key, ByMonth: kv.Value, Total: kv.Value.Values.Sum(v => v.c)))
                        .OrderByDescending(x => x.Total)
                        .Take(3)
                        .Select(x => new ProductionPayerDrillDown
                        {
                            PayerName    = x.Payer,
                            ByMonth      = x.ByMonth.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch)),
                            ByYear       = x.ByMonth.GroupBy(kv => int.Parse(kv.Key[..4])).ToDictionary(g => g.Key, g => new ProductionYearTotal(g.Sum(kv => kv.Value.c), g.Sum(kv => kv.Value.ch))),
                            TotalClaims  = x.ByMonth.Values.Sum(v => v.c),
                            TotalCharges = x.ByMonth.Values.Sum(v => v.ch),
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
            _logger.LogError(ex, "[{Prefix}] GetMonthlyAsync failed.", _cfg.Prefix);
        return new SharedProductionReportResult([], [], [], [], [], new Dictionary<string, ProductionMonthCell>(), 0, 0m);
        }
    }

    // ?? Weekly Claim Volume ???????????????????????????????????????????????
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
        // Single SP per lab (naming convention: usp_Get{Prefix}WeeklyBilledProductionSummary).
        // See GetMonthlyAsync for filter-parameter behaviour. Output schema is identical:
        //   PayerRank = 0  -> panel-level totals across ALL payers (panel row).
        //   PayerRank 1..N -> top payer drill-down sub-rows.
        var spName = $"dbo.usp_Get{_cfg.Prefix}WeeklyBilledProductionSummary";

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand(spName, conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddProductionFilterParameters(
                cmd,
                filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);
            await using var rdr  = await cmd.ExecuteReaderAsync(ct);

            var weekCols     = new Dictionary<string, WeekColumn>();
            var panelWeek    = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var payerWeekMap = new Dictionary<string, Dictionary<string, Dictionary<string, (int c, decimal ch)>>>(StringComparer.OrdinalIgnoreCase);

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
                    // PayerRank 0 = panel-level total across ALL payers.
                    if (!panelWeek.TryGetValue(panel, out var pw)) panelWeek[panel] = pw = [];
                    pw[weekKey] = (count, charges);
                }
                else
                {
                    // PayerRank 1-3 = top payer drill-down.
                    if (!payerWeekMap.TryGetValue(panel, out var payW)) payerWeekMap[panel] = payW = new(StringComparer.OrdinalIgnoreCase);
                    if (!payW.TryGetValue(payer, out var wDict)) payW[payer] = wDict = [];
                    wDict[weekKey] = wDict.TryGetValue(weekKey, out var w0) ? (w0.c + count, w0.ch + charges) : (count, charges);
                }
            }

            var columns     = weekCols.Values.OrderBy(w => w.WeekStart).ToList();
            var grandByWeek = new Dictionary<string, ProductionMonthCell>();
            var panelRows   = new List<WeeklyPanelRow>();

            // Fallback: if the SP table pre-dates the PayerRank=0 change (no all-payer
            // totals rows yet), derive panel totals by summing the PayerRank 1-3 rows.
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

            foreach (var (panel, pw) in panelWeek.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
            {
                var byWeek = pw.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));

                foreach (var (wk, cell) in byWeek)
                {
                    if (!grandByWeek.TryGetValue(wk, out var g)) grandByWeek[wk] = cell;
                    else grandByWeek[wk] = new ProductionMonthCell(g.ClaimCount + cell.ClaimCount, g.BilledCharges + cell.BilledCharges);
                }

                // Top 3 payers ranked by total claim count across all 4 weeks.
                var topPayers = payerWeekMap.TryGetValue(panel, out var payW)
                    ? payW
                        .Select(kv => (Payer: kv.Key, ByWeek: kv.Value, Total: kv.Value.Values.Sum(v => v.c)))
                        .OrderByDescending(x => x.Total)
                        .Take(3)
                        .Select(x => new WeeklyPayerDrillDown
                        {
                            PayerName    = x.Payer,
                            ByWeek       = x.ByWeek.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch)),
                            TotalClaims  = x.ByWeek.Values.Sum(v => v.c),
                            TotalCharges = x.ByWeek.Values.Sum(v => v.ch),
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
            _logger.LogError(ex, "[{Prefix}] GetWeeklyAsync failed.", _cfg.Prefix);
        return new SharedWeeklyClaimVolumeResult([], [], new Dictionary<string, ProductionMonthCell>(), 0, 0m);
        }
    }

    // ?? Coding ????????????????????????????????????????????????????????????
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
        // Certus has no coding tables — return empty so the tab shows the "no data" state.
        if (!_cfg.HasCodingTables)
        return new SharedCodingResult([], 0, 0m);

        // When the lab's read SPs are parameterised (SupportsFilteredMonthlyWeeklySp == true)
        // we call usp_Get{Prefix}CodingBreakdown which returns two result sets and serves
        // either the snapshot tables (no filters) or a live aggregate (any filter).
        // For labs that haven't been upgraded yet we fall back to the legacy two-SELECT
        // batch against the snapshot tables (filters are silently ignored).
        var spName = $"dbo.usp_Get{_cfg.Prefix}CodingBreakdown";

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            SqlCommand cmd;
            if (_cfg.SupportsFilteredMonthlyWeeklySp)
            {
                cmd = new SqlCommand(spName, conn)
                {
                    CommandType    = CommandType.StoredProcedure,
                    CommandTimeout = 180,
                };
                AddProductionFilterParameters(
                    cmd,
                    filterPayerNames, filterPanelNames,
                    filterDosFrom, filterDosTo,
                    filterFirstBillFrom, filterFirstBillTo,
                    filterFirstBilledFrom, filterFirstBilledTo);
            }
            else if (_cfg.HasCodingTables)
            {
                var legacySql =
                    $"SELECT PanelName, ClaimCount, TotalCharges FROM dbo.{_cfg.Prefix}CodingPanelSummary ORDER BY TotalCharges DESC; " +
                    $"SELECT PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges FROM dbo.{_cfg.Prefix}CodingCPTDetail ORDER BY PanelName, TotalCharges DESC";
                cmd = new SqlCommand(legacySql, conn) { CommandTimeout = 120 };
            }
            else
            {
                return new SharedCodingResult([], 0, 0m);
            }
            await using var _cmd = cmd;

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
            _logger.LogError(ex, "[{Prefix}] GetCodingAsync failed.", _cfg.Prefix);
        return new SharedCodingResult([], 0, 0m);
        }
    }

    // ?? Payer Breakdown ???????????????????????????????????????????????????
    /// <inheritdoc/>
    /// <summary>
    /// Panel Breakdown with payer drill-down (Production Summary).
    /// Calls <c>usp_Get{Prefix}PanelBreakdownWithPayers</c>, deployed by
    /// <c>Sql\40_AllLabs_PanelBreakdownWithPayers.sql</c>. Labs whose database has
    /// not had that script run yet return an empty result and the table simply stays
    /// hidden - same behaviour as before this method existed.
    /// </summary>
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
        var spName = $"dbo.usp_Get{_cfg.Prefix}PanelBreakdownWithPayers";

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            await using var cmd = new SqlCommand(spName, conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            AddProductionFilterParameters(
                cmd,
                filterPayerNames, filterPanelNames,
                filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo);

            await using var rdr = await cmd.ExecuteReaderAsync(ct);
            return await ReadPanelBreakdownWithPayersAsync(rdr, ct);
        }
        catch (SqlException ex) when (ex.Number is 2812 or 208)
        {
            _logger.LogWarning(
                "[{Prefix}] {Sp} not deployed - Panel Breakdown will be empty for this lab. "
                + "Run Sql/40_AllLabs_PanelBreakdownWithPayers.sql on its database.",
                _cfg.Prefix, spName);
            return new SharedPayerBreakdownResult([], [], [], new Dictionary<string, int>(), 0);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[{Prefix}] GetPanelBreakdownAsync failed.", _cfg.Prefix);
            return new SharedPayerBreakdownResult([], [], [], new Dictionary<string, int>(), 0);
        }
    }

    /// <summary>
    /// Reads (PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges) rows into
    /// panel parent rows with payer <see cref="PayerBreakdownRow.ChildRows"/>, matching the
    /// shape the NorthWest Panel Breakdown produces so the view renders both identically.
    /// </summary>
    private static async Task<SharedPayerBreakdownResult> ReadPanelBreakdownWithPayersAsync(
        SqlDataReader rdr, CancellationToken ct)
    {
        var panelPayerMonth = new Dictionary<string, Dictionary<string, Dictionary<string, (int c, decimal ch)>>>(
            StringComparer.OrdinalIgnoreCase);
        var allMonths = new SortedSet<string>();

        while (await rdr.ReadAsync(ct))
        {
            if (rdr.IsDBNull(0) || rdr.IsDBNull(1) || rdr.IsDBNull(2)) continue;

            var panel   = rdr.GetString(0);
            var payer   = rdr.GetString(1);
            var month   = rdr.GetString(2);
            var count   = rdr.IsDBNull(3) ? 0 : Convert.ToInt32(rdr.GetValue(3));
            var charges = rdr.IsDBNull(4) ? 0m : Convert.ToDecimal(rdr.GetValue(4));

            allMonths.Add(month);
            if (!panelPayerMonth.TryGetValue(panel, out var payers))
                panelPayerMonth[panel] = payers = new(StringComparer.OrdinalIgnoreCase);
            if (!payers.TryGetValue(payer, out var months))
                payers[payer] = months = new(StringComparer.OrdinalIgnoreCase);

            var prev = months.GetValueOrDefault(month);
            months[month] = (prev.c + count, prev.ch + charges);
        }

        var monthsList          = allMonths.ToList();
        var years               = monthsList.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
        var grandByMonth        = new Dictionary<string, int>();
        var grandChargesByMonth = new Dictionary<string, decimal>();
        var rows                = new List<PayerBreakdownRow>();

        foreach (var (panel, payers) in panelPayerMonth
                     .OrderByDescending(x => x.Value.Sum(p => p.Value.Values.Sum(v => v.c))))
        {
            var panelMonth = new Dictionary<string, (int c, decimal ch)>(StringComparer.OrdinalIgnoreCase);
            var childRows  = new List<PayerBreakdownRow>();

            foreach (var (payer, mm) in payers
                         .OrderByDescending(x => x.Value.Values.Sum(v => v.c))
                         .ThenBy(x => x.Key, StringComparer.OrdinalIgnoreCase))
            {
                foreach (var (mk, v) in mm)
                {
                    var prev = panelMonth.GetValueOrDefault(mk);
                    panelMonth[mk] = (prev.c + v.c, prev.ch + v.ch);
                }

                childRows.Add(new PayerBreakdownRow
                {
                    PayerName         = payer,
                    ByMonth           = mm.ToDictionary(kv => kv.Key, kv => kv.Value.c),
                    ByYear            = years.ToDictionary(y => y, y => mm.Where(kv => kv.Key.StartsWith($"{y:D4}")).Sum(kv => kv.Value.c)),
                    GrandTotal        = mm.Values.Sum(v => v.c),
                    ByMonthCharges    = mm.ToDictionary(kv => kv.Key, kv => kv.Value.ch),
                    ByYearCharges     = years.ToDictionary(y => y, y => mm.Where(kv => kv.Key.StartsWith($"{y:D4}")).Sum(kv => kv.Value.ch)),
                    GrandTotalCharges = mm.Values.Sum(v => v.ch),
                });
            }

            foreach (var (mk, v) in panelMonth)
            {
                grandByMonth[mk]        = grandByMonth.GetValueOrDefault(mk) + v.c;
                grandChargesByMonth[mk] = grandChargesByMonth.GetValueOrDefault(mk) + v.ch;
            }

            rows.Add(new PayerBreakdownRow
            {
                PayerName         = panel,
                ByMonth           = panelMonth.ToDictionary(kv => kv.Key, kv => kv.Value.c),
                ByYear            = years.ToDictionary(y => y, y => panelMonth.Where(kv => kv.Key.StartsWith($"{y:D4}")).Sum(kv => kv.Value.c)),
                GrandTotal        = panelMonth.Values.Sum(v => v.c),
                ByMonthCharges    = panelMonth.ToDictionary(kv => kv.Key, kv => kv.Value.ch),
                ByYearCharges     = years.ToDictionary(y => y, y => panelMonth.Where(kv => kv.Key.StartsWith($"{y:D4}")).Sum(kv => kv.Value.ch)),
                GrandTotalCharges = panelMonth.Values.Sum(v => v.ch),
                ChildRows         = childRows,
            });
        }

        return new SharedPayerBreakdownResult(
            monthsList, years, rows, grandByMonth, grandByMonth.Values.Sum(),
            grandChargesByMonth, grandChargesByMonth.Values.Sum());
    }

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
        // When the lab's read SP is parameterised, call it. Otherwise fall back to the
        // legacy direct SELECT against the snapshot table (filters silently ignored).
        var spName = $"dbo.usp_Get{_cfg.Prefix}PayerBreakdown";

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            SqlCommand cmd;
            if (_cfg.SupportsFilteredMonthlyWeeklySp)
            {
                cmd = new SqlCommand(spName, conn)
                {
                    CommandType    = CommandType.StoredProcedure,
                    CommandTimeout = 180,
                };
                AddProductionFilterParameters(
                    cmd,
                    filterPayerNames, filterPanelNames,
                    filterDosFrom, filterDosTo,
                    filterFirstBillFrom, filterFirstBillTo,
                    filterFirstBilledFrom, filterFirstBilledTo);
            }
            else
            {
                var legacySql =
                    $"SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges " +
                    $"FROM dbo.{_cfg.Prefix}PayerBreakdown ORDER BY PayerName, BilledYearMonth";
                cmd = new SqlCommand(legacySql, conn) { CommandTimeout = 120 };
            }
            await using var _cmd = cmd;
            await using var rdr = await cmd.ExecuteReaderAsync(ct);

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

            var months       = allMonths.ToList();
            var years        = months.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
            var grandByMonth = new Dictionary<string, int>();
            var payerRows    = new List<PayerBreakdownRow>();

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
            _logger.LogError(ex, "[{Prefix}] GetPayerBreakdownAsync failed.", _cfg.Prefix);
        return new SharedPayerBreakdownResult([], [], [], new Dictionary<string, int>(), 0);
        }
    }

    // ?? Payer × Panel ?????????????????????????????????????????????????????
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
        // When the lab's read SP is parameterised, call it. Otherwise fall back to the
        // legacy direct SELECT against the snapshot table (filters silently ignored).
        var spName = $"dbo.usp_Get{_cfg.Prefix}PayerByPanel";

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            SqlCommand cmd;
            if (_cfg.SupportsFilteredMonthlyWeeklySp)
            {
                cmd = new SqlCommand(spName, conn)
                {
                    CommandType    = CommandType.StoredProcedure,
                    CommandTimeout = 180,
                };
                AddProductionFilterParameters(
                    cmd,
                    filterPayerNames, filterPanelNames,
                    filterDosFrom, filterDosTo,
                    filterFirstBillFrom, filterFirstBillTo,
                    filterFirstBilledFrom, filterFirstBilledTo);
            }
            else
            {
                var legacySql =
                    $"SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges " +
                    $"FROM dbo.{_cfg.Prefix}PayerByPanel ORDER BY PayerName, PanelName";
                cmd = new SqlCommand(legacySql, conn) { CommandTimeout = 120 };
            }
            await using var _cmd = cmd;
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
                panelCols,
                payerRows,
                grandPanel,
                grandPanel.Values.Sum(c => c.ClaimCount),
                grandPanel.Values.Sum(c => c.BilledCharges));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[{Prefix}] GetPayerByPanelAsync failed.", _cfg.Prefix);
        return new SharedPayerPanelResult([], [], new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase), 0, 0m);
        }
    }

    // ?? Unbilled Aging ????????????????????????????????????????????????????
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
        // When the lab's read SP is parameterised, call it. Otherwise fall back to the
        // legacy direct SELECT against the snapshot table (filters silently ignored).
        var spName = $"dbo.usp_Get{_cfg.Prefix}UnbilledAging";

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            SqlCommand cmd;
            if (_cfg.SupportsFilteredMonthlyWeeklySp)
            {
                cmd = new SqlCommand(spName, conn)
                {
                    CommandType    = CommandType.StoredProcedure,
                    CommandTimeout = 180,
                };
                AddProductionFilterParameters(
                    cmd,
                    filterPayerNames, filterPanelNames,
                    filterDosFrom, filterDosTo,
                    filterFirstBillFrom, filterFirstBillTo,
                    filterFirstBilledFrom, filterFirstBilledTo);
            }
            else
            {
                // The TotalCharges column may not exist in some tables (e.g. Cove).
                var chargesCol = _cfg.UnbilledAgingHasCharges
                    ? ", TotalCharges"
                    : ", CAST(0 AS DECIMAL(18,2)) AS TotalCharges";
                var legacySql =
                    $"SELECT {_cfg.UnbilledAgingRowKey}, {_cfg.UnbilledAgingBucketCol}, ClaimCount{chargesCol} " +
                    $"FROM dbo.{_cfg.Prefix}UnbilledAging " +
                    $"ORDER BY {_cfg.UnbilledAgingRowKey}, {_cfg.UnbilledAgingBucketCol}";
                cmd = new SqlCommand(legacySql, conn) { CommandTimeout = 120 };
            }
            await using var _cmd = cmd;
            await using var rdr = await cmd.ExecuteReaderAsync(ct);

            var rowBucket  = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var allBuckets = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);

            while (await rdr.ReadAsync(ct))
            {
                var rowKey  = rdr.IsDBNull(0) ? "Unknown" : rdr.GetString(0);
                var bucket  = rdr.IsDBNull(1) ? "Unknown" : rdr.GetString(1);
                var count   = rdr.GetInt32(2);
                var charges = rdr.GetDecimal(3);

                allBuckets.Add(bucket);
                if (!rowBucket.TryGetValue(rowKey, out var rb)) rowBucket[rowKey] = rb = new(StringComparer.OrdinalIgnoreCase);
                rb[bucket] = (rb.GetValueOrDefault(bucket).c + count, rb.GetValueOrDefault(bucket).ch + charges);
            }

            var grandByBucket = new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase);
            var panelRows     = new List<UnbilledAgingRow>();

            foreach (var (rowKey, rb) in rowBucket.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
            {
                var byBucket = rb.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));
                foreach (var (bk, cell) in byBucket)
                {
                    if (!grandByBucket.TryGetValue(bk, out var g)) grandByBucket[bk] = cell;
                    else grandByBucket[bk] = new ProductionMonthCell(g.ClaimCount + cell.ClaimCount, g.BilledCharges + cell.BilledCharges);
                }
                panelRows.Add(new UnbilledAgingRow
                {
                    PanelName         = rowKey,
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
            _logger.LogError(ex, "[{Prefix}] GetUnbilledAgingAsync failed.", _cfg.Prefix);
        return new SharedUnbilledAgingResult([], new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase), 0, 0m);
        }
    }

    // ?? CPT Breakdown ?????????????????????????????????????????????????????
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
        // When the lab's read SP is parameterised, call it. Otherwise fall back to the
        // legacy direct SELECT against the snapshot table (filters silently ignored).
        var spName = $"dbo.usp_Get{_cfg.Prefix}CPTBreakdown";

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            SqlCommand cmd;
            if (_cfg.SupportsFilteredMonthlyWeeklySp)
            {
                cmd = new SqlCommand(spName, conn)
                {
                    CommandType    = CommandType.StoredProcedure,
                    CommandTimeout = 180,
                };
                AddProductionFilterParameters(
                    cmd,
                    filterPayerNames, filterPanelNames,
                    filterDosFrom, filterDosTo,
                    filterFirstBillFrom, filterFirstBillTo,
                    filterFirstBilledFrom, filterFirstBilledTo);
            }
            else
            {
                var legacySql =
                    $"SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges " +
                    $"FROM dbo.{_cfg.Prefix}CPTBreakdown ORDER BY CPTCode, BilledYearMonth";
                cmd = new SqlCommand(legacySql, conn) { CommandTimeout = 120 };
            }
            await using var _cmd = cmd;
            await using var rdr = await cmd.ExecuteReaderAsync(ct);

            var cptMonth  = new Dictionary<string, Dictionary<string, (int c, decimal u, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
            var allMonths = new SortedSet<string>();

            while (await rdr.ReadAsync(ct))
            {
                var cpt     = rdr.GetString(0);
                var month   = rdr.GetString(1);
                // Column 2 = LineCount (claim count); Column 3 = BilledUnits (sum of Units field)
                var count   = rdr.GetInt32(2);     // LineCount (index 2) - this is the claim count
                var units   = rdr.GetDecimal(3);   // BilledUnits (index 3)
                var charges = rdr.GetDecimal(4);

                allMonths.Add(month);
                if (!cptMonth.TryGetValue(cpt, out var mm)) cptMonth[cpt] = mm = [];
                var prev = mm.GetValueOrDefault(month);
                mm[month] = (prev.c + count, prev.u + units, prev.ch + charges);
            }

            var months       = allMonths.ToList();
            var years        = months.Select(m => int.Parse(m[..4])).Distinct().OrderBy(y => y).ToList();
            var grandByMonth = new Dictionary<string, CptBreakdownCell>();
            var cptRows      = new List<CptBreakdownRow>();

            foreach (var (cpt, mm) in cptMonth.OrderBy(x => x.Key))
            {
                var byMonth = mm.ToDictionary(kv => kv.Key, kv => new CptBreakdownCell(kv.Value.u, kv.Value.ch, kv.Value.c));
                foreach (var (mk, cell) in byMonth)
                {
                    if (!grandByMonth.TryGetValue(mk, out var g)) grandByMonth[mk] = cell;
                    else grandByMonth[mk] = new CptBreakdownCell(
                        g.Units + cell.Units, 
                        g.BilledCharges + cell.BilledCharges,
                        g.ClaimCount + cell.ClaimCount);
                }
                cptRows.Add(new CptBreakdownRow
                {
                    CptCode           = cpt,
                    ByMonth           = byMonth,
                    GrandTotalUnits   = byMonth.Values.Sum(c => c.Units),
                    GrandTotalCharges = byMonth.Values.Sum(c => c.BilledCharges),
                    GrandTotalClaims  = byMonth.Values.Sum(c => c.ClaimCount),
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
            _logger.LogError(ex, "[{Prefix}] GetCptBreakdownAsync failed.", _cfg.Prefix);
        return new SharedCptBreakdownResult([], [], [], new Dictionary<string, CptBreakdownCell>(), 0m, 0m);
        }
    }

    // Adds the @PayerNames / @PanelNames / @Dos*/@FirstBill*/@FirstBilled* parameters
    // expected by the parameterised Monthly/Weekly read SPs. List parameters are
    // joined with '|' so values containing commas survive intact. NULL is sent for
    // missing values; the SP treats NULL as "no filter".
    private static void AddProductionFilterParameters(
        SqlCommand cmd,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        DateOnly? filterDosFrom,
        DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom,
        DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom,
        DateOnly? filterFirstBilledTo)
    {
        cmd.Parameters.Add(new SqlParameter("@PayerNames", SqlDbType.NVarChar, -1)
        {
            Value = JoinList(filterPayerNames),
        });
        cmd.Parameters.Add(new SqlParameter("@PanelNames", SqlDbType.NVarChar, -1)
        {
            Value = JoinList(filterPanelNames),
        });
        cmd.Parameters.Add(DateParam("@DosFrom",         filterDosFrom));
        cmd.Parameters.Add(DateParam("@DosTo",           filterDosTo));
        cmd.Parameters.Add(DateParam("@FirstBillFrom",   filterFirstBillFrom));
        cmd.Parameters.Add(DateParam("@FirstBillTo",     filterFirstBillTo));
        cmd.Parameters.Add(DateParam("@FirstBilledFrom", filterFirstBilledFrom));
        cmd.Parameters.Add(DateParam("@FirstBilledTo",   filterFirstBilledTo));

        static object JoinList(List<string>? values)
        {
            if (values is null || values.Count == 0) return DBNull.Value;
            var cleaned = values
                .Where(v => !string.IsNullOrWhiteSpace(v))
                .Select(v => v.Trim())
                .ToList();
            return cleaned.Count == 0 ? DBNull.Value : string.Join('|', cleaned);
        }

        static SqlParameter DateParam(string name, DateOnly? value) =>
            new(name, SqlDbType.Date)
            {
                Value = value.HasValue
                    ? value.Value.ToDateTime(TimeOnly.MinValue)
                    : DBNull.Value,
            };
    }
}
