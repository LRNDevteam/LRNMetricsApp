using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Spreadsheet;
using LRN.MasterFileProcessorWorker.BulkLoad;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using System.Data;
using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;

public sealed class LimsMasterBulkImporter
{
	private readonly ILogger _logger;
	private const int DefaultBatchSize = 50000;

	/// <summary>Relaxed escaping keeps the stored JSON readable (&amp;, &lt;, quotes stay legible).</summary>
	private static readonly JsonSerializerOptions JsonOptions = new()
	{
		Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
	};

	public LimsMasterBulkImporter(ILogger logger)
	{
		_logger = logger;
	}

	public async Task<LimsImportResult> ImportAsync(LimsImportRequest request, CancellationToken ct)
	{
		if (string.IsNullOrWhiteSpace(request.ExcelPath) || !File.Exists(request.ExcelPath))
			throw new FileNotFoundException("LIMS Excel file not found.", request.ExcelPath);

		if (string.IsNullOrWhiteSpace(request.ConnectionString))
			throw new InvalidOperationException("LIMS lab DB connection string is missing. Configure LabDbConnectionString for the lab.");

		var tableName = string.IsNullOrWhiteSpace(request.DestinationTable) ? "dbo.LIMSMaster" : request.DestinationTable!;
		var batchSize = request.BatchSize <= 0 ? DefaultBatchSize : request.BatchSize;
		var runCreatedOn = request.CreatedOn == default ? DateTime.Now : request.CreatedOn;

		var mappingsFromSchema = LimsSchemaMapping.Load(request.SchemaJsonPath);
		await using var connection = new SqlConnection(request.ConnectionString);
		await connection.OpenAsync(ct);

		var destinationColumns = await LoadDestinationColumnsAsync(connection, tableName, ct);
		if (destinationColumns.Count == 0)
			throw new InvalidOperationException($"Destination table '{tableName}' was not found or has no columns.");

		var disabledIndexes = new List<string>();
		var triggersDisabled = false;

		try
		{
			if (request.TruncateBeforeLoad)
			{
				await ExecuteNonQueryAsync(connection, $"TRUNCATE TABLE {QuoteTableName(tableName)};", ct);
				_logger.LogInformation("LIMS import: truncated {TableName}", tableName);
			}

			if (request.DisableTriggersDuringLoad)
			{
				await ExecuteNonQueryAsync(connection, $"DISABLE TRIGGER ALL ON {QuoteTableName(tableName)};", ct);
				triggersDisabled = true;
				_logger.LogInformation("LIMS import: disabled triggers on {TableName}", tableName);
			}

			if (request.DisableNonClusteredIndexesDuringLoad)
			{
				disabledIndexes = await DisableNonClusteredIndexesAsync(connection, tableName, ct);
				if (disabledIndexes.Count > 0)
					_logger.LogInformation("LIMS import: disabled {Count} non-clustered indexes on {TableName}", disabledIndexes.Count, tableName);
			}

			var result = await StreamExcelToSqlAsync(
				request,
				connection,
				tableName,
				destinationColumns,
				mappingsFromSchema,
				batchSize,
				runCreatedOn,
				ct);

			return result;
		}
		finally
		{
			if (triggersDisabled)
			{
				try { await ExecuteNonQueryAsync(connection, $"ENABLE TRIGGER ALL ON {QuoteTableName(tableName)};", CancellationToken.None); }
				catch (Exception ex) { _logger.LogWarning(ex, "LIMS import: failed to re-enable triggers on {TableName}", tableName); }
			}

			foreach (var indexName in disabledIndexes)
			{
				try { await ExecuteNonQueryAsync(connection, $"ALTER INDEX {QuoteIdentifier(indexName)} ON {QuoteTableName(tableName)} REBUILD;", CancellationToken.None); }
				catch (Exception ex) { _logger.LogWarning(ex, "LIMS import: failed to rebuild index {IndexName} on {TableName}", indexName, tableName); }
			}
		}
	}

	private async Task<LimsImportResult> StreamExcelToSqlAsync(
		LimsImportRequest request,
		SqlConnection connection,
		string tableName,
		List<SqlDestinationColumn> destinationColumns,
		List<LimsColumnMapping> schemaMappings,
		int batchSize,
		DateTime runCreatedOn,
		CancellationToken ct)
	{
		using var document = SpreadsheetDocument.Open(request.ExcelPath, false);
		var workbookPart = document.WorkbookPart ?? throw new InvalidOperationException("Invalid workbook. WorkbookPart is missing.");
		var sharedStrings = LoadSharedStrings(workbookPart);
		var dateStyleIndexes = LoadDateStyleIndexes(workbookPart);
		var selectedSheet = SelectWorksheet(workbookPart, sharedStrings, request.PreferredSheetName, schemaMappings, destinationColumns);

		_logger.LogInformation("LIMS import: selected worksheet '{SheetName}' from {File}", selectedSheet.SheetName, Path.GetFileName(request.ExcelPath));

		var headerMap = selectedSheet.Headers
			.Where(h => !string.IsNullOrWhiteSpace(h.Value))
			.GroupBy(h => NormalizeName(h.Value))
			.ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);

		var plan = BuildLoadPlan(destinationColumns, schemaMappings, headerMap, request);
		var columnsToLoad = plan.LoadColumns;

		if (columnsToLoad.Count == 0)
			throw new InvalidOperationException("No matching LIMS columns found between Excel/schema and destination table.");

		if (plan.ExcludedSensitiveHeaders.Count > 0)
		{
			_logger.LogWarning(
				"LIMS import: {Count} sheet column(s) were DROPPED and not captured, per the sensitive-column policy: {Columns}",
				plan.ExcludedSensitiveHeaders.Count,
				string.Join(", ", plan.ExcludedSensitiveHeaders));
		}

		if (plan.AdditionalHeaders.Count > 0)
		{
			_logger.LogInformation(
				"LIMS import: {Count} sheet column(s) are not in the schema JSON and will be captured as JSON in {Column}: {Columns}",
				plan.AdditionalHeaders.Count,
				plan.AdditionalFieldsColumn!.Name,
				string.Join(", ", plan.AdditionalHeaders.Select(h => h.Value)));
		}
		else if (request.CaptureAdditionalFields && plan.AdditionalFieldsColumn == null)
		{
			_logger.LogInformation(
				"LIMS import: {TableName} has no {Column} column, so any column added to the file beyond the schema JSON is dropped. " +
				"Run sql/Create_LIMSMaster.sql to add it.",
				tableName,
				request.AdditionalFieldsColumn);
		}

		var table = CreateDataTable(columnsToLoad);
		var totalRows = 0;
		var copiedRows = 0;
		var firstDataRowNumber = selectedSheet.HeaderRowNumber + 1;

		using var reader = OpenXmlReader.Create(selectedSheet.WorksheetPart);
		while (reader.Read())
		{
			ct.ThrowIfCancellationRequested();
			if (reader.ElementType != typeof(Row) || !reader.IsStartElement)
				continue;

			var row = (Row)reader.LoadCurrentElement();
			var rowNumber = (int)(row.RowIndex?.Value ?? 0);
			if (rowNumber < firstDataRowNumber)
				continue;

			var valuesByColumnIndex = ReadRowValues(row, sharedStrings, dateStyleIndexes);
			if (IsBlankDataRow(valuesByColumnIndex))
				continue;

			var dataRow = table.NewRow();
			var hasAnyMappedValue = false;

			foreach (var loadColumn in columnsToLoad)
			{
				object? value = null;

				if (loadColumn.SpecialColumn == LimsSpecialColumn.CreatedOn)
					value = runCreatedOn;
				else if (loadColumn.SpecialColumn == LimsSpecialColumn.LabId)
					value = request.LabId;
				else if (loadColumn.SpecialColumn == LimsSpecialColumn.LabName)
					value = request.LabName;
				else if (loadColumn.SpecialColumn == LimsSpecialColumn.SourceFileName)
					value = Path.GetFileName(request.ExcelPath);
				else if (loadColumn.SpecialColumn == LimsSpecialColumn.RunId)
					value = request.RunId;
				else if (loadColumn.SpecialColumn == LimsSpecialColumn.AdditionalFields)
				{
					value = BuildAdditionalFieldsJson(plan.AdditionalHeaders, valuesByColumnIndex, loadColumn.DestinationColumn.MaxLength);

					// A row carrying only new columns is still a row. Without this it would be
					// discarded as empty and the new data would silently never arrive.
					if (value != null)
						hasAnyMappedValue = true;
				}
				else if (loadColumn.ExcelColumnIndex.HasValue && valuesByColumnIndex.TryGetValue(loadColumn.ExcelColumnIndex.Value, out var text))
				{
					value = ConvertValue(text, loadColumn.DestinationColumn);
					if (!string.IsNullOrWhiteSpace(text))
						hasAnyMappedValue = true;
				}

				dataRow[loadColumn.DestinationColumn.Name] = value ?? DBNull.Value;
			}

			if (!hasAnyMappedValue)
				continue;

			table.Rows.Add(dataRow);
			totalRows++;

			if (table.Rows.Count >= batchSize)
			{
				copiedRows += await BulkCopyAsync(connection, tableName, table, batchSize, ct);
				table.Clear();
			}
		}

		if (table.Rows.Count > 0)
		{
			copiedRows += await BulkCopyAsync(connection, tableName, table, batchSize, ct);
			table.Clear();
		}

		return new LimsImportResult
		{
			FilePath = request.ExcelPath,
			SheetName = selectedSheet.SheetName,
			HeaderRowNumber = selectedSheet.HeaderRowNumber,
			TotalRowsRead = totalRows,
			TotalRowsCopied = copiedRows,
			CreatedOn = runCreatedOn,
			DestinationTable = tableName,
			AdditionalFieldNames = plan.AdditionalHeaders.Select(h => h.Value).ToList(),
			ExcludedSensitiveColumns = plan.ExcludedSensitiveHeaders
		};
	}

	/// <summary>
	/// Works out which destination column each sheet column feeds, and which sheet columns feed none.
	/// <para>
	/// The leftovers are the point of this method: a lab that adds columns to its LIMS file should
	/// not need an ALTER TABLE and a schema-JSON edit before the data can land. Anything the schema
	/// JSON does not name and no destination column claims is written to the <c>AdditionalFields</c>
	/// JSON column instead of being discarded.
	/// </para>
	/// </summary>
	private static LimsLoadPlan BuildLoadPlan(
		List<SqlDestinationColumn> destinationColumns,
		List<LimsColumnMapping> schemaMappings,
		Dictionary<string, ExcelHeaderInfo> headerMap,
		LimsImportRequest request)
	{
		var schemaByDestination = schemaMappings
			.GroupBy(m => NormalizeName(m.DestinationName))
			.ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);

		var additionalFieldsName = string.IsNullOrWhiteSpace(request.AdditionalFieldsColumn)
			? "AdditionalFields"
			: request.AdditionalFieldsColumn!;

		var loadColumns = new List<LimsLoadColumn>();
		var claimedHeaderIndexes = new HashSet<int>();
		SqlDestinationColumn? additionalFieldsColumn = null;

		foreach (var dest in destinationColumns.Where(c => !c.IsIdentity && !c.IsComputed))
		{
			var normalizedDest = NormalizeName(dest.Name);

			if (normalizedDest == NormalizeName(additionalFieldsName))
			{
				if (request.CaptureAdditionalFields)
				{
					additionalFieldsColumn = dest;
					loadColumns.Add(new LimsLoadColumn(dest, null, LimsSpecialColumn.AdditionalFields));
				}

				continue;
			}

			var special = GetSpecialColumn(dest.Name);

			if (special != LimsSpecialColumn.None)
			{
				loadColumns.Add(new LimsLoadColumn(dest, null, special));
				continue;
			}

			var candidateNames = new List<string> { dest.Name };
			if (schemaByDestination.TryGetValue(normalizedDest, out var mapping))
			{
				candidateNames.Add(mapping.DestinationName);
				candidateNames.AddRange(mapping.SourceNames);
			}

			ExcelHeaderInfo? matchedHeader = null;
			foreach (var candidate in candidateNames.Where(x => !string.IsNullOrWhiteSpace(x)))
			{
				if (headerMap.TryGetValue(NormalizeName(candidate), out matchedHeader))
					break;
			}

			if (matchedHeader != null)
			{
				loadColumns.Add(new LimsLoadColumn(dest, matchedHeader.ColumnIndex, LimsSpecialColumn.None));
				claimedHeaderIndexes.Add(matchedHeader.ColumnIndex);
			}
		}

		var additionalHeaders = new List<ExcelHeaderInfo>();
		var excludedHeaders = new List<string>();

		if (additionalFieldsColumn != null)
		{
			// "Known to the schema" is judged on the schema JSON alone, not on what got loaded: a
			// column the schema names but whose SQL column is missing from the table stays out of
			// the JSON, so AdditionalFields never quietly duplicates a mapping mistake.
			var knownToSchema = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
			foreach (var m in schemaMappings)
			{
				knownToSchema.Add(NormalizeName(m.DestinationName));
				foreach (var s in m.SourceNames) knownToSchema.Add(NormalizeName(s));
			}

			foreach (var header in headerMap.Values.OrderBy(h => h.ColumnIndex))
			{
				var normalized = NormalizeName(header.Value);

				if (normalized.Length == 0
					|| claimedHeaderIndexes.Contains(header.ColumnIndex)
					|| knownToSchema.Contains(normalized)
					|| GetSpecialColumn(header.Value) != LimsSpecialColumn.None
					|| normalized == NormalizeName(additionalFieldsName))
					continue;

				// Policy deny-list wins over "capture everything we do not recognise". Dropped here,
				// at plan time, so the value is never read into a row in the first place.
				if (SensitiveColumns.IsBlocked(header.Value))
				{
					excludedHeaders.Add(header.Value);
					continue;
				}

				additionalHeaders.Add(header);
			}
		}

		return new LimsLoadPlan(loadColumns, additionalHeaders, additionalFieldsColumn, excludedHeaders);
	}

	/// <summary>
	/// The row's unlisted sheet columns as one JSON object, or null when the row filled none of them.
	/// <para>
	/// Blank values are left out, so a column that is mostly empty costs almost nothing per row.
	/// If the destination column is sized rather than NVARCHAR(MAX), trailing pairs are dropped
	/// until the value fits - the stored text stays parseable JSON rather than being cut mid-string.
	/// </para>
	/// </summary>
	private static string? BuildAdditionalFieldsJson(
		IReadOnlyList<ExcelHeaderInfo> headers,
		Dictionary<int, string> valuesByColumnIndex,
		int maxLength)
	{
		if (headers.Count == 0)
			return null;

		Dictionary<string, string>? payload = null;

		foreach (var header in headers)
		{
			if (!valuesByColumnIndex.TryGetValue(header.ColumnIndex, out var text) || string.IsNullOrWhiteSpace(text))
				continue;

			payload ??= new Dictionary<string, string>(StringComparer.Ordinal);
			payload[header.Value] = text.Trim();
		}

		if (payload is null)
			return null;

		var json = JsonSerializer.Serialize(payload, JsonOptions);

		while (maxLength > 0 && json.Length > maxLength && payload.Count > 0)
		{
			payload.Remove(payload.Keys.Last());
			json = JsonSerializer.Serialize(payload, JsonOptions);
		}

		return payload.Count == 0 ? null : json;
	}

	private static LimsSpecialColumn GetSpecialColumn(string columnName)
	{
		var n = NormalizeName(columnName);
		if (n == "createdon" || n == "ingestedon") return LimsSpecialColumn.CreatedOn;
		if (n == "labid") return LimsSpecialColumn.LabId;
		if (n == "labname") return LimsSpecialColumn.LabName;
		if (n == "sourcefile" || n == "sourcefileid" || n == "sourcefilename" || n == "filename") return LimsSpecialColumn.SourceFileName;
		if (n == "runid") return LimsSpecialColumn.RunId;
		return LimsSpecialColumn.None;
	}

	private static DataTable CreateDataTable(List<LimsLoadColumn> columns)
	{
		var table = new DataTable();
		foreach (var col in columns)
			table.Columns.Add(col.DestinationColumn.Name, GetClrType(col.DestinationColumn.SqlTypeName));
		return table;
	}

	private static async Task<int> BulkCopyAsync(SqlConnection connection, string tableName, DataTable table, int batchSize, CancellationToken ct)
	{
		using var bulkCopy = new SqlBulkCopy(connection, SqlBulkCopyOptions.TableLock | SqlBulkCopyOptions.KeepNulls, null)
		{
			DestinationTableName = tableName,
			BatchSize = batchSize,
			BulkCopyTimeout = 0,
			EnableStreaming = true
		};

		foreach (DataColumn col in table.Columns)
			bulkCopy.ColumnMappings.Add(col.ColumnName, col.ColumnName);

		await bulkCopy.WriteToServerAsync(table, ct);
		return table.Rows.Count;
	}

	private static object? ConvertValue(string? value, SqlDestinationColumn destinationColumn)
	{
		if (string.IsNullOrWhiteSpace(value))
			return null;

		value = value.Trim();
		var type = destinationColumn.SqlTypeName.ToLowerInvariant();

		try
		{
			if (type.Contains("date") || type.Contains("time"))
			{
				if (double.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var oa))
					return DateTime.FromOADate(oa);

				if (DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt))
					return dt;

				if (DateTime.TryParse(value, CultureInfo.CurrentCulture, DateTimeStyles.None, out dt))
					return dt;

				return null;
			}

			if (type is "int")
				return int.TryParse(RemoveExcelDecimal(value), NumberStyles.Any, CultureInfo.InvariantCulture, out var i) ? i : null;

			if (type is "bigint")
				return long.TryParse(RemoveExcelDecimal(value), NumberStyles.Any, CultureInfo.InvariantCulture, out var l) ? l : null;

			if (type is "smallint")
				return short.TryParse(RemoveExcelDecimal(value), NumberStyles.Any, CultureInfo.InvariantCulture, out var s) ? s : null;

			if (type is "tinyint")
				return byte.TryParse(RemoveExcelDecimal(value), NumberStyles.Any, CultureInfo.InvariantCulture, out var b) ? b : null;

			if (type is "bit")
			{
				if (bool.TryParse(value, out var boolValue)) return boolValue;
				if (value == "1") return true;
				if (value == "0") return false;
				return null;
			}

			if (type is "decimal" or "numeric" or "money" or "smallmoney")
				return decimal.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var d) ? d : null;

			if (type is "float")
				return double.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var dbl) ? dbl : null;

			if (type is "real")
				return float.TryParse(value, NumberStyles.Any, CultureInfo.InvariantCulture, out var f) ? f : null;
		}
		catch
		{
			return null;
		}

		if (destinationColumn.MaxLength > 0 && value.Length > destinationColumn.MaxLength)
			return value[..destinationColumn.MaxLength];

		return value;
	}

	private static string RemoveExcelDecimal(string value)
	{
		return Regex.IsMatch(value, @"^-?\d+\.0+$") ? value[..value.IndexOf('.', StringComparison.Ordinal)] : value;
	}

	private static Type GetClrType(string sqlTypeName)
	{
		return sqlTypeName.ToLowerInvariant() switch
		{
			"int" => typeof(int),
			"bigint" => typeof(long),
			"smallint" => typeof(short),
			"tinyint" => typeof(byte),
			"bit" => typeof(bool),
			"decimal" or "numeric" or "money" or "smallmoney" => typeof(decimal),
			"float" => typeof(double),
			"real" => typeof(float),
			"date" or "datetime" or "datetime2" or "smalldatetime" => typeof(DateTime),
			_ => typeof(string)
		};
	}

	private static LimsWorksheetSelection SelectWorksheet(
		WorkbookPart workbookPart,
		IReadOnlyList<string> sharedStrings,
		string? preferredSheetName,
		List<LimsColumnMapping> schemaMappings,
		List<SqlDestinationColumn> destinationColumns)
	{
		var sheets = workbookPart.Workbook.Sheets?.Elements<Sheet>().ToList() ?? new List<Sheet>();
		if (sheets.Count == 0)
			throw new InvalidOperationException("Workbook does not contain sheets.");

		var preferredNames = new[] { preferredSheetName, "Masterfile", "Master File", "LIMS", "LIMS Master" }
			.Where(x => !string.IsNullOrWhiteSpace(x))
			.Select(NormalizeName)
			.ToHashSet(StringComparer.OrdinalIgnoreCase);

		LimsWorksheetSelection? best = null;

		foreach (var sheet in sheets)
		{
			if (sheet.Id == null) continue;
			var part = (WorksheetPart)workbookPart.GetPartById(sheet.Id!);
			var selection = InspectWorksheet(part, sheet.Name?.Value ?? string.Empty, sharedStrings, schemaMappings, destinationColumns);

			if (preferredNames.Contains(NormalizeName(selection.SheetName)) && selection.Headers.Count > 0)
				return selection;

			if (best == null || selection.MatchScore > best.MatchScore)
				best = selection;
		}

		return best ?? throw new InvalidOperationException("No valid worksheet found in LIMS workbook.");
	}

	private static LimsWorksheetSelection InspectWorksheet(
		WorksheetPart part,
		string sheetName,
		IReadOnlyList<string> sharedStrings,
		List<LimsColumnMapping> schemaMappings,
		List<SqlDestinationColumn> destinationColumns)
	{
		var expected = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
		foreach (var c in destinationColumns) expected.Add(NormalizeName(c.Name));
		foreach (var m in schemaMappings)
		{
			expected.Add(NormalizeName(m.DestinationName));
			foreach (var s in m.SourceNames) expected.Add(NormalizeName(s));
		}

		using var reader = OpenXmlReader.Create(part);
		var checkedRows = 0;
		var bestHeaders = new List<ExcelHeaderInfo>();
		var bestScore = -1;
		var bestRow = 1;

		while (reader.Read() && checkedRows < 20)
		{
			if (reader.ElementType != typeof(Row) || !reader.IsStartElement)
				continue;

			var row = (Row)reader.LoadCurrentElement();
			checkedRows++;
			var headers = ReadRowValues(row, sharedStrings)
				.Where(kv => !string.IsNullOrWhiteSpace(kv.Value))
				.Select(kv => new ExcelHeaderInfo(kv.Key, kv.Value.Trim()))
				.ToList();

			var score = headers.Count(h => expected.Contains(NormalizeName(h.Value)));
			if (score > bestScore)
			{
				bestScore = score;
				bestHeaders = headers;
				bestRow = (int)(row.RowIndex?.Value ?? 0);
			}
		}

		return new LimsWorksheetSelection(part, sheetName, bestRow, bestHeaders, bestScore);
	}

	private static Dictionary<int, string> ReadRowValues(Row row, IReadOnlyList<string> sharedStrings, HashSet<int>? dateStyleIndexes = null)
	{
		var result = new Dictionary<int, string>();
		foreach (var cell in row.Elements<Cell>())
		{
			var index = GetColumnIndex(cell.CellReference?.Value);
			if (index <= 0) continue;
			result[index] = GetCellValue(cell, sharedStrings, dateStyleIndexes);
		}
		return result;
	}

	private static bool IsBlankDataRow(Dictionary<int, string> values)
	{
		return values.Count == 0 || values.Values.All(string.IsNullOrWhiteSpace);
	}

	private static string GetCellValue(Cell cell, IReadOnlyList<string> sharedStrings, HashSet<int>? dateStyleIndexes = null)
	{
		var raw = cell.CellValue?.Text ?? cell.InnerText ?? string.Empty;
		if (cell.DataType == null)
		{
			// Detect date-formatted cells: DataType is null for numeric cells; style index identifies date formats.
			if (dateStyleIndexes != null
				&& cell.StyleIndex?.HasValue == true
				&& dateStyleIndexes.Contains((int)cell.StyleIndex.Value)
				&& !string.IsNullOrEmpty(raw)
				&& double.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out var oaDate))
			{
				try { return DateTime.FromOADate(oaDate).ToString("MM/dd/yyyy", CultureInfo.InvariantCulture); }
				catch { }
			}
			return raw;
		}

		if (cell.DataType.Value == CellValues.SharedString && int.TryParse(raw, out var sharedIndex))
			return sharedIndex >= 0 && sharedIndex < sharedStrings.Count ? sharedStrings[sharedIndex] : string.Empty;

		if (cell.DataType.Value == CellValues.InlineString)
			return cell.InlineString?.Text?.Text ?? cell.InnerText ?? string.Empty;

		if (cell.DataType.Value == CellValues.Boolean)
			return raw == "1" ? "true" : "false";

		return raw;
	}

	private static List<string> LoadSharedStrings(WorkbookPart workbookPart)
	{
		return workbookPart.SharedStringTablePart?.SharedStringTable
			.Elements<SharedStringItem>()
			.Select(x => x.InnerText ?? string.Empty)
			.ToList() ?? new List<string>();
	}

	private static HashSet<int> LoadDateStyleIndexes(WorkbookPart workbookPart)
	{
		var result = new HashSet<int>();
		var stylesheet = workbookPart.WorkbookStylesPart?.Stylesheet;
		if (stylesheet == null) return result;

		// ECMA-376 built-in date numFmtIds (14-17=date-only, 22=date+time; 18-21 and 45-47 are time-only)
		var dateNumFmtIds = new HashSet<int> { 14, 15, 16, 17, 22 };

		// Add any custom number formats whose format code represents a date
		if (stylesheet.NumberingFormats != null)
		{
			foreach (var nf in stylesheet.NumberingFormats.Elements<NumberingFormat>())
			{
				var id = (int)(nf.NumberFormatId?.Value ?? 0);
				var fmt = nf.FormatCode?.Value ?? string.Empty;
				if (IsDateFormatCode(fmt))
					dateNumFmtIds.Add(id);
			}
		}

		// Map each CellFormat style index to whether its numFmtId is a date format
		if (stylesheet.CellFormats != null)
		{
			var styleIdx = 0;
			foreach (var cf in stylesheet.CellFormats.Elements<CellFormat>())
			{
				var numFmtId = (int)(cf.NumberFormatId?.Value ?? 0);
				if (dateNumFmtIds.Contains(numFmtId))
					result.Add(styleIdx);
				styleIdx++;
			}
		}

		return result;
	}

	private static bool IsDateFormatCode(string formatCode)
	{
		if (string.IsNullOrWhiteSpace(formatCode)) return false;
		// Strip quoted literal text (e.g. "\"some text\"") and escaped chars (\x)
		var cleaned = Regex.Replace(formatCode, "\"[^\"]*\"", string.Empty);
		cleaned = Regex.Replace(cleaned, @"\\.", string.Empty);
		// A date format code contains 'y' or 'Y' (year part)
		return cleaned.IndexOf('y') >= 0 || cleaned.IndexOf('Y') >= 0;
	}

	private static int GetColumnIndex(string? cellReference)
	{
		if (string.IsNullOrWhiteSpace(cellReference)) return 0;
		var columnName = Regex.Replace(cellReference.ToUpperInvariant(), "[^A-Z]", "");
		var sum = 0;
		foreach (var c in columnName)
			sum = (sum * 26) + (c - 'A' + 1);
		return sum;
	}

	private static async Task<List<SqlDestinationColumn>> LoadDestinationColumnsAsync(SqlConnection connection, string tableName, CancellationToken ct)
	{
		var (schema, table) = SplitTableName(tableName);
		const string sql = @"
SELECT
    c.name AS ColumnName,
    t.name AS SqlTypeName,
    c.max_length AS MaxLength,
    c.is_identity AS IsIdentity,
    c.is_computed AS IsComputed
FROM sys.columns c
INNER JOIN sys.types t ON c.user_type_id = t.user_type_id
INNER JOIN sys.tables tb ON c.object_id = tb.object_id
INNER JOIN sys.schemas s ON tb.schema_id = s.schema_id
WHERE s.name = @schema AND tb.name = @table
ORDER BY c.column_id;";

		var result = new List<SqlDestinationColumn>();
		await using var cmd = new SqlCommand(sql, connection);
		cmd.Parameters.AddWithValue("@schema", schema);
		cmd.Parameters.AddWithValue("@table", table);
		await using var reader = await cmd.ExecuteReaderAsync(ct);
		while (await reader.ReadAsync(ct))
		{
			var maxLength = Convert.ToInt32(reader["MaxLength"], CultureInfo.InvariantCulture);
			var typeName = Convert.ToString(reader["SqlTypeName"], CultureInfo.InvariantCulture) ?? "nvarchar";
			if ((typeName == "nvarchar" || typeName == "nchar") && maxLength > 0) maxLength /= 2;
			result.Add(new SqlDestinationColumn(
				Convert.ToString(reader["ColumnName"], CultureInfo.InvariantCulture)!,
				typeName,
				maxLength,
				Convert.ToBoolean(reader["IsIdentity"], CultureInfo.InvariantCulture),
				Convert.ToBoolean(reader["IsComputed"], CultureInfo.InvariantCulture)));
		}
		return result;
	}

	private static async Task<List<string>> DisableNonClusteredIndexesAsync(SqlConnection connection, string tableName, CancellationToken ct)
	{
		var (schema, table) = SplitTableName(tableName);
		const string sql = @"
							SELECT i.name
							FROM sys.indexes i
							INNER JOIN sys.tables t ON i.object_id = t.object_id
							INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
							WHERE s.name = @schema
							  AND t.name = @table
							  AND i.type_desc = 'NONCLUSTERED'
							  AND i.is_primary_key = 0
							  AND i.is_unique_constraint = 0
							  AND i.name IS NOT NULL;";

		var indexes = new List<string>();
		await using (var cmd = new SqlCommand(sql, connection))
		{
			cmd.Parameters.AddWithValue("@schema", schema);
			cmd.Parameters.AddWithValue("@table", table);
			await using var reader = await cmd.ExecuteReaderAsync(ct);
			while (await reader.ReadAsync(ct))
				indexes.Add(reader.GetString(0));
		}

		foreach (var index in indexes)
			await ExecuteNonQueryAsync(connection, $"ALTER INDEX {QuoteIdentifier(index)} ON {QuoteTableName(tableName)} DISABLE;", ct);

		return indexes;
	}

	private static async Task ExecuteNonQueryAsync(SqlConnection connection, string sql, CancellationToken ct)
	{
		await using var cmd = new SqlCommand(sql, connection) { CommandTimeout = 0 };
		await cmd.ExecuteNonQueryAsync(ct);
	}

	private static (string Schema, string Table) SplitTableName(string tableName)
	{
		var parts = tableName.Split('.', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
		return parts.Length == 2 ? (CleanIdentifier(parts[0]), CleanIdentifier(parts[1])) : ("dbo", CleanIdentifier(tableName));
	}

	private static string QuoteTableName(string tableName)
	{
		var (schema, table) = SplitTableName(tableName);
		return $"{QuoteIdentifier(schema)}.{QuoteIdentifier(table)}";
	}

	private static string QuoteIdentifier(string value)
	{
		return $"[{CleanIdentifier(value).Replace("]", "]]", StringComparison.Ordinal)}]";
	}

	private static string CleanIdentifier(string value)
	{
		return value.Trim().Trim('[', ']');
	}

	private static string NormalizeName(string? value)
	{
		if (string.IsNullOrWhiteSpace(value)) return string.Empty;
		return Regex.Replace(value.Trim(), @"[^A-Za-z0-9]", "").ToLowerInvariant();
	}

	private sealed record LimsWorksheetSelection(WorksheetPart WorksheetPart, string SheetName, int HeaderRowNumber, List<ExcelHeaderInfo> Headers, int MatchScore);
	private sealed record ExcelHeaderInfo(int ColumnIndex, string Value);
	private sealed record SqlDestinationColumn(string Name, string SqlTypeName, int MaxLength, bool IsIdentity, bool IsComputed);
	private sealed record LimsLoadColumn(SqlDestinationColumn DestinationColumn, int? ExcelColumnIndex, LimsSpecialColumn SpecialColumn);
	private sealed record LimsLoadPlan(
		List<LimsLoadColumn> LoadColumns,
		List<ExcelHeaderInfo> AdditionalHeaders,
		SqlDestinationColumn? AdditionalFieldsColumn,
		List<string> ExcludedSensitiveHeaders);
	private enum LimsSpecialColumn { None, CreatedOn, LabId, LabName, SourceFileName, RunId, AdditionalFields }

	private sealed class LimsSchemaMapping
	{
		public string DestinationName { get; set; } = string.Empty;
		public List<string> SourceNames { get; set; } = new();

		public static List<LimsColumnMapping> Load(string? schemaPath)
		{
			var result = new List<LimsColumnMapping>();

			if (string.IsNullOrWhiteSpace(schemaPath) || !File.Exists(schemaPath))
				return result;

			using var doc = JsonDocument.Parse(File.ReadAllText(schemaPath));

			if (!doc.RootElement.TryGetProperty("Columns", out var columns) ||
				columns.ValueKind != JsonValueKind.Array)
				return result;

			foreach (var col in columns.EnumerateArray())
			{
				var sqlColName =
					ReadString(col, "SQLColName")
					?? ReadString(col, "Name")
					?? ReadString(col, "ColumnName")
					?? ReadString(col, "Destination");

				if (string.IsNullOrWhiteSpace(sqlColName))
					continue;

				var mapping = new LimsColumnMapping
				{
					DestinationName = sqlColName.Trim()
				};

				AddIfNotBlank(mapping.SourceNames, ReadString(col, "ExcelColName"));
				AddIfNotBlank(mapping.SourceNames, ReadString(col, "ExcelCoName"));
				AddIfNotBlank(mapping.SourceNames, ReadString(col, "Source"));
				AddIfNotBlank(mapping.SourceNames, ReadString(col, "SourceName"));
				AddIfNotBlank(mapping.SourceNames, ReadString(col, "Header"));
				AddIfNotBlank(mapping.SourceNames, ReadString(col, "ExcelHeader"));

				foreach (var prop in new[] { "Aliases", "SourceColumns", "SourceNames" })
				{
					if (col.TryGetProperty(prop, out var arr) && arr.ValueKind == JsonValueKind.Array)
					{
						foreach (var item in arr.EnumerateArray())
							AddIfNotBlank(mapping.SourceNames, item.GetString());
					}
				}

				result.Add(mapping);
			}

			return result;
		}

		private static string? ReadString(JsonElement element, string propertyName)
		{
			return element.TryGetProperty(propertyName, out var prop) && prop.ValueKind == JsonValueKind.String ? prop.GetString() : null;
		}

		private static void AddIfNotBlank(List<string> list, string? value)
		{
			if (!string.IsNullOrWhiteSpace(value)) list.Add(value.Trim());
		}
	}
}

public sealed class LimsImportRequest
{
	public string ExcelPath { get; set; } = string.Empty;
	public string ConnectionString { get; set; } = string.Empty;
	public string DestinationTable { get; set; } = "dbo.LIMSMaster";
	public string? SchemaJsonPath { get; set; }
	public string PreferredSheetName { get; set; } = "Masterfile";
	public int BatchSize { get; set; } = 50000;
	public bool TruncateBeforeLoad { get; set; } = true;
	public bool DisableNonClusteredIndexesDuringLoad { get; set; } = true;
	public bool DisableTriggersDuringLoad { get; set; } = true;
	public DateTime CreatedOn { get; set; } = DateTime.Now;
	public int? LabId { get; set; }
	public string? LabName { get; set; }
	public string? RunId { get; set; }

	/// <summary>
	/// Capture sheet columns the schema JSON does not name into <see cref="AdditionalFieldsColumn"/>
	/// as JSON, rather than dropping them.
	/// <para>
	/// On by default, but it only takes effect where the destination table actually has that column,
	/// so a database that has not run sql/Create_LIMSMaster.sql keeps loading exactly as before.
	/// </para>
	/// </summary>
	public bool CaptureAdditionalFields { get; set; } = true;

	/// <summary>Destination column that holds the JSON. NVARCHAR(MAX) is expected.</summary>
	public string AdditionalFieldsColumn { get; set; } = "AdditionalFields";
}

public sealed class LimsImportResult
{
	public string FilePath { get; set; } = string.Empty;
	public string SheetName { get; set; } = string.Empty;
	public int HeaderRowNumber { get; set; }
	public int TotalRowsRead { get; set; }
	public int TotalRowsCopied { get; set; }
	public DateTime CreatedOn { get; set; }
	public string DestinationTable { get; set; } = string.Empty;

	/// <summary>Sheet columns that went into the AdditionalFields JSON instead of their own column.</summary>
	public IReadOnlyList<string> AdditionalFieldNames { get; set; } = Array.Empty<string>();

	/// <summary>
	/// Sheet columns dropped by the sensitive-column policy - present in the file, deliberately not
	/// stored. Reported so an audit can show the pipeline saw them and refused them.
	/// </summary>
	public IReadOnlyList<string> ExcludedSensitiveColumns { get; set; } = Array.Empty<string>();
}

public sealed class LimsColumnMapping
{
	public string DestinationName { get; set; } = string.Empty;
	public List<string> SourceNames { get; set; } = new();
}
