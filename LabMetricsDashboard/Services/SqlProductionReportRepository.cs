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
    /// <summary>
    /// Rule1 / legacy drill-down limit: keep only the Top N <c>PayerName</c> rows per
    /// <c>PanelName</c>, ranked by <c>COUNT(DISTINCT ClaimID)</c> descending.
    /// </summary>
    private const int TopPayerDrillDownCount = 3;

    private readonly ILogger<SqlProductionReportRepository> _logger;

    public SqlProductionReportRepository(ILogger<SqlProductionReportRepository> logger)
        => _logger = logger;

    public async Task<ProductionReportResult> GetMonthlyClaimVolumeAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        string? rule = null,
        CancellationToken ct = default,
        bool panelNewStrict = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        // - Rule3 (Augustus Laboratories) is functionally identical to Rule1 today; it exists
        //   so the lab can be configured now and the row column can later be switched from
        //   PanelName to PanelNameNew when that column becomes available, without any
        //   controller / view / config changes.
        // - Rule4 (NorthWest) is currently identical to Rule3 (same filters, ChargeEnteredDate
        //   columns, PanelName fallback). Kept as a distinct rule so it can diverge from
        //   Rule3 later without touching other labs.
        // - Rule5 (Cove, Elixir) is intentionally routed through the legacy/default branch
        //   (FirstBilledDate columns, PayerName not blank + FirstBilledDate IS NOT NULL).
        //   Kept as a named rule so these labs can be explicitly tagged and so Rule5 can
        //   diverge later without affecting un-tagged labs.
        var isRule1 = string.Equals(rule, "Rule1", StringComparison.OrdinalIgnoreCase);
        var isRule2 = string.Equals(rule, "Rule2", StringComparison.OrdinalIgnoreCase);
        var isRule3 = string.Equals(rule, "Rule3", StringComparison.OrdinalIgnoreCase);
        var isRule4 = string.Equals(rule, "Rule4", StringComparison.OrdinalIgnoreCase);
        var isRule5 = string.Equals(rule, "Rule5", StringComparison.OrdinalIgnoreCase);
        _ = isRule5; // currently no behavior change vs default; flag kept for future divergence
        var useChargeEnteredDate = isRule1 || isRule2 || isRule3 || isRule4;
        var columnDateExpr = useChargeEnteredDate
            ? "TRY_CAST(ChargeEnteredDate AS DATE)"
            : "TRY_CAST(FirstBilledDate AS DATE)";

        // Rule4 = PanelType; Rule3 (Augustus) = PanelNew only — no PanelName fallback.
        // panelNewStrict=true  (ProductionSummaryReport): use bare PanelNew, PanelNew IS NOT NULL guard.
        // panelNewStrict=false (standard ProductionReport): use PanelNew; null/empty displayed as '(No PanelNew)'.
        var rule3PanelExpr  = panelNewStrict
            ? "PanelNew"
            : "ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)),''), '(No PanelNew)')";
        var panelColumnExpr = isRule4 ? "PanelType" : isRule3 ? rule3PanelExpr : "PanelName";

        // Rule4 (NorthWest) and Rule3 (Augustus) do NOT require FirstBilledDate.
        // All other rules keep the legacy guard.
        var whereClauses = (isRule4 || isRule3)
            ? new List<string>()
            : new List<string>
            {
                "TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL",
                "YEAR(TRY_CAST(FirstBilledDate AS DATE)) > 1900"
            };
        var parameters = new List<SqlParameter>();

        // Rule3 WHERE: when strict (ProductionSummaryReport), guard PanelNew IS NOT NULL
        // so filtered live results match the aggregate tables (which also require PanelNew).
        if (isRule3 && panelNewStrict)
            whereClauses.Add("NULLIF(LTRIM(RTRIM(PanelNew)), '') IS NOT NULL");

        if (isRule2)
        {
            // Rule2 (Certus Laboratories): exclude PayerName_Raw containing any of these keywords
            // (case-insensitive). Treat NULL/empty PayerName_Raw as "exclude as well" by requiring it
            // to be present. This matches the spec: "Exclude PayerName_Raw contains None, Accu Labs,
            // Client Bill, Client, Patient, Patient Pay".
            var excludeKeywords = new[] { "None", "Accu Labs", "Client Bill", "Client", "Patient", "Patient Pay" };
            var notLikeClauses = new List<string>
            {
                "PayerName_Raw IS NOT NULL",
                "LTRIM(RTRIM(PayerName_Raw)) <> ''"
            };
            for (int i = 0; i < excludeKeywords.Length; i++)
            {
                var pName = $"@exKw{i}";
                notLikeClauses.Add($"PayerName_Raw NOT LIKE {pName}");
                parameters.Add(new SqlParameter(pName, $"%{excludeKeywords[i]}%"));
            }
            whereClauses.AddRange(notLikeClauses);
        }
        else
        {
        // For Rule1 / Rule3 / Rule4 / legacy: PayerName_Raw must not be blank.
            whereClauses.Add("LTRIM(RTRIM(PayerName_Raw)) <> ''");
            whereClauses.Add("PayerName_Raw IS NOT NULL");
        }

        // Rule4 (NorthWest): exclude unbilled/zero-charge statuses and guard PanelType.
        if (isRule4)
        {
            whereClauses.Add("LTRIM(RTRIM(ClaimStatus)) NOT IN ('Unbilled in Daq','Unbilled in Daq - PR','Unbilled in Webpm','Unbilled in Webpm - PR','Billed amount 0')");
            whereClauses.Add("NULLIF(LTRIM(RTRIM(PanelType)), '') IS NOT NULL");
        }

        // Rule3 (Augustus): require ChargeEnteredDate. Rows with null/empty PanelNew
        // are kept and displayed as '(No PanelNew)' — no PanelName fallback.
        if (isRule3)
        {
            whereClauses.Add("TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL");
            whereClauses.Add("YEAR(TRY_CAST(ChargeEnteredDate AS DATE)) > 1900");
        }

        // For Rule1/Rule2/Rule3/Rule4 ensure the column-date is also valid so we don't get NULL year/month rows.
        if (useChargeEnteredDate)
        {
            whereClauses.Add("TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL");
            whereClauses.Add("YEAR(TRY_CAST(ChargeEnteredDate AS DATE)) > 1900");
        }

        if (filterPayerNames is { Count: > 0 })
        {
            var pNames = filterPayerNames.Select((n, i) => $"@fpn{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PayerName_Raw)) IN ({string.Join(",", pNames)})");
            for (int i = 0; i < filterPayerNames.Count; i++)
                parameters.Add(new SqlParameter($"@fpn{i}", filterPayerNames[i]));
        }

        if (filterPanelNames is { Count: > 0 })
        {
            var plNames = filterPanelNames.Select((n, i) => $"@fpl{i}").ToList();
            // Rule4 = PanelType; Rule3 = same expression as SELECT so filter matches visible rows; others = PanelName.
            var panelFilterCol = isRule4 ? "PanelType" : isRule3 ? rule3PanelExpr : "PanelName";
            whereClauses.Add($"LTRIM(RTRIM({panelFilterCol})) IN ({string.Join(",", plNames)})");
            for (int i = 0; i < filterPanelNames.Count; i++)
                parameters.Add(new SqlParameter($"@fpl{i}", filterPanelNames[i]));
        }

        // Apply the user-supplied date-range filter.
        // Rule3 (Augustus): month columns use ChargeEnteredDate, but the user's date input
        // filters by FirstBilledDate. All other rules keep filter and grouping on the same column.
        var filterDateExpr = isRule3
            ? "TRY_CAST(FirstBilledDate AS DATE)"
            : columnDateExpr;

        if (filterFirstBillFrom.HasValue)
        {
            whereClauses.Add($"{filterDateExpr} >= @fbFrom");
            parameters.Add(new SqlParameter("@fbFrom", SqlDbType.Date) { Value = filterFirstBillFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterFirstBillTo.HasValue)
        {
            whereClauses.Add($"{filterDateExpr} <= @fbTo");
            parameters.Add(new SqlParameter("@fbTo", SqlDbType.Date) { Value = filterFirstBillTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        // Date of Service filters (optional)
        if (filterDosFrom.HasValue)
        {
            whereClauses.Add("TRY_CAST(DateOfService AS DATE) >= @dosFrom");
            parameters.Add(new SqlParameter("@dosFrom", SqlDbType.Date) { Value = filterDosFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterDosTo.HasValue)
        {
            whereClauses.Add("TRY_CAST(DateOfService AS DATE) <= @dosTo");
            parameters.Add(new SqlParameter("@dosTo", SqlDbType.Date) { Value = filterDosTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        // Explicit FirstBilledDate range filter (always applied when provided)
        if (filterFirstBilledFrom.HasValue)
        {
            whereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) >= @firstBilledFrom");
            parameters.Add(new SqlParameter("@firstBilledFrom", SqlDbType.Date) { Value = filterFirstBilledFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterFirstBilledTo.HasValue)
        {
            whereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) <= @firstBilledTo");
            parameters.Add(new SqlParameter("@firstBilledTo", SqlDbType.Date) { Value = filterFirstBilledTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        var whereStr = string.Join(" AND ", whereClauses);

        // Query 1: filter option lists (unfiltered).
        // Rule4 = PanelType; Rule3 (Augustus) = PanelNew; others = PanelName.
        // Dropdown options: always use the real PanelNew column so '(No PanelNew)' rows are
        // not listed as a selectable filter — they are a display-only label for unassigned rows.
        var panelOptionsCol = isRule4 ? "PanelType" : isRule3 ? "PanelNew" : "PanelName";
        var optionsSql = $"""
            SELECT DISTINCT LTRIM(RTRIM(PayerName_Raw)) FROM dbo.ClaimLevelData
            WHERE PayerName_Raw IS NOT NULL AND PayerName_Raw <> '' ORDER BY 1;
            SELECT DISTINCT LTRIM(RTRIM({panelOptionsCol})) FROM dbo.ClaimLevelData
            WHERE {panelOptionsCol} IS NOT NULL AND LTRIM(RTRIM({panelOptionsCol})) <> '' ORDER BY 1;
            """;

        // Query 2: panel × month aggregation (unique claim count + sum charges).
        // Year/Month columns come from the rule-selected date source (FirstBilledDate by default,
        // ChargeEnteredDate when rule = "Rule1" / "Rule2" / "Rule3" / "Rule4").
        // Row column comes from panelColumnExpr ("PanelName" today; will be "PanelNameNew" for Rule3/Rule4 in future).
        var pivotSql = $"""
            SELECT
                LTRIM(RTRIM({panelColumnExpr}))                          AS PanelName,
                LTRIM(RTRIM(PayerName_Raw))                            AS PayerName,
                YEAR({columnDateExpr})                                  AS BillYear,
                MONTH({columnDateExpr})                                 AS BillMonth,
                COUNT(DISTINCT ClaimID)                                  AS ClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS BilledCharges
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY
                LTRIM(RTRIM({panelColumnExpr})),
                LTRIM(RTRIM(PayerName_Raw)),
                YEAR({columnDateExpr}),
                MONTH({columnDateExpr})
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

            // Rule1 / Rule2: Drill-down = Top 3 PayerName per panel by COUNT(DISTINCT ClaimID).
            // Tie-breaker on PayerName (case-insensitive ascending) keeps the result
            // deterministic when several payers share the same claim count. Empty/whitespace
            // PayerName values are excluded from the drill-down (they still contribute to
            // the panel total).
            var payerGroups = rows
                .Where(r => !string.IsNullOrWhiteSpace(r.PayerName))
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
                .ThenBy(p => p.PayerName, StringComparer.OrdinalIgnoreCase)
                .Take(TopPayerDrillDownCount)
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
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        string? rule = null,
        string? weekRange = null,
        CancellationToken ct = default,
        bool panelNewStrict = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        // Weekly Claim Volume rule semantics (per shared spec):
        //   Rule2 ? FirstBilledDate week columns; filter PayerName not blank + FirstBilledDate is date.
        //   Rule3 ? ChargeEnteredDate week columns; PayerName/ChargeEnteredDate not blank + FirstBilledDate is date.
        //   Rule4 ? Same as Rule3 (kept distinct so it can diverge later; Northwest).
        //   Rule5 ? ChargeEnteredDate week columns; exclude PayerName_Raw keywords + FirstBilledDate not blank.
        //   Rule1 / default / unset ? FirstBilledDate week columns + PayerName not blank (legacy).
        var isRule1 = string.Equals(rule, "Rule1", StringComparison.OrdinalIgnoreCase);
        var isRule2 = string.Equals(rule, "Rule2", StringComparison.OrdinalIgnoreCase);
        var isRule3 = string.Equals(rule, "Rule3", StringComparison.OrdinalIgnoreCase);
        var isRule4 = string.Equals(rule, "Rule4", StringComparison.OrdinalIgnoreCase);
        var isRule5 = string.Equals(rule, "Rule5", StringComparison.OrdinalIgnoreCase);
        _ = isRule1; // legacy default behavior; flag kept for readability
        _ = isRule2; // FirstBilledDate + PayerName not blank — same as default branch
        var useChargeEnteredDate = isRule3 || isRule4 || isRule5;
        var weekDateExpr = useChargeEnteredDate
            ? "TRY_CAST(ChargeEnteredDate AS DATE)"
            : "TRY_CAST(FirstBilledDate AS DATE)";

        // Resolve lab-specific week boundary (Mon–Sun by default).
        var weekStartDay = WeekRangeHelper.ResolveWeekStart(weekRange);

        // Determine the last 4 complete weeks based on today + chosen week-start day.
        var today = DateOnly.FromDateTime(DateTime.Today);
        var weekColumns = BuildLast4Weeks(today, weekStartDay);
        var earliest = weekColumns[0].WeekStart;
        var latest = weekColumns[^1].WeekEnd;

        var whereClauses = new List<string>
        {
            // Trim to the visible 4-week window using the rule's column date source.
            $"{weekDateExpr} >= @WeekStart",
            $"{weekDateExpr} <= @WeekEnd",
        };

        // Rule4 (NorthWest) does NOT require FirstBilledDate — it uses ClaimStatus exclusion.
        // All other rules keep the legacy FirstBilledDate guard.
        if (!isRule4)
        {
            whereClauses.Insert(0, "TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL");
        }
        var parameters = new List<SqlParameter>
        {
            new("@WeekStart", SqlDbType.Date) { Value = earliest.ToDateTime(TimeOnly.MinValue) },
            new("@WeekEnd",   SqlDbType.Date) { Value = latest.ToDateTime(TimeOnly.MinValue) },
        };

        if (isRule5)
        {
            // Rule5: exclude PayerName_Raw containing keywords (Cove / Elixir spec).
            var excludeKeywords = new[] { "None", "Accu Labs", "Client Bill", "Client", "Patient", "Patient Pay" };
            whereClauses.Add("PayerName_Raw IS NOT NULL");
            whereClauses.Add("LTRIM(RTRIM(PayerName_Raw)) <> ''");
            for (int i = 0; i < excludeKeywords.Length; i++)
            {
                var pName = $"@wExKw{i}";
                whereClauses.Add($"PayerName_Raw NOT LIKE {pName}");
                parameters.Add(new SqlParameter(pName, $"%{excludeKeywords[i]}%"));
            }
        }
        else
        {
            // Rule1 / Rule2 / Rule3 / Rule4 / default: PayerName_Raw must not be blank.
            whereClauses.Add("LTRIM(RTRIM(PayerName_Raw)) <> ''");
            whereClauses.Add("PayerName_Raw IS NOT NULL");
        }

        // Rule3 / Rule4 also require ChargeEnteredDate to be a real date.
        if (isRule3 || isRule4)
        {
            whereClauses.Add("TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL");
        }

        // Rule4 (NorthWest): exclude unbilled/zero-charge statuses + guard PanelType.
        if (isRule4)
        {
            whereClauses.Add("LTRIM(RTRIM(ClaimStatus)) NOT IN ('Unbilled in Daq','Unbilled in Daq - PR','Unbilled in Webpm','Unbilled in Webpm - PR','Billed amount 0')");
            whereClauses.Add("NULLIF(LTRIM(RTRIM(PanelType)), '') IS NOT NULL");
        }

        // Rule3 (Augustus): rows with null/empty PanelNew are kept and shown as '(No PanelNew)'.
        // No PanelName fallback — coalesce to label handled in SELECT/GROUP BY.
        if (isRule3)
        {
            // No additional WHERE guard; null PanelNew rendered as '(No PanelNew)' in the pivot.
        }

        // Rule3 panel expression: strict (ProductionSummaryReport) = bare PanelNew with IS NOT NULL guard;
        // non-strict (ProductionReport) = ISNULL(PanelNew, '(No PanelNew)') — no PanelName fallback.
        var rule3WeekPanelExpr = panelNewStrict
            ? "PanelNew"
            : "ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)),''), '(No PanelNew)')";

        // When strict: add PanelNew IS NOT NULL guard so results match the aggregate tables.
        if (isRule3 && panelNewStrict)
            whereClauses.Add("NULLIF(LTRIM(RTRIM(PanelNew)), '') IS NOT NULL");

        if (filterPayerNames is { Count: > 0 })
        {
            var pNames = filterPayerNames.Select((n, i) => $"@wfpn{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PayerName_Raw)) IN ({string.Join(",", pNames)})");
            for (int i = 0; i < filterPayerNames.Count; i++)
                parameters.Add(new SqlParameter($"@wfpn{i}", filterPayerNames[i]));
        }

        if (filterPanelNames is { Count: > 0 })
        {
            var plNames = filterPanelNames.Select((n, i) => $"@wfpl{i}").ToList();
            var weekPanelFilterCol = isRule4 ? "PanelType" : isRule3 ? rule3WeekPanelExpr : "PanelName";
            whereClauses.Add($"LTRIM(RTRIM({weekPanelFilterCol})) IN ({string.Join(",", plNames)})");
            for (int i = 0; i < filterPanelNames.Count; i++)
                parameters.Add(new SqlParameter($"@wfpl{i}", filterPanelNames[i]));
        }

        // Rule3 (Augustus): filter by FirstBilledDate; all others filter by the grouping column.
        var weekFilterDateExpr = isRule3 ? "TRY_CAST(FirstBilledDate AS DATE)" : weekDateExpr;

        // The user-supplied date range narrows the window further on the appropriate date column.
        if (filterFirstBillFrom.HasValue)
        {
            whereClauses.Add($"{weekFilterDateExpr} >= @wfbFrom");
            parameters.Add(new SqlParameter("@wfbFrom", SqlDbType.Date) { Value = filterFirstBillFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterFirstBillTo.HasValue)
        {
            whereClauses.Add($"{weekFilterDateExpr} <= @wfbTo");
            parameters.Add(new SqlParameter("@wfbTo", SqlDbType.Date) { Value = filterFirstBillTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        // Date of Service filters for weekly query
        if (filterDosFrom.HasValue)
        {
            whereClauses.Add("TRY_CAST(DateOfService AS DATE) >= @wDosFrom");
            parameters.Add(new SqlParameter("@wDosFrom", SqlDbType.Date) { Value = filterDosFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterDosTo.HasValue)
        {
            whereClauses.Add("TRY_CAST(DateOfService AS DATE) <= @wDosTo");
            parameters.Add(new SqlParameter("@wDosTo", SqlDbType.Date) { Value = filterDosTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        // Explicit FirstBilledDate range filter for weekly queries
        if (filterFirstBilledFrom.HasValue)
        {
            whereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) >= @wFirstBilledFrom");
            parameters.Add(new SqlParameter("@wFirstBilledFrom", SqlDbType.Date) { Value = filterFirstBilledFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterFirstBilledTo.HasValue)
        {
            whereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) <= @wFirstBilledTo");
            parameters.Add(new SqlParameter("@wFirstBilledTo", SqlDbType.Date) { Value = filterFirstBilledTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        var whereStr = string.Join(" AND ", whereClauses);

        // Query: panel × payer × week-date aggregation within the 4-week window.
        // Rule4 (NW) = PanelType; Rule3 (Augustus) = PanelNew only, null ? '(No PanelNew)'; others = PanelName.
        var weekPanelExpr = isRule4 ? "PanelType" : isRule3 ? rule3WeekPanelExpr : "PanelName";
        var pivotSql = $"""
            SELECT
                LTRIM(RTRIM({weekPanelExpr}))                           AS PanelName,
                LTRIM(RTRIM(PayerName_Raw))                            AS PayerName,
                {weekDateExpr}                                          AS BillDate,
                COUNT(DISTINCT ClaimID)                                  AS ClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS BilledCharges
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY
                LTRIM(RTRIM({weekPanelExpr})),
                LTRIM(RTRIM(PayerName_Raw)),
                {weekDateExpr}
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

        _logger.LogInformation(
            "Weekly Claim Volume: {RawCount} raw rows (rule={Rule}, weekStart={WeekStart})",
            rawRows.Count, rule ?? "Default", weekStartDay);

        return BuildWeeklyResult(weekColumns, rawRows);
    }

    /// <summary>
    /// Builds the last 4 complete weeks ending before today's week, using the supplied
    /// <paramref name="weekStartDay"/> as the first day of each week.
    /// </summary>
    private static List<WeekColumn> BuildLast4Weeks(DateOnly today, DayOfWeek weekStartDay)
    {
        // Days from "today" back to the most recent occurrence of weekStartDay (0..6).
        int daysSinceWeekStart = ((int)today.DayOfWeek - (int)weekStartDay + 7) % 7;
        var currentWeekStart = today.AddDays(-daysSinceWeekStart);

        var weeks = new List<WeekColumn>();
        for (int i = 4; i >= 1; i--)
        {
            var start = currentWeekStart.AddDays(-7 * i);
            var end = start.AddDays(6);
            // Key uses the week-start date so it is unambiguous across week boundaries.
            var key = $"{start:yyyy-MM-dd}";
            weeks.Add(new WeekColumn(key, start, end));
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

            // Top 3 payers per panel by COUNT(DISTINCT ClaimID), with deterministic
            // tiebreaker on PayerName. Empty PayerName entries are excluded from drill-down
            // (they still contribute to the panel total).
            var payerGroups = entries
                .Where(x => !string.IsNullOrWhiteSpace(x.Row.PayerName))
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
                .ThenBy(p => p.PayerName, StringComparer.OrdinalIgnoreCase)
                .Take(TopPayerDrillDownCount)
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
                LTRIM(RTRIM(PanelName))                                                         AS PanelName,
                ISNULL(LTRIM(RTRIM(CPTCodeXUnitsXModifier)), '')                                AS CptCode,
                COUNT(DISTINCT NULLIF(LTRIM(RTRIM(AccessionNumber)), ''))                       AS ClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)                          AS TotalCharges
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
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        string? rule = null,
        CancellationToken ct = default,
        bool panelNewStrict = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var isRule1 = string.Equals(rule, "Rule1", StringComparison.OrdinalIgnoreCase);
        var isRule2 = string.Equals(rule, "Rule2", StringComparison.OrdinalIgnoreCase);
        var isRule3 = string.Equals(rule, "Rule3", StringComparison.OrdinalIgnoreCase);
        var isRule4 = string.Equals(rule, "Rule4", StringComparison.OrdinalIgnoreCase);
        var useChargeEnteredDate = isRule1 || isRule2 || isRule3 || isRule4;
        var columnDateExpr = useChargeEnteredDate
            ? "TRY_CAST(ChargeEnteredDate AS DATE)"
            : "TRY_CAST(FirstBilledDate AS DATE)";

        var whereClauses = new List<string>
        {
            "LTRIM(RTRIM(PayerName_Raw)) <> ''",
            "PayerName_Raw IS NOT NULL",
        };
        var parameters = new List<SqlParameter>();

        if (useChargeEnteredDate)
        {
            whereClauses.Add("TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL");
            whereClauses.Add("YEAR(TRY_CAST(ChargeEnteredDate AS DATE)) > 1900");
        }
        else
        {
            whereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL");
            whereClauses.Add("YEAR(TRY_CAST(FirstBilledDate AS DATE)) > 1900");
        }

        // Rule4 (NorthWest): exclude unbilled/zero-charge statuses.
        if (isRule4)
        {
            whereClauses.Add("LTRIM(RTRIM(ClaimStatus)) NOT IN ('Unbilled in Daq','Unbilled in Daq - PR','Unbilled in Webpm','Unbilled in Webpm - PR','Billed amount 0')");
        }

        // Rule3 (Augustus): ChargeEnteredDate + FirstBilledDate already guarded above.
        // No additional ClaimStatus exclusion needed.

        if (filterPayerNames is { Count: > 0 })
        {
            var pNames = filterPayerNames.Select((n, i) => $"@pbpn{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PayerName_Raw)) IN ({string.Join(",", pNames)})");
            for (int i = 0; i < filterPayerNames.Count; i++)
                parameters.Add(new SqlParameter($"@pbpn{i}", filterPayerNames[i]));
        }

        if (filterPanelNames is { Count: > 0 })
        {
            var plNames = filterPanelNames.Select((n, i) => $"@pbpl{i}").ToList();
            var pbPanelExpr = isRule4 ? "PanelType"
                : isRule3 ? (panelNewStrict ? "PanelNew" : "ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)),''), '(No PanelNew)')")
                : "PanelName";
            whereClauses.Add($"LTRIM(RTRIM({pbPanelExpr})) IN ({string.Join(",", plNames)})");
            for (int i = 0; i < filterPanelNames.Count; i++)
                parameters.Add(new SqlParameter($"@pbpl{i}", filterPanelNames[i]));
        }

        // When strict (ProductionSummaryReport) add PanelNew guard to match aggregate table rows.
        if (isRule3 && panelNewStrict)
            whereClauses.Add("NULLIF(LTRIM(RTRIM(PanelNew)), '') IS NOT NULL");

        // Apply optional date filters.
        // Rule3 (Augustus): filter by FirstBilledDate; all others filter by the grouping column.
        var pbFilterDateExpr = isRule3 ? "TRY_CAST(FirstBilledDate AS DATE)" : columnDateExpr;

        if (filterFirstBillFrom.HasValue)
        {
            whereClauses.Add($"{pbFilterDateExpr} >= @pbFbFrom");
            parameters.Add(new SqlParameter("@pbFbFrom", SqlDbType.Date) { Value = filterFirstBillFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterFirstBillTo.HasValue)
        {
            whereClauses.Add($"{pbFilterDateExpr} <= @pbFbTo");
            parameters.Add(new SqlParameter("@pbFbTo", SqlDbType.Date) { Value = filterFirstBillTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterDosFrom.HasValue)
        {
            whereClauses.Add("TRY_CAST(DateOfService AS DATE) >= @pbDosFrom");
            parameters.Add(new SqlParameter("@pbDosFrom", SqlDbType.Date) { Value = filterDosFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterDosTo.HasValue)
        {
            whereClauses.Add("TRY_CAST(DateOfService AS DATE) <= @pbDosTo");
            parameters.Add(new SqlParameter("@pbDosTo", SqlDbType.Date) { Value = filterDosTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        var whereStr = string.Join(" AND ", whereClauses);

        var pivotSql = $"""
            SELECT
            LTRIM(RTRIM(PayerName_Raw))                AS PayerName,
                YEAR({columnDateExpr})                       AS EnteredYear,
                MONTH({columnDateExpr})                      AS EnteredMonth,
                COUNT(DISTINCT ClaimID)                      AS ClaimCount
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY
                LTRIM(RTRIM(PayerName_Raw)),
                YEAR({columnDateExpr}),
                MONTH({columnDateExpr})
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
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        string? rule = null,
        CancellationToken ct = default,
        bool panelNewStrict = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var isRule1 = string.Equals(rule, "Rule1", StringComparison.OrdinalIgnoreCase);
        var isRule2 = string.Equals(rule, "Rule2", StringComparison.OrdinalIgnoreCase);
        var isRule3 = string.Equals(rule, "Rule3", StringComparison.OrdinalIgnoreCase);
        var isRule4 = string.Equals(rule, "Rule4", StringComparison.OrdinalIgnoreCase);
        var useChargeEnteredDate = isRule1 || isRule2 || isRule3 || isRule4;
        var columnDateExpr = useChargeEnteredDate
            ? "TRY_CAST(ChargeEnteredDate AS DATE)"
            : "TRY_CAST(FirstBilledDate AS DATE)";

        var whereClauses = new List<string>
        {
            "LTRIM(RTRIM(PayerName_Raw)) <> ''",
            "PayerName_Raw IS NOT NULL",
        };
        var parameters = new List<SqlParameter>();

        if (useChargeEnteredDate)
        {
            whereClauses.Add("TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL");
            whereClauses.Add("YEAR(TRY_CAST(ChargeEnteredDate AS DATE)) > 1900");
        }
        else
        {
            whereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL");
            whereClauses.Add("YEAR(TRY_CAST(FirstBilledDate AS DATE)) > 1900");
        }

        // Rule4 (NorthWest): exclude unbilled/zero-charge statuses.
        // Matches usp_RefreshNW_PayerByPanel filter exactly.
        if (isRule4)
        {
            whereClauses.Add("LTRIM(RTRIM(ClaimStatus)) NOT IN ('Unbilled in Daq','Unbilled in Daq - PR','Unbilled in Webpm','Unbilled in Webpm - PR','Billed amount 0')");
        }

        if (filterPayerNames is { Count: > 0 })
        {
            var pNames = filterPayerNames.Select((n, i) => $"@pxpn{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PayerName_Raw)) IN ({string.Join(",", pNames)})");
            for (int i = 0; i < filterPayerNames.Count; i++)
                parameters.Add(new SqlParameter($"@pxpn{i}", filterPayerNames[i]));
        }

        if (filterPanelNames is { Count: > 0 })
        {
            var plNames = filterPanelNames.Select((n, i) => $"@pxpl{i}").ToList();
            // Rule4 (NW) = PanelType; Rule3 (Augustus) = PanelNew only, no PanelName fallback; others = PanelName.
            var pxpPanelFilterExpr = isRule4 ? "PanelType"
                : isRule3 ? (panelNewStrict ? "PanelNew" : "ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)),''), '(No PanelNew)')")
                : "PanelName";
            whereClauses.Add($"LTRIM(RTRIM({pxpPanelFilterExpr})) IN ({string.Join(",", plNames)})");
            for (int i = 0; i < filterPanelNames.Count; i++)
                parameters.Add(new SqlParameter($"@pxpl{i}", filterPanelNames[i]));
        }

        // When strict (ProductionSummaryReport) add PanelNew guard to match aggregate table rows.
        if (isRule3 && panelNewStrict)
            whereClauses.Add("NULLIF(LTRIM(RTRIM(PanelNew)), '') IS NOT NULL");

        // Apply optional date filters.
        // Rule3 (Augustus): filter by FirstBilledDate; all others filter by the grouping column.
        var ppFilterDateExpr = isRule3 ? "TRY_CAST(FirstBilledDate AS DATE)" : columnDateExpr;

        if (filterFirstBillFrom.HasValue)
        {
            whereClauses.Add($"{ppFilterDateExpr} >= @ppFbFrom");
            parameters.Add(new SqlParameter("@ppFbFrom", SqlDbType.Date) { Value = filterFirstBillFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterFirstBillTo.HasValue)
        {
            whereClauses.Add($"{ppFilterDateExpr} <= @ppFbTo");
            parameters.Add(new SqlParameter("@ppFbTo", SqlDbType.Date) { Value = filterFirstBillTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterDosFrom.HasValue)
        {
            whereClauses.Add("TRY_CAST(DateOfService AS DATE) >= @ppDosFrom");
            parameters.Add(new SqlParameter("@ppDosFrom", SqlDbType.Date) { Value = filterDosFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterDosTo.HasValue)
        {
            whereClauses.Add("TRY_CAST(DateOfService AS DATE) <= @ppDosTo");
            parameters.Add(new SqlParameter("@ppDosTo", SqlDbType.Date) { Value = filterDosTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        var whereStr = string.Join(" AND ", whereClauses);

        // Rule4 (NW) = PanelType; Rule3 (Augustus) = PanelNew only, null/empty ? '(No PanelNew)'; others = PanelName.
        var pxpPanelExpr = isRule4 ? "PanelType"
            : isRule3 ? (panelNewStrict ? "PanelNew" : "ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)),''), '(No PanelNew)')")
            : "PanelName";
        var pivotSql = $"""
            SELECT
                LTRIM(RTRIM(PayerName_Raw))                            AS PayerName,
                LTRIM(RTRIM({pxpPanelExpr}))                           AS PanelName,
                COUNT(DISTINCT ClaimID)                                  AS ClaimCount,
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS BilledCharges
            FROM dbo.ClaimLevelData
            WHERE {whereStr}
            GROUP BY
                LTRIM(RTRIM(PayerName_Raw)),
                LTRIM(RTRIM({pxpPanelExpr}))
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
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        string? rule = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var isRule1 = string.Equals(rule, "Rule1", StringComparison.OrdinalIgnoreCase);
        var isRule2 = string.Equals(rule, "Rule2", StringComparison.OrdinalIgnoreCase);
        var isRule3 = string.Equals(rule, "Rule3", StringComparison.OrdinalIgnoreCase);
        var isRule4 = string.Equals(rule, "Rule4", StringComparison.OrdinalIgnoreCase);
        var useChargeEnteredDate = isRule1 || isRule2 || isRule3 || isRule4;
        var columnDateExpr = useChargeEnteredDate
            ? "TRY_CAST(ChargeEnteredDate AS DATE)"
            : "TRY_CAST(FirstBilledDate AS DATE)";

        // Rule4 (NorthWest): filter by ClaimStatus IN unbilled list + PayerName_Raw NOT NULL.
        // All other rules: filter by FirstBilledDate IS NULL (legacy unbilled definition).
        var whereClauses = isRule4
            ? new List<string>
            {
                "LTRIM(RTRIM(ClaimStatus)) IN ('Unbilled in Daq','Unbilled in Webpm')",
                "NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL",
            }
            : new List<string>
            {
                "(FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')"
            };
        var parameters = new List<SqlParameter>();

        // Panel filter only applies to legacy (non-Rule4, non-Rule3) path where PanelName is the row.
        if (!isRule4 && !isRule3 && filterPanelNames is { Count: > 0 })
        {
            var plNames = filterPanelNames.Select((n, i) => $"@uapl{i}").ToList();
            whereClauses.Add($"LTRIM(RTRIM(PanelName)) IN ({string.Join(",", plNames)})");
            for (int i = 0; i < filterPanelNames.Count; i++)
                parameters.Add(new SqlParameter($"@uapl{i}", filterPanelNames[i]));
        }

        // Apply optional date filters against the active date column determined by the rule
        if (filterFirstBillFrom.HasValue)
        {
            whereClauses.Add($"{columnDateExpr} >= @uaFbFrom");
            parameters.Add(new SqlParameter("@uaFbFrom", SqlDbType.Date) { Value = filterFirstBillFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterFirstBillTo.HasValue)
        {
            whereClauses.Add($"{columnDateExpr} <= @uaFbTo");
            parameters.Add(new SqlParameter("@uaFbTo", SqlDbType.Date) { Value = filterFirstBillTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterDosFrom.HasValue)
        {
            whereClauses.Add("TRY_CAST(DateOfService AS DATE) >= @uaDosFrom");
            parameters.Add(new SqlParameter("@uaDosFrom", SqlDbType.Date) { Value = filterDosFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterDosTo.HasValue)
        {
            whereClauses.Add("TRY_CAST(DateOfService AS DATE) <= @uaDosTo");
            parameters.Add(new SqlParameter("@uaDosTo", SqlDbType.Date) { Value = filterDosTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        var whereStr = string.Join(" AND ", whereClauses);

        // Rule4 (NorthWest): row = PayerName_Raw, bucket = Aging column.
        // Rule3 (Augustus): row = PanelNew, bucket = Aging column.
        // Legacy: row = PanelName, bucket computed from DaystoDOS.
        string agingSql;
        if (isRule4)
        {
            agingSql = $"""
                SELECT
                    LTRIM(RTRIM(PayerName_Raw))                                 AS PanelName,
                    ISNULL(LTRIM(RTRIM(Aging)), 'Unknown')                      AS AgingBucket,
                    COUNT(DISTINCT
                        COALESCE(
                            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
                            NULLIF(LTRIM(RTRIM(ClaimID)), '')
                        ))                                                      AS ClaimCount,
                    ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)      AS BilledCharges
                FROM dbo.ClaimLevelData
                WHERE {whereStr}
                GROUP BY
                    LTRIM(RTRIM(PayerName_Raw)),
                    ISNULL(LTRIM(RTRIM(Aging)), 'Unknown')
                ORDER BY PanelName, AgingBucket
                """;
        }
        else if (isRule3)
        {
            // Augustus: row = PanelNew only — no PanelName fallback.
            // Null/empty PanelNew rows are labelled '(No PanelNew)' so they remain visible.
            agingSql = $"""
                SELECT
                    ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)),''), '(No PanelNew)')  AS PanelName,
                    ISNULL(LTRIM(RTRIM(Aging)), 'Unknown')                      AS AgingBucket,
                    COUNT(DISTINCT
                        COALESCE(
                            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
                            NULLIF(LTRIM(RTRIM(ClaimID)), '')
                        ))                                                      AS ClaimCount,
                    ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)      AS BilledCharges
                FROM dbo.ClaimLevelData
                WHERE {whereStr}
                GROUP BY
                    ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)),''), '(No PanelNew)'),
                    ISNULL(LTRIM(RTRIM(Aging)), 'Unknown')
                ORDER BY PanelName, AgingBucket
                """;
        }
        else
        {
            agingSql = $"""
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
        }

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
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default,
        string? rule = null)   // Rule3 (Augustus) ? COUNT DISTINCT CPTCode instead of SUM Units
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        var isRule3 = string.Equals(rule, "Rule3", StringComparison.OrdinalIgnoreCase);

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

        // CPT: optional DateOfService range
        if (filterDosFrom.HasValue)
        {
            whereClauses.Add("TRY_CAST(DateOfService AS DATE) >= @cptDosFrom");
            parameters.Add(new SqlParameter("@cptDosFrom", SqlDbType.Date) { Value = filterDosFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterDosTo.HasValue)
        {
            whereClauses.Add("TRY_CAST(DateOfService AS DATE) <= @cptDosTo");
            parameters.Add(new SqlParameter("@cptDosTo", SqlDbType.Date) { Value = filterDosTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        // CPT: explicit FirstBilledDate range filter
        if (filterFirstBilledFrom.HasValue)
        {
            whereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) >= @cptFirstBilledFrom");
            parameters.Add(new SqlParameter("@cptFirstBilledFrom", SqlDbType.Date) { Value = filterFirstBilledFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterFirstBilledTo.HasValue)
        {
            whereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) <= @cptFirstBilledTo");
            parameters.Add(new SqlParameter("@cptFirstBilledTo", SqlDbType.Date) { Value = filterFirstBilledTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        var whereStr = string.Join(" AND ", whereClauses);

        // Rule3 (Augustus): metric = COUNT(DISTINCT CPTCode) per month.
        // All other rules: metric = SUM(Units) per month.
        var unitsExpr = isRule3
            ? "CAST(COUNT(DISTINCT LTRIM(RTRIM(CPTCode))) AS DECIMAL(18,2))"
            : "ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))),0)";

        var sql = $"""
            SELECT
                LTRIM(RTRIM(CPTCode))                                       AS CptCode,
                YEAR(TRY_CAST(FirstBilledDate AS DATE))                     AS BilledYear,
                MONTH(TRY_CAST(FirstBilledDate AS DATE))                    AS BilledMonth,
                {unitsExpr}                                                  AS TotalUnits,
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
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        var (whereStr, parameters) = BuildExportFilters(filterPayerNames, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo, "ce");

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
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default)
    {
        var (whereStr, parameters) = BuildExportFilters(filterPayerNames, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo, "le");

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

    internal static (string WhereStr, List<SqlParameter> Parameters) BuildExportFilters(
        List<string>? filterPayerNames, List<string>? filterPanelNames,
        DateOnly? filterDosFrom, DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom, DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom, DateOnly? filterFirstBilledTo,
        string prefix)
    {
        var where = new List<string>();
        var parms = new List<SqlParameter>();

        if (filterPayerNames is { Count: > 0 })
        {
            var names = filterPayerNames.Select((n, i) => $"@{prefix}pn{i}").ToList();
            where.Add($"LTRIM(RTRIM(PayerName_Raw)) IN ({string.Join(",", names)})");
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

        // Explicit FirstBilledDate filters (different param names) for exports
        if (filterFirstBilledFrom.HasValue)
        {
            where.Add($"TRY_CAST(FirstBilledDate AS DATE) >= @{prefix}firstBilledFrom");
            parms.Add(new SqlParameter($"@{prefix}firstBilledFrom", SqlDbType.Date) { Value = filterFirstBilledFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterFirstBilledTo.HasValue)
        {
            where.Add($"TRY_CAST(FirstBilledDate AS DATE) <= @{prefix}firstBilledTo");
            parms.Add(new SqlParameter($"@{prefix}firstBilledTo", SqlDbType.Date) { Value = filterFirstBilledTo.Value.ToDateTime(TimeOnly.MinValue) });
        }

        // DateOfService filters for exports
        if (filterDosFrom.HasValue)
        {
            where.Add($"TRY_CAST(DateOfService AS DATE) >= @{prefix}dosFrom");
            parms.Add(new SqlParameter($"@{prefix}dosFrom", SqlDbType.Date) { Value = filterDosFrom.Value.ToDateTime(TimeOnly.MinValue) });
        }

        if (filterDosTo.HasValue)
        {
            where.Add($"TRY_CAST(DateOfService AS DATE) <= @{prefix}dosTo");
            parms.Add(new SqlParameter($"@{prefix}dosTo", SqlDbType.Date) { Value = filterDosTo.Value.ToDateTime(TimeOnly.MinValue) });
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
