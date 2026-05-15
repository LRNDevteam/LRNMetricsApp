using System.Data;
using ClosedXML.Excel;
using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Spreadsheet;
using LRN.ProductionReports.Models;
using Microsoft.Data.SqlClient;
using System.Data;
using System.Globalization;
using Microsoft.Extensions.Logging;

namespace LRN.ProductionReports.Services;

/// <summary>
/// Reads Monthly Claim Volume data from <c>dbo.ClaimLevelData</c>.
/// Groups by PanelName × Year/Month(FirstBilledDate), counts unique ClaimIDs,
/// and sums ChargeAmount. Includes top-3 payer drill-down per panel.
/// </summary>
public sealed class SqlProductionReportRepository : IProductionReportRepository
{
    private const int ExportSplitThreshold = 300_000;
    private const string CertusPrefix = "Cert_";
    private const string CovePrefix = "Cove_";
    private const string ElixirPrefix = "Elix_";
    private const string AugustusPrefix = "Aug_";
    private const string NorthWestPrefix = "NW_";
    private const string PcrPrefix = "PCR_";
    private const string BeechTreePrefix = "BT_";
    private const string RisingTidesPrefix = "RT_";

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
        if (TryResolveReadStoredProcedurePrefix(connectionString, rule, out var spPrefix))
            return await GetMonthlyClaimVolumeFromStoredProcedureAsync(connectionString, spPrefix, filterPayerNames, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo, ct).ConfigureAwait(false);

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
        if (TryResolveReadStoredProcedurePrefix(connectionString, rule, out var spPrefix))
            return await GetWeeklyClaimVolumeFromStoredProcedureAsync(connectionString, spPrefix, filterPayerNames, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo, ct).ConfigureAwait(false);

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

        if (TryResolveReadStoredProcedurePrefix(connectionString, rule: null, out var spPrefix))
            return await GetCodingFromStoredProcedureAsync(connectionString, spPrefix, null, filterPanelNames, null, null, null, null, null, null, ct).ConfigureAwait(false);

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

        if (TryResolveReadStoredProcedurePrefix(connectionString, rule, out var spPrefix))
            return await GetPayerBreakdownFromStoredProcedureAsync(connectionString, spPrefix, filterPayerNames, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo, ct).ConfigureAwait(false);

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

        if (TryResolveReadStoredProcedurePrefix(connectionString, rule, out var spPrefix))
            return await GetPayerPanelFromStoredProcedureAsync(connectionString, spPrefix, filterPayerNames, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo, ct).ConfigureAwait(false);

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

        if (TryResolveReadStoredProcedurePrefix(connectionString, rule, out var spPrefix))
            return await GetUnbilledAgingFromStoredProcedureAsync(connectionString, spPrefix, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo, ct).ConfigureAwait(false);

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
        if (TryResolveReadStoredProcedurePrefix(connectionString, rule, out var spPrefix))
            return await GetCptBreakdownFromStoredProcedureAsync(connectionString, spPrefix, null, null, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo, ct).ConfigureAwait(false);

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
                ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)      AS BilledCharges,
                COUNT(*)                                                     AS ClaimCount
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
                    rdr.GetDecimal(4),
                    rdr.GetInt32(5)));
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
                    byMonth[mk] = new CptBreakdownCell(em.Units + r.TotalUnits, em.BilledCharges + r.BilledCharges, em.ClaimCount + r.ClaimCount);
                else
                    byMonth[mk] = new CptBreakdownCell(r.TotalUnits, r.BilledCharges, r.ClaimCount);

                if (byYear.TryGetValue(r.BilledYear, out var ey))
                    byYear[r.BilledYear] = new CptBreakdownCell(ey.Units + r.TotalUnits, ey.BilledCharges + r.BilledCharges, ey.ClaimCount + r.ClaimCount);
                else
                    byYear[r.BilledYear] = new CptBreakdownCell(r.TotalUnits, r.BilledCharges, r.ClaimCount);
            }

            decimal totalUnits = byMonth.Values.Sum(c => c.Units);
            decimal totalCharges = byMonth.Values.Sum(c => c.BilledCharges);
            int     totalClaims  = byMonth.Values.Sum(c => c.ClaimCount);

            cptRows.Add(new CptBreakdownRow
            {
                CptCode = cpt,
                ByMonth = byMonth,
                ByYear = byYear,
                GrandTotalUnits = totalUnits,
                GrandTotalCharges = totalCharges,
                GrandTotalClaims = totalClaims,
            });
        }

        cptRows = cptRows.OrderByDescending(c => c.GrandTotalUnits).ToList();

        var grandByMonth = new Dictionary<string, CptBreakdownCell>();
        foreach (var c in cptRows)
        {
            foreach (var (mk, cell) in c.ByMonth)
            {
                if (grandByMonth.TryGetValue(mk, out var eg))
                    grandByMonth[mk] = new CptBreakdownCell(eg.Units + cell.Units, eg.BilledCharges + cell.BilledCharges, eg.ClaimCount + cell.ClaimCount);
                else
                    grandByMonth[mk] = new CptBreakdownCell(cell.Units, cell.BilledCharges, cell.ClaimCount);
            }
        }

        decimal grandUnits = cptRows.Sum(c => c.GrandTotalUnits);
        decimal grandCharges = cptRows.Sum(c => c.GrandTotalCharges);
        int     grandClaims  = cptRows.Sum(c => c.GrandTotalClaims);

        return new CptBreakdownResult(months, years, cptRows, grandByMonth, grandUnits, grandCharges, grandClaims);
    }

    private sealed record RawCptBreakdownRow(
        string CptCode,
        int BilledYear,
        int BilledMonth,
        decimal TotalUnits,
        decimal BilledCharges,
        int ClaimCount);

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
        CancellationToken ct = default,
        string? rule = null)
    {
        var (whereStr, parameters) = BuildExportFilters(filterPayerNames, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo, "ce", rule, isLineLevel: false);

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
    public Task<List<RawDataSegment>> GetClaimLevelDataExportSegmentsAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default,
        string? rule = null)
    {
        // SP-based bucket approach used for all labs:
        // usp_GetClaimLevelExportBuckets  ? splits by FirstBilledDate year/month
        // usp_GetClaimLevelExportDataByDateRange ? fetches one slice at a time
        return GetExportSegmentsViaSpAsync(
            connectionString,
            bucketSpName: "dbo.usp_GetClaimLevelExportBuckets",
            dataSpName:   "dbo.usp_GetClaimLevelExportDataByDateRange",
            filterPayerNames, filterPanelNames,
            filterDosFrom, filterDosTo,
            filterFirstBillFrom, filterFirstBillTo,
            filterFirstBilledFrom, filterFirstBilledTo,
            ct);
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
        CancellationToken ct = default,
        string? rule = null)
    {
        var (whereStr, parameters) = BuildExportFilters(filterPayerNames, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo, "le", rule, isLineLevel: true);

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

    /// <inheritdoc />
    public Task<List<RawDataSegment>> GetLineLevelDataExportSegmentsAsync(
        string connectionString,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        CancellationToken ct = default,
        string? rule = null)
    {
        // SP-based bucket approach used for all labs:
        // usp_GetLineLevelExportBuckets  ? splits by FirstBilledDate year/month
        // usp_GetLineLevelExportDataByDateRange ? fetches one slice at a time
        return GetExportSegmentsViaSpAsync(
            connectionString,
            bucketSpName: "dbo.usp_GetLineLevelExportBuckets",
            dataSpName:   "dbo.usp_GetLineLevelExportDataByDateRange",
            filterPayerNames, filterPanelNames,
            filterDosFrom, filterDosTo,
            filterFirstBillFrom, filterFirstBillTo,
            filterFirstBilledFrom, filterFirstBilledTo,
            ct);
    }

    // Internal model — used only by the SP-backed bucket export path.
    private sealed record SpExportBucket(
        string   BucketType,
        int?     YearNo,
        int?     MonthNo,
        DateTime? FromDate,
        DateTime? ToDate,
        int      RecordCount,
        string   SheetName);

    /// <summary>
    /// SP-backed export segment fetch: calls the bucket SP to get date-range slices,
    /// then calls the data SP once per slice. Used for NorthWest (Rule4) raw exports.
    /// </summary>
    private async Task<List<RawDataSegment>> GetExportSegmentsViaSpAsync(
        string connectionString,
        string bucketSpName,
        string dataSpName,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        DateOnly? filterDosFrom,
        DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom,
        DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom,
        DateOnly? filterFirstBilledTo,
        CancellationToken ct)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var payerParam  = filterPayerNames is { Count: > 0 } ? string.Join("|", filterPayerNames) : null;
        var panelParam  = filterPanelNames is { Count: > 0 } ? string.Join("|", filterPanelNames) : null;

        var sw = System.Diagnostics.Stopwatch.StartNew();
        _logger.LogInformation("[SpExport] Fetching buckets SP={Sp}", bucketSpName);

        var buckets = await GetSpExportBucketsAsync(
            connectionString, bucketSpName, ExportSplitThreshold,
            payerParam, panelParam,
            filterDosFrom, filterDosTo,
            filterFirstBillFrom, filterFirstBillTo,
            filterFirstBilledFrom, filterFirstBilledTo,
            ct).ConfigureAwait(false);

        _logger.LogInformation("[SpExport] Buckets={Count} SP={Sp}", buckets.Count, bucketSpName);

        if (buckets.Count == 0)
            return [new RawDataSegment("ClaimLevel", [], [])];

        var segments = new List<RawDataSegment>(buckets.Count);
        var usedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var bucket in buckets)
        {
            var sheetName = CreateUniqueSheetName(bucket.SheetName, usedNames);
            var from = bucket.FromDate.HasValue ? DateOnly.FromDateTime(bucket.FromDate.Value) : (DateOnly?)null;
            var to   = bucket.ToDate.HasValue   ? DateOnly.FromDateTime(bucket.ToDate.Value)   : (DateOnly?)null;

            _logger.LogInformation(
                "[SpExport] Fetching sheet={Sheet} From={From} To={To} ExpectedRows={Rows:N0}",
                sheetName, from, to, bucket.RecordCount);

            var (cols, rows) = await GetSpExportDataAsync(
                connectionString, dataSpName,
                from, to,
                payerParam, panelParam,
                filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo,
                ct).ConfigureAwait(false);

            _logger.LogInformation("[SpExport] Fetched sheet={Sheet} Rows={Rows:N0}", sheetName, rows.Count);
            segments.Add(new RawDataSegment(sheetName, cols, rows));
        }

        _logger.LogInformation(
            "[SpExport] Done SP={Sp} Segments={Segments} TotalRows={Rows:N0} ElapsedMs={Ms}",
            bucketSpName, segments.Count, segments.Sum(s => s.Rows.Count), sw.ElapsedMilliseconds);

        return segments;
    }

    /// <summary>
    /// Streams raw export data directly from a SqlDataReader into ClosedXML worksheets,
    /// one bucket at a time. Avoids the per-row Dictionary/array buffering
    /// that causes OOM on high-volume labs (NorthWest, RisingTides, etc.).
    /// <para>
    /// Pipeline per bucket: open reader ? add worksheet ? write header + stream rows
    /// directly into cells ? close reader ? force GC ? next bucket.
    /// </para>
    /// </summary>
    /// <returns>The total number of data rows written across all sheets.</returns>
    public async Task<int> WriteSpExportToWorkbookAsync(
        XLWorkbook workbook,
        string connectionString,
        string bucketSpName,
        string dataSpName,
        string baseSheetName,
        XLColor tabColor,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        int threshold = 50_000,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(workbook);
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(bucketSpName);
        ArgumentException.ThrowIfNullOrWhiteSpace(dataSpName);

        var payerParam = filterPayerNames is { Count: > 0 } ? string.Join("|", filterPayerNames) : null;
        var panelParam = filterPanelNames is { Count: > 0 } ? string.Join("|", filterPanelNames) : null;

        var totalSw = System.Diagnostics.Stopwatch.StartNew();
        _logger.LogInformation("[SpExportStream] Fetching buckets SP={Sp} Threshold={T:N0}", bucketSpName, threshold);

        var buckets = await GetSpExportBucketsAsync(
            connectionString, bucketSpName, threshold,
            payerParam, panelParam,
            filterDosFrom, filterDosTo,
            filterFirstBillFrom, filterFirstBillTo,
            filterFirstBilledFrom, filterFirstBilledTo,
            ct).ConfigureAwait(false);

        _logger.LogInformation("[SpExportStream] Buckets={Count} SP={Sp}", buckets.Count, bucketSpName);

        if (buckets.Count == 0)
        {
            var emptyWs = workbook.AddWorksheet(baseSheetName);
            emptyWs.TabColor = tabColor;
            emptyWs.Cell(1, 1).Value = "No data available.";
            emptyWs.Cell(1, 1).Style.Font.Italic = true;
            return 0;
        }

        int totalRows = 0;
        var usedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var bucket in buckets)
        {
            var sheetName = CreateUniqueSheetName(bucket.SheetName, usedNames);
            var from = bucket.FromDate.HasValue ? DateOnly.FromDateTime(bucket.FromDate.Value) : (DateOnly?)null;
            var to   = bucket.ToDate.HasValue   ? DateOnly.FromDateTime(bucket.ToDate.Value)   : (DateOnly?)null;

            _logger.LogInformation(
                "[SpExportStream] Streaming sheet={Sheet} From={From} To={To} ExpectedRows={Rows:N0}",
                sheetName, from, to, bucket.RecordCount);

            var bucketSw = System.Diagnostics.Stopwatch.StartNew();
            int written = await StreamSpDataToWorksheetAsync(
                workbook, sheetName, tabColor,
                connectionString, dataSpName,
                from, to, payerParam, panelParam,
                filterDosFrom, filterDosTo,
                filterFirstBillFrom, filterFirstBillTo,
                filterFirstBilledFrom, filterFirstBilledTo,
                ct).ConfigureAwait(false);
            bucketSw.Stop();

            _logger.LogInformation(
                "[SpExportStream] Done sheet={Sheet} Rows={Rows:N0} ElapsedMs={Ms}",
                sheetName, written, bucketSw.ElapsedMilliseconds);

            totalRows += written;

            // Encourage release of transient SqlDataReader / boxing garbage between sheets.
            GC.Collect();
            GC.WaitForPendingFinalizers();
        }

        _logger.LogInformation(
            "[SpExportStream] Complete SP={Sp} Sheets={Sheets} TotalRows={Rows:N0} ElapsedMs={Ms}",
            bucketSpName, buckets.Count, totalRows, totalSw.ElapsedMilliseconds);

        return totalRows;
    }

    /// <summary>
    /// Appends raw export sheets to an existing .xlsx file using a <b>per-bucket-file + merge</b>
    /// strategy that keeps memory absolutely flat:
    /// <list type="number">
    ///   <item>For each bucket, create an isolated single-sheet .xlsx file in a temp folder
    ///         (streamed via <see cref="OpenXmlWriter"/> directly from a SqlDataReader).</item>
    ///   <item>After all bucket files are produced, open the main .xlsx once and stream-copy
    ///         each bucket's WorksheetPart bytes into it (no XML parsing, just zip-to-zip).</item>
    ///   <item>Delete the temp folder.</item>
    /// </list>
    /// <para>
    /// Benefits over a single long-lived <c>SpreadsheetDocument</c>:
    /// no growing in-memory part graph (avoids VS debugger OOM), each bucket file is
    /// independently disposable, and the merge step is byte-level fast because the
    /// worksheets use inline strings only (self-contained, no style/shared-string deps).
    /// </para>
    /// </summary>
    /// <returns>The total number of data rows written across all sheets.</returns>
    public async Task<int> AppendSpExportSheetsToFileAsync(
        string filePath,
        string connectionString,
        string bucketSpName,
        string dataSpName,
        string baseSheetName,
        XLColor tabColor,
        List<string>? filterPayerNames = null,
        List<string>? filterPanelNames = null,
        DateOnly? filterDosFrom = null,
        DateOnly? filterDosTo = null,
        DateOnly? filterFirstBillFrom = null,
        DateOnly? filterFirstBillTo = null,
        DateOnly? filterFirstBilledFrom = null,
        DateOnly? filterFirstBilledTo = null,
        int threshold = 50_000,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(bucketSpName);
        ArgumentException.ThrowIfNullOrWhiteSpace(dataSpName);

        if (!File.Exists(filePath))
            throw new FileNotFoundException($"Workbook file not found: {filePath}", filePath);

        var payerParam = filterPayerNames is { Count: > 0 } ? string.Join("|", filterPayerNames) : null;
        var panelParam = filterPanelNames is { Count: > 0 } ? string.Join("|", filterPanelNames) : null;

        var totalSw = System.Diagnostics.Stopwatch.StartNew();
        _logger.LogInformation("[SpExportFile] Fetching buckets SP={Sp} Threshold={T:N0}", bucketSpName, threshold);

        var buckets = await GetSpExportBucketsAsync(
            connectionString, bucketSpName, threshold,
            payerParam, panelParam,
            filterDosFrom, filterDosTo,
            filterFirstBillFrom, filterFirstBillTo,
            filterFirstBilledFrom, filterFirstBilledTo,
            ct).ConfigureAwait(false);

        _logger.LogInformation("[SpExportFile] Buckets={Count} SP={Sp}", buckets.Count, bucketSpName);

        // Read existing sheet names from the main file once (so we don't collide with summary tabs).
        var usedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (var probe = SpreadsheetDocument.Open(filePath, isEditable: false))
        {
            var probeSheets = probe.WorkbookPart?.Workbook.GetFirstChild<Sheets>();
            if (probeSheets is not null)
                foreach (var s in probeSheets.Elements<Sheet>())
                    if (s.Name?.Value is { } n) usedNames.Add(n);
        }
        ForceGc();

        if (buckets.Count == 0)
        {
            var placeholderName = CreateUniqueSheetName(baseSheetName, usedNames);
            using (var doc = SpreadsheetDocument.Open(filePath, isEditable: true, new OpenSettings { AutoSave = false }))
            {
                var workbookPart = doc.WorkbookPart!;
                var sheets       = workbookPart.Workbook.GetFirstChild<Sheets>() ?? workbookPart.Workbook.AppendChild(new Sheets());
                AppendOpenXmlPlaceholderSheet(workbookPart, sheets, placeholderName, tabColor);
                workbookPart.Workbook.Save();
            }
            ForceGc();
            _logger.LogInformation("[SpExportFile] No data — placeholder sheet added: {Sheet}", placeholderName);
            return 0;
        }

        // ?? Phase 1: stream every bucket into its own isolated .xlsx file ???????
        var tempFolder = Path.Combine(
            Path.GetDirectoryName(filePath) ?? Path.GetTempPath(),
            $"_bkt_{baseSheetName}_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempFolder);

        var bucketFiles = new List<(string Path, string SheetName, int Rows)>(buckets.Count);
        int totalRows  = 0;

        try
        {
            int bucketIdx = 0;
            foreach (var bucket in buckets)
            {
                bucketIdx++;
                var sheetName = CreateUniqueSheetName(bucket.SheetName, usedNames);
                var from = bucket.FromDate.HasValue ? DateOnly.FromDateTime(bucket.FromDate.Value) : (DateOnly?)null;
                var to   = bucket.ToDate.HasValue   ? DateOnly.FromDateTime(bucket.ToDate.Value)   : (DateOnly?)null;

                var bucketFile = Path.Combine(tempFolder, $"{SanitizeForFileName(sheetName)}.xlsx");

                _logger.LogInformation(
                    "[SpExportFile] [Phase1] Bucket {Idx}/{Total} ? {File} (Sheet={Sheet} From={From} To={To} ExpectedRows={Rows:N0})",
                    bucketIdx, buckets.Count, Path.GetFileName(bucketFile), sheetName, from, to, bucket.RecordCount);

                var sw = System.Diagnostics.Stopwatch.StartNew();
                int written = await CreateSingleBucketFileAsync(
                    bucketFile, sheetName,
                    connectionString, dataSpName,
                    from, to, payerParam, panelParam,
                    filterDosFrom, filterDosTo,
                    filterFirstBillFrom, filterFirstBillTo,
                    filterFirstBilledFrom, filterFirstBilledTo,
                    bucketIdx, buckets.Count, _logger,
                    ct).ConfigureAwait(false);
                sw.Stop();

                bucketFiles.Add((bucketFile, sheetName, written));
                totalRows += written;

                _logger.LogInformation(
                    "[SpExportFile] [Phase1] Bucket {Idx}/{Total} done — {Rows:N0} rows in {Ms} ms ({Rps:N0} rows/s, file={Size:N0} bytes)",
                    bucketIdx, buckets.Count, written, sw.ElapsedMilliseconds,
                    written / Math.Max(0.001, sw.Elapsed.TotalSeconds),
                    new FileInfo(bucketFile).Length);

                ForceGc();
            }

            // ?? Phase 2: stream-copy every bucket's WorksheetPart into the main file ??
            // Open & close the main workbook PER MERGE so System.IO.Packaging releases
            // its in-memory part graph + packaging temp buffers between iterations.
            // Holding the main workbook open across many merges accumulates DOM state
            // and packaging buffers that exceed memory on high-volume labs (NorthWest).
            _logger.LogInformation("[SpExportFile] [Phase2] Merging {Count} bucket file(s) into {Main}",
                bucketFiles.Count, Path.GetFileName(filePath));

            var mergeSw = System.Diagnostics.Stopwatch.StartNew();
            int mergeIdx = 0;
            foreach (var (path, sheetName, _) in bucketFiles)
            {
                mergeIdx++;
                var oneSw = System.Diagnostics.Stopwatch.StartNew();

                using (var mainDoc = SpreadsheetDocument.Open(filePath, isEditable: true, new OpenSettings { AutoSave = false }))
                {
                    var mainWorkbookPart = mainDoc.WorkbookPart!;
                    var mainSheets       = mainWorkbookPart.Workbook.GetFirstChild<Sheets>()
                                           ?? mainWorkbookPart.Workbook.AppendChild(new Sheets());

                    CopyWorksheetPartFromFile(path, mainWorkbookPart, mainSheets, sheetName, _logger);

                    mainWorkbookPart.Workbook.Save();
                } // mainDoc disposed ? packaging buffers + DOM released

                oneSw.Stop();
                _logger.LogInformation(
                    "[SpExportFile] [Phase2] Merged {Idx}/{Total}={Sheet} in {Ms} ms",
                    mergeIdx, bucketFiles.Count, sheetName, oneSw.ElapsedMilliseconds);

                // Delete the bucket file as soon as it's merged — frees disk space
                // and keeps the temp folder small.
                try { File.Delete(path); }
                catch (Exception ex) { _logger.LogWarning(ex, "[SpExportFile] Failed to delete bucket file {File}", path); }

                ForceGc();
            }
            mergeSw.Stop();

            _logger.LogInformation(
                "[SpExportFile] [Phase2] Merge done — {Count} sheet(s) in {Ms} ms",
                bucketFiles.Count, mergeSw.ElapsedMilliseconds);
        }
        finally
        {
            // Clean up the per-bucket files; ignore errors (they're throwaway).
            try { Directory.Delete(tempFolder, recursive: true); }
            catch (Exception ex) { _logger.LogWarning(ex, "[SpExportFile] Failed to clean temp folder {Folder}", tempFolder); }
        }

        _logger.LogInformation(
            "[SpExportFile] Complete SP={Sp} Sheets={Sheets} TotalRows={Rows:N0} ElapsedMs={Ms}",
            bucketSpName, buckets.Count, totalRows, totalSw.ElapsedMilliseconds);

        return totalRows;
    }

    /// <summary>
    /// Creates a brand-new minimal single-sheet .xlsx file at <paramref name="bucketFile"/>,
    /// streaming the rows from the data SP via <see cref="OpenXmlWriter"/>.
    /// </summary>
    private static async Task<int> CreateSingleBucketFileAsync(
        string bucketFile, string sheetName,
        string connectionString, string dataSpName,
        DateOnly? fromDate, DateOnly? toDate,
        string? payerNames, string? panelNames,
        DateOnly? dosFrom,        DateOnly? dosTo,
        DateOnly? cedFrom,        DateOnly? cedTo,
        DateOnly? firstBilledFrom, DateOnly? firstBilledTo,
        int bucketIdx, int bucketTotal,
        ILogger logger,
        CancellationToken ct)
    {
        if (File.Exists(bucketFile)) File.Delete(bucketFile);

        using var doc = SpreadsheetDocument.Create(bucketFile, SpreadsheetDocumentType.Workbook, autoSave: false);
        var workbookPart = doc.AddWorkbookPart();
        workbookPart.Workbook = new Workbook();
        var sheets = workbookPart.Workbook.AppendChild(new Sheets());

        int written = await StreamBucketViaOpenXmlAsync(
            workbookPart, sheets, sheetName, /* tabColor unused */ XLColor.NoColor,
            connectionString, dataSpName,
            fromDate, toDate, payerNames, panelNames,
            dosFrom, dosTo, cedFrom, cedTo,
            firstBilledFrom, firstBilledTo,
            bucketIdx, bucketTotal, logger,
            ct).ConfigureAwait(false);

        workbookPart.Workbook.Save();
        return written;
    }

    /// <summary>
    /// Stream-copies the first WorksheetPart from <paramref name="bucketFile"/> into
    /// <paramref name="mainWorkbookPart"/> and registers it as a new sheet named <paramref name="sheetName"/>.
    /// Pure byte copy — no XML parsing.
    /// </summary>
    private static void CopyWorksheetPartFromFile(
        string bucketFile,
        WorkbookPart mainWorkbookPart,
        Sheets mainSheets,
        string sheetName,
        ILogger logger)
    {
        using var sourceDoc = SpreadsheetDocument.Open(bucketFile, isEditable: false);
        var sourceWsPart = sourceDoc.WorkbookPart?.WorksheetParts.FirstOrDefault()
            ?? throw new InvalidOperationException($"Bucket file {bucketFile} contains no worksheet part.");

        var targetWsPart = mainWorkbookPart.AddNewPart<WorksheetPart>();

        using (var srcStream = sourceWsPart.GetStream(FileMode.Open, FileAccess.Read))
        using (var dstStream = targetWsPart.GetStream(FileMode.Create, FileAccess.Write))
        {
            srcStream.CopyTo(dstStream);
        }

        var relId   = mainWorkbookPart.GetIdOfPart(targetWsPart);
        var sheetId = (uint)(mainSheets.Elements<Sheet>().Count() + 1);
        mainSheets.Append(new Sheet { Id = relId, SheetId = sheetId, Name = sheetName });

        logger.LogInformation("[SpExportFile] [Phase2] Copied {File} ? main sheet '{Sheet}'",
            Path.GetFileName(bucketFile), sheetName);
    }

    private static string SanitizeForFileName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        return string.Concat(name.Select(c => invalid.Contains(c) ? '_' : c));
    }

    /// <summary>
    /// Streams one bucket's rows directly from a SqlDataReader into a new WorksheetPart
    /// using <see cref="OpenXmlWriter"/>. Memory stays flat (one row at a time);
    /// disk I/O is sequential append; no parsing of the existing workbook.
    /// </summary>
    private static async Task<int> StreamBucketViaOpenXmlAsync(
        WorkbookPart workbookPart,
        Sheets sheets,
        string sheetName,
        XLColor tabColor,
        string connectionString,
        string dataSpName,
        DateOnly? fromDate, DateOnly? toDate,
        string? payerNames, string? panelNames,
        DateOnly? dosFrom,        DateOnly? dosTo,
        DateOnly? cedFrom,        DateOnly? cedTo,
        DateOnly? firstBilledFrom, DateOnly? firstBilledTo,
        int bucketIdx, int bucketTotal,
        ILogger logger,
        CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await using var cmd  = new SqlCommand(dataSpName, conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 1200
        };

        cmd.Parameters.Add(new SqlParameter("@FromDate",        SqlDbType.Date) { Value = fromDate.HasValue        ? fromDate.Value.ToDateTime(TimeOnly.MinValue)        : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@ToDate",          SqlDbType.Date) { Value = toDate.HasValue          ? toDate.Value.ToDateTime(TimeOnly.MinValue)          : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@PayerNames",      SqlDbType.NVarChar, -1) { Value = (object?)payerNames ?? DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@PanelNames",      SqlDbType.NVarChar, -1) { Value = (object?)panelNames ?? DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@DosFrom",         SqlDbType.Date) { Value = dosFrom.HasValue         ? dosFrom.Value.ToDateTime(TimeOnly.MinValue)         : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@DosTo",           SqlDbType.Date) { Value = dosTo.HasValue           ? dosTo.Value.ToDateTime(TimeOnly.MinValue)           : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@CEDFrom",         SqlDbType.Date) { Value = cedFrom.HasValue         ? cedFrom.Value.ToDateTime(TimeOnly.MinValue)         : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@CEDTo",           SqlDbType.Date) { Value = cedTo.HasValue           ? cedTo.Value.ToDateTime(TimeOnly.MinValue)           : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@FirstBilledFrom", SqlDbType.Date) { Value = firstBilledFrom.HasValue ? firstBilledFrom.Value.ToDateTime(TimeOnly.MinValue) : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@FirstBilledTo",   SqlDbType.Date) { Value = firstBilledTo.HasValue   ? firstBilledTo.Value.ToDateTime(TimeOnly.MinValue)   : DBNull.Value });

        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var rdr = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct).ConfigureAwait(false);

        int colCount = rdr.FieldCount;
        var headers  = new string[colCount];
        for (int i = 0; i < colCount; i++) headers[i] = rdr.GetName(i);

        // Cache column names ? cell-reference prefixes so we don't recompute per cell.
        var colRefs = new string[colCount];
        for (int i = 0; i < colCount; i++) colRefs[i] = ColumnLetter(i + 1);

        var worksheetPart = workbookPart.AddNewPart<WorksheetPart>();
        var relId         = workbookPart.GetIdOfPart(worksheetPart);

        int rowCount = 0;
        var progressSw = System.Diagnostics.Stopwatch.StartNew();
        const int progressEvery = 25_000;

        using (var writer = OpenXmlWriter.Create(worksheetPart))
        {
            writer.WriteStartElement(new Worksheet());
            writer.WriteStartElement(new SheetData());

            // Header row
            writer.WriteStartElement(new Row { RowIndex = 1U });
            for (int c = 0; c < colCount; c++)
                WriteInlineStringCell(writer, $"{colRefs[c]}1", headers[c]);
            writer.WriteEndElement(); // </row>

            // Data rows
            uint rowIdx = 2;
            while (await rdr.ReadAsync(ct).ConfigureAwait(false))
            {
                writer.WriteStartElement(new Row { RowIndex = rowIdx });
                for (int c = 0; c < colCount; c++)
                {
                    if (rdr.IsDBNull(c)) continue;
                    var val = rdr.GetValue(c);
                    WriteValueCell(writer, $"{colRefs[c]}{rowIdx}", val);
                }
                writer.WriteEndElement(); // </row>
                rowIdx++;
                rowCount++;

                if (rowCount % progressEvery == 0)
                {
                    logger.LogInformation(
                        "[SpExportFile]   Progress sheet {Idx}/{Total}={Sheet}: {Rows:N0} rows written ({Rps:N0} rows/s)",
                        bucketIdx, bucketTotal, sheetName, rowCount,
                        rowCount / Math.Max(0.001, progressSw.Elapsed.TotalSeconds));
                }
            }

            writer.WriteEndElement(); // </sheetData>
            writer.WriteEndElement(); // </worksheet>
        }

        // Register the sheet in workbook.xml
        var sheetId = (uint)(sheets.Elements<Sheet>().Count() + 1);
        sheets.Append(new Sheet
        {
            Id      = relId,
            SheetId = sheetId,
            Name    = sheetName
        });

        // Apply tab color (small, written to the worksheet part as a SheetProperties patch).
        // Skipped to keep streaming pure; can be added later via a post-write pass if needed.
        _ = tabColor;

        return rowCount;
    }

    private static void AppendOpenXmlPlaceholderSheet(
        WorkbookPart workbookPart, Sheets sheets, string sheetName, XLColor tabColor)
    {
        var worksheetPart = workbookPart.AddNewPart<WorksheetPart>();
        var relId         = workbookPart.GetIdOfPart(worksheetPart);

        using (var writer = OpenXmlWriter.Create(worksheetPart))
        {
            writer.WriteStartElement(new Worksheet());
            writer.WriteStartElement(new SheetData());
            writer.WriteStartElement(new Row { RowIndex = 1U });
            WriteInlineStringCell(writer, "A1", "No data available.");
            writer.WriteEndElement();
            writer.WriteEndElement();
            writer.WriteEndElement();
        }

        var sheetId = (uint)(sheets.Elements<Sheet>().Count() + 1);
        sheets.Append(new Sheet { Id = relId, SheetId = sheetId, Name = sheetName });
        _ = tabColor;
    }

    private static void WriteInlineStringCell(OpenXmlWriter writer, string cellRef, string value)
    {
        writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.InlineString });
        writer.WriteStartElement(new InlineString());
        writer.WriteElement(new Text(SanitizeXmlString(value)));
        writer.WriteEndElement();
        writer.WriteEndElement();
    }

    /// <summary>
    /// Strips characters that are illegal in XML 1.0 from a string before it is written
    /// into the .xlsx package. Database columns occasionally contain control bytes
    /// (e.g. 0x1D, 0x1E) copied from source files; these would otherwise throw
    /// <c>InvalidOperationException: hexadecimal value 0xNN, is an invalid character</c>.
    /// XML 1.0 allows: 0x09, 0x0A, 0x0D, and 0x20-0xD7FF, 0xE000-0xFFFD, 0x10000-0x10FFFF.
    /// </summary>
    private static string SanitizeXmlString(string? value)
    {
        if (string.IsNullOrEmpty(value)) return string.Empty;

        // Fast path: scan; only allocate a buffer when an illegal char is found.
        int i = 0;
        for (; i < value.Length; i++)
        {
            if (!IsLegalXmlChar(value[i])) break;
        }
        if (i == value.Length) return value;

        var sb = new System.Text.StringBuilder(value.Length);
        if (i > 0) sb.Append(value, 0, i);
        for (; i < value.Length; i++)
        {
            char c = value[i];
            if (IsLegalXmlChar(c)) sb.Append(c);
            // illegal characters are silently dropped
        }
        return sb.ToString();
    }

    private static bool IsLegalXmlChar(char c) =>
        c == 0x09 || c == 0x0A || c == 0x0D ||
        (c >= 0x20  && c <= 0xD7FF) ||
        (c >= 0xE000 && c <= 0xFFFD);

    private static void WriteValueCell(OpenXmlWriter writer, string cellRef, object val)
    {
        switch (val)
        {
            case string s:
                WriteInlineStringCell(writer, cellRef, s);
                break;
            case decimal d:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(d.ToString(CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case double dbl:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(dbl.ToString("R", CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case float f:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(f.ToString("R", CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case int i:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(i.ToString(CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case long l:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(l.ToString(CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case short sh:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(sh.ToString(CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case byte by:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Number });
                writer.WriteElement(new CellValue(by.ToString(CultureInfo.InvariantCulture)));
                writer.WriteEndElement();
                break;
            case bool b:
                writer.WriteStartElement(new Cell { CellReference = cellRef, DataType = CellValues.Boolean });
                writer.WriteElement(new CellValue(b ? "1" : "0"));
                writer.WriteEndElement();
                break;
            case DateTime dt:
                // ISO-8601 inline string keeps it readable in Excel without a styles entry.
                WriteInlineStringCell(writer, cellRef, dt.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture));
                break;
            case DateTimeOffset dto:
                WriteInlineStringCell(writer, cellRef, dto.ToString("yyyy-MM-dd HH:mm:sszzz", CultureInfo.InvariantCulture));
                break;
            case Guid g:
                WriteInlineStringCell(writer, cellRef, g.ToString());
                break;
            default:
                WriteInlineStringCell(writer, cellRef, val.ToString() ?? string.Empty);
                break;
        }
    }

    /// <summary>Converts a 1-based column index to its A1-style letter (1?A, 27?AA, …).</summary>
    private static string ColumnLetter(int col)
    {
        Span<char> buf = stackalloc char[8];
        int pos = buf.Length;
        int n = col;
        while (n > 0)
        {
            n--;
            buf[--pos] = (char)('A' + (n % 26));
            n /= 26;
        }
        return new string(buf[pos..]);
    }

    private static void ForceGc()
    {
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
    }

    /// <summary>
    /// Opens the data SP for one bucket and streams every row directly into a freshly created worksheet.
    /// One row of memory at a time — no intermediate List buffer.
    /// </summary>
    private static async Task<int> StreamSpDataToWorksheetAsync(
        XLWorkbook workbook,
        string sheetName,
        XLColor tabColor,
        string connectionString,
        string dataSpName,
        DateOnly? fromDate, DateOnly? toDate,
        string? payerNames, string? panelNames,
        DateOnly? dosFrom,        DateOnly? dosTo,
        DateOnly? cedFrom,        DateOnly? cedTo,
        DateOnly? firstBilledFrom, DateOnly? firstBilledTo,
        CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await using var cmd  = new SqlCommand(dataSpName, conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 600
        };

        cmd.Parameters.Add(new SqlParameter("@FromDate",        SqlDbType.Date) { Value = fromDate.HasValue        ? fromDate.Value.ToDateTime(TimeOnly.MinValue)        : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@ToDate",          SqlDbType.Date) { Value = toDate.HasValue          ? toDate.Value.ToDateTime(TimeOnly.MinValue)          : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@PayerNames",      SqlDbType.NVarChar, -1) { Value = (object?)payerNames ?? DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@PanelNames",      SqlDbType.NVarChar, -1) { Value = (object?)panelNames ?? DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@DosFrom",         SqlDbType.Date) { Value = dosFrom.HasValue         ? dosFrom.Value.ToDateTime(TimeOnly.MinValue)         : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@DosTo",           SqlDbType.Date) { Value = dosTo.HasValue           ? dosTo.Value.ToDateTime(TimeOnly.MinValue)           : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@CEDFrom",         SqlDbType.Date) { Value = cedFrom.HasValue         ? cedFrom.Value.ToDateTime(TimeOnly.MinValue)         : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@CEDTo",           SqlDbType.Date) { Value = cedTo.HasValue           ? cedTo.Value.ToDateTime(TimeOnly.MinValue)           : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@FirstBilledFrom", SqlDbType.Date) { Value = firstBilledFrom.HasValue ? firstBilledFrom.Value.ToDateTime(TimeOnly.MinValue) : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@FirstBilledTo",   SqlDbType.Date) { Value = firstBilledTo.HasValue   ? firstBilledTo.Value.ToDateTime(TimeOnly.MinValue)   : DBNull.Value });

        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var rdr = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct).ConfigureAwait(false);

        var ws = workbook.AddWorksheet(sheetName);
        ws.TabColor = tabColor;

        int colCount = rdr.FieldCount;

        // Header row
        for (int c = 0; c < colCount; c++)
        {
            var cell = ws.Cell(1, c + 1);
            cell.Value = rdr.GetName(c);
            cell.Style.Font.Bold = true;
        }
        ws.SheetView.FreezeRows(1);

        // Stream data rows — one row at a time, no buffering
        int row = 2;
        while (await rdr.ReadAsync(ct).ConfigureAwait(false))
        {
            for (int c = 0; c < colCount; c++)
            {
                if (rdr.IsDBNull(c)) continue;
                SetCellValueFast(ws.Cell(row, c + 1), rdr.GetValue(c));
            }
            row++;
        }

        return row - 2;
    }

    private static void SetCellValueFast(IXLCell cell, object val)
    {
        switch (val)
        {
            case decimal d:  cell.Value = d;   break;
            case double dbl: cell.Value = dbl; break;
            case int i:      cell.Value = i;   break;
            case long l:     cell.Value = l;   break;
            case bool b:     cell.Value = b;   break;
            case DateTime dt:
                cell.Value = dt;
                cell.Style.NumberFormat.Format = "yyyy-MM-dd";
                break;
            default:
                cell.Value = val.ToString();
                break;
        }
    }

    private static async Task<List<SpExportBucket>> GetSpExportBucketsAsync(
        string connectionString,
        string spName,
        int threshold,
        string? payerNames,
        string? panelNames,
        DateOnly? dosFrom,    DateOnly? dosTo,
        DateOnly? cedFrom,    DateOnly? cedTo,
        DateOnly? firstBilledFrom, DateOnly? firstBilledTo,
        CancellationToken ct)
    {
        var result = new List<SpExportBucket>();

        await using var conn = new SqlConnection(connectionString);
        await using var cmd  = new SqlCommand(spName, conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 300
        };

        cmd.Parameters.Add(new SqlParameter("@Threshold",       SqlDbType.Int)  { Value = threshold });
        cmd.Parameters.Add(new SqlParameter("@PayerNames",      SqlDbType.NVarChar, -1) { Value = (object?)payerNames      ?? DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@PanelNames",      SqlDbType.NVarChar, -1) { Value = (object?)panelNames      ?? DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@DosFrom",         SqlDbType.Date) { Value = dosFrom.HasValue        ? dosFrom.Value.ToDateTime(TimeOnly.MinValue)        : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@DosTo",           SqlDbType.Date) { Value = dosTo.HasValue          ? dosTo.Value.ToDateTime(TimeOnly.MinValue)          : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@CEDFrom",         SqlDbType.Date) { Value = cedFrom.HasValue        ? cedFrom.Value.ToDateTime(TimeOnly.MinValue)        : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@CEDTo",           SqlDbType.Date) { Value = cedTo.HasValue          ? cedTo.Value.ToDateTime(TimeOnly.MinValue)          : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@FirstBilledFrom", SqlDbType.Date) { Value = firstBilledFrom.HasValue ? firstBilledFrom.Value.ToDateTime(TimeOnly.MinValue) : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@FirstBilledTo",   SqlDbType.Date) { Value = firstBilledTo.HasValue   ? firstBilledTo.Value.ToDateTime(TimeOnly.MinValue)   : DBNull.Value });

        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var rdr = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

        while (await rdr.ReadAsync(ct).ConfigureAwait(false))
        {
            result.Add(new SpExportBucket(
                BucketType:  rdr["BucketType"]?.ToString() ?? "ALL",
                YearNo:      rdr["YearNo"]  == DBNull.Value ? null : Convert.ToInt32(rdr["YearNo"],  CultureInfo.InvariantCulture),
                MonthNo:     rdr["MonthNo"] == DBNull.Value ? null : Convert.ToInt32(rdr["MonthNo"], CultureInfo.InvariantCulture),
                FromDate:    rdr["FromDate"] == DBNull.Value ? null : Convert.ToDateTime(rdr["FromDate"], CultureInfo.InvariantCulture),
                ToDate:      rdr["ToDate"]   == DBNull.Value ? null : Convert.ToDateTime(rdr["ToDate"],   CultureInfo.InvariantCulture),
                RecordCount: rdr["RecordCount"] == DBNull.Value ? 0 : Convert.ToInt32(rdr["RecordCount"], CultureInfo.InvariantCulture),
                SheetName:   rdr["SheetName"]?.ToString() ?? "Sheet"));
        }

        // The ALL bucket returns NULL FromDate/ToDate when the data SP requires real dates.
        // Fill in a safe wide range so the data SP never receives nulls.
        foreach (var b in result.Where(b =>
            b.BucketType.Equals("ALL", StringComparison.OrdinalIgnoreCase)
            && (!b.FromDate.HasValue || !b.ToDate.HasValue)))
        {
            result[result.IndexOf(b)] = b with
            {
                FromDate = firstBilledFrom.HasValue
                    ? firstBilledFrom.Value.ToDateTime(TimeOnly.MinValue)
                    : new DateTime(2000, 1, 1),
                ToDate = firstBilledTo.HasValue
                    ? firstBilledTo.Value.ToDateTime(TimeOnly.MinValue)
                    : DateTime.Today
            };
        }

        return result;
    }

    private static async Task<(string[] Columns, List<object?[]> Rows)> GetSpExportDataAsync(
        string connectionString,
        string spName,
        DateOnly? fromDate,
        DateOnly? toDate,
        string? payerNames,
        string? panelNames,
        DateOnly? dosFrom,    DateOnly? dosTo,
        DateOnly? cedFrom,    DateOnly? cedTo,
        DateOnly? firstBilledFrom, DateOnly? firstBilledTo,
        CancellationToken ct)
    {
        await using var conn = new SqlConnection(connectionString);
        await using var cmd  = new SqlCommand(spName, conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 600
        };

        cmd.Parameters.Add(new SqlParameter("@FromDate",        SqlDbType.Date) { Value = fromDate.HasValue ? fromDate.Value.ToDateTime(TimeOnly.MinValue) : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@ToDate",          SqlDbType.Date) { Value = toDate.HasValue   ? toDate.Value.ToDateTime(TimeOnly.MinValue)   : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@PayerNames",      SqlDbType.NVarChar, -1) { Value = (object?)payerNames ?? DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@PanelNames",      SqlDbType.NVarChar, -1) { Value = (object?)panelNames ?? DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@DosFrom",         SqlDbType.Date) { Value = dosFrom.HasValue        ? dosFrom.Value.ToDateTime(TimeOnly.MinValue)        : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@DosTo",           SqlDbType.Date) { Value = dosTo.HasValue          ? dosTo.Value.ToDateTime(TimeOnly.MinValue)          : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@CEDFrom",         SqlDbType.Date) { Value = cedFrom.HasValue        ? cedFrom.Value.ToDateTime(TimeOnly.MinValue)        : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@CEDTo",           SqlDbType.Date) { Value = cedTo.HasValue          ? cedTo.Value.ToDateTime(TimeOnly.MinValue)          : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@FirstBilledFrom", SqlDbType.Date) { Value = firstBilledFrom.HasValue ? firstBilledFrom.Value.ToDateTime(TimeOnly.MinValue) : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@FirstBilledTo",   SqlDbType.Date) { Value = firstBilledTo.HasValue   ? firstBilledTo.Value.ToDateTime(TimeOnly.MinValue)   : DBNull.Value });

        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var rdr = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

        var columns = Enumerable.Range(0, rdr.FieldCount).Select(i => rdr.GetName(i)).ToArray();
        var rows    = new List<object?[]>();

        while (await rdr.ReadAsync(ct).ConfigureAwait(false))
        {
            var row = new object?[columns.Length];
            for (int i = 0; i < columns.Length; i++)
                row[i] = rdr.IsDBNull(i) ? null : rdr.GetValue(i);
            rows.Add(row);
        }

        return (columns, rows);
    }

    private async Task<List<RawDataSegment>> GetRawDataExportSegmentsAsync(
        string connectionString,
        string tableName,
        string selectColumns,
        string baseSheetName,
        string whereStr,
        List<SqlParameter> parameters,
        CancellationToken ct)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var sw = System.Diagnostics.Stopwatch.StartNew();
        _logger.LogInformation(
            "[ProdExcelExportSplit] SQL split START Sheet={Sheet} Table={Table} Threshold={Threshold:N0}",
            baseSheetName, tableName, ExportSplitThreshold);

        var totalRows = await ExecuteCountAsync(connectionString, tableName, whereStr, parameters, null, ct);
        _logger.LogInformation(
            "[ProdExcelExportSplit] SQL split total Sheet={Sheet} Rows={Rows:N0}",
            baseSheetName, totalRows);

        if (totalRows == 0)
        {
            _logger.LogInformation(
                "[ProdExcelExportSplit] SQL split DONE Sheet={Sheet} Segments=1 Empty=true ElapsedMs={Ms}",
                baseSheetName, sw.ElapsedMilliseconds);
            return [new RawDataSegment(baseSheetName, [], [])];
        }

        if (totalRows <= ExportSplitThreshold)
        {
            var (cols, rows) = await ExecuteSegmentQueryAsync(connectionString, tableName, selectColumns, whereStr, parameters, null, null, null, null, null, ct);
            _logger.LogInformation(
                "[ProdExcelExportSplit] SQL split DONE Sheet={Sheet} Segments=1 Rows={Rows:N0} ElapsedMs={Ms}",
                baseSheetName, rows.Count, sw.ElapsedMilliseconds);
            return [new RawDataSegment(baseSheetName, cols, rows)];
        }

        var segments = new List<RawDataSegment>();
        var usedSheetNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var yearCounts = await ExecuteYearCountsAsync(connectionString, tableName, whereStr, parameters, ct);

        foreach (var (year, yearRows) in yearCounts)
        {
            var yearLabel = year > 0 ? year.ToString() : "Unknown";
            _logger.LogInformation(
                "[ProdExcelExportSplit] SQL year split Sheet={Sheet} Year={Year} Rows={Rows:N0}",
                baseSheetName, yearLabel, yearRows);

            var yearFilter = BuildYearFilter(year);
            if (yearRows <= ExportSplitThreshold || year == 0)
            {
                await AddPagedSegmentsAsync(connectionString, tableName, selectColumns, baseSheetName, whereStr, parameters, yearFilter, year > 0 ? year : null, null, yearLabel, null, yearRows, segments, usedSheetNames, ct);
                continue;
            }

            var monthCounts = await ExecuteMonthCountsAsync(connectionString, tableName, whereStr, parameters, year, ct);
            foreach (var (month, monthRows) in monthCounts)
            {
                _logger.LogInformation(
                    "[ProdExcelExportSplit] SQL month split Sheet={Sheet} Year={Year} Month={Month:D2} Rows={Rows:N0}",
                    baseSheetName, yearLabel, month, monthRows);

                await AddPagedSegmentsAsync(connectionString, tableName, selectColumns, baseSheetName, whereStr, parameters, BuildMonthFilter(year, month), year, month, yearLabel, month, monthRows, segments, usedSheetNames, ct);
            }
        }

        _logger.LogInformation(
            "[ProdExcelExportSplit] SQL split DONE Sheet={Sheet} Segments={Segments} Rows={Rows:N0} ElapsedMs={Ms} Details=[{Details}]",
            baseSheetName,
            segments.Count,
            segments.Sum(s => s.Rows.Count),
            sw.ElapsedMilliseconds,
            string.Join(", ", segments.Select(s => $"'{s.SheetName}'({s.Rows.Count:N0})")));

        return segments;
    }

    private async Task AddPagedSegmentsAsync(
        string connectionString,
        string tableName,
        string selectColumns,
        string baseSheetName,
        string whereStr,
        List<SqlParameter> parameters,
        string splitFilter,
        int? splitYear,
        int? splitMonth,
        string yearLabel,
        int? month,
        long rowCount,
        List<RawDataSegment> segments,
        HashSet<string> usedSheetNames,
        CancellationToken ct)
    {
        var pageCount = Math.Max(1, (int)Math.Ceiling(rowCount / (double)ExportSplitThreshold));
        for (var page = 0; page < pageCount; page++)
        {
            var offset = page * ExportSplitThreshold;
            var partSuffix = pageCount > 1 ? $"_Part{page + 1}" : string.Empty;
            var sheetNamePrefix = month.HasValue
                ? $"{yearLabel}_{month.Value:D2}_{baseSheetName}{partSuffix}"
                : $"{yearLabel}_{baseSheetName}{partSuffix}";
            var sheetName = CreateUniqueSheetName(sheetNamePrefix, usedSheetNames);

            _logger.LogInformation(
                "[ProdExcelExportSplit] SQL segment query START Sheet={SheetName} Source={BaseSheet} Offset={Offset:N0} Take={Take:N0}",
                sheetName, baseSheetName, offset, ExportSplitThreshold);

            var (cols, rows) = await ExecuteSegmentQueryAsync(
                connectionString,
                tableName,
                selectColumns,
                whereStr,
                parameters,
                splitFilter,
                splitYear,
                splitMonth,
                offset,
                ExportSplitThreshold,
                ct);

            _logger.LogInformation(
                "[ProdExcelExportSplit] SQL segment query DONE Sheet={SheetName} Rows={Rows:N0}",
                sheetName, rows.Count);

            segments.Add(new RawDataSegment(sheetName, cols, rows));
        }
    }

    internal static (string WhereStr, List<SqlParameter> Parameters) BuildExportFilters(
        List<string>? filterPayerNames, List<string>? filterPanelNames,
        DateOnly? filterDosFrom, DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom, DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom, DateOnly? filterFirstBilledTo,
        string prefix,
        string? rule = null,
        bool isLineLevel = false)
    {
        var where = new List<string>();
        var parms = new List<SqlParameter>();
        var isRule4 = string.Equals(rule, "Rule4", StringComparison.OrdinalIgnoreCase);

        // Panel column differs by table type:
        //   ClaimLevelData  NorthWest (Rule4) = PanelType | Augustus (Rule3) = PanelNew | others = PanelName
        //   LineLevelData   all rules = Panelname (standard column, no PanelType/PanelNew)
        var panelGuardCol   = isLineLevel ? "Panelname"  : (isRule4 ? "PanelType"  : "PanelName");
        var panelFilterCol  = panelGuardCol;

        if (isRule4)
        {
            if (!isLineLevel)
                where.Add("NULLIF(LTRIM(RTRIM(PanelType)), '') IS NOT NULL");
            where.Add("LTRIM(RTRIM(ClaimStatus)) NOT IN ('Unbilled in Daq','Unbilled in Daq - PR','Unbilled in Webpm','Unbilled in Webpm - PR','Billed amount 0')");
        }

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
            where.Add($"LTRIM(RTRIM({panelFilterCol})) IN ({string.Join(",", names)})");
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

    // ?? Run Info ?????????????????????????????????????????????????????

    /// <inheritdoc />
    public async Task<(string? WeekFolder, string? RunId)> GetRunInfoAsync(
        string connectionString, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        const string sql = "SELECT TOP 1 WeekFolder, CAST(RunId AS NVARCHAR(50)) FROM LineClaimFileLogs ORDER BY 1 DESC";
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
            await using var rdr = await cmd.ExecuteReaderAsync(ct);
            if (await rdr.ReadAsync(ct))
            {
                var weekFolder = rdr.IsDBNull(0) ? null : rdr.GetString(0);
                var runId      = rdr.IsDBNull(1) ? null : rdr.GetString(1);
                return (weekFolder, runId);
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to read RunInfo from LineClaimFileLogs.");
        }
        return (null, null);
    }

    private static string GetClaimLevelExportColumns() => """
        [ClaimID],[AccessionNumber],[PayerName],[PayerType],[BillingProvider],[ReferringProvider],
        [ClinicName],[SalesRepname],[PatientID],[PatientDOB],[DateofService],[ChargeEnteredDate],
        [FirstBilledDate],[Panelname],[CPTCodeXUnitsXModifier],[POS],[TOS],[ChargeAmount],[AllowedAmount],
        [InsurancePayment],[PatientPayment],[TotalPayments],[InsuranceAdjustments],[PatientAdjustments],
        [TotalAdjustments],[InsuranceBalance],[PatientBalance],[TotalBalance],[CheckDate],[ClaimStatus],
        [DenialCode],[ICDCode],[DaystoDOS],[RollingDays],[DaystoBill],[DaystoPost],[ICDPointer],[InsertedDateTime]
        """;

    private static string GetLineLevelExportColumns() => """
        [ClaimID],[AccessionNumber],[PayerName],[PayerType],[BillingProvider],[ReferringProvider],
        [ClinicName],[SalesRepname],[PatientID],[PatientDOB],[DateofService],[ChargeEnteredDate],
        [FirstBilledDate],[Panelname],[CPTCode],[Units],[Modifier],[POS],[TOS],
        [ChargeAmount],[ChargeAmountPerUnit],[AllowedAmount],[AllowedAmountPerUnit],
        [InsurancePayment],[InsurancePaymentPerUnit],[PatientPayment],[PatientPaymentPerUnit],
        [TotalPayments],[InsuranceAdjustments],[PatientAdjustments],[TotalAdjustments],
        [InsuranceBalance],[PatientBalance],[PatientBalancePerUnit],[TotalBalance],
        [CheckDate],[PostingDate],[ClaimStatus],[PayStatus],[DenialCode],[DenialDate],
        [ICDCode],[DaystoDOS],[RollingDays],[DaystoBill],[DaystoPost],[ICDPointer]
        """;

    private static string BuildYearFilter(int year) => year > 0
        ? "YEAR(TRY_CAST(FirstBilledDate AS DATE)) = @splitYear"
        : "(TRY_CAST(FirstBilledDate AS DATE) IS NULL OR YEAR(TRY_CAST(FirstBilledDate AS DATE)) <= 1900)";

    private static string BuildMonthFilter(int year, int month) =>
        "YEAR(TRY_CAST(FirstBilledDate AS DATE)) = @splitYear AND MONTH(TRY_CAST(FirstBilledDate AS DATE)) = @splitMonth";

    private static string AppendWhere(string whereStr, string? extraFilter)
    {
        if (string.IsNullOrWhiteSpace(extraFilter))
            return whereStr;

        return string.IsNullOrWhiteSpace(whereStr)
            ? "WHERE " + extraFilter
            : whereStr + " AND " + extraFilter;
    }

    private static string CreateUniqueSheetName(string requestedName, HashSet<string> usedSheetNames)
    {
        static string Clean(string value)
        {
            var cleaned = value.Trim();
            foreach (var invalid in new[] { ':', '\\', '/', '?', '*', '[', ']' })
                cleaned = cleaned.Replace(invalid, '_');
            return string.IsNullOrWhiteSpace(cleaned) ? "Sheet" : cleaned;
        }

        var baseName = Clean(requestedName);
        var candidate = baseName.Length <= 31 ? baseName : baseName[..31];
        var suffix = 1;
        while (!usedSheetNames.Add(candidate))
        {
            var tail = $"_{suffix++}";
            var maxBaseLength = 31 - tail.Length;
            candidate = (baseName.Length <= maxBaseLength ? baseName : baseName[..maxBaseLength]) + tail;
        }

        return candidate;
    }

    private async Task<long> ExecuteCountAsync(
        string connectionString,
        string tableName,
        string whereStr,
        List<SqlParameter> parameters,
        string? extraFilter,
        CancellationToken ct)
    {
        var sql = $"SELECT COUNT_BIG(*) FROM {tableName} {AppendWhere(whereStr, extraFilter)}";
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 300 };
        AddClonedParameters(cmd, parameters);
        AddSplitParameters(cmd, extraFilter, year: null, month: null, offset: null, take: null);
        var value = await cmd.ExecuteScalarAsync(ct);
        return Convert.ToInt64(value, CultureInfo.InvariantCulture);
    }

    private async Task<List<(int Year, long Rows)>> ExecuteYearCountsAsync(
        string connectionString,
        string tableName,
        string whereStr,
        List<SqlParameter> parameters,
        CancellationToken ct)
    {
        var sql = $"""
            SELECT
                CASE
                    WHEN TRY_CAST(FirstBilledDate AS DATE) IS NULL OR YEAR(TRY_CAST(FirstBilledDate AS DATE)) <= 1900 THEN 0
                    ELSE YEAR(TRY_CAST(FirstBilledDate AS DATE))
                END AS SplitYear,
                COUNT_BIG(*) AS TotalRows
            FROM {tableName}
            {whereStr}
            GROUP BY
                CASE
                    WHEN TRY_CAST(FirstBilledDate AS DATE) IS NULL OR YEAR(TRY_CAST(FirstBilledDate AS DATE)) <= 1900 THEN 0
                    ELSE YEAR(TRY_CAST(FirstBilledDate AS DATE))
                END
            ORDER BY SplitYear
            """;

        var rows = new List<(int Year, long Rows)>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 300 };
        AddClonedParameters(cmd, parameters);
        await using var rdr = await cmd.ExecuteReaderAsync(ct);
        while (await rdr.ReadAsync(ct))
            rows.Add((rdr.GetInt32(0), rdr.GetInt64(1)));
        return rows;
    }

    private async Task<List<(int Month, long Rows)>> ExecuteMonthCountsAsync(
        string connectionString,
        string tableName,
        string whereStr,
        List<SqlParameter> parameters,
        int year,
        CancellationToken ct)
    {
        var sql = $"""
            SELECT MONTH(TRY_CAST(FirstBilledDate AS DATE)) AS SplitMonth, COUNT_BIG(*) AS TotalRows
            FROM {tableName}
            {AppendWhere(whereStr, BuildYearFilter(year))}
            GROUP BY MONTH(TRY_CAST(FirstBilledDate AS DATE))
            ORDER BY SplitMonth
            """;

        var rows = new List<(int Month, long Rows)>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 300 };
        AddClonedParameters(cmd, parameters);
        cmd.Parameters.Add(new SqlParameter("@splitYear", SqlDbType.Int) { Value = year });
        await using var rdr = await cmd.ExecuteReaderAsync(ct);
        while (await rdr.ReadAsync(ct))
            rows.Add((rdr.GetInt32(0), rdr.GetInt64(1)));
        return rows;
    }

    private async Task<(string[] Columns, List<object?[]> Rows)> ExecuteSegmentQueryAsync(
        string connectionString,
        string tableName,
        string selectColumns,
        string whereStr,
        List<SqlParameter> parameters,
        string? extraFilter,
        int? splitYear,
        int? splitMonth,
        int? offset,
        int? take,
        CancellationToken ct)
    {
        var pagingSql = offset.HasValue && take.HasValue
            ? "ORDER BY TRY_CAST(FirstBilledDate AS DATE), ClaimID, AccessionNumber OFFSET @splitOffset ROWS FETCH NEXT @splitTake ROWS ONLY"
            : "ORDER BY TRY_CAST(FirstBilledDate AS DATE), ClaimID, AccessionNumber";
        var sql = $"""
            SELECT {selectColumns}
            FROM {tableName}
            {AppendWhere(whereStr, extraFilter)}
            {pagingSql}
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 300 };
        AddClonedParameters(cmd, parameters);
        AddSplitParameters(cmd, extraFilter, splitYear, splitMonth, offset, take);
        return await ExecuteReaderToArraysAsync(cmd, ct);
    }

    private static void AddClonedParameters(SqlCommand cmd, List<SqlParameter> parameters)
    {
        foreach (var p in parameters)
            cmd.Parameters.Add(new SqlParameter(p.ParameterName, p.SqlDbType) { Value = p.Value });
    }

    private static void AddSplitParameters(SqlCommand cmd, string? extraFilter, int? year, int? month, int? offset, int? take)
    {
        if (!string.IsNullOrWhiteSpace(extraFilter) && extraFilter.Contains("@splitYear", StringComparison.Ordinal) && year.HasValue)
            cmd.Parameters.Add(new SqlParameter("@splitYear", SqlDbType.Int) { Value = year.Value });
        if (!string.IsNullOrWhiteSpace(extraFilter) && extraFilter.Contains("@splitMonth", StringComparison.Ordinal) && month.HasValue)
            cmd.Parameters.Add(new SqlParameter("@splitMonth", SqlDbType.Int) { Value = month.Value });
        if (offset.HasValue)
            cmd.Parameters.Add(new SqlParameter("@splitOffset", SqlDbType.Int) { Value = offset.Value });
        if (take.HasValue)
            cmd.Parameters.Add(new SqlParameter("@splitTake", SqlDbType.Int) { Value = take.Value });
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

        return await ExecuteReaderToDictionaryListAsync(cmd, ct);
    }

    private async Task<List<Dictionary<string, object?>>> ExecuteReaderToDictionaryListAsync(SqlCommand cmd, CancellationToken ct)
    {
        var rows = new List<Dictionary<string, object?>>();
        var sw = System.Diagnostics.Stopwatch.StartNew();

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

    /// <summary>
    /// Memory-efficient reader for segment export paths.
    /// Column names are stored once; each row is a plain <c>object?[]</c> array
    /// (~75 % less memory per row than a Dictionary).
    /// </summary>
    private async Task<(string[] Columns, List<object?[]> Rows)> ExecuteReaderToArraysAsync(
        SqlCommand cmd, CancellationToken ct)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        await using var r = await cmd.ExecuteReaderAsync(ct);

        var columns = Enumerable.Range(0, r.FieldCount).Select(i => r.GetName(i)).ToArray();
        var rows    = new List<object?[]>();

        while (await r.ReadAsync(ct))
        {
            var row = new object?[columns.Length];
            for (int i = 0; i < columns.Length; i++)
                row[i] = r.IsDBNull(i) ? null : r.GetValue(i);
            rows.Add(row);
        }

        _logger.LogInformation("ProductionReport segment query: rows={Count}, elapsed={Ms}ms",
            rows.Count, sw.ElapsedMilliseconds);

        return (columns, rows);
    }

    private async Task<ProductionReportResult> GetMonthlyClaimVolumeFromStoredProcedureAsync(
        string connectionString,
        string spPrefix,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        DateOnly? filterDosFrom,
        DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom,
        DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom,
        DateOnly? filterFirstBilledTo,
        CancellationToken ct)
    {
        var spName = $"dbo.usp_Get{spPrefix}MonthlyBilledProductionSummary";
        var (payerNames, panelNames) = await GetFilterOptionsAsync(connectionString, rule: spPrefix, ct).ConfigureAwait(false);
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var cmd = new SqlCommand(spName, conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 180,
        };
        AddProductionFilterParameters(cmd, filterPayerNames, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo);
        await using var rdr = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

        var panelMonth = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
        var payerMonthMap = new Dictionary<string, Dictionary<string, Dictionary<string, (int c, decimal ch)>>>(StringComparer.OrdinalIgnoreCase);
        var payerRankMap = new Dictionary<string, Dictionary<string, int>>(StringComparer.OrdinalIgnoreCase);
        var allMonths = new SortedSet<string>();

        while (await rdr.ReadAsync(ct).ConfigureAwait(false))
        {
            var panel = rdr.GetString(0);
            var payer = rdr.GetString(1);
            var rank = Convert.ToInt32(rdr.GetValue(2), CultureInfo.InvariantCulture);
            var month = rdr.GetString(3);
            var count = rdr.GetInt32(4);
            var charges = rdr.GetDecimal(5);

            allMonths.Add(month);

            if (rank == 0)
            {
                if (!panelMonth.TryGetValue(panel, out var panelByMonth))
                    panelMonth[panel] = panelByMonth = [];

                panelByMonth[month] = (count, charges);
                continue;
            }

            if (!payerMonthMap.TryGetValue(panel, out var payerByPanel))
                payerMonthMap[panel] = payerByPanel = new(StringComparer.OrdinalIgnoreCase);
            if (!payerByPanel.TryGetValue(payer, out var payerByMonth))
                payerByPanel[payer] = payerByMonth = [];

            payerByMonth[month] = payerByMonth.TryGetValue(month, out var existing)
                ? (existing.c + count, existing.ch + charges)
                : (count, charges);

            if (!payerRankMap.TryGetValue(panel, out var rankMap))
                payerRankMap[panel] = rankMap = new(StringComparer.OrdinalIgnoreCase);

            rankMap[payer] = rank;
        }

        if (panelMonth.Count == 0)
        {
            foreach (var (panel, payers) in payerMonthMap)
            {
                if (!panelMonth.TryGetValue(panel, out var panelByMonth))
                    panelMonth[panel] = panelByMonth = [];

                foreach (var (_, months) in payers)
                {
                    foreach (var (month, value) in months)
                    {
                        panelByMonth[month] = panelByMonth.TryGetValue(month, out var existing)
                            ? (existing.c + value.c, existing.ch + value.ch)
                            : value;
                    }
                }
            }
        }

        return BuildProductionReportResultFromStoredProcedure(panelMonth, payerMonthMap, payerRankMap, allMonths, payerNames, panelNames);
    }

    private static ProductionReportResult BuildProductionReportResultFromStoredProcedure(
        Dictionary<string, Dictionary<string, (int c, decimal ch)>> panelMonth,
        Dictionary<string, Dictionary<string, Dictionary<string, (int c, decimal ch)>>> payerMonthMap,
        Dictionary<string, Dictionary<string, int>> payerRankMap,
        SortedSet<string> allMonths,
        List<string> payerNames,
        List<string> panelNames)
    {
        var months = allMonths.ToList();
        var years = months.Select(m => int.Parse(m[..4], CultureInfo.InvariantCulture)).Distinct().OrderBy(y => y).ToList();
        var grandByMonth = new Dictionary<string, ProductionMonthCell>();
        var panelRows = new List<ProductionPanelRow>();

        foreach (var (panel, panelValues) in panelMonth.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
        {
            var byMonth = panelValues.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));

            foreach (var (mk, cell) in byMonth)
            {
                if (!grandByMonth.TryGetValue(mk, out var existingGrand))
                    grandByMonth[mk] = cell;
                else
                    grandByMonth[mk] = new ProductionMonthCell(existingGrand.ClaimCount + cell.ClaimCount, existingGrand.BilledCharges + cell.BilledCharges);
            }

            var topPayers = payerMonthMap.TryGetValue(panel, out var payers) && payerRankMap.TryGetValue(panel, out var ranks)
                ? payers
                    .OrderBy(p => ranks.GetValueOrDefault(p.Key, 99))
                    .Take(TopPayerDrillDownCount)
                    .Select(p => new ProductionPayerDrillDown
                    {
                        PayerName = p.Key,
                        ByMonth = p.Value.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch)),
                        ByYear = p.Value
                            .GroupBy(kv => int.Parse(kv.Key[..4], CultureInfo.InvariantCulture))
                            .ToDictionary(g => g.Key, g => new ProductionYearTotal(g.Sum(kv => kv.Value.c), g.Sum(kv => kv.Value.ch))),
                        TotalClaims = p.Value.Values.Sum(v => v.c),
                        TotalCharges = p.Value.Values.Sum(v => v.ch),
                    })
                    .ToList()
                : [];

            panelRows.Add(new ProductionPanelRow
            {
                PanelName = panel,
                ByMonth = byMonth,
                ByYear = panelValues
                    .GroupBy(kv => int.Parse(kv.Key[..4], CultureInfo.InvariantCulture))
                    .ToDictionary(g => g.Key, g => new ProductionYearTotal(g.Sum(kv => kv.Value.c), g.Sum(kv => kv.Value.ch))),
                TotalClaims = byMonth.Values.Sum(c => c.ClaimCount),
                TotalCharges = byMonth.Values.Sum(c => c.BilledCharges),
                TopPayers = topPayers,
            });
        }

        return new ProductionReportResult(
            payerNames,
            panelNames.Count > 0 ? panelNames : panelRows.Select(p => p.PanelName).ToList(),
            months,
            years,
            panelRows,
            grandByMonth,
            grandByMonth.Values.Sum(c => c.ClaimCount),
            grandByMonth.Values.Sum(c => c.BilledCharges));
    }

    private async Task<(List<string> PayerNames, List<string> PanelNames)> GetFilterOptionsAsync(
        string connectionString,
        string rule,
        CancellationToken ct)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(rule);

        // Panel column hardcoded per lab rule — ClaimLevelData only (filter options are always claim-level):
        //   NorthWest  (NW_  / Rule4) = PanelType
        //   Augustus   (Aug_ / Rule3) = PanelNew
        //   all others               = PanelName
        var isRule4 = string.Equals(rule, NorthWestPrefix, StringComparison.OrdinalIgnoreCase);
        var isRule3 = string.Equals(rule, AugustusPrefix, StringComparison.OrdinalIgnoreCase);
        var isRule2 = string.Equals(rule, CertusPrefix, StringComparison.OrdinalIgnoreCase);

        var payerWhereClauses = new List<string>();
        var panelWhereClauses = new List<string>();
        var payerColumn = "PayerName_Raw";
        var panelColumn = isRule4 ? "PanelType" : isRule3 ? "PanelNew" : "PanelName";

        if (isRule4)
        {
            payerWhereClauses.Add("NULLIF(LTRIM(RTRIM(PanelType)), '') IS NOT NULL");
            payerWhereClauses.Add("LTRIM(RTRIM(ClaimStatus)) NOT IN ('Unbilled in Daq','Unbilled in Daq - PR','Unbilled in Webpm','Unbilled in Webpm - PR','Billed amount 0')");
            panelWhereClauses.AddRange(payerWhereClauses);
        }
        else if (isRule3)
        {
            payerWhereClauses.Add("TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL");
            payerWhereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL");
            panelWhereClauses.AddRange(payerWhereClauses);
            panelWhereClauses.Add("NULLIF(LTRIM(RTRIM(PanelNew)), '') IS NOT NULL");
        }
        else if (isRule2)
        {
            payerWhereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL");
            panelWhereClauses.AddRange(payerWhereClauses);
        }
        else
        {
            payerWhereClauses.Add("TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL");
            panelWhereClauses.AddRange(payerWhereClauses);
            if (string.Equals(rule, PcrPrefix, StringComparison.OrdinalIgnoreCase)
                || string.Equals(rule, BeechTreePrefix, StringComparison.OrdinalIgnoreCase)
                || string.Equals(rule, RisingTidesPrefix, StringComparison.OrdinalIgnoreCase))
            {
                payerWhereClauses.Add("TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL");
                panelWhereClauses.Add("TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL");
            }
        }

        payerWhereClauses.Add("NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL");
        panelWhereClauses.Add($"NULLIF(LTRIM(RTRIM({panelColumn})), '') IS NOT NULL");

        var payerWhere = string.Join(" AND ", payerWhereClauses);
        var panelWhere = string.Join(" AND ", panelWhereClauses);
        var sql = $"""
            SELECT DISTINCT LTRIM(RTRIM({payerColumn}))
            FROM dbo.ClaimLevelData
            WHERE {payerWhere}
            ORDER BY 1;

            SELECT DISTINCT LTRIM(RTRIM({panelColumn}))
            FROM dbo.ClaimLevelData
            WHERE {panelWhere}
            ORDER BY 1;
            """;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        await using var rdr = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

        var payers = new List<string>();
        while (await rdr.ReadAsync(ct).ConfigureAwait(false))
            if (!rdr.IsDBNull(0)) payers.Add(rdr.GetString(0));

        await rdr.NextResultAsync(ct).ConfigureAwait(false);
        var panels = new List<string>();
        while (await rdr.ReadAsync(ct).ConfigureAwait(false))
            if (!rdr.IsDBNull(0)) panels.Add(rdr.GetString(0));

        return (payers, panels);
    }

    private async Task<WeeklyClaimVolumeResult> GetWeeklyClaimVolumeFromStoredProcedureAsync(
        string connectionString,
        string spPrefix,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        DateOnly? filterDosFrom,
        DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom,
        DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom,
        DateOnly? filterFirstBilledTo,
        CancellationToken ct)
    {
        var spName = $"dbo.usp_Get{spPrefix}WeeklyBilledProductionSummary";
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var cmd = new SqlCommand(spName, conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 180,
        };
        AddProductionFilterParameters(cmd, filterPayerNames, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo);
        await using var rdr = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

        var weekCols = new Dictionary<string, WeekColumn>();
        var panelWeek = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
        var payerWeekMap = new Dictionary<string, Dictionary<string, Dictionary<string, (int c, decimal ch)>>>(StringComparer.OrdinalIgnoreCase);
        var payerRankMap = new Dictionary<string, Dictionary<string, int>>(StringComparer.OrdinalIgnoreCase);

        while (await rdr.ReadAsync(ct).ConfigureAwait(false))
        {
            var panel = rdr.GetString(0);
            var payer = rdr.GetString(1);
            var rank = Convert.ToInt32(rdr.GetValue(2), CultureInfo.InvariantCulture);
            var weekStart = DateOnly.FromDateTime(rdr.GetDateTime(3));
            var weekEnd = DateOnly.FromDateTime(rdr.GetDateTime(4));
            var count = rdr.GetInt32(6);
            var charges = rdr.GetDecimal(7);
            var weekKey = weekStart.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

            if (!weekCols.ContainsKey(weekKey))
                weekCols[weekKey] = new WeekColumn(weekKey, weekStart, weekEnd);

            if (rank == 0)
            {
                if (!panelWeek.TryGetValue(panel, out var panelByWeek))
                    panelWeek[panel] = panelByWeek = [];

                panelByWeek[weekKey] = (count, charges);
                continue;
            }

            if (!payerWeekMap.TryGetValue(panel, out var payers))
                payerWeekMap[panel] = payers = new(StringComparer.OrdinalIgnoreCase);
            if (!payers.TryGetValue(payer, out var byWeek))
                payers[payer] = byWeek = [];

            byWeek[weekKey] = byWeek.TryGetValue(weekKey, out var existing)
                ? (existing.c + count, existing.ch + charges)
                : (count, charges);

            if (!payerRankMap.TryGetValue(panel, out var rankMap))
                payerRankMap[panel] = rankMap = new(StringComparer.OrdinalIgnoreCase);

            rankMap[payer] = rank;
        }

        if (panelWeek.Count == 0)
        {
            foreach (var (panel, payers) in payerWeekMap)
            {
                if (!panelWeek.TryGetValue(panel, out var panelByWeek))
                    panelWeek[panel] = panelByWeek = [];

                foreach (var (_, weeks) in payers)
                {
                    foreach (var (week, value) in weeks)
                    {
                        panelByWeek[week] = panelByWeek.TryGetValue(week, out var existing)
                            ? (existing.c + value.c, existing.ch + value.ch)
                            : value;
                    }
                }
            }
        }

        return BuildWeeklyResultFromStoredProcedure(weekCols, panelWeek, payerWeekMap, payerRankMap);
    }

    private static WeeklyClaimVolumeResult BuildWeeklyResultFromStoredProcedure(
        Dictionary<string, WeekColumn> weekCols,
        Dictionary<string, Dictionary<string, (int c, decimal ch)>> panelWeek,
        Dictionary<string, Dictionary<string, Dictionary<string, (int c, decimal ch)>>> payerWeekMap,
        Dictionary<string, Dictionary<string, int>> payerRankMap)
    {
        var columns = weekCols.Values.OrderBy(w => w.WeekStart).ToList();
        var grandByWeek = new Dictionary<string, ProductionMonthCell>();
        var panelRows = new List<WeeklyPanelRow>();

        foreach (var (panel, weeks) in panelWeek.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
        {
            var byWeek = weeks.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));

            foreach (var (weekKey, cell) in byWeek)
            {
                if (!grandByWeek.TryGetValue(weekKey, out var existingGrand))
                    grandByWeek[weekKey] = cell;
                else
                    grandByWeek[weekKey] = new ProductionMonthCell(existingGrand.ClaimCount + cell.ClaimCount, existingGrand.BilledCharges + cell.BilledCharges);
            }

            var topPayers = payerWeekMap.TryGetValue(panel, out var payers) && payerRankMap.TryGetValue(panel, out var ranks)
                ? payers
                    .OrderBy(p => ranks.GetValueOrDefault(p.Key, 99))
                    .Take(TopPayerDrillDownCount)
                    .Select(p => new WeeklyPayerDrillDown
                    {
                        PayerName = p.Key,
                        ByWeek = p.Value.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch)),
                        TotalClaims = p.Value.Values.Sum(v => v.c),
                        TotalCharges = p.Value.Values.Sum(v => v.ch),
                    })
                    .ToList()
                : [];

            panelRows.Add(new WeeklyPanelRow
            {
                PanelName = panel,
                ByWeek = byWeek,
                TotalClaims = byWeek.Values.Sum(c => c.ClaimCount),
                TotalCharges = byWeek.Values.Sum(c => c.BilledCharges),
                TopPayers = topPayers,
            });
        }

        return new WeeklyClaimVolumeResult(
            columns,
            panelRows,
            grandByWeek,
            grandByWeek.Values.Sum(c => c.ClaimCount),
            grandByWeek.Values.Sum(c => c.BilledCharges));
    }

    private async Task<CodingResult> GetCodingFromStoredProcedureAsync(
        string connectionString,
        string spPrefix,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        DateOnly? filterDosFrom,
        DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom,
        DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom,
        DateOnly? filterFirstBilledTo,
        CancellationToken ct)
    {
        var spName = $"dbo.usp_Get{spPrefix}CodingBreakdown";
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var cmd = new SqlCommand(spName, conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 180,
        };
        AddProductionFilterParameters(cmd, filterPayerNames, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo);

        var panelMap = new Dictionary<string, (int c, decimal ch)>(StringComparer.OrdinalIgnoreCase);
        var cptMap = new Dictionary<string, List<CodingCptDrillDown>>(StringComparer.OrdinalIgnoreCase);

        await using var rdr = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
        while (await rdr.ReadAsync(ct).ConfigureAwait(false))
            panelMap[rdr.GetString(0)] = (rdr.GetInt32(1), rdr.GetDecimal(2));

        if (await rdr.NextResultAsync(ct).ConfigureAwait(false))
        {
            while (await rdr.ReadAsync(ct).ConfigureAwait(false))
            {
                var panel = rdr.GetString(0);
                if (!cptMap.TryGetValue(panel, out var list))
                    cptMap[panel] = list = [];

                list.Add(new CodingCptDrillDown
                {
                    CptCodeUnitsModifier = rdr.GetString(1),
                    ClaimCount = rdr.GetInt32(2),
                    TotalCharges = rdr.GetDecimal(3),
                });
            }
        }

        var panelRows = panelMap
            .OrderByDescending(kv => kv.Value.ch)
            .Select(kv => new CodingPanelRow
            {
                PanelName = kv.Key,
                ClaimCount = kv.Value.c,
                TotalCharges = kv.Value.ch,
                CptRows = cptMap.GetValueOrDefault(kv.Key) ?? [],
            })
            .ToList();

        return new CodingResult(panelRows, panelRows.Sum(r => r.ClaimCount), panelRows.Sum(r => r.TotalCharges));
    }

    private async Task<PayerBreakdownResult> GetPayerBreakdownFromStoredProcedureAsync(
        string connectionString,
        string spPrefix,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        DateOnly? filterDosFrom,
        DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom,
        DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom,
        DateOnly? filterFirstBilledTo,
        CancellationToken ct)
    {
        var spName = $"dbo.usp_Get{spPrefix}PayerBreakdown";
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var cmd = new SqlCommand(spName, conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 180,
        };
        AddProductionFilterParameters(cmd, filterPayerNames, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo);
        await using var rdr = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

        var payerMonth = new Dictionary<string, Dictionary<string, int>>(StringComparer.OrdinalIgnoreCase);
        var allMonths = new SortedSet<string>();

        while (await rdr.ReadAsync(ct).ConfigureAwait(false))
        {
            var payer = rdr.GetString(0);
            var month = rdr.GetString(1);
            var count = rdr.GetInt32(2);

            allMonths.Add(month);
            if (!payerMonth.TryGetValue(payer, out var byMonth))
                payerMonth[payer] = byMonth = [];
            byMonth[month] = byMonth.GetValueOrDefault(month) + count;
        }

        var months = allMonths.ToList();
        var years = months.Select(m => int.Parse(m[..4], CultureInfo.InvariantCulture)).Distinct().OrderBy(y => y).ToList();
        var grandByMonth = new Dictionary<string, int>();
        var payerRows = new List<PayerBreakdownRow>();

        foreach (var (payer, byMonth) in payerMonth.OrderByDescending(x => x.Value.Values.Sum()))
        {
            var byYear = years.ToDictionary(y => y, y => byMonth.Where(kv => kv.Key.StartsWith($"{y:D4}", StringComparison.Ordinal)).Sum(kv => kv.Value));
            foreach (var (month, count) in byMonth)
                grandByMonth[month] = grandByMonth.GetValueOrDefault(month) + count;

            payerRows.Add(new PayerBreakdownRow
            {
                PayerName = payer,
                ByMonth = byMonth,
                ByYear = byYear,
                GrandTotal = byMonth.Values.Sum(),
            });
        }

        return new PayerBreakdownResult(months, years, payerRows, grandByMonth, grandByMonth.Values.Sum());
    }

    private async Task<PayerPanelResult> GetPayerPanelFromStoredProcedureAsync(
        string connectionString,
        string spPrefix,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        DateOnly? filterDosFrom,
        DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom,
        DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom,
        DateOnly? filterFirstBilledTo,
        CancellationToken ct)
    {
        var spName = $"dbo.usp_Get{spPrefix}PayerByPanel";
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var cmd = new SqlCommand(spName, conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 180,
        };
        AddProductionFilterParameters(cmd, filterPayerNames, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo);
        await using var rdr = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

        var payerPanel = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
        var allPanels = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);

        while (await rdr.ReadAsync(ct).ConfigureAwait(false))
        {
            var payer = rdr.GetString(0);
            var panel = rdr.GetString(1);
            var count = rdr.GetInt32(2);
            var charges = rdr.GetDecimal(3);

            allPanels.Add(panel);
            if (!payerPanel.TryGetValue(payer, out var byPanel))
                payerPanel[payer] = byPanel = new(StringComparer.OrdinalIgnoreCase);
            byPanel[panel] = (byPanel.GetValueOrDefault(panel).c + count, byPanel.GetValueOrDefault(panel).ch + charges);
        }

        var panelColumns = allPanels.ToList();
        var grandByPanel = new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase);
        var payerRows = new List<PayerPanelRow>();

        foreach (var (payer, byPanel) in payerPanel.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
        {
            var cells = byPanel.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));
            foreach (var (panel, cell) in cells)
            {
                if (!grandByPanel.TryGetValue(panel, out var existingGrand))
                    grandByPanel[panel] = cell;
                else
                    grandByPanel[panel] = new ProductionMonthCell(existingGrand.ClaimCount + cell.ClaimCount, existingGrand.BilledCharges + cell.BilledCharges);
            }

            payerRows.Add(new PayerPanelRow
            {
                PayerName = payer,
                ByPanel = cells,
                GrandTotalClaims = cells.Values.Sum(c => c.ClaimCount),
                GrandTotalCharges = cells.Values.Sum(c => c.BilledCharges),
            });
        }

        return new PayerPanelResult(panelColumns, payerRows, grandByPanel, grandByPanel.Values.Sum(c => c.ClaimCount), grandByPanel.Values.Sum(c => c.BilledCharges));
    }

    private async Task<UnbilledAgingResult> GetUnbilledAgingFromStoredProcedureAsync(
        string connectionString,
        string spPrefix,
        List<string>? filterPanelNames,
        DateOnly? filterDosFrom,
        DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom,
        DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom,
        DateOnly? filterFirstBilledTo,
        CancellationToken ct)
    {
        var spName = $"dbo.usp_Get{spPrefix}UnbilledAging";
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var cmd = new SqlCommand(spName, conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 180,
        };
        AddProductionFilterParameters(cmd, null, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo);
        await using var rdr = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

        var rowBucket = new Dictionary<string, Dictionary<string, (int c, decimal ch)>>(StringComparer.OrdinalIgnoreCase);
        while (await rdr.ReadAsync(ct).ConfigureAwait(false))
        {
            var rowKey = rdr.IsDBNull(0) ? "Unknown" : rdr.GetString(0);
            var bucket = rdr.IsDBNull(1) ? "Unknown" : rdr.GetString(1);
            var count = rdr.GetInt32(2);
            var charges = rdr.GetDecimal(3);

            if (!rowBucket.TryGetValue(rowKey, out var buckets))
                rowBucket[rowKey] = buckets = new(StringComparer.OrdinalIgnoreCase);
            buckets[bucket] = (buckets.GetValueOrDefault(bucket).c + count, buckets.GetValueOrDefault(bucket).ch + charges);
        }

        var grandByBucket = new Dictionary<string, ProductionMonthCell>(StringComparer.OrdinalIgnoreCase);
        var panelRows = new List<UnbilledAgingRow>();

        foreach (var (rowKey, buckets) in rowBucket.OrderByDescending(x => x.Value.Values.Sum(v => v.c)))
        {
            var byBucket = buckets.ToDictionary(kv => kv.Key, kv => new ProductionMonthCell(kv.Value.c, kv.Value.ch));
            foreach (var (bucket, cell) in byBucket)
            {
                if (!grandByBucket.TryGetValue(bucket, out var existingGrand))
                    grandByBucket[bucket] = cell;
                else
                    grandByBucket[bucket] = new ProductionMonthCell(existingGrand.ClaimCount + cell.ClaimCount, existingGrand.BilledCharges + cell.BilledCharges);
            }

            panelRows.Add(new UnbilledAgingRow
            {
                PanelName = rowKey,
                ByBucket = byBucket,
                GrandTotalClaims = byBucket.Values.Sum(c => c.ClaimCount),
                GrandTotalCharges = byBucket.Values.Sum(c => c.BilledCharges),
            });
        }

        return new UnbilledAgingResult(panelRows, grandByBucket, grandByBucket.Values.Sum(c => c.ClaimCount), grandByBucket.Values.Sum(c => c.BilledCharges));
    }

    private async Task<CptBreakdownResult> GetCptBreakdownFromStoredProcedureAsync(
        string connectionString,
        string spPrefix,
        List<string>? filterPayerNames,
        List<string>? filterPanelNames,
        DateOnly? filterDosFrom,
        DateOnly? filterDosTo,
        DateOnly? filterFirstBillFrom,
        DateOnly? filterFirstBillTo,
        DateOnly? filterFirstBilledFrom,
        DateOnly? filterFirstBilledTo,
        CancellationToken ct)
    {
        var spName = $"dbo.usp_Get{spPrefix}CPTBreakdown";
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var cmd = new SqlCommand(spName, conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 180,
        };
        AddProductionFilterParameters(cmd, filterPayerNames, filterPanelNames, filterDosFrom, filterDosTo, filterFirstBillFrom, filterFirstBillTo, filterFirstBilledFrom, filterFirstBilledTo);
        await using var rdr = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

        var cptMonth = new Dictionary<string, Dictionary<string, (decimal units, decimal ch, int claims)>>(StringComparer.OrdinalIgnoreCase);
        var allMonths = new SortedSet<string>();

        while (await rdr.ReadAsync(ct).ConfigureAwait(false))
        {
            var cpt = rdr.GetString(0);
            var month = rdr.GetString(1);
            var claimCount = rdr.GetInt32(2);
            var unitsValue = rdr.GetValue(3);
            var units = unitsValue is decimal decimalUnits ? decimalUnits : Convert.ToDecimal(unitsValue, CultureInfo.InvariantCulture);
            var charges = rdr.GetDecimal(4);

            allMonths.Add(month);
            if (!cptMonth.TryGetValue(cpt, out var byMonth))
                cptMonth[cpt] = byMonth = [];

            var previous = byMonth.GetValueOrDefault(month);
            byMonth[month] = (previous.units + units, previous.ch + charges, previous.claims + claimCount);
        }

        var months = allMonths.ToList();
        var years = months.Select(m => int.Parse(m[..4], CultureInfo.InvariantCulture)).Distinct().OrderBy(y => y).ToList();
        var grandByMonth = new Dictionary<string, CptBreakdownCell>();
        var cptRows = new List<CptBreakdownRow>();

        foreach (var (cpt, byMonthValues) in cptMonth.OrderBy(x => x.Key, StringComparer.OrdinalIgnoreCase))
        {
            var byMonth = byMonthValues.ToDictionary(kv => kv.Key, kv => new CptBreakdownCell(kv.Value.units, kv.Value.ch, kv.Value.claims));
            foreach (var (month, cell) in byMonth)
            {
                if (!grandByMonth.TryGetValue(month, out var existingGrand))
                    grandByMonth[month] = cell;
                else
                    grandByMonth[month] = new CptBreakdownCell(existingGrand.Units + cell.Units, existingGrand.BilledCharges + cell.BilledCharges, existingGrand.ClaimCount + cell.ClaimCount);
            }

            cptRows.Add(new CptBreakdownRow
            {
                CptCode = cpt,
                ByMonth = byMonth,
                ByYear = years.ToDictionary(
                    y => y,
                    y =>
                    {
                        var cells = byMonth.Where(kv => kv.Key.StartsWith($"{y:D4}", StringComparison.Ordinal)).Select(kv => kv.Value).ToList();
                        return new CptBreakdownCell(cells.Sum(c => c.Units), cells.Sum(c => c.BilledCharges), cells.Sum(c => c.ClaimCount));
                    }),
                GrandTotalUnits = byMonth.Values.Sum(c => c.Units),
                GrandTotalCharges = byMonth.Values.Sum(c => c.BilledCharges),
                GrandTotalClaims = byMonth.Values.Sum(c => c.ClaimCount),
            });
        }

        return new CptBreakdownResult(
            months,
            years,
            cptRows,
            grandByMonth,
            grandByMonth.Values.Sum(c => c.Units),
            grandByMonth.Values.Sum(c => c.BilledCharges),
            grandByMonth.Values.Sum(c => c.ClaimCount));
    }

    private static bool TryResolveReadStoredProcedurePrefix(string connectionString, string? rule, out string prefix)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        prefix = string.Empty;
        var isRule2 = string.Equals(rule, "Rule2", StringComparison.OrdinalIgnoreCase);
        var isRule3 = string.Equals(rule, "Rule3", StringComparison.OrdinalIgnoreCase);
        var isRule4 = string.Equals(rule, "Rule4", StringComparison.OrdinalIgnoreCase);
        var isRule5 = string.Equals(rule, "Rule5", StringComparison.OrdinalIgnoreCase);

        if (isRule2)
        {
            prefix = CertusPrefix;
            return true;
        }

        if (isRule3)
        {
            prefix = AugustusPrefix;
            return true;
        }

        if (isRule4)
        {
            prefix = NorthWestPrefix;
            return true;
        }

        var builder = new SqlConnectionStringBuilder(connectionString);
        var initialCatalog = builder.InitialCatalog;
        if (string.IsNullOrWhiteSpace(initialCatalog))
            return false;

        prefix = initialCatalog.Trim() switch
        {
            "Rising_Tides" => RisingTidesPrefix,
            "Beech_Tree" => BeechTreePrefix,
            "PCRLabsofAmerica" => PcrPrefix,
            "PCRLOA" => PcrPrefix,
            "CoveLRN" => CovePrefix,
            "Elixir_LRN" => ElixirPrefix,
            "Certus_LRN" => CertusPrefix,
            "Augustus_LRN" => AugustusPrefix,
            "NWL" => NorthWestPrefix,
            _ => string.Empty,
        };

        if (string.IsNullOrEmpty(prefix) && string.Equals(initialCatalog, "Cove", StringComparison.OrdinalIgnoreCase))
            prefix = CovePrefix;
        if (string.IsNullOrEmpty(prefix) && string.Equals(initialCatalog, "Elixir", StringComparison.OrdinalIgnoreCase))
            prefix = ElixirPrefix;
        if (string.IsNullOrEmpty(prefix) && string.Equals(initialCatalog, "Certus", StringComparison.OrdinalIgnoreCase))
            prefix = CertusPrefix;
        if (string.IsNullOrEmpty(prefix) && string.Equals(initialCatalog, "Augustus", StringComparison.OrdinalIgnoreCase))
            prefix = AugustusPrefix;
        if (string.IsNullOrEmpty(prefix) && string.Equals(initialCatalog, "NorthWest", StringComparison.OrdinalIgnoreCase))
            prefix = NorthWestPrefix;
        if (string.IsNullOrEmpty(prefix) && string.Equals(initialCatalog, "RisingTides", StringComparison.OrdinalIgnoreCase))
            prefix = RisingTidesPrefix;

        if (string.IsNullOrEmpty(prefix) && !isRule5)
        {
            if (string.Equals(initialCatalog, "BeechTree", StringComparison.OrdinalIgnoreCase)
                || string.Equals(initialCatalog, "Beech_Tree_LRN", StringComparison.OrdinalIgnoreCase))
            {
                prefix = BeechTreePrefix;
            }
            else if (string.Equals(initialCatalog, "PCR", StringComparison.OrdinalIgnoreCase)
                || initialCatalog.Contains("PCR", StringComparison.OrdinalIgnoreCase))
            {
                prefix = PcrPrefix;
            }
        }

        if (isRule5 && string.IsNullOrEmpty(prefix))
        {
            if (initialCatalog.Contains("Cove", StringComparison.OrdinalIgnoreCase))
                prefix = CovePrefix;
            else if (initialCatalog.Contains("Elixir", StringComparison.OrdinalIgnoreCase))
                prefix = ElixirPrefix;
        }

        return !string.IsNullOrEmpty(prefix);
    }

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
        ArgumentNullException.ThrowIfNull(cmd);

        cmd.Parameters.Add(new SqlParameter("@PayerNames", SqlDbType.NVarChar, -1)
        {
            Value = JoinFilterList(filterPayerNames),
        });
        cmd.Parameters.Add(new SqlParameter("@PanelNames", SqlDbType.NVarChar, -1)
        {
            Value = JoinFilterList(filterPanelNames),
        });
        cmd.Parameters.Add(CreateDateParameter("@DosFrom", filterDosFrom));
        cmd.Parameters.Add(CreateDateParameter("@DosTo", filterDosTo));
        cmd.Parameters.Add(CreateDateParameter("@FirstBillFrom", filterFirstBillFrom));
        cmd.Parameters.Add(CreateDateParameter("@FirstBillTo", filterFirstBillTo));
        cmd.Parameters.Add(CreateDateParameter("@FirstBilledFrom", filterFirstBilledFrom));
        cmd.Parameters.Add(CreateDateParameter("@FirstBilledTo", filterFirstBilledTo));
    }

    private static object JoinFilterList(List<string>? values)
    {
        if (values is null || values.Count == 0)
            return DBNull.Value;

        var cleaned = values
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .Select(v => v.Trim())
            .ToList();

        return cleaned.Count == 0 ? DBNull.Value : string.Join('|', cleaned);
    }

    private static SqlParameter CreateDateParameter(string name, DateOnly? value) =>
        new(name, SqlDbType.Date)
        {
            Value = value.HasValue
                ? value.Value.ToDateTime(TimeOnly.MinValue)
                : DBNull.Value,
        };
}
