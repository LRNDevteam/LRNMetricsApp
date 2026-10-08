using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Denial Summary data access. Every calculation, ranking, total and row order comes from the
/// lab's <c>usp_Get{prefix}_Denial*</c> SPs; the page and the Excel export share these calls.
/// </summary>
public interface IDenialSummaryRepository
{
    Task<DenialPeriodResult> GetMonthlyAsync(string connectionString, string prefix, DenialSummaryFilters filters, CancellationToken ct = default);
    Task<DenialPeriodResult> GetWeeklyAsync(string connectionString, string prefix, DenialSummaryFilters filters, CancellationToken ct = default);
    Task<IReadOnlyList<DenialListRow>> GetDenialListAsync(string connectionString, string prefix, DenialSummaryFilters filters, CancellationToken ct = default);
    Task<IReadOnlyList<DenialPlanTypeRow>> GetPlanTypeAsync(string connectionString, string prefix, DenialSummaryFilters filters, CancellationToken ct = default);
    Task<DenialSummaryFilterOptions> GetFilterOptionsAsync(string connectionString, string prefix, CancellationToken ct = default);
    Task<DenialSummaryTiles> GetSummaryTilesAsync(string connectionString, string prefix, CancellationToken ct = default);
}

public sealed class SqlDenialSummaryRepository : IDenialSummaryRepository
{
    private const int CommandTimeoutSeconds = 180;

    public Task<DenialPeriodResult> GetMonthlyAsync(string connectionString, string prefix, DenialSummaryFilters filters, CancellationToken ct = default)
        => GetPeriodAsync(connectionString, $"dbo.usp_Get{prefix}_DenialMonthly", filters, ct);

    public Task<DenialPeriodResult> GetWeeklyAsync(string connectionString, string prefix, DenialSummaryFilters filters, CancellationToken ct = default)
        => GetPeriodAsync(connectionString, $"dbo.usp_Get{prefix}_DenialWeekly", filters, ct);

    private static async Task<DenialPeriodResult> GetPeriodAsync(string connectionString, string spName, DenialSummaryFilters filters, CancellationToken ct)
    {
        var rows = new List<DenialPeriodRow>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = CreateFilteredCommand(conn, spName, filters);
        await using var rd = await cmd.ExecuteReaderAsync(ct);

        int oRowType = rd.GetOrdinal("RowType"), oPayer = rd.GetOrdinal("PayerName"), oCode = rd.GetOrdinal("DenialCode"),
            oPayerRank = rd.GetOrdinal("PayerRank"), oCodeRank = rd.GetOrdinal("CodeRank"),
            oPeriodType = rd.GetOrdinal("PeriodType"), oPeriodKey = rd.GetOrdinal("PeriodKey"),
            oPeriodYear = rd.GetOrdinal("PeriodYear"), oStart = rd.GetOrdinal("PeriodStart"), oEnd = rd.GetOrdinal("PeriodEnd"),
            oLabel = rd.GetOrdinal("PeriodLabel"), oClaims = rd.GetOrdinal("ClaimCount"),
            oBal = rd.GetOrdinal("TotalInsuranceBalance"), oSort = rd.GetOrdinal("SortOrder"), oPeriodOrder = rd.GetOrdinal("PeriodOrder"),
            oIndex = rd.GetOrdinal("IndexLabel"), oRowLabel = rd.GetOrdinal("RowLabel"), oCoverage = rd.GetOrdinal("CoveragePct");

        while (await rd.ReadAsync(ct))
        {
            rows.Add(new DenialPeriodRow(
                Str(rd, oRowType), Str(rd, oPayer), Str(rd, oCode),
                Int(rd, oPayerRank), Int(rd, oCodeRank),
                Str(rd, oPeriodType), Str(rd, oPeriodKey),
                rd.IsDBNull(oPeriodYear) ? null : Convert.ToInt32(rd.GetValue(oPeriodYear)),
                rd.IsDBNull(oStart) ? null : rd.GetDateTime(oStart),
                rd.IsDBNull(oEnd) ? null : rd.GetDateTime(oEnd),
                Str(rd, oLabel), Int(rd, oClaims), Dec(rd, oBal), Int(rd, oSort), Int(rd, oPeriodOrder),
                Str(rd, oIndex), Str(rd, oRowLabel), Dec(rd, oCoverage)));
        }

        return DenialPeriodResult.From(rows);
    }

    public async Task<DenialSummaryTiles> GetSummaryTilesAsync(string connectionString, string prefix, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand($"dbo.usp_Get{prefix}_DenialSummaryTiles", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = CommandTimeoutSeconds,
        };
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (!await rd.ReadAsync(ct)) return DenialSummaryTiles.Empty;

        return new DenialSummaryTiles(
            Int(rd, rd.GetOrdinal("DeniedClaims")),
            Dec(rd, rd.GetOrdinal("InsuranceBalance")),
            Int(rd, rd.GetOrdinal("DenialCodes")),
            Int(rd, rd.GetOrdinal("Insurances")),
            Int(rd, rd.GetOrdinal("UndatedGroups")),
            rd.IsDBNull(rd.GetOrdinal("LoadedThrough")) ? null : rd.GetDateTime(rd.GetOrdinal("LoadedThrough")),
            rd.IsDBNull(rd.GetOrdinal("RefreshedAt")) ? null : rd.GetDateTime(rd.GetOrdinal("RefreshedAt")));
    }

    public async Task<IReadOnlyList<DenialListRow>> GetDenialListAsync(string connectionString, string prefix, DenialSummaryFilters filters, CancellationToken ct = default)
    {
        var rows = new List<DenialListRow>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = CreateFilteredCommand(conn, $"dbo.usp_Get{prefix}_DenialList", filters);
        cmd.Parameters.Add(new SqlParameter("@DenialCodeSearch", SqlDbType.NVarChar, 200)
        {
            Value = string.IsNullOrWhiteSpace(filters.DenialCodeSearch) ? DBNull.Value : filters.DenialCodeSearch.Trim()
        });
        await using var rd = await cmd.ExecuteReaderAsync(ct);

        int oRowType = rd.GetOrdinal("RowType"), oCode = rd.GetOrdinal("DenialCode"), oPayer = rd.GetOrdinal("PayerName"),
            oCodeRank = rd.GetOrdinal("CodeRank"), oPayerRank = rd.GetOrdinal("PayerRank"),
            oClaims = rd.GetOrdinal("ClaimCount"), oBal = rd.GetOrdinal("TotalInsuranceBalance"), oSort = rd.GetOrdinal("SortOrder");

        while (await rd.ReadAsync(ct))
        {
            rows.Add(new DenialListRow(
                Str(rd, oRowType), Str(rd, oCode), Str(rd, oPayer),
                Int(rd, oCodeRank), Int(rd, oPayerRank), Int(rd, oClaims), Dec(rd, oBal), Int(rd, oSort)));
        }
        return rows;
    }

    public async Task<IReadOnlyList<DenialPlanTypeRow>> GetPlanTypeAsync(string connectionString, string prefix, DenialSummaryFilters filters, CancellationToken ct = default)
    {
        var rows = new List<DenialPlanTypeRow>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = CreateFilteredCommand(conn, $"dbo.usp_Get{prefix}_DenialPlanType", filters);
        await using var rd = await cmd.ExecuteReaderAsync(ct);

        int oRowType = rd.GetOrdinal("RowType"), oType = rd.GetOrdinal("PayerType"),
            oClaims = rd.GetOrdinal("ClaimCount"), oBal = rd.GetOrdinal("TotalInsuranceBalance"), oSort = rd.GetOrdinal("SortOrder");

        while (await rd.ReadAsync(ct))
            rows.Add(new DenialPlanTypeRow(Str(rd, oRowType), Str(rd, oType), Int(rd, oClaims), Dec(rd, oBal), Int(rd, oSort)));
        return rows;
    }

    public async Task<DenialSummaryFilterOptions> GetFilterOptionsAsync(string connectionString, string prefix, CancellationToken ct = default)
    {
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand($"dbo.usp_Get{prefix}_DenialFilterOptions", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = CommandTimeoutSeconds,
        };
        await using var rd = await cmd.ExecuteReaderAsync(ct);

        var payers = await ReadValuesAsync(rd, ct);
        var types = await rd.NextResultAsync(ct) ? await ReadValuesAsync(rd, ct) : [];
        var codes = await rd.NextResultAsync(ct) ? await ReadValuesAsync(rd, ct) : [];

        DateTime? min = null, max = null, refreshed = null;
        if (await rd.NextResultAsync(ct) && await rd.ReadAsync(ct))
        {
            min = rd.IsDBNull(0) ? null : rd.GetDateTime(0);
            max = rd.IsDBNull(1) ? null : rd.GetDateTime(1);
            refreshed = rd.IsDBNull(2) ? null : rd.GetDateTime(2);
        }

        return new DenialSummaryFilterOptions(payers, types, codes, min, max, refreshed);
    }

    private static async Task<List<string>> ReadValuesAsync(SqlDataReader rd, CancellationToken ct)
    {
        var values = new List<string>();
        while (await rd.ReadAsync(ct))
            if (!rd.IsDBNull(0)) values.Add(rd.GetString(0));
        return values;
    }

    private static SqlCommand CreateFilteredCommand(SqlConnection conn, string spName, DenialSummaryFilters filters)
    {
        var cmd = new SqlCommand(spName, conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = CommandTimeoutSeconds,
        };
        cmd.Parameters.Add(new SqlParameter("@PayerNames", SqlDbType.NVarChar, -1) { Value = Joined(filters.PayerNames) });
        cmd.Parameters.Add(new SqlParameter("@PayerTypes", SqlDbType.NVarChar, -1) { Value = Joined(filters.PayerTypes) });
        cmd.Parameters.Add(new SqlParameter("@DenialCodes", SqlDbType.NVarChar, -1) { Value = Joined(filters.DenialCodes) });
        cmd.Parameters.Add(new SqlParameter("@DenialFrom", SqlDbType.Date) { Value = (object?)filters.DenialFrom?.ToDateTime(TimeOnly.MinValue) ?? DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@DenialTo", SqlDbType.Date) { Value = (object?)filters.DenialTo?.ToDateTime(TimeOnly.MinValue) ?? DBNull.Value });
        return cmd;
    }

    private static object Joined(IReadOnlyCollection<string> values) =>
        values.Count == 0 ? DBNull.Value : string.Join('|', values);

    private static string Str(SqlDataReader rd, int ordinal) =>
        rd.IsDBNull(ordinal) ? string.Empty : Convert.ToString(rd.GetValue(ordinal))!.Trim();

    private static int Int(SqlDataReader rd, int ordinal) =>
        rd.IsDBNull(ordinal) ? 0 : Convert.ToInt32(rd.GetValue(ordinal));

    private static decimal Dec(SqlDataReader rd, int ordinal) =>
        rd.IsDBNull(ordinal) ? 0m : Convert.ToDecimal(rd.GetValue(ordinal));
}
