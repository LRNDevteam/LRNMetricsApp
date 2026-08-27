using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using System.Data;

public sealed class LabModeMedianRepository
{
	private const string MedianTable = "LabMedians";
	private const string ModeTable = "LabModes";

	private readonly string _connStr;

	public LabModeMedianRepository(IConfiguration config)
	{
		_connStr = config.GetConnectionString("DefaultConnection")
				  ?? throw new InvalidOperationException("Missing DefaultConnection connection string.");
	}

	public async Task<int> SaveAsync(
		string runId,
		string labName,
		int labId,
		IReadOnlyList<ModeMedianPaymentReportWriter.PaymentReportRow> reportRows,
		CancellationToken ct)
	{
		var medianTable = BuildMedianDataTable(runId, labName, labId, reportRows);
		var modeTable = BuildModeDataTable(runId, labName, labId, reportRows);

		using var conn = new SqlConnection(_connStr);
		await conn.OpenAsync(ct);

		using var tx = conn.BeginTransaction();

		await DeleteLabRowsAsync(conn, tx, MedianTable, labId, ct);
		await DeleteLabRowsAsync(conn, tx, ModeTable, labId, ct);

		await BulkInsertAsync(conn, tx, MedianTable, medianTable, ct);
		await BulkInsertAsync(conn, tx, ModeTable, modeTable, ct);

		tx.Commit();

		return reportRows.Count;
	}

	private static async Task DeleteLabRowsAsync(
		SqlConnection conn,
		SqlTransaction tx,
		string tableName,
		int labId,
		CancellationToken ct)
	{
		using var cmd = new SqlCommand($"DELETE FROM {tableName} WHERE LabId = @LabId;", conn, tx);
		cmd.Parameters.Add(new SqlParameter("@LabId", SqlDbType.Int) { Value = labId });
		await cmd.ExecuteNonQueryAsync(ct);
	}

	private static async Task BulkInsertAsync(
		SqlConnection conn,
		SqlTransaction tx,
		string tableName,
		DataTable rows,
		CancellationToken ct)
	{
		if (rows.Rows.Count == 0)
			return;

		using var bulk = new SqlBulkCopy(conn, SqlBulkCopyOptions.Default, tx)
		{
			DestinationTableName = tableName,
			BatchSize = 5000
		};

		foreach (DataColumn column in rows.Columns)
			bulk.ColumnMappings.Add(column.ColumnName, column.ColumnName);

		await bulk.WriteToServerAsync(rows, ct);
	}

	private static DataTable BuildMedianDataTable(
		string runId,
		string labName,
		int labId,
		IReadOnlyList<ModeMedianPaymentReportWriter.PaymentReportRow> reportRows)
	{
		var table = CreateBaseTable(
			"MedianAllowedAmount",
			"MedianInsurancePaymentAmount",
			"AllowedAmountPerUnitMedian",
			"InsurancePaymentPerUnitMedian");

		foreach (var row in reportRows)
		{
			AddRow(
				table,
				row,
				runId,
				labName,
				labId,
				row.MedianAllowedAmount,
				row.MedianInsurancePaymentAmount,
				row.MedianAllowedAmountPerUnit,
				row.MedianInsurancePaymentPerUnit);
		}

		return table;
	}

	private static DataTable BuildModeDataTable(
		string runId,
		string labName,
		int labId,
		IReadOnlyList<ModeMedianPaymentReportWriter.PaymentReportRow> reportRows)
	{
		var table = CreateBaseTable(
			"ModeAllowedAmount",
			"ModeInsurancePaymentAmount",
			"AllowedAmountPerUnitMode",
			"InsurancePaymentPerUnitMode");

		foreach (var row in reportRows)
		{
			AddRow(
				table,
				row,
				runId,
				labName,
				labId,
				row.ModeAllowedAmount,
				row.ModeInsurancePaymentAmount,
				row.ModeAllowedAmountPerUnit,
				row.ModeInsurancePaymentPerUnit);
		}

		return table;
	}

	private static DataTable CreateBaseTable(
		string metricColumn1,
		string metricColumn2,
		string metricColumn3,
		string metricColumn4)
	{
		var table = new DataTable();
		table.Columns.Add("PayerName", typeof(string));
		table.Columns.Add("PanelName", typeof(string));
		table.Columns.Add("CPTCode", typeof(string));
		table.Columns.Add("AllowedAmount", typeof(decimal));
		table.Columns.Add("InsurancePayment", typeof(decimal));
		table.Columns.Add("DistinctAllowedPaymentCount", typeof(int));
		table.Columns.Add(metricColumn1, typeof(decimal));
		table.Columns.Add(metricColumn2, typeof(decimal));
		table.Columns.Add(metricColumn3, typeof(decimal));
		table.Columns.Add(metricColumn4, typeof(decimal));
		table.Columns.Add("LabName", typeof(string));
		table.Columns.Add("LabId", typeof(int));
		table.Columns.Add("RunID", typeof(string));
		table.Columns.Add("RollingDays", typeof(string));
		table.Columns.Add("MinDateofService", typeof(DateTime));
		table.Columns.Add("MaxDateofService", typeof(DateTime));
		table.Columns.Add("AsOfDate", typeof(DateTime));
		return table;
	}

	private static void AddRow(
		DataTable table,
		ModeMedianPaymentReportWriter.PaymentReportRow row,
		string runId,
		string labName,
		int labId,
		decimal? metric1,
		decimal? metric2,
		decimal? metric3,
		decimal? metric4)
	{
		table.Rows.Add(
			Truncate(row.PayerName, 250),
			Truncate(row.Panel, 250),
			Truncate(row.CPTCode, 50),
			ToDb(row.AllowedAmount),
			ToDb(row.InsurancePaymentAmount),
			row.DistinctAllowedPaymentCount,
			ToDb(metric1),
			ToDb(metric2),
			ToDb(metric3),
			ToDb(metric4),
			TruncateRequired(labName, 50),
			labId,
			Truncate(runId, 50),
			Truncate(row.RollingDays, 20),
			ToDb(row.MinDateOfService),
			ToDb(row.MaxDateOfService),
			DateTime.Today);
	}

	private static object ToDb(decimal? value)
		=> value.HasValue ? value.Value : DBNull.Value;

	private static object ToDb(DateTime? value)
		=> value.HasValue ? value.Value : DBNull.Value;

	private static object Truncate(string? value, int maxLength)
	{
		if (string.IsNullOrWhiteSpace(value))
			return DBNull.Value;

		var trimmed = value.Trim();
		return trimmed.Length <= maxLength ? trimmed : trimmed.Substring(0, maxLength);
	}

	// LabName is NOT NULL in both tables, so never map it to DBNull.
	private static string TruncateRequired(string? value, int maxLength)
	{
		var trimmed = (value ?? string.Empty).Trim();
		return trimmed.Length <= maxLength ? trimmed : trimmed.Substring(0, maxLength);
	}
}
