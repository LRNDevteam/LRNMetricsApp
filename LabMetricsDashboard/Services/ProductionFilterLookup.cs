using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Fast Production Summary filter lists. Snapshot tables and
/// <c>DashboardFilterLookup</c> are small; a DISTINCT on <c>ClaimLevelData</c>
/// can take several seconds on large labs and must not block first paint.
/// </summary>
internal static class ProductionFilterLookup
{
    public static async Task<(List<string> PayerNames, List<string> PanelNames)> LoadFastAsync(
        SqlConnection conn,
        string tablePrefix,
        ILogger logger,
        CancellationToken ct)
    {
        if (tablePrefix.Any(c => !char.IsLetterOrDigit(c) && c != '_'))
            return ([], []);

        var fromAgg = await TryAggregatesAsync(conn, tablePrefix, ct);
        if (fromAgg is { } a && (a.PayerNames.Count > 0 || a.PanelNames.Count > 0))
        {
            logger.LogInformation(
                "Filter options from {Prefix} snapshot (payers={P}, panels={N}).",
                tablePrefix, a.PayerNames.Count, a.PanelNames.Count);
            return a;
        }

        var fromLookup = await TryDashboardLookupAsync(conn, ct);
        if (fromLookup is { } l && (l.PayerNames.Count > 0 || l.PanelNames.Count > 0))
        {
            logger.LogInformation(
                "Filter options from DashboardFilterLookup (payers={P}, panels={N}).",
                l.PayerNames.Count, l.PanelNames.Count);
            return l;
        }

        logger.LogWarning(
            "Filter options: no snapshot or DashboardFilterLookup for {Prefix}; skipping ClaimLevelData DISTINCT.",
            tablePrefix);
        return ([], []);
    }

    private static async Task<(List<string> PayerNames, List<string> PanelNames)?> TryAggregatesAsync(
        SqlConnection conn, string prefix, CancellationToken ct)
    {
        try
        {
            await using var probe = new SqlCommand($"""
                SELECT CASE WHEN OBJECT_ID('dbo.{prefix}PayerBreakdown','U') IS NOT NULL
                              AND EXISTS (SELECT 1 FROM dbo.{prefix}PayerBreakdown)
                             THEN 1 ELSE 0 END
                """, conn)
            { CommandTimeout = 8 };
            if (Convert.ToInt32(await probe.ExecuteScalarAsync(ct)) != 1)
                return null;

            var payers = await ReadDistinctAsync(conn, $"""
                SELECT DISTINCT LTRIM(RTRIM(PayerName))
                FROM dbo.{prefix}PayerBreakdown
                WHERE NULLIF(LTRIM(RTRIM(PayerName)), '') IS NOT NULL
                ORDER BY 1
                """, ct);

            var panels = new List<string>();
            try
            {
                panels = await ReadDistinctAsync(conn, $"""
                    SELECT DISTINCT LTRIM(RTRIM(PanelType))
                    FROM dbo.{prefix}PayerByPanel
                    WHERE NULLIF(LTRIM(RTRIM(PanelType)), '') IS NOT NULL
                    ORDER BY 1
                    """, ct);
            }
            catch
            {
                // Panel snapshot missing is fine; payers still usable.
            }

            if (payers.Count > 0 || panels.Count > 0)
                return (payers, panels);
        }
        catch
        {
            // fall through
        }

        return null;
    }

    private static async Task<(List<string> PayerNames, List<string> PanelNames)?> TryDashboardLookupAsync(
        SqlConnection conn, CancellationToken ct)
    {
        try
        {
            await using var probe = new SqlCommand("""
                SELECT CASE WHEN OBJECT_ID('dbo.DashboardFilterLookup','U') IS NOT NULL
                              AND EXISTS (SELECT 1 FROM dbo.DashboardFilterLookup)
                             THEN 1 ELSE 0 END
                """, conn)
            { CommandTimeout = 8 };
            if (Convert.ToInt32(await probe.ExecuteScalarAsync(ct)) != 1)
                return null;

            var payers = await ReadDistinctAsync(conn, """
                SELECT FilterValue FROM dbo.DashboardFilterLookup
                WHERE FilterType IN (N'PayerName', N'PayerName_Raw')
                  AND NULLIF(LTRIM(RTRIM(FilterValue)), '') IS NOT NULL
                ORDER BY FilterValue
                """, ct);
            var panels = await ReadDistinctAsync(conn, """
                SELECT FilterValue FROM dbo.DashboardFilterLookup
                WHERE FilterType IN (N'PanelType', N'PanelName', N'PanelNew')
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
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 8 };
        await using var rdr = await cmd.ExecuteReaderAsync(ct);
        while (await rdr.ReadAsync(ct))
            if (!rdr.IsDBNull(0)) list.Add(rdr.GetString(0));
        return list;
    }
}
