using LabMetricsDashboard.Models;
using System.Diagnostics;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Aggregate-table fast-path implementations for <see cref="SqlCollectionSummaryRepository"/>.
/// Reads from the pre-aggregated <c>{prefix}_CS_*</c> snapshot tables produced by the
/// <c>usp_Refresh{prefix}_CS_*</c> stored procedures (Augustus, NorthWest, BeechTree, Certus,
/// Cove, Elixir, PCRLabsofAmerica, RisingTides).
///
/// All methods take a <c>prefix</c> argument (e.g. "NW", "Aug", "BT", ...) and produce
/// the same result shapes as the live counterparts so the controller / view code is
/// unaware of which path was used.
/// </summary>
public sealed partial class SqlCollectionSummaryRepository
{
    // ?? Filter options from aggregate tables (fast path) ?????????????????????
    // The MonthlyClaimVolume snapshot already contains every distinct PanelName and
    // PayerName that appeared in ClaimLevelData, deduplicated by the refresh SP.
    // Reading from the tiny aggregate is orders of magnitude faster than running
    // SELECT DISTINCT across the full ClaimLevelData table.
    public async Task<CollectionFilterOptions> GetFilterOptionsFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);

        var sql = $"""
            SELECT DISTINCT PayerName FROM dbo.{prefix}_CS_InsuranceVsPaymentPct
            WHERE PayerName IS NOT NULL AND LTRIM(RTRIM(PayerName)) <> ''
            ORDER BY PayerName;

            SELECT DISTINCT PanelName FROM dbo.{prefix}_CS_MonthlyClaimVolume
            WHERE PanelName IS NOT NULL AND LTRIM(RTRIM(PanelName)) <> ''
            ORDER BY PanelName;
            """;

        var payerNames = new List<string>();
        var panelNames = new List<string>();
        var sw = Stopwatch.StartNew();

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) payerNames.Add(r.GetString(0));
        await r.NextResultAsync(ct);
        while (await r.ReadAsync(ct)) panelNames.Add(r.GetString(0));

        _logger.LogInformation(
            "CollectionSummary[Aggregate] FilterOptions({Prefix}): payers={P}, panels={N}, {Ms}ms",
            prefix, payerNames.Count, panelNames.Count, sw.ElapsedMilliseconds);

        return new CollectionFilterOptions(payerNames, panelNames);
    }

    // ?? Top 5 Reimbursement % ?????????????????????????????????????????????????
    public async Task<Top5ReimbursementResult> GetTop5ReimbursementFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);

        // NorthWest, Augustus, Phi_Life, PCR, IHD, and Certus route through dedicated read SPs
        // (usp_Get{prefix}_CS_Top5ReimbursementPct). Certus returns AvgPaymentPct AS PaymentPct.
        // If the read SP is not deployed yet (2812/208), fall through to the snapshot table so the
        // Collection Summary page still loads.
        if (string.Equals(prefix, "NW", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Aug", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Phi", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "PCR", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "IHD", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Cert", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "CERT", StringComparison.OrdinalIgnoreCase))
        {
            _logger.LogInformation("CollectionSummary[Aggregate] Top5ReimbursementPct({Prefix}): routing to SP usp_Get{Prefix}_CS_Top5ReimbursementPct", prefix, prefix);
            try
            {
                return await GetTop5ReimbursementViaSpAsync(
                    connectionString, prefix,
                    filterPayerNames: null, filterPanelNames: null,
                    filterFirstBillFrom: null, filterFirstBillTo: null,
                    filterDosFrom: null, filterDosTo: null,
                    filterCheckDateFrom: null, filterCheckDateTo: null,
                    ct).ConfigureAwait(false);
            }
            catch (SqlException ex) when (ex.Number is 2812 or 208)
            {
                _logger.LogWarning(
                    "CollectionSummary[Aggregate] Top5ReimbursementPct({Prefix}): SP/table missing ({Number}); falling back to snapshot table {Prefix}_CS_Top5ReimbursementPct",
                    prefix, ex.Number, prefix);
            }
        }

        _logger.LogInformation("CollectionSummary[Aggregate] Top5ReimbursementPct({Prefix}): reading snapshot table {Prefix}_CS_Top5ReimbursementPct", prefix, prefix);

        // Snapshot tables: PaymentPct (NW/Aug) or AvgPaymentPct (Certus).
        var hasPaymentPctColumn = string.Equals(prefix, "NW", StringComparison.OrdinalIgnoreCase) ||
                                   string.Equals(prefix, "Aug", StringComparison.OrdinalIgnoreCase);
        var hasAvgPaymentPctColumn = string.Equals(prefix, "Cert", StringComparison.OrdinalIgnoreCase) ||
                                      string.Equals(prefix, "CERT", StringComparison.OrdinalIgnoreCase);
        var sql = hasPaymentPctColumn
            ? $"""
              SELECT PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount, PaymentPct
              FROM   dbo.{prefix}_CS_Top5ReimbursementPct
              ORDER  BY PayerRank;
              """
            : hasAvgPaymentPctColumn
            ? $"""
              SELECT PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount, AvgPaymentPct AS PaymentPct
              FROM   dbo.{prefix}_CS_Top5ReimbursementPct
              ORDER  BY PayerRank;
              """
            : $"""
              SELECT PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount
              FROM   dbo.{prefix}_CS_Top5ReimbursementPct
              ORDER  BY PayerRank;
              """;

        var rows = new List<InsuranceReimbursementRow>();
        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            decimal? pct = null;
            if ((hasPaymentPctColumn || hasAvgPaymentPctColumn) && HasColumn(r, "PaymentPct") && !r.IsDBNull(r.GetOrdinal("PaymentPct")))
                pct = Convert.ToDecimal(r.GetValue(r.GetOrdinal("PaymentPct")));

            rows.Add(new InsuranceReimbursementRow(
                Rank:                GetByteOrDefault(r, "PayerRank"),
                PayerName:           r.IsDBNull(r.GetOrdinal("PayerName")) ? string.Empty : Convert.ToString(r.GetValue(r.GetOrdinal("PayerName"))) ?? string.Empty,
                SumInsurancePayment: r.IsDBNull(r.GetOrdinal("SumInsurancePayment")) ? 0m : Convert.ToDecimal(r.GetValue(r.GetOrdinal("SumInsurancePayment"))),
                SumChargeAmount:     r.IsDBNull(r.GetOrdinal("SumChargeAmount")) ? 0m : Convert.ToDecimal(r.GetValue(r.GetOrdinal("SumChargeAmount"))),
                UniqueVisitCount:    r.IsDBNull(r.GetOrdinal("UniqueVisitCount")) ? 0 : Convert.ToInt32(r.GetValue(r.GetOrdinal("UniqueVisitCount"))),
                PaymentPctFromSp:    pct));
        }

        _logger.LogInformation("CollectionSummary[Aggregate] Top5ReimbursementPct({Prefix}): rows={N}, {Ms}ms",
            prefix, rows.Count, sw.ElapsedMilliseconds);
        return new Top5ReimbursementResult(rows);
    }

    // ?? Top 5 Reimbursement Payments ??????????????????????????????????????????
    public async Task<Top5TotalPaymentsResult> GetTop5TotalPaymentsFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);

        // NorthWest, Phi_Life, and PCR route through dedicated read SPs (usp_Get{prefix}_CS_Top5ReimbursementPay),
        // matching every other NorthWest/Phi/PCR Collection Summary tab. The SP returns the
        // snapshot on the no-filter path and aggregates live from ClaimLevelData when filters are supplied.
        if (string.Equals(prefix, "NW", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Aug", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Phi", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "PCR", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "IHD", StringComparison.OrdinalIgnoreCase))
            return await GetTop5TotalPaymentsViaSpAsync(
                connectionString, prefix,
                filterPayerNames: null, filterPanelNames: null,
                filterFirstBillFrom: null, filterFirstBillTo: null,
                filterDosFrom: null, filterDosTo: null,
                filterCheckDateFrom: null, filterCheckDateTo: null,
                ct).ConfigureAwait(false);

        var sql = $"""
            SELECT PayerRank, PayerName, TotalPayments, UniqueVisitCount
            FROM   dbo.{prefix}_CS_Top5ReimbursementPay
            ORDER  BY PayerRank;
            """;

        var rows = new List<InsuranceTotalPaymentRow>();
        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new InsuranceTotalPaymentRow(
                Rank:             GetByteOrDefault(r, "PayerRank"),
                PayerName:        r.GetString(r.GetOrdinal("PayerName")),
                TotalPayments:    r.GetDecimal(r.GetOrdinal("TotalPayments")),
                UniqueVisitCount: r.GetInt32(r.GetOrdinal("UniqueVisitCount"))));
        }

        _logger.LogInformation("CollectionSummary[Aggregate] Top5ReimbursementPay({Prefix}): rows={N}, {Ms}ms",
            prefix, rows.Count, sw.ElapsedMilliseconds);
        return new Top5TotalPaymentsResult(rows);
    }

    // ?? Monthly Claim Volume (pivot built from snapshot) ??????????????????????
    public async Task<CollectionMonthlyVolumeResult> GetCollectionMonthlyVolumeFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);

        _logger.LogInformation("CollectionSummary[Aggregate] MonthlyClaimVolume({Prefix}): entry point", prefix);

        // Labs with a dedicated read SP route through it with all-null filters
        // (@HasFilter = 0 inside the SP → snapshot path).
        if (string.Equals(prefix, "NW",  StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Aug", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Phi", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "PCR", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "IHD", StringComparison.OrdinalIgnoreCase))
        {
            _logger.LogInformation("CollectionSummary[Aggregate] MonthlyClaimVolume({Prefix}): routing to SP usp_Get{Prefix}_CS_MonthlyClaimVolume", prefix, prefix);
            return await GetCollectionMonthlyVolumeViaSpAsync(
                connectionString,
                prefix,
                filterPayerNames: null,
                filterPanelNames: null,
                filterFirstBillFrom: null,
                filterFirstBillTo: null,
                filterDosFrom: null,
                filterDosTo: null,
                filterCheckDateFrom: null,
                filterCheckDateTo: null,
                ct).ConfigureAwait(false);
        }

        _logger.LogInformation("CollectionSummary[Aggregate] MonthlyClaimVolume({Prefix}): reading snapshot table {Prefix}_CS_MonthlyClaimVolume", prefix, prefix);

        var sql = $"""
            SELECT PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment
            FROM   dbo.{prefix}_CS_MonthlyClaimVolume
            ORDER  BY PanelName, PayerRank, BillYear, BillMonth;
            """;

        var raw = new List<CollectionRawPivotRow>();
        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using (var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 })
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                raw.Add(new CollectionRawPivotRow(
                    PanelName:     r.GetString(r.GetOrdinal("PanelName")),
                    PayerName:     r.GetString(r.GetOrdinal("PayerName")),
                    BillYear:      r.GetInt32 (r.GetOrdinal("BillYear")),
                    BillMonth:     GetByteOrDefault(r, "BillMonth"),
                    LineItemCount: r.GetInt32 (r.GetOrdinal("NoOfClaims")),
                    InsurancePaid: r.GetDecimal(r.GetOrdinal("InsurancePayment")),
                    PayerRank:     GetByteOrDefault(r, "PayerRank")));
            }
        }

        _logger.LogInformation("CollectionSummary[Aggregate] MonthlyClaimVolume({Prefix}): raw rows={N}, {Ms}ms",
            prefix, raw.Count, sw.ElapsedMilliseconds);
        return BuildMonthlyVolumePivot(raw);
    }

    // ?? Weekly Claim Volume (pivot built from snapshot) ???????????????????????
    public async Task<CollectionWeeklyVolumeResult> GetCollectionWeeklyVolumeFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);

        // Labs that have a dedicated read SP route through it with all-null filters
        // (@HasFilter = 0 inside the SP → snapshot path). This guarantees that the
        // week labels and anchor date are always driven by SP logic, not duplicated here.
        // ALL labs now have Collection Summary read SPs, so always route through the SP.
        _logger.LogInformation("CollectionSummary[Aggregate] WeeklyClaimVolume({Prefix}): routing to SP usp_Get{Prefix}_CS_WeeklyClaimVolume", prefix, prefix);
        return await GetCollectionWeeklyVolumeViaSpAsync(
            connectionString,
            prefix,
            filterPayerNames: null,
            filterPanelNames: null,
            filterFirstBillFrom: null,
            filterFirstBillTo: null,
            filterDosFrom: null,
            filterDosTo: null,
            filterCheckDateFrom: null,
            filterCheckDateTo: null,
            ct).ConfigureAwait(false);

        // Old direct table read path - kept for reference but unreachable
        // If a lab needs to fall back to direct table reads, add an explicit condition above
        #pragma warning disable CS0162 // Unreachable code detected
        _logger.LogInformation("CollectionSummary[Aggregate] WeeklyClaimVolume({Prefix}): reading snapshot table {Prefix}_CS_WeeklyClaimVolume", prefix, prefix);
        var sql = $"""
            SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment
            FROM   dbo.{prefix}_CS_WeeklyClaimVolume
            ORDER  BY PanelName, PayerRank, WeekKey;
            """;

        var rows = new List<(string Panel, string Payer, byte PayerRank, byte Week, DateTime Start, DateTime End, int Claims, decimal Paid)>();
        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using (var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 })
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                rows.Add((
                    r.GetString(r.GetOrdinal("PanelName")),
                    r.GetString(r.GetOrdinal("PayerName")),
                    GetByteOrDefault(r, "PayerRank"),
                    GetByteOrDefault(r, "WeekKey"),
                    r.GetDateTime(r.GetOrdinal("WeekStart")),
                    r.GetDateTime(r.GetOrdinal("WeekEnd")),
                    r.GetInt32 (r.GetOrdinal("NoOfClaims")),
                    r.GetDecimal(r.GetOrdinal("InsurancePayment"))));
            }
        }

        _logger.LogInformation("CollectionSummary[Aggregate] WeeklyClaimVolume({Prefix}): raw rows={N}, {Ms}ms",
            prefix, rows.Count, sw.ElapsedMilliseconds);
        return BuildWeeklyVolumePivotFromAggregate(rows);
    }

    // ?? Panel Averages (flat per panel + payer) ???????????????????????????????
    // Schema for {prefix}_CS_PanelAverages:
    //   ClaimCount, TotalCharges, CarrierPayment,
    //   FullyPaidCount, FullyPaidAmount, Days30Count/Amount, Days60Count/Amount
    //   (Adjudicated columns present only on labs that opted in, e.g. NW)
    public async Task<PanelAveragesResult> GetPanelAveragesFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        // Try the SP first; fall back to direct snapshot table read if SP is not yet deployed.
        try
        {
            return await GetPanelAveragesViaSpAsync(
                connectionString,
                $"dbo.usp_Get{prefix}_CS_PanelAverages",
                filterPayerNames: null, filterPanelNames: null,
                filterFirstBillFrom: null, filterFirstBillTo: null,
                filterDosFrom: null, filterDosTo: null,
                filterCheckDateFrom: null, filterCheckDateTo: null,
                ct).ConfigureAwait(false);
        }
        catch (SqlException ex) when (ex.Number == 2812) // SP not yet deployed
        {
            _logger.LogWarning(
                "CollectionSummary PanelAverages({Prefix}): SP not found ({Sp}), falling back to direct table read.",
                prefix, $"usp_Get{prefix}_CS_PanelAverages");
            return await ReadPanelAveragesAsync(
                connectionString, $"{prefix}_CS_PanelAverages", prefix, "PanelAverages",
                claimCountCol: "NoOfClaims",
                carrierPayCol: "CarrierPayment",
                days30CountCol: "Days30Count", days30AmtCol: "Days30Amount",
                days60CountCol: "Days60Count", days60AmtCol: "Days60Amount",
                ct);
        }
    }

    // Schema for {prefix}_CS_AvgPayments (different column names!):
    //   ClaimCount, TotalCharges, InsurancePayment (carrier),
    //   FullyPaidCount, FullyPaidAmount, AdjudicatedCount/Amount,
    //   Over30Count/Amount, Over60Count/Amount
    public async Task<PanelAveragesResult> GetAvgPaymentsFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        // Try the SP first; fall back to direct snapshot table read if SP is not yet deployed.
        try
        {
            return await GetAvgPaymentsViaSpAsync(
                connectionString,
                $"dbo.usp_Get{prefix}_CS_AvgPayments",
                filterPayerNames: null, filterPanelNames: null,
                filterFirstBillFrom: null, filterFirstBillTo: null,
                filterDosFrom: null, filterDosTo: null,
                filterCheckDateFrom: null, filterCheckDateTo: null,
                ct).ConfigureAwait(false);
        }
        catch (SqlException ex) when (ex.Number == 2812) // SP not yet deployed
        {
            _logger.LogWarning(
                "CollectionSummary AvgPayments({Prefix}): SP not found ({Sp}), falling back to direct table read.",
                prefix, $"usp_Get{prefix}_CS_AvgPayments");
            return await ReadPanelAveragesAsync(
                connectionString, $"{prefix}_CS_AvgPayments", prefix, "AvgPayments",
                claimCountCol: "ClaimCount",
                carrierPayCol: "InsurancePayment",
                days30CountCol: "Over30Count", days30AmtCol: "Over30Amount",
                days60CountCol: "Over60Count", days60AmtCol: "Over60Amount",
                ct);
        }
    }

    /// <summary>
    /// Reads a panel-averages style snapshot table and rolls up per-panel totals.
    /// Both <c>*_CS_PanelAverages</c> and <c>*_CS_AvgPayments</c> share the same
    /// shape (panel + payer + claim metrics) but use different column names; the
    /// caller supplies the column map. Adjudicated columns are read when present,
    /// defaulted to 0 otherwise (we detect via SQL error 207 and re-issue).
    /// </summary>
    private async Task<PanelAveragesResult> ReadPanelAveragesAsync(
        string connectionString, string tableName, string prefix, string tag,
        string claimCountCol, string carrierPayCol,
        string days30CountCol, string days30AmtCol,
        string days60CountCol, string days60AmtCol,
        CancellationToken ct)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(tableName);
        tableName = SafeSqlIdentifier(tableName);
        claimCountCol = SafePanelAveragesColumn(claimCountCol);
        carrierPayCol = SafePanelAveragesColumn(carrierPayCol);
        days30CountCol = SafePanelAveragesColumn(days30CountCol);
        days30AmtCol = SafePanelAveragesColumn(days30AmtCol);
        days60CountCol = SafePanelAveragesColumn(days60CountCol);
        days60AmtCol = SafePanelAveragesColumn(days60AmtCol);

        string BuildSql(bool withAdj)
        {
            var adjSelect = withAdj
                ? "AdjudicatedCount AS AdjudicatedCount, AdjudicatedAmount AS AdjudicatedAmount"
                : "0 AS AdjudicatedCount, CAST(0 AS DECIMAL(18,2)) AS AdjudicatedAmount";
            return $"""
                SELECT PanelName, PayerName,
                       {claimCountCol}  AS NoOfClaims,
                       TotalCharges,
                       {carrierPayCol}  AS CarrierPayment,
                       FullyPaidCount, FullyPaidAmount,
                       {adjSelect},
                       {days30CountCol} AS Days30Count, {days30AmtCol} AS Days30Amount,
                       {days60CountCol} AS Days60Count, {days60AmtCol} AS Days60Amount
                FROM   dbo.{tableName}
                ORDER  BY PanelName, PayerName;
                """;
        }

        var grouped = new Dictionary<string, List<(string Payer, PanelAveragesMetrics M)>>(StringComparer.OrdinalIgnoreCase);

        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        async Task ReadAsync(string s)
        {
            await using var cmd = new SqlCommand(s, conn) { CommandTimeout = 60 };
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                var panel = r.GetString(r.GetOrdinal("PanelName"));
                var payer = r.GetString(r.GetOrdinal("PayerName"));
                var metrics = new PanelAveragesMetrics(
                    ClaimCount:        r.GetInt32  (r.GetOrdinal("NoOfClaims")),
                    TotalCharges:      r.GetDecimal(r.GetOrdinal("TotalCharges")),
                    CarrierPayment:    r.GetDecimal(r.GetOrdinal("CarrierPayment")),
                    FullyPaidCount:    r.GetInt32  (r.GetOrdinal("FullyPaidCount")),
                    FullyPaidAmount:   r.GetDecimal(r.GetOrdinal("FullyPaidAmount")),
                    AdjudicatedCount:  Convert.ToInt32  (r.GetValue(r.GetOrdinal("AdjudicatedCount"))),
                    AdjudicatedAmount: Convert.ToDecimal(r.GetValue(r.GetOrdinal("AdjudicatedAmount"))),
                    Days30Count:       r.GetInt32  (r.GetOrdinal("Days30Count")),
                    Days30Amount:      r.GetDecimal(r.GetOrdinal("Days30Amount")),
                    Days60Count:       r.GetInt32  (r.GetOrdinal("Days60Count")),
                    Days60Amount:      r.GetDecimal(r.GetOrdinal("Days60Amount")));

                if (!grouped.TryGetValue(panel, out var list))
                    grouped[panel] = list = [];
                list.Add((payer, metrics));
            }
        }

        try
        {
            await ReadAsync(BuildSql(withAdj: true));
        }
        catch (SqlException ex) when (ex.Number == 207) // Invalid column name (Adjudicated*)
        {
            grouped.Clear();
            await ReadAsync(BuildSql(withAdj: false));
        }

        var panelRows = new List<PanelAveragesRow>();
        foreach (var (panelName, payerList) in grouped)
        {
            // Roll up the panel-level metrics by summing across payers
            var rolled = payerList.Aggregate(
                new PanelAveragesMetrics(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
                (acc, p) => new PanelAveragesMetrics(
                    acc.ClaimCount        + p.M.ClaimCount,
                    acc.TotalCharges      + p.M.TotalCharges,
                    acc.CarrierPayment    + p.M.CarrierPayment,
                    acc.FullyPaidCount    + p.M.FullyPaidCount,
                    acc.FullyPaidAmount   + p.M.FullyPaidAmount,
                    acc.AdjudicatedCount  + p.M.AdjudicatedCount,
                    acc.AdjudicatedAmount + p.M.AdjudicatedAmount,
                    acc.Days30Count       + p.M.Days30Count,
                    acc.Days30Amount      + p.M.Days30Amount,
                    acc.Days60Count       + p.M.Days60Count,
                    acc.Days60Amount      + p.M.Days60Amount));

            panelRows.Add(new PanelAveragesRow
            {
                PanelName = panelName,
                Metrics   = rolled,
                Payers    = [.. payerList.Select(p => new PanelAveragesPayerRow
                {
                    PayerName = p.Payer,
                    Metrics   = p.M,
                })],
            });
        }

        panelRows.Sort((a, b) => b.Metrics.ClaimCount.CompareTo(a.Metrics.ClaimCount));

        _logger.LogInformation("CollectionSummary[Aggregate] {Tag}({Prefix}): panels={N}, {Ms}ms",
            tag, prefix, panelRows.Count, sw.ElapsedMilliseconds);
        return new PanelAveragesResult(panelRows);
    }

    // ?? Insurance vs Aging (flat ? pivot per payer) ???????????????????????????
    public async Task<InsuranceAgingResult> GetInsuranceAgingFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);

        // Prefer the read SP. Fall back to the snapshot table when the SP has not been
        // deployed yet; this keeps localhost and partially-updated lab DBs usable.
        try
        {
            return await GetInsuranceAgingViaSpAsync(
                connectionString,
                CollectionGetSp(prefix, "CS_InsuranceVsAging"),
                filterPayerNames: null, filterPanelNames: null,
                filterFirstBillFrom: null, filterFirstBillTo: null,
                filterDosFrom: null, filterDosTo: null,
                filterCheckDateFrom: null, filterCheckDateTo: null,
                ct).ConfigureAwait(false);
        }
        catch (SqlException ex) when (ex.Number == 2812) // stored procedure not found
        {
            _logger.LogWarning(
                "CollectionSummary InsuranceVsAging({Prefix}): read SP not found, falling back to {Table} snapshot table.",
                prefix, $"{prefix}_CS_InsuranceVsAging");
            return await GetInsuranceAgingFromSnapshotTableAsync(connectionString, prefix, ct).ConfigureAwait(false);
        }
    }

    private async Task<InsuranceAgingResult> GetInsuranceAgingFromSnapshotTableAsync(
        string connectionString, string prefix, CancellationToken ct)
    {
        // Snapshot tables differ in the count column name: NW/BT use VisitCount,
        // Augustus uses ClaimCount. Select * and resolve the ordinal from the schema.
        var sql = $"""
            SELECT *
            FROM   dbo.{prefix}_CS_InsuranceVsAging
            ORDER  BY PayerName, AgingBucket;
            """;

        var perPayer = new Dictionary<string, (string Source, string Payer, Dictionary<string, (int Cnt, decimal Bal)> Buckets)>(
            StringComparer.OrdinalIgnoreCase);
        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        var cntOrdinal = -1;
        var hasSource = false;
        while (await r.ReadAsync(ct))
        {
            if (cntOrdinal < 0)
            {
                cntOrdinal = HasColumn(r, "VisitCount") ? r.GetOrdinal("VisitCount")
                           : HasColumn(r, "ClaimCount") ? r.GetOrdinal("ClaimCount")
                           : throw new InvalidOperationException(
                               $"Snapshot table '{prefix}_CS_InsuranceVsAging' has neither 'VisitCount' nor 'ClaimCount'.");
                hasSource = HasColumn(r, "Source");
            }

            var payer = GetStringOrEmpty(r, "PayerName");
            if (string.IsNullOrWhiteSpace(payer)) continue;
            var source = hasSource ? GetStringOrEmpty(r, "Source") : string.Empty;
            var bucket = NormalizeAgingBucketForSnapshot(GetStringOrEmpty(r, "AgingBucket"));
            var cnt = r.IsDBNull(cntOrdinal) ? 0 : Convert.ToInt32(r.GetValue(cntOrdinal));
            var bal = GetDecimalOrDefault(r, "InsuranceBalance");

            var key = $"{source}\u0001{payer}";
            if (!perPayer.TryGetValue(key, out var entry))
                perPayer[key] = entry = (source, payer, new Dictionary<string, (int, decimal)>(StringComparer.OrdinalIgnoreCase));
            entry.Buckets[bucket] = (cnt, bal);
        }

        static (int c, decimal b) Get(Dictionary<string, (int, decimal)> d, string key)
            => d.TryGetValue(key, out var v) ? v : (0, 0m);

        var rows = perPayer.Values.Select(entry =>
        {
            var (cur, bCur) = Get(entry.Buckets, "Current");
            var (b30, x30) = Get(entry.Buckets, "30 Days");
            var (b60, x60) = Get(entry.Buckets, "60 Days");
            var (b90, x90) = Get(entry.Buckets, "90 Days");
            var (b120, x120) = Get(entry.Buckets, "120+ Days");
            return new InsuranceAgingRow(
                PayerName: entry.Payer,
                ClaimsCurrent: cur, BalanceCurrent: bCur,
                Claims30: b30, Balance30: x30,
                Claims60: b60, Balance60: x60,
                Claims90: b90, Balance90: x90,
                Claims120: b120, Balance120: x120,
                ClaimsTotal: cur + b30 + b60 + b90 + b120,
                BalanceTotal: bCur + x30 + x60 + x90 + x120,
                Source: entry.Source);
        })
        .OrderBy(row => row.Source, StringComparer.OrdinalIgnoreCase)
        .ThenByDescending(row => row.BalanceTotal)
        .ToList();

        _logger.LogInformation("CollectionSummary[Aggregate] InsuranceVsAging({Prefix}) snapshot fallback: rows={N}, {Ms}ms",
            prefix, rows.Count, sw.ElapsedMilliseconds);

        return new InsuranceAgingResult(rows);
    }

    private static string NormalizeAgingBucketForSnapshot(string bucket) => bucket.Trim() switch
    {
        "30+" or "30" or "30 Days" => "30 Days",
        "60+" or "60" or "60 Days" => "60 Days",
        "90+" or "90" or "90 Days" => "90 Days",
        "120+" or "120" or "120+ Days" => "120+ Days",
        "Current" => "Current",
        var value => value
    };

    // ?? Panel vs Payment ??????????????????????????????????????????????????????
    public async Task<PanelPaymentResult> GetPanelPaymentFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);

        if (string.Equals(prefix, "NW", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Aug", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Phi", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "PCR", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "IHD", StringComparison.OrdinalIgnoreCase))
            return await GetPanelPaymentViaSpAsync(
                connectionString,
                CollectionGetSp(prefix, "CS_PanelVsPayment"),
                filterPayerNames: null, filterPanelNames: null,
                filterFirstBillFrom: null, filterFirstBillTo: null,
                filterDosFrom: null, filterDosTo: null,
                filterCheckDateFrom: null, filterCheckDateTo: null,
                ct).ConfigureAwait(false);

        // Elixir/Cove/BT/Cert snapshots store per-month rows (PanelName, BilledYear, BilledMonth) so the UI
        // can pivot Year/Month. Other labs keep a flat panel-level row.
        bool hasMonthlyGrain = string.Equals(prefix, "Elix", StringComparison.OrdinalIgnoreCase)
            || string.Equals(prefix, "Cove", StringComparison.OrdinalIgnoreCase)
            || string.Equals(prefix, "BT",   StringComparison.OrdinalIgnoreCase)
            || string.Equals(prefix, "Cert", StringComparison.OrdinalIgnoreCase);
        string sql = hasMonthlyGrain
            ? $"""
                SELECT PanelName,
                       BilledYear,
                       BilledMonth,
                       NoOfClaims,
                       InsurancePayment AS InsurancePayments
                FROM   dbo.{prefix}_CS_PanelVsPayment
                ORDER  BY PanelName, BilledYear, BilledMonth;
                """
            : $"""
                SELECT PanelName,
                       SUM(NoOfClaims)       AS NoOfClaims,
                       SUM(InsurancePayment) AS InsurancePayments
                FROM   dbo.{prefix}_CS_PanelVsPayment
                GROUP  BY PanelName
                ORDER  BY SUM(InsurancePayment) DESC;
                """;

        var rows = new List<PanelPaymentRow>();
        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new PanelPaymentRow(
                PanelName:         r.GetString(r.GetOrdinal("PanelName")),
                NoOfClaims:        r.GetInt32 (r.GetOrdinal("NoOfClaims")),
                InsurancePayments: r.GetDecimal(r.GetOrdinal("InsurancePayments")),
                BillYear:          hasMonthlyGrain ? r.GetInt32(r.GetOrdinal("BilledYear")) : 0,
                BillMonth:         hasMonthlyGrain ? Convert.ToInt32(r.GetValue(r.GetOrdinal("BilledMonth"))) : 0));
        }

        _logger.LogInformation("CollectionSummary[Aggregate] PanelVsPayment({Prefix}): rows={N}, {Ms}ms",
            prefix, rows.Count, sw.ElapsedMilliseconds);
        return new PanelPaymentResult(rows);
    }

    // ?? Rep vs Payment (one row per rep � year � month) ??????????????????????
    public async Task<RepPaymentResult> GetRepPaymentFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);

        if (string.Equals(prefix, "NW", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Phi", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "PCR", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "IHD", StringComparison.OrdinalIgnoreCase))
            return await GetRepPaymentViaSpAsync(
                connectionString,
                $"dbo.usp_Get{prefix}_CS_RepVsPayment",
                filterPayerNames: null, filterPanelNames: null,
                filterFirstBillFrom: null, filterFirstBillTo: null,
                filterDosFrom: null, filterDosTo: null,
                filterCheckDateFrom: null, filterCheckDateTo: null,
                ct).ConfigureAwait(false);

        var sql = $"""
            SELECT SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment
            FROM   dbo.{prefix}_CS_RepVsPayment
            ORDER  BY SalesRepName, CheckYear, CheckMonth;
            """;

        var rows = new List<RepPaymentFlatRow>();
        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new RepPaymentFlatRow(
                SalesRepName:      r.GetString(r.GetOrdinal("SalesRepName")),
                Year:              r.GetInt32 (r.GetOrdinal("CheckYear")),
                Month:             r.GetByte  (r.GetOrdinal("CheckMonth")),
                NoOfClaims:        r.GetInt32 (r.GetOrdinal("NoOfClaims")),
                InsurancePayments: r.GetDecimal(r.GetOrdinal("InsurancePayment"))));
        }

        _logger.LogInformation("CollectionSummary[Aggregate] RepVsPayment({Prefix}): rows={N}, {Ms}ms",
            prefix, rows.Count, sw.ElapsedMilliseconds);
        return new RepPaymentResult(rows);
    }

    // ?? Insurance vs Payment % ????????????????????????????????????????????????
    public async Task<InsurancePaymentPctResult> GetInsurancePaymentPctFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);

        if (string.Equals(prefix, "NW", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Aug", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Phi", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "PCR", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "IHD", StringComparison.OrdinalIgnoreCase))
            return await GetInsurancePaymentPctViaSpAsync(
                connectionString,
                CollectionGetSp(prefix, "CS_InsuranceVsPaymentPct"),
                filterPayerNames: null, filterPanelNames: null,
                filterFirstBillFrom: null, filterFirstBillTo: null,
                filterDosFrom: null, filterDosTo: null,
                filterCheckDateFrom: null, filterCheckDateTo: null,
                ct).ConfigureAwait(false);

        // Newer Northwest snapshots include month grain and additional count fields.
        // Older lab snapshots use either NoOfPaidClaims or PanelGroupCount as the count column.
        var sqlNew = $"""
            SELECT SummaryId, PayerName, PanelGroupCount, NoOfPaidClaims, InsurancePayment,
                   PaymentPct, RefreshedAt, BillYear, BillMonth
            FROM   dbo.{prefix}_CS_InsuranceVsPaymentPct
            ORDER  BY BillYear DESC, BillMonth DESC, InsurancePayment DESC;
            """;
        var sqlA = $"""
            SELECT PayerName, NoOfPaidClaims AS NoOfClaims, InsurancePayment, PaymentPct
            FROM   dbo.{prefix}_CS_InsuranceVsPaymentPct
            ORDER  BY InsurancePayment DESC;
            """;
        var sqlB = $"""
            SELECT PayerName, PanelGroupCount AS NoOfClaims, InsurancePayment, PaymentPct
            FROM   dbo.{prefix}_CS_InsuranceVsPaymentPct
            ORDER  BY InsurancePayment DESC;
            """;

        var rows = new List<InsurancePaymentPctRow>();
        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        async Task ReadAsync(string s)
        {
            await using var cmd = new SqlCommand(s, conn) { CommandTimeout = 60 };
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                static int? GetNullableInt(SqlDataReader reader, string columnName)
                {
                    var ordinal = reader.GetOrdinal(columnName);
                    return reader.IsDBNull(ordinal) ? null : Convert.ToInt32(reader.GetValue(ordinal));
                }

                static DateTime? GetNullableDateTime(SqlDataReader reader, string columnName)
                {
                    var ordinal = reader.GetOrdinal(columnName);
                    return reader.IsDBNull(ordinal) ? null : reader.GetDateTime(ordinal);
                }

                var payer  = r.GetString(r.GetOrdinal("PayerName"));
                var insPay = r.GetDecimal(r.GetOrdinal("InsurancePayment"));
                var pct    = r.GetDecimal(r.GetOrdinal("PaymentPct"));

                int? summaryId = null;
                int? panelGroupCount = null;
                int? noOfPaidClaims = null;
                DateTime? refreshedAt = null;
                int? billYear = null;
                int? billMonth = null;
                int claims;

                if (ColumnExists(r, "NoOfClaims"))
                {
                    claims = r.GetInt32(r.GetOrdinal("NoOfClaims"));
                }
                else
                {
                    summaryId = GetNullableInt(r, "SummaryId");
                    panelGroupCount = GetNullableInt(r, "PanelGroupCount");
                    noOfPaidClaims = GetNullableInt(r, "NoOfPaidClaims");
                    refreshedAt = GetNullableDateTime(r, "RefreshedAt");
                    billYear = GetNullableInt(r, "BillYear");
                    billMonth = GetNullableInt(r, "BillMonth");
                    claims = noOfPaidClaims ?? panelGroupCount ?? 0;
                }

                // Snapshot stores PaymentPct directly. Back-compute Paid Charge so the
                // record's derived PaymentPct property equals the snapshot value.
                decimal paidChg = pct > 0 ? Math.Round(insPay * 100m / pct, 2) : 0m;

                rows.Add(new InsurancePaymentPctRow(
                    SummaryId:            summaryId,
                    PayerName:            payer,
                    TotalClaims:          claims,
                    InsurancePayments:    insPay,
                    PaidInsurancePayment: insPay,
                    PaidChargeAmount:     paidChg,
                    PanelGroupCount:      panelGroupCount,
                    NoOfPaidClaims:       noOfPaidClaims,
                    RefreshedAt:          refreshedAt,
                    BillYear:             billYear,
                    BillMonth:            billMonth,
                    SnapshotPaymentPct:   pct));
            }
        }

        static bool ColumnExists(SqlDataReader reader, string columnName)
        {
            for (var i = 0; i < reader.FieldCount; i++)
            {
                if (string.Equals(reader.GetName(i), columnName, StringComparison.OrdinalIgnoreCase))
                    return true;
            }

            return false;
        }

        try
        {
            await ReadAsync(sqlNew);
        }
        catch (SqlException ex) when (ex.Number == 207)
        {
            rows.Clear();
            try
            {
                await ReadAsync(sqlA);
            }
            catch (SqlException ex2) when (ex2.Number == 207)
            {
                rows.Clear();
                await ReadAsync(sqlB);
            }
        }

        _logger.LogInformation("CollectionSummary[Aggregate] InsuranceVsPaymentPct({Prefix}): rows={N}, {Ms}ms",
            prefix, rows.Count, sw.ElapsedMilliseconds);
        return new InsurancePaymentPctResult(rows);
    }

    // ?? Insurance Vs Payment (live SP fallback) ??????????????????????????????????
    /// <summary>
    /// Reads Insurance vs Payment data via <c>usp_Get{prefix}_CS_InsuranceVsPayment</c>.
    /// Used as a fallback when the snapshot table does not exist.
    /// </summary>
    private async Task<List<InsuranceVsPaymentRow>> GetInsuranceVsPaymentViaSpAsync(
        string connectionString, string prefix,
        List<string>? filterPayerNames, List<string>? filterPanelNames,
        DateOnly? filterFirstBillFrom, DateOnly? filterFirstBillTo,
        DateOnly? filterDosFrom, DateOnly? filterDosTo,
        DateOnly? filterCheckDateFrom, DateOnly? filterCheckDateTo,
        CancellationToken ct)
    {
        var spName = CollectionGetSp(prefix, "CS_InsuranceVsPayment");
        var rows = new List<InsuranceVsPaymentRow>();
        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(spName, conn)
        {
            CommandType = System.Data.CommandType.StoredProcedure,
            CommandTimeout = 120
        };
        cmd.Parameters.AddRange(BuildCollectionReadSpParameters(
            filterPayerNames, filterPanelNames,
            filterFirstBillFrom, filterFirstBillTo,
            filterDosFrom, filterDosTo,
            filterCheckDateFrom, filterCheckDateTo));
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new InsuranceVsPaymentRow(
                PayerName:        r.GetString (r.GetOrdinal("PayerName")),
                BillYear:         Convert.ToInt32(r.GetValue(r.GetOrdinal("BillYear"))),
                BillMonth:        Convert.ToInt32(r.GetValue(r.GetOrdinal("BillMonth"))),
                NoOfPaidClaims:   Convert.ToInt32(r.GetValue(r.GetOrdinal("NoOfPaidClaims"))),
                InsurancePayment: r.GetDecimal(r.GetOrdinal("InsurancePayment")),
                PaymentPct:       r.GetDecimal(r.GetOrdinal("PaymentPct"))));
        }
        _logger.LogInformation("CollectionSummary[SP] {Sp}: rows={N}, {Ms}ms", spName, rows.Count, sw.ElapsedMilliseconds);
        return rows;
    }

    // ?? Insurance Vs Payment (Payer � Year/Month snapshot pivot) ?????????????
    // Reads from dbo.{prefix}_CS_InsuranceVsPayment. The table is optional: a missing
    // table (SQL error 208 "invalid object name") falls back to the live SP, and an
    // empty result set shows "data not available" in the view.
    public async Task<List<InsuranceVsPaymentRow>> GetInsuranceVsPaymentFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);

        // NorthWest, Phi_Life, and PCR route through dedicated read SPs (usp_Get{prefix}_CS_InsuranceVsPayment),
        // matching every other NorthWest/Phi/PCR Collection Summary tab. The SP returns the
        // snapshot on the no-filter path and aggregates live from ClaimLevelData when filters are supplied.
        if (string.Equals(prefix, "NW", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Aug", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Phi", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "PCR", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "IHD", StringComparison.OrdinalIgnoreCase))
            return await GetInsuranceVsPaymentViaSpAsync(
                connectionString, prefix,
                filterPayerNames: null, filterPanelNames: null,
                filterFirstBillFrom: null, filterFirstBillTo: null,
                filterDosFrom: null, filterDosTo: null,
                filterCheckDateFrom: null, filterCheckDateTo: null,
                ct).ConfigureAwait(false);

        var rows = new List<InsuranceVsPaymentRow>();
        var sql = $"""
            SELECT PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct
            FROM   dbo.{prefix}_CS_InsuranceVsPayment
            ORDER  BY BillYear, BillMonth, InsurancePayment DESC;
            """;

        var sw = Stopwatch.StartNew();
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                rows.Add(new InsuranceVsPaymentRow(
                    PayerName:        r.GetString(r.GetOrdinal("PayerName")),
                    BillYear:         Convert.ToInt32(r.GetValue(r.GetOrdinal("BillYear"))),
                    BillMonth:        Convert.ToInt32(r.GetValue(r.GetOrdinal("BillMonth"))),
                    NoOfPaidClaims:   Convert.ToInt32(r.GetValue(r.GetOrdinal("NoOfPaidClaims"))),
                    InsurancePayment: r.GetDecimal(r.GetOrdinal("InsurancePayment")),
                    PaymentPct:       r.GetDecimal(r.GetOrdinal("PaymentPct"))));
            }
        }
        catch (SqlException ex) when (ex.Number == 208)
        {
            // Snapshot table does not exist for this lab � fall back to the live SP.
            // usp_Get{prefix}_CS_InsuranceVsPayment aggregates live from ClaimLevelData.
            _logger.LogInformation(
                "CollectionSummary[Aggregate] InsuranceVsPayment({Prefix}): snapshot table not found, falling back to live SP.",
                prefix);
            try
            {
                return await GetInsuranceVsPaymentViaSpAsync(
                    connectionString, prefix,
                    filterPayerNames: null, filterPanelNames: null,
                    filterFirstBillFrom: null, filterFirstBillTo: null,
                    filterDosFrom: null, filterDosTo: null,
                    filterCheckDateFrom: null, filterCheckDateTo: null,
                    ct).ConfigureAwait(false);
            }
            catch (Exception spEx)
            {
                _logger.LogWarning(spEx,
                    "CollectionSummary[Aggregate] InsuranceVsPayment({Prefix}) SP fallback failed; returning empty.",
                    prefix);
                return [];
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex,
                "CollectionSummary[Aggregate] InsuranceVsPayment({Prefix}) failed; returning empty.",
                prefix);
            return [];
        }

        _logger.LogInformation("CollectionSummary[Aggregate] InsuranceVsPayment({Prefix}): rows={N}, {Ms}ms",
            prefix, rows.Count, sw.ElapsedMilliseconds);
        return rows;
    }

    // ?? CPT vs Payment % ??????????????????????????????????????????????????????
    public async Task<CptPaymentPctResult> GetCptPaymentPctFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);

        if (string.Equals(prefix, "NW", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Phi", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "PCR", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "IHD", StringComparison.OrdinalIgnoreCase))
            return await GetCptPaymentPctViaSpAsync(
                connectionString,
                $"dbo.usp_Get{prefix}_CS_CptVsPaymentPct",
                filterPayerNames: null, filterPanelNames: null,
                filterFirstBillFrom: null, filterFirstBillTo: null,
                filterDosFrom: null, filterDosTo: null,
                filterCheckDateFrom: null, filterCheckDateTo: null,
                ct).ConfigureAwait(false);

        var sql = $"""
            SELECT CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct
            FROM   dbo.{prefix}_CS_CptVsPaymentPct
            ORDER  BY SumUnits DESC;
            """;

        var rows = new List<CptPaymentPctRow>();
        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            // Use the pre-computed PaymentPct from the aggregate table directly.
            // PaidInsurancePayment / PaidChargeAmount can both be 0 in the snapshot
            // while PaymentPct still holds the correct value.
            var snapshotPct = r.IsDBNull(r.GetOrdinal("PaymentPct"))
                ? (decimal?)null
                : r.GetDecimal(r.GetOrdinal("PaymentPct"));

            rows.Add(new CptPaymentPctRow(
                CptCode:              r.GetString (r.GetOrdinal("CPTCode")),
                SumServiceUnits:      r.GetDecimal(r.GetOrdinal("SumUnits")),
                PaidInsurancePayment: r.GetDecimal(r.GetOrdinal("PaidInsurancePayment")),
                PaidChargeAmount:     r.GetDecimal(r.GetOrdinal("PaidChargeAmount")),
                SnapshotPaymentPct:   snapshotPct));
        }

        _logger.LogInformation("CollectionSummary[Aggregate] CptVsPaymentPct({Prefix}): rows={N}, {Ms}ms",
            prefix, rows.Count, sw.ElapsedMilliseconds);
        return new CptPaymentPctResult(rows);
    }

    // ?? Status Summary (build 3-level hierarchy from flat rows) ???????????????
    public async Task<StatusSummaryResult> GetStatusSummaryFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);

        if (string.Equals(prefix, "NW", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Phi", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "PCR", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "IHD", StringComparison.OrdinalIgnoreCase))
            return await GetStatusSummaryViaSpAsync(
                connectionString,
                $"dbo.usp_Get{prefix}_CS_StatusSummary",
                filterPayerNames: null, filterPanelNames: null,
                filterFirstBillFrom: null, filterFirstBillTo: null,
                filterDosFrom: null, filterDosTo: null,
                filterCheckDateFrom: null, filterCheckDateTo: null,
                ct).ConfigureAwait(false);

        var sql = $"""
            SELECT ClaimStatus, PanelName, CptCode, PayerName,
                   NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance
            FROM   dbo.{prefix}_CS_StatusSummary;
            """;

        var flat = new List<(string Status, string Panel, string Cpt, string Payer,
                             int N, decimal IP, decimal IB, decimal PB)>();

        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using (var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 })
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                flat.Add((
                    r.GetString(r.GetOrdinal("ClaimStatus")),
                    r.GetString(r.GetOrdinal("PanelName")),
                    r.GetString(r.GetOrdinal("CptCode")),
                    r.GetString(r.GetOrdinal("PayerName")),
                    r.GetInt32 (r.GetOrdinal("NoOfClaims")),
                    r.GetDecimal(r.GetOrdinal("InsurancePayment")),
                    r.GetDecimal(r.GetOrdinal("InsuranceBalance")),
                    r.GetDecimal(r.GetOrdinal("PatientBalance"))));
            }
        }

        _logger.LogInformation("CollectionSummary[Aggregate] StatusSummary({Prefix}): raw rows={N}, {Ms}ms",
            prefix, flat.Count, sw.ElapsedMilliseconds);
        return BuildStatusSummaryHierarchy(flat);
    }

    // ?? Provider Summary ??????????????????????????????????????????????????????
    public async Task<ProviderSummaryResult> GetProviderSummaryFromAggregatesAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);

        if (string.Equals(prefix, "NW", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "Phi", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "PCR", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(prefix, "IHD", StringComparison.OrdinalIgnoreCase))
            return await GetProviderSummaryViaSpAsync(
                connectionString,
                $"dbo.usp_Get{prefix}_CS_ProviderSummary",
                filterPayerNames: null, filterPanelNames: null,
                filterFirstBillFrom: null, filterFirstBillTo: null,
                filterDosFrom: null, filterDosTo: null,
                filterCheckDateFrom: null, filterCheckDateTo: null,
                ct).ConfigureAwait(false);

        // Prefer InsurancePayment; fall back to legacy ProcTotalPayment if present.
        var sqlA = $"""
            SELECT ProviderRank, ReferringProvider, NoOfClaims,
                   InsurancePayment AS InsurancePayments,
                   InsuranceBalance, PatientBalance
            FROM   dbo.{prefix}_CS_ProviderSummary
            ORDER  BY ProviderRank;
            """;
        var sqlB = $"""
            SELECT ProviderRank, ReferringProvider, NoOfClaims,
                   ProcTotalPayment AS InsurancePayments,
                   InsuranceBalance, PatientBalance
            FROM   dbo.{prefix}_CS_ProviderSummary
            ORDER  BY ProviderRank;
            """;

        var rows = new List<ProviderSummaryRow>();
        var sw = Stopwatch.StartNew();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);

        async Task ReadAsync(string s)
        {
            await using var cmd = new SqlCommand(s, conn) { CommandTimeout = 60 };
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                rows.Add(new ProviderSummaryRow(
                    Rank:               r.GetInt32  (r.GetOrdinal("ProviderRank")),
                    ReferringProvider:  r.GetString (r.GetOrdinal("ReferringProvider")),
                    NoOfClaims:         r.GetInt32  (r.GetOrdinal("NoOfClaims")),
                    InsurancePayments:  r.GetDecimal(r.GetOrdinal("InsurancePayments")),
                    InsuranceBalance:   r.GetDecimal(r.GetOrdinal("InsuranceBalance")),
                    PatientBalance:     r.GetDecimal(r.GetOrdinal("PatientBalance"))));
            }
        }

        try
        {
            await ReadAsync(sqlA);
        }
        catch (SqlException ex) when (ex.Number == 207)
        {
            rows.Clear();
            await ReadAsync(sqlB);
        }

        _logger.LogInformation("CollectionSummary[Aggregate] ProviderSummary({Prefix}): rows={N}, {Ms}ms",
            prefix, rows.Count, sw.ElapsedMilliseconds);
        return new ProviderSummaryResult
        {
            Rows                   = rows,
            GrandNoClaims          = rows.Sum(r => r.NoOfClaims),
            GrandInsurancePayments = rows.Sum(r => r.InsurancePayments),
            GrandInsuranceBalance  = rows.Sum(r => r.InsuranceBalance),
            GrandPatientBalance    = rows.Sum(r => r.PatientBalance),
        };
    }

    // ?? Last refreshed timestamp across all snapshot tables for the lab ??????
    public async Task<DateTime?> GetAggregateLastRefreshedAtAsync(
        string connectionString, string prefix, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(prefix);

        // Probe a single representative table � Top5ReimbursementPct is always present.
        var sql = $"SELECT MAX(RefreshedAt) FROM dbo.{prefix}_CS_Top5ReimbursementPct;";
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
            var v = await cmd.ExecuteScalarAsync(ct);
            return v is DateTime dt ? dt : null;
        }
        catch (SqlException ex)
        {
            _logger.LogWarning(ex, "CollectionSummary[Aggregate] could not read RefreshedAt for prefix '{Prefix}'.", prefix);
            return null;
        }
    }

    // ?? Helpers ???????????????????????????????????????????????????????????????

    /// <summary>
    /// Builds the <see cref="CollectionMonthlyVolumeResult"/> pivot from raw rows.
    /// Mirrors the inline pivot logic from <c>GetCollectionMonthlyVolumeAsync</c>
    /// but expects the rows to already be pre-filtered to top-3 payers per panel
    /// (which is what the snapshot table stores).
    /// </summary>
    private static CollectionMonthlyVolumeResult BuildMonthlyVolumePivot(List<CollectionRawPivotRow> rawRows)
    {
        if (rawRows.Count == 0)
        {
            return new CollectionMonthlyVolumeResult(
                [], [], [], new Dictionary<string, CollectionMonthlyCell>(), new Dictionary<int, CollectionYearTotal>(), 0, 0m);
        }

        var periodSet = new SortedSet<string>(StringComparer.Ordinal);
        var yearSet   = new SortedSet<int>();
        foreach (var r in rawRows)
        {
            periodSet.Add($"{r.BillYear:D4}-{r.BillMonth:D2}");
            yearSet.Add(r.BillYear);
        }
        var periods = periodSet.Select(k => { var p = k.Split('-'); return new CollectionMonthlyPeriod(int.Parse(p[0]), int.Parse(p[1])); }).ToList();
        var years   = yearSet.ToList();

        var grandByMonth = new Dictionary<string, (int enc, decimal paid)>();
        var grandByYear  = new Dictionary<int,    (int enc, decimal paid)>();
        int    grandEnc  = 0;
        decimal grandPaid = 0m;

        var panelRows = new List<CollectionPanelRow>();
        foreach (var pg in rawRows.GroupBy(r => r.PanelName, StringComparer.OrdinalIgnoreCase))
        {
            var panelByMonth = new Dictionary<string, CollectionMonthlyCell>();
            var panelByYear  = new Dictionary<int, (int enc, decimal paid)>();
            int    panelEnc  = 0;
            decimal panelPaid = 0m;

            var payerAgg = new Dictionary<string, (int totalEnc, decimal totalPaid,
                Dictionary<string,(int enc, decimal paid)> byMonth,
                Dictionary<int,(int enc, decimal paid)> byYear)>(StringComparer.OrdinalIgnoreCase);

            foreach (var r in pg)
            {
                var mk = $"{r.BillYear:D4}-{r.BillMonth:D2}";
                int enc = r.LineItemCount;

                panelByMonth[mk] = panelByMonth.TryGetValue(mk, out var pe)
                    ? new CollectionMonthlyCell(pe.EncounterCount + enc, pe.InsurancePaidAmount + r.InsurancePaid)
                    : new CollectionMonthlyCell(enc, r.InsurancePaid);
                panelByYear[r.BillYear] = panelByYear.TryGetValue(r.BillYear, out var py)
                    ? (py.enc + enc, py.paid + r.InsurancePaid) : (enc, r.InsurancePaid);
                panelEnc += enc; panelPaid += r.InsurancePaid;

                grandByMonth[mk] = grandByMonth.TryGetValue(mk, out var gm)
                    ? (gm.enc + enc, gm.paid + r.InsurancePaid) : (enc, r.InsurancePaid);
                grandByYear[r.BillYear] = grandByYear.TryGetValue(r.BillYear, out var gy)
                    ? (gy.enc + enc, gy.paid + r.InsurancePaid) : (enc, r.InsurancePaid);
                grandEnc += enc; grandPaid += r.InsurancePaid;

                if (!payerAgg.TryGetValue(r.PayerName, out var pa))
                    payerAgg[r.PayerName] = pa = (0, 0m,
                        new Dictionary<string,(int,decimal)>(),
                        new Dictionary<int,(int,decimal)>());

                pa.totalEnc += enc; pa.totalPaid += r.InsurancePaid;
                pa.byMonth[mk] = pa.byMonth.TryGetValue(mk, out var pme)
                    ? (pme.enc + enc, pme.paid + r.InsurancePaid) : (enc, r.InsurancePaid);
                pa.byYear[r.BillYear] = pa.byYear.TryGetValue(r.BillYear, out var pye)
                    ? (pye.enc + enc, pye.paid + r.InsurancePaid) : (enc, r.InsurancePaid);
                payerAgg[r.PayerName] = pa;
            }

            // Totals (panelByMonth, panelByYear, panelEnc/panelPaid) already include ALL payers.
            // TopPayers drill-down: show only the top-3 ranked payers (PayerRank 1-3 from DB).
            // When PayerRank == 0 the data came from a live query � fall back to top-3 by count.
            bool hasDbRank = payerAgg.Keys.Any(k =>
                rawRows.Any(r => r.PanelName == pg.Key && r.PayerName == k && r.PayerRank > 0));

            var topPayers = payerAgg
                .OrderByDescending(kv => kv.Value.totalEnc)
                .Where(kv => !hasDbRank ||
                    rawRows.Any(r => r.PanelName == pg.Key && r.PayerName == kv.Key && r.PayerRank > 0 && r.PayerRank <= 3))
                .Select(kv => new CollectionPayerDrillDown
                {
                    PayerName          = kv.Key,
                    PayerRank          = hasDbRank
                        ? rawRows.Where(r => r.PanelName == pg.Key && r.PayerName == kv.Key && r.PayerRank > 0).Select(r => (byte)r.PayerRank).FirstOrDefault()
                        : (byte)0,
                    ByMonth            = kv.Value.byMonth.ToDictionary(x => x.Key, x => new CollectionMonthlyCell(x.Value.enc, x.Value.paid)),
                    ByYear             = kv.Value.byYear .ToDictionary(x => x.Key, x => new CollectionYearTotal(x.Value.enc, x.Value.paid)),
                    TotalEncounters    = kv.Value.totalEnc,
                    TotalInsurancePaid = kv.Value.totalPaid,
                })
                .ToList();

            panelRows.Add(new CollectionPanelRow
            {
                PanelName          = pg.Key,
                ByMonth            = panelByMonth,
                ByYear             = panelByYear.ToDictionary(kv => kv.Key, kv => new CollectionYearTotal(kv.Value.enc, kv.Value.paid)),
                TotalEncounters    = panelEnc,
                TotalInsurancePaid = panelPaid,
                TopPayers          = topPayers,
            });
        }

        panelRows.Sort((a, b) => b.TotalEncounters.CompareTo(a.TotalEncounters));

        return new CollectionMonthlyVolumeResult(
            periods, years, panelRows,
            grandByMonth.ToDictionary(kv => kv.Key, kv => new CollectionMonthlyCell(kv.Value.enc, kv.Value.paid)),
            grandByYear .ToDictionary(kv => kv.Key, kv => new CollectionYearTotal  (kv.Value.enc, kv.Value.paid)),
            grandEnc, grandPaid);
    }

    /// <summary>
    /// Builds the weekly volume pivot from snapshot rows. Snapshot already contains
    /// only the top-3 payers per panel.
    /// </summary>
    private static CollectionWeeklyVolumeResult BuildWeeklyVolumePivotFromAggregate(
        List<(string Panel, string Payer, byte PayerRank, byte Week, DateTime Start, DateTime End, int Claims, decimal Paid)> rows)
    {
        if (rows.Count == 0)
        {
            return new CollectionWeeklyVolumeResult(
                [], [], new Dictionary<string, CollectionMonthlyCell>(), 0, 0m);
        }

        // Build the week list (1..4) using the first occurrence of each WeekKey
        var weeks = rows
            .GroupBy(r => r.Week)
            .OrderBy(g => g.Key)
            .Select(g =>
            {
                var first = g.First();
                return new CollectionWeekBucket(g.Key, first.Start, first.End);
            })
            .ToList();

        var grandByWeek = new Dictionary<string, CollectionMonthlyCell>();
        int grandEnc = 0;
        decimal grandPaid = 0m;

        var panelRows = new List<CollectionWeeklyPanelRow>();
        foreach (var pg in rows.GroupBy(r => r.Panel, StringComparer.OrdinalIgnoreCase))
        {
            var panelByWeek = new Dictionary<string, CollectionMonthlyCell>();
            int panelEnc = 0;
            decimal panelPaid = 0m;
            var payerAgg = new Dictionary<string, (int totalEnc, decimal totalPaid,
                Dictionary<string, CollectionMonthlyCell> byWeek)>(StringComparer.OrdinalIgnoreCase);

            foreach (var r in pg)
            {
                var key = $"W{r.Week}";
                panelByWeek[key] = panelByWeek.TryGetValue(key, out var pe)
                    ? new CollectionMonthlyCell(pe.EncounterCount + r.Claims, pe.InsurancePaidAmount + r.Paid)
                    : new CollectionMonthlyCell(r.Claims, r.Paid);
                panelEnc += r.Claims; panelPaid += r.Paid;

                grandByWeek[key] = grandByWeek.TryGetValue(key, out var gw)
                    ? new CollectionMonthlyCell(gw.EncounterCount + r.Claims, gw.InsurancePaidAmount + r.Paid)
                    : new CollectionMonthlyCell(r.Claims, r.Paid);
                grandEnc += r.Claims; grandPaid += r.Paid;

                // Accumulate ALL payers into payerAgg (used for totals column on drill-down rows).
                // TopPayers display is filtered to PayerRank<=3 below.
                if (!payerAgg.TryGetValue(r.Payer, out var pa))
                    payerAgg[r.Payer] = pa = (0, 0m, new Dictionary<string, CollectionMonthlyCell>());

                pa.totalEnc += r.Claims; pa.totalPaid += r.Paid;
                pa.byWeek[key] = pa.byWeek.TryGetValue(key, out var pw)
                    ? new CollectionMonthlyCell(pw.EncounterCount + r.Claims, pw.InsurancePaidAmount + r.Paid)
                    : new CollectionMonthlyCell(r.Claims, r.Paid);
                payerAgg[r.Payer] = pa;
            }

            // Display only top-3 payers (PayerRank 1-3 from DB).
            // The panel-level totals above already include every payer.
            bool hasDbRank = pg.Any(r => r.PayerRank > 0);
            var topPayers = payerAgg
                .OrderByDescending(kv => kv.Value.totalEnc)
                .Where(kv => !hasDbRank ||
                    pg.Any(r => r.Payer == kv.Key && r.PayerRank > 0 && r.PayerRank <= 3))
                .Select(kv => new CollectionWeeklyPayerDrillDown
                {
                    PayerName          = kv.Key,
                    PayerRank          = hasDbRank
                        ? pg.Where(r => r.Payer == kv.Key && r.PayerRank > 0).Select(r => (byte)r.PayerRank).FirstOrDefault()
                        : (byte)0,
                    ByWeek             = kv.Value.byWeek,
                    TotalEncounters    = kv.Value.totalEnc,
                    TotalInsurancePaid = kv.Value.totalPaid,
                })
                .ToList();

            panelRows.Add(new CollectionWeeklyPanelRow
            {
                PanelName          = pg.Key,
                ByWeek             = panelByWeek,
                TotalEncounters    = panelEnc,
                TotalInsurancePaid = panelPaid,
                TopPayers          = topPayers,
            });
        }

        panelRows.Sort((a, b) => b.TotalEncounters.CompareTo(a.TotalEncounters));

        return new CollectionWeeklyVolumeResult(weeks, panelRows, grandByWeek, grandEnc, grandPaid);
    }

    /// <summary>
    /// Builds the 3-level (ClaimStatus ? Panel ? CPT ? Payer) hierarchy from flat
    /// snapshot rows. Sorts by NoClaims descending at every level.
    /// </summary>
    private static StatusSummaryResult BuildStatusSummaryHierarchy(
        List<(string Status, string Panel, string Cpt, string Payer,
              int N, decimal IP, decimal IB, decimal PB)> flat)
    {
        var statusGroups = flat
            .GroupBy(x => x.Status, StringComparer.OrdinalIgnoreCase)
            .Select(sg =>
            {
                var panelRows = sg
                    .GroupBy(x => x.Panel, StringComparer.OrdinalIgnoreCase)
                    .Select(pg =>
                    {
                        var cptRows = pg
                            .GroupBy(x => x.Cpt, StringComparer.OrdinalIgnoreCase)
                            .Select(cg =>
                            {
                                var payerRows = cg
                                    .GroupBy(x => x.Payer, StringComparer.OrdinalIgnoreCase)
                                    .Select(yg => new StatusSummaryPayerRow(
                                        PayerName:         yg.Key,
                                        NoClaims:          yg.Sum(z => z.N),
                                        InsurancePayments: yg.Sum(z => z.IP),
                                        InsuranceBalance:  yg.Sum(z => z.IB),
                                        PatientBalance:    yg.Sum(z => z.PB)))
                                    .OrderByDescending(p => p.NoClaims)
                                    .ToList();

                                return new StatusSummaryCptRow
                                {
                                    CptCode           = cg.Key,
                                    NoClaims          = cg.Sum(z => z.N),
                                    InsurancePayments = cg.Sum(z => z.IP),
                                    InsuranceBalance  = cg.Sum(z => z.IB),
                                    PatientBalance    = cg.Sum(z => z.PB),
                                    Payers            = payerRows,
                                };
                            })
                            .OrderByDescending(c => c.NoClaims)
                            .ToList();

                        return new StatusSummaryPanelRow
                        {
                            PanelName         = pg.Key,
                            NoClaims          = pg.Sum(z => z.N),
                            InsurancePayments = pg.Sum(z => z.IP),
                            InsuranceBalance  = pg.Sum(z => z.IB),
                            PatientBalance    = pg.Sum(z => z.PB),
                            CptRows           = cptRows,
                        };
                    })
                    .OrderByDescending(p => p.NoClaims)
                    .ToList();

                return new StatusSummaryClaimRow
                {
                    ClaimStatus       = sg.Key,
                    NoClaims          = sg.Sum(z => z.N),
                    InsurancePayments = sg.Sum(z => z.IP),
                    InsuranceBalance  = sg.Sum(z => z.IB),
                    PatientBalance    = sg.Sum(z => z.PB),
                    PanelRows         = panelRows,
                };
            })
            .OrderByDescending(s => s.NoClaims)
            .ToList();

        return new StatusSummaryResult
        {
            Rows                   = statusGroups,
            GrandNoClaims          = flat.Sum(x => x.N),
            GrandInsurancePayments = flat.Sum(x => x.IP),
            GrandInsuranceBalance  = flat.Sum(x => x.IB),
            GrandPatientBalance    = flat.Sum(x => x.PB),
        };
    }
    private static string SafeSqlIdentifier(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Any(c => !(char.IsLetterOrDigit(c) || c == '_')))
            throw new InvalidOperationException("Unsupported SQL identifier.");
        return value;
    }

    private static string SafePanelAveragesColumn(string value)
    {
        var allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "NoOfClaims", "ClaimCount", "CarrierPayment", "InsurancePayment",
            "Days30Count", "Days30Amount", "Over30Count", "Over30Amount",
            "Days60Count", "Days60Amount", "Over60Count", "Over60Amount"
        };
        if (!allowed.Contains(value)) throw new InvalidOperationException("Unsupported aggregate column.");
        return value;
    }
}
