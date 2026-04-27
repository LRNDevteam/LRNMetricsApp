using LabMetricsDashboard.Models;
using LabMetricsDashboard.Models;
using System.Diagnostics;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// SQL Server implementation of <see cref="ICollectionSummaryRepository"/>.
/// Reads from <c>dbo.ClaimLevelData</c>.
/// </summary>
public sealed class SqlCollectionSummaryRepository : ICollectionSummaryRepository
{
    private readonly ILogger<SqlCollectionSummaryRepository> _logger;

    public SqlCollectionSummaryRepository(ILogger<SqlCollectionSummaryRepository> logger)
        => _logger = logger;

    /// <summary>Fetches distinct PayerName/PanelName lists once for filter dropdowns.</summary>
    public async Task<CollectionFilterOptions> GetFilterOptionsAsync(
        string connectionString,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        const string sql = """
            SELECT DISTINCT LTRIM(RTRIM(PayerName_Raw)) FROM dbo.ClaimLevelData
            WHERE PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> '' ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM(PanelName)) FROM dbo.ClaimLevelData
            WHERE PanelName IS NOT NULL AND LTRIM(RTRIM(PanelName)) <> '' ORDER BY 1;
            """;

        var sw = Stopwatch.StartNew();
        var payerNames = new List<string>();
        var panelNames = new List<string>();

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) payerNames.Add(r.GetString(0));
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct)) panelNames.Add(r.GetString(0));

        _logger.LogInformation("CollectionSummary FilterOptions: payers={Payers}, panels={Panels}, elapsed={Ms}ms",
            payerNames.Count, panelNames.Count, sw.ElapsedMilliseconds);

        return new CollectionFilterOptions(payerNames, panelNames);
    }

    public async Task<CollectionMonthlyVolumeResult> GetCollectionMonthlyVolumeAsync(
        string connectionString,
        string? rule = null,
        bool useLineEncounters = false,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        _ = rule;
        _ = useLineEncounters;

        // Data based on Posted Date (CheckDate)
        const string dateColumn = "CheckDate";

        // Base WHERE for ClaimLevelData (monthly): only InsurancePayment > 0 and
        // valid CheckDate. Any user-selected filters are appended below.
        var whereClauses = new List<string>
        {
            "ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0",
            "PanelName IS NOT NULL",
            "LTRIM(RTRIM(PanelName)) <> ''",
            "PayerName_Raw IS NOT NULL",
            "LTRIM(RTRIM(PayerName_Raw)) <> ''",
            $"TRY_CAST({dateColumn} AS DATE) IS NOT NULL",
            $"YEAR(TRY_CAST({dateColumn} AS DATE)) > 1900"
        };
        var parameters = new List<SqlParameter>();

        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PayerName_Raw))", "@mvpn", filterPayerNames);
        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PanelName))", "@mvpl", filterPanelNames);
        AddAllDateFilters(whereClauses, parameters, "mv",
            filterFirstBillFrom, filterFirstBillTo,
            filterDosFrom, filterDosTo,
            filterCheckDateFrom, filterCheckDateTo);

        var whereStr = string.Join(" AND ", whereClauses);

        const string countExpr = "COUNT(DISTINCT ClaimID)";
        const string payerGroupExpr = "LTRIM(RTRIM(PayerName_Raw))";

        var pivotSql = $"""
            SELECT
                LTRIM(RTRIM(PanelName))                                 AS PanelName,
                {payerGroupExpr}                                        AS PayerName,
                YEAR(TRY_CAST({dateColumn} AS DATE))                    AS BillYear,
                MONTH(TRY_CAST({dateColumn} AS DATE))                   AS BillMonth,
                {countExpr}                                             AS LineItemCount,
                ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePaid
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY
                LTRIM(RTRIM(PanelName)),
                {payerGroupExpr},
                YEAR(TRY_CAST({dateColumn} AS DATE)),
                MONTH(TRY_CAST({dateColumn} AS DATE))
            ORDER BY PanelName, PayerName, BillYear, BillMonth
            """;

        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        var rawRows = new List<CollectionRawPivotRow>();
        await using (var cmd = new SqlCommand(pivotSql, conn) { CommandTimeout = 180 })
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                rawRows.Add(new CollectionRawPivotRow(
                    PanelName: r.GetString(r.GetOrdinal("PanelName")),
                    PayerName: r.GetString(r.GetOrdinal("PayerName")),
                    BillYear: r.GetInt32(r.GetOrdinal("BillYear")),
                    BillMonth: r.GetInt32(r.GetOrdinal("BillMonth")),
                    LineItemCount: r.GetInt32(r.GetOrdinal("LineItemCount")),
                    InsurancePaid: r.GetDecimal(r.GetOrdinal("InsurancePaid"))));
            }
        }

        // If using LineLevelData for encounter counts, fetch them separately
        // Monthly volume is based on ClaimLevelData unique ClaimID counts.
        Dictionary<(string Panel, string Payer, int Year, int Month), int>? lineEncounters = null;

        _logger.LogInformation(
            "CollectionSummary MonthlyVolume: rawRows={Count}, useLineEncounters={UseLine}, elapsed={Ms}ms",
            rawRows.Count, useLineEncounters, sw.ElapsedMilliseconds);

        return BuildCollectionMonthlyResult(rawRows, lineEncounters);
    }

    /// <summary>
    /// Reads encounter counts from LineLevelData for labs that need line-level encounters.
    /// </summary>
    private static async Task<Dictionary<(string Panel, string Payer, int Year, int Month), int>> GetLineEncounterCountsAsync(
        SqlConnection conn,
        List<SqlParameter> baseParams,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        CancellationToken ct)
    {
        var llWhere = new List<string>
        {
            "ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0",
            "LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid','Paid-Client')",
            "PanelName IS NOT NULL",
            "LTRIM(RTRIM(PanelName)) <> ''",
            "TRY_CAST(PostingDate AS DATE) IS NOT NULL",
            "YEAR(TRY_CAST(PostingDate AS DATE)) > 1900"
        };
        var llParams = new List<SqlParameter>();

        AddInClause(llWhere, llParams, "LTRIM(RTRIM(PayerName_Raw))", "@llpn", filterPayerNames);
        AddInClause(llWhere, llParams, "LTRIM(RTRIM(PanelName))", "@llpl", filterPanelNames);

        var llWhereStr = string.Join(" AND ", llWhere);

        var llSql = $"""
            SELECT
                LTRIM(RTRIM(PanelName))                                 AS PanelName,
                LTRIM(RTRIM(PayerName))                                 AS PayerName,
                YEAR(TRY_CAST(PostingDate AS DATE))                     AS BillYear,
                MONTH(TRY_CAST(PostingDate AS DATE))                    AS BillMonth,
                COUNT(*)                                                AS EncounterCount
            FROM dbo.LineLevelData
            WHERE {llWhereStr}
            GROUP BY
                LTRIM(RTRIM(PanelName)),
                LTRIM(RTRIM(PayerName)),
                YEAR(TRY_CAST(PostingDate AS DATE)),
                MONTH(TRY_CAST(PostingDate AS DATE))
            """;

        var result = new Dictionary<(string, string, int, int), int>();

        await using var cmd = new SqlCommand(llSql, conn) { CommandTimeout = 180 };
        cmd.Parameters.AddRange(CloneParams(llParams));
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            var key = (
                r.GetString(r.GetOrdinal("PanelName")),
                r.GetString(r.GetOrdinal("PayerName")),
                r.GetInt32(r.GetOrdinal("BillYear")),
                r.GetInt32(r.GetOrdinal("BillMonth")));
            result[key] = r.GetInt32(r.GetOrdinal("EncounterCount"));
        }

        return result;
    }

    /// <summary>
    /// Builds the Collection Monthly Volume pivot result from raw query rows.
    /// </summary>
    private static CollectionMonthlyVolumeResult BuildCollectionMonthlyResult(
        List<CollectionRawPivotRow> rawRows,
        Dictionary<(string Panel, string Payer, int Year, int Month), int>? lineEncounters)
    {
        if (rawRows.Count == 0)
        {
            return new CollectionMonthlyVolumeResult(
                [], [], [], [], [], 0, 0m);
        }

        // Discover periods
        var periodSet = new SortedSet<string>();
        var yearSet = new SortedSet<int>();
        foreach (var r in rawRows)
        {
            periodSet.Add($"{r.BillYear:D4}-{r.BillMonth:D2}");
            yearSet.Add(r.BillYear);
        }

        var periods = periodSet
            .Select(k =>
            {
                var parts = k.Split('-');
                return new CollectionMonthlyPeriod(int.Parse(parts[0]), int.Parse(parts[1]));
            })
            .ToList();
        var years = yearSet.ToList();

        // Group by Panel ? Payer ? Month
        var panelGroups = rawRows
            .GroupBy(r => r.PanelName, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var panelRows = new List<CollectionPanelRow>();
        var grandByMonth = new Dictionary<string, (int enc, decimal paid)>();
        var grandByYear = new Dictionary<int, (int enc, decimal paid)>();
        int grandEncounters = 0;
        decimal grandPaid = 0m;

        foreach (var pg in panelGroups)
        {
            var panelByMonth = new Dictionary<string, CollectionMonthlyCell>();
            var panelByYear = new Dictionary<int, (int enc, decimal paid)>();
            int panelTotalEnc = 0;
            decimal panelTotalPaid = 0m;

            // Per-payer aggregation for drill-down ranking
            var payerAgg = new Dictionary<string, (int totalEnc, decimal totalPaid,
                Dictionary<string, (int enc, decimal paid)> byMonth,
                Dictionary<int, (int enc, decimal paid)> byYear)>(StringComparer.OrdinalIgnoreCase);

            foreach (var r in pg)
            {
                var mk = $"{r.BillYear:D4}-{r.BillMonth:D2}";
                int enc = lineEncounters is not null
                    && lineEncounters.TryGetValue((r.PanelName, r.PayerName, r.BillYear, r.BillMonth), out var le)
                    ? le : r.LineItemCount;

                // Panel level
                if (panelByMonth.TryGetValue(mk, out var existing))
                    panelByMonth[mk] = new CollectionMonthlyCell(existing.EncounterCount + enc, existing.InsurancePaidAmount + r.InsurancePaid);
                else
                    panelByMonth[mk] = new CollectionMonthlyCell(enc, r.InsurancePaid);

                if (panelByYear.TryGetValue(r.BillYear, out var yExisting))
                    panelByYear[r.BillYear] = (yExisting.enc + enc, yExisting.paid + r.InsurancePaid);
                else
                    panelByYear[r.BillYear] = (enc, r.InsurancePaid);

                panelTotalEnc += enc;
                panelTotalPaid += r.InsurancePaid;

                // Grand totals
                if (grandByMonth.TryGetValue(mk, out var gm))
                    grandByMonth[mk] = (gm.enc + enc, gm.paid + r.InsurancePaid);
                else
                    grandByMonth[mk] = (enc, r.InsurancePaid);

                if (grandByYear.TryGetValue(r.BillYear, out var gy))
                    grandByYear[r.BillYear] = (gy.enc + enc, gy.paid + r.InsurancePaid);
                else
                    grandByYear[r.BillYear] = (enc, r.InsurancePaid);

                grandEncounters += enc;
                grandPaid += r.InsurancePaid;

                // Payer level
                if (!payerAgg.TryGetValue(r.PayerName, out var pa))
                {
                    pa = (0, 0m, new Dictionary<string, (int, decimal)>(), new Dictionary<int, (int, decimal)>());
                    payerAgg[r.PayerName] = pa;
                }

                pa.totalEnc += enc;
                pa.totalPaid += r.InsurancePaid;

                if (pa.byMonth.TryGetValue(mk, out var pmExisting))
                    pa.byMonth[mk] = (pmExisting.enc + enc, pmExisting.paid + r.InsurancePaid);
                else
                    pa.byMonth[mk] = (enc, r.InsurancePaid);

                if (pa.byYear.TryGetValue(r.BillYear, out var pyExisting))
                    pa.byYear[r.BillYear] = (pyExisting.enc + enc, pyExisting.paid + r.InsurancePaid);
                else
                    pa.byYear[r.BillYear] = (enc, r.InsurancePaid);

                payerAgg[r.PayerName] = pa;
            }

            // When lineEncounters is provided (table1 mode), show all payers; otherwise top 3
            var payerQuery = payerAgg
                .OrderByDescending(kv => kv.Value.totalEnc);

            var topPayers = (lineEncounters is not null ? payerQuery : payerQuery.Take(3))
                .Select(kv => new CollectionPayerDrillDown
                {
                    PayerName = kv.Key,
                    ByMonth = kv.Value.byMonth.ToDictionary(
                        m => m.Key,
                        m => new CollectionMonthlyCell(m.Value.enc, m.Value.paid)),
                    ByYear = kv.Value.byYear.ToDictionary(
                        y => y.Key,
                        y => new CollectionYearTotal(y.Value.enc, y.Value.paid)),
                    TotalEncounters = kv.Value.totalEnc,
                    TotalInsurancePaid = kv.Value.totalPaid,
                })
                .ToList();

            panelRows.Add(new CollectionPanelRow
            {
                PanelName = pg.Key,
                ByMonth = panelByMonth,
                ByYear = panelByYear.ToDictionary(
                    kv => kv.Key,
                    kv => new CollectionYearTotal(kv.Value.enc, kv.Value.paid)),
                TotalEncounters = panelTotalEnc,
                TotalInsurancePaid = panelTotalPaid,
                TopPayers = topPayers,
            });
        }

        // Sort panels by grand total encounters descending
        panelRows.Sort((a, b) => b.TotalEncounters.CompareTo(a.TotalEncounters));

        return new CollectionMonthlyVolumeResult(
            periods,
            years,
            panelRows,
            grandByMonth.ToDictionary(kv => kv.Key, kv => new CollectionMonthlyCell(kv.Value.enc, kv.Value.paid)),
            grandByYear.ToDictionary(kv => kv.Key, kv => new CollectionYearTotal(kv.Value.enc, kv.Value.paid)),
            grandEncounters,
            grandPaid);
    }

    private sealed record CollectionRawPivotRow(
        string PanelName,
        string PayerName,
        int BillYear,
        int BillMonth,
        int LineItemCount,
        decimal InsurancePaid);


    // ?? Weekly Claim Volume ??????????????????????????????????????

    public async Task<CollectionWeeklyVolumeResult> GetCollectionWeeklyVolumeAsync(
        string connectionString,
        bool useLineEncounters = false,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        string? weeklyRule = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        // Northwestlabs rule: group payer drill-down by raw payer name (PayerName_Raw)
        // instead of the cleaned PayerName.
        var useRawPayer = !string.IsNullOrWhiteSpace(weeklyRule)
            && string.Equals(weeklyRule, "Northwestlabs Rule", StringComparison.OrdinalIgnoreCase);
        var payerSelectExpr = useRawPayer
            ? "LTRIM(RTRIM(PayerName_Raw))"
            : "LTRIM(RTRIM(PayerName))";

        // Compute the last 4 complete weeks (Mon-Sun) ending before the current week.
        var today = DateTime.Today;
        var daysSinceSunday = (int)today.DayOfWeek;
        var lastSunday = today.AddDays(daysSinceSunday == 0 ? -7 : -daysSinceSunday);
        var weeks = new List<CollectionWeekBucket>(4);
        for (var i = 3; i >= 0; i--)
        {
            var weekEnd = lastSunday.AddDays(-7 * i);
            var weekStart = weekEnd.AddDays(-6);
            weeks.Add(new CollectionWeekBucket(4 - i, weekStart, weekEnd));
        }

        var week1Start = weeks[0].WeekStart;
        var week4End = weeks[^1].WeekEnd;

        // ClaimLevelData uses CheckDate; LineLevelData uses PostingDate
        var clWeekCaseSql = string.Join("\n                ",
            weeks.Select(w =>
                $"WHEN TRY_CAST(CheckDate AS DATE) BETWEEN '{w.WeekStart:yyyy-MM-dd}' AND '{w.WeekEnd:yyyy-MM-dd}' THEN '{w.Key}'"));
        var clWeekCaseExpr = $"CASE {clWeekCaseSql} END";

        var llWeekCaseSql = string.Join("\n                ",
            weeks.Select(w =>
                $"WHEN TRY_CAST(PostingDate AS DATE) BETWEEN '{w.WeekStart:yyyy-MM-dd}' AND '{w.WeekEnd:yyyy-MM-dd}' THEN '{w.Key}'"));
        var llWeekCaseExpr = $"CASE {llWeekCaseSql} END";

        var clWhere = new List<string>
        {
            "ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0",
            "LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid','Paid-Client')",
            "PanelName IS NOT NULL",
            "LTRIM(RTRIM(PanelName)) <> ''",
            "TRY_CAST(CheckDate AS DATE) IS NOT NULL",
            $"TRY_CAST(CheckDate AS DATE) BETWEEN '{week1Start:yyyy-MM-dd}' AND '{week4End:yyyy-MM-dd}'"
        };
        var clParams = new List<SqlParameter>();
        AddInClause(clWhere, clParams, "LTRIM(RTRIM(PayerName_Raw))", "@wvpn", filterPayerNames);
        AddInClause(clWhere, clParams, "LTRIM(RTRIM(PanelName))", "@wvpl", filterPanelNames);
        AddAllDateFilters(clWhere, clParams, "wv", filterFirstBillFrom, filterFirstBillTo, filterDosFrom, filterDosTo, filterCheckDateFrom, filterCheckDateTo);
        var clWhereStr = string.Join(" AND ", clWhere);

        var countExpr = useLineEncounters ? "COUNT(*)" : "COUNT(DISTINCT ClaimID)";
        var clSql = $"""
            SELECT
                LTRIM(RTRIM(PanelName))                                 AS PanelName,
                {payerSelectExpr}                                       AS PayerName,
                {clWeekCaseExpr}                                        AS WeekKey,
                {countExpr}                                             AS EncounterCount,
                ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePaid
            FROM dbo.ClaimLevelData
            WHERE {clWhereStr}
              AND {clWeekCaseExpr} IS NOT NULL
            GROUP BY
                LTRIM(RTRIM(PanelName)),
                {payerSelectExpr},
                {clWeekCaseExpr}
            ORDER BY PanelName, PayerName, WeekKey
            """;

        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        var claimRows = new List<WeeklyRawRow>();
        await using (var cmd = new SqlCommand(clSql, conn) { CommandTimeout = 180 })
        {
            cmd.Parameters.AddRange(CloneParams(clParams));
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                claimRows.Add(new WeeklyRawRow(
                    r.GetString(r.GetOrdinal("PanelName")),
                    r.GetString(r.GetOrdinal("PayerName")),
                    r.GetString(r.GetOrdinal("WeekKey")),
                    r.GetInt32(r.GetOrdinal("EncounterCount")),
                    r.GetDecimal(r.GetOrdinal("InsurancePaid"))));
            }
        }

        Dictionary<(string Panel, string Payer, string WeekKey), int>? lineEncounters = null;
        if (useLineEncounters)
        {
            lineEncounters = await GetWeeklyLineEncounterCountsAsync(
                conn, weeks, llWeekCaseExpr, week1Start, week4End,
                filterPayerNames, filterPanelNames, ct);
        }

        _logger.LogInformation(
            "CollectionSummary WeeklyVolume: claimRows={Count}, useLineEncounters={UseLine}, elapsed={Ms}ms",
            claimRows.Count, useLineEncounters, sw.ElapsedMilliseconds);

        return BuildCollectionWeeklyResult(weeks, claimRows, lineEncounters, useLineEncounters);
    }

    private sealed record WeeklyRawRow(
        string PanelName, string PayerName, string WeekKey,
        int EncounterCount, decimal InsurancePaid);

    private static async Task<Dictionary<(string Panel, string Payer, string WeekKey), int>> GetWeeklyLineEncounterCountsAsync(
        SqlConnection conn, List<CollectionWeekBucket> weeks, string weekCaseExpr,
        DateTime week1Start, DateTime week4End,
        List<string>? filterPayerNames, List<string>? filterPanelNames,
        CancellationToken ct)
    {
        var llWhere = new List<string>
        {
            "ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0",
            "LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid','Paid-Client')",
            "PanelName IS NOT NULL",
            "LTRIM(RTRIM(PanelName)) <> ''",
            "TRY_CAST(PostingDate AS DATE) IS NOT NULL",
            $"TRY_CAST(PostingDate AS DATE) BETWEEN '{week1Start:yyyy-MM-dd}' AND '{week4End:yyyy-MM-dd}'"
        };
        var llParams = new List<SqlParameter>();
        AddInClause(llWhere, llParams, "LTRIM(RTRIM(PayerName))", "@wllpn", filterPayerNames);
        AddInClause(llWhere, llParams, "LTRIM(RTRIM(PanelName))", "@wllpl", filterPanelNames);
        var llWhereStr = string.Join(" AND ", llWhere);

        var llSql = $"""
            SELECT
                LTRIM(RTRIM(PanelName))  AS PanelName,
                LTRIM(RTRIM(PayerName))  AS PayerName,
                {weekCaseExpr}           AS WeekKey,
                COUNT(*)                 AS EncounterCount
            FROM dbo.LineLevelData
            WHERE {llWhereStr}
              AND {weekCaseExpr} IS NOT NULL
            GROUP BY
                LTRIM(RTRIM(PanelName)),
                LTRIM(RTRIM(PayerName)),
                {weekCaseExpr}
            """;

        var result = new Dictionary<(string, string, string), int>();
        await using var cmd = new SqlCommand(llSql, conn) { CommandTimeout = 180 };
        cmd.Parameters.AddRange(CloneParams(llParams));
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            var key = (
                r.GetString(r.GetOrdinal("PanelName")),
                r.GetString(r.GetOrdinal("PayerName")),
                r.GetString(r.GetOrdinal("WeekKey")));
            result[key] = r.GetInt32(r.GetOrdinal("EncounterCount"));
        }
        return result;
    }

    private static CollectionWeeklyVolumeResult BuildCollectionWeeklyResult(
        List<CollectionWeekBucket> weeks, List<WeeklyRawRow> rawRows,
        Dictionary<(string Panel, string Payer, string WeekKey), int>? lineEncounters,
        bool useLineEncounters)
    {
        if (rawRows.Count == 0)
            return new CollectionWeeklyVolumeResult(weeks, [], [], 0, 0m);

        var panelGroups = rawRows
            .GroupBy(r => r.PanelName, StringComparer.OrdinalIgnoreCase).ToList();

        var panelRows = new List<CollectionWeeklyPanelRow>();
        var grandByWeek = new Dictionary<string, (int enc, decimal paid)>();
        int grandEncounters = 0;
        decimal grandPaid = 0m;

        foreach (var pg in panelGroups)
        {
            var panelByWeek = new Dictionary<string, (int enc, decimal paid)>();
            int panelTotalEnc = 0;
            decimal panelTotalPaid = 0m;
            var payerAgg = new Dictionary<string, (int totalEnc, decimal totalPaid,
                Dictionary<string, (int enc, decimal paid)> byWeek)>(StringComparer.OrdinalIgnoreCase);

            foreach (var r in pg)
            {
                int enc = lineEncounters is not null
                    && lineEncounters.TryGetValue((r.PanelName, r.PayerName, r.WeekKey), out var le)
                    ? le : r.EncounterCount;

                if (panelByWeek.TryGetValue(r.WeekKey, out var existing))
                    panelByWeek[r.WeekKey] = (existing.enc + enc, existing.paid + r.InsurancePaid);
                else
                    panelByWeek[r.WeekKey] = (enc, r.InsurancePaid);

                panelTotalEnc += enc;
                panelTotalPaid += r.InsurancePaid;

                if (grandByWeek.TryGetValue(r.WeekKey, out var gw))
                    grandByWeek[r.WeekKey] = (gw.enc + enc, gw.paid + r.InsurancePaid);
                else
                    grandByWeek[r.WeekKey] = (enc, r.InsurancePaid);

                grandEncounters += enc;
                grandPaid += r.InsurancePaid;

                if (!payerAgg.TryGetValue(r.PayerName, out var pa))
                {
                    pa = (0, 0m, new Dictionary<string, (int, decimal)>());
                    payerAgg[r.PayerName] = pa;
                }
                pa.totalEnc += enc;
                pa.totalPaid += r.InsurancePaid;
                if (pa.byWeek.TryGetValue(r.WeekKey, out var pwExisting))
                    pa.byWeek[r.WeekKey] = (pwExisting.enc + enc, pwExisting.paid + r.InsurancePaid);
                else
                    pa.byWeek[r.WeekKey] = (enc, r.InsurancePaid);
                payerAgg[r.PayerName] = pa;
            }

            var payerQuery = payerAgg.OrderByDescending(kv => kv.Value.totalEnc);
            var topPayers = (useLineEncounters ? payerQuery : payerQuery.Take(3))
                .Select(kv => new CollectionWeeklyPayerDrillDown
                {
                    PayerName = kv.Key,
                    ByWeek = kv.Value.byWeek.ToDictionary(
                        m => m.Key, m => new CollectionMonthlyCell(m.Value.enc, m.Value.paid)),
                    TotalEncounters = kv.Value.totalEnc,
                    TotalInsurancePaid = kv.Value.totalPaid,
                }).ToList();

            panelRows.Add(new CollectionWeeklyPanelRow
            {
                PanelName = pg.Key,
                ByWeek = panelByWeek.ToDictionary(
                    kv => kv.Key, kv => new CollectionMonthlyCell(kv.Value.enc, kv.Value.paid)),
                TotalEncounters = panelTotalEnc,
                TotalInsurancePaid = panelTotalPaid,
                TopPayers = topPayers,
            });
        }

        panelRows.Sort((a, b) => b.TotalEncounters.CompareTo(a.TotalEncounters));

        return new CollectionWeeklyVolumeResult(
            weeks, panelRows,
            grandByWeek.ToDictionary(kv => kv.Key, kv => new CollectionMonthlyCell(kv.Value.enc, kv.Value.paid)),
            grandEncounters, grandPaid);
    }


    public async Task<Top5ReimbursementResult> GetTop5ReimbursementAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        // ?? Build WHERE clauses for the data query ??????????????
        var whereClauses = new List<string>
        {
            "ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0",
            "LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid','Patient Responsibility')",
            "PayerName_Raw IS NOT NULL",
            "LTRIM(RTRIM(PayerName_Raw)) <> ''"
        };
        var parameters = new List<SqlParameter>();

        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PayerName_Raw))", "@fpn", filterPayerNames);
        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PanelName))", "@fpl", filterPanelNames);
        AddAllDateFilters(whereClauses, parameters, "f", filterFirstBillFrom, filterFirstBillTo, filterDosFrom, filterDosTo, filterCheckDateFrom, filterCheckDateTo);

        var whereStr = string.Join(" AND ", whereClauses);

        var dataSql = $"""
            SELECT TOP 5
                LTRIM(RTRIM(PayerName_Raw))                                           AS PayerName,
                ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)            AS SumInsPayment,
                ISNULL(SUM(TRY_CAST(ChargeAmount     AS DECIMAL(18,2))), 0)            AS SumCharges,
                COUNT(DISTINCT AccessionNumber)                                         AS UniqueVisits
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY LTRIM(RTRIM(PayerName_Raw))
            ORDER BY COUNT(DISTINCT AccessionNumber) DESC
            """;

        var rows = new List<InsuranceReimbursementRow>();

        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        await using (var cmd = new SqlCommand(dataSql, conn) { CommandTimeout = 120 })
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            await using var r = await cmd.ExecuteReaderAsync(ct);

            int rank = 0;
            while (await r.ReadAsync(ct))
            {
                rank++;
                rows.Add(new InsuranceReimbursementRow(
                    Rank: rank,
                    PayerName: r.GetString(r.GetOrdinal("PayerName")),
                    SumInsurancePayment: r.GetDecimal(r.GetOrdinal("SumInsPayment")),
                    SumChargeAmount: r.GetDecimal(r.GetOrdinal("SumCharges")),
                    UniqueVisitCount: r.GetInt32(r.GetOrdinal("UniqueVisits"))));
            }
        }

        _logger.LogInformation(
            "CollectionSummary Top5Reimbursement: rows={Count}, elapsed={Ms}ms", rows.Count, sw.ElapsedMilliseconds);

        return new Top5ReimbursementResult(rows);
    }

    public async Task<Top5TotalPaymentsResult> GetTop5TotalPaymentsAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        // ?? Build WHERE clauses ?????????????????????????????????
        var whereClauses = new List<string>
        {
            "ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0",
            "LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid','Patient Responsibility')",
            "PayerName_Raw IS NOT NULL",
            "LTRIM(RTRIM(PayerName_Raw)) <> ''"
        };
        var parameters = new List<SqlParameter>();

        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PayerName_Raw))", "@tpn", filterPayerNames);
        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PanelName))", "@tpl", filterPanelNames);
        AddAllDateFilters(whereClauses, parameters, "t", filterFirstBillFrom, filterFirstBillTo, filterDosFrom, filterDosTo, filterCheckDateFrom, filterCheckDateTo);

        var whereStr = string.Join(" AND ", whereClauses);

        // ?? Top 5 Total Payments query ??????????????????????????
        // SUM(InsurancePayment) per PayerName, ranked by COUNT(DISTINCT AccessionNumber) desc.
        var dataSql = $"""
            SELECT TOP 5
                LTRIM(RTRIM(PayerName_Raw))                                           AS PayerName,
                ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)            AS TotalPayments,
                COUNT(DISTINCT AccessionNumber)                                         AS UniqueVisits
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY LTRIM(RTRIM(PayerName_Raw))
            ORDER BY COUNT(DISTINCT AccessionNumber) DESC
            """;

        var rows = new List<InsuranceTotalPaymentRow>();

        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        await using (var cmd = new SqlCommand(dataSql, conn) { CommandTimeout = 120 })
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            await using var r = await cmd.ExecuteReaderAsync(ct);

            int rank = 0;
            while (await r.ReadAsync(ct))
            {
                rank++;
                rows.Add(new InsuranceTotalPaymentRow(
                    Rank: rank,
                    PayerName: r.GetString(r.GetOrdinal("PayerName")),
                    TotalPayments: r.GetDecimal(r.GetOrdinal("TotalPayments")),
                    UniqueVisitCount: r.GetInt32(r.GetOrdinal("UniqueVisits"))));
            }
        }

        _logger.LogInformation(
            "CollectionSummary Top5TotalPayments: rows={Count}, elapsed={Ms}ms", rows.Count, sw.ElapsedMilliseconds);

        return new Top5TotalPaymentsResult(rows);
    }

    public async Task<InsuranceAgingResult> GetInsuranceAgingAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        // ?? Build WHERE clauses ?????????????????????????????????
        var whereClauses = new List<string>
        {
            "LTRIM(RTRIM(ClaimStatus)) = 'No Response'",
            "PayerName_Raw IS NOT NULL",
            "LTRIM(RTRIM(PayerName_Raw)) <> ''"
        };
        var parameters = new List<SqlParameter>();

        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PayerName_Raw))", "@apn", filterPayerNames);
        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PanelName))", "@apl", filterPanelNames);
        AddAllDateFilters(whereClauses, parameters, "a", filterFirstBillFrom, filterFirstBillTo, filterDosFrom, filterDosTo, filterCheckDateFrom, filterCheckDateTo);

        var whereStr = string.Join(" AND ", whereClauses);

        // Aging buckets are derived from DaysToDOS (NVARCHAR ? INT).
        // Current = days < 30, 30+ = 30..59, 60+ = 60..89, 90+ = 90..119, 120+ = >= 120.
            var dataSql = $"""
            ;WITH src AS (
                SELECT
                    LTRIM(RTRIM(PayerName))                              AS PayerName,
                    AccessionNumber,
                    ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) AS InsBalance,
                    ISNULL(TRY_CAST(DaysToDOS AS INT), 0)                AS AgingDays
                FROM dbo.ClaimLevelData
                WHERE {whereStr}
            )
            SELECT
                PayerName,
                COUNT(DISTINCT CASE WHEN AgingDays < 30                  THEN AccessionNumber END) AS ClaimsCurrent,
                SUM(  CASE WHEN AgingDays < 30                           THEN InsBalance ELSE 0 END) AS BalanceCurrent,
                COUNT(DISTINCT CASE WHEN AgingDays >= 30 AND AgingDays < 60  THEN AccessionNumber END) AS Claims30,
                SUM(  CASE WHEN AgingDays >= 30 AND AgingDays < 60       THEN InsBalance ELSE 0 END) AS Balance30,
                COUNT(DISTINCT CASE WHEN AgingDays >= 60 AND AgingDays < 90  THEN AccessionNumber END) AS Claims60,
                SUM(  CASE WHEN AgingDays >= 60 AND AgingDays < 90       THEN InsBalance ELSE 0 END) AS Balance60,
                COUNT(DISTINCT CASE WHEN AgingDays >= 90 AND AgingDays < 120 THEN AccessionNumber END) AS Claims90,
                SUM(  CASE WHEN AgingDays >= 90 AND AgingDays < 120      THEN InsBalance ELSE 0 END) AS Balance90,
                COUNT(DISTINCT CASE WHEN AgingDays >= 120                THEN AccessionNumber END) AS Claims120,
                SUM(  CASE WHEN AgingDays >= 120                         THEN InsBalance ELSE 0 END) AS Balance120,
                COUNT(DISTINCT AccessionNumber)                          AS ClaimsTotal,
                SUM(InsBalance)                                          AS BalanceTotal
            FROM src
            GROUP BY PayerName
            ORDER BY SUM(InsBalance) DESC
            """;

        var rows = new List<InsuranceAgingRow>();

        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        await using (var cmd = new SqlCommand(dataSql, conn) { CommandTimeout = 120 })
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            await using var r = await cmd.ExecuteReaderAsync(ct);

            while (await r.ReadAsync(ct))
            {
                rows.Add(new InsuranceAgingRow(
                    PayerName: r.GetString(r.GetOrdinal("PayerName")),
                    ClaimsCurrent: r.GetInt32(r.GetOrdinal("ClaimsCurrent")),
                    BalanceCurrent: r.GetDecimal(r.GetOrdinal("BalanceCurrent")),
                    Claims30: r.GetInt32(r.GetOrdinal("Claims30")),
                    Balance30: r.GetDecimal(r.GetOrdinal("Balance30")),
                    Claims60: r.GetInt32(r.GetOrdinal("Claims60")),
                    Balance60: r.GetDecimal(r.GetOrdinal("Balance60")),
                    Claims90: r.GetInt32(r.GetOrdinal("Claims90")),
                    Balance90: r.GetDecimal(r.GetOrdinal("Balance90")),
                    Claims120: r.GetInt32(r.GetOrdinal("Claims120")),
                    Balance120: r.GetDecimal(r.GetOrdinal("Balance120")),
                    ClaimsTotal: r.GetInt32(r.GetOrdinal("ClaimsTotal")),
                    BalanceTotal: r.GetDecimal(r.GetOrdinal("BalanceTotal"))));
            }
        }

        _logger.LogInformation(
            "CollectionSummary InsuranceAging: rows={Count}, elapsed={Ms}ms", rows.Count, sw.ElapsedMilliseconds);

        return new InsuranceAgingResult(rows);
    }

    public async Task<PanelPaymentResult> GetPanelPaymentAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        // ?? Build WHERE clauses ?????????????????????????????????
        var whereClauses = new List<string>
        {
            "ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0",
            "PanelName IS NOT NULL",
            "LTRIM(RTRIM(PanelName)) <> ''"
        };
        var parameters = new List<SqlParameter>();

        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PayerName_Raw))", "@ppn", filterPayerNames);
        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PanelName))", "@ppl", filterPanelNames);
        AddAllDateFilters(whereClauses, parameters, "pp", filterFirstBillFrom, filterFirstBillTo, filterDosFrom, filterDosTo, filterCheckDateFrom, filterCheckDateTo);

        var whereStr = string.Join(" AND ", whereClauses);

        // ?? Panel vs Payment query ??????????????????????????????
        // COUNT(DISTINCT ClaimID) per PanelName, SUM(InsurancePayment), sorted by total desc.
        var dataSql = $"""
            SELECT
                LTRIM(RTRIM(PanelName))                                                AS PanelName,
                COUNT(DISTINCT ClaimID)                                                 AS NoOfClaims,
                ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)            AS InsurancePayments
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY LTRIM(RTRIM(PanelName))
            ORDER BY ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) DESC
            """;

        var rows = new List<PanelPaymentRow>();

        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        await using (var cmd = new SqlCommand(dataSql, conn) { CommandTimeout = 120 })
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            await using var r = await cmd.ExecuteReaderAsync(ct);

            while (await r.ReadAsync(ct))
            {
                rows.Add(new PanelPaymentRow(
                    PanelName: r.GetString(r.GetOrdinal("PanelName")),
                    NoOfClaims: r.GetInt32(r.GetOrdinal("NoOfClaims")),
                    InsurancePayments: r.GetDecimal(r.GetOrdinal("InsurancePayments"))));
            }
        }

        _logger.LogInformation(
            "CollectionSummary PanelPayment: rows={Count}, elapsed={Ms}ms", rows.Count, sw.ElapsedMilliseconds);

        return new PanelPaymentResult(rows);
    }

    public async Task<RepPaymentResult> GetRepPaymentAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        // ?? Build WHERE clauses ?????????????????????????????????
        var whereClauses = new List<string>
        {
            "ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0",
            "TRY_CAST(CheckDate AS DATE) IS NOT NULL",
            "SalesRepName IS NOT NULL",
            "LTRIM(RTRIM(SalesRepName)) <> ''"
        };
        var parameters = new List<SqlParameter>();

        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PayerName_Raw))", "@rpn", filterPayerNames);
        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PanelName))", "@rpl", filterPanelNames);
        AddAllDateFilters(whereClauses, parameters, "r", filterFirstBillFrom, filterFirstBillTo, filterDosFrom, filterDosTo, filterCheckDateFrom, filterCheckDateTo);

        var whereStr = string.Join(" AND ", whereClauses);

        // ?? Rep vs Payments query ???????????????????????????????
        // Flat result: SalesRepName ï¿½ Year ï¿½ Month with counts and sums.
        var dataSql = $"""
            SELECT
                LTRIM(RTRIM(SalesRepName))                                             AS SalesRepName,
                YEAR(TRY_CAST(CheckDate AS DATE))                                      AS CheckYear,
                MONTH(TRY_CAST(CheckDate AS DATE))                                     AS CheckMonth,
                COUNT(DISTINCT ClaimID)                                                 AS NoOfClaims,
                ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)            AS InsurancePayments
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY LTRIM(RTRIM(SalesRepName)),
                     YEAR(TRY_CAST(CheckDate AS DATE)),
                     MONTH(TRY_CAST(CheckDate AS DATE))
            ORDER BY LTRIM(RTRIM(SalesRepName)),
                     YEAR(TRY_CAST(CheckDate AS DATE)),
                     MONTH(TRY_CAST(CheckDate AS DATE))
            """;

        var rows = new List<RepPaymentFlatRow>();

        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        await using (var cmd = new SqlCommand(dataSql, conn) { CommandTimeout = 120 })
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            await using var r = await cmd.ExecuteReaderAsync(ct);

            while (await r.ReadAsync(ct))
            {
                rows.Add(new RepPaymentFlatRow(
                    SalesRepName: r.GetString(r.GetOrdinal("SalesRepName")),
                    Year: r.GetInt32(r.GetOrdinal("CheckYear")),
                    Month: r.GetInt32(r.GetOrdinal("CheckMonth")),
                    NoOfClaims: r.GetInt32(r.GetOrdinal("NoOfClaims")),
                    InsurancePayments: r.GetDecimal(r.GetOrdinal("InsurancePayments"))));
            }
        }

        _logger.LogInformation(
            "CollectionSummary RepPayment: flatRows={Count}, elapsed={Ms}ms", rows.Count, sw.ElapsedMilliseconds);

        return new RepPaymentResult(rows);
    }

    public async Task<InsurancePaymentPctResult> GetInsurancePaymentPctAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        // ?? Build WHERE clauses ?????????????????????????????????
        // Base filter: InsurancePayment > 0, valid PayerName.
        var whereClauses = new List<string>
        {
            "ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0",
            "PayerName IS NOT NULL",
            "LTRIM(RTRIM(PayerName)) <> ''"
        };
        var parameters = new List<SqlParameter>();

        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PayerName_Raw))", "@ipn", filterPayerNames);
        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PanelName))", "@ipl", filterPanelNames);
        AddAllDateFilters(whereClauses, parameters, "i", filterFirstBillFrom, filterFirstBillTo, filterDosFrom, filterDosTo, filterCheckDateFrom, filterCheckDateTo);

        var whereStr = string.Join(" AND ", whereClauses);

        // ?? Insurance vs Payment % query ????????????????????????
        // Total claims and payments from all rows (InsurancePayment > 0).
        // Payment % numerator/denominator from Fully Paid + Partially Paid only
        // (conditional aggregation avoids a second pass).
        var dataSql = $"""
            SELECT
                LTRIM(RTRIM(PayerName))                                                AS PayerName,
                COUNT(DISTINCT ClaimID)                                                 AS TotalClaims,
                ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)            AS InsurancePayments,
                ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                                THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0)
                                                                                        AS PaidInsPayment,
                ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                                THEN TRY_CAST(ChargeAmount AS DECIMAL(18,2)) ELSE 0 END), 0)
                                                                                        AS PaidChargeAmt
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY LTRIM(RTRIM(PayerName))
            ORDER BY ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) DESC
            """;

        var rows = new List<InsurancePaymentPctRow>();

        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        await using (var cmd = new SqlCommand(dataSql, conn) { CommandTimeout = 120 })
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            await using var r = await cmd.ExecuteReaderAsync(ct);

            while (await r.ReadAsync(ct))
            {
                rows.Add(new InsurancePaymentPctRow(
                    PayerName: r.GetString(r.GetOrdinal("PayerName")),
                    TotalClaims: r.GetInt32(r.GetOrdinal("TotalClaims")),
                    InsurancePayments: r.GetDecimal(r.GetOrdinal("InsurancePayments")),
                    PaidInsurancePayment: r.GetDecimal(r.GetOrdinal("PaidInsPayment")),
                    PaidChargeAmount: r.GetDecimal(r.GetOrdinal("PaidChargeAmt"))));
            }
        }

        _logger.LogInformation(
            "CollectionSummary InsurancePaymentPct: rows={Count}, elapsed={Ms}ms", rows.Count, sw.ElapsedMilliseconds);

        return new InsurancePaymentPctResult(rows);
    }

    public async Task<CptPaymentPctResult> GetCptPaymentPctAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        // ?? Build WHERE clauses ?????????????????????????????????
        // Source: LineLevelData, all rows (no InsurancePayment > 0 base filter).
        var whereClauses = new List<string>
        {
            "CPTCode IS NOT NULL",
            "LTRIM(RTRIM(CPTCode)) <> ''"
        };
        var parameters = new List<SqlParameter>();

        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PayerName_Raw))", "@cpn", filterPayerNames);
        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PanelName))", "@cpl", filterPanelNames);
        AddAllDateFilters(whereClauses, parameters, "c", filterFirstBillFrom, filterFirstBillTo, filterDosFrom, filterDosTo, filterCheckDateFrom, filterCheckDateTo);

        var whereStr = string.Join(" AND ", whereClauses);

        // ?? CPT vs Payment % query ??????????????????????????????
        // SUM(Units) for all rows; Payment % from Fully Paid + Partially Paid only.
        // Sorted by SUM(Units) descending (Grand Total).
        var dataSql = $"""
            SELECT
                LTRIM(RTRIM(CPTCode))                                                  AS CptCode,
                ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0)                       AS SumUnits,
                ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                                THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0)
                                                                                        AS PaidInsPayment,
                ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                                THEN TRY_CAST(ChargeAmount AS DECIMAL(18,2)) ELSE 0 END), 0)
                                                                                        AS PaidChargeAmt
            FROM dbo.LineLevelData
            WHERE {whereStr}
            GROUP BY LTRIM(RTRIM(CPTCode))
            ORDER BY ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0) DESC
            """;

        var rows = new List<CptPaymentPctRow>();

        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        await using (var cmd = new SqlCommand(dataSql, conn) { CommandTimeout = 120 })
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            await using var r = await cmd.ExecuteReaderAsync(ct);

            while (await r.ReadAsync(ct))
            {
                rows.Add(new CptPaymentPctRow(
                    CptCode: r.GetString(r.GetOrdinal("CptCode")),
                    SumServiceUnits: r.GetDecimal(r.GetOrdinal("SumUnits")),
                    PaidInsurancePayment: r.GetDecimal(r.GetOrdinal("PaidInsPayment")),
                    PaidChargeAmount: r.GetDecimal(r.GetOrdinal("PaidChargeAmt"))));
            }
        }

        _logger.LogInformation(
            "CollectionSummary CptPaymentPct: rows={Count}, elapsed={Ms}ms", rows.Count, sw.ElapsedMilliseconds);

        return new CptPaymentPctResult(rows);
    }

    // ?? Panel Averages ????????????????????????????????????????????

    /// <summary>Adjudicated claim statuses used by Panel Averages tab.</summary>
    private static readonly string[] AdjudicatedStatuses =
    [
        "Fully Paid", "Partially Paid", "Complete W/O", "Fully Adjusted",
        "Fully Denied", "Denied", "Partially Denied", "Partially Adjusted",
        "Patient Responsibility"
    ];

    public async Task<PanelAveragesResult> GetPanelAveragesAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var cutoffDate = DateTime.Today.AddMonths(-6);

        var adjStatusList = string.Join(", ", AdjudicatedStatuses.Select((_, i) => $"@adjSt_{i}"));

        var whereClauses = new List<string>
        {
            "PanelName IS NOT NULL",
            "LTRIM(RTRIM(PanelName)) <> ''",
            "TRY_CAST(DateOfService AS DATE) IS NOT NULL",
            $"TRY_CAST(DateOfService AS DATE) >= '{cutoffDate:yyyy-MM-dd}'"
        };
        var parameters = new List<SqlParameter>();

        for (var i = 0; i < AdjudicatedStatuses.Length; i++)
            parameters.Add(new SqlParameter($"@adjSt_{i}", AdjudicatedStatuses[i]));

        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PayerName))", "@papn", filterPayerNames);
        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PanelName))", "@papl", filterPanelNames);
        AddAllDateFilters(whereClauses, parameters, "pa", filterFirstBillFrom, filterFirstBillTo, filterDosFrom, filterDosTo, filterCheckDateFrom, filterCheckDateTo);

        var whereStr = string.Join(" AND ", whereClauses);

        var dataSql = $"""
            SELECT
                LTRIM(RTRIM(PanelName))  AS PanelName,
                LTRIM(RTRIM(PayerName))  AS PayerName,
                COUNT(DISTINCT ClaimID)  AS ClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)       AS TotalCharges,
                ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)   AS CarrierPayment,

                COUNT(DISTINCT CASE WHEN LTRIM(RTRIM(ClaimStatus)) = 'Fully Paid' THEN ClaimID END)
                    AS FullyPaidCount,
                ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) = 'Fully Paid'
                    THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0)
                    AS FullyPaidAmount,

                COUNT(DISTINCT CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ({adjStatusList}) THEN ClaimID END)
                    AS AdjudicatedCount,
                ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ({adjStatusList})
                    THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0)
                    AS AdjudicatedAmount,

                COUNT(DISTINCT CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ({adjStatusList})
                    AND ISNULL(TRY_CAST(DaysToDOS AS INT), 9999) <= 30 THEN ClaimID END)
                    AS Days30Count,
                ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ({adjStatusList})
                    AND ISNULL(TRY_CAST(DaysToDOS AS INT), 9999) <= 30
                    THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0)
                    AS Days30Amount,

                COUNT(DISTINCT CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ({adjStatusList})
                    AND ISNULL(TRY_CAST(DaysToDOS AS INT), 9999) <= 60 THEN ClaimID END)
                    AS Days60Count,
                ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ({adjStatusList})
                    AND ISNULL(TRY_CAST(DaysToDOS AS INT), 9999) <= 60
                    THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0)
                    AS Days60Amount
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY LTRIM(RTRIM(PanelName)), LTRIM(RTRIM(PayerName))
            ORDER BY PanelName, PayerName
            """;

        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        var rawRows = new List<PanelAveragesRawRow>();
        await using (var cmd = new SqlCommand(dataSql, conn) { CommandTimeout = 180 })
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                rawRows.Add(new PanelAveragesRawRow(
                    r.GetString(r.GetOrdinal("PanelName")),
                    r.GetString(r.GetOrdinal("PayerName")),
                    r.GetInt32(r.GetOrdinal("ClaimCount")),
                    r.GetDecimal(r.GetOrdinal("TotalCharges")),
                    r.GetDecimal(r.GetOrdinal("CarrierPayment")),
                    r.GetInt32(r.GetOrdinal("FullyPaidCount")),
                    r.GetDecimal(r.GetOrdinal("FullyPaidAmount")),
                    r.GetInt32(r.GetOrdinal("AdjudicatedCount")),
                    r.GetDecimal(r.GetOrdinal("AdjudicatedAmount")),
                    r.GetInt32(r.GetOrdinal("Days30Count")),
                    r.GetDecimal(r.GetOrdinal("Days30Amount")),
                    r.GetInt32(r.GetOrdinal("Days60Count")),
                    r.GetDecimal(r.GetOrdinal("Days60Amount"))));
            }
        }

        _logger.LogInformation(
            "CollectionSummary PanelAverages: rawRows={Count}, elapsed={Ms}ms", rawRows.Count, sw.ElapsedMilliseconds);

        return BuildPanelAveragesResult(rawRows);
    }

    private sealed record PanelAveragesRawRow(
        string PanelName, string PayerName,
        int ClaimCount, decimal TotalCharges, decimal CarrierPayment,
        int FullyPaidCount, decimal FullyPaidAmount,
        int AdjudicatedCount, decimal AdjudicatedAmount,
        int Days30Count, decimal Days30Amount,
        int Days60Count, decimal Days60Amount);

    private static PanelAveragesResult BuildPanelAveragesResult(
        List<PanelAveragesRawRow> rawRows)
    {
        if (rawRows.Count == 0)
            return new PanelAveragesResult([]);

        static PanelAveragesMetrics Aggregate(IEnumerable<PanelAveragesRawRow> rows)
        {
            int claims = 0, fp = 0, adj = 0, d30 = 0, d60 = 0;
            decimal charges = 0m, carrier = 0m, fpAmt = 0m, adjAmt = 0m, d30Amt = 0m, d60Amt = 0m;
            foreach (var r in rows)
            {
                claims += r.ClaimCount;
                charges += r.TotalCharges;
                carrier += r.CarrierPayment;
                fp += r.FullyPaidCount;
                fpAmt += r.FullyPaidAmount;
                adj += r.AdjudicatedCount;
                adjAmt += r.AdjudicatedAmount;
                d30 += r.Days30Count;
                d30Amt += r.Days30Amount;
                d60 += r.Days60Count;
                d60Amt += r.Days60Amount;
            }
            return new PanelAveragesMetrics(claims, charges, carrier, fp, fpAmt, adj, adjAmt, d30, d30Amt, d60, d60Amt);
        }

        var panelGroups = rawRows
            .GroupBy(r => r.PanelName, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var panelRows = new List<PanelAveragesRow>();
        foreach (var pg in panelGroups)
        {
            var payerRows = pg
                .OrderByDescending(r => r.ClaimCount)
                .Select(r => new PanelAveragesPayerRow
                {
                    PayerName = r.PayerName,
                    Metrics = new PanelAveragesMetrics(
                        r.ClaimCount, r.TotalCharges, r.CarrierPayment,
                        r.FullyPaidCount, r.FullyPaidAmount,
                        r.AdjudicatedCount, r.AdjudicatedAmount,
                        r.Days30Count, r.Days30Amount,
                        r.Days60Count, r.Days60Amount)
                })
                .ToList();

            panelRows.Add(new PanelAveragesRow
            {
                PanelName = pg.Key,
                Metrics = Aggregate(pg),
                Payers = payerRows
            });
        }

        panelRows.Sort((a, b) => b.Metrics.ClaimCount.CompareTo(a.Metrics.ClaimCount));

        return new PanelAveragesResult(panelRows);
    }

    // ?? Average Payments (Per Panel | Last 6 Months | Posted Date) ??????

    /// <inheritdoc />
    public async Task<PanelAveragesResult> GetAvgPaymentsAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var cutoffDate    = DateTime.Today.AddMonths(-6);
        var adjStatusList = string.Join(", ", AdjudicatedStatuses.Select((_, i) => $"@apAdjSt_{i}"));

        const string visitKey = "COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), ClaimID)";

        var whereClauses = new List<string>
        {
            "ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0",
            "PanelName IS NOT NULL",
            "LTRIM(RTRIM(PanelName)) <> ''",
            "PayerName_Raw IS NOT NULL",
            "LTRIM(RTRIM(PayerName_Raw)) <> ''",
            "TRY_CAST(CheckDate AS DATE) IS NOT NULL",
            "ClaimStatus IS NOT NULL",
            "LTRIM(RTRIM(ClaimStatus)) <> ''",
            $"TRY_CAST(CheckDate AS DATE) >= '{cutoffDate:yyyy-MM-dd}'"
        };
        var parameters = new List<SqlParameter>();

        for (var i = 0; i < AdjudicatedStatuses.Length; i++)
            parameters.Add(new SqlParameter($"@apAdjSt_{i}", AdjudicatedStatuses[i]));

        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PayerName_Raw))", "@appn", filterPayerNames);
        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PanelName))",     "@appl", filterPanelNames);
        AddDateRangeClause(whereClauses, parameters, "CheckDate", "@apcdFrom", "@apcdTo",
            filterCheckDateFrom, filterCheckDateTo);

        var whereStr = string.Join(" AND ", whereClauses);

        var dataSql = $"""
            SELECT
                LTRIM(RTRIM(PanelName))                                                AS PanelName,
                ISNULL(LTRIM(RTRIM(PayerName_Raw)), '(blank)')                          AS PayerName,
                COUNT(DISTINCT ClaimID)                                                 AS ClaimCount,
                COUNT(DISTINCT {visitKey})                                              AS VisitCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount     AS DECIMAL(18,2))), 0)            AS TotalCharges,
                ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)            AS CarrierPayment,

                COUNT(DISTINCT CASE WHEN LTRIM(RTRIM(ClaimStatus)) = 'Fully Paid'
                    THEN ClaimID END)                                                   AS FullyPaidCount,
                ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) = 'Fully Paid'
                    THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0)   AS FullyPaidAmount,

                COUNT(DISTINCT CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ({adjStatusList})
                    THEN ClaimID END)                                                   AS AdjudicatedCount,
                ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ({adjStatusList})
                    THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0)   AS AdjudicatedAmount,

                COUNT(DISTINCT CASE WHEN ISNULL(TRY_CAST(DaysToDOS AS INT), 9999) <= 30
                    THEN ClaimID END)                                                   AS Days30Count,
                ISNULL(SUM(CASE WHEN ISNULL(TRY_CAST(DaysToDOS AS INT), 9999) <= 30
                    THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0)   AS Days30Amount,

                COUNT(DISTINCT CASE WHEN ISNULL(TRY_CAST(DaysToDOS AS INT), 9999) <= 60
                    THEN ClaimID END)                                                   AS Days60Count,
                ISNULL(SUM(CASE WHEN ISNULL(TRY_CAST(DaysToDOS AS INT), 9999) <= 60
                    THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0)   AS Days60Amount
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY LTRIM(RTRIM(PanelName)), LTRIM(RTRIM(PayerName_Raw))
            ORDER BY PanelName, PayerName
            """;

        var rawRows = new List<PanelAveragesRawRow>();
        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        await using (var cmd = new SqlCommand(dataSql, conn) { CommandTimeout = 180 })
        {
            cmd.Parameters.AddRange(CloneParams(parameters));
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                rawRows.Add(new PanelAveragesRawRow(
                    PanelName:        r.GetString(r.GetOrdinal("PanelName")),
                    PayerName:        r.GetString(r.GetOrdinal("PayerName")),
                    ClaimCount:       r.GetInt32(r.GetOrdinal("ClaimCount")),
                    TotalCharges:     r.GetDecimal(r.GetOrdinal("TotalCharges")),
                    CarrierPayment:   r.GetDecimal(r.GetOrdinal("CarrierPayment")),
                    FullyPaidCount:   r.GetInt32(r.GetOrdinal("FullyPaidCount")),
                    FullyPaidAmount:  r.GetDecimal(r.GetOrdinal("FullyPaidAmount")),
                    AdjudicatedCount: r.GetInt32(r.GetOrdinal("AdjudicatedCount")),
                    AdjudicatedAmount:r.GetDecimal(r.GetOrdinal("AdjudicatedAmount")),
                    Days30Count:      r.GetInt32(r.GetOrdinal("Days30Count")),
                    Days30Amount:     r.GetDecimal(r.GetOrdinal("Days30Amount")),
                    Days60Count:      r.GetInt32(r.GetOrdinal("Days60Count")),
                    Days60Amount:     r.GetDecimal(r.GetOrdinal("Days60Amount"))));
            }
        }

        _logger.LogInformation(
            "CollectionSummary AvgPayments: rawRows={Count}, elapsed={Ms}ms", rawRows.Count, sw.ElapsedMilliseconds);

        return BuildPanelAveragesResult(rawRows);
    }

    // ?? Excel Export ??????????????????????????????????????????????

    /// <inheritdoc />
    public async Task<List<Dictionary<string, object?>>> GetClaimLevelDataExportAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var whereClauses = new List<string>();
        var parameters = new List<SqlParameter>();

        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PayerName))", "@expn", filterPayerNames);
        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PanelName))", "@expl", filterPanelNames);
        AddAllDateFilters(whereClauses, parameters, "ex", filterFirstBillFrom, filterFirstBillTo, filterDosFrom, filterDosTo, filterCheckDateFrom, filterCheckDateTo);

        var whereStr = whereClauses.Count > 0 ? "WHERE " + string.Join(" AND ", whereClauses) : "";

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
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var whereClauses = new List<string>();
        var parameters = new List<SqlParameter>();

        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PayerName))", "@lxpn", filterPayerNames);
        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PanelName))", "@lxpl", filterPanelNames);
        AddAllDateFilters(whereClauses, parameters, "lx", filterFirstBillFrom, filterFirstBillTo, filterDosFrom, filterDosTo, filterCheckDateFrom, filterCheckDateTo);

        var whereStr = whereClauses.Count > 0 ? "WHERE " + string.Join(" AND ", whereClauses) : "";

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

    /// <summary>Executes an export query and returns rows as list of column-value dictionaries.</summary>
    private async Task<List<Dictionary<string, object?>>> ExecuteExportQueryAsync(
        string connectionString, string sql, List<SqlParameter> parameters, CancellationToken ct)
    {
        var rows = new List<Dictionary<string, object?>>();

        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 300 };
        cmd.Parameters.AddRange(CloneParams(parameters));

        await using var r = await cmd.ExecuteReaderAsync(ct);
        var columns = Enumerable.Range(0, r.FieldCount).Select(i => r.GetName(i)).ToArray();

        while (await r.ReadAsync(ct))
        {
            var row = new Dictionary<string, object?>(columns.Length);
            for (int i = 0; i < columns.Length; i++)
                row[columns[i]] = r.IsDBNull(i) ? null : r.GetValue(i);
            rows.Add(row);
        }

        _logger.LogInformation("CollectionSummary export query: rows={Count}, elapsed={Ms}ms",
            rows.Count, sw.ElapsedMilliseconds);

        return rows;
    }

    // ?? Helpers ??????????????????????????????????????????????????

    private static void AddInClause(List<string> where, List<SqlParameter> parms,
        string columnExpression, string paramPrefix, List<string>? values)
    {
        if (values is not { Count: > 0 }) return;

        var paramNames = new List<string>(values.Count);
        for (var i = 0; i < values.Count; i++)
        {
            var name = $"{paramPrefix}_{i}";
            paramNames.Add(name);
            parms.Add(new SqlParameter(name, values[i]));
        }

        where.Add($"{columnExpression} IN ({string.Join(", ", paramNames)})");
    }

    private static SqlParameter[] CloneParams(List<SqlParameter> source)
    {
        var cloned = new SqlParameter[source.Count];
        for (var i = 0; i < source.Count; i++)
            cloned[i] = new SqlParameter(source[i].ParameterName, source[i].Value);
        return cloned;
    }

    private static void AddDateRangeClause(
        List<string> whereClauses,
        List<SqlParameter> parameters,
        string columnName,
        string fromParamName,
        string toParamName,
        DateOnly? from,
        DateOnly? to)
    {
        if (from.HasValue)
        {
            whereClauses.Add($"TRY_CAST({columnName} AS DATE) >= {fromParamName}");
            parameters.Add(new SqlParameter(fromParamName, System.Data.SqlDbType.Date) { Value = from.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (to.HasValue)
        {
            whereClauses.Add($"TRY_CAST({columnName} AS DATE) <= {toParamName}");
            parameters.Add(new SqlParameter(toParamName, System.Data.SqlDbType.Date) { Value = to.Value.ToDateTime(TimeOnly.MinValue) });
        }
    }

    private static void AddAllDateFilters(
        List<string> whereClauses,
        List<SqlParameter> parameters,
        string prefix,
        DateOnly? filterFirstBillFrom, DateOnly? filterFirstBillTo,
        DateOnly? filterDosFrom, DateOnly? filterDosTo,
        DateOnly? filterCheckDateFrom, DateOnly? filterCheckDateTo)
    {
        AddDateRangeClause(whereClauses, parameters, "FirstBilledDate", $"@{prefix}fbFrom", $"@{prefix}fbTo", filterFirstBillFrom, filterFirstBillTo);
        AddDateRangeClause(whereClauses, parameters, "DateOfService", $"@{prefix}dosFrom", $"@{prefix}dosTo", filterDosFrom, filterDosTo);
        AddDateRangeClause(whereClauses, parameters, "CheckDate", $"@{prefix}cdFrom", $"@{prefix}cdTo", filterCheckDateFrom, filterCheckDateTo);
    }

    // â”€â”€ Status Summary â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

    public async Task<StatusSummaryResult> GetStatusSummaryAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom = null, DateOnly? filterDosTo = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var whereList = new List<string>();
        var parms     = new List<SqlParameter>();
        AddInClause(whereList, parms, "LTRIM(RTRIM(PayerName_Raw))", "@sspn", filterPayerNames);
        AddInClause(whereList, parms, "LTRIM(RTRIM(PanelName))",     "@sspl", filterPanelNames);
        AddAllDateFilters(whereList, parms, "ss",
            filterFirstBillFrom, filterFirstBillTo,
            filterDosFrom, filterDosTo,
            filterCheckDateFrom, filterCheckDateTo);

        var whereStr = whereList.Count > 0
            ? "WHERE " + string.Join(" AND ", whereList)
            : string.Empty;

        // Single query: all 3 levels in one hit.
        // Client-side grouping/sorting avoids multiple round-trips.
        var sql = $"""
            SELECT
                ISNULL(LTRIM(RTRIM(ClaimStatus)),              '(blank)') AS ClaimStatus,
                ISNULL(LTRIM(RTRIM(PanelName)),                '(blank)') AS PanelName,
                ISNULL(LTRIM(RTRIM(CPTCodeXUnitsXModifier)),   '(blank)') AS CptCode,
                ISNULL(LTRIM(RTRIM(PayerName_Raw)),            '(blank)') AS PayerName,
                COUNT(DISTINCT ClaimID)                                    AS NoClaims,
                ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0) AS InsurancePayments,
                ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))),0) AS InsuranceBalance,
                ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))),0) AS PatientBalance
            FROM dbo.ClaimLevelData
            {whereStr}
            GROUP BY
                LTRIM(RTRIM(ClaimStatus)),
                LTRIM(RTRIM(PanelName)),
                LTRIM(RTRIM(CPTCodeXUnitsXModifier)),
                LTRIM(RTRIM(PayerName_Raw))
            """;

        // Read into flat leaf rows, then aggregate into the 4-level hierarchy.
        var flat = new List<(string Status, string Panel, string Cpt, string Payer,
                             int No, decimal Pay, decimal InsBal, decimal PtBal)>();

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 180 };
        cmd.Parameters.AddRange(CloneParams(parms));

        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            flat.Add((
                r.GetString(0), r.GetString(1), r.GetString(2), r.GetString(3),
                r.GetInt32(4),
                r.GetDecimal(5), r.GetDecimal(6), r.GetDecimal(7)));
        }

        if (flat.Count == 0)
            return StatusSummaryResult.Empty;

        // Build 4-level hierarchy: ClaimStatus → Panel → CPT → Payer
        var claimRows = flat
            .GroupBy(x => x.Status, StringComparer.OrdinalIgnoreCase)
            .Select(g =>
            {
                var panelRows = g
                    .GroupBy(x => x.Panel, StringComparer.OrdinalIgnoreCase)
                    .Select(gp =>
                    {
                        var cptRows = gp
                            .GroupBy(x => x.Cpt, StringComparer.OrdinalIgnoreCase)
                            .Select(gc =>
                            {
                                var payers = gc
                                    .GroupBy(x => x.Payer, StringComparer.OrdinalIgnoreCase)
                                    .Select(gpay => new StatusSummaryPayerRow(
                                        PayerName:         gpay.Key,
                                        NoClaims:          gpay.Sum(x => x.No),
                                        InsurancePayments: gpay.Sum(x => x.Pay),
                                        InsuranceBalance:  gpay.Sum(x => x.InsBal),
                                        PatientBalance:    gpay.Sum(x => x.PtBal)))
                                    .OrderByDescending(p => p.NoClaims)
                                    .ToList();

                                return new StatusSummaryCptRow
                                {
                                    CptCode           = gc.Key,
                                    NoClaims          = payers.Sum(p => p.NoClaims),
                                    InsurancePayments = payers.Sum(p => p.InsurancePayments),
                                    InsuranceBalance  = payers.Sum(p => p.InsuranceBalance),
                                    PatientBalance    = payers.Sum(p => p.PatientBalance),
                                    Payers            = payers,
                                };
                            })
                            .OrderByDescending(c => c.NoClaims)
                            .ToList();

                        return new StatusSummaryPanelRow
                        {
                            PanelName         = gp.Key,
                            NoClaims          = cptRows.Sum(c => c.NoClaims),
                            InsurancePayments = cptRows.Sum(c => c.InsurancePayments),
                            InsuranceBalance  = cptRows.Sum(c => c.InsuranceBalance),
                            PatientBalance    = cptRows.Sum(c => c.PatientBalance),
                            CptRows           = cptRows,
                        };
                    })
                    .OrderByDescending(p => p.NoClaims)
                    .ToList();

                return new StatusSummaryClaimRow
                {
                    ClaimStatus       = g.Key,
                    NoClaims          = panelRows.Sum(p => p.NoClaims),
                    InsurancePayments = panelRows.Sum(p => p.InsurancePayments),
                    InsuranceBalance  = panelRows.Sum(p => p.InsuranceBalance),
                    PatientBalance    = panelRows.Sum(p => p.PatientBalance),
                    PanelRows         = panelRows,
                };
            })
            .OrderByDescending(s => s.NoClaims)
            .ToList();

        return new StatusSummaryResult
        {
            Rows                 = claimRows,
            GrandNoClaims        = claimRows.Sum(r2 => r2.NoClaims),
            GrandInsurancePayments = claimRows.Sum(r2 => r2.InsurancePayments),
            GrandInsuranceBalance  = claimRows.Sum(r2 => r2.InsuranceBalance),
            GrandPatientBalance    = claimRows.Sum(r2 => r2.PatientBalance),
        };
    }

    // ── Provider Summary ─────────────────────────────────────────────────────

    public async Task<ProviderSummaryResult> GetProviderSummaryAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterFirstBillFrom = null, DateOnly? filterFirstBillTo = null,
        DateOnly? filterDosFrom       = null, DateOnly? filterDosTo       = null,
        DateOnly? filterCheckDateFrom = null, DateOnly? filterCheckDateTo = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var whereClauses = new List<string>
        {
            "ReferringProvider IS NOT NULL",
            "LTRIM(RTRIM(ReferringProvider)) <> ''"
        };
        var parameters = new List<SqlParameter>();

        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PayerName_Raw))", "@prvpn", filterPayerNames);
        AddInClause(whereClauses, parameters, "LTRIM(RTRIM(PanelName))",     "@prvpl", filterPanelNames);
        AddAllDateFilters(whereClauses, parameters, "prv",
            filterFirstBillFrom, filterFirstBillTo,
            filterDosFrom,       filterDosTo,
            filterCheckDateFrom, filterCheckDateTo);

        var whereStr = string.Join(" AND ", whereClauses);

        var sql = $"""
            SELECT
                LTRIM(RTRIM(ReferringProvider))                                         AS ReferringProvider,
                COUNT(DISTINCT ClaimID)                                                  AS NoOfClaims,
                ISNULL(SUM(TRY_CAST(InsurancePayment   AS DECIMAL(18,2))), 0)           AS InsurancePayments,
                ISNULL(SUM(TRY_CAST(InsuranceBalance   AS DECIMAL(18,2))), 0)           AS InsuranceBalance,
                ISNULL(SUM(TRY_CAST(PatientBalance     AS DECIMAL(18,2))), 0)           AS PatientBalance
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY LTRIM(RTRIM(ReferringProvider))
            ORDER BY COUNT(DISTINCT ClaimID) DESC
            """;

        var rows = new List<ProviderSummaryRow>();
        var sw   = Stopwatch.StartNew();

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        cmd.Parameters.AddRange(CloneParams(parameters));

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        int rank = 0;
        while (await reader.ReadAsync(ct))
        {
            rank++;
            rows.Add(new ProviderSummaryRow(
                Rank:               rank,
                ReferringProvider:  reader.GetString(reader.GetOrdinal("ReferringProvider")),
                NoOfClaims:         reader.GetInt32(reader.GetOrdinal("NoOfClaims")),
                InsurancePayments:  reader.GetDecimal(reader.GetOrdinal("InsurancePayments")),
                InsuranceBalance:   reader.GetDecimal(reader.GetOrdinal("InsuranceBalance")),
                PatientBalance:     reader.GetDecimal(reader.GetOrdinal("PatientBalance"))));
        }

        _logger.LogInformation(
            "CollectionSummary ProviderSummary: rows={Count}, elapsed={Ms}ms",
            rows.Count, sw.ElapsedMilliseconds);

        return new ProviderSummaryResult
        {
            Rows                  = rows,
            GrandNoClaims         = rows.Sum(r => r.NoOfClaims),
            GrandInsurancePayments= rows.Sum(r => r.InsurancePayments),
            GrandInsuranceBalance = rows.Sum(r => r.InsuranceBalance),
            GrandPatientBalance   = rows.Sum(r => r.PatientBalance),
        };
    }
}
