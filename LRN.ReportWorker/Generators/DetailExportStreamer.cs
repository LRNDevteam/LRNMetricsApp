using Microsoft.Data.SqlClient;

namespace LRN.ReportWorker.Generators;

/// <summary>
/// Chunked Claim/Line Level Excel export via <see cref="OpenXmlRowStreamer"/>.
/// One forward-only SqlDataReader; sheet-split every
/// <see cref="OpenXmlRowStreamer.SheetSplitThreshold"/> rows. Avoids ClosedXML
/// SaveAs OOM on high-volume labs.
/// </summary>
internal static class DetailExportStreamer
{
    private const int CountTimeoutSeconds = 45;
    private const int QueryTimeoutSeconds = 3600;

    public static async Task<int> WriteAsync(
        string connectionString,
        string dataSql,
        string countSql,
        List<SqlParameter> parameters,
        string labName,
        string title,
        List<(string Label, string? Value)> activeFilters,
        HashSet<string> moneyColumns,
        ClosedXML.Excel.XLColor tabColor,
        string tempPath,
        Func<byte, Task>? reportProgressAsync,
        CancellationToken ct)
    {
        // moneyColumns / tabColor kept for call-site compatibility; OpenXml inline
        // strings don't apply number formats (values still export correctly).
        _ = moneyColumns;
        _ = tabColor;

        if (reportProgressAsync is not null) await reportProgressAsync(2);

        var totalFiltered = await TryCountAsync(connectionString, countSql, parameters, ct);
        if (reportProgressAsync is not null)
            await reportProgressAsync(totalFiltered is > 0 ? (byte)5 : (byte)3);

        return await OpenXmlRowStreamer.WriteFromSqlAsync(
            connectionString,
            dataSql,
            parameters,
            tempPath,
            labName,
            title,
            activeFilters,
            reportProgressAsync,
            totalFiltered,
            ct,
            QueryTimeoutSeconds);
    }

    private static async Task<int?> TryCountAsync(
        string connectionString, string countSql, List<SqlParameter> parameters, CancellationToken ct)
    {
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(countSql, conn) { CommandTimeout = CountTimeoutSeconds };
            foreach (var p in parameters)
                cmd.Parameters.Add(new SqlParameter(p.ParameterName, p.Value ?? DBNull.Value));
            return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct) ?? 0);
        }
        catch (Exception) when (!ct.IsCancellationRequested)
        {
            return null;
        }
    }
}
