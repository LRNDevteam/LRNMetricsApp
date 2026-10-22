using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;
using System.Data;

namespace LabMetricsDashboard.Services;

public sealed partial class SqlPhiExecutiveSummaryRepository
{
    public static string ExecutiveSummaryCellRowsSpName(string prefix) =>
        $"dbo.usp_Get{prefix}_ExecutiveSummaryCellRows";

    /// <summary>
    /// Reads <c>usp_Get{prefix}_ExecutiveSummaryCellRows</c>: result set 1 = rules, 2 = summary,
    /// 3 = one page of source rows (every row when <see cref="ExecSummaryCellRowsRequest.PageSize"/> is 0).
    /// </summary>
    public async Task<ExecSummaryCellRowsResult> GetCellRowsAsync(
        string connectionString, string prefix, ExecSummaryCellRowsRequest req, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(ExecutiveSummaryCellRowsSpName(prefix), conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 300,
        };
        cmd.Parameters.Add("@Category", SqlDbType.VarChar, 10).Value = req.Category;
        cmd.Parameters.Add("@RowCode", SqlDbType.NVarChar, 20).Value = req.RowCode;
        cmd.Parameters.Add("@Year", SqlDbType.Int).Value = req.Year;
        cmd.Parameters.Add("@Month", SqlDbType.Int).Value = req.Month;
        cmd.Parameters.Add("@YearFrom", SqlDbType.Int).Value = (object?)req.YearFrom ?? DBNull.Value;
        cmd.Parameters.Add("@YearTo", SqlDbType.Int).Value = (object?)req.YearTo ?? DBNull.Value;
        cmd.Parameters.Add("@MonthFrom", SqlDbType.Int).Value = (object?)req.MonthFrom ?? DBNull.Value;
        cmd.Parameters.Add("@MonthTo", SqlDbType.Int).Value = (object?)req.MonthTo ?? DBNull.Value;
        cmd.Parameters.Add("@DosFrom", SqlDbType.Date).Value = (object?)req.DosFrom ?? DBNull.Value;
        cmd.Parameters.Add("@DosTo", SqlDbType.Date).Value = (object?)req.DosTo ?? DBNull.Value;
        cmd.Parameters.Add("@BilledFrom", SqlDbType.Date).Value = (object?)req.BilledFrom ?? DBNull.Value;
        cmd.Parameters.Add("@BilledTo", SqlDbType.Date).Value = (object?)req.BilledTo ?? DBNull.Value;
        cmd.Parameters.Add("@Panels", SqlDbType.NVarChar, -1).Value = (object?)req.Panels ?? DBNull.Value;
        cmd.Parameters.Add("@Clinics", SqlDbType.NVarChar, -1).Value = (object?)req.Clinics ?? DBNull.Value;
        cmd.Parameters.Add("@Providers", SqlDbType.NVarChar, -1).Value = (object?)req.Providers ?? DBNull.Value;
        cmd.Parameters.Add("@Reps", SqlDbType.NVarChar, -1).Value = (object?)req.Reps ?? DBNull.Value;
        cmd.Parameters.Add("@Page", SqlDbType.Int).Value = req.Page;
        cmd.Parameters.Add("@PageSize", SqlDbType.Int).Value = req.PageSize;

        var result = new ExecSummaryCellRowsResult { Page = req.Page, PageSize = req.PageSize };
        await using var reader = await cmd.ExecuteReaderAsync(ct);

        while (await reader.ReadAsync(ct))
            result.Rules.Add(new ExecSummaryCellRule(reader.GetString(1), reader.GetString(2)));

        if (await reader.NextResultAsync(ct) && await reader.ReadAsync(ct))
        {
            result.SourceTable = reader.IsDBNull(0) ? null : reader.GetString(0);
            result.Measure = reader.IsDBNull(1) ? string.Empty : reader.GetString(1);
            result.AmountColumn = reader.IsDBNull(2) ? null : reader.GetString(2);
            result.TotalRows = reader.IsDBNull(3) ? 0 : Convert.ToInt32(reader.GetValue(3));
            result.TotalAmount = reader.IsDBNull(4) ? 0m : Convert.ToDecimal(reader.GetValue(4));
            result.IsFormula = !reader.IsDBNull(5) && Convert.ToBoolean(reader.GetValue(5));
        }

        if (await reader.NextResultAsync(ct))
        {
            for (var i = 0; i < reader.FieldCount; i++)
                result.Columns.Add(reader.GetName(i));
            while (await reader.ReadAsync(ct))
            {
                var row = new object?[reader.FieldCount];
                for (var i = 0; i < reader.FieldCount; i++)
                {
                    var v = reader.IsDBNull(i) ? null : reader.GetValue(i);
                    row[i] = v is DateTime d ? d.ToString("MM/dd/yyyy") : v;
                }
                result.Rows.Add(row);
            }
        }

        return result;
    }
}
