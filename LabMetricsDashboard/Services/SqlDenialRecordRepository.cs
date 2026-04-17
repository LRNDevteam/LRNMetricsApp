using System.Data;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.ViewModels;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Caching.Memory;

namespace LabMetricsDashboard.Services;

public class SqlDenialRecordRepository : IDenialRecordRepository
{
	private static readonly HashSet<int> ClaimLevelInsuranceBalanceLabIds = new([18, 19, 20]);
	private static readonly TimeSpan LabsCacheDuration = TimeSpan.FromMinutes(15);
	private static readonly TimeSpan TaskBoardCacheDuration = TimeSpan.FromMinutes(5);
	private static readonly TimeSpan CurrentRunCacheDuration = TimeSpan.FromMinutes(5);
	private static readonly TimeSpan ExportPathCacheDuration = TimeSpan.FromMinutes(3);
	private static readonly TimeSpan AutocompleteCacheDuration = TimeSpan.FromMinutes(15);

	private readonly IConfiguration _configuration;
	private readonly IMemoryCache _cache;
	private readonly string _masterConnectionString;

	public SqlDenialRecordRepository(IConfiguration configuration, IMemoryCache cache)
	{
		_configuration = configuration;
		_cache = cache;
		_masterConnectionString = configuration.GetConnectionString("DefaultConnection")
			?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is not configured.");
	}

	private static string TaskBoardCacheKey(int labId) => $"denial-dashboard:task-board:{labId}";
	private static string CurrentRunCacheKey(int labId) => $"denial-dashboard:current-run:{labId}";
	private static string AutocompleteCacheKey(int labId, string? runId) => $"denial-dashboard:autocomplete:{labId}:{runId ?? "all"}";

	public async Task<IReadOnlyList<LabOption>> GetLabsAsync(CancellationToken cancellationToken = default)
	{
		return await _cache.GetOrCreateAsync("denial-dashboard:labs", async entry =>
		{
			entry.AbsoluteExpirationRelativeToNow = LabsCacheDuration;

			const string sql = @"
SELECT
    CAST(ISNULL(LabId, 0) AS int) AS LabId,
    ISNULL(LabName, '') AS LabName,
    ISNULL(ConnectionKey, '') AS ConnectionKey
FROM dbo.LRNMetricsLab
WHERE ISNULL(IsActive, 0) = 1
ORDER BY LabName, LabId;";

			var items = new List<LabOption>();
			await using var connection = new SqlConnection(_masterConnectionString);
			await connection.OpenAsync(cancellationToken);
			await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 120 };
			await using var reader = await command.ExecuteReaderAsync(cancellationToken);
			while (await reader.ReadAsync(cancellationToken))
			{
				items.Add(new LabOption
				{
					LabId = GetInt(reader, "LabId"),
					LabName = GetString(reader, "LabName"),
					ConnectionKey = GetString(reader, "ConnectionKey")
				});
			}
			return (IReadOnlyList<LabOption>)items;
		}) ?? Array.Empty<LabOption>();
	}

	public async Task<IReadOnlyList<DenialRecord>> GetByLabAsync(int labId, CancellationToken cancellationToken = default)
	{
		var currentRunId = await GetCurrentRunIdAsync(labId, cancellationToken);
		var cacheKey = $"{TaskBoardCacheKey(labId)}:{currentRunId ?? "all"}";

		return await _cache.GetOrCreateAsync(cacheKey, async entry =>
		{
			entry.AbsoluteExpirationRelativeToNow = TaskBoardCacheDuration;

			await using var connection = await OpenLabConnectionAsync(labId, cancellationToken);
			if (!await TableExistsAsync(connection, "dbo", "DenialTaskBoard", cancellationToken))
			{
				return (IReadOnlyList<DenialRecord>)Array.Empty<DenialRecord>();
			}

			var cols = await GetTableColumnsAsync(connection, "dbo", "DenialTaskBoard", cancellationToken);
			var where = BuildScopedWhere(cols, currentRunId);

			var sql = $@"
SELECT
    {SelectString(cols, "TaskID")},
    {SelectString(cols, "ClaimID")},
    {SelectString(cols, "PatientId")},
    {SelectString(cols, "CPTCode")},
    {SelectString(cols, "DenialCode")},
    {SelectString(cols, "DenialDescription")},
    {SelectString(cols, "DenialClassification")},
    {SelectString(cols, "ActionCode")},
    {SelectString(cols, "RecommendedAction")},
    {SelectString(cols, "ActionCategory")},
    {SelectString(cols, "AssignedTo")},
    {SelectString(cols, "Task")},
    {SelectString(cols, "Priority")},
    {SelectDecimal(cols, "InsuranceBalance", 2)},
    {SelectDecimal(cols, "TotalBalance", 2)},
    {SelectBit(cols, "IsCurrentDenial")},
    {SelectInt(cols, "SLADays")},
    {SelectString(cols, "Status")},
    {SelectDate(cols, "DateOpened")},
    {SelectDate(cols, "DueDate")},
    {SelectDate(cols, "DateCompleted")},
    {SelectInt(cols, "DaysRemaining")},
    {SelectString(cols, "SLAStatus")},
    {SelectInt(cols, "LabId")},
    {SelectString(cols, "LabName")},
    {SelectString(cols, "RunId")},
    {SelectDate(cols, "CreatedOn")},
    {SelectString(cols, "UniqueTrackId")},
    {SelectString(cols, "SalesRepname")},
    {SelectString(cols, "ClinicName")},
    {SelectString(cols, "ReferringProvider")},
    {SelectString(cols, "PayerName")},
    {SelectString(cols, "PayerNameNormalized")},
    {SelectString(cols, "PayerType")},
    {SelectString(cols, "PanelName")},
    {SelectDate(cols, "FirstBilledDate")},
    {SelectDate(cols, "DateOfService")},
    {SelectString(cols, "Feedback")},
    {SelectString(cols, "Responsibility")},
    {SelectDate(cols, "DiscussionDate")},
    {SelectString(cols, "ETA")}
FROM dbo.DenialTaskBoard
WHERE {where}
ORDER BY {OrderBy(cols, "DueDate", "TaskID")};";

			var items = new List<DenialRecord>();
			await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 180 };
			AddScopeParameters(command, cols, labId, currentRunId);

			await using var reader = await command.ExecuteReaderAsync(cancellationToken);
			while (await reader.ReadAsync(cancellationToken))
			{
				items.Add(new DenialRecord
				{
					TaskId = GetString(reader, "TaskID"),
					ClaimId = GetString(reader, "ClaimID"),
					PatientId = GetString(reader, "PatientId"),
					CptCode = GetString(reader, "CPTCode"),
					DenialCode = GetString(reader, "DenialCode"),
					DenialDescription = GetString(reader, "DenialDescription"),
					DenialClassification = NormalizeMappedValue(GetString(reader, "DenialClassification")),
					ActionCode = GetString(reader, "ActionCode"),
					RecommendedAction = GetString(reader, "RecommendedAction"),
					ActionCategory = NormalizeMappedValue(GetString(reader, "ActionCategory")),
					AssignedTo = GetString(reader, "AssignedTo"),
					Task = GetString(reader, "Task"),
					Priority = NormalizeMappedValue(GetString(reader, "Priority")),
					InsuranceBalance = GetNullableDecimal(reader, "InsuranceBalance") ?? 0m,
					TotalBalance = GetNullableDecimal(reader, "TotalBalance") ?? 0m,
					IsCurrentDenial = GetNullableBool(reader, "IsCurrentDenial") ?? false,
					SlaDays = GetNullableInt(reader, "SLADays") ?? 0,
					Status = GetString(reader, "Status"),
					DateOpened = GetNullableDateTime(reader, "DateOpened") ?? DateTime.Today,
					DueDate = GetNullableDateTime(reader, "DueDate") ?? DateTime.Today,
					DateCompleted = GetNullableDateTime(reader, "DateCompleted"),
					StoredDaysRemaining = GetNullableInt(reader, "DaysRemaining"),
					StoredSlaStatus = GetNullableString(reader, "SLAStatus"),
					LabId = GetNullableInt(reader, "LabId") ?? labId,
					LabName = GetString(reader, "LabName"),
					RunId = GetString(reader, "RunId"),
					CreatedOn = GetNullableDateTime(reader, "CreatedOn"),
					UniqueTrackId = GetString(reader, "UniqueTrackId"),
					SalesRepname = GetString(reader, "SalesRepname"),
					ClinicName = GetString(reader, "ClinicName"),
					ReferringProvider = GetString(reader, "ReferringProvider"),
					PayerName = GetString(reader, "PayerName"),
					PayerNameNormalized = GetString(reader, "PayerNameNormalized"),
					PayerType = GetString(reader, "PayerType"),
					PanelName = GetString(reader, "PanelName"),
					FirstBilledDate = GetNullableDateTime(reader, "FirstBilledDate"),
					DateOfService = GetNullableDateTime(reader, "DateOfService"),
					Feedback = GetString(reader, "Feedback"),
					Responsibility = GetString(reader, "Responsibility"),
					DiscussionDate = GetNullableDateTime(reader, "DiscussionDate"),
					ETA = GetString(reader, "ETA")
				});
			}

			return (IReadOnlyList<DenialRecord>)items;
		}) ?? Array.Empty<DenialRecord>();
	}

	public async Task<IReadOnlyList<DenialInsightRecord>> GetInsightsByLabAsync(int labId, CancellationToken cancellationToken = default)
	{
		var records = await GetByLabAsync(labId, cancellationToken);
		return BuildInsights(records);
	}

	public Task<IReadOnlyList<DenialLineItemRecord>> GetLineItemsByLabAsync(int labId, int page, int pageSize, DenialDashboardFilters filters, CancellationToken cancellationToken = default)
		=> QueryLineItemsAsync(labId, filters, cancellationToken, withPaging: true, page, pageSize);

	public Task<IReadOnlyList<DenialLineItemRecord>> GetLineItemsForExportByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default)
		=> QueryLineItemsAsync(labId, filters, cancellationToken, withPaging: false, 1, 1);


	public async Task<IReadOnlyList<DenialBreakdownSourceRecord>> GetBreakdownSourceByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default)
	{
		var currentRunId = await GetCurrentRunIdAsync(labId, cancellationToken);
		await using var connection = await OpenLabConnectionAsync(labId, cancellationToken);
		if (!await TableExistsAsync(connection, "dbo", "DenialLineItem", cancellationToken))
		{
			return Array.Empty<DenialBreakdownSourceRecord>();
		}

		var cols = await GetTableColumnsAsync(connection, "dbo", "DenialLineItem", cancellationToken);
		if (!cols.Contains("DenialDate"))
		{
			return Array.Empty<DenialBreakdownSourceRecord>();
		}

		if (await ShouldUseClaimLevelDenialSummaryLogicAsync(connection, labId, cancellationToken))
		{
			return await GetClaimLevelBreakdownSourceByLabAsync(connection, cols, filters, cancellationToken);
		}

		var useClaimLevelInsuranceBalance = await ShouldUseClaimLevelInsuranceBalanceAsync(connection, labId, cancellationToken);
		var claimLevelCols = useClaimLevelInsuranceBalance
			? await GetTableColumnsAsync(connection, "dbo", "ClaimLevelData", cancellationToken)
			: new HashSet<string>(StringComparer.OrdinalIgnoreCase);

		var where = BuildLineItemWhere(cols, filters, currentRunId);
		var claimLevelApplySql = BuildClaimLevelInsuranceBalanceApplySql(claimLevelCols);
		var insuranceBalanceSelect = SelectInsuranceBalance(cols, claimLevelCols, useClaimLevelInsuranceBalance, 4);
		var sql = $@"
SELECT
    {SelectDate(cols, "DenialDate")},
    {SelectString(cols, "VisitNumber")},
    {insuranceBalanceSelect},
    {SelectDecimal(cols, "TotalBalance", 4)},
    {SelectString(cols, "PayerName")},
    {SelectString(cols, "PayerNameNormalized")},
    {SelectString(cols, "DenialCodeNormalized")},
    {SelectString(cols, "DenialDescription")}
FROM dbo.DenialLineItem dli
{claimLevelApplySql}
WHERE {where};";

		await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 180 };
		AddScopeParameters(command, cols, labId, currentRunId);
		AddLineItemFilterParameters(command, filters);

		var items = new List<DenialBreakdownSourceRecord>();
		await using var reader = await command.ExecuteReaderAsync(cancellationToken);
		while (await reader.ReadAsync(cancellationToken))
		{
			items.Add(new DenialBreakdownSourceRecord
			{
				DenialDate = GetNullableDateTime(reader, "DenialDate"),
				VisitNumber = GetString(reader, "VisitNumber"),
				InsuranceBalance = GetNullableDecimal(reader, "InsuranceBalance") ?? 0m,
				TotalBalance = GetNullableDecimal(reader, "TotalBalance") ?? 0m,
				PayerName = GetString(reader, "PayerName"),
				PayerNameNormalized = GetString(reader, "PayerNameNormalized"),
				DenialCodeNormalized = GetString(reader, "DenialCodeNormalized"),
				DenialDescription = GetString(reader, "DenialDescription")
			});
		}

		return items;
	}

	public async Task<int> GetLineItemCountByLabAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken = default)
	{
		var currentRunId = await GetCurrentRunIdAsync(labId, cancellationToken);
		await using var connection = await OpenLabConnectionAsync(labId, cancellationToken);
		if (!await TableExistsAsync(connection, "dbo", "DenialLineItem", cancellationToken))
		{
			return 0;
		}

		var cols = await GetTableColumnsAsync(connection, "dbo", "DenialLineItem", cancellationToken);
		var where = BuildLineItemWhere(cols, filters, currentRunId);
		var sql = $"SELECT COUNT(1) FROM dbo.DenialLineItem WHERE {where};";
		await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 180 };
		AddScopeParameters(command, cols, labId, currentRunId);
		AddLineItemFilterParameters(command, filters);
		var result = await command.ExecuteScalarAsync(cancellationToken);
		return result == null || result == DBNull.Value ? 0 : Convert.ToInt32(result);
	}

	public async Task<IReadOnlyList<string>> GetPayerNamesByLabAsync(int labId, CancellationToken cancellationToken = default)
	{
		var currentRunId = await GetCurrentRunIdAsync(labId, cancellationToken);
		await using var connection = await OpenLabConnectionAsync(labId, cancellationToken);
		if (!await TableExistsAsync(connection, "dbo", "DenialLineItem", cancellationToken)) return Array.Empty<string>();
		var cols = await GetTableColumnsAsync(connection, "dbo", "DenialLineItem", cancellationToken);
		if (!cols.Contains("PayerName")) return Array.Empty<string>();
		var where = BuildScopedWhere(cols, currentRunId);
		var sql = $@"SELECT DISTINCT TOP (200) LTRIM(RTRIM(ISNULL(PayerName, ''))) AS PayerNameValue FROM dbo.DenialLineItem WHERE {where} AND ISNULL(PayerName, '') <> '' ORDER BY PayerNameValue;";
		await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 120 };
		AddScopeParameters(command, cols, labId, currentRunId);
		var items = new List<string>();
		await using var reader = await command.ExecuteReaderAsync(cancellationToken);
		while (await reader.ReadAsync(cancellationToken))
		{
			var value = GetNullableString(reader, "PayerNameValue");
			if (!string.IsNullOrWhiteSpace(value)) items.Add(value.Trim());
		}
		return items;
	}

	public async Task<IReadOnlyList<string>> GetPanelNamesByLabAsync(int labId, CancellationToken cancellationToken = default)
	{
		var currentRunId = await GetCurrentRunIdAsync(labId, cancellationToken);
		await using var connection = await OpenLabConnectionAsync(labId, cancellationToken);
		if (!await TableExistsAsync(connection, "dbo", "DenialLineItem", cancellationToken)) return Array.Empty<string>();
		var cols = await GetTableColumnsAsync(connection, "dbo", "DenialLineItem", cancellationToken);
		if (!cols.Contains("PanelName")) return Array.Empty<string>();
		var where = BuildScopedWhere(cols, currentRunId);
		var sql = $@"SELECT DISTINCT TOP (200) LTRIM(RTRIM(ISNULL(PanelName, ''))) AS PanelNameValue FROM dbo.DenialLineItem WHERE {where} AND ISNULL(PanelName, '') <> '' ORDER BY PanelNameValue;";
		await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 120 };
		AddScopeParameters(command, cols, labId, currentRunId);
		var items = new List<string>();
		await using var reader = await command.ExecuteReaderAsync(cancellationToken);
		while (await reader.ReadAsync(cancellationToken))
		{
			var value = GetNullableString(reader, "PanelNameValue");
			if (!string.IsNullOrWhiteSpace(value)) items.Add(value.Trim());
		}
		return items;
	}

	public async Task<DenialFilterAutocompleteOptions> GetFilterAutocompleteOptionsAsync(int labId, CancellationToken cancellationToken = default)
	{
		var currentRunId = await GetCurrentRunIdAsync(labId, cancellationToken);
		var cacheKey = AutocompleteCacheKey(labId, currentRunId);

		return await _cache.GetOrCreateAsync(cacheKey, async entry =>
		{
			entry.AbsoluteExpirationRelativeToNow = AutocompleteCacheDuration;

			await using var connection = await OpenLabConnectionAsync(labId, cancellationToken);
			var taskBoardExists = await TableExistsAsync(connection, "dbo", "DenialTaskBoard", cancellationToken);
			var lineItemExists = await TableExistsAsync(connection, "dbo", "DenialLineItem", cancellationToken);

			var taskCols = taskBoardExists
				? await GetTableColumnsAsync(connection, "dbo", "DenialTaskBoard", cancellationToken)
				: new HashSet<string>(StringComparer.OrdinalIgnoreCase);
			var lineCols = lineItemExists
				? await GetTableColumnsAsync(connection, "dbo", "DenialLineItem", cancellationToken)
				: new HashSet<string>(StringComparer.OrdinalIgnoreCase);

			return new DenialFilterAutocompleteOptions
			{
				PayerNames = await GetAutocompleteValuesAsync(connection, labId, currentRunId, "PayerName", taskCols, lineCols, cancellationToken),
				PayerTypes = await GetAutocompleteValuesAsync(connection, labId, currentRunId, "PayerType", taskCols, lineCols, cancellationToken),
				PanelNames = await GetAutocompleteValuesAsync(connection, labId, currentRunId, "PanelName", taskCols, lineCols, cancellationToken),
				ReferringProviders = await GetAutocompleteValuesAsync(connection, labId, currentRunId, "ReferringProvider", taskCols, lineCols, cancellationToken),
				ClinicNames = await GetAutocompleteValuesAsync(connection, labId, currentRunId, "ClinicName", taskCols, lineCols, cancellationToken),
				SalesRepnames = await GetAutocompleteValuesAsync(connection, labId, currentRunId, "SalesRepname", taskCols, lineCols, cancellationToken)
			};
		}) ?? new DenialFilterAutocompleteOptions();
	}

	public async Task<string?> GetCurrentRunIdAsync(int labId, CancellationToken cancellationToken = default)
	{
		return await _cache.GetOrCreateAsync(CurrentRunCacheKey(labId), async entry =>
		{
			entry.AbsoluteExpirationRelativeToNow = CurrentRunCacheDuration;

			await using var connection = await OpenLabConnectionAsync(labId, cancellationToken);
			if (!await TableExistsAsync(connection, "dbo", "DenialTaskBoard", cancellationToken)) return null;
			var cols = await GetTableColumnsAsync(connection, "dbo", "DenialTaskBoard", cancellationToken);
			if (!cols.Contains("RunId")) return null;

			var where = cols.Contains("LabId") ? "WHERE [LabId] = @LabId AND [RunId] IS NOT NULL AND [RunId] <> ''" : "WHERE [RunId] IS NOT NULL AND [RunId] <> ''";
			var orderBy = cols.Contains("IsCurrentDenial")
				? "ORDER BY CASE WHEN ISNULL([IsCurrentDenial], 0) = 1 THEN 0 ELSE 1 END, ISNULL([CreatedOn], '19000101') DESC, [RunId] DESC"
				: cols.Contains("CreatedOn")
					? "ORDER BY ISNULL([CreatedOn], '19000101') DESC, [RunId] DESC"
					: "ORDER BY [RunId] DESC";

			var sql = $"SELECT TOP (1) [RunId] FROM dbo.DenialTaskBoard {where} {orderBy};";
			await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 120 };
			if (cols.Contains("LabId")) command.Parameters.AddWithValue("@LabId", labId);
			var result = await command.ExecuteScalarAsync(cancellationToken);
			return result == null || result == DBNull.Value ? null : Convert.ToString(result);
		});
	}

	public async Task<string?> GetLatestExportFilePathForLabAsync(int labId, CancellationToken cancellationToken = default)
	{
		var currentRunId = await GetCurrentRunIdAsync(labId, cancellationToken);
		if (string.IsNullOrWhiteSpace(currentRunId)) return null;

		var cacheKey = $"denial-dashboard:export-path:{labId}:{currentRunId}";
		return await _cache.GetOrCreateAsync(cacheKey, async entry =>
		{
			entry.AbsoluteExpirationRelativeToNow = ExportPathCacheDuration;

			const string sql = @"
SELECT TOP (1)
    OutputFileName
FROM dbo.DenialAnalysisRunLog
WHERE RunId = @RunId
  AND OutputFileName IS NOT NULL
  AND OutputFileName <> ''
ORDER BY ISNULL(CreatedOn, '19000101') DESC;";

			await using var connection = new SqlConnection(_masterConnectionString);
			await connection.OpenAsync(cancellationToken);
			await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 120 };
			command.Parameters.AddWithValue("@RunId", currentRunId);
			var result = await command.ExecuteScalarAsync(cancellationToken);
			return result == null || result == DBNull.Value ? null : Convert.ToString(result);
		});
	}

	public async Task<TaskBoardUploadResult> UpdateTaskBoardAsync(int labId, IReadOnlyList<TaskBoardCsvUpdate> updates, CancellationToken cancellationToken = default)
	{
		var result = new TaskBoardUploadResult { TotalRows = updates?.Count ?? 0 };
		if (updates is null || updates.Count == 0) return result;

		var validUpdates = new List<TaskBoardCsvUpdate>(updates.Count);
		foreach (var update in updates)
		{
			var taskId = update.TaskId?.Trim() ?? string.Empty;
			var uniqueTrackId = update.UniqueTrackId?.Trim() ?? string.Empty;
			var runId = update.RunId?.Trim() ?? string.Empty;
			if (string.IsNullOrWhiteSpace(taskId) && string.IsNullOrWhiteSpace(uniqueTrackId))
			{
				result.SkippedRows++;
				continue;
			}

			validUpdates.Add(new TaskBoardCsvUpdate
			{
				TaskId = taskId,
				UniqueTrackId = uniqueTrackId,
				Status = update.Status?.Trim() ?? string.Empty,
				AssignedTo = update.AssignedTo?.Trim() ?? string.Empty,
				RunId = runId,
				DateCompleted = update.DateCompleted
			});
		}

		if (validUpdates.Count == 0) return result;

		await using var connection = await OpenLabConnectionAsync(labId, cancellationToken);
		await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);

		try
		{
			const string createTempTableSql = @"
CREATE TABLE #TaskBoardCsvUpdates
(
    RowNumber int NOT NULL,
    RunId nvarchar(255) NULL,
    UniqueTrackId nvarchar(255) NULL,
    TaskId nvarchar(100) NULL,
    Status nvarchar(100) NULL,
    AssignedTo nvarchar(255) NULL,
    DateCompleted datetime NULL
);";

			await using (var createCommand = new SqlCommand(createTempTableSql, connection, transaction) { CommandType = CommandType.Text, CommandTimeout = 600 })
			{
				await createCommand.ExecuteNonQueryAsync(cancellationToken);
			}

			var table = new DataTable();
			table.Columns.Add("RowNumber", typeof(int));
			table.Columns.Add("RunId", typeof(string));
			table.Columns.Add("UniqueTrackId", typeof(string));
			table.Columns.Add("TaskId", typeof(string));
			table.Columns.Add("Status", typeof(string));
			table.Columns.Add("AssignedTo", typeof(string));
			table.Columns.Add("DateCompleted", typeof(DateTime));

			for (var i = 0; i < validUpdates.Count; i++)
			{
				var update = validUpdates[i];
				table.Rows.Add(
					i + 1,
					string.IsNullOrWhiteSpace(update.RunId) ? DBNull.Value : update.RunId,
					string.IsNullOrWhiteSpace(update.UniqueTrackId) ? DBNull.Value : update.UniqueTrackId,
					string.IsNullOrWhiteSpace(update.TaskId) ? DBNull.Value : update.TaskId,
					update.Status,
					update.AssignedTo,
					update.DateCompleted.HasValue ? update.DateCompleted.Value : DBNull.Value);
			}

			using (var bulkCopy = new SqlBulkCopy(connection, SqlBulkCopyOptions.Default, transaction))
			{
				bulkCopy.DestinationTableName = "#TaskBoardCsvUpdates";
				bulkCopy.BatchSize = 5000;
				bulkCopy.BulkCopyTimeout = 600;
				foreach (DataColumn column in table.Columns)
				{
					bulkCopy.ColumnMappings.Add(column.ColumnName, column.ColumnName);
				}
				await bulkCopy.WriteToServerAsync(table, cancellationToken);
			}

			const string applyUpdatesSql = @"
CREATE CLUSTERED INDEX IX_TaskBoardCsvUpdates_RowNumber ON #TaskBoardCsvUpdates (RowNumber);
CREATE INDEX IX_TaskBoardCsvUpdates_UniqueTrackId_RunId ON #TaskBoardCsvUpdates (UniqueTrackId, RunId);
CREATE INDEX IX_TaskBoardCsvUpdates_TaskId_RunId ON #TaskBoardCsvUpdates (TaskId, RunId);

CREATE TABLE #MatchedRows (RowNumber int NOT NULL PRIMARY KEY);

INSERT INTO #MatchedRows (RowNumber)
SELECT DISTINCT u.RowNumber
FROM #TaskBoardCsvUpdates u
INNER JOIN dbo.DenialTaskBoard t
    ON u.UniqueTrackId IS NOT NULL
   AND t.UniqueTrackId = u.UniqueTrackId
   AND (u.RunId IS NULL OR t.RunId = u.RunId);

UPDATE t
SET
    t.Status = ISNULL(u.Status, ''),
    t.AssignedTo = ISNULL(u.AssignedTo, ''),
    t.DateCompleted = u.DateCompleted
FROM dbo.DenialTaskBoard t
INNER JOIN #TaskBoardCsvUpdates u
    ON u.UniqueTrackId IS NOT NULL
   AND t.UniqueTrackId = u.UniqueTrackId
   AND (u.RunId IS NULL OR t.RunId = u.RunId)
WHERE ISNULL(t.Status, '') <> ISNULL(u.Status, '')
   OR ISNULL(t.AssignedTo, '') <> ISNULL(u.AssignedTo, '')
   OR ISNULL(t.DateCompleted, '19000101') <> ISNULL(u.DateCompleted, '19000101');

INSERT INTO #MatchedRows (RowNumber)
SELECT DISTINCT u.RowNumber
FROM #TaskBoardCsvUpdates u
INNER JOIN dbo.DenialTaskBoard t
    ON u.UniqueTrackId IS NULL
   AND u.TaskId IS NOT NULL
   AND t.TaskID = u.TaskId
   AND (u.RunId IS NULL OR t.RunId = u.RunId)
WHERE NOT EXISTS (SELECT 1 FROM #MatchedRows m WHERE m.RowNumber = u.RowNumber);

UPDATE t
SET
    t.Status = ISNULL(u.Status, ''),
    t.AssignedTo = ISNULL(u.AssignedTo, ''),
    t.DateCompleted = u.DateCompleted
FROM dbo.DenialTaskBoard t
INNER JOIN #TaskBoardCsvUpdates u
    ON u.UniqueTrackId IS NULL
   AND u.TaskId IS NOT NULL
   AND t.TaskID = u.TaskId
   AND (u.RunId IS NULL OR t.RunId = u.RunId)
WHERE ISNULL(t.Status, '') <> ISNULL(u.Status, '')
   OR ISNULL(t.AssignedTo, '') <> ISNULL(u.AssignedTo, '')
   OR ISNULL(t.DateCompleted, '19000101') <> ISNULL(u.DateCompleted, '19000101');

SELECT MatchedRows = (SELECT COUNT(1) FROM #MatchedRows);";

			await using var applyCommand = new SqlCommand(applyUpdatesSql, connection, transaction) { CommandType = CommandType.Text, CommandTimeout = 600 };
			var matched = await applyCommand.ExecuteScalarAsync(cancellationToken);
			result.UpdatedRows = matched == null || matched == DBNull.Value ? 0 : Convert.ToInt32(matched);
			result.SkippedRows += Math.Max(0, validUpdates.Count - result.UpdatedRows);

			await transaction.CommitAsync(cancellationToken);

			_cache.Remove(TaskBoardCacheKey(labId));
			_cache.Remove(CurrentRunCacheKey(labId));
			return result;
		}
		catch (Exception ex)
		{
			await transaction.RollbackAsync(cancellationToken);
			result.Errors.Add(ex.Message);
			return result;
		}
	}

	private async Task<IReadOnlyList<DenialLineItemRecord>> QueryLineItemsAsync(int labId, DenialDashboardFilters filters, CancellationToken cancellationToken, bool withPaging, int page, int pageSize)
	{
		var currentRunId = await GetCurrentRunIdAsync(labId, cancellationToken);
		await using var connection = await OpenLabConnectionAsync(labId, cancellationToken);
		if (!await TableExistsAsync(connection, "dbo", "DenialLineItem", cancellationToken)) return Array.Empty<DenialLineItemRecord>();

		var cols = await GetTableColumnsAsync(connection, "dbo", "DenialLineItem", cancellationToken);
		var useClaimLevelInsuranceBalance = await ShouldUseClaimLevelInsuranceBalanceAsync(connection, labId, cancellationToken);
		var claimLevelCols = useClaimLevelInsuranceBalance
			? await GetTableColumnsAsync(connection, "dbo", "ClaimLevelData", cancellationToken)
			: new HashSet<string>(StringComparer.OrdinalIgnoreCase);
		var where = BuildLineItemWhere(cols, filters, currentRunId);
		var pagingSql = withPaging ? " OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY" : string.Empty;
		var claimLevelApplySql = BuildClaimLevelInsuranceBalanceApplySql(claimLevelCols);

		var sql = $@"
SELECT
    {SelectString(cols, "AccessionNo")},
    {SelectString(cols, "VisitNumber")},
    {SelectString(cols, "CPTCode")},
    {SelectDate(cols, "PatientDOB")},
    {SelectInt(cols, "PayerCode")},
    {SelectString(cols, "PayerName")},
    {SelectString(cols, "PayerNameNormalized")},
    {SelectString(cols, "PayerType")},
    {SelectString(cols, "PayStatus")},
    {SelectString(cols, "HistoricalPayment")},
    {SelectString(cols, "HistoricalPaidLineItemCount")},
    {SelectString(cols, "HistoricalPaymentConfidenceScore")},
    {SelectInt(cols, "TotalLineItemCount")},
    {SelectInt(cols, "PaidLineItemCount")},
    {SelectDecimal(cols, "PaidLineItemCountPercent", 4)},
    {SelectString(cols, "PayerFoundInPolicy")},
    {SelectDate(cols, "DateOfService")},
    {SelectDate(cols, "FirstBilledDate")},
    {SelectDate(cols, "DenialDate")},
    {SelectString(cols, "PanelName")},
    {SelectString(cols, "LISICD10Codes")},
    {SelectString(cols, "CCWICD10Code")},
    {SelectInt(cols, "Units")},
    {SelectString(cols, "Modifier")},
    {SelectString(cols, "ReferringProvider")},
    {SelectString(cols, "ClinicName")},
    {SelectString(cols, "SalesRepname")},
    {SelectString(cols, "DenialCodeOriginal")},
    {SelectString(cols, "DenialCodeNormalized")},
    {SelectString(cols, "DenialDescription")},
    {SelectDecimal(cols, "BilledAmount", 4)},
    {SelectDecimal(cols, "AllowedAmount", 4)},
    {SelectDecimal(cols, "InsurancePayment", 4)},
    {SelectDecimal(cols, "InsuranceAdjustment", 4)},
    {SelectDecimal(cols, "PatientPaidAmount", 4)},
    {SelectDecimal(cols, "PatientAdjustment", 4)},
    {SelectInsuranceBalance(cols, claimLevelCols, useClaimLevelInsuranceBalance, 4)},
    {SelectDecimal(cols, "PatientBalance", 4)},
    {SelectDecimal(cols, "TotalBalance", 4)},
    {SelectDecimal(cols, "MedicareFee", 4)},
    {SelectString(cols, "FinalClaimStatus")},
    {SelectString(cols, "CoveredICD10CodesBilled")},
    {SelectString(cols, "NonCoveredICD10CodesBilled")},
    {SelectString(cols, "BilledICDCodesNotAvailableInPayerPolicy")},
    {SelectString(cols, "CoverageStatus")},
    {SelectString(cols, "FinalCoverageStatus")},
    {SelectString(cols, "CoveredICD10CodesAsPerPayerPolicy")},
    {SelectString(cols, "NonCoveredICD10CodesAsPerPayerPolicy")},
    {SelectString(cols, "ActionComment")},
    {SelectString(cols, "Resolution")},
    {SelectString(cols, "LabName")},
    {SelectString(cols, "CodingValidation")},
    {SelectString(cols, "CodingValidationSubStatus")},
    {SelectString(cols, "ICDComplianceStatus")},
    {SelectString(cols, "ICDComplianceSubstatus")},
    {SelectString(cols, "ICDPrimaryIndicatorAvailable")},
    {SelectString(cols, "CoveredICDPresence")},
    {SelectString(cols, "ICDValidationConfidence")},
    {SelectString(cols, "FrequencyConditionMet")},
    {SelectString(cols, "GenderConditionMet")},
    {SelectString(cols, "Payability")},
    {SelectString(cols, "ForecastingPayability")},
    {SelectString(cols, "PolicyCoverageExpectation")},
    {SelectString(cols, "DenialValidity")},
    {SelectString(cols, "CoverageExpectationRemarks")},
    {SelectDecimal(cols, "ExpectedAverageAllowedAmount", 4)},
    {SelectDecimal(cols, "ExpectedAverageInsurancePayment", 4)},
    {SelectDecimal(cols, "ExpectedAllowedAmountSameLab", 4)},
    {SelectDecimal(cols, "ExpectedInsurancePaymentSameLab", 4)},
    {SelectDecimal(cols, "ModeAllowedAmountSameLab", 4)},
    {SelectDecimal(cols, "ModeInsurancePaidSameLab", 4)},
    {SelectDecimal(cols, "ModeAllowedAmountPeer", 4)},
    {SelectDecimal(cols, "ModeInsurancePaidPeer", 4)},
    {SelectDecimal(cols, "MedianAllowedAmountSameLab", 4)},
    {SelectDecimal(cols, "MedianInsurancePaidSameLab", 4)},
    {SelectDecimal(cols, "MedianAllowedAmountPeer", 4)},
    {SelectDecimal(cols, "MedianInsurancePaidPeer", 4)},
    {SelectDecimal(cols, "ModeAllowedAmountDifference", 4)},
    {SelectDecimal(cols, "ModeInsurancePaidDifference", 4)},
    {SelectDecimal(cols, "MedianAllowedAmountDifference", 4)},
    {SelectDecimal(cols, "MedianInsurancePaidDifference", 4)},
    {SelectDecimal(cols, "DenialRate", 4)},
    {SelectDecimal(cols, "AdjustmentRate", 4)},
    {SelectInt(cols, "PaymentDays")},
    {SelectDate(cols, "ExpectedPaymentDate")},
    {SelectString(cols, "ExpectedPaymentMonth")},
    {SelectString(cols, "BillingProvider")},
    {SelectString(cols, "DenialClassification")},
    {SelectString(cols, "DenialType")},
    {SelectString(cols, "ActionCategory")},
    {SelectString(cols, "ActionCode")},
    {SelectString(cols, "RecommendedAction")},
    {SelectString(cols, "TaskGuidance")},
    {SelectString(cols, "TaskStatus")},
    {SelectString(cols, "Priority")},
    {SelectString(cols, "SLADays")},
    {SelectString(cols, "PatientID")},
    {SelectDate(cols, "ChargeEnteredDate")},
    {SelectString(cols, "POS")},
    {SelectString(cols, "TOS")},
    {SelectDate(cols, "CheckDate")},
    {SelectInt(cols, "DaystoDOS")},
    {SelectString(cols, "RollingDays")},
    {SelectInt(cols, "DaystoBill")},
    {SelectInt(cols, "DaystoPost")},
    {SelectString(cols, "RunId")},
    {SelectDate(cols, "CreatedOn")}
FROM dbo.DenialLineItem dli
{claimLevelApplySql}
WHERE {where}
ORDER BY {OrderBy(cols, "DateOfService", "AccessionNo")}{pagingSql};";

		await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 180 };
		AddScopeParameters(command, cols, labId, currentRunId);
		AddLineItemFilterParameters(command, filters);
		if (withPaging)
		{
			command.Parameters.AddWithValue("@Offset", (Math.Max(page, 1) - 1) * Math.Max(pageSize, 1));
			command.Parameters.AddWithValue("@PageSize", Math.Max(pageSize, 1));
		}

		var items = new List<DenialLineItemRecord>();
		await using var reader = await command.ExecuteReaderAsync(cancellationToken);
		while (await reader.ReadAsync(cancellationToken))
		{
			items.Add(new DenialLineItemRecord
			{
				AccessionNo = GetString(reader, "AccessionNo"),
				VisitNumber = GetString(reader, "VisitNumber"),
				CptCode = GetString(reader, "CPTCode"),
				PatientDob = GetNullableDateTime(reader, "PatientDOB"),
				PayerCode = GetNullableInt(reader, "PayerCode"),
				PayerName = GetString(reader, "PayerName"),
				PayerNameNormalized = GetString(reader, "PayerNameNormalized"),
				PayerType = GetString(reader, "PayerType"),
				PayStatus = GetString(reader, "PayStatus"),
				HistoricalPayment = GetString(reader, "HistoricalPayment"),
				HistoricalPaidLineItemCount = GetString(reader, "HistoricalPaidLineItemCount"),
				HistoricalPaymentConfidenceScore = GetString(reader, "HistoricalPaymentConfidenceScore"),
				TotalLineItemCount = GetNullableInt(reader, "TotalLineItemCount"),
				PaidLineItemCount = GetNullableInt(reader, "PaidLineItemCount"),
				PaidLineItemCountPercent = GetNullableDecimal(reader, "PaidLineItemCountPercent"),
				PayerFoundInPolicy = GetString(reader, "PayerFoundInPolicy"),
				DateOfService = GetNullableDateTime(reader, "DateOfService"),
				FirstBilledDate = GetNullableDateTime(reader, "FirstBilledDate"),
				DenialDate = GetNullableDateTime(reader, "DenialDate"),
				PanelName = GetString(reader, "PanelName"),
				LisIcd10Codes = GetString(reader, "LISICD10Codes"),
				CcwIcd10Code = GetString(reader, "CCWICD10Code"),
				Units = GetNullableInt(reader, "Units"),
				Modifier = GetString(reader, "Modifier"),
				ReferringProvider = GetString(reader, "ReferringProvider"),
				ClinicName = GetString(reader, "ClinicName"),
				SalesRepname = GetString(reader, "SalesRepname"),
				DenialCodeOriginal = GetString(reader, "DenialCodeOriginal"),
				DenialCodeNormalized = GetString(reader, "DenialCodeNormalized"),
				DenialDescription = GetString(reader, "DenialDescription"),
				BilledAmount = GetNullableDecimal(reader, "BilledAmount") ?? 0m,
				AllowedAmount = GetNullableDecimal(reader, "AllowedAmount") ?? 0m,
				InsurancePayment = GetNullableDecimal(reader, "InsurancePayment") ?? 0m,
				InsuranceAdjustment = GetNullableDecimal(reader, "InsuranceAdjustment") ?? 0m,
				PatientPaidAmount = GetNullableDecimal(reader, "PatientPaidAmount") ?? 0m,
				PatientAdjustment = GetNullableDecimal(reader, "PatientAdjustment") ?? 0m,
				InsuranceBalance = GetNullableDecimal(reader, "InsuranceBalance") ?? 0m,
				PatientBalance = GetNullableDecimal(reader, "PatientBalance") ?? 0m,
				TotalBalance = GetNullableDecimal(reader, "TotalBalance") ?? 0m,
				MedicareFee = GetNullableDecimal(reader, "MedicareFee") ?? 0m,
				FinalClaimStatus = GetString(reader, "FinalClaimStatus"),
				CoveredIcd10CodesBilled = GetString(reader, "CoveredICD10CodesBilled"),
				NonCoveredIcd10CodesBilled = GetString(reader, "NonCoveredICD10CodesBilled"),
				BilledIcdCodesNotAvailableInPayerPolicy = GetString(reader, "BilledICDCodesNotAvailableInPayerPolicy"),
				CoverageStatus = GetString(reader, "CoverageStatus"),
				FinalCoverageStatus = GetString(reader, "FinalCoverageStatus"),
				CoveredIcd10CodesAsPerPayerPolicy = GetString(reader, "CoveredICD10CodesAsPerPayerPolicy"),
				NonCoveredIcd10CodesAsPerPayerPolicy = GetString(reader, "NonCoveredICD10CodesAsPerPayerPolicy"),
				ActionComment = GetString(reader, "ActionComment"),
				Resolution = GetString(reader, "Resolution"),
				LabName = GetString(reader, "LabName"),
				CodingValidation = GetString(reader, "CodingValidation"),
				CodingValidationSubStatus = GetString(reader, "CodingValidationSubStatus"),
				IcdComplianceStatus = GetString(reader, "ICDComplianceStatus"),
				IcdComplianceSubstatus = GetString(reader, "ICDComplianceSubstatus"),
				IcdPrimaryIndicatorAvailable = GetString(reader, "ICDPrimaryIndicatorAvailable"),
				CoveredIcdPresence = GetString(reader, "CoveredICDPresence"),
				IcdValidationConfidence = GetString(reader, "ICDValidationConfidence"),
				FrequencyConditionMet = GetString(reader, "FrequencyConditionMet"),
				GenderConditionMet = GetString(reader, "GenderConditionMet"),
				Payability = GetString(reader, "Payability"),
				ForecastingPayability = GetString(reader, "ForecastingPayability"),
				PolicyCoverageExpectation = GetString(reader, "PolicyCoverageExpectation"),
				DenialValidity = GetString(reader, "DenialValidity"),
				CoverageExpectationRemarks = GetString(reader, "CoverageExpectationRemarks"),
				ExpectedAverageAllowedAmount = GetNullableDecimal(reader, "ExpectedAverageAllowedAmount"),
				ExpectedAverageInsurancePayment = GetNullableDecimal(reader, "ExpectedAverageInsurancePayment"),
				ExpectedAllowedAmountSameLab = GetNullableDecimal(reader, "ExpectedAllowedAmountSameLab"),
				ExpectedInsurancePaymentSameLab = GetNullableDecimal(reader, "ExpectedInsurancePaymentSameLab"),
				ModeAllowedAmountSameLab = GetNullableDecimal(reader, "ModeAllowedAmountSameLab"),
				ModeInsurancePaidSameLab = GetNullableDecimal(reader, "ModeInsurancePaidSameLab"),
				ModeAllowedAmountPeer = GetNullableDecimal(reader, "ModeAllowedAmountPeer"),
				ModeInsurancePaidPeer = GetNullableDecimal(reader, "ModeInsurancePaidPeer"),
				MedianAllowedAmountSameLab = GetNullableDecimal(reader, "MedianAllowedAmountSameLab"),
				MedianInsurancePaidSameLab = GetNullableDecimal(reader, "MedianInsurancePaidSameLab"),
				MedianAllowedAmountPeer = GetNullableDecimal(reader, "MedianAllowedAmountPeer"),
				MedianInsurancePaidPeer = GetNullableDecimal(reader, "MedianInsurancePaidPeer"),
				ModeAllowedAmountDifference = GetNullableDecimal(reader, "ModeAllowedAmountDifference"),
				ModeInsurancePaidDifference = GetNullableDecimal(reader, "ModeInsurancePaidDifference"),
				MedianAllowedAmountDifference = GetNullableDecimal(reader, "MedianAllowedAmountDifference"),
				MedianInsurancePaidDifference = GetNullableDecimal(reader, "MedianInsurancePaidDifference"),
				DenialRate = GetNullableDecimal(reader, "DenialRate"),
				AdjustmentRate = GetNullableDecimal(reader, "AdjustmentRate"),
				PaymentDays = GetNullableInt(reader, "PaymentDays"),
				ExpectedPaymentDate = GetNullableDateTime(reader, "ExpectedPaymentDate"),
				ExpectedPaymentMonth = GetString(reader, "ExpectedPaymentMonth"),
				BillingProvider = GetString(reader, "BillingProvider"),
				DenialClassification = NormalizeMappedValue(GetString(reader, "DenialClassification")),
				DenialType = GetString(reader, "DenialType"),
				ActionCategory = NormalizeMappedValue(GetString(reader, "ActionCategory")),
				ActionCode = GetString(reader, "ActionCode"),
				RecommendedAction = GetString(reader, "RecommendedAction"),
				TaskGuidance = GetString(reader, "TaskGuidance"),
				TaskStatus = GetString(reader, "TaskStatus"),
				Priority = NormalizeMappedValue(GetString(reader, "Priority")),
				SlaDays = GetString(reader, "SLADays"),
				PatientId = GetString(reader, "PatientID"),
				ChargeEnteredDate = GetNullableDateTime(reader, "ChargeEnteredDate"),
				Pos = GetString(reader, "POS"),
				Tos = GetString(reader, "TOS"),
				CheckDate = GetNullableDateTime(reader, "CheckDate"),
				DaystoDos = GetNullableInt(reader, "DaystoDOS"),
				RollingDays = GetString(reader, "RollingDays"),
				DaystoBill = GetNullableInt(reader, "DaystoBill"),
				DaystoPost = GetNullableInt(reader, "DaystoPost"),
				RunId = GetString(reader, "RunId"),
				CreatedOn = GetNullableDateTime(reader, "CreatedOn")
			});
		}

		return items;
	}

	private static string NormalizeMappedValue(string? value)
	{
		if (string.IsNullOrWhiteSpace(value)) return string.Empty;

		var trimmed = value.Trim();
		var colonIndex = trimmed.IndexOf(':');
		if (colonIndex <= 0 || colonIndex >= trimmed.Length - 1) return trimmed;

		var prefix = trimmed[..colonIndex].Trim();
		var suffix = trimmed[(colonIndex + 1)..].Trim();

		var looksLikeDenialCode = prefix.Any(char.IsDigit)
			&& prefix.Any(char.IsLetter)
			&& prefix.Length <= 30
			&& !suffix.Contains(':');

		return looksLikeDenialCode ? suffix : trimmed;
	}

	private async Task<LabOption> GetLabAsync(int labId, CancellationToken cancellationToken)
	{
		var labs = await GetLabsAsync(cancellationToken);
		return labs.FirstOrDefault(x => x.LabId == labId)
			?? throw new InvalidOperationException($"Active lab '{labId}' was not found in dbo.LRNMetricsLab.");
	}

	private static async Task<bool> ShouldUseClaimLevelDenialSummaryLogicAsync(SqlConnection connection, int labId, CancellationToken cancellationToken)
		=> await ShouldUseClaimLevelInsuranceBalanceAsync(connection, labId, cancellationToken);

	private async Task<IReadOnlyList<DenialBreakdownSourceRecord>> GetClaimLevelBreakdownSourceByLabAsync(
		SqlConnection connection,
		HashSet<string> denialLineCols,
		DenialDashboardFilters filters,
		CancellationToken cancellationToken)
	{
		var claimLevelCols = await GetTableColumnsAsync(connection, "dbo", "ClaimLevelData", cancellationToken);
		if (!claimLevelCols.Contains("ClaimID") || !claimLevelCols.Contains("InsuranceBalance"))
		{
			return Array.Empty<DenialBreakdownSourceRecord>();
		}

		var payerNameSelect = claimLevelCols.Contains("PayerName")
			? "ISNULL(CONVERT(nvarchar(500), cld.[PayerName]), '') AS [PayerName]"
			: claimLevelCols.Contains("PayerName_Raw")
				? "ISNULL(CONVERT(nvarchar(500), cld.[PayerName_Raw]), '') AS [PayerName]"
				: "CAST('' AS nvarchar(500)) AS [PayerName]";

		var totalBalanceSelect = denialLineCols.Contains("TotalBalance")
			? "TRY_CONVERT(decimal(18, 4), dli.[TotalBalance]) AS [TotalBalance]"
			: "TRY_CONVERT(decimal(18, 4), cld.[InsuranceBalance]) AS [TotalBalance]";

		var denialCodeColumn = denialLineCols.Contains("DenialCodeOriginal")
			? "DenialCodeOriginal"
			: denialLineCols.Contains("DenialCodeNormalized")
				? "DenialCodeNormalized"
				: string.Empty;

		var where = BuildClaimLevelBreakdownWhere(denialLineCols, claimLevelCols, filters, denialCodeColumn);
		var sql = $@"
SELECT
    {SelectDateWithAlias(denialLineCols, "DenialDate", "dli")},
    ISNULL(CONVERT(nvarchar(500), dli.[VisitNumber]), '') AS [VisitNumber],
    TRY_CONVERT(decimal(18, 4), cld.[InsuranceBalance]) AS [InsuranceBalance],
    {totalBalanceSelect},
    {payerNameSelect},
    {SelectStringWithAlias(denialLineCols, "PayerNameNormalized", "dli")},
    {SelectStringWithAlias(denialLineCols, "DenialCodeNormalized", "dli")},
    {SelectStringWithAlias(denialLineCols, denialCodeColumn, "dli", "DenialCodeOriginal")},
    {SelectStringWithAlias(denialLineCols, "DenialDescription", "dli")}
FROM dbo.ClaimLevelData cld
INNER JOIN dbo.DenialLineItem dli
    ON dli.[VisitNumber] = cld.[ClaimID]
WHERE {where};";

		await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 180 };
		AddClaimLevelBreakdownFilterParameters(command, filters);

		var items = new List<DenialBreakdownSourceRecord>();
		await using var reader = await command.ExecuteReaderAsync(cancellationToken);
		while (await reader.ReadAsync(cancellationToken))
		{
			items.Add(new DenialBreakdownSourceRecord
			{
				DenialDate = GetNullableDateTime(reader, "DenialDate"),
				VisitNumber = GetString(reader, "VisitNumber"),
				InsuranceBalance = GetNullableDecimal(reader, "InsuranceBalance") ?? 0m,
				TotalBalance = GetNullableDecimal(reader, "TotalBalance") ?? 0m,
				PayerName = GetString(reader, "PayerName"),
				PayerNameNormalized = GetString(reader, "PayerNameNormalized"),
				DenialCode = GetString(reader, "DenialCodeOriginal"),
				DenialCodeNormalized = GetString(reader, "DenialCodeNormalized"),
				DenialDescription = GetString(reader, "DenialDescription")
			});
		}

		return items;
	}

	private static string BuildClaimLevelBreakdownWhere(HashSet<string> denialLineCols, HashSet<string> claimLevelCols, DenialDashboardFilters filters, string denialCodeColumn)
	{
		var where = new List<string>
		{
			string.IsNullOrWhiteSpace(denialCodeColumn)
				? "1 = 1"
				: $"ISNULL(CONVERT(nvarchar(max), dli.[{denialCodeColumn}]), '') <> ''",
			"TRY_CONVERT(decimal(18, 4), cld.[InsuranceBalance]) > 0"
		};

		AddStartsWithWithAlias(where, claimLevelCols, "PayerName", "cld", filters.PayerName, "@PayerName");
		if (!claimLevelCols.Contains("PayerName"))
		{
			AddStartsWithWithAlias(where, claimLevelCols, "PayerName_Raw", "cld", filters.PayerName, "@PayerName");
		}
		AddStartsWithWithAlias(where, claimLevelCols, "Panelname", "cld", filters.PanelName, "@PanelName");
		AddStartsWithWithAlias(where, denialLineCols, "SalesRepname", "dli", filters.SalesRepname, "@SalesRepname");
		AddStartsWithWithAlias(where, denialLineCols, "ClinicName", "dli", filters.ClinicName, "@ClinicName");
		AddStartsWithWithAlias(where, denialLineCols, "ReferringProvider", "dli", filters.ReferringProvider, "@ReferringProvider");
		AddStartsWithWithAlias(where, denialLineCols, "PayerType", "dli", filters.PayerType, "@PayerType");
		AddExactWithAlias(where, denialLineCols, "TaskStatus", "dli", filters.Status, "@Status");
		AddExactNormalizedWithAlias(where, denialLineCols, "Priority", "dli", filters.Priority, "@Priority");
		AddExactNormalizedWithAlias(where, denialLineCols, "ActionCategory", "dli", filters.ActionCategory, "@ActionCategory");
		AddExactNormalizedWithAlias(where, denialLineCols, "DenialClassification", "dli", filters.Classification, "@Classification");
		AddDateRangeWithAlias(where, denialLineCols, "FirstBilledDate", "dli", filters.FirstBilledDateFrom, filters.FirstBilledDateTo, "@FirstBilledDateFrom", "@FirstBilledDateTo");
		AddDateRangeWithAlias(where, denialLineCols, "DateOfService", "dli", filters.DateOfServiceFrom, filters.DateOfServiceTo, "@DateOfServiceFrom", "@DateOfServiceTo");
		AddDateRangeWithAlias(where, denialLineCols, "DenialDate", "dli", filters.DenialDateFrom, filters.DenialDateTo, "@DenialDateFrom", "@DenialDateTo");

		return string.Join(" AND ", where);
	}

	private static void AddClaimLevelBreakdownFilterParameters(SqlCommand command, DenialDashboardFilters filters)
	{
		AddLineItemFilterParameters(command, filters);
	}

	private static string SelectStringWithAlias(HashSet<string> cols, string column, string alias)
		=> SelectStringWithAlias(cols, column, alias, column);

	private static string SelectStringWithAlias(HashSet<string> cols, string column, string alias, string outputAlias)
		=> !string.IsNullOrWhiteSpace(column) && cols.Contains(column)
			? $"ISNULL(CONVERT(nvarchar(max), {alias}.[{column}]), '') AS [{outputAlias}]"
			: $"CAST('' AS nvarchar(max)) AS [{outputAlias}]";

	private static string SelectDateWithAlias(HashSet<string> cols, string column, string alias)
		=> cols.Contains(column)
			? $"TRY_CONVERT(datetime, {alias}.[{column}]) AS [{column}]"
			: $"CAST(NULL AS datetime) AS [{column}]";

	private static void AddExactWithAlias(List<string> where, HashSet<string> cols, string column, string alias, string? value, string parameter)
	{
		if (cols.Contains(column) && !string.IsNullOrWhiteSpace(value) && value != "(All)")
		{
			where.Add($"ISNULL(CONVERT(nvarchar(255), {alias}.[{column}]), '') = {parameter}");
		}
	}

	private static void AddExactNormalizedWithAlias(List<string> where, HashSet<string> cols, string column, string alias, string? value, string parameter)
	{
		if (cols.Contains(column) && !string.IsNullOrWhiteSpace(value) && value != "(All)")
		{
			where.Add(NormalizedEqualsExpression(alias, column, parameter));
		}
	}

	private static void AddStartsWithWithAlias(List<string> where, HashSet<string> cols, string column, string alias, string? value, string parameter)
	{
		if (cols.Contains(column) && !string.IsNullOrWhiteSpace(value))
		{
			where.Add($"{alias}.[{column}] LIKE {parameter}");
		}
	}

	private static void AddDateRangeWithAlias(List<string> where, HashSet<string> cols, string column, string alias, DateTime? from, DateTime? to, string fromParameter, string toParameter)
	{
		if (!cols.Contains(column)) return;
		if (from.HasValue) where.Add($"{alias}.[{column}] >= {fromParameter}");
		if (to.HasValue) where.Add($"{alias}.[{column}] <= {toParameter}");
	}

	private static async Task<bool> ShouldUseClaimLevelInsuranceBalanceAsync(SqlConnection connection, int labId, CancellationToken cancellationToken)
	{
		if (!ClaimLevelInsuranceBalanceLabIds.Contains(labId))
		{
			return false;
		}

		const string sql = @"
SELECT CASE WHEN EXISTS (
    SELECT 1
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'ClaimLevelData'
) THEN 1 ELSE 0 END;";

		await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 60 };
		var result = await command.ExecuteScalarAsync(cancellationToken);
		return result != null && result != DBNull.Value && Convert.ToInt32(result) == 1;
	}

	private static string BuildClaimLevelInsuranceBalanceApplySql(HashSet<string> claimLevelCols)
	{
		if (!claimLevelCols.Contains("ClaimID") || !claimLevelCols.Contains("InsuranceBalance"))
		{
			return string.Empty;
		}

		var orderBy = claimLevelCols.Contains("InsertedDateTime")
			? "ORDER BY TRY_CONVERT(datetime, cld.[InsertedDateTime]) DESC, TRY_CONVERT(int, cld.[RecordId]) DESC"
			: claimLevelCols.Contains("RecordId")
				? "ORDER BY TRY_CONVERT(int, cld.[RecordId]) DESC"
				: string.Empty;

		return $@"
OUTER APPLY
(
    SELECT TOP (1)
        TRY_CONVERT(decimal(18, 4), cld.[InsuranceBalance]) AS OverrideInsuranceBalance
    FROM dbo.ClaimLevelData cld WITH (INDEX(IX_ClaimLevelData_ClaimID_Latest))
    WHERE cld.[ClaimID] = dli.[VisitNumber]
      AND cld.[ClaimID] IS NOT NULL
      AND cld.[InsuranceBalance] IS NOT NULL
      AND cld.[InsuranceBalance] <> ''
    {orderBy}
) claimBal";
	}

	private static string SelectInsuranceBalance(HashSet<string> cols, HashSet<string> claimLevelCols, bool useClaimLevelInsuranceBalance, int scale)
	{
		if (useClaimLevelInsuranceBalance && claimLevelCols.Contains("ClaimID") && claimLevelCols.Contains("InsuranceBalance"))
		{
			var fallback = cols.Contains("InsuranceBalance")
				? $"TRY_CONVERT(decimal(18, {scale}), [InsuranceBalance])"
				: $"CAST(0 AS decimal(18, {scale}))";

			return $"COALESCE(claimBal.OverrideInsuranceBalance, {fallback}) AS [InsuranceBalance]";
		}

		return SelectDecimal(cols, "InsuranceBalance", scale);
	}

	private static async Task<IReadOnlyList<string>> GetAutocompleteValuesAsync(
		SqlConnection connection,
		int labId,
		string? currentRunId,
		string column,
		HashSet<string> taskCols,
		HashSet<string> lineCols,
		CancellationToken cancellationToken)
	{
		var queries = new List<string>();

		if (taskCols.Contains(column))
		{
			queries.Add($@"
SELECT LTRIM(RTRIM(CONVERT(nvarchar(255), [{column}]))) AS [Value]
FROM dbo.DenialTaskBoard
WHERE {BuildScopedWhere(taskCols, currentRunId)} AND ISNULL(CONVERT(nvarchar(255), [{column}]), '') <> ''");
		}

		if (lineCols.Contains(column))
		{
			queries.Add($@"
SELECT LTRIM(RTRIM(CONVERT(nvarchar(255), [{column}]))) AS [Value]
FROM dbo.DenialLineItem
WHERE {BuildScopedWhere(lineCols, currentRunId)} AND ISNULL(CONVERT(nvarchar(255), [{column}]), '') <> ''");
		}

		if (queries.Count == 0)
		{
			return Array.Empty<string>();
		}

		var sql = $@"
SELECT TOP (500) [Value]
FROM
(
    {string.Join("\n    UNION\n", queries)}
) AS src
WHERE ISNULL([Value], '') <> ''
GROUP BY [Value]
ORDER BY [Value];";

		var values = new List<string>();
		await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 180 };
		command.Parameters.AddWithValue("@LabId", labId);
		if (!string.IsNullOrWhiteSpace(currentRunId))
		{
			command.Parameters.AddWithValue("@RunId", currentRunId);
		}

		await using var reader = await command.ExecuteReaderAsync(cancellationToken);
		while (await reader.ReadAsync(cancellationToken))
		{
			var value = reader.IsDBNull(0) ? null : reader.GetString(0);
			if (!string.IsNullOrWhiteSpace(value))
			{
				values.Add(value.Trim());
			}
		}

		return values
			.Distinct(StringComparer.OrdinalIgnoreCase)
			.OrderBy(x => x)
			.ToList();
	}

	private async Task<SqlConnection> OpenLabConnectionAsync(int labId, CancellationToken cancellationToken)
	{
		var lab = await GetLabAsync(labId, cancellationToken);
		if (string.IsNullOrWhiteSpace(lab.ConnectionKey))
		{
			throw new InvalidOperationException($"Lab '{lab.LabName}' does not have a ConnectionKey in dbo.LRNMetricsLab.");
		}

		var connectionString = _configuration.GetConnectionString(lab.ConnectionKey);
		if (string.IsNullOrWhiteSpace(connectionString))
		{
			throw new InvalidOperationException($"Connection string '{lab.ConnectionKey}' was not found in appsettings.json.");
		}

		var connection = new SqlConnection(connectionString);
		await connection.OpenAsync(cancellationToken);
		return connection;
	}

	private async Task<bool> TableExistsAsync(SqlConnection connection, string schema, string table, CancellationToken cancellationToken)
	{
		const string sql = @"
SELECT CASE WHEN EXISTS (
    SELECT 1
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA = @Schema AND TABLE_NAME = @Table
) THEN 1 ELSE 0 END;";
		await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 60 };
		command.Parameters.AddWithValue("@Schema", schema);
		command.Parameters.AddWithValue("@Table", table);
		var result = await command.ExecuteScalarAsync(cancellationToken);
		return result != null && result != DBNull.Value && Convert.ToInt32(result) == 1;
	}

	private async Task<HashSet<string>> GetTableColumnsAsync(SqlConnection connection, string schema, string table, CancellationToken cancellationToken)
	{
		var cacheKey = $"schema:{connection.DataSource}:{connection.Database}:{schema}.{table}";
		return await _cache.GetOrCreateAsync(cacheKey, async entry =>
		{
			entry.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(30);
			const string sql = @"
SELECT COLUMN_NAME
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = @Schema AND TABLE_NAME = @Table;";
			var items = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
			await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 60 };
			command.Parameters.AddWithValue("@Schema", schema);
			command.Parameters.AddWithValue("@Table", table);
			await using var reader = await command.ExecuteReaderAsync(cancellationToken);
			while (await reader.ReadAsync(cancellationToken))
			{
				var name = reader.GetString(0);
				if (!string.IsNullOrWhiteSpace(name)) items.Add(name);
			}
			return items;
		}) ?? new HashSet<string>(StringComparer.OrdinalIgnoreCase);
	}

	private static string BuildScopedWhere(HashSet<string> cols, string? currentRunId)
	{
		var where = new List<string>();
		if (cols.Contains("LabId")) where.Add("[LabId] = @LabId");
		if (!string.IsNullOrWhiteSpace(currentRunId) && cols.Contains("RunId")) where.Add("[RunId] = @RunId");
		return where.Count == 0 ? "1 = 1" : string.Join(" AND ", where);
	}

	private static void AddScopeParameters(SqlCommand command, HashSet<string> cols, int labId, string? currentRunId)
	{
		if (cols.Contains("LabId")) command.Parameters.AddWithValue("@LabId", labId);
		if (!string.IsNullOrWhiteSpace(currentRunId) && cols.Contains("RunId")) command.Parameters.AddWithValue("@RunId", currentRunId);
	}

	private static string BuildLineItemWhere(HashSet<string> cols, DenialDashboardFilters filters, string? currentRunId)
	{
		var where = new List<string>();

		AddExact(where, cols, "TaskStatus", filters.Status, "@Status");
		AddExactNormalized(where, cols, "Priority", filters.Priority, "@Priority");
		AddExactNormalized(where, cols, "ActionCategory", filters.ActionCategory, "@ActionCategory");
		AddExactNormalized(where, cols, "DenialClassification", filters.Classification, "@Classification");

		AddStartsWith(where, cols, "SalesRepname", filters.SalesRepname, "@SalesRepname");
		AddStartsWith(where, cols, "ClinicName", filters.ClinicName, "@ClinicName");
		AddStartsWith(where, cols, "ReferringProvider", filters.ReferringProvider, "@ReferringProvider");
		AddStartsWith(where, cols, "PayerName", filters.PayerName, "@PayerName");
		AddStartsWith(where, cols, "PayerType", filters.PayerType, "@PayerType");
		AddStartsWith(where, cols, "PanelName", filters.PanelName, "@PanelName");

		AddDateRange(where, cols, "FirstBilledDate", filters.FirstBilledDateFrom, filters.FirstBilledDateTo, "@FirstBilledDateFrom", "@FirstBilledDateTo");
		AddDateRange(where, cols, "DateOfService", filters.DateOfServiceFrom, filters.DateOfServiceTo, "@DateOfServiceFrom", "@DateOfServiceTo");

		return where.Count == 0 ? "1 = 1" : string.Join(" AND ", where);
	}

	private static void AddExact(List<string> where, HashSet<string> cols, string column, string? value, string parameter)
	{
		if (cols.Contains(column) && !string.IsNullOrWhiteSpace(value) && value != "(All)")
		{
			where.Add($"ISNULL(CONVERT(nvarchar(255), [{column}]), '') = {parameter}");
		}
	}

	private static void AddExactNormalized(List<string> where, HashSet<string> cols, string column, string? value, string parameter)
	{
		if (cols.Contains(column) && !string.IsNullOrWhiteSpace(value) && value != "(All)")
		{
			where.Add($"{NormalizedEqualsExpression(column, parameter)}");
		}
	}

	private static string NormalizedEqualsExpression(string column, string parameter)
		=> NormalizedEqualsExpression(null, column, parameter);

	private static string NormalizedEqualsExpression(string? alias, string column, string parameter)
	{
		var qualifiedColumn = string.IsNullOrWhiteSpace(alias) ? $"[{column}]" : $"{alias}.[{column}]";
		return $@"(CASE 
                WHEN CHARINDEX(':', ISNULL(CONVERT(nvarchar(4000), {qualifiedColumn}), '')) > 0
                     AND PATINDEX('%[A-Za-z]%', LEFT(ISNULL(CONVERT(nvarchar(4000), {qualifiedColumn}), ''), CHARINDEX(':', ISNULL(CONVERT(nvarchar(4000), {qualifiedColumn}), '')) - 1)) > 0
                     AND PATINDEX('%[0-9]%', LEFT(ISNULL(CONVERT(nvarchar(4000), {qualifiedColumn}), ''), CHARINDEX(':', ISNULL(CONVERT(nvarchar(4000), {qualifiedColumn}), '')) - 1)) > 0
                THEN LTRIM(SUBSTRING(ISNULL(CONVERT(nvarchar(4000), {qualifiedColumn}), ''), CHARINDEX(':', ISNULL(CONVERT(nvarchar(4000), {qualifiedColumn}), '')) + 1, 4000))
                ELSE ISNULL(CONVERT(nvarchar(4000), {qualifiedColumn}), '')
            END) = {parameter}";
	}

	private static void AddStartsWith(List<string> where, HashSet<string> cols, string column, string? value, string parameter)
	{
		if (cols.Contains(column) && !string.IsNullOrWhiteSpace(value))
		{
			where.Add($"[{column}] LIKE {parameter}");
		}
	}

	private static void AddDateRange(List<string> where, HashSet<string> cols, string column, DateTime? from, DateTime? to, string fromParameter, string toParameter)
	{
		if (!cols.Contains(column)) return;
		if (from.HasValue) where.Add($"[{column}] >= {fromParameter}");
		if (to.HasValue) where.Add($"[{column}] <= {toParameter}");
	}

	private static void AddLineItemFilterParameters(SqlCommand command, DenialDashboardFilters filters)
	{
		if (filters.Status != "(All)") command.Parameters.AddWithValue("@Status", filters.Status);
		if (filters.Priority != "(All)") command.Parameters.AddWithValue("@Priority", filters.Priority);
		if (filters.ActionCategory != "(All)") command.Parameters.AddWithValue("@ActionCategory", filters.ActionCategory);
		if (filters.Classification != "(All)") command.Parameters.AddWithValue("@Classification", filters.Classification);
		if (!string.IsNullOrWhiteSpace(filters.SalesRepname)) command.Parameters.AddWithValue("@SalesRepname", $"{filters.SalesRepname.Trim()}%");
		if (!string.IsNullOrWhiteSpace(filters.ClinicName)) command.Parameters.AddWithValue("@ClinicName", $"{filters.ClinicName.Trim()}%");
		if (!string.IsNullOrWhiteSpace(filters.ReferringProvider)) command.Parameters.AddWithValue("@ReferringProvider", $"{filters.ReferringProvider.Trim()}%");
		if (!string.IsNullOrWhiteSpace(filters.PayerName)) command.Parameters.AddWithValue("@PayerName", $"{filters.PayerName.Trim()}%");
		if (!string.IsNullOrWhiteSpace(filters.PayerType)) command.Parameters.AddWithValue("@PayerType", $"{filters.PayerType.Trim()}%");
		if (!string.IsNullOrWhiteSpace(filters.PanelName)) command.Parameters.AddWithValue("@PanelName", $"{filters.PanelName.Trim()}%");
		if (filters.FirstBilledDateFrom.HasValue) command.Parameters.AddWithValue("@FirstBilledDateFrom", filters.FirstBilledDateFrom.Value.Date);
		if (filters.FirstBilledDateTo.HasValue) command.Parameters.AddWithValue("@FirstBilledDateTo", filters.FirstBilledDateTo.Value.Date);
		if (filters.DateOfServiceFrom.HasValue) command.Parameters.AddWithValue("@DateOfServiceFrom", filters.DateOfServiceFrom.Value.Date);
		if (filters.DateOfServiceTo.HasValue) command.Parameters.AddWithValue("@DateOfServiceTo", filters.DateOfServiceTo.Value.Date);
		if (filters.DenialDateFrom.HasValue) command.Parameters.AddWithValue("@DenialDateFrom", filters.DenialDateFrom.Value.Date);
		if (filters.DenialDateTo.HasValue) command.Parameters.AddWithValue("@DenialDateTo", filters.DenialDateTo.Value.Date);
	}

	private static IReadOnlyList<DenialInsightRecord> BuildInsights(IEnumerable<DenialRecord> records)
	{
		return records
			.Where(x => !string.IsNullOrWhiteSpace(x.DenialCode))
			.GroupBy(x => new
			{
				DenialCode = string.IsNullOrWhiteSpace(x.DenialCode) ? "(Blank)" : x.DenialCode.Trim(),
				Description = string.IsNullOrWhiteSpace(x.DenialDescription) ? string.Empty : x.DenialDescription.Trim(),
				ActionCategory = string.IsNullOrWhiteSpace(x.EffectiveActionCategory) ? string.Empty : x.EffectiveActionCategory.Trim(),
				ActionCode = string.IsNullOrWhiteSpace(x.ActionCode) ? string.Empty : x.ActionCode.Trim(),
				Action = string.IsNullOrWhiteSpace(x.RecommendedAction) ? string.Empty : x.RecommendedAction.Trim(),
				Task = string.IsNullOrWhiteSpace(x.Task) ? string.Empty : x.Task.Trim()
			})
			.Select(group =>
			{
				var totalBalance = decimal.Round(group.Sum(x => x.EffectiveTotalBalance), 2);
				var topPayer = group
					.GroupBy(
						x => !string.IsNullOrWhiteSpace(x.PayerNameNormalized) ? x.PayerNameNormalized.Trim() : (string.IsNullOrWhiteSpace(x.PayerName) ? "(Blank)" : x.PayerName.Trim()),
						StringComparer.OrdinalIgnoreCase)
					.Select(g => new { PayerName = g.Key, Balance = decimal.Round(g.Sum(x => x.InsuranceBalance), 2) })
					.OrderByDescending(x => x.Balance)
					.ThenBy(x => x.PayerName)
					.FirstOrDefault();

				var highImpactInsuranceBalance = topPayer?.Balance ?? 0m;

				return new DenialInsightRecord
				{
					DenialCodes = group.Key.DenialCode,
					Descriptions = group.Key.Description,
					NoOfDenialCount = group.Count(),
					NoOfClaimsCount = group.Select(x => x.ClaimId).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count(),
					TotalBalance = totalBalance,
					HighImpactInsurance = topPayer?.PayerName ?? string.Empty,
					InsuranceBalance = highImpactInsuranceBalance,
					ImpactPercentage = totalBalance == 0 ? 0 : decimal.Round((highImpactInsuranceBalance / totalBalance) * 100m, 2),
					ActionCategory = group.Key.ActionCategory,
					ActionCode = group.Key.ActionCode,
					Action = group.Key.Action,
					Task = group.Key.Task,
					Feedback = group.Select(x => x.Feedback).FirstOrDefault(x => !string.IsNullOrWhiteSpace(x)) ?? string.Empty,
					Responsibility = group.Select(x => x.Responsibility).FirstOrDefault(x => !string.IsNullOrWhiteSpace(x)) ?? string.Empty,
					DiscussionDate = group.Select(x => x.DiscussionDate).FirstOrDefault(x => x.HasValue),
					ETA = group.Select(x => x.ETA).FirstOrDefault(x => !string.IsNullOrWhiteSpace(x)) ?? string.Empty,
					LabId = group.Select(x => x.LabId).FirstOrDefault(),
					LabName = group.Select(x => x.LabName).FirstOrDefault() ?? string.Empty,
					RunId = group.Select(x => x.RunId).FirstOrDefault() ?? string.Empty,
					CreatedOn = group.Max(x => x.CreatedOn)
				};
			})
			.OrderByDescending(x => x.TotalBalance)
			.ThenByDescending(x => x.InsuranceBalance)
			.ThenBy(x => x.DenialCodes)
			.ToList();
	}

	private static string SelectString(HashSet<string> cols, string column)
		=> cols.Contains(column) ? $"ISNULL(CONVERT(nvarchar(max), [{column}]), '') AS [{column}]" : $"CAST('' AS nvarchar(max)) AS [{column}]";

	private static string SelectDecimal(HashSet<string> cols, string column, int scale)
		=> cols.Contains(column) ? $"TRY_CONVERT(decimal(18, {scale}), [{column}]) AS [{column}]" : $"CAST(0 AS decimal(18, {scale})) AS [{column}]";

	private static string SelectInt(HashSet<string> cols, string column)
		=> cols.Contains(column) ? $"TRY_CONVERT(int, [{column}]) AS [{column}]" : $"CAST(0 AS int) AS [{column}]";

	private static string SelectBit(HashSet<string> cols, string column)
		=> cols.Contains(column) ? $"TRY_CONVERT(bit, [{column}]) AS [{column}]" : $"CAST(0 AS bit) AS [{column}]";

	private static string SelectDate(HashSet<string> cols, string column)
		=> cols.Contains(column) ? $"TRY_CONVERT(datetime, [{column}]) AS [{column}]" : $"CAST(NULL AS datetime) AS [{column}]";

	private static string OrderBy(HashSet<string> cols, string primary, string fallback)
	{
		var primaryExpr = cols.Contains(primary) ? $"[{primary}]" : cols.Contains(fallback) ? $"[{fallback}]" : "(SELECT NULL)";
		var fallbackExpr = cols.Contains(fallback) ? $", [{fallback}]" : string.Empty;
		return $"{primaryExpr}{fallbackExpr}";
	}

	private static int GetInt(IDataRecord record, string column) => record[column] == DBNull.Value ? 0 : Convert.ToInt32(record[column]);
	private static string GetString(IDataRecord record, string column) => record[column] == DBNull.Value ? string.Empty : Convert.ToString(record[column]) ?? string.Empty;
	private static string? GetNullableString(IDataRecord record, string column) => record[column] == DBNull.Value ? null : Convert.ToString(record[column]);
	private static int? GetNullableInt(IDataRecord record, string column) => record[column] == DBNull.Value ? null : Convert.ToInt32(record[column]);
	private static bool? GetNullableBool(IDataRecord record, string column) => record[column] == DBNull.Value ? null : Convert.ToBoolean(record[column]);
	private static decimal? GetNullableDecimal(IDataRecord record, string column) => record[column] == DBNull.Value ? null : Convert.ToDecimal(record[column]);
	private static DateTime? GetNullableDateTime(IDataRecord record, string column) => record[column] == DBNull.Value ? null : Convert.ToDateTime(record[column]);
}
