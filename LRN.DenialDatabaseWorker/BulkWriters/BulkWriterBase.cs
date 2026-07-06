using System.Data;
using System.Globalization;
using System.Text.Json;
using DenialDatabaseProcessorWorker.Models;
using Microsoft.Data.SqlClient;

namespace DenialDatabaseProcessorWorker.BulkWriters;

public abstract class BulkWriterBase
{
	private readonly string _connectionString;

	protected BulkWriterBase(string connectionString)
	{
		_connectionString = connectionString;
	}

	protected async Task BulkInsertAsync(
		DataTable table,
		string targetTable,
		TableMapperConfig mapper)
	{
		if (table == null)
			throw new ArgumentNullException(nameof(table));

		if (mapper == null)
			throw new ArgumentNullException(nameof(mapper));

		using var conn = new SqlConnection(_connectionString);
		await conn.OpenAsync();

		// Lab databases drift: some are missing newer columns and some add their own
		// (including computed columns such as ClaimIDNormalized). Only map columns that
		// exist in THIS lab's table, otherwise SqlBulkCopy fails with a column mismatch.
		var destinationColumns = await GetDestinationColumnsAsync(conn, targetTable);

		var resolvedColumns = new List<ResolvedColumn>();

		foreach (var map in mapper.Columns)
		{
			if (!destinationColumns.TryGetValue(map.SqlColumn, out var destinationColumn))
				continue;

			string? sourceColumn = null;

			// Case 1: builder already created SQL column names
			if (table.Columns.Contains(map.SqlColumn))
			{
				sourceColumn = map.SqlColumn;
			}
			// Case 2: source table still has Excel/display column names
			else if (table.Columns.Contains(map.ExcelColumn))
			{
				sourceColumn = map.ExcelColumn;
			}

			if (sourceColumn != null)
				resolvedColumns.Add(new ResolvedColumn(sourceColumn, destinationColumn, map.DataType));
		}

		if (resolvedColumns.Count == 0)
		{
			throw new InvalidOperationException(
				$"No valid column mappings found for target table '{targetTable}'.");
		}

		// Stage rows into a table typed per the mapper so SqlBulkCopy never has to coerce
		// raw strings into int/decimal/bit/date destination columns (lab schemas differ).
		var typedTable = BuildTypedTable(table, resolvedColumns);

		using var bulk = new SqlBulkCopy(
			conn,
			SqlBulkCopyOptions.TableLock | SqlBulkCopyOptions.CheckConstraints,
			null)
		{
			DestinationTableName = targetTable,
			BatchSize = 500000,
			BulkCopyTimeout = 0
		};

		foreach (DataColumn column in typedTable.Columns)
			bulk.ColumnMappings.Add(column.ColumnName, column.ColumnName);

		await bulk.WriteToServerAsync(typedTable);
	}

	private sealed record ResolvedColumn(string SourceColumn, string DestinationColumn, string DataType);

	private static async Task<Dictionary<string, string>> GetDestinationColumnsAsync(
		SqlConnection conn,
		string targetTable)
	{
		const string sql = @"
SELECT c.name
FROM sys.columns c
WHERE c.object_id = OBJECT_ID(@TargetTable)
  AND c.is_computed = 0
  AND c.is_identity = 0";

		// Keyed case-insensitively but stores the exact destination casing,
		// so mappings always use the column name as deployed.
		var columns = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

		using var cmd = new SqlCommand(sql, conn);
		cmd.Parameters.AddWithValue("@TargetTable", targetTable);

		using var reader = await cmd.ExecuteReaderAsync();
		while (await reader.ReadAsync())
		{
			var name = reader.GetString(0);
			columns[name] = name;
		}

		if (columns.Count == 0)
		{
			throw new InvalidOperationException(
				$"Destination table '{targetTable}' was not found in the target database.");
		}

		return columns;
	}

	private static DataTable BuildTypedTable(DataTable source, List<ResolvedColumn> columns)
	{
		var typed = new DataTable();

		foreach (var col in columns)
			typed.Columns.Add(col.DestinationColumn, GetClrType(col.DataType));

		foreach (DataRow sourceRow in source.Rows)
		{
			var row = typed.NewRow();

			foreach (var col in columns)
				row[col.DestinationColumn] = ConvertValue(sourceRow[col.SourceColumn], col.DataType);

			typed.Rows.Add(row);
		}

		return typed;
	}

	private static Type GetClrType(string dataType) => dataType?.ToLowerInvariant() switch
	{
		"int" => typeof(int),
		"decimal" => typeof(decimal),
		"date" or "datetime" => typeof(DateTime),
		"boolean" or "bool" or "bit" => typeof(bool),
		_ => typeof(string)
	};

	private static object ConvertValue(object? raw, string dataType)
	{
		if (raw == null || raw == DBNull.Value)
			return DBNull.Value;

		// Already typed by a builder (e.g. DenialLineItemTableBuilder) — pass through.
		if (raw is not string)
			return raw;

		var text = raw.ToString()!.Trim();
		if (text.Length == 0)
			return DBNull.Value;

		switch (dataType?.ToLowerInvariant())
		{
			case "int":
				if (int.TryParse(text, NumberStyles.Any, CultureInfo.InvariantCulture, out var intValue))
					return intValue;

				// Excel often stores whole numbers as "1234.0"
				if (decimal.TryParse(text, NumberStyles.Any, CultureInfo.InvariantCulture, out var intAsDecimal) &&
					intAsDecimal == Math.Truncate(intAsDecimal) &&
					intAsDecimal >= int.MinValue && intAsDecimal <= int.MaxValue)
				{
					return (int)intAsDecimal;
				}

				return DBNull.Value;

			case "decimal":
				var cleaned = text.Replace("%", "").Replace(",", "");
				return decimal.TryParse(cleaned, NumberStyles.Any, CultureInfo.InvariantCulture, out var decimalValue)
					? decimalValue
					: DBNull.Value;

			case "date":
			case "datetime":
				if (DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.RoundtripKind, out var dateValue) ||
					DateTime.TryParse(text, CultureInfo.CurrentCulture, DateTimeStyles.AllowWhiteSpaces, out dateValue))
				{
					return dateValue;
				}

				return DBNull.Value;

			case "boolean":
			case "bool":
			case "bit":
				if (bool.TryParse(text, out var boolValue))
					return boolValue;

				if (text == "1") return true;
				if (text == "0") return false;

				return DBNull.Value;

			default:
				return text;
		}
	}

	protected static TableMapperConfig LoadMapper(string mapperFileName)
	{
		var basePath = AppContext.BaseDirectory;
		var fullPath = Path.Combine(basePath, mapperFileName);

		if (!File.Exists(fullPath))
			throw new FileNotFoundException($"Mapper file not found: {fullPath}");

		var json = File.ReadAllText(fullPath);
		var mapper = JsonSerializer.Deserialize<TableMapperConfig>(
			json,
			new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

		if (mapper == null)
			throw new InvalidOperationException($"Failed to deserialize mapper: {fullPath}");

		return mapper;
	}
}
