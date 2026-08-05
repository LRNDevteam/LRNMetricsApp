using System.Data;
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

		using var bulk = new SqlBulkCopy(
			conn,
			SqlBulkCopyOptions.TableLock | SqlBulkCopyOptions.CheckConstraints,
			null)
		{
			DestinationTableName = targetTable,
			BatchSize = 500000,
			BulkCopyTimeout = 0
		};

		foreach (var map in mapper.Columns)
		{
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
			{
				bulk.ColumnMappings.Add(sourceColumn, map.SqlColumn);
			}
		}

		if (bulk.ColumnMappings.Count == 0)
		{
			throw new InvalidOperationException(
				$"No valid column mappings found for target table '{targetTable}'.");
		}

		await bulk.WriteToServerAsync(table);
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