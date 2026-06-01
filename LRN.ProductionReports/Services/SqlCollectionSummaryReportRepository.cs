using System.Data;
using LRN.ProductionReports.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

namespace LRN.ProductionReports.Services;

/// <summary>
/// SQL Server implementation for shared Collection Summary report data.
/// </summary>
public sealed class SqlCollectionSummaryReportRepository : ICollectionSummaryReportRepository
{
    private readonly ILogger<SqlCollectionSummaryReportRepository> _logger;

    public SqlCollectionSummaryReportRepository(ILogger<SqlCollectionSummaryReportRepository> logger)
        => _logger = logger;

    /// <inheritdoc />
    public Task<CollectionSummaryMonthlyClaimVolumeResult> GetNorthWestMonthlyClaimVolumeAsync(
        string connectionString,
        CollectionSummaryFilters? filters = null,
        CancellationToken ct = default)
        => GetMonthlyClaimVolumeAsync(connectionString, "dbo.usp_GetNW_CS_MonthlyClaimVolume", filters, ct);

    /// <inheritdoc />
    public async Task<CollectionSummaryMonthlyClaimVolumeResult> GetMonthlyClaimVolumeAsync(
        string connectionString,
        string storedProcedureName,
        CollectionSummaryFilters? filters = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(storedProcedureName);

        var rows = new List<MonthlyRawRow>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var cmd = CreateSpCommand(conn, storedProcedureName, filters);

        await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
        while (await reader.ReadAsync(ct).ConfigureAwait(false))
        {
            rows.Add(new MonthlyRawRow(
                PanelName: reader.GetString(reader.GetOrdinal("PanelName")),
                PayerName: reader.GetString(reader.GetOrdinal("PayerName")),
                PayerRank: reader.GetByte(reader.GetOrdinal("PayerRank")),
                Year: reader.GetInt32(reader.GetOrdinal("BillYear")),
                Month: reader.GetByte(reader.GetOrdinal("BillMonth")),
                ClaimCount: reader.GetInt32(reader.GetOrdinal("NoOfClaims")),
                TotalPaid: reader.GetDecimal(reader.GetOrdinal("InsurancePayment"))));
        }

        _logger.LogInformation("CollectionSummary {Sp} monthly rows={Rows}", storedProcedureName, rows.Count);
        return BuildMonthlyResult(rows);
    }

    /// <inheritdoc />
    public Task<CollectionSummaryWeeklyClaimVolumeResult> GetNorthWestWeeklyClaimVolumeAsync(
        string connectionString,
        CollectionSummaryFilters? filters = null,
        CancellationToken ct = default)
        => GetWeeklyClaimVolumeAsync(connectionString, "dbo.usp_GetNW_CS_WeeklyClaimVolume", filters, ct);

    /// <inheritdoc />
    public async Task<CollectionSummaryWeeklyClaimVolumeResult> GetWeeklyClaimVolumeAsync(
        string connectionString,
        string storedProcedureName,
        CollectionSummaryFilters? filters = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(storedProcedureName);

        var rows = new List<WeeklyRawRow>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var cmd = CreateSpCommand(conn, storedProcedureName, filters);

        await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
        while (await reader.ReadAsync(ct).ConfigureAwait(false))
        {
            rows.Add(new WeeklyRawRow(
                PanelName: reader.GetString(reader.GetOrdinal("PanelName")),
                PayerName: reader.GetString(reader.GetOrdinal("PayerName")),
                PayerRank: reader.GetByte(reader.GetOrdinal("PayerRank")),
                WeekKey: reader.GetByte(reader.GetOrdinal("WeekKey")),
                WeekStart: DateOnly.FromDateTime(reader.GetDateTime(reader.GetOrdinal("WeekStart"))),
                WeekEnd: DateOnly.FromDateTime(reader.GetDateTime(reader.GetOrdinal("WeekEnd"))),
                ClaimCount: reader.GetInt32(reader.GetOrdinal("NoOfClaims")),
                TotalPaid: reader.GetDecimal(reader.GetOrdinal("InsurancePayment"))));
        }

        _logger.LogInformation("CollectionSummary {Sp} weekly rows={Rows}", storedProcedureName, rows.Count);
        return BuildWeeklyResult(rows);
    }

    // All lab SPs share the same parameter set — generic helper used by every lab.
    private static SqlCommand CreateSpCommand(SqlConnection conn, string storedProcedureName, CollectionSummaryFilters? filters)
    => CreateNorthWestCommand(conn, storedProcedureName, filters);

    private static SqlCommand CreateNorthWestCommand(SqlConnection conn, string storedProcedureName, CollectionSummaryFilters? filters)
    {
        var cmd = new SqlCommand(storedProcedureName, conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 180
        };

        filters ??= new CollectionSummaryFilters();
        cmd.Parameters.Add(new SqlParameter("@PayerNames", SqlDbType.NVarChar, -1) { Value = filters.PayerNames is { Count: > 0 } ? string.Join("|", filters.PayerNames) : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@PanelNames", SqlDbType.NVarChar, -1) { Value = filters.PanelNames is { Count: > 0 } ? string.Join("|", filters.PanelNames) : DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@DosFrom", SqlDbType.Date) { Value = DateValue(filters.DosFrom) });
        cmd.Parameters.Add(new SqlParameter("@DosTo", SqlDbType.Date) { Value = DateValue(filters.DosTo) });
        cmd.Parameters.Add(new SqlParameter("@FirstBillFrom", SqlDbType.Date) { Value = DateValue(filters.FirstBillFrom) });
        cmd.Parameters.Add(new SqlParameter("@FirstBillTo", SqlDbType.Date) { Value = DateValue(filters.FirstBillTo) });
        cmd.Parameters.Add(new SqlParameter("@CheckDateFrom", SqlDbType.Date) { Value = DateValue(filters.CheckDateFrom) });
        cmd.Parameters.Add(new SqlParameter("@CheckDateTo", SqlDbType.Date) { Value = DateValue(filters.CheckDateTo) });
        return cmd;
    }

    private static object DateValue(DateOnly? value) => value.HasValue
        ? value.Value.ToDateTime(TimeOnly.MinValue)
        : DBNull.Value;

    private static CollectionSummaryMonthlyClaimVolumeResult BuildMonthlyResult(List<MonthlyRawRow> rows)
    {
        if (rows.Count == 0)
            return CollectionSummaryMonthlyClaimVolumeResult.Empty;

        var periods = rows
            .Select(r => new CollectionSummaryMonthPeriod(r.Year, r.Month))
            .Distinct()
            .OrderBy(p => p.Year)
            .ThenBy(p => p.Month)
            .ToList();
        var years = periods.Select(p => p.Year).Distinct().OrderBy(y => y).ToList();

        var grandByMonth = new Dictionary<string, CollectionSummaryCell>(StringComparer.OrdinalIgnoreCase);
        var grandByYear = new Dictionary<int, CollectionSummaryCell>();
        var panelRows = new List<CollectionSummaryMonthlyPanelRow>();
        var grandClaims = 0;
        var grandPaid = 0m;

        foreach (var panelGroup in rows.GroupBy(r => r.PanelName, StringComparer.OrdinalIgnoreCase))
        {
            var panelByMonth = new Dictionary<string, CollectionSummaryCell>(StringComparer.OrdinalIgnoreCase);
            var panelByYear = new Dictionary<int, CollectionSummaryCell>();
            var payerAgg = new Dictionary<string, PayerMonthlyAccumulator>(StringComparer.OrdinalIgnoreCase);
            var panelClaims = 0;
            var panelPaid = 0m;

            foreach (var row in panelGroup)
            {
                var monthKey = $"{row.Year:D4}-{row.Month:D2}";
                AddCell(panelByMonth, monthKey, row.ClaimCount, row.TotalPaid);
                AddCell(panelByYear, row.Year, row.ClaimCount, row.TotalPaid);
                AddCell(grandByMonth, monthKey, row.ClaimCount, row.TotalPaid);
                AddCell(grandByYear, row.Year, row.ClaimCount, row.TotalPaid);

                panelClaims += row.ClaimCount;
                panelPaid += row.TotalPaid;
                grandClaims += row.ClaimCount;
                grandPaid += row.TotalPaid;

                if (!payerAgg.TryGetValue(row.PayerName, out var payer))
                {
                    payer = new PayerMonthlyAccumulator(row.PayerName, row.PayerRank);
                    payerAgg[row.PayerName] = payer;
                }

                payer.Rank = row.PayerRank;
                payer.TotalClaimCount += row.ClaimCount;
                payer.TotalPaid += row.TotalPaid;
                AddCell(payer.ByMonth, monthKey, row.ClaimCount, row.TotalPaid);
                AddCell(payer.ByYear, row.Year, row.ClaimCount, row.TotalPaid);
            }

            panelRows.Add(new CollectionSummaryMonthlyPanelRow
            {
                PanelName = panelGroup.Key,
                ByMonth = panelByMonth,
                ByYear = panelByYear,
                TotalClaimCount = panelClaims,
                TotalPaid = panelPaid,
                Payers = payerAgg.Values
                    .OrderBy(p => p.Rank)
                    .ThenByDescending(p => p.TotalClaimCount)
                    .Select(p => new CollectionSummaryMonthlyPayerRow
                    {
                        PayerName = p.PayerName,
                        PayerRank = p.Rank,
                        ByMonth = p.ByMonth,
                        ByYear = p.ByYear,
                        TotalClaimCount = p.TotalClaimCount,
                        TotalPaid = p.TotalPaid
                    })
                    .ToList()
            });
        }

        return new CollectionSummaryMonthlyClaimVolumeResult
        {
            Periods = periods,
            Years = years,
            PanelRows = panelRows.OrderByDescending(p => p.TotalClaimCount).ToList(),
            GrandTotalByMonth = grandByMonth,
            GrandTotalByYear = grandByYear,
            GrandTotalClaimCount = grandClaims,
            GrandTotalPaid = grandPaid
        };
    }

    private static CollectionSummaryWeeklyClaimVolumeResult BuildWeeklyResult(List<WeeklyRawRow> rows)
    {
        if (rows.Count == 0)
            return CollectionSummaryWeeklyClaimVolumeResult.Empty;

        var weeks = rows
            .GroupBy(r => r.WeekKey)
            .OrderBy(g => g.Key)
            .Select(g =>
            {
                var first = g.First();
                return new CollectionSummaryWeekPeriod(first.WeekKey, first.WeekStart, first.WeekEnd);
            })
            .ToList();

        var grandByWeek = new Dictionary<string, CollectionSummaryCell>(StringComparer.OrdinalIgnoreCase);
        var panelRows = new List<CollectionSummaryWeeklyPanelRow>();
        var grandClaims = 0;
        var grandPaid = 0m;

        foreach (var panelGroup in rows.GroupBy(r => r.PanelName, StringComparer.OrdinalIgnoreCase))
        {
            var panelByWeek = new Dictionary<string, CollectionSummaryCell>(StringComparer.OrdinalIgnoreCase);
            var payerAgg = new Dictionary<string, PayerWeeklyAccumulator>(StringComparer.OrdinalIgnoreCase);
            var panelClaims = 0;
            var panelPaid = 0m;

            foreach (var row in panelGroup)
            {
                var weekKey = $"W{row.WeekKey}";
                AddCell(panelByWeek, weekKey, row.ClaimCount, row.TotalPaid);
                AddCell(grandByWeek, weekKey, row.ClaimCount, row.TotalPaid);

                panelClaims += row.ClaimCount;
                panelPaid += row.TotalPaid;
                grandClaims += row.ClaimCount;
                grandPaid += row.TotalPaid;

                if (!payerAgg.TryGetValue(row.PayerName, out var payer))
                {
                    payer = new PayerWeeklyAccumulator(row.PayerName, row.PayerRank);
                    payerAgg[row.PayerName] = payer;
                }

                payer.Rank = row.PayerRank;
                payer.TotalClaimCount += row.ClaimCount;
                payer.TotalPaid += row.TotalPaid;
                AddCell(payer.ByWeek, weekKey, row.ClaimCount, row.TotalPaid);
            }

            panelRows.Add(new CollectionSummaryWeeklyPanelRow
            {
                PanelName = panelGroup.Key,
                ByWeek = panelByWeek,
                TotalClaimCount = panelClaims,
                TotalPaid = panelPaid,
                Payers = payerAgg.Values
                    .OrderBy(p => p.Rank)
                    .ThenByDescending(p => p.TotalClaimCount)
                    .Select(p => new CollectionSummaryWeeklyPayerRow
                    {
                        PayerName = p.PayerName,
                        PayerRank = p.Rank,
                        ByWeek = p.ByWeek,
                        TotalClaimCount = p.TotalClaimCount,
                        TotalPaid = p.TotalPaid
                    })
                    .ToList()
            });
        }

        return new CollectionSummaryWeeklyClaimVolumeResult
        {
            Weeks = weeks,
            PanelRows = panelRows.OrderByDescending(p => p.TotalClaimCount).ToList(),
            GrandTotalByWeek = grandByWeek,
            GrandTotalClaimCount = grandClaims,
            GrandTotalPaid = grandPaid
        };
    }

    private static void AddCell<TKey>(Dictionary<TKey, CollectionSummaryCell> target, TKey key, int claims, decimal paid)
        where TKey : notnull
    {
        target[key] = target.TryGetValue(key, out var existing)
            ? new CollectionSummaryCell(existing.ClaimCount + claims, existing.TotalPaid + paid)
            : new CollectionSummaryCell(claims, paid);
    }

    private sealed record MonthlyRawRow(string PanelName, string PayerName, byte PayerRank, int Year, int Month, int ClaimCount, decimal TotalPaid);
    private sealed record WeeklyRawRow(string PanelName, string PayerName, byte PayerRank, byte WeekKey, DateOnly WeekStart, DateOnly WeekEnd, int ClaimCount, decimal TotalPaid);

    private sealed class PayerMonthlyAccumulator(string payerName, byte rank)
    {
        public string PayerName { get; } = payerName;
        public byte Rank { get; set; } = rank;
        public Dictionary<string, CollectionSummaryCell> ByMonth { get; } = [];
        public Dictionary<int, CollectionSummaryCell> ByYear { get; } = [];
        public int TotalClaimCount { get; set; }
        public decimal TotalPaid { get; set; }
    }

    private sealed class PayerWeeklyAccumulator(string payerName, byte rank)
    {
        public string PayerName { get; } = payerName;
        public byte Rank { get; set; } = rank;
        public Dictionary<string, CollectionSummaryCell> ByWeek { get; } = [];
        public int TotalClaimCount { get; set; }
        public decimal TotalPaid { get; set; }
    }
}
